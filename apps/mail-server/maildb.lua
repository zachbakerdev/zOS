-- The mail server's accounts, mailboxes and outgoing queue. Kept in files because the app and its
-- service each load their own copy of this module, and both change them. Hashing and signing
-- yield, so nothing here holds a table it read before one of those and writes it back after.
--
-- Bodies are never here in the clear. An account's secret key is kept locked with its password,
-- and whoever sends a message seals it with a new key, which only the recipient's secret key can
-- get back. Addresses, subjects and dates are not encrypted, since servers need them.

local crypto = require("crypto")
local trust = require("trust")
local util = require("util")

local db = {}

db.PORT = 4202
db.MAX_BODY = 8192
db.MAX_SUBJECT = 64
db.MAX_RECIPIENTS = 8

local DIR = "/etc/mail-server"
local OLD_DIR = "/etc/zos/mail-server" -- where zOS 2 kept this
local CONFIG = fs.combine(DIR, "config")
local ACCOUNTS = fs.combine(DIR, "accounts")
local OUTBOX = fs.combine(DIR, "outbox")
local BOXES = fs.combine(DIR, "boxes")
local KEYS = fs.combine(DIR, "keys") -- public keys of accounts on other servers

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
local MAX_KNOWN_KEYS = 256

-- Bring over what an older version saved. The app and its service both get here, and nothing
-- here yields, so only the first one moves it.
if fs.exists(OLD_DIR) and not fs.exists(DIR) then
    fs.makeDir("/etc")
    fs.move(OLD_DIR, DIR)
end

local failures = {} -- user -> { count, untilMs }

local function now()
    return os.epoch("utc")
end

local function hex(n)
    return crypto.toHex(crypto.randomBytes(n))
end

local function boxPath(user, name)
    return fs.combine(fs.combine(BOXES, user), name)
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

local function cleanBox(box, limit)
    if type(box) == "table" and crypto.isHex(box.nonce, 24) and crypto.isHex(box.ct) and #box.ct <= limit
            and crypto.isHex(box.tag, 64) then
        return { nonce = box.nonce, ct = box.ct, tag = box.tag }
    end
end

-- A message's key, sealed to one recipient.
local function cleanKey(box)
    local clean = cleanBox(box, 64)
    if clean and crypto.isHex(box.eph, 64) then
        clean.eph = box.eph
        return clean
    end
end

