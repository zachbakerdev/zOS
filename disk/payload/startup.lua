-- zOS bootstrap, installed as /startup.lua.
--
-- CraftOS runs this from its shell. If it ever returned, the user would be left at
-- an unauthenticated shell prompt, so it never does: it hands control to
-- /zos/boot.lua forever, or falls back to recovery and reboots.

local nativePullEvent = os.pullEvent
os.pullEvent = os.pullEventRaw

local function halt(action)
    action()
    while true do os.pullEventRaw() end
end

-- Must match lib/update.lua.
local UPDATE = "/etc/zos/update"
local STAGED, READY = UPDATE .. "/new", UPDATE .. "/new/ready"
local OLD, BAD, TRIAL, FAILED = UPDATE .. "/old", UPDATE .. "/bad", UPDATE .. "/trial", UPDATE .. "/failed"

-- Swap in an update stored by lib/update.lua. This is done here, before any zOS code has loaded,
-- and every step is a rename. If it's interrupted, running it again at the next boot finishes it.
local function applyUpdate()
    if not fs.exists(READY) then return end
    if fs.exists(STAGED .. "/zos") then
        if not fs.exists(TRIAL) then fs.copy(READY, TRIAL) end
        if fs.exists("/zos") then
            if fs.exists(OLD) then fs.delete(OLD) end
            fs.move("/zos", OLD)
        end
        fs.move(STAGED .. "/zos", "/zos")
    end
    if fs.exists(STAGED .. "/startup.lua") then
        fs.delete("/startup.lua")
        fs.move(STAGED .. "/startup.lua", "/startup.lua")
    end
end

-- The update couldn't boot, so go back to the version before it.
local function rollBack()
    if fs.exists(BAD) then fs.delete(BAD) end
    if fs.exists("/zos") then fs.move("/zos", BAD) end
    fs.move(OLD, "/zos")
    if fs.exists(FAILED) then fs.delete(FAILED) end
    fs.move(TRIAL, FAILED)
    if fs.exists(STAGED) then fs.delete(STAGED) end -- or the next boot would try it again
    local log = fs.open("/etc/zos/system.log", "a")
    if log then
        log.writeLine("update failed to boot, went back to the previous version")
        log.close()
    end
end

local applied, applyErr = pcall(applyUpdate)

local ctx = { shell = shell, require = require }

local ok, err = false, "boot.lua is missing"
local boot = loadfile("/zos/boot.lua", nil, _G)
if boot then ok, err = pcall(boot, ctx) end

if fs.exists(TRIAL) and fs.exists(OLD) and pcall(rollBack) then halt(os.reboot) end

-- Only reached if boot crashed. Offer an admin-only recovery shell.
term.redirect(term.native())
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("zOS failed to start:")
printError(tostring(err))
if not applied then printError("Update failed: " .. tostring(applyErr)) end
print()

local authOk, auth = pcall(function()
    local env = setmetatable({}, { __index = _G })
    env.require, env.package = require("cc.require").make(env, "/zos/lib")
    env.package.path = "/zos/lib/?.lua;" .. env.package.path
    return env.require("auth")
end)

if authOk and auth.hasUsers() and auth.lockRemaining() == 0 then
    print("Log in as an administrator for a recovery shell,")
    print("or leave the username empty to reboot.")
    write("Username: ")
    local name = read()
    if name ~= "" then
        write("Password: ")
        local password = read("*")
        if auth.isAdmin(name) and auth.verify(name, password) then
            auth.recordSuccess()
            os.pullEvent = nativePullEvent
            print("Recovery shell. Type 'exit' to reboot.")
            pcall(shell.run, "shell")
            os.pullEvent = os.pullEventRaw
        else
            auth.recordFailure()
            printError("Access denied.")
            sleep(2)
        end
    end
else
    print("Recovery is unavailable. Rebooting in 5 seconds.")
    sleep(5)
end

halt(os.reboot)
