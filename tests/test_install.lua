-- Tests of install.lua on simulated computers, using a real image if ./package has built one.
-- Run from the repository root: lua5.2 tests/test_install.lua
-- ZOS_INSTALLER=dist/install.lua tests a minified build of it instead.

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

local INSTALLER = assert(readHost(os.getenv("ZOS_INSTALLER") or "install.lua"))

local function norm(p) return (p:gsub("^/+", "")) end

-- A computer: `files` maps paths without a leading / to contents. `answers` are what's chosen in
-- each menu: the number of an item, reached with the arrow keys, or a list of events.
local function computer(files, answers)
  local c = { files = files, out = {}, reboots = 0, ejected = {}, settings = {}, urls = {}, freeSpace = 1000000 }
  local function under(p, k) return p == "" or k:sub(1, #p + 1) == p .. "/" end
  local fs = {}
  function fs.combine(a, b) a, b = norm(a), norm(b) return a == "" and b or (b == "" and a or a .. "/" .. b) end
  function fs.getDir(p) return norm(p):match("^(.*)/[^/]*$") or "" end
  function fs.getName(p) return norm(p):match("[^/]*$") end
  function fs.isDir(p)
    p = norm(p)
    if c.files[p] then return false end
    for k in pairs(c.files) do if under(p, k) then return true end end
    return p == ""
  end
  function fs.exists(p) p = norm(p) return c.files[p] ~= nil or fs.isDir(p) end
  function fs.getFreeSpace() return c.freeSpace end
  function fs.list(p)
    p = norm(p)
    local seen, names = {}, {}
    for k in pairs(c.files) do
      local name = under(p, k) and k:sub(#p + 2):match("^[^/]+")
      if name and not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
    return names
  end
  function fs.makeDir() end
  function fs.delete(p)
    p = norm(p)
    for k in pairs(c.files) do if k == p or under(p, k) then c.files[k] = nil end end
  end
  local function each(from, to, keep)
    from, to = norm(from), norm(to)
    if not fs.exists(from) then error("No such file: " .. from, 0) end
    local moved = {}
    for k, v in pairs(c.files) do
      if k == from or under(from, k) then moved[k] = v end
    end
    for k, v in pairs(moved) do
      if not keep then c.files[k] = nil end
      c.files[to .. k:sub(#from + 1)] = v
    end
  end
  function fs.move(a, b) each(a, b, false) end
  function fs.copy(a, b) each(a, b, true) end
  function fs.open(p, mode)
    p = norm(p)
    if mode == "rb" then
      local data = c.files[p]
      if not data then return nil, "No such file" end
      return { readAll = function() return data end, close = function() end }
    end
    return {
      write = function(data)
        if c.limit and c.limit(p) then data = data:sub(1, 1) end
        c.files[p] = data
      end,
      close = function() end,
    }
  end

  local KEYS = { up = 200, down = 208, enter = 28, numPadEnter = 156 }
  local queue, next_answer = {}, 0
  local function pullEvent()
    if #queue == 0 then
      next_answer = next_answer + 1
      local answer = answers and answers[next_answer]
      if not answer then error("asked too many questions", 0) end
      if type(answer) == "table" then
        for _, event in ipairs(answer) do queue[#queue + 1] = event end
      else
        for _ = 2, answer do queue[#queue + 1] = { "key", KEYS.down } end
        queue[#queue + 1] = { "key", KEYS.enter }
      end
    end
    return table.unpack(table.remove(queue, 1))
  end

  local x, y = 1, 1
  c.width, c.height, c.rows = 51, 19, {}
  local term = {
    getSize = function() return c.width, c.height end,
    getCursorPos = function() return x, y end,
    setCursorPos = function(a, b) x, y = a, b end,
    setCursorBlink = function() end,
    setTextColor = function() end,
    setBackgroundColor = function() end,
    clear = function() end,
    clearLine = function() end,
    scroll = function() end,
    isColour = function() return true end,
    write = function(text)
      assert(x + #text - 1 <= c.width and y <= c.height, "drawn off the screen: " .. text)
      c.out[#c.out + 1] = text
      c.rows[text:match("^%s*(.-)%s*$")] = y
      x = x + #text
    end,
  }

  c.env = setmetatable({
    fs = fs,
    term = term,
    keys = KEYS,
    colors = setmetatable({}, { __index = function() return 1 end }),
    shell = {
      getRunningProgram = function() return c.program or "install.lua" end,
      resolve = function(p) return norm(p) end,
    },
    os = {
      getComputerID = function() return 7 end,
      reboot = function() c.reboots = c.reboots + 1 error("rebooted", 0) end,
      pullEvent = pullEvent,
      pullEventRaw = function() end,
    },
    http = { get = function(url)
      local text = c.urls[url]
      if not text then return nil, "Not Found" end
      return { readAll = function() return text end, close = function() end }
    end },
    disk = {
      isPresent = function(side) return side == "left" end,
      getMountPath = function() return "disk" end,
      eject = function(side) c.ejected[#c.ejected + 1] = side end,
    },
    peripheral = { getNames = function() return { "left" } end },
    settings = {
      set = function(k, v) c.settings[k] = v end,
      save = function(path) c.settingsSaved = path end,
    },
    textutils = { unserialize = function(s)
      local fn = load("return " .. s, "=image", "t", {})
      if not fn then return nil end
      local ok, v = pcall(fn)
      return ok and v or nil
    end },
    sleep = function() end,
  }, { __index = _G })
  return c
end

local function run(c, ...)
  local fn = assert(load(INSTALLER, "@install.lua", "t", c.env))
  local ok, err = pcall(fn, ...)
  return ok or err == "rebooted" or err == "", err
end

local function said(c, pattern)
  return table.concat(c.out, " "):find(pattern) ~= nil
end

local function quote(s) return string.format("%q", s) end

local function imageText(extra)
  local files = {
    ["/startup.lua"] = "-- new startup",
    ["/.zos/boot.lua"] = "-- new boot",
    ["/.zos/lib/system.lua"] = 'local a={VERSION="1.0.0",ROOT="/.zos"}return a',
    ["/.zos/apps/files/main.lua"] = "-- new files app",
  }
  for k, v in pairs(extra or {}) do files[k] = v or nil end
  local out = { '{["zi:metadata"]={version=1},' }
  for k, v in pairs(files) do out[#out + 1] = "[" .. quote(k) .. "]=" .. quote(v) .. "," end
  out[#out + 1] = "}"
  return table.concat(out)
end

local function withImage(files, text)
  files["zos.zi"] = text or imageText()
  return files
end

-- A fresh install --------------------------------------------------------------------------------

do
  local c = computer(withImage({ ["startup.lua"] = "-- mine", ["startup"] = "-- also mine" }), { 1 })
  check("install: runs", run(c))
  check("install: boot", c.files[".zos/boot.lua"] == "-- new boot")
  check("install: bootstrap", c.files["startup.lua"] == "-- new startup")
  check("install: backs up startup.lua", c.files["zos-backup/startup.lua"] == "-- mine")
  check("install: backs up startup", c.files["zos-backup/startup"] == "-- also mine")
  check("install: nothing else runs at boot", c.files["startup"] == nil)
  check("install: no leftovers", c.files["startup.lua.install"] == nil and not c.env.fs.exists(".zos.install"))
  check("install: disk boot off", c.settings["shell.allow_disk_startup"] == false and c.settingsSaved == "/.settings")
  check("install: reboots", c.reboots == 1)
  check("install: the image isn't a file on the computer", c.files["zi:metadata"] == nil)
end

do
  local c = computer(withImage({ ["startup.lua"] = "-- mine" }), { 2 })
  run(c)
  check("cancel: nothing changed", c.files["startup.lua"] == "-- mine" and not c.env.fs.exists(".zos"))
  check("cancel: no reboot", c.reboots == 0)
end

-- Sources ----------------------------------------------------------------------------------------

do
  local c = computer({}, { 1 })
  c.urls["https://github.com/zachbakerdev/zOS/releases/latest/download/zos.zi"] = imageText()
  c.program = "rom/programs/http/wget.lua"
  run(c)
  check("no local image: uses the release", c.files[".zos/boot.lua"] ~= nil)
end

do
  local c = computer({}, { 1 })
  c.urls["https://example.com/z.zi"] = imageText()
  run(c, "https://example.com/z.zi")
  check("a URL works", c.files[".zos/boot.lua"] ~= nil)
end

do
  local c = computer({ ["disk/zos.zi"] = imageText() }, { 1 })
  c.program = "disk/startup.lua"
  run(c)
  check("from a disk: installs", c.files[".zos/boot.lua"] ~= nil)
  check("from a disk: ejects", c.ejected[1] == "left")
end

do
  local c = computer({ ["my.zi"] = imageText() }, { 1 })
  run(c, "my.zi")
  check("a path works", c.files[".zos/boot.lua"] ~= nil)
  check("a local image ejects nothing", #c.ejected == 0)
end

do
  local c = computer({})
  run(c, "missing.zi")
  check("missing image: says so", said(c, "no image at missing.zi"))
end

do
  local c = computer({})
  run(c)
  check("failed download: says so", said(c, "download failed"))
end

-- Bad images change nothing ----------------------------------------------------------------------

local function refused(name, text, pattern)
  local c = computer(withImage({ ["startup.lua"] = "-- mine" }, text))
  run(c)
  check(name .. ": refused", said(c, pattern))
  check(name .. ": nothing changed", c.files["startup.lua"] == "-- mine" and not c.env.fs.exists(".zos"))
end

refused("garbage", "this is not an image", "isn't a .zi image")
refused("cut off", imageText():sub(1, 60), "isn't a .zi image")
refused("wrong version", (imageText():gsub("version=1", "version=2")), "newer installer")
refused("no boot", imageText({ ["/.zos/boot.lua"] = false }), "complete system")
refused("no version", imageText({ ["/.zos/lib/system.lua"] = "-- none" }), "complete system")
refused("short version", imageText({ ["/.zos/lib/system.lua"] = 'local a={VERSION="1.0"}return a' }), "complete system")
refused("traversal", imageText({ ["/.zos/../evil"] = "x" }), "bad file name")
refused("rom", imageText({ ["/rom/evil"] = "x" }), "bad file name")
refused("disk", imageText({ ["/disk2/evil"] = "x" }), "bad file name")
refused("file and folder", imageText({ ["/.zos/a"] = "x", ["/.zos/a/b"] = "y" }), "both a file and a folder")
refused("broken lua", imageText({ ["/.zos/lib/x.lua"] = "local = 1" }), "doesn't compile")

do
  local c = computer(withImage({}))
  c.freeSpace = 100
  run(c)
  check("no space: refused", said(c, "disk space") and not c.env.fs.exists(".zos"))
end

do
  local c = computer(withImage({ ["etc/motd"] = "folder here/x" }, imageText({ ["/etc/motd/x"] = "y" })))
  c.files["etc/motd"] = "a file"
  run(c)
  check("file in the way: refused", said(c, "is a file") and not c.env.fs.exists(".zos"))
end

do
  local c = computer(withImage({ ["etc/motd/x"] = "y" }, imageText({ ["/etc/motd"] = "y" })))
  run(c)
  check("folder in the way: refused", said(c, "is a folder") and not c.env.fs.exists(".zos"))
end

do
  local c = computer(withImage({ ["startup.lua"] = "-- mine" }), { 1 })
  c.limit = function(p) return p:match("^%.zos%.install/boot") end
  run(c)
  check("short write: refused", said(c, "Couldn't write"))
  check("short write: nothing left behind", not c.env.fs.exists(".zos.install") and not c.env.fs.exists(".zos"))
  check("short write: startup untouched", c.files["startup.lua"] == "-- mine")
  check("short write: no reboot", c.reboots == 0)
end

-- With zOS installed -----------------------------------------------------------------------------

local function installed()
  return {
    ["startup.lua"] = "-- old startup",
    [".zos/boot.lua"] = "-- old boot",
    [".zos/stale.lua"] = "-- gone in the new version",
    [".zos/apps/files/main.lua"] = "-- old files app",
    [".zos/apps/mail/main.lua"] = "-- mail",
    ["etc/zos/users.db"] = "{}",
    ["etc/zos/LOCKOUT"] = "{}",
    ["etc/zos/keys/a"] = "key",
    ["etc/zos/known_keys"] = "{}",
    ["etc/zos/net/id"] = "id",
    ["etc/zos/config"] = "{secureBoot=false}",
    ["etc/zos/system.log"] = "log",
    ["etc/mail/box"] = "letters",
    ["home/zach/notes"] = "notes",
  }
end

do
  local files = withImage(installed())
  files["etc/zos/update/ready"] = "8.0.0"
  files["etc/zos/update/new/boot.lua"] = "-- a waiting update"
  files["etc/zos/update/failed"] = "9.0.0"
  local c = computer(files, { 1 })
  check("upgrade: runs", run(c))
  local D = "etc/zos/update/"
  check("upgrade: staged", c.files[D .. "new/boot.lua"] == "-- new boot" and c.files[D .. "ready"] == "1.0.0")
  check("upgrade: stages the bootstrap", c.files[D .. "startup.new"] == "-- new startup")
  check("upgrade: replaces a failed marker", c.files[D .. "failed"] == nil)
  check("upgrade: apps aren't staged", not c.env.fs.exists(D .. "new/apps"))
  check("upgrade: running system untouched", c.files[".zos/boot.lua"] == "-- old boot" and c.files["startup.lua"] == "-- old startup")
  check("upgrade: keeps accounts", c.files["etc/zos/users.db"] == "{}" and c.files["etc/zos/keys/a"] == "key")
  check("upgrade: keeps the boot setting", c.settings["shell.allow_disk_startup"] == nil)
  check("upgrade: reboots", c.reboots == 1)
end

do
  local c = computer(withImage(installed()), { 1 })
  c.limit = function(p) return p == "etc/zos/update/startup.new" end
  run(c)
  check("upgrade short write: nothing staged", c.files["etc/zos/update/ready"] == nil and not c.env.fs.exists("etc/zos/update/new"))
  check("upgrade short write: no reboot", c.reboots == 0)
end

do
  local c = computer(withImage(installed()), { 2 })
  check("reinstall: runs", run(c))
  for _, name in ipairs({ "users.db", "LOCKOUT", "keys/a", "known_keys", "net/id", "config" }) do
    check("reinstall: deletes " .. name, c.files["etc/zos/" .. name] == nil)
  end
  check("reinstall: new system", c.files[".zos/boot.lua"] == "-- new boot" and c.files["startup.lua"] == "-- new startup")
  check("reinstall: old system gone", c.files[".zos/stale.lua"] == nil)
  check("reinstall: built-in app replaced", c.files[".zos/apps/files/main.lua"] == "-- new files app")
  check("reinstall: other apps kept", c.files[".zos/apps/mail/main.lua"] == "-- mail")
  check("reinstall: user data kept", c.files["home/zach/notes"] == "notes" and c.files["etc/mail/box"] == "letters")
  check("reinstall: disk boot off", c.settings["shell.allow_disk_startup"] == false)
  check("reinstall: no backup of a current system", not c.env.fs.exists("zos-backup"))
end

do
  local files = withImage(installed())
  files["startup"] = "-- something of mine"
  local c = computer(files, { 2 })
  run(c)
  check("reinstall: a stray /startup is removed", c.files["startup"] == nil)
  check("reinstall: and backed up", c.files["zos-backup/startup"] == "-- something of mine")
end

do
  local c = computer(withImage(installed()), { 3 })
  run(c)
  check("cancel when installed: unchanged", c.files["etc/zos/users.db"] == "{}" and c.reboots == 0)
end

do
  local c = computer(withImage({
    ["startup.lua"] = "-- damaged",
    ["etc/zos/users.db"] = "{}",
  }), { 1 })
  run(c)
  check("no system: only a reinstall is offered", c.files[".zos/boot.lua"] == "-- new boot")
  check("no system: can't upgrade", not said(c, "Upgrade"))
  check("no system: accounts deleted", c.files["etc/zos/users.db"] == nil)
  check("no system: backed up", c.files["zos-backup/startup.lua"] == "-- damaged")
end

do
  local files = installed()
  files[".zos/boot.lua"] = nil
  local c = computer(withImage(files), { 1 })
  run(c)
  check("damaged system: reinstalled", c.files[".zos/boot.lua"] == "-- new boot" and c.files["etc/zos/users.db"] == nil)
end

-- The menu ---------------------------------------------------------------------------------------

do
  local c = computer(withImage(installed()), { 3 })
  run(c)
  check("menu: hint of the first item", said(c, "Keeps users, apps and settings"))
  check("menu: hint of the item moved to", said(c, "Deletes all accounts"))
end

do
  local c = computer(withImage(installed()), { 1 })
  run(c)
  check("menu: other items' hints aren't shown", not said(c, "Deletes all accounts"))
end

do
  local c = computer(withImage(installed()), { { { "key", 200 }, { "key", 28 } } })
  run(c)
  check("menu: up wraps around to Cancel", c.reboots == 0 and said(c, "Cancelled"))
end

do
  local c = computer(withImage(installed()), { { { "mouse_scroll", 1 }, { "mouse_scroll", 1 }, { "mouse_scroll", 1 }, { "key", 28 } } })
  run(c)
  check("menu: the scroll wheel stops at the end", c.reboots == 0 and said(c, "Cancelled"))
end

do
  local c = computer(withImage(installed()), { { { "char", "2" }, { "mouse_click", 1, 2, 1 }, { "key", 28 } } })
  run(c)
  check("menu: ignores number keys and clicks outside it", c.files["etc/zos/update/ready"] == "1.0.0")
end

do
  local probe = computer(withImage({}), { 2 })
  run(probe)
  local c = computer(withImage({ ["startup.lua"] = "-- mine" }), { { { "mouse_click", 1, 2, probe.rows["Cancel"] } } })
  run(c)
  check("menu: a click chooses", c.reboots == 0 and said(c, "Cancelled"))
end

do
  local c = computer(withImage(installed()), { 2 })
  c.width, c.height = 26, 20
  check("menu: fits a pocket computer", run(c) and c.reboots == 1)
end

-- The real image, if it's been built -------------------------------------------------------------

local real = readHost("dist/zos.zi")
if real then
  local c = computer(withImage({}, real), { 1 })
  check("real image: installs", run(c) and c.reboots == 1)
  check("real image: complete", c.files[".zos/sys/recovery.lua"] and c.files[".zos/apps/appman/app.manifest"])
else
  print("Skipping the real image: run ./package first.")
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
