-- zOS setup tool. Installs zOS from this disk onto the computer.
-- Run it with `disk/install`, or boot a fresh computer with this disk inserted.
-- `install --delete-source` removes the setup files once installed. The single-file
-- installer (tools/package.py) uses it for the temporary folder it unpacks into.

local SOURCE = fs.getDir(shell.getRunningProgram()) -- e.g. "disk"
local DELETE_SOURCE = ({ ... })[1] == "--delete-source" and fs.getDrive(SOURCE) == "hdd" -- never a floppy
local PAYLOAD = fs.combine(SOURCE, "payload")
local BACKUP = "/zos-backup"

-- Load the zOS libraries straight from the disk.
local cache = {}
local function import(name)
  if cache[name] == nil then
    local path = fs.combine(PAYLOAD, "zos/lib/" .. name .. ".lua")
    cache[name] = assert(loadfile(path, nil, _G))(import)
  end
  return cache[name]
end

if not fs.exists(fs.combine(PAYLOAD, "zos/boot.lua")) then
  printError("Setup files not found in " .. PAYLOAD)
  return
end

local ui, auth, apps = import("ui"), import("auth"), import("apps")

-- Load every other library now, so a broken file stops setup before it has
-- changed anything on this computer.
local keys
do
  local ok, err = pcall(function()
    keys = import("keys") -- also loads crypto
  end)
  if not ok then
    printError("Setup files on this disk are damaged:")
    printError(tostring(err))
    print("Nothing was changed on this computer.")
    return
  end
end

local function readVersion()
  local f = fs.open(fs.combine(PAYLOAD, "zos/boot.lua"), "r")
  local text = f.readAll()
  f.close()
  return text:match('VERSION = "([^"]+)"') or "?"
end

local VERSION = readVersion()
local TITLE = "zOS Setup " .. VERSION
local installed = fs.exists("/zos/boot.lua")

local function screen(step)
  ui.screen(TITLE, step)
  ui.text("")
end

------------------------------------------------------------------------------
-- 1. Welcome / choose mode
------------------------------------------------------------------------------

local mode -- "install", "upgrade" or "reinstall"
do
  local items
  if installed then
    items = {
      { label = "Upgrade zOS", hint = "Replace system files, keep users and apps", mode = "upgrade" },
      { label = "Clean reinstall", hint = "Delete all users and set up from scratch", mode = "reinstall" },
      { label = "Cancel", fg = ui.theme.dim },
    }
  else
    items = {
      { label = "Install zOS", hint = "Install zOS on computer #" .. os.getComputerID(), mode = "install" },
      { label = "Cancel", fg = ui.theme.dim, hint = "Exit to the CraftOS shell" },
    }
  end
  local choice = ui.menu({ title = TITLE, items = items })
  mode = items[choice].mode
  if not mode then
    term.clear()
    term.setCursorPos(1, 1)
    print("Setup cancelled.")
    return
  end
end

------------------------------------------------------------------------------
-- 2. Account, label and options
------------------------------------------------------------------------------

local username, password
if mode ~= "upgrade" then
  local function intro()
    screen("Account")
    ui.text("Create the administrator account. You will need it to log in.", ui.theme.dim)
    ui.text("")
  end
  username = ui.newUsername(auth.validName, intro, "admin")
  password = ui.newPassword(auth.checkPassword, function()
    intro()
    ui.text("Username: " .. username, ui.theme.dim)
    ui.text("")
  end)
end

screen("Computer")
ui.text("Give this computer a label (optional). It is shown on the login screen.", ui.theme.dim)
ui.text("")
local label = ui.input("Computer label", nil, os.getComputerLabel())

------------------------------------------------------------------------------
-- 3. Confirm
------------------------------------------------------------------------------

screen("Ready")
ui.text("Setup will:", ui.theme.accent)
if mode == "install" then
  ui.text("- back up any existing startup files to " .. BACKUP)
end
ui.text("- " .. (mode == "upgrade" and "replace" or "install") .. " the zOS system files")
if mode == "reinstall" then ui.text("- delete ALL existing user accounts", ui.theme.bad) end
if username then ui.text("- create administrator '" .. username .. "'") end
ui.text(mode == "upgrade" and "- keep your secure boot setting" or "- turn on secure boot (no booting from disks)")
ui.text("")
if not ui.confirm("Continue?") then
  print()
  print("Setup cancelled. Nothing was changed.")
  return
end

------------------------------------------------------------------------------
-- 4. Install
------------------------------------------------------------------------------

os.pullEvent = os.pullEventRaw -- don't allow Ctrl+T to leave a half-installed system
screen("Installing")

local function step(text, fn)
  ui.text("* " .. text .. "...")
  fn()
  sleep(0.1)
end

if mode == "install" then
  step("Backing up startup files", function()
    for _, name in ipairs({ "startup", "startup.lua" }) do
      if fs.exists(name) then
        fs.makeDir(BACKUP)
        local dest = fs.combine(BACKUP, name)
        if fs.exists(dest) then fs.delete(dest) end
        fs.move(name, dest)
      end
    end
  end)
end

step("Copying system files", function()
  if fs.exists("/zos") then fs.delete("/zos") end
  fs.copy(fs.combine(PAYLOAD, "zos"), "/zos")
  if fs.exists("/startup.lua") then fs.delete("/startup.lua") end
  fs.copy(fs.combine(PAYLOAD, "startup.lua"), "/startup.lua")
  fs.makeDir(apps.USER_DIR)
end)

if username then
  step("Creating account '" .. username .. "'", function()
    auth.reset()
    keys.reset() -- old encryption keys belong to the old accounts
    if fs.exists("/etc/zos/config") then fs.delete("/etc/zos/config") end -- back to defaults: secure boot on
    assert(auth.create(username, password, true))
  end)
end

step("Setting computer label", function()
  os.setComputerLabel(label ~= "" and label or nil)
end)

-- Secure boot is on unless an admin turned it off in Settings (kept on upgrade).
local function secureBootWanted()
  if not fs.exists("/etc/zos/config") then return true end
  local f = fs.open("/etc/zos/config", "r")
  local config = textutils.unserialise(f.readAll())
  f.close()
  return type(config) ~= "table" or config.secureBoot ~= false
end

step(secureBootWanted() and "Enabling secure boot" or "Keeping secure boot off", function()
  settings.set("shell.allow_disk_startup", not secureBootWanted())
  settings.set("shell.allow_startup", true)
  settings.set("motd.enable", false)
  settings.save(".settings")
end)

------------------------------------------------------------------------------
-- 5. Finish
------------------------------------------------------------------------------

-- Eject the setup disk so it isn't left in the drive.
for _, side in ipairs(peripheral.getNames()) do
  if disk.isPresent(side) and disk.getMountPath(side) == SOURCE then
    disk.eject(side)
  end
end

if DELETE_SOURCE then fs.delete(SOURCE) end

ui.text("")
ui.text("zOS " .. VERSION .. " is installed!", ui.theme.good)
if not DELETE_SOURCE then ui.text("The setup disk has been ejected.", ui.theme.dim) end
ui.waitEnter("Press Enter to reboot.")
os.reboot()
while true do os.pullEventRaw() end
