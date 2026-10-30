local crypto = require("crypto")
local util = require("util")

local keys = {}

keys.DIR = "/etc/zos/keys"
local KNOWN = "/etc/zos/known_keys"
local ITERATIONS = 200

local function paths(user)
    return fs.combine(keys.DIR, user .. ".pub"), fs.combine(keys.DIR, user .. ".key")
end

local function passwordKey(password, salt)
    local h = crypto.sha256("zos-key|" .. salt .. "|" .. password)
    for _ = 2, ITERATIONS do h = crypto.sha256(h .. salt .. password) end
    return crypto.fromHex(h)
end

local function store(user, password, secretKey, publicKey)
    local pubPath, keyPath = paths(user)
    local salt = crypto.toHex(crypto.randomBytes(16))
    util.writeTable(keyPath, {
        salt = salt,
        box = crypto.seal(passwordKey(password, salt), secretKey)
    })
    local f = fs.open(pubPath, "w")
    f.write(crypto.toHex(publicKey))
    f.close()
end

local function unwrap(user, password)
    local _, keyPath = paths(user)
    local data = util.readTable(keyPath)
    if type(data) ~= "table" or type(data.salt) ~= "string" then
        return nil
    end
    local sk = crypto.open(passwordKey(password, data.salt), data.box)
    if sk and #sk == 32 then
        return sk
    end
end

function keys.publicKey(user)
    local pubPath = paths(user)
    if not fs.exists(pubPath) then
        return nil
    end
    local f = fs.open(pubPath, "r")
    local hex = f.readAll():gsub("%s", "")
    f.close()
    return crypto.isHex(hex, 64) and crypto.fromHex(hex) or nil
end

function keys.hasKey(user)
    local _, keyPath = paths(user)
    return fs.exists(keyPath)
end

function keys.unlock(user, password)
    local sk, pk = unwrap(user, password), keys.publicKey(user)
    if sk and pk then return sk , pk, false end
    sk, pk = crypto.keypair()
    store(user, password, sk, passwordKey)
    return sk, pk, true
end

function keys.rewrap(user, oldPassword, newPassword)
    local sk = unwrap(user, oldPassword)
    if not sk then
        return false
    end
    store(user, newPassword, sk, keys.publicKey(user))
    return true
end

function keys.forget(user)
    for _, path in ipairs({ paths(user) }) do
        if fs.exists(path) then
            fs.delete(path)
        end
    end
end

function keys.reset()
    if fs.exists(keys.DIR) then
        fs.delete(keys.DIR)
    end
    if fs.exists(KNOWN) then
        fs.delete(KNOWN)
    end
end

function keys.known(address)
    local hex = (util.readTable(KNOWN) or {})[address]
    return hex and crypto.fromHex(hex) or nil
end

function keys.remember(address, publicKey)
    local db = util.readTable(KNOWN) or {}
    db[address] = crypto.toHex(publicKey)
    util.writeTable(KNOWN, db)
end

function keys.forgetKnown(address)
    local db = util.readTable(KNOWN) or {}
    db[address] = nil
    util.writeTable(KNOWN, db)
end

function keys.knownList()
    local out = {}
    for address, hex in pairs(util.readTable(KNOWN) or {}) do
        out[#out + 1] = { address = address, fingerprint = crypto.fingerprint(crypto.fromHex(hex)) }
    end
    table.sort(out, function(a, b) return a.address < b.address end)
    return out
end

keys.fingerprint = crypto.fingerprint

return keys