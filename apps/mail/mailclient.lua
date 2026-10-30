-- Talking to a mail server from the Mail app. net.requestHost only sends to the computer holding
-- the hostname, according to the root server for its top-level domain. Passwords are only sent
-- when signing in. What's kept is the token the server gives back, sealed with a key from the
-- user's own secret key, so other people logging in to this computer can't use it.

local crypto = require("crypto")
local net = require("net")
local trust = require("trust")
local util = require("util")

local client = {}

local PORT = 4202 -- must match the mail server's
local DIR = "/etc/zos/mail-client"
local TIMEOUT = 15 -- seconds

-- Split user@host. Returns user and host, or nil and a reason.
function client.parseAddress(address)
    local user, host = (address or ""):match("^([a-z0-9_%-]+)@([^@]+)$")
    if not user or #user > 16 or not trust.parseHost(host) then
        return nil, "Addresses look like you@zmail.root-a, in lowercase."
    end
    return user, host
end

local function path(session)
    return fs.combine(DIR, session.user)
end

local function sealingKey(session)
    return session.secretKey and crypto.hmac(session.secretKey, "zos-mail-client-1")
end

-- The account this user is signed in to, as { user, host, token }, if any.
function client.load(session)
    local key = sealingKey(session)
    local box = key and util.readTable(path(session))
    local plain = box and crypto.open(key, box)
    local user, host, token = (plain or ""):match("^([^\n]+)\n([^\n]+)\n([^\n]+)$")
    if user then return { user = user, host = host, token = token } end
end

local function save(session, account)
    local key = sealingKey(session)
    if key then
        util.writeTable(path(session), crypto.seal(key, account.user .. "\n" .. account.host .. "\n" .. account.token))
    end
end

function client.forget(session)
    fs.delete(path(session))
end

-- Send one request. Returns the answer, or nil, a reason and whether signing in again would help.
local function call(host, payload)
    local reply, err = net.requestHost(host, PORT, payload, { timeout = TIMEOUT })
    if not reply then return nil, "Couldn't reach " .. host .. ":\n\n" .. tostring(err) end
    local answer = reply.payload
    if type(answer) ~= "table" then return nil, host .. " sent a bad answer." end
    if answer.error then return nil, tostring(answer.error), answer.auth end
    return answer
end

local function signIn(session, op, address, password)
    local user, host = client.parseAddress(address)
    if not user then return nil, host end
    local answer, err = call(host, { op = op, user = user, password = password })
    if not answer then return nil, err end
    if type(answer.token) ~= "string" then return nil, host .. " sent a bad answer." end
    local account = { user = user, host = host, token = answer.token }
    save(session, account)
    return account
end

function client.signIn(session, address, password)
    return signIn(session, "login", address, password)
end

function client.signUp(session, address, password)
    return signIn(session, "signup", address, password)
end

-- Run an operation on the account's mail server.
function client.call(account, op, fields)
    local payload = fields or {}
    payload.op, payload.user, payload.token = op, account.user, account.token
    return call(account.host, payload)
end

function client.changePassword(session, account, new)
    local answer, err = client.call(account, "password", { new = new })
    if not answer then return nil, err end
    account.token = answer.token
    save(session, account)
    return true
end

return client
