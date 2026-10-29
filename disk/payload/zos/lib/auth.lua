-- User accounts for zOS. Passwords are stored as salted, iterated SHA-256 hashes.
-- Loaded through the zOS module loader, which is passed in as `...`.

local import = ...
local sha256 = import("sha256")

local auth = {}

local DB = "/etc/zos/users.db"
local LOCKOUT = "/etc/zos/lockout"
local ITERATIONS = 200
local MIN_PASSWORD = 4

local function readTable(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local data = f.readAll()
  f.close()
  return textutils.unserialise(data)
end

local function writeTable(path, value)
  fs.makeDir(fs.getDir(path))
  local f = fs.open(path, "w")
  f.write(textutils.serialise(value))
  f.close()
end

local function load() return readTable(DB) or {} end
local function save(db) writeTable(DB, db) end

local function newSalt()
  math.randomseed(os.epoch("utc") + os.getComputerID() * 7919 + math.random(0, 65535))
  local bytes = {}
  for i = 1, 16 do bytes[i] = string.format("%02x", math.random(0, 255)) end
  return table.concat(bytes)
end

local function derive(password, salt, iterations)
  local h = sha256(salt .. password)
  for _ = 2, iterations do
    h = sha256(h .. salt .. password)
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

function auth.hasUsers() return next(load()) ~= nil end
function auth.exists(name) return load()[name] ~= nil end

function auth.isAdmin(name)
  local user = load()[name]
  return user ~= nil and user.admin == true
end

-- Returns a sorted list of { name = ..., admin = ... }.
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
  return auth.setPassword(name, password)
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
  return true
end

-- Wipe every account (used by the installer for a clean install).
function auth.reset()
  if fs.exists(DB) then fs.delete(DB) end
  if fs.exists(LOCKOUT) then fs.delete(LOCKOUT) end
end

-- Failed-login throttling. Stored on disk so rebooting doesn't reset it.
function auth.lockRemaining()
  local state = readTable(LOCKOUT)
  if not state or not state.untilMs then return 0 end
  local left = (state.untilMs - os.epoch("utc")) / 1000
  return left > 0 and math.ceil(left) or 0
end

function auth.recordFailure()
  local state = readTable(LOCKOUT) or { failures = 0 }
  state.failures = state.failures + 1
  if state.failures >= 3 then
    -- 5s, 10s, 20s, ... capped at 5 minutes
    state.untilMs = os.epoch("utc") + math.min(300, 5 * 2 ^ (state.failures - 3)) * 1000
  end
  writeTable(LOCKOUT, state)
end

function auth.recordSuccess()
  if fs.exists(LOCKOUT) then fs.delete(LOCKOUT) end
end

return auth
