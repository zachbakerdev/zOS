-- Users' key pairs, and keys pinned for remote addresses. See specs/libs/KEYS.md.

local crypto = require("crypto")
local system = require("system")
local util = require("util")

local keys = {}

local DIR = system.DATA .. "/keys"
local KNOWN = system.DATA .. "/known_keys"

local function path(user)
    return DIR .. "/" .. user
end

function keys.hasKey(user)
    return fs.exists(path(user)) or fs.exists(path(user) .. ".new")
end

function keys.publicKey(user)
    local stored = util.readTable(path(user))
    return stored and crypto.fromHex(stored.public) or nil
end

-- Make a user's key pair, locked with their password. Returns the secret and public keys.
function keys.create(user, password)
    local secret, public = crypto.keypair()
    util.writeTable(path(user), { public = crypto.toHex(public), locked = crypto.lock(password, secret) })
    return secret, public
end

-- The secret and public keys, or nil if the password is wrong. A password change that stopped
-- partway leaves the key locked with both passwords, so whichever opens it is the one to keep.
function keys.unlock(user, password)
    local stored = util.readTable(path(user))
    if not stored then return nil end
    local secret = crypto.unlock(password, stored.locked)
    if not secret and stored.previous then
        secret = crypto.unlock(password, stored.previous)
        if secret then stored.locked = stored.previous end
    end
    if not secret then return nil end
    if stored.previous then
        stored.previous = nil
        util.writeTable(path(user), stored)
    end
    return secret, crypto.fromHex(stored.public)
end

-- Lock the same key with a new password. The old lock stays until keys.settle, so a crash before
-- the new password is saved can't lose the key. Returns true, or false and a reason.
function keys.rewrap(user, oldPassword, newPassword)
    local secret, public = keys.unlock(user, oldPassword)
    if not secret then return false end
    local stored = util.readTable(path(user))
    return util.writeTable(path(user), {
        public = crypto.toHex(public),
        locked = crypto.lock(newPassword, secret),
        previous = stored.locked,
    })
end

-- The new password is saved, so the old lock can go.
function keys.settle(user)
    local stored = util.readTable(path(user))
    if stored and stored.previous then
        stored.previous = nil
        util.writeTable(path(user), stored)
    end
end

-- Move a key that can't be opened out of the way, in case it can be rescued by hand.
function keys.setAside(user)
    local from = fs.exists(path(user)) and path(user) or path(user) .. ".new"
    local to = path(user) .. "." .. os.epoch("utc") .. ".damaged"
    fs.move(from, to)
    return to
end

function keys.forget(user)
    fs.delete(path(user))
    fs.delete(path(user) .. ".new")
end

-- Delete every key on the computer, for a clean reinstall.
function keys.reset()
    fs.delete(DIR)
    fs.delete(KNOWN)
    fs.delete(system.DATA .. "/net")
end

local function pins()
    return util.readTable(KNOWN) or {}
end

function keys.known(address)
    local key = pins()[address]
    return key and crypto.fromHex(key) or nil
end

function keys.remember(address, public)
    local all = pins()
    all[address] = crypto.toHex(public)
    util.writeTable(KNOWN, all)
end

function keys.forgetKnown(address)
    local all = pins()
    all[address] = nil
    util.writeTable(KNOWN, all)
end

function keys.knownList()
    local out = {}
    for address, key in pairs(pins()) do
        out[#out + 1] = { address = address, fingerprint = crypto.fingerprint(crypto.fromHex(key)) }
    end
    table.sort(out, function(a, b) return a.address < b.address end)
    return out
end

return keys
