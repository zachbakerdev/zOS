-- Builds a real release and puts it through the real update library, on a fake GitHub.
-- Run from the repository root: luajit tests/test_release.lua
package.path = "tests/?.lua;" .. package.path

local sim = require("sim")

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
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local OUT = os.tmpname()
os.remove(OUT)
local built = os.execute("python3 tools/make_update.py -o '" .. OUT .. "' > /dev/null")
assert(built == true or built == 0, "the build failed")

local VERSION = readHost("src/.zos/lib/system.lua"):match('VERSION = "([^"]+)"')
local RELEASES = "https://github.com/zachbakerdev/zOS/releases/"

local site = {}
local function publish(name)
  local text = assert(readHost(OUT .. "/" .. name), name)
  site[RELEASES .. "latest/download/" .. name:match("[^/]+$")] = text
  site[RELEASES .. "download/v" .. VERSION .. "/" .. name:match("[^/]+$")] = text
end
publish("zos.zi")
publish("zos-update.manifest")
publish("zos-apps.manifest")

local ids = {}
local p = io.popen("ls apps/*/app.manifest")
for line in p:lines() do
  local id = line:match("^apps/(.-)/")
  ids[#ids + 1] = id
  publish("apps/" .. id .. ".za")
end
p:close()

local c = sim.computer(1, { files = {} })
c.env.http = { get = function(url)
  local text = site[url]
  if not text then return nil, "Not Found" end
  return { readAll = function() return text end, close = function() end }
end }
c.env.sleep = function() end
local system = c.env.require("system")
local update = c.env.require("update")
local apps = c.env.require("apps")

local function call(fn, ...)
  local results
  local args = table.pack and table.pack(...) or { n = select("#", ...), ... }
  local unpack = table.unpack or unpack
  local thread = sim.spawn(c, function() results = { fn(unpack(args, 1, args.n)) } end)
  sim.run(function() return thread.done end, 600)
  return unpack(results, 1, 2)
end

-- The system ------------------------------------------------------------------------------------

system.VERSION = "0.0.1"
local info, err = call(update.check)
check("the system manifest reads: " .. tostring(err), info and info.version == VERSION)
local ok
if info then ok, err = call(update.download, info) end
check("the image downloads and stages: " .. tostring(err), ok)
check("the version is staged", update.stagedVersion() == VERSION)
check("the system is staged", c.files["etc/zos/update/new/boot.lua"] ~= nil)
check("/startup.lua is staged", c.files["etc/zos/update/startup.new"] ~= nil)
check("the image is minified", #c.files["etc/zos/update/new/boot.lua"] < 0.8 * #readHost("src/.zos/boot.lua"))
system.VERSION = VERSION

-- The apps --------------------------------------------------------------------------------------

local list
list, err = call(update.checkApps)
check("the apps manifest reads: " .. tostring(err), list and #list == #ids)
for _, entry in ipairs(list or {}) do
  local name = entry.id .. ": "
  check(name .. "is supported", entry.supported)
  local pkg, why = call(update.downloadApp, entry)
  check(name .. "downloads: " .. tostring(why), pkg)
  if pkg then
    check(name .. "manifest survives", pkg.manifest.name == entry.name and pkg.manifest.version == entry.version)
    check(name .. "is minified", not pkg.files["main.lua"]:find("\n--", 1, true))
    check(name .. "manifest is minified", not pkg.files["app.manifest"]:find("\n", 1, true))
    if not apps.PROTECTED[entry.id] then
      local app, reason = call(apps.install, pkg)
      check(name .. "installs: " .. tostring(reason), app)
    end
  end
end

-- The installer ---------------------------------------------------------------------------------

local installer = readHost(OUT .. "/install.lua")
check("the installer is minified", #installer < 0.7 * #readHost("install.lua"))
check("the installer compiles", (loadstring or load)(installer))

os.execute("rm -rf '" .. OUT .. "'")

if failed > 0 then
  print(("release: %d passed, %d FAILED"):format(passed, failed))
  os.exit(1)
end
print(("release: all %d passed"):format(passed))
