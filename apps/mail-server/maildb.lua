-- The mail server's accounts, mailboxes and outgoing queue. Kept in files because the app and its
-- service each load their own copy of this module, and both change them. Hashing and signing
-- yield, so nothing here holds a table it read before one of those and writes it back after.

local crypto = require("crypto")
local trust = require("trust")
local util = require("util")

local db = {}

db.PORT = 4202
db.MAX_BODY = 8192
db.MAX_SUBJECT = 64
db.MAX_RECIPIENTS = 8

local DIR = "/etc/zos/mail-server"
local CONFIG = fs.combine(DIR, "config")
local ACCOUNTS = fs.combine(DIR, "accounts")
local OUTBOX = fs.combine(DIR, "outbox")
local BOXES = fs.combine(DIR, "boxes")

local ITERATIONS = 200
local MIN_PASSWORD = 8
local MAX_ACCOUNTS = 64
local MAX_TOKENS = 8 -- devices signed in to one account
local TOKEN_LIFETIME = 30 * 24 * 3600 * 1000 -- ms
local MAX_MAILBOX = 64 -- messages
local MAX_OUTBOX = 32
local RESERVE = 8192 -- bytes of disk kept free for the indexes
local MAX_FAILURES = 5
local LOCK = 60000 -- ms
local POSTMASTER = "postmaster" -- bounces come from here, so nobody can have this account

local failures = {} -- user -> { count, untilMs }

local function now()
    return os.epoch("utc")
end

local function hex(n)
    return crypto.toHex(crypto.randomBytes(n))
end

function db.config()
    local config = util.readTable(CONFIG) or {}
    if config.signups == nil then config.signups = true end
    return config
end

function db.setConfig(changes)
    local config = db.config()
    for key, value in pairs(changes) do config[key] = value end
    util.writeTable(CONFIG, config)
end

-- The hostname this server holds a certificate for, and that certificate, if any.
function db.hostname()
    local config = db.config()
    local cert = config.root and trust.cert(config.root)
    if cert and cert.name == config.hostname then return config.hostname, cert end
end

function db.setHostname(host, root)
    db.setConfig({ hostname = host, root = root })
end

------------------------------------------------------------------------------
-- Addresses and messages
------------------------------------------------------------------------------

function db.validUser(user)
    if type(user) ~= "string" or #user > 16 or not user:match("^[a-z0-9_%-]+$") then
        return false, "Account names are 1-16 lowercase letters, digits, - or _."
    end
    return true
end

-- Split user@host. A bare name is on this server. Returns user and host, or nil.
function db.parseAddress(address, localHost)
    if type(address) ~= "string" then return nil end
    local user, host = address:match("^([^@]+)@([^@]+)$")
    if not user then user, host = address, localHost end
    if db.validUser(user) and trust.parseHost(host) then return user, host end
end

-- Mail comes from anyone and ends up on someone's screen, so only ordinary text gets through.
local function cleanLine(text, limit)
    return (text:gsub("%c", " ")):sub(1, limit)
end

local function cleanBody(text)
    return (text:gsub("\r\n?", "\n"):gsub("[%z\1-\8\11-\31\127]", "")):sub(1, db.MAX_BODY)
end

