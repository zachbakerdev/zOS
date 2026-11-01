-- Talking to a mail server from the Mail app. net.requestHost only sends to the computer holding
-- the hostname, according to the root server for its top-level domain. Passwords are only sent
-- when signing in. What's kept is the token the server gives back and the account's mail key,
-- sealed with a key from the user's own secret key, so other people logging in to this computer
-- can't use them.
--
-- The server holds the account's mail key locked with the password, and hands it over at sign-in
-- to be opened here. Message bodies are encrypted here for each recipient's public key, and
-- decrypted here, so the server only ever stores them encrypted.

local crypto = require("crypto")
local net = require("net")
local trust = require("trust")
local util = require("util")

local client = {}

local PORT = 4202 -- must match the mail server's
local TIMEOUT = 15 -- seconds
local FIND_TIMEOUT = 45 -- seconds; the server may have to look up another server first
local MAX_BODY = 8192 -- must match the mail server's

-- Split user@host. Returns user and host, or nil and a reason.
function client.parseAddress(address)
    local user, host = (address or ""):match("^([a-z0-9_%-]+)@([^@]+)$")
    if not user or #user > 16 or not trust.parseHost(host) then
        return nil, "Addresses look like you@zmail.root-a, in lowercase."
    end
    return user, host
end

local function path(session)
    return "/home/" .. session.user .. "/.config/mail/account"
end

local function sealingKey(session)
    return session.secretKey and crypto.hmac(session.secretKey, "zos-mail-client-1")
end

-- The account this user is signed in to, as { user, host, token, secret, public }, if any.
function client.load(session)
    local key = sealingKey(session)
    local box = key and util.readTable(path(session))
    local plain = box and crypto.open(key, box)
    local user, host, token, secret, public = (plain or ""):match("^([^\n]+)\n([^\n]+)\n([^\n]+)\n(%x+)\n(%x+)$")
    if user then
        return { user = user, host = host, token = token, secret = crypto.fromHex(secret), public = crypto.fromHex(public) }
    end
end

local function save(session, account)
    local key = sealingKey(session)
    if key then
        util.writeTable(path(session), crypto.seal(key, table.concat({ account.user, account.host, account.token,
            crypto.toHex(account.secret), crypto.toHex(account.public) }, "\n")))
    end
end

function client.forget(session)
    fs.delete(path(session))
end

-- Send one request. Returns the answer, or nil, a reason and whether signing in again would help.
local function call(host, payload, timeout)
    local reply, err = net.requestHost(host, PORT, payload, { timeout = timeout or TIMEOUT })
    if not reply then return nil, "Couldn't reach " .. host .. ":\n\n" .. tostring(err) end
    local answer = reply.payload
    if type(answer) ~= "table" then return nil, host .. " sent a bad answer." end
    if answer.error then return nil, tostring(answer.error), answer.auth end
    return answer
end

-- Open a certificate from the server. Returns the secret and public keys, or nil.
local function unlock(certificate, password)
    if type(certificate) ~= "table" or not crypto.isHex(certificate.public, 64) then return nil end
    local secret = crypto.unlock(password, certificate.locked)
    local public = crypto.fromHex(certificate.public)
    if secret and #secret == 32 and crypto.publicKey(secret) == public then return secret, public end
end

local function signIn(session, op, address, password)
    local user, host = client.parseAddress(address)
    if not user then return nil, host end
    local answer, err = call(host, { op = op, user = user, password = password })
    if not answer then return nil, err end
    if type(answer.token) ~= "string" then return nil, host .. " sent a bad answer." end
    local secret, public = unlock(answer.certificate, password)
    if not secret then return nil, "Your key from " .. host .. " can't be decrypted with this password." end
    local account = { user = user, host = host, token = answer.token, secret = secret, public = public }
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
function client.call(account, op, fields, timeout)
    local payload = fields or {}
    payload.op, payload.user, payload.token = op, account.user, account.token
    return call(account.host, payload, timeout)
end

-- Encrypt a message for each recipient and send it. Returns what client.call does.
function client.send(account, to, subject, body)
    if type(body) ~= "string" then return nil, "That message is malformed." end
    if #body > MAX_BODY then return nil, "Messages are up to " .. MAX_BODY .. " bytes." end
    local key = crypto.randomBytes(32)
    local addresses, keys = {}, {}
    for i, address in ipairs(to) do
        if not address:find("@", 1, true) then address = address .. "@" .. account.host end
        local answer, err, expired = client.call(account, "findKey", { address = address }, FIND_TIMEOUT)
        if not answer then return nil, err, expired end
        keys[address] = crypto.isHex(answer.key, 64) and crypto.sealTo(crypto.fromHex(answer.key), key) or nil
        if not keys[address] then return nil, account.host .. " sent a bad key for " .. address .. "." end
        addresses[i] = address
    end
    return client.call(account, "send", { to = addresses, subject = subject, body = crypto.seal(key, body), keys = keys })
end

-- A message's body as text, or nil if this account's key doesn't open it. Mail comes from anyone
-- and ends up on the screen, and the server can't see inside it, so it's cleaned here.
function client.decrypt(account, message)
    local key = crypto.openSealed(account.secret, account.public, message.key)
    local body = key and #key == 32 and crypto.open(key, message.body)
    if body then return (body:gsub("\r\n?", "\n"):gsub("[%z\1-\8\11-\31\127]", "")):sub(1, MAX_BODY) end
end

-- Save the certificate, still locked with the password, in the user's home. Returns its path.
function client.downloadCertificate(session, account)
    local answer, err, expired = client.call(account, "certificate")
    if not answer then return nil, err, expired end
    local file = "/home/" .. session.user .. "/" .. account.user .. "@" .. account.host .. ".key"
    util.writeTable(file, answer.certificate)
    return file
end

function client.changePassword(session, account, old, new)
    local answer, err = client.call(account, "password", { old = old, new = new })
    if not answer then return nil, err end
    account.token = answer.token
    save(session, account)
    return true
end

return client
