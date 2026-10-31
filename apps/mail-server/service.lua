--[[ Answers mail clients and other mail servers, and sends queued mail on, whether or not anyone
is logged in. Clients send a password once to get a token. Their requests go out with `expect`,
so they only reach the computer the root server named, and net.reply only goes to the key that
asked. Servers prove who a message is from by holding the hostname in its address.

Sending waits for the other server, which may be waiting for this one, so it gets its own loop.
So does asking another server for a public key. Requests that come in meanwhile wait in the
port's inbox. ]]

local crypto = require("crypto")
local db = require("maildb")
local net = require("net")
local system = require("system")

local WAKE = "mail_outbox"
local FIND = "mail_find_key"
local BASE_DELAY = 60 -- seconds, doubled after each failed try
local MAX_DELAY = 3600
local GIVE_UP = 3 * 24 * 3600 * 1000 -- ms
local TIMEOUT = 15 -- seconds
local MAX_FINDING = 8

local OPS = {}
local finding = {} -- public keys to get from other servers, as { msg, user, host }

function OPS.signup(_, payload)
    if not db.config().signups then return { error = "This server isn't taking new accounts." } end
    local ok, why = db.createAccount(payload.user, payload.password)
    if not ok then return { error = why } end
    return { token = db.login(payload.user, payload.password), certificate = db.certificate(payload.user) }
end

function OPS.login(_, payload)
    local token, why = db.login(payload.user, payload.password)
    if not token then return { error = why } end
    return { token = token, certificate = db.certificate(payload.user) }
end

-- Anyone can write to anyone, so public keys are for anyone to ask for.
function OPS.publicKey(_, payload)
    local key, why = db.publicKey(payload.user)
    if not key then return { error = why } end
    return { key = key }
end

-- What another server hands over. Each user gets "ok", or a reason. `retry` means trying again
-- could work.
function OPS.deliver(msg, payload)
    local host = db.hostname()
    local message = db.cleanMessage(payload.message)
    if not host or not message or type(payload.users) ~= "table" then return { error = "bad message" } end
    local _, fromHost = db.parseAddress(message.from)
    if not fromHost or not net.isHost(msg.peer, fromHost) then
        return { error = "this server can't verify that the sender is " .. tostring(fromHost) }
    end

    local results = {}
    for i = 1, math.min(#payload.users, db.MAX_RECIPIENTS) do
        local user = payload.users[i]
        if db.validUser(user) then
            local ok, why = db.store(user, message)
            results[user] = ok and "ok" or why
        end
    end
    return { results = results }
end

-- These need a signed-in account.
local AUTHED = {}

function AUTHED.certificate(user)
    return { certificate = db.certificate(user) }
end

-- The public key of any address, so that clients only have to trust their own server's root. The
-- answer for another server's address comes from `lookups`.
function AUTHED.findKey(_, payload, msg)
    local host = db.hostname()
    local name, target = db.parseAddress(payload.address, host)
    if not name then return { error = "'" .. tostring(payload.address) .. "' isn't an address, like bob@zmail.root-a." } end
    if target == host then
        local key, why = db.publicKey(name)
        if key then return { key = key } end
        return { error = why == "no such account" and ("There's no account called " .. name .. " here.") or why }
    end
    if #finding >= MAX_FINDING then return { error = "This server is busy. Try again in a moment." } end
    finding[#finding + 1] = { msg = msg, user = name, host = target }
    os.queueEvent(FIND)
end

function AUTHED.list(user)
    return { messages = db.index(user) }
end

function AUTHED.read(user, payload)
    local message = db.open(user, payload.id)
    if not message then return { error = "That message is gone." } end
    return { message = message }
end

function AUTHED.delete(user, payload)
    db.delete(user, payload.id)
    return {}
end

function AUTHED.send(user, payload)
    local id, why = db.submit(user, payload.to, payload.subject, payload.body, payload.keys)
    if not id then return { error = why } end
    os.queueEvent(WAKE)
    return { id = id }
end

function AUTHED.password(user, payload)
    local ok, why = db.changePassword(user, payload.old, payload.new)
    if not ok then return { error = why } end
    return { token = db.login(user, payload.new) }
end

function AUTHED.logout(user, payload)
    db.logout(user, payload.token)
    return {}
end

local function answer(msg)
    local payload = msg.payload
    if type(payload) ~= "table" then return { error = "bad request" } end
    if OPS[payload.op] then return OPS[payload.op](msg, payload) end
    if AUTHED[payload.op] then
        if not db.checkToken(payload.user, payload.token) then return { error = "Please sign in again.", auth = true } end
        return AUTHED[payload.op](payload.user, payload, msg)
    end
    return { error = "bad request" }
end

local function requests()
    while true do
        local msg = net.receive(db.PORT)
        if msg then
            local ok, result = pcall(answer, msg)
            if not ok then
                system.log("mail-server: " .. tostring(result))
                result = { error = "The server hit an error." }
            end
            if result then net.reply(msg, result) end -- `lookups` answers the rest
        end
    end
end

local function remoteKey(user, host)
    local address = user .. "@" .. host
    local reply, err = net.requestHost(host, db.PORT, { op = "publicKey", user = user }, { timeout = TIMEOUT })
    local answered = reply and reply.payload
    if type(answered) == "table" then
        if crypto.isHex(answered.key, 64) then
            db.rememberKey(address, answered.key)
            return { key = answered.key }
        elseif answered.error == "no such account" then
            return { error = "There's no account called " .. address .. "." }
        end
        err = answered.error
    end
    local known = db.knownKey(address)
    if known then return { key = known } end
    return { error = "Couldn't get the key for " .. address .. ":\n\n" .. tostring(err) }
end

local function lookups()
    while true do
        local job = table.remove(finding, 1)
        if job then
            local ok, result = pcall(remoteKey, job.user, job.host)
            if not ok then
                system.log("mail-server: " .. tostring(result))
                result = { error = "The server hit an error." }
            end
            net.reply(job.msg, result)
        else
            os.pullEventRaw(FIND)
        end
    end
end

local function delay(attempts)
    return math.min(BASE_DELAY * 2 ^ attempts, MAX_DELAY)
end

local function addresses(users, host)
    local out = {}
    for i, user in ipairs(users) do out[i] = user .. "@" .. host end
    return out
end

-- Try again later, or give up if it's been too long.
local function postpone(entry, users, why)
    if os.epoch("utc") - entry.created >= GIVE_UP then
        db.bounce(entry.message, addresses(users, entry.host), why)
        db.updateQueued(entry.id, nil)
        return
    end
    db.updateQueued(entry.id, {
        users = users, attempts = entry.attempts + 1, lastError = why,
        nextTry = os.epoch("utc") + delay(entry.attempts) * 1000,
    })
end

local function attempt(entry)
    local reply, err = net.requestHost(entry.host, db.PORT, {
        op = "deliver", users = entry.users, message = entry.message,
    }, { timeout = TIMEOUT })
    local answered = reply and reply.payload
    if type(answered) ~= "table" or type(answered.results) ~= "table" then
        return postpone(entry, entry.users, tostring(type(answered) == "table" and answered.error or err))
    end

    local later, why = {}, nil
    for _, user in ipairs(entry.users) do
        local result = answered.results[user]
        if result == "no such account" then
            db.bounce(entry.message, { user .. "@" .. entry.host }, "There's no such account.")
        elseif result ~= "ok" then
            later[#later + 1] = user
            why = tostring(result)
        end
    end
    if #later > 0 then return postpone(entry, later, why) end
    db.updateQueued(entry.id, nil)
end

local function outgoing()
    while true do
        local tried = false
        local soonest
        for _, entry in ipairs(db.outbox()) do
            if entry.nextTry <= os.epoch("utc") then
                tried = true
                local ok, err = pcall(attempt, entry)
                if not ok then
                    system.log("mail-server: " .. tostring(err))
                    db.updateQueued(entry.id, { nextTry = os.epoch("utc") + MAX_DELAY * 1000 })
                end
            elseif not soonest or entry.nextTry < soonest then
                soonest = entry.nextTry
            end
        end
        -- Sending yields, so look again for anything that came in meanwhile before going to sleep.
        if not tried then
            local wait = soonest and math.max(1, (soonest - os.epoch("utc")) / 1000) or MAX_DELAY
            local timer = os.startTimer(wait)
            while true do
                local e, id = os.pullEventRaw()
                if e == WAKE or (e == "timer" and id == timer) then break end
            end
        end
    end
end

net.listen(db.PORT)
parallel.waitForAll(requests, outgoing, lookups)
