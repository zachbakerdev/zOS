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

local ctx = { shell = shell, require = require }

local ok, err = false, "boot.lua is missing"
local boot = loadfile("/zos/boot.lua", nil, _G)
if boot then ok, err = pcall(boot, ctx) end

-- Only reached if boot crashed. Offer an admin-only recovery shell.
term.redirect(term.native())
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("zOS failed to start:")
printError(tostring(err))
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
