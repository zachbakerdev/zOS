-- Tests of lib/update.lua and the swap in /startup.lua, using the real files and a fake GitHub.
-- Run from the repository root: luajit tests/test_update.lua
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

local CURRENT, NEXT = "2.0.0", "9.0.0"
local MANIFEST = "https://github.com/zachbakerdev/zOS/releases/latest/download/zos-update.manifest"
local IMAGE = "https://github.com/zachbakerdev/zOS/releases/download/v" .. NEXT .. "/zos.zi"

local function readFile(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end
local STARTUP = readFile("src/startup.lua")

local function appText(c, id, version, minZos)
  return c.env.textutils.serialize({
    ["za:metadata"] = { version = 1, id = id },
    ["main.lua"] = "print('hi')",
    ["app.manifest"] = '{ name = "' .. id .. '", version = "' .. version .. '"' ..
      (minZos and (', minZos = "' .. minZos .. '"') or "") .. ' }',
  })
end

-- A system image. Overrides replace entries, and false removes one.
local function imageText(c, overrides)
  local image = {
    ["zi:metadata"] = { version = 1 },
    ["/.zos/boot.lua"] = "-- new boot", ["/.zos/lib/system.lua"] = "-- new lib", ["/startup.lua"] = STARTUP,
  }
  for k, v in pairs(overrides or {}) do image[k] = v or nil end
  return c.env.textutils.serialize(image)
end

local APPS_MANIFEST = "https://github.com/zachbakerdev/zOS/releases/latest/download/zos-apps.manifest"
local function appUrl(id) return "https://github.com/zachbakerdev/zOS/releases/download/v" .. NEXT .. "/" .. id .. ".za" end

-- Publish these apps (id -> version, or { version, minZos }) as a list and .za files.
local function publishApps(c, list)
  local ids = {}
  for id in pairs(list) do ids[#ids + 1] = id end
  table.sort(ids)
  local lines = { "zos-apps 1", "release=" .. NEXT }
  for _, id in ipairs(ids) do
    local version, minZos = list[id], nil
    if type(version) == "table" then version, minZos = version[1], version[2] end
    local text = appText(c, id, version, minZos)
    c.site[appUrl(id)] = text
    lines[#lines + 1] = "app=" .. table.concat({ id, version, #text, c.crypto.sha256(text), minZos or "",
      "App " .. id, "About " .. id }, "\t")
  end
  c.site[APPS_MANIFEST] = table.concat(lines, "\n") .. "\nend\n"
end

-- A computer that believes it's running CURRENT, and a fake release.
local function setup(files)
  for _, c in pairs(sim.computers) do sim.powerOff(c) end
  local c = sim.computer(1, { files = files or {} })
  local crypto = c.env.require("crypto")
  local update = c.env.require("update")
  c.env.require("system").VERSION = CURRENT
  c.env.sleep = function() end

  c.site = {}
  c.fetched = {}
  c.manifest = function(text, version)
    return "zos-update 1\nversion=" .. (version or NEXT) .. "\nsize=" .. #text ..
      "\nsha256=" .. crypto.sha256(text) .. "\nend\n"
  end
  c.publish = function(text, version)
    c.site[MANIFEST], c.site[IMAGE] = c.manifest(text, version), text
  end
  c.env.http = { get = function(url)
    c.fetched[url] = (c.fetched[url] or 0) + 1
    local text = c.site[url]
    if not text then return nil, "Not Found" end
    return { readAll = function() return text end, close = function() end }
  end }
  c.update, c.crypto = update, crypto
  return c
end

-- Run fn on the computer and return what it returned.
local function call(c, fn, ...)
  local results
  local args = table.pack(...)
  local thread = sim.spawn(c, function() results = table.pack(fn(table.unpack(args, 1, args.n))) end)
  sim.run(function() return thread.done end, 600)
  return table.unpack(results, 1, results.n)
end

-- Run the real /startup.lua. A power cut stops it dead before the crashAt-th change to the disk,
-- without any of its pcalls seeing an error. Returns "booted", "reboot" or "crash".
local function boot(c, crashAt)
  local files, ops = c.files, 0
  local realFs = c.env.fs
  local function step(name)
    return function(...)
      ops = ops + 1
      if ops == crashAt then coroutine.yield("crash") end
      return realFs[name](...)
    end
  end
  local env = setmetatable({
    fs = setmetatable({ move = step("move"), delete = step("delete"), copy = step("copy") }, { __index = realFs }),
    os = setmetatable({
      reboot = function() coroutine.yield("reboot") end,
      pullEventRaw = function() error("waited for an event") end,
    }, { __index = c.env.os }),
    load = function(text, name, mode, fenv)
      if name ~= "@/.zos/boot.lua" then return load(text, name, mode, fenv) end
      return function()
        if text:find("broken", 1, true) then error("boot crashed", 0) end
        coroutine.yield("booted")
      end
    end,
    shell = {},
  }, { __index = c.env })
  local fn = assert(load(files["startup.lua"], "=startup", "t", env))
  local co = coroutine.create(fn)
  local ok, result = coroutine.resume(co)
  if not ok then error(result, 0) end
  return result, ops
end

local function installed(extra)
  local files = { [".zos/boot.lua"] = "-- old boot", [".zos/lib/system.lua"] = "-- old lib", ["startup.lua"] = STARTUP }
  for k, v in pairs(extra or {}) do files[k] = v end
  return files
end

-- Finding updates ----------------------------------------------------------------

do
  local c = setup(installed())
  local bundle = imageText(c)
  c.publish(bundle)
  local info = call(c, c.update.check)
  check("finds a newer version", info and info.version == NEXT)

  c.publish(bundle, CURRENT)
  check("same version is up to date", call(c, c.update.check) == false)
  c.publish(bundle, "1.9.0")
  check("older version is up to date", call(c, c.update.check) == false)

  c.site[MANIFEST] = nil
  local none, err = call(c, c.update.check)
  check("reports a failed check", none == nil and err:find("Not Found", 1, true))

  c.env.http = nil
  none, err = call(c, c.update.check)
  check("reports no HTTP", none == nil and err:find("disabled", 1, true))
end

-- Refusing bad updates -----------------------------------------------------------

do
  local c = setup(installed())
  local bundle = imageText(c)

  check("only asks over HTTPS", c.update.RELEASES:sub(1, 8) == "https://")

  local info, err
  c.publish(bundle)
  for _, text in ipairs({ "", "<html>Not Found</html>", "zos-update 1\nversion=9.0.0\n", "{ version = '9.0.0' }",
    c.site[MANIFEST]:sub(1, -5) }) do
    c.site[MANIFEST] = text
    info = call(c, c.update.check)
    check("refuses junk as a manifest", info == nil)
  end
  check("still nothing on offer", c.update.stagedVersion() == nil)

  c.publish(bundle)
  info = call(c, c.update.check)
  c.site[IMAGE] = bundle:gsub("new boot", "bad boot")
  local ok
  ok, err = call(c, c.update.download, info)
  check("refuses a changed image", not ok and err:find("changed", 1, true))
  check("stores nothing when refused", not c.env.fs.exists("etc/zos/update/new"))
  c.site[IMAGE] = bundle .. " "
  check("refuses an image of the wrong size", not call(c, c.update.download, info))

  local function refused(name, text, wanted)
    c.publish(text)
    local i = call(c, c.update.check)
    local good, why = call(c, c.update.download, i)
    check(name, not good and why:find(wanted, 1, true))
    check(name .. " stores nothing", not c.env.fs.exists("etc/zos/update/new"))
  end
  c.publish(c.env.textutils.serialize({ ["zi:metadata"] = { version = 2 }, ["/.zos/boot.lua"] = "", ["/startup.lua"] = "" }))
  refused("refuses a future format", c.site[IMAGE], "newer version of zOS")
  refused("refuses an image without a boot file", imageText(c, { ["/.zos/boot.lua"] = false }), "complete system")
  refused("refuses an image without a startup file", imageText(c, { ["/startup.lua"] = false }), "complete system")
  refused("refuses path escapes", imageText(c, { ["/.zos/../etc/x"] = "" }), "bad file name")
  refused("refuses relative paths", imageText(c, { [".zos/x"] = "" }), "bad file name")
  refused("refuses a file used as a folder", imageText(c, { ["/.zos/lib"] = "" }), "both a file and a folder")
  refused("refuses code that doesn't compile", imageText(c, { ["/.zos/boot.lua"] = "if" }), "doesn't compile")

  c.files.freeSpace = 100
  refused("refuses when the disk is too full", imageText(c), "disk space")
  c.files.freeSpace = nil
end

do
  local c = setup(installed({ ["etc/zos/users.db"] = "accounts" }))
  c.publish(imageText(c, { ["/etc/zos/users.db"] = "taken", ["/.zos/apps/mine/main.lua"] = "-- from the image" }))
  check("stages an image with other files", call(c, c.update.download, call(c, c.update.check)))
  check("only stages the system", not c.env.fs.exists("etc/zos/update/new/etc") and c.files["etc/zos/users.db"] == "accounts")
  check("doesn't stage apps", not c.env.fs.exists("etc/zos/update/new/apps"))
end

-- Installing, keeping what must be kept -------------------------------------------

do
  local c = setup(installed({
    ["etc/zos/users.db"] = "accounts",
    [".zos/apps/mine/main.lua"] = "old", [".zos/apps/mine/app.manifest"] = '{ name = "mine", version = "1.0.0" }',
  }))
  c.publish(imageText(c))
  publishApps(c, { terminal = "2.0.0", mine = "2.0.0", other = "2.0.0" })
  call(c, c.update.tick)
  check("tick downloads by itself", c.fetched[IMAGE] == 1)
  check("waits for the next boot", c.update.stagedVersion() == NEXT)
  check("running system is untouched", c.files[".zos/boot.lua"] == "-- old boot")
  call(c, c.update.tick)
  check("skips what's already stored", c.fetched[IMAGE] == 1)

  check("boots", boot(c) == "booted")
  check("new system in place", c.files[".zos/boot.lua"] == "-- new boot")
  check("nothing left of the old system", c.files[".zos/lib/system.lua"] == "-- new lib")
  check("old version kept for now", c.env.fs.exists("etc/zos/update/old/boot.lua"))
  check("installed apps carried over", c.files[".zos/apps/mine/main.lua"] == "old")

  c.env.require("system").VERSION = NEXT
  call(c, c.update.finish)
  check("accounts kept", c.files["etc/zos/users.db"] == "accounts")
  check("installed app upgraded", c.files[".zos/apps/mine/main.lua"] == "print('hi')")
  check("built-in app installed", c.env.fs.exists(".zos/apps/terminal/main.lua"))
  check("doesn't install other apps", not c.env.fs.exists(".zos/apps/other"))
  check("cleans up", not c.env.fs.exists("etc/zos/update/new") and not c.env.fs.exists("etc/zos/update/old")
    and not c.env.fs.exists("etc/zos/update/trial"))
  check("app updates aren't left due", not c.env.fs.exists("etc/zos/update/apps-due"))
  check("logs it", c.files["etc/zos/system.log"]:find("Updated to zOS " .. NEXT, 1, true))
  check("next boot is normal", boot(c) == "booted" and c.files[".zos/boot.lua"] == "-- new boot")
end

do -- Offline when the update finishes: the apps catch up later.
  local c = setup(installed({ [".zos/apps/mine/main.lua"] = "old", [".zos/apps/mine/app.manifest"] = '{ name = "mine", version = "1.0.0" }' }))
  c.publish(imageText(c))
  call(c, c.update.tick)
  boot(c)
  c.env.require("system").VERSION = NEXT
  call(c, c.update.finish)
  check("offline: apps stay due", c.env.fs.exists("etc/zos/update/apps-due"))
  publishApps(c, { mine = "2.0.0" })
  call(c, c.update.tick)
  check("offline: tick catches up", c.files[".zos/apps/mine/main.lua"] == "print('hi')")
  check("offline: no longer due", not c.env.fs.exists("etc/zos/update/apps-due"))
end

do
  local c = setup(installed())
  local system = c.env.require("system")
  system.setConfig({ autoUpdate = false })
  c.publish(imageText(c))
  call(c, c.update.tick)
  check("off: doesn't download", c.update.stagedVersion() == nil and not c.fetched[IMAGE])

  system.setConfig({ autoUpdate = true })
  call(c, c.update.tick)
  check("on: downloads", c.update.stagedVersion() == NEXT)
  call(c, c.update.finish)
  check("a stored update survives a boot that didn't apply it", c.update.stagedVersion() == NEXT)
end

do
  local c = setup(installed({ ["startup.lua"] = "-- old startup\n" .. STARTUP }))
  c.publish(imageText(c))
  call(c, c.update.tick)
  check("boots after replacing itself", boot(c) == "booted")
  check("keeps /startup.lua during the trial", c.files["startup.lua"] ~= STARTUP)
  call(c, c.update.finish)
  check("replaces /startup.lua", c.files["startup.lua"] == STARTUP)
end

-- Rolling back ---------------------------------------------------------------------

do
  local c = setup(installed())
  c.publish(imageText(c, { ["/.zos/boot.lua"] = "-- broken boot" }))
  publishApps(c, { terminal = "2.0.0" })
  call(c, c.update.tick)
  check("falls back and reboots", boot(c) == "reboot")
  check("old version restored", c.files[".zos/boot.lua"] == "-- old boot" and c.files[".zos/lib/system.lua"] == "-- old lib")
  check("remembers what failed", c.update.failedVersion() == NEXT)
  check("doesn't try it again", boot(c) == "booted" and c.files[".zos/boot.lua"] == "-- old boot")
  call(c, c.update.finish)
  check("no apps from the failed update", not c.env.fs.exists(".zos/apps/terminal"))
  call(c, c.update.tick)
  check("won't redownload it by itself", c.update.stagedVersion() == nil)

  c.publish(imageText(c))
  local info = call(c, c.update.check)
  check("an admin can still choose to", call(c, c.update.download, info))
  check("then it installs", boot(c) == "booted" and c.files[".zos/boot.lua"] == "-- new boot")
  c.env.require("system").VERSION = NEXT
  call(c, c.update.finish)
  check("failure forgotten after a good install", c.update.failedVersion() == nil)
end

-- Apps from the same release ---------------------------------------------------------

local function withApps(extra)
  return installed({
    [".zos/apps/old/main.lua"] = "old", [".zos/apps/old/app.manifest"] = '{ name = "old", version = "1.0.0" }',
    [".zos/apps/same/main.lua"] = "same", [".zos/apps/same/app.manifest"] = '{ name = "same", version = "2.0.0" }',
    [".zos/apps/ahead/main.lua"] = "ahead", [".zos/apps/ahead/app.manifest"] = '{ name = "ahead", version = "5.0.0" }',
  })
end

do
  local c = setup(withApps())
  publishApps(c, { old = "2.0.0", same = "2.0.0", ahead = "2.0.0", fresh = "1.0.0" })
  local list = call(c, c.update.checkApps)
  check("lists the release's apps", list and #list == 4)
  check("updates come first", list[1].id == "old" and list[1].newer and list[1].current == "1.0.0")
  check("then new apps", list[2].id == "fresh" and not list[2].current)
  check("same version isn't an update", not list[3].newer and not list[4].newer)
  check("older version isn't an update", list[3].id == "ahead" or list[4].id == "ahead")

  local pkg = call(c, c.update.downloadApp, list[1])
  check("downloads a checked package", pkg and pkg.id == "old" and pkg.manifest.version == "2.0.0")

  local good = c.site[appUrl("old")]
  c.site[appUrl("old")] = good:gsub("print", "error")
  local none, err = call(c, c.update.downloadApp, list[1])
  check("refuses a changed app", not none and err:find("changed", 1, true))
  c.site[appUrl("old")] = nil
  check("reports a missing app", not call(c, c.update.downloadApp, list[1]))

  -- The right size and hash, but a different app.
  publishApps(c, { old = "2.0.0", same = "2.0.0" })
  c.site[appUrl("old")] = c.site[appUrl("same")]
  local entry = call(c, c.update.checkApps)[1]
  entry.sha256 = c.crypto.sha256(c.site[appUrl("old")])
  entry.size = #c.site[appUrl("old")]
  none, err = call(c, c.update.downloadApp, entry)
  check("refuses an app that isn't the one listed", not none and err:find("listed", 1, true))

  publishApps(c, { old = "2.0.0" })
  c.site[APPS_MANIFEST] = c.site[APPS_MANIFEST]:sub(1, -5)
  none, err = call(c, c.update.checkApps)
  check("refuses a cut-off list", not none and err:find("damaged", 1, true))

  c.site[APPS_MANIFEST] = c.manifest("image")
  none = call(c, c.update.checkApps)
  check("a zOS manifest doesn't pass as an app list", none == nil)

  c.site[MANIFEST] = "zos-apps 1\nrelease=9.0.0\nversion=9.0.0\nsize=1\nsha256=ab\nend\n"
  check("an app list doesn't pass as a zOS manifest", call(c, c.update.check) == nil)

  c.site[MANIFEST] = c.manifest("image", "9.0")
  local refused, why = call(c, c.update.check)
  check("refuses a zOS release with a short version", refused == nil and why:find("damaged", 1, true))

  local line = "app=old\t%s\t5\t" .. string.rep("0", 64) .. "\t%s\tOld\tOld app\n"
  c.site[APPS_MANIFEST] = "zos-apps 1\nrelease=9.0.0\n" .. line:format("2.0", "") .. "end\n"
  refused, why = call(c, c.update.checkApps)
  check("refuses an app with a short version", refused == nil and why:find("damaged", 1, true))
  c.site[APPS_MANIFEST] = "zos-apps 1\nrelease=9.0.0\n" .. line:format("2.0.0", "2.0") .. "end\n"
  refused, why = call(c, c.update.checkApps)
  check("refuses an app with a short minZos", refused == nil and why:find("damaged", 1, true))
end

-- Driving the real App Manager -------------------------------------------------------

local function key(c, name) c.env.os.queueEvent("key", c.env.keys[name]) end
local function char(c, ch) c.env.os.queueEvent("char", ch) end
local function screenHas(c, text)
  local ok, err = pcall(sim.run, function() return c.screenText():find(text, 1, true) ~= nil end, 60)
  if not ok then
    print("Waiting for '" .. text .. "', the screen says:\n" .. c.screenText())
    error(err, 0)
  end
  return true
end
local function pick(c, n)
  for _ = 1, n do key(c, "down") end
  key(c, "enter")
end
local function appman(c, admin)
  local fn = assert(load(readFile("apps/appman/main.lua"), "@main.lua", "t", c.env))
  return sim.spawn(c, fn, { user = "me", admin = admin }, {})
end

do
  local c = setup(withApps())
  c.env.require("system").VERSION = NEXT
  c.env.require("system").VERSION = NEXT
  publishApps(c, { old = "2.0.0", same = "2.0.0", fresh = "1.0.0", other = "3.0.0" })
  c.site[appUrl("other")] = nil -- this one fails partway through
  c.files[".zos/apps/other/main.lua"] = "other"
  c.files[".zos/apps/other/app.manifest"] = '{ name = "other", version = "1.0.0" }'
  appman(c, true)
  check("App Manager offers GitHub", screenHas(c, "Get apps from GitHub"))
  key(c, "enter")
  check("offers to update all", screenHas(c, "Update all (2)"))
  check("shows the update", c.screenText():find("App old 2.0.0  (update from 1.0.0)", 1, true))
  check("shows new apps", c.screenText():find("App fresh 1.0.0  (new)", 1, true))
  check("shows installed apps", c.screenText():find("App same 2.0.0  (installed)", 1, true))

  key(c, "enter")
  check("asks first", screenHas(c, "Install 2 update(s)?"))
  check("nothing changed yet", c.files[".zos/apps/old/main.lua"] == "old")
  char(c, "y")
  check("reports the failure", screenHas(c, "Not Found"))
  check("keeps going after a failure", c.files[".zos/apps/old/main.lua"] == "print('hi')")
  check("leaves the failed app alone", c.files[".zos/apps/other/main.lua"] == "other")
  check("doesn't install new apps", not c.env.fs.exists(".zos/apps/fresh"))
  check("logs the install", c.files["etc/zos/system.log"]:find("installed app old 2.0.0", 1, true))
  key(c, "enter")
  screenHas(c, "Get apps from GitHub")

  -- One new app: Update all, other, fresh, old, same, Back.
  c.site[appUrl("other")] = appText(c, "other", "3.0.0")
  publishApps(c, { same = "2.0.0", fresh = "1.0.0" })
  key(c, "enter")
  screenHas(c, "App fresh 1.0.0  (new)")
  key(c, "enter")
  check("shows the usual install screen", screenHas(c, "Install it?"))
  char(c, "y")
  check("installs it", screenHas(c, "Installed fresh 1.0.0"))
  check("files in place", c.files[".zos/apps/fresh/main.lua"] == "print('hi')")
  key(c, "enter")
  screenHas(c, "Get apps from GitHub")

  -- Up to date: no Update all, and nothing to reinstall.
  key(c, "enter")
  screenHas(c, "App same 2.0.0  (installed)")
  check("nothing to update", not c.screenText():find("Update all", 1, true))
  pick(c, 1)
  check("won't reinstall", screenHas(c, "is up to date"))
end

do
  local c = setup(withApps())
  publishApps(c, { old = "2.0.0" })
  appman(c, false)
  screenHas(c, "Get apps from GitHub")
  key(c, "enter")
  check("anyone can look", screenHas(c, "Update all (1)"))
  key(c, "enter")
  check("only admins can install", screenHas(c, "Only administrators"))
  check("nothing installed", c.files[".zos/apps/old/main.lua"] == "old")
end

-- Apps that need a newer zOS ----------------------------------------------------------

do
  local c = setup(withApps())
  local apps = c.env.require("apps")
  check("no minZos runs anywhere", apps.supports(nil))
  check("same version is enough", apps.supports(CURRENT))
  for _, bad in ipairs({ "1", "1.0", "1.0.0.0", "v1.0.0", "1.0.0-beta", "1.0.", ".1.0", "1..0", " 1.0.0", "1.0.0\n", "", 1 }) do
    check("not a version: " .. tostring(bad), not apps.validVersion(bad))
    check("refuses the version " .. tostring(bad), not apps.parse(appText(c, "x", bad)))
    check("can't compare " .. tostring(bad), not pcall(apps.compareVersions, bad, "1.0.0"))
  end
  check("a version has three numbers", apps.validVersion("0.0.0") and apps.validVersion("10.20.30"))
  check("compares numbers, not text", not apps.supports("2.0.10") and apps.supports("1.10.0"))
  check("newer isn't enough", not apps.supports("2.0.1"))

  local function parsed(minZos) return apps.parse(appText(c, "x", "1.0.0", minZos)) end
  check("accepts a version", parsed("2.1.0"))
  check("refuses a bad minZos", not parsed("soon") and not parsed("2.1.0-beta") and not parsed("2.1"))

  local pkg = parsed("3.0.0")
  local app, err = apps.install(pkg)
  check("install refuses a newer minZos", not app and err:find("needs zOS 3.0.0", 1, true))
  check("install leaves nothing behind", not c.env.fs.exists(".zos/apps/x"))
  check("install allows a met minZos", apps.install(parsed("2.0.0")))
  check("minZos is kept on the app", apps.get("x").minZos == "2.0.0")

  check("apps aren't admin only by default", apps.get("x").admin == false)
  local user, boss = { user = "u", admin = false }, { user = "b", admin = true }
  check("anyone can run a normal app", apps.canRun(apps.get("x"), user))
  local function setManifest(text)
    local file = c.env.fs.open(".zos/apps/x/app.manifest", "w")
    file.write(text)
    file.close()
  end
  setManifest('{ name = "X", version = "1.0.0", admin = true }')
  check("reads the admin flag", apps.get("x").admin == true)
  check("an admin can run an admin app", apps.canRun(apps.get("x"), boss))
  check("a user can't run an admin app", not apps.canRun(apps.get("x"), user))
  local started, why = apps.launch(apps.get("x"), user)
  check("launch refuses a user", started == false and why:find("Only administrators", 1, true))
  setManifest('{ name = "X", version = "1.0.0", admin = "yes" }')
  check("refuses an admin flag that isn't a boolean", apps.get("x") == nil)
  setManifest('{ name = "X", version = "1.0.0" }')

  publishApps(c, { old = { "2.0.0", "3.0.0" }, same = { "3.0.0", "3.0.0" }, fresh = { "1.0.0", "3.0.0" }, ok = { "1.0.0", "2.0.0" } })
  local list = call(c, c.update.checkApps)
  check("apps it can run come first", list[1].id == "ok" and list[1].supported)
  check("marks an update it can't run", list[2].minZos == "3.0.0" and not list[2].supported)
  check("every other app is marked", not list[3].supported and not list[4].supported)
end

do
  local c = setup(withApps())
  publishApps(c, { old = { "2.0.0", "3.0.0" }, same = { "3.0.0", "1.0.0" }, fresh = { "1.0.0", "3.0.0" } })
  appman(c, true)
  screenHas(c, "Get apps from GitHub")
  key(c, "enter")
  check("offers only what it can install", screenHas(c, "Update all (1)"))
  check("shows what's needed", c.screenText():find("App old 2.0.0  (needs zOS 3.0.0)", 1, true))
  check("shows it for new apps too", c.screenText():find("App fresh 1.0.0  (needs zOS 3.0.0)", 1, true))

  -- Update all, App same, App fresh, App old, Back.
  pick(c, 3)
  check("explains and points to updates", screenHas(c, "Settings > Updates"))
  check("old version stays", c.files[".zos/apps/old/main.lua"] == "old")
  key(c, "enter")
  screenHas(c, "Get apps from GitHub")
  key(c, "enter")
  screenHas(c, "Update all (1)")
  key(c, "enter")
  screenHas(c, "Install 1 update(s)?")
  check("Update all leaves it out", not c.screenText():find("App old", 1, true))
  char(c, "y")
  screenHas(c, "Everything is up to date")
  check("the rest updates", c.files[".zos/apps/same/app.manifest"]:find('"3.0.0"', 1, true))
  check("still not installed", c.files[".zos/apps/old/main.lua"] == "old")
end

do -- Installing from a file gets the same check.
  local c = setup(withApps())
  c.files["new.za"] = appText(c, "fresh", "1.0.0", "3.0.0")
  appman(c, true)
  screenHas(c, "Install from file")
  pick(c, 2)
  screenHas(c, "Path")
  c.env.os.queueEvent("sim_line", "new.za")
  check("a file gets the same check", screenHas(c, "needs zOS 3.0.0"))
  check("nothing installed from the file", not c.env.fs.exists(".zos/apps/fresh"))
end

do -- An update whose app needs more than the update provides is skipped, and zOS still boots.
  local c = setup(installed({ [".zos/apps/mine/main.lua"] = "old", [".zos/apps/mine/app.manifest"] = '{ name = "mine", version = "1.0.0" }' }))
  c.publish(imageText(c))
  publishApps(c, { mine = { "2.0.0", "99.0.0" } })
  call(c, c.update.tick)
  check("boots with an app it can't run", boot(c) == "booted")
  c.env.require("system").VERSION = NEXT
  call(c, c.update.finish)
  check("skips an app it can't run", c.files[".zos/apps/mine/main.lua"] == "old")
end

-- A power cut at every step ---------------------------------------------------------

local function powerCuts(name, text, finalBoot)
  local n = 1
  while true do
    local c = setup(installed())
    c.publish(text(c))
    call(c, c.update.tick)
    local result, ops = boot(c, n)
    if result ~= "crash" then break end
    local attempts = 0
    repeat
      result = boot(c)
      attempts = attempts + 1
    until result == "booted" or attempts > 3
    check(name .. ": comes back after a cut at step " .. n, result == "booted")
    check(name .. ": right version after a cut at step " .. n, c.files[".zos/boot.lua"] == finalBoot)
    n = n + 1
  end
  check(name .. ": tried every step", n > 2)
end

powerCuts("update", function(c) return imageText(c) end, "-- new boot")
powerCuts("rollback", function(c) return imageText(c, { ["/.zos/boot.lua"] = "-- broken boot" }) end, "-- old boot")

if failed > 0 then
  print(("update: %d passed, %d FAILED"):format(passed, failed))
  os.exit(1)
end
print(("update: all %d passed"):format(passed))
