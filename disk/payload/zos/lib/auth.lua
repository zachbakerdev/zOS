local crypto = require("crypto")
local keys = require("keys")
local util = require("util")

local auth = {}

local DB = "/etc/zos/users.db"
local LOCKOUT = "/etc/zos/LOCKOUT"
local ITERATIONS = 200
local MIN_PASSWORD = 8

local function load()
    return util.readTable(DB) or {}
end

local function save(db)
    return util.writeTable(DB, db)
end

local function newSalt()
    return crypto.toHex(crypto.randomBytes(16))
end

local function derive(password, salt, iterations)
    local h = crypto.sha256(salt .. password)
    for _ = 2, iterations do
        h = crypto.sha256(h .. salt .. password)
    end
    return h
end

function auth.validName(name)
    if type(name) ~= "string" or not name:match("^[%w_%-]+$") or #name > 16 then
        return false, "Usernames are 1-16 letters, digits, - or _."
    end
    return true
end

function auth.checkPassword(password)
    if type(password) ~= "string" or #password < MIN_PASSWORD then
        return false, "Passwords must be at least " .. MIN_PASSWORD .. " characters."
    end
    return true
end

function auth.hasUsers()
    return next(load()) ~= nil
end

function auth.exists(name)
    return load()[name] ~= nil
end

function auth.isAdmin(name)
    local user = load()[name]
    return user ~= nil and user.admin == true
end

function auth.list()
    local out = {}
    for name, user in pairs(load()) do out[#out + 1] = { name = name, admin = user.admin == true } end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function auth.verify(name, password)
    local user = type(name) == "string" and load()[name]
    if not user or type(password) ~= "string" then return false end
    return derive(password, user.salt, user.iterations or ITERATIONS) == user.hash
end

function auth.setPassword(name, password)
    local ok, err = auth.checkPassword(password)
    if not ok then return false, err end
    local db = load()
    if not db[name] then return false, "No such user: " .. tostring(name) end
    local salt = newSalt()
    db[name].salt, db[name].iterations = salt, ITERATIONS
    db[name].hash = derive(password, salt, ITERATIONS)
    save(db)
    return true
end

function auth.create(name, password, admin)
    local ok, err = auth.validName(name)
    if not ok then return false, err end
    ok, err = auth.checkPassword(password)
    if not ok then return false, err end
    local db = load()
    if db[name] then return false, "User '" .. name .. "' already exists." end
    db[name] = { admin = admin == true }
    save(db)
    ok, err = auth.setPassword(name, password)
    if not ok then return false, err end
    -- Every account gets its encryption keys up front, sealed with its password.
    crypto.addEntropy(password)
    keys.create(name, password)
    return true
end

function auth.remove(name)
    local db = load()
    if not db[name] then return false, "No such user: " .. tostring(name) end
    if db[name].admin then
        local admins = 0
        for _, user in pairs(db) do if user.admin then admins = admins + 1 end end
        if admins <= 1 then return false, "Can't remove the last administrator." end
    end
    db[name] = nil
    save(db)
    keys.forget(name)
    return true
end

function auth.reset()
    if fs.exists(DB) then fs.delete(DB) end
    if fs.exists(LOCKOUT) then fs.delete(LOCKOUT) end
end

function auth.lockRemaining()
    local state = util.readTable(LOCKOUT)
    if not state or not state.untilMs then return 0 end
    local left = (state.untilMs - os.epoch("utc")) / 1000
    return left > 0 and math.ceil(left) or 0
end

function auth.recordFailure()
    local state = util.readTable(LOCKOUT) or { failures = 0 }
    state.failures = state.failures + 1
    if state.failures >= 3 then
        state.untilMs = os.epoch("utc") + math.min(300, 5 * 2 ^ (state.failures - 3)) * 1000
    end
    util.writeTable(LOCKOUT, state)
end

function auth.recordSuccess()
    if fs.exists(LOCKOUT) then fs.delete(LOCKOUT) end
end

return auth