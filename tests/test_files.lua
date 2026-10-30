-- Drives the real Files app with scripted keys, on a simulated screen.
-- Run from the repository root: luajit tests/test_files.lua
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

local function has(s, text)
  return s:find(text, 1, true) ~= nil
end

local function screenHas(c, text)
  local ok, err = pcall(sim.run, function() return has(c.screenText(), text) end, 30)
  if not ok then
    print("Waiting for '" .. text .. "', the screen says:\n" .. c.screenText())
    error(err, 0)
  end
  return true
end

local function key(c, name) c.env.os.queueEvent("key", c.env.keys[name]) end
local function char(c, ch) c.env.os.queueEvent("char", ch) end
local function line(c, text) c.env.os.queueEvent("sim_line", text) end

-- Move down `n` rows and press Enter on the current menu.
local function pick(c, n)
  for _ = 1, n do key(c, "down") end
  key(c, "enter")
end

local function start(files, width)
  for _, c in pairs(sim.computers) do sim.powerOff(c) end
  local c = sim.computer(1, { files = files, width = width })
  c.edited, c.editorEnv = {}, nil
  c.env.shell = { resolve = function(p) return p end, openTab = function() end, switchTab = function() end }
  c.env.os.run = function(env, program, path)
    c.editorEnv, c.program = env, program
    c.edited[#c.edited + 1] = path
    return true
  end
  local fn = assert(loadfile("apps/files/main.lua"))
  setfenv(fn, c.env)
  c.thread = sim.spawn(c, fn, { user = "me", admin = false }, {})
  return c
end

-- Opens in the home folder, with folders first ----------------------------------

do
  local c = start({ ["home/me/notes.txt"] = "hello", ["home/me/old/a.txt"] = "a", ["home/me/old/b/c.txt"] = "c" })
  check("opens at home", screenHas(c, "/home/me"))
  check("lists the folder", screenHas(c, "old/"))
  check("lists the file", has(c.screenText(), "notes.txt"))
  check("folders come first", c.screenText():find("old/", 1, true) < c.screenText():find("notes.txt", 1, true))

  -- Edit: .., old/, notes.txt
  pick(c, 2)
  check("file actions", screenHas(c, "Rename / move..."))
  key(c, "enter")
  sim.run(function() return #c.edited == 1 end, 30)
  check("edits the file", c.edited[1] == "/home/me/notes.txt")
  check("uses the editor", c.program == "rom/programs/edit.lua")
  check("editor can't open tabs", c.editorEnv.shell.openTab == nil and c.editorEnv.shell.switchTab == nil)
  check("editor keeps the rest of the shell", c.editorEnv.shell.resolve ~= nil)
  check("editor can require", c.editorEnv.require ~= nil)
  check("back in the list", screenHas(c, "[New file]"))

  -- Delete a file: .., old/, notes.txt, then Edit, Copy, Rename, Delete
  pick(c, 0) -- the list remembers notes.txt
  check("actions again", screenHas(c, "Delete"))
  pick(c, 3)
  check("asks first", screenHas(c, "Delete /home/me/notes.txt?"))
  char(c, "n")
  check("n keeps it", screenHas(c, "[New file]") and c.files["home/me/notes.txt"] == "hello")
  pick(c, 0)
  screenHas(c, "Delete")
  pick(c, 3)
  screenHas(c, "Delete /home/me/notes.txt?")
  char(c, "y")
  check("reports it", screenHas(c, "Deleted /home/me/notes.txt."))
  check("file is gone", c.files["home/me/notes.txt"] == nil)
  key(c, "enter")
  check("list updates", screenHas(c, "[New file]") and not has(c.screenText(), "notes.txt"))
end

-- Creating ---------------------------------------------------------------------

do
  local c = start({ ["home/me/keep.txt"] = "x" })
  screenHas(c, "[New file]")
  pick(c, 2) -- .., keep.txt, [New file]
  check("asks for a name", screenHas(c, "File name"))
  line(c, "new.lua")
  sim.run(function() return #c.edited == 1 end, 30)
  check("creates the file", c.files["home/me/new.lua"] == "")
  check("opens it", c.edited[1] == "/home/me/new.lua")

  screenHas(c, "[New folder]")
  pick(c, 3) -- .., keep.txt, new.lua, [New file]
  screenHas(c, "File name")
  line(c, "keep.txt")
  check("won't overwrite", screenHas(c, "/home/me/keep.txt already exists."))
  check("keeps the contents", c.files["home/me/keep.txt"] == "x")
  key(c, "enter")

  screenHas(c, "[New folder]")
  pick(c, 4)
  check("asks for a folder name", screenHas(c, "Folder name"))
  line(c, "stuff")
  check("makes the folder", screenHas(c, "Created /home/me/stuff."))
  check("folder exists", c.env.fs.isDir("home/me/stuff"))
  key(c, "enter")
  check("empty folder is listed", screenHas(c, "stuff/"))

  -- Delete the folder from inside it
  pick(c, 1)
  check("inside the folder", screenHas(c, "/home/me/stuff"))
  screenHas(c, "[This folder...]")
  pick(c, 3) -- .., [New file], [New folder], [This folder...]
  screenHas(c, "Delete")
  pick(c, 2) -- Copy, Rename, Delete
  check("warns about the folder", screenHas(c, "Delete the folder /home/me/stuff"))
  char(c, "y")
  screenHas(c, "Deleted /home/me/stuff.")
  key(c, "enter")
  check("returns to the parent", screenHas(c, "keep.txt"))
  check("folder is gone", not c.env.fs.exists("home/me/stuff"))

  -- Backspace walks up, and quits from the top
  key(c, "backspace")
  check("up a folder", screenHas(c, "me/"))
  key(c, "backspace")
  check("up to the root", screenHas(c, "home/"))
  key(c, "backspace")
  sim.run(function() return c.thread.done end, 30)
  check("quits from the root", c.thread.done)
end

-- Copying and moving -----------------------------------------------------------

do
  local c = start({ ["home/me/a.txt"] = "A", ["home/me/box/x"] = "x" })
  screenHas(c, "a.txt")
  pick(c, 2) -- .., box/, a.txt
  screenHas(c, "Copy to...")
  pick(c, 1)
  check("asks where", screenHas(c, "Copy a.txt to"))
  line(c, "box")
  check("copies into a folder", screenHas(c, "Copied to /home/me/box/a.txt."))
  check("copy has the contents", c.files["home/me/box/a.txt"] == "A" and c.files["home/me/a.txt"] == "A")
  key(c, "enter")

  screenHas(c, "[New file]")
  pick(c, 0)
  screenHas(c, "Copy to...")
  pick(c, 2)
  screenHas(c, "Move a.txt to")
  line(c, "/home/me/b.txt")
  check("moves", screenHas(c, "Moved to /home/me/b.txt."))
  check("moved", c.files["home/me/b.txt"] == "A" and c.files["home/me/a.txt"] == nil)
  key(c, "enter")
end

-- Read-only files, system files and folders that vanish ------------------------

do
  local files = { ["rom/programs/edit.lua"] = "e", ["zos/boot.lua"] = "b", ["startup.lua"] = "s" }
  local c = start(files) -- no home folder, so it opens at the root
  check("opens at the root", screenHas(c, "rom/"))
  check("no [This folder...] at the root", not has(c.screenText(), "This folder"))
  pick(c, 3) -- etc/, rom/, zos/, startup.lua
  screenHas(c, "Delete")
  pick(c, 3)
  check("warns about system files", screenHas(c, "is part of zOS"))
  char(c, "n")
  screenHas(c, "[New file]")

  key(c, "home")
  pick(c, 1) -- rom/
  check("in rom", screenHas(c, "programs/"))
  check("can't create in rom", not has(c.screenText(), "[New file]"))
  pick(c, 1)
  screenHas(c, "edit.lua")
  pick(c, 1)
  check("read-only files are viewed", screenHas(c, "View"))
  check("and can't be deleted", not has(c.screenText(), "Delete"))
  check("or moved", not has(c.screenText(), "Rename"))
end

do
  local c = start({ ["home/me/box/x"] = "x", ["home/me/why.txt"] = "y" })
  screenHas(c, "box/")
  pick(c, 1)
  check("into the folder", screenHas(c, "/home/me/box"))
  screenHas(c, "[New folder]")
  c.env.fs.delete("home/me/box")
  pick(c, 3) -- .., x, [New file], [New folder], on the menu drawn before it went
  screenHas(c, "Folder name")
  line(c, "") -- cancelling lists the folder again
  check("a vanished folder falls back to its parent", screenHas(c, "why.txt"))
  check("still running", not c.thread.done)
end

-- A pocket computer's screen ---------------------------------------------------

do
  local c = start({ ["home/me/a-file-with-a-rather-long-name.txt"] = "x" }, 26)
  check("pocket list", screenHas(c, "a-file-with-a"))
  pick(c, 2) -- .., the file, [New file]
  check("pocket prompt wraps", screenHas(c, "File name"))
end

if failed > 0 then
  print(("%d passed, %d FAILED"):format(passed, failed))
  os.exit(1)
end
print(("files: all %d passed"):format(passed))
