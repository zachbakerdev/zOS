-- The bootstrap. It must never return, or the user would be left at an open shell.

os.pullEvent = os.pullEventRaw

local DIR = "/etc/zos/update"
local NEW, OLD = DIR .. "/new", DIR .. "/old"
local READY, TRIAL = DIR .. "/ready", DIR .. "/trial"
local ROLLBACK, FAILED = DIR .. "/rollback", DIR .. "/failed"
local STARTUP = DIR .. "/startup.new"
local SYSTEM = "/.zos"
local APPS = SYSTEM .. "/apps"

local function readFile(path)
    local f = fs.open(path, "rb")
    if not f then return nil end
    local text = f.readAll()
    f.close()
    return text
end

-- Bring a staged update in. Every step is a rename that checks whether it has already happened,
-- so a computer that stops partway finishes the job at its next boot.
local function applyUpdate()
    if not fs.exists(READY) then return end
    if fs.exists(NEW) then
        -- A system next to an old one means no swap is under way: an earlier update never finished.
        if fs.exists(SYSTEM) and fs.exists(OLD) then fs.delete(OLD) end
        if fs.exists(SYSTEM) then fs.move(SYSTEM, OLD) end
        if not fs.exists(SYSTEM) then fs.move(NEW, SYSTEM) end
    end
    -- Installed apps stay with the running system, whichever one that is.
    if fs.exists(OLD .. "/apps") and not fs.exists(APPS) then fs.move(OLD .. "/apps", APPS) end
    fs.delete(TRIAL)
    fs.move(READY, TRIAL)
end

-- Go back to the old version. A marker keeps this going across an interrupted boot.
local function finishRollback()
    if not fs.exists(ROLLBACK) then return end
    if fs.exists(OLD) then
        if fs.exists(APPS) and not fs.exists(OLD .. "/apps") then fs.move(APPS, OLD .. "/apps") end
        fs.delete(SYSTEM)
        fs.move(OLD, SYSTEM)
    end
    fs.delete(STARTUP)
    local version = readFile(ROLLBACK)
    local f = fs.open(FAILED, "wb")
    if f then
        f.write(version or "")
        f.close()
    end
    fs.delete(ROLLBACK)
end

local function bootSystem()
    local text = readFile(SYSTEM .. "/boot.lua")
    if not text then error("The system files are missing.", 0) end
    local env = setmetatable({ shell = shell, multishell = multishell, ccRequire = require },
        { __index = _G })
    local fn, err = load(text, "@/.zos/boot.lua", "t", env)
    if not fn then error(err, 0) end
    fn()
end

local function runRecovery(why)
    local text = readFile(SYSTEM .. "/sys/recovery.lua")
    local fn = text and load(text, "@/.zos/sys/recovery.lua", "t",
        setmetatable({ shell = shell, ccRequire = require }, { __index = _G }))
    if fn then
        pcall(fn, why)
    else
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
        print("zOS can't start:")
        print(tostring(why))
        print("")
        print("Restarting in 10 seconds.")
        local timer = os.startTimer(10)
        repeat
            local _, id = os.pullEventRaw("timer")
        until id == timer
    end
end

local ok, err = pcall(function()
    finishRollback()
    applyUpdate()
end)
if not ok then
    runRecovery(err)
    os.reboot()
end

ok, err = pcall(bootSystem)

-- bootSystem only comes back if the boot failed.
if fs.exists(TRIAL) then
    pcall(function()
        fs.move(TRIAL, ROLLBACK)
        finishRollback()
    end)
    os.reboot()
end
runRecovery(ok and "The system stopped." or err)
os.reboot()

while true do os.pullEventRaw() end
