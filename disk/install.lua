-- zOS setup tool. Installs zOS from this disk onto the computer.
-- Run it with `disk/install`, or boot a fresh computer with this disk inserted.
-- `install --delete-source` removes the setup files once installed (only from a
-- folder on the computer, never a floppy).

local SOURCE = fs.getDir(shell.getRunningProgram())
local DELETE_SOURCE = ({ ... })[1] == "--delete-source" and fs.getDrive(SOURCE) == "hdd"
local PAYLOAD = fs.combine(SOURCE, "payload")
local BUILT_IN_APPS = fs.combine(PAYLOAD, "apps")
local LIB = "/" .. fs.combine(PAYLOAD, "zos/lib")
local BACKUP = "/zos-backup"

if not fs.exists(fs.combine(PAYLOAD, "zos/boot.lua")) then
    printError("Setup files not found in " .. PAYLOAD)
    return
end

-- Load the zOS libraries straight from the disk. Load all of them now, so a
-- broken file stops setup before it has changed anything on this computer.
local env = setmetatable({}, { __index = _G })
env.require, env.package = require("cc.require").make(env, LIB)
env.package.path = LIB .. "/?.lua;" .. env.package.path

local ui, auth, keys, system, apps
local builtIn = {} -- packages for the apps that come with zOS
do
    local ok, err = pcall(function()
        ui, auth, keys, system = env.require("ui"), env.require("auth"), env.require("keys"), env.require("system")
        apps = env.require("apps")
        for _, name in ipairs(fs.exists(BUILT_IN_APPS) and fs.list(BUILT_IN_APPS) or {}) do
            builtIn[#builtIn + 1] = assert(apps.readPackage(fs.combine(BUILT_IN_APPS, name)))
        end
    end)
    if not ok then
        printError("Setup files on this disk are damaged:")
        printError(tostring(err))
        print("Nothing was changed on this computer.")
        return
    end
end

local VERSION = system.VERSION
local TITLE = "zOS Setup " .. VERSION
local installed = fs.exists("/zos/boot.lua")
local fromV1 = installed and not fs.exists("/zos/lib/system.lua")

local function screen(step)
    ui.screen(TITLE, step)
    ui.text("")
end

------------------------------------------------------------------------------
-- 1. Choose what to do
------------------------------------------------------------------------------

local mode -- "install", "upgrade" or "reinstall"
do
    local items
    if installed then
        items = {
            { label = "Upgrade zOS", hint = "Replace system files, keep users and settings", mode = "upgrade" },
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
-- 2. Account and label
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
ui.text("- install the built-in apps")
if fromV1 then
    ui.text("- move your zOS 1 apps to " .. BACKUP .. "/apps-v1; zOS " .. VERSION ..
        " installs apps from .app files instead", ui.theme.dim)
end
ui.text("")
if not ui.confirm("Continue?") then
    print()
    print("Setup cancelled. Nothing was changed.")
    return
end

------------------------------------------------------------------------------
-- 4. Install
------------------------------------------------------------------------------

os.pullEvent = os.pullEventRaw -- don't let Ctrl+T leave a half-installed system
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
end)

if fromV1 and mode == "upgrade" then
    -- zOS 1 kept pinned keys with Mail's data.
    step("Moving pinned keys", function()
        local old, new = "/etc/zos/mail/known_keys", "/etc/zos/known_keys"
        if fs.exists(old) and not fs.exists(new) then fs.move(old, new) end
    end)
end

if fromV1 and fs.exists(apps.DIR) then
    step("Moving zOS 1 apps", function()
        local dest = fs.combine(BACKUP, "apps-v1")
        if fs.exists(dest) then fs.delete(dest) end
        fs.makeDir(BACKUP)
        fs.move(apps.DIR, dest)
    end)
end

step("Installing built-in apps", function()
    for _, pkg in ipairs(builtIn) do assert(apps.install(pkg)) end
end)

if username then
    step("Creating account '" .. username .. "'", function()
        auth.reset()
        keys.reset() -- old encryption keys belong to the old accounts
        system.resetConfig() -- back to defaults: secure boot on
        assert(auth.create(username, password, true))
    end)
end

step("Setting computer label", function()
    os.setComputerLabel(label ~= "" and label or nil)
end)

step(system.secureBootEnabled() and "Enabling secure boot" or "Keeping secure boot off", system.applyBootPolicy)

system.log("zOS " .. VERSION .. " " .. mode .. (mode == "upgrade" and "d" or "ed") ..
    (username and (", administrator " .. username) or ""))

------------------------------------------------------------------------------
-- 5. Finish
------------------------------------------------------------------------------

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