-- A copy of a message with only the expected fields, or nil. Its id goes in a path.
function db.cleanMessage(message)
    if type(message) ~= "table" or type(message.subject) ~= "string" or type(message.body) ~= "string"
            or type(message.from) ~= "string" or type(message.to) ~= "table" or not crypto.isHex(message.id, 32)
            or #message.body > db.MAX_BODY then
        return nil
    end
    local to = {}
    for i = 1, math.min(#message.to, db.MAX_RECIPIENTS) do
        if type(message.to[i]) == "string" then to[#to + 1] = cleanLine(message.to[i], 48) end
    end
    return {
        id = message.id, from = cleanLine(message.from, 48), to = to,
        subject = cleanLine(message.subject, db.MAX_SUBJECT), body = cleanBody(message.body), date = now(),
    }
end

------------------------------------------------------------------------------
-- Accounts
------------------------------------------------------------------------------

local function loadAccounts()
    return util.readTable(ACCOUNTS) or {}
end

local function saveAccounts(accounts)
    util.writeTable(ACCOUNTS, accounts)
end

local function derive(password, salt)
    local h = crypto.sha256(salt .. password)
    for _ = 2, ITERATIONS do h = crypto.sha256(h .. salt .. password) end
    return h
end

-- Every account name, sorted.
function db.accounts()
    local names = {}
    for name in pairs(loadAccounts()) do names[#names + 1] = name end
    table.sort(names)
    return names
end

function db.exists(user)
    return loadAccounts()[user] ~= nil
end

function db.createAccount(user, password)
    local ok, why = db.validUser(user)
    if not ok then return nil, why end
    if user == POSTMASTER then return nil, "That name is reserved." end
    if type(password) ~= "string" or #password < MIN_PASSWORD then
        return nil, "Passwords must be at least " .. MIN_PASSWORD .. " characters."
    end
    if db.exists(user) then return nil, "That name is taken." end
    if #db.accounts() >= MAX_ACCOUNTS then return nil, "This server is full." end

    local salt = hex(16)
    local hash = derive(password, salt)
    local accounts = loadAccounts()
    if accounts[user] then return nil, "That name is taken." end
    accounts[user] = { salt = salt, hash = hash, tokens = {}, created = now() }
    saveAccounts(accounts)
    return true
end

function db.setPassword(user, password)
    if type(password) ~= "string" or #password < MIN_PASSWORD then
        return nil, "Passwords must be at least " .. MIN_PASSWORD .. " characters."
    end
    local salt = hex(16)
    local hash = derive(password, salt)
    local accounts = loadAccounts()
    if not accounts[user] then return nil, "There's no such account." end
    accounts[user].salt, accounts[user].hash, accounts[user].tokens = salt, hash, {}
    saveAccounts(accounts)
    return true
end

function db.removeAccount(user)
    local accounts = loadAccounts()
    accounts[user] = nil
    saveAccounts(accounts)
    fs.delete(fs.combine(BOXES, user))
end

-- Whoever guesses wrong too often is locked out of this account for a while. Kept in memory, in
-- the service, which is the only caller.
local function lockedOut(user)
    local entry = failures[user]
    return entry and entry.locked and entry.locked > now()
end

local function failed(user)
    local entry = failures[user] or { count = 0 }
    entry.count = entry.count + 1
    if entry.count >= MAX_FAILURES then entry.count, entry.locked = 0, now() + LOCK end
    failures[user] = entry
end

local function newToken(user)
    local token = hex(24)
    local hash = crypto.sha256(token)
    local accounts = loadAccounts()
    local account = accounts[user]
    if not account then return nil end

    local count, oldest = 0, nil
    for key, expires in pairs(account.tokens) do
        if expires <= now() then
            account.tokens[key] = nil
        else
            count = count + 1
            if not oldest or expires < account.tokens[oldest] then oldest = key end
        end
    end
    if count >= MAX_TOKENS then account.tokens[oldest] = nil end
    account.tokens[hash] = now() + TOKEN_LIFETIME
    saveAccounts(accounts)
    return token
end

-- Swap a password for a token. Returns the token, or nil and a reason.
function db.login(user, password)
    if type(user) ~= "string" or type(password) ~= "string" then return nil, "Wrong account or password." end
    if lockedOut(user) then return nil, "Too many wrong passwords. Try again in a minute." end
    local account = loadAccounts()[user]
    if not account then return nil, "Wrong account or password." end
    if derive(password, account.salt) ~= account.hash then
        failed(user)
        return nil, "Wrong account or password."
    end
    failures[user] = nil
    return newToken(user)
end

function db.checkToken(user, token)
    if type(user) ~= "string" or type(token) ~= "string" then return false end
    local hash = crypto.sha256(token)
    local account = loadAccounts()[user]
    local expires = account and account.tokens[hash]
    return expires ~= nil and expires > now()
end

function db.logout(user, token)
    local hash = crypto.sha256(token)
    local accounts = loadAccounts()
    if accounts[user] then
        accounts[user].tokens[hash] = nil
        saveAccounts(accounts)
    end
end

------------------------------------------------------------------------------
-- Mailboxes
------------------------------------------------------------------------------

local function boxPath(user, name)
    return fs.combine(fs.combine(BOXES, user), name)
end

-- One account's messages without their bodies, newest first.
function db.index(user)
    return util.readTable(boxPath(user, "index")) or {}
end

local function saveIndex(user, index)
    util.writeTable(boxPath(user, "index"), index)
end

-- Put a clean message in a mailbox. A message sent again after a lost answer is only kept once.
-- Returns true, or nil and a reason.
function db.store(user, message)
    if not db.exists(user) then return nil, "no such account" end
    local index = db.index(user)
    for _, entry in ipairs(index) do
        if entry.id == message.id then return true end
    end
    if #index >= MAX_MAILBOX then return nil, "mailbox full" end
    local dir = fs.combine(BOXES, user)
    fs.makeDir(dir)
    if #message.body + RESERVE > fs.getFreeSpace(dir) then return nil, "server out of space" end

    util.writeTable(boxPath(user, message.id), message)
    table.insert(index, 1, {
        id = message.id, from = message.from, subject = message.subject, date = message.date,
        size = #message.body, read = false,
    })
    saveIndex(user, index)
    return true
end

-- A whole message, marked as read. Returns nil if there's no such message.
function db.open(user, id)
    if not crypto.isHex(id, 32) then return nil end
    local message = util.readTable(boxPath(user, id))
    if not message then return nil end
    local index = db.index(user)
    for _, entry in ipairs(index) do
        if entry.id == id then entry.read = true end
    end
    saveIndex(user, index)
    return message
end

function db.delete(user, id)
    if not crypto.isHex(id, 32) then return end
    fs.delete(boxPath(user, id))
    local index = db.index(user)
    for i, entry in ipairs(index) do
        if entry.id == id then
            table.remove(index, i)
            break
        end
    end
    saveIndex(user, index)
end

------------------------------------------------------------------------------
-- Outgoing queue
------------------------------------------------------------------------------

-- Messages waiting for other servers, as { id, host, users, message, attempts, nextTry, created, lastError }.
function db.outbox()
    return util.readTable(OUTBOX) or {}
end

local function saveOutbox(outbox)
    util.writeTable(OUTBOX, outbox)
end

function db.queue(host, users, message)
    local outbox = db.outbox()
    outbox[#outbox + 1] = {
        id = hex(8), host = host, users = users, message = message, attempts = 0, nextTry = 0, created = now(),
    }
    saveOutbox(outbox)
end

-- Change one entry. Other entries can be added while a delivery is under way, so this goes by id.
function db.updateQueued(id, changes)
    local outbox = db.outbox()
    for i, entry in ipairs(outbox) do
        if entry.id == id then
            if changes then
                for key, value in pairs(changes) do entry[key] = value end
            else
                table.remove(outbox, i)
            end
            return saveOutbox(outbox)
        end
    end
end

-- Tell a sender here that their mail couldn't be delivered.
function db.bounce(message, recipients, why)
    local user, host = message.from:match("^([^@]+)@(.+)$")
    if not user or user == POSTMASTER then return end
    db.store(user, db.cleanMessage({
        id = hex(16), from = POSTMASTER .. "@" .. host, to = { message.from },
        subject = "Undeliverable: " .. message.subject,
        body = "This message couldn't be delivered to " .. table.concat(recipients, ", ") .. ":\n\n" .. why ..
            "\n\n---\n" .. message.body:sub(1, db.MAX_BODY - 1024),
    }))
end

-- Accept a message from an account here. Nothing is sent unless every recipient is usable, so
-- that a typo can't leave a message half delivered. Returns the id, or nil and a reason.
function db.submit(user, to, subject, body)
    local host = db.hostname()
    if not host then return nil, "This server has no hostname." end
    if type(to) ~= "table" or #to == 0 then return nil, "Say who it's for." end
    if #to > db.MAX_RECIPIENTS then return nil, "Up to " .. db.MAX_RECIPIENTS .. " recipients." end
    if type(subject) ~= "string" or type(body) ~= "string" then return nil, "That message is malformed." end
    if #body > db.MAX_BODY then return nil, "Messages are up to " .. db.MAX_BODY .. " bytes." end

    local here, there, hosts = {}, {}, 0
    local addresses = {}
    for _, address in ipairs(to) do
        local name, target = db.parseAddress(address, host)
        if not name then return nil, "'" .. tostring(address) .. "' isn't an address, like bob@zmail.root-a." end
        addresses[#addresses + 1] = name .. "@" .. target
        if target == host then
            if not db.exists(name) then return nil, "There's no account called " .. name .. " here." end
            here[#here + 1] = name
        else
            if not there[target] then there[target], hosts = {}, hosts + 1 end
            table.insert(there[target], name)
        end
    end
    if #db.outbox() + hosts > MAX_OUTBOX then return nil, "Too much mail is waiting to go out. Try again later." end

    local message = db.cleanMessage({
        id = hex(16), from = user .. "@" .. host, to = addresses, subject = subject, body = body,
    })
    for _, name in ipairs(here) do
        local ok, why = db.store(name, message)
        if not ok then db.bounce(message, { name .. "@" .. host }, why) end
    end
    for target, users in pairs(there) do db.queue(target, users, message) end
    return message.id
end

return db