-- A copy of a message with only the expected fields, or nil. Its id goes in a path. The body can't
-- be checked here, so Mail cleans it after decrypting it.
function db.cleanMessage(message)
    if type(message) ~= "table" or type(message.subject) ~= "string" or type(message.from) ~= "string"
            or type(message.to) ~= "table" or type(message.keys) ~= "table" or not crypto.isHex(message.id, 32) then
        return nil
    end
    local body = cleanBox(message.body, 2 * db.MAX_BODY)
    if not body then return nil end
    local keys, count = {}, 0
    for user, box in pairs(message.keys) do
        count = count + 1
        if count > db.MAX_RECIPIENTS then return nil end
        if db.validUser(user) then keys[user] = cleanKey(box) end
    end
    local to = {}
    for i = 1, math.min(#message.to, db.MAX_RECIPIENTS) do
        if type(message.to[i]) == "string" then to[#to + 1] = cleanLine(message.to[i], 48) end
    end
    return {
        id = message.id, from = cleanLine(message.from, 48), to = to,
        subject = cleanLine(message.subject, db.MAX_SUBJECT), body = body, keys = keys, date = now(),
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

-- A new key pair, with the secret key locked by the password. The salt isn't the one the login
-- hash uses, and neither is the derivation, so that hash doesn't open the key.
local function newKey(password)
    crypto.addEntropy(password)
    local secret, public = crypto.keypair()
    return { public = crypto.toHex(public), locked = crypto.lock(password, secret) }
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
    local key = newKey(password)
    local accounts = loadAccounts()
    if accounts[user] then return nil, "That name is taken." end
    accounts[user] = { salt = salt, hash = hash, key = key, sealed = true, tokens = {}, created = now() }
    saveAccounts(accounts)
    return true
end

-- For an admin, who doesn't know the old password, so nothing can open the old secret key. The
-- account gets a new one, and mail already in the mailbox can no longer be read.
function db.setPassword(user, password)
    if type(password) ~= "string" or #password < MIN_PASSWORD then
        return nil, "Passwords must be at least " .. MIN_PASSWORD .. " characters."
    end
    local salt = hex(16)
    local hash = derive(password, salt)
    local key = newKey(password)
    local accounts = loadAccounts()
    if not accounts[user] then return nil, "There's no such account." end
    accounts[user].salt, accounts[user].hash, accounts[user].key, accounts[user].tokens = salt, hash, key, {}
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

-- Accounts from before mail was encrypted get their key at their next sign-in, the first time the
-- password is here, and what's in their mailbox is sealed then. One key does for all of it, because
-- sealing to a public key is slow and someone is waiting to sign in.
local function upgrade(user, password)
    local account = loadAccounts()[user]
    local cert = account.key or newKey(password)
    local accounts = loadAccounts()
    accounts[user].key = cert
    saveAccounts(accounts)

    local key = crypto.randomBytes(32)
    local sealed = crypto.sealTo(crypto.fromHex(cert.public), key)
    for _, entry in ipairs(db.index(user)) do
        local path = boxPath(user, entry.id)
        local message = util.readTable(path)
        if message and type(message.body) == "string" then
            message.body, message.key = crypto.seal(key, message.body), sealed
            util.writeTable(path, message)
        end
    end
    accounts = loadAccounts()
    accounts[user].sealed = true
    saveAccounts(accounts)
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
    if not account.sealed then upgrade(user, password) end
    return newToken(user)
end

-- The owner changing their own password. Their secret key stays the same, locked with the new one.
function db.changePassword(user, old, new)
    if type(new) ~= "string" or #new < MIN_PASSWORD then
        return nil, "Passwords must be at least " .. MIN_PASSWORD .. " characters."
    end
    if type(old) ~= "string" then return nil, "That isn't your password." end
    if lockedOut(user) then return nil, "Too many wrong passwords. Try again in a minute." end
    local account = loadAccounts()[user]
    if not account then return nil, "There's no such account." end
    if derive(old, account.salt) ~= account.hash then
        failed(user)
        return nil, "That isn't your password."
    end
    failures[user] = nil
    if not account.key then return db.setPassword(user, new) end

    local secret = crypto.unlock(old, account.key.locked)
    if not secret then return nil, "Your key can't be decrypted with this password." end
    local locked = crypto.lock(new, secret)
    local salt = hex(16)
    local hash = derive(new, salt)
    local accounts = loadAccounts()
    if not accounts[user] then return nil, "There's no such account." end
    accounts[user].salt, accounts[user].hash, accounts[user].tokens = salt, hash, {}
    accounts[user].key.locked = locked
    saveAccounts(accounts)
    return true
end

-- An account's public key and its locked secret key, as { public, locked }. Useless without the
-- password, so it's given to the account's owner to open.
function db.certificate(user)
    local account = loadAccounts()[user]
    return account and account.key
end

-- An account's public key, in hex, or nil and a reason.
function db.publicKey(user)
    local account = loadAccounts()[user]
    if not account then return nil, "no such account" end
    if not account.key then return nil, "this account has to sign in again before it can get mail" end
    return account.key.public
end

-- What other servers said about their accounts, so that mail can still be queued while they're away.
function db.knownKey(address)
    return (util.readTable(KEYS) or {})[address]
end

function db.rememberKey(address, key)
    local known = util.readTable(KEYS) or {}
    if known[address] == key then return end
    local count = 0
    for _ in pairs(known) do count = count + 1 end
    if count >= MAX_KNOWN_KEYS then known = {} end
    known[address] = key
    util.writeTable(KEYS, known)
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
    local key = message.keys[user]
    if not key then return nil, "not sealed for this account" end
    if #index >= MAX_MAILBOX then return nil, "mailbox full" end
    local dir = fs.combine(BOXES, user)
    fs.makeDir(dir)
    local size = #message.body.ct / 2
    if size + RESERVE > fs.getFreeSpace(dir) then return nil, "server out of space" end

    -- A recipient only gets their own copy of the message's key.
    util.writeTable(boxPath(user, message.id), {
        id = message.id, from = message.from, to = message.to, subject = message.subject, date = message.date,
        body = message.body, key = key,
    })
    table.insert(index, 1, {
        id = message.id, from = message.from, subject = message.subject, date = message.date,
        size = size, read = false,
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

-- Tell a sender here that their mail couldn't be delivered. This server can't read the message,
-- so it can't quote it.
function db.bounce(message, recipients, why)
    local user, host = message.from:match("^([^@]+)@(.+)$")
    local public = user and user ~= POSTMASTER and db.publicKey(user)
    if not public then return end
    local key = crypto.randomBytes(32)
    db.store(user, db.cleanMessage({
        id = hex(16), from = POSTMASTER .. "@" .. host, to = { message.from },
        subject = "Undeliverable: " .. message.subject,
        body = crypto.seal(key, "This message couldn't be delivered to " .. table.concat(recipients, ", ") ..
            ":\n\n" .. why),
        keys = { [user] = crypto.sealTo(crypto.fromHex(public), key) },
    }))
end

-- Accept a message from an account here. Nothing is sent unless every recipient is usable, so
-- that a typo can't leave a message half delivered. Returns the id, or nil and a reason.
-- `body` is sealed with a new key, and `keys` has that key sealed to each address in `to`.
function db.submit(user, to, subject, body, keys)
    local host = db.hostname()
    if not host then return nil, "This server has no hostname." end
    if type(to) ~= "table" or #to == 0 then return nil, "Say who it's for." end
    if #to > db.MAX_RECIPIENTS then return nil, "Up to " .. db.MAX_RECIPIENTS .. " recipients." end
    if type(subject) ~= "string" or type(keys) ~= "table" then return nil, "That message is malformed." end

    local here, there, hosts = {}, {}, 0
    local addresses, sealed = {}, {}
    for _, address in ipairs(to) do
        local name, target = db.parseAddress(address, host)
        if not name then return nil, "'" .. tostring(address) .. "' isn't an address, like bob@zmail.root-a." end
        addresses[#addresses + 1] = name .. "@" .. target
        local key = cleanKey(keys[addresses[#addresses]])
        if not key then return nil, "That message is malformed." end
        sealed[target] = sealed[target] or {}
        sealed[target][name] = key
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
        id = hex(16), from = user .. "@" .. host, to = addresses, subject = subject, body = body, keys = {},
    })
    if not message then return nil, "That message is malformed." end
    message.keys = sealed[host] or {}
    for _, name in ipairs(here) do
        local ok, why = db.store(name, message)
        if not ok then db.bounce(message, { name .. "@" .. host }, why) end
    end
    for target, users in pairs(there) do
        message.keys = sealed[target]
        db.queue(target, users, message)
    end
    return message.id
end

return db
