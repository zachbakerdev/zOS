-- Tests of how src/ survives crashes, full disks and bad networks, using the real files.
-- Run from the repository root: luajit tests/test_recovery.lua (or lua5.2)
package.path = "tests/?.lua;" .. package.path
if not bit32 then require("cc_shim") end
local unpack = table.unpack or unpack
local ROOT = "src/.zos/"

local failed, passed = 0, 0
local function check(name, ok)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name)
  end
end

local function readHost(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

local function serialize(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  local out = {}
  for k, x in pairs(v) do out[#out + 1] = "[" .. serialize(k) .. "]=" .. serialize(x) end
  return "{" .. table.concat(out, ",") .. "}"
end

local function norm(p) return (p:gsub("^/+", "")) end

-- A computer: a table of files, and the globals the libraries use. `c.limit` cuts writes short.
local function computer(files)
  local c = { files = files or {}, log = {}, urls = {}, reboots = 0 }
  local dirs = {}
  local fs = {}
  function fs.exists(p)
    p = norm(p)
    if c.files[p] or dirs[p] then return true end
    for k in pairs(c.files) do if k:sub(1, #p + 1) == p .. "/" then return true end end
    return false
  end
  function fs.isDir(p) return fs.exists(p) and not c.files[norm(p)] end
  function fs.getDir(p) return norm(p):match("^(.*)/[^/]*$") or "" end
  function fs.getName(p) return norm(p):match("[^/]*$") end
  function fs.combine(a, b) return norm(a .. "/" .. b) end
  function fs.getFreeSpace() return 1000000 end
  function fs.getSize(p) return #c.files[norm(p)] end
  function fs.makeDir(p) dirs[norm(p)] = true end
  function fs.isReadOnly() return false end
  function fs.list(p)
    p = norm(p)
    local seen, names = {}, {}
    for _, set in ipairs({ c.files, dirs }) do
      for k in pairs(set) do
        local name = k:sub(1, #p + 1) == p .. "/" and k:sub(#p + 2):match("^[^/]+")
        if name and not seen[name] then seen[name] = true names[#names + 1] = name end
      end
    end
    return names
  end
  function fs.delete(p)
    p = norm(p)
    for _, set in ipairs({ c.files, dirs }) do
      for k in pairs(set) do
        if k == p or k:sub(1, #p + 1) == p .. "/" then set[k] = nil end
      end
    end
  end
  function fs.move(a, b)
    a, b = norm(a), norm(b)
    assert(fs.exists(a), "move of a missing file: " .. a)
    assert(not fs.exists(b), "move onto a file: " .. b)
    for _, set in ipairs({ c.files, dirs }) do
      local found = {}
      for k, v in pairs(set) do
        if k == a or k:sub(1, #a + 1) == a .. "/" then found[#found + 1] = { k, v } end
      end
      for _, e in ipairs(found) do
        set[e[1]] = nil
        set[b .. e[1]:sub(#a + 1)] = e[2]
      end
    end
  end
  function fs.open(p, mode)
    p = norm(p)
    if mode:sub(1, 1) == "r" then
      if not c.files[p] then return nil, "no file" end
      local text = c.files[p]
      return { readAll = function() return text end, close = function() end }
    end
    local buf = {}
    return {
      write = function(s) buf[#buf + 1] = s end,
      close = function()
        local text = table.concat(buf)
        if c.limit and c.limit(p) then text = text:sub(1, 8) end
        c.files[p] = text
      end,
    }
  end

  local clock = 1700000000000
  local env = setmetatable({}, { __index = _G })
  env._G = env
  env.fs = fs
  env.bit32 = bit32
  env.os = {
    epoch = function() clock = clock + 1 return clock end,
    getComputerID = function() return 1 end, getComputerLabel = function() return nil end,
    queueEvent = function() end,
    clock = function() return 0 end, date = os.date, time = os.time, startTimer = function() return 1 end,
    pullEventRaw = function() return "timer", 1 end, pullEvent = function() return "timer", 1 end,
    reboot = function() c.reboots = c.reboots + 1 error("rebooted", 0) end,
  }
  env.textutils = {
    serialize = serialize,
    unserialize = function(s)
      local fn = load("return " .. s, "=data", "t", {})
      return fn and fn()
    end,
    urlEncode = function(s) return s end,
  }
  env.term = setmetatable({}, { __index = function() return function() return 51, 19 end end })
  env.colors = setmetatable({}, { __index = function() return 1 end })
  env.keys = { backspace = 14 }
  env.http = {
    get = function(url)
      local text = c.urls[url]
      if not text then return nil, "404" end
      return { readAll = function() return text end, close = function() end }
    end,
  }
  env.sleep = function() c.slept = (c.slept or 0) + 1 end
  env.print = function() end
  env.settings = { set = function() end, save = function() end, get = function() end }
  env.parallel = { waitForAny = function(a) a() end }

  local loaded = {}
  function env.require(name)
    if loaded[name] then return loaded[name] end
    local path = ROOT .. "lib/" .. name .. ".lua"
    local value = assert(load(readHost(path), "@" .. path, "t", env))(name)
    loaded[name] = value == nil and true or value
    return loaded[name]
  end
  c.env = env
  return c
end

-- Keys -------------------------------------------------------------------------------------------

local KEY = "etc/zos/keys/ann"

local function withUser()
  local c = computer()
  local auth = c.env.require("auth")
  assert(auth.create("ann", "password1", true))
  local session = auth.session("ann", "password1")
  return c, auth, c.env.require("keys"), session.publicKey
end

do -- a crash after the key changed, before the new password was saved
  local c, auth, keys, public = withUser()
  assert(keys.rewrap("ann", "password1", "password2"))
  local session = auth.session("ann", "password1")
  check("crash before saving: old password opens the key", session.publicKey == public and not session.keyReplaced)
  check("crash before saving: the abandoned lock is gone", not keys.unlock("ann", "password2"))
  check("crash before saving: no damaged key", c.files[KEY] ~= nil)
end

do -- a crash after the new password was saved, before the old lock went
  local _, auth, keys, public = withUser()
  assert(keys.rewrap("ann", "password1", "password2"))
  local session = auth.session("ann", "password2")
  check("crash after saving: new password opens the key", session.publicKey == public and not session.keyReplaced)
  check("crash after saving: the old lock is gone", not keys.unlock("ann", "password1"))
end

do -- the normal path
  local _, auth, keys, public = withUser()
  assert(auth.changePassword("ann", "password1", "password2"))
  check("change: new password works", auth.verify("ann", "password2"))
  check("change: key kept", auth.session("ann", "password2").publicKey == public)
  check("change: old lock gone", not keys.unlock("ann", "password1"))
end

do -- the users file can't be written
  local c, auth, keys, public = withUser()
  c.limit = function(p) return p == "etc/zos/users.db.new" end
  local ok = auth.changePassword("ann", "password1", "password2")
  c.limit = nil
  check("failed save: reported", not ok)
  check("failed save: old password still logs in", auth.verify("ann", "password1"))
  check("failed save: key opens", auth.session("ann", "password1").publicKey == public)
  check("failed save: new password doesn't", not keys.unlock("ann", "password2"))
end

do -- the key file can't be written
  local c, auth, _, public = withUser()
  c.limit = function(p) return p == KEY .. ".new" end
  local ok = auth.changePassword("ann", "password1", "password2")
  c.limit = nil
  check("full disk: reported", not ok)
  check("full disk: key untouched", auth.session("ann", "password1").publicKey == public)
  check("full disk: no temp file left", c.files[KEY .. ".new"] == nil)
end

do -- a key that really can't be opened
  local c, auth, _, public = withUser()
  c.files[KEY] = "{ broken"
  local session = auth.session("ann", "password1")
  check("damaged: login still works", session.secretKey ~= nil and session.publicKey ~= public)
  check("damaged: says where it went", c.files[norm(session.keyReplaced)] == "{ broken")
end

do -- a save that stopped between deleting the old file and renaming the new one
  local c, auth, _, public = withUser()
  c.files[KEY .. ".new"], c.files[KEY] = c.files[KEY], nil
  check("half-saved key isn't replaced", auth.session("ann", "password1").publicKey == public)
end

-- Updates ----------------------------------------------------------------------------------------

local DIR = "etc/zos/update/"
local RELEASE = "https://github.com/zachbakerdev/zOS/releases/"

local function imageText(extra)
  local files = { ["/.zos/boot.lua"] = "-- new", ["/.zos/lib/x.lua"] = "-- lib", ["/startup.lua"] = "-- startup" }
  for k, v in pairs(extra or {}) do files[k] = v end
  files["zi:metadata"] = { version = 1 }
  return serialize(files)
end

local function staged(c)
  local update, crypto = c.env.require("update"), c.env.require("crypto")
  local text = imageText()
  c.urls[RELEASE .. "download/v9.0.0/zos.zi"] = text
  return update, { version = "9.0.0", size = #text, sha256 = crypto.sha256(text) }
end

do
  local c = computer()
  local update, info = staged(c)
  c.limit = function(p) return p == DIR .. "startup.new" end
  local ok = update.download(info)
  check("short startup write: refused", not ok)
  check("short startup write: nothing staged", not c.files[DIR .. "ready"] and not c.env.fs.exists(DIR .. "new"))
  c.limit = nil
  check("clean stage works", update.download(info) and c.files[DIR .. "ready"] == "9.0.0")
end

local function trial(c)
  c.files[DIR .. "trial"] = "9.0.0"
  c.files[DIR .. "old/boot.lua"] = "-- old"
  c.files[DIR .. "startup.new"] = "-- new startup"
  c.files["startup.lua"] = "-- old startup"
end

do
  local c = computer()
  local update = c.env.require("update")
  trial(c)
  update.finish()
  check("offline finish: accepted", not c.files[DIR .. "trial"] and not c.env.fs.exists(DIR .. "old"))
  check("offline finish: startup replaced", c.files["startup.lua"] == "-- new startup")
  check("offline finish: apps still due", c.files[DIR .. "apps-due"] == "9.0.0")

  c.urls[RELEASE .. "latest/download/zos-apps.manifest"] =
    "zos-apps 1\nrelease=9.0.0\napp=terminal\t2.0.0\t5\t" .. string.rep("0", 64) .. "\t\tTerminal\tShell\nend\n"
  c.env.require("system").config = function() return { autoUpdate = false } end
  update.tick()
  check("a failed app stays due", c.files[DIR .. "apps-due"] ~= nil)
  c.urls[RELEASE .. "latest/download/zos-apps.manifest"] = "zos-apps 1\nrelease=9.0.0\nend\n"
  update.tick()
  check("retry clears the marker", c.files[DIR .. "apps-due"] == nil)
end

-- /startup.lua -----------------------------------------------------------------------------------

local function boot(c, bootText)
  c.files[".zos/boot.lua"] = bootText
  local fn = assert(load(readHost("src/startup.lua"), "@startup.lua", "t", c.env))
  pcall(fn)
end

do -- a normal swap
  local c = computer()
  c.files[DIR .. "ready"] = "9.0.0"
  c.files[DIR .. "new/boot.lua"] = "_G.RAN = 'new'"
  c.files[".zos/apps/a/main.lua"] = "-- app"
  c.files[".zos/marker"] = "old system"
  local fn = assert(load(readHost("src/startup.lua"), "@startup.lua", "t", c.env))
  c.files[".zos/boot.lua"] = "-- old"
  pcall(fn)
  -- boot.lua returning counts as a failed trial, so the old system comes back, apps and all.
  check("swap: new system ran", c.env.RAN == "new")
  check("swap: old system restored", c.files[".zos/marker"] == "old system")
  check("swap: apps carried over", c.files[".zos/apps/a/main.lua"] == "-- app")
end

do -- a crash between the two renames
  local c = computer()
  c.files[DIR .. "ready"] = "9.0.0"
  c.files[DIR .. "new/boot.lua"] = "while true do error('stop') end"
  c.files[DIR .. "old/marker"] = "old system"
  c.files[DIR .. "old/boot.lua"] = "-- old"
  local fn = assert(load(readHost("src/startup.lua"), "@startup.lua", "t", c.env))
  pcall(fn)
  -- The new boot failed during its trial, so this is a rollback to the real old system.
  check("interrupted swap: old system survives", c.files[".zos/marker"] == "old system")
end

do -- an update that didn't finish, then another one staged
  local c = computer()
  c.files[".zos/marker"] = "current"
  c.files[".zos/apps/a/main.lua"] = "-- app"
  c.files[DIR .. "old/marker"] = "stale"
  c.files[DIR .. "trial"] = "8.0.0"
  c.files[DIR .. "ready"] = "9.0.0"
  c.files[DIR .. "new/marker"] = "new"
  c.files[DIR .. "new/boot.lua"] = "_G.COUNT = 1"
  local fn = assert(load(readHost("src/startup.lua"), "@startup.lua", "t", c.env))
  pcall(fn)
  -- boot.lua returning counts as a failed trial, which rolls back to what was running: "current".
  check("stale old: next update really ran", c.env.COUNT == 1)
  check("stale old: rollback goes to the running version", c.files[".zos/marker"] == "current")
  check("stale old: version recorded as failed", c.files[DIR .. "failed"] == "9.0.0")
end

-- /.zos/boot.lua ---------------------------------------------------------------------------------

do -- login.lua is missing, so every session crashes
  local c = computer()
  local stub = "return setmetatable({ count = function() return 1 end }, " ..
    "{ __index = function() return function() end end })"
  for _, name in ipairs({ "apps", "services", "update", "auth", "crypto", "ui", "net", "system" }) do
    c.files[".zos/lib/" .. name .. ".lua"] = stub
  end
  c.env.shell = nil
  local fn = assert(load(readHost(ROOT .. "boot.lua"), "@boot.lua", "t", c.env))
  local ok, err = pcall(fn)
  check("crash loop: stops", not ok and tostring(err):match("keeps crashing") ~= nil)
  check("crash loop: yields between tries", c.slept == 4)
end

-- Certificates -----------------------------------------------------------------------------------

do
  local c = computer()
  local crypto, trust = c.env.require("crypto"), c.env.require("trust")
  crypto.addEntropy(string.rep("seed", 16))
  local peer = string.rep("ab", 32)
  local good, goodPublic = crypto.signingKeypair()
  local certs = {}
  for i = 1, 5 do
    local seed, public = crypto.signingKeypair()
    certs[i] = trust.issue(seed, public, "old" .. i, 2, peer, -1000) -- expired
  end
  certs[6] = trust.issue(good, goodPublic, "good.tld", 2, peer, 100000000)
  trust.addRoot(crypto.toHex(goodPublic), "root", 3)
  for i = 1, 5 do trust.addRoot(certs[i].root, "expired", 3) end
  local names = trust.namesFor(certs, 2, peer)
  check("a good certificate behind expired ones counts", names[crypto.toHex(goodPublic)] == "good.tld")
  check("a certificate for another computer doesn't", next(trust.namesFor(certs, 3, peer)) == nil)
end

-- .za images ------------------------------------------------------------------------------------

-- An image's files can only land in its own app folder. What its code does once it runs is
-- another matter: see Security in specs/formats/ZA_FORMAT.md.

local function appImage(id, extra)
  local contents = {
    ["za:metadata"] = { version = 1, id = id },
    ["app.manifest"] = '{ name = "Notes", version = "1.0" }',
    ["main.lua"] = "return 1",
  }
  for path, data in pairs(extra or {}) do contents[path] = data end
  return serialize(contents)
end

do
  local apps = computer().env.require("apps")

  check("a normal image parses", apps.parse(appImage("notes", { ["lib/store.lua"] = "return {}" })))

  local badPaths = {
    "../other/x.lua", "../../boot.lua", "../../lib/util.lua", "../../../startup.lua",
    "lib/../main.lua", "lib/../../../boot.lua", "a/..", "..", ".", "./main.lua",
    "/main.lua", "/.zos/boot.lua", "/startup.lua", "/etc/zos/users",
    ".hidden", "lib/.hidden", ".zos/boot.lua", "a//b", "a/", "/", "",
    "lib\\main.lua", "..\\boot.lua", "C:/boot.lua", "a b", "a\nb", string.rep("a", 129),
  }
  for _, path in ipairs(badPaths) do
    local pkg, err = apps.parse(appImage("notes", { [path] = "return 1" }))
    check("za path refused: " .. path, pkg == nil and tostring(err):find("bad file name", 1, true) ~= nil)
  end
  check("za path refused: a number", apps.parse(appImage("notes", { [1] = "return 1" })) == nil)
  check("za file refused: not a string", apps.parse(appImage("notes", { ["data"] = { "x" } })) == nil)

  local badIds = {
    "..", ".", "../lib", "../../etc", "a/b", "/lib", "a.b", ".hidden", "", "zos", "Notes", "a b",
    string.rep("a", 33), 7,
  }
  for _, id in ipairs(badIds) do
    local pkg, err = apps.parse(appImage(id))
    check("za id refused: " .. tostring(id), pkg == nil and tostring(err):find("invalid id", 1, true) ~= nil)
  end

  check("a file can't also be a folder", apps.parse(appImage("notes", { lib = "x", ["lib/a"] = "y" })) == nil)
end

do -- installing writes only to the app's folder
  local system = {
    [".zos/boot.lua"] = "-- boot", [".zos/lib/util.lua"] = "-- util", [".zos/sys/login.lua"] = "-- login",
    [".zos/apps/other/main.lua"] = "-- other", [".zos/apps/notes/old.lua"] = "-- old version",
    ["startup.lua"] = "-- startup", ["etc/zos/users"] = "{}",
  }
  local c = computer({})
  for path, data in pairs(system) do c.files[path] = data end
  local apps = c.env.require("apps")

  local pkg = assert(apps.parse(appImage("notes", { ["lib/store.lua"] = "return {}" })))
  check("za install works", apps.install(pkg))

  for path, data in pairs(system) do
    if path ~= ".zos/apps/notes/old.lua" then
      check("za install leaves " .. path .. " alone", c.files[path] == data)
    end
  end
  for path in pairs(c.files) do
    check("za install wrote nothing else: " .. path,
      system[path] ~= nil or path:sub(1, #".zos/apps/notes/") == ".zos/apps/notes/")
  end
  check("za install put the files in place", c.files[".zos/apps/notes/lib/store.lua"] == "return {}")
  check("za install replaced the old version", c.files[".zos/apps/notes/old.lua"] == nil)
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
