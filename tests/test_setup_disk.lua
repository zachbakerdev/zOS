-- Drives the real Setup Disk app with scripted keys and a fake floppy and GitHub.
-- Run from the repository root: luajit tests/test_setup_disk.lua
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

local VERSION = "9.8.7"
local RELEASES = "https://github.com/zachbakerdev/zOS/releases/"
local MANIFEST = RELEASES .. "latest/download/zos-update.manifest"
local IMAGE = RELEASES .. "download/v" .. VERSION .. "/zos.zi"
local INSTALLER = RELEASES .. "download/v" .. VERSION .. "/install.lua"

local function screenHas(c, text)
  local ok, err = pcall(sim.run, function() return c.screenText():find(text, 1, true) ~= nil end, 30)
  if not ok then
    print("Waiting for '" .. text .. "', the screen says:\n" .. c.screenText())
    error(err, 0)
  end
  return true
end

local function key(c, name) c.env.os.queueEvent("key", c.env.keys[name]) end
local function char(c, ch) c.env.os.queueEvent("char", ch) end

local function finished(c)
  sim.run(function() return c.thread.done end, 30)
  return true
end

-- A computer with `drives` (side -> { mount, id, label }, or { empty = true }), and a site that
-- serves a good release unless `change` alters it.
local function start(files, drives, change)
  for _, other in pairs(sim.computers) do sim.powerOff(other) end
  local c = sim.computer(1, { files = files })
  local env = c.env

  local image = env.textutils.serialize({
    ["zi:metadata"] = { version = 1 },
    ["/.zos/boot.lua"] = "return 1",
    ["/startup.lua"] = "return 2",
  })
  c.site = {
    [IMAGE] = image,
    [INSTALLER] = "print('install')",
  }
  c.site[MANIFEST] = "zos-update 1\nversion=" .. VERSION .. "\nsize=" .. #image .. "\nsha256=" ..
    env.require("crypto").sha256(image) .. "\nend\n"
  if change then change(c.site, drives, c) end
  c.image, c.requests = c.site[IMAGE], {}
  env.http = { get = function(url)
    c.requests[#c.requests + 1] = url
    if c.onRequest then c.onRequest(url) end
    local text = c.site[url]
    if not text then return nil, "Not Found" end
    return { readAll = function() return text end, close = function() end }
  end }

  local realPeripheral = env.peripheral
  env.peripheral = setmetatable({
    getNames = function()
      local names = realPeripheral.getNames()
      for side in pairs(drives) do names[#names + 1] = side end
      table.sort(names)
      return names
    end,
    getType = function(side) return drives[side] and "drive" or realPeripheral.getType(side) end,
  }, { __index = realPeripheral })
  env.disk = {
    hasData = function(side) return drives[side] ~= nil and not drives[side].empty end,
    getMountPath = function(side) return drives[side].mount end,
    getID = function(side) return drives[side].id end,
    getLabel = function(side) return drives[side].label end,
  }
  local isReadOnly = env.fs.isReadOnly
  env.fs.isReadOnly = function(path)
    for _, d in pairs(drives) do
      if d.readOnly and d.mount == path then return true end
    end
    return isReadOnly(path)
  end
  env.fs.getCapacity = function() return c.capacity or 125000 end

  local fn = assert(loadfile("apps/setup-disk/main.lua"))
  setfenv(fn, env)
  c.thread = sim.spawn(c, fn, { user = "me", admin = false }, {})
  return c
end

local function oldDisk()
  return { ["disk/old.txt"] = "old", ["disk/folder/more.txt"] = "more", ["disk/startup"] = "print('old')" }
end
local function oneDrive() return { left = { mount = "disk", id = 7, label = "Backups" } } end

-- Makes a setup disk -----------------------------------------------------------------------------

do
  local files = oldDisk()
  local c = start(files, oneDrive())
  check("names the disk", screenHas(c, 'Disk: "Backups" (/disk)'))
  check("counts what's on it", screenHas(c, "It has 3 items on it."))
  check("asks first", screenHas(c, "Erase it and make a setup disk?"))
  check("nothing is downloaded before it asks", #c.requests == 0)
  char(c, "y")
  check("reports success", screenHas(c, "zOS " .. VERSION .. " setup disk"))
  check("old files are gone", not files["disk/old.txt"] and not files["disk/folder/more.txt"])
  check("old startup is gone", not files["disk/startup"])
  check("image is on the disk", files["disk/zos.zi"] == c.image)
  check("installer is the startup script", files["disk/startup.lua"] == c.site[INSTALLER])
  check("only those two files", #c.env.fs.list("disk") == 2)
  check("the installer comes from the same release", c.requests[3] == INSTALLER)
  key(c, "enter")
  check("exits", finished(c))
end

-- Saying no ----------------------------------------------------------------------------------------

do
  local files = oldDisk()
  local c = start(files, oneDrive())
  screenHas(c, "Erase it and make a setup disk?")
  char(c, "n")
  check("no leaves", finished(c))
  check("no leaves the disk alone", files["disk/old.txt"] == "old")
  check("no downloads nothing", #c.requests == 0)
end

-- Anything wrong leaves the disk as it was ----------------------------------------------------------

local function refused(name, change, message, prepare)
  local files = oldDisk()
  local c = start(files, oneDrive(), change)
  if prepare then prepare(c) end
  screenHas(c, "Erase it and make a setup disk?")
  char(c, "y")
  check(name .. ": says so", screenHas(c, message))
  check(name .. ": says it wasn't erased", screenHas(c, "erased"))
  check(name .. ": disk unchanged", files["disk/old.txt"] == "old" and files["disk/zos.zi"] == nil
    and files["disk/startup.lua"] == nil)
  key(c, "enter")
  check(name .. ": exits", finished(c))
end

refused("no release", function(site) site[MANIFEST] = nil end, "Not Found")
refused("cut-off list", function(site) site[MANIFEST] = site[MANIFEST]:gsub("end\n$", "") end, "damaged")
refused("no image", function(site) site[IMAGE] = nil end, "Not Found")
refused("short image", function(site) site[IMAGE] = site[IMAGE]:sub(1, -2) end, "wrong size")
refused("altered image", function(site) site[IMAGE] = site[IMAGE]:gsub("return 1", "return 3") end, "has changed")
refused("no installer", function(site) site[INSTALLER] = nil end, "Not Found")
refused("broken installer", function(site) site[INSTALLER] = "this is not lua" end, "doesn't compile")
refused("too small", nil, "A setup disk needs 1 KB", function(c) c.capacity = 900 end)

-- A disk swapped during the download wasn't the one agreed to.
do
  local files = oldDisk()
  local drives = oneDrive()
  local c = start(files, drives)
  c.onRequest = function(url) if url == INSTALLER then drives.left.id = 8 end end
  screenHas(c, "Erase it and make a setup disk?")
  char(c, "y")
  check("swap: says so", screenHas(c, "taken out or changed"))
  check("swap: nothing erased", files["disk/old.txt"] == "old")
end

-- Finding disks --------------------------------------------------------------------------------------

do
  local files = oldDisk()
  files["disk2/keep.txt"] = "keep"
  local c = start(files, {
    left = { mount = "disk", id = 7, label = "Backups" },
    right = { mount = "disk2", id = 8 },
  })
  check("several: lists them", screenHas(c, '"Backups" (/disk)'))
  check("several: lists the unlabelled one", screenHas(c, "/disk2"))
  key(c, "down")
  key(c, "enter")
  check("several: asks about the chosen one", screenHas(c, "Disk: /disk2"))
  char(c, "y")
  screenHas(c, "This is now")
  check("several: erases the chosen one", files["disk2/keep.txt"] == nil and files["disk2/zos.zi"] ~= nil)
  check("several: leaves the other", files["disk/old.txt"] == "old")
end

do
  local files = oldDisk()
  local drives = { left = { empty = true }, right = { mount = "disk", id = 7, readOnly = true } }
  local c = start(files, drives)
  check("none: asks for one, ignoring an empty drive and a read-only disk", screenHas(c, "Put a floppy"))
  drives.left = { mount = "disk2", id = 9 }
  c.env.os.queueEvent("disk", "left")
  check("none: notices a new disk", screenHas(c, "Disk: /disk2"))
end

do
  local c = start({}, {})
  screenHas(c, "Put a floppy")
  key(c, "backspace")
  check("none: backspace leaves", finished(c))
end

-- Root servers -------------------------------------------------------------------------------------

local function rootServer(id, name, tld)
  local c = sim.computer(id)
  c.appDir = "apps/root-server/"
  c.db = c.env.require("rootdb")
  sim.call(c, function() c.db.setup(name, tld) end)
  local fn = assert(loadfile("apps/root-server/service.lua"))
  setfenv(fn, c.env)
  sim.spawn(c, fn)
  sim.advance(1)
  return c
end

local function trustIt(c, server, name)
  local _, public = server.db.keypair()
  c.env.require("trust").addRoot(c.env.require("crypto").toHex(public), name, server.id)
end

local function onDisk(c, files)
  return files["disk/zos.zr"] and c.env.textutils.unserialize(files["disk/zos.zr"])
end

-- One root for each domain: the second choice replaces the first.
do
  local files = oldDisk()
  local c = start(files, oneDrive(), function(_, _, c)
    trustIt(c, rootServer(10, "Alpha", "shared"), "Alpha")
    trustIt(c, rootServer(11, "Beta", "shared"), "Beta")
    trustIt(c, rootServer(12, "Gamma", "other"), "Gamma")
  end)
  screenHas(c, "Erase it and make a setup disk?")
  char(c, "y")
  check("roots: lists them", screenHas(c, "[ ] Alpha  .shared"))
  key(c, "enter")
  check("roots: ticks one", screenHas(c, "[x] Alpha  .shared"))
  key(c, "down")
  check("roots: warns about the replacement", screenHas(c, "replaces Alpha"))
  key(c, "enter")
  check("roots: the other is replaced", screenHas(c, "[x] Beta  .shared") and screenHas(c, "[ ] Alpha  .shared"))
  key(c, "down")
  key(c, "enter")
  check("roots: another domain is added", screenHas(c, "[x] Gamma  .other"))
  key(c, "down")
  key(c, "enter")
  screenHas(c, "This is now")
  local data = onDisk(c, files)
  check("roots: the format version", data["zr:metadata"].version == 1)
  check("roots: the chosen root", data.roots.shared.name == "Beta" and data.roots.shared.host == 11)
  check("roots: the other domain", data.roots.other.name == "Gamma")
  local trust = c.env.require("trust")
  local shared = data.roots.shared
  check("roots: signed", sim.call(c, function()
    return trust.verifyZone({ tld = "shared", root = shared.key, sig = shared.sig }, shared.key)
  end))
  check("roots: the image is untouched", files["disk/zos.zi"] == c.image)
  check("roots: three files", #c.env.fs.list("disk") == 3)
end

-- Choosing none leaves no file, and a dead root is left out.
do
  local files = oldDisk()
  local c = start(files, oneDrive(), function(_, _, c)
    c.env.require("trust").addRoot(string.rep("a", 64), "Gone", 99)
    trustIt(c, rootServer(10, "Alpha", "alpha"), "Alpha")
  end)
  screenHas(c, "Erase it and make a setup disk?")
  char(c, "y")
  check("dead root: says so", screenHas(c, "Gone"))
  key(c, "enter")
  screenHas(c, "[ ] Alpha")
  check("dead root: isn't offered", not c.screenText():find("Gone", 1, true))
  key(c, "up")
  key(c, "enter")
  screenHas(c, "This is now")
  check("none chosen: no file", files["disk/zos.zr"] == nil and files["disk/zos.zi"] ~= nil)
end

-- Backing out of the list changes nothing.
do
  local files = oldDisk()
  local c = start(files, oneDrive(), function(_, _, c) trustIt(c, rootServer(10, "Alpha", "alpha"), "Alpha") end)
  screenHas(c, "Erase it and make a setup disk?")
  char(c, "y")
  screenHas(c, "[ ] Alpha")
  key(c, "backspace")
  check("back: leaves", finished(c))
  check("back: disk unchanged", files["disk/old.txt"] == "old" and #c.requests == 0)
end

-- A root server can put itself on a disk without trusting itself.
do
  local files = oldDisk()
  local c = start(files, oneDrive(), function(_, _, c)
    c.appDir = "apps/root-server/"
    local db = c.env.require("rootdb")
    sim.call(c, function() db.setup("Own Root", "own") end)
    c.appDir = nil
  end)
  screenHas(c, "Erase it and make a setup disk?")
  char(c, "y")
  check("own root: offered", screenHas(c, "[ ] Own Root  .own"))
  key(c, "enter")
  screenHas(c, "[x] Own Root")
  key(c, "up")
  key(c, "enter")
  screenHas(c, "This is now")
  check("own root: on the disk", onDisk(c, files).roots.own.host == 1)
end

if failed > 0 then
  print(("%d passed, %d FAILED"):format(passed, failed))
  os.exit(1)
end
print(("setup-disk: all %d passed"):format(passed))
