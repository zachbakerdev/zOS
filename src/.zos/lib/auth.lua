-- User accounts, logins and the login lock.

local crypto = require("crypto")
local keys = require("keys")
local system = require("system")
local util = require("util")

local auth = { MIN_PASSWORD = 8, MAX_NAME = 16 }

local USERS = system.DATA .. "/users.db"
local LOCKOUT = system.DATA .. "/LOCKOUT"

local FREE_ATTEMPTS = 3
local FIRST_LOCK, MAX_LOCK = 5000, 300000

local function users()
    return util.readTable(USERS) or {}
end

local function save(all)
    return util.writeTable(USERS, all)
end

local function hash(password, salt)
    return crypto.toHex(crypto.passwordKey(password, salt))
end

-- nil, or why this can't be a user name. It's also a folder name, so it has to be plain.
function auth.badName(name)
    if type(name) ~= "string" or #name < 1 or #name > auth.MAX_NAME or not name:match("^%l[%l%d_%-]*$") then
        return "Names are 1-" .. auth.MAX_NAME .. " lowercase letters, digits, - or _, starting with a letter."
    end
end

function auth.badPassword(password)
    if type(password) ~= "string" or #password < auth.MIN_PASSWORD then
        return "Passwords need at least " .. auth.MIN_PASSWORD .. " characters."
    end
end

function auth.count()
    local n = 0
    for _ in pairs(users()) do n = n + 1 end
    return n
end

function auth.exists(name)
    return users()[name] ~= nil
end

function auth.isAdmin(name)
    local user = users()[name]
    return user ~= nil and user.admin == true
end

-- Every account as { name, admin }, sorted by name.
function auth.list()
    local out = {}
    for name, user in pairs(users()) do out[#out + 1] = { name = name, admin = user.admin == true } end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local function record(password, admin)
    local salt = crypto.randomBytes(16)
    return { salt = crypto.toHex(salt), hash = hash(password, salt), admin = admin == true }
end

function auth.create(name, password, admin)
    local bad = auth.badName(name) or auth.badPassword(password)
    if bad then return nil, bad end
    local all = users()
    if all[name] then return nil, "That name is taken." end
    crypto.addEntropy(password)
    all[name] = record(password, admin)
    save(all)
    fs.makeDir("/home/" .. name)
    return true
end

-- Whether this is the user's password. Takes the same time for a user who doesn't exist.
function auth.verify(name, password)
    local user = users()[name]
    local salt = user and crypto.fromHex(user.salt) or string.rep("\0", 16)
    local result = hash(password, salt)
    return user ~= nil and result == user.hash
end

local function lockState()
    return util.readTable(LOCKOUT) or { failures = 0, untilTime = 0 }
end

-- Milliseconds until login opens again, or 0.
function auth.lockRemaining()
    return math.max(0, lockState().untilTime - os.epoch("utc"))
end

local function loginFailed()
    local state = lockState()
    state.failures = state.failures + 1
    if state.failures >= FREE_ATTEMPTS then
        local wait = math.min(MAX_LOCK, FIRST_LOCK * 2 ^ (state.failures - FREE_ATTEMPTS))
        state.untilTime = os.epoch("utc") + wait
    end
    util.writeTable(LOCKOUT, state)
end

-- Check a login against the lock. Returns true, or nil and a reason.
function auth.attempt(name, password)
    local left = auth.lockRemaining()
    if left > 0 then
        return nil, ("Login is locked for %d more seconds."):format(math.ceil(left / 1000))
    end
    if not auth.verify(name, password) then
        loginFailed()
        system.log("Failed login for " .. tostring(name))
        return nil, "Wrong name or password."
    end
    fs.delete(LOCKOUT)
    return true
end

-- The session for a user whose password has been checked, creating their key if they have none.
-- A key that can't be opened is kept, not overwritten, and `keyReplaced` says where it went.
function auth.session(name, password)
    crypto.addEntropy(password)
    local secret, public, replaced
    if keys.hasKey(name) then
        local ok, first, second = pcall(keys.unlock, name, password)
        if ok then secret, public = first, second end
        if not secret then
            replaced = keys.setAside(name)
            system.log("The key of " .. name .. " couldn't be opened, and was moved to " .. replaced)
        end
    end
    if not secret then secret, public = keys.create(name, password) end
    fs.makeDir("/home/" .. name)
    return {
        user = name,
        admin = auth.isAdmin(name),
        since = os.epoch("utc"),
        secretKey = secret,
        publicKey = public,
        keyReplaced = replaced,
    }
end

-- Change your own password, which keeps your key.
function auth.changePassword(name, old, new)
    local bad = auth.badPassword(new)
    if bad then return nil, bad end
    if not auth.verify(name, old) then return nil, "That isn't your current password." end
    local hasKey = keys.hasKey(name)
    if hasKey then
        local ok, why = keys.rewrap(name, old, new)
        if not ok then return nil, why or "Your key couldn't be unlocked." end
    end
    local all = users()
    all[name] = record(new, all[name].admin)
    local saved, why = save(all)
    if not saved then
        if hasKey then keys.unlock(name, old) end -- which puts the old lock back
        return nil, "The new password couldn't be saved: " .. tostring(why)
    end
    if hasKey then keys.settle(name) end
    return true
end

-- An administrator's reset can't open the old key, so the user gets a new one at their next login.
function auth.resetPassword(name, new)
    local bad = auth.badPassword(new)
    if bad then return nil, bad end
    local all = users()
    if not all[name] then return nil, "There's no such user." end
    all[name] = record(new, all[name].admin)
    save(all)
    keys.forget(name)
    return true
end

function auth.remove(name)
    local all = users()
    if not all[name] then return nil, "There's no such user." end
    if all[name].admin then
        local admins = 0
        for _, user in pairs(all) do
            if user.admin then admins = admins + 1 end
        end
        if admins == 1 then return nil, "This is the last administrator." end
    end
    all[name] = nil
    save(all)
    keys.forget(name)
    return true
end

-- Delete every account and the login lock, for a clean reinstall.
function auth.reset()
    fs.delete(USERS)
    fs.delete(LOCKOUT)
end

return auth
