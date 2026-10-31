-- The login screen. Returns a session, or nil to show it again.

local auth = require("auth")
local system = require("system")
local ui = require("ui")

local why
while true do
    local label = os.getComputerLabel()
    ui.screen("zOS " .. system.VERSION, label or ("Computer " .. os.getComputerID()))
    ui.text("Log in.", ui.theme.dim)
    ui.text("")
    if why then ui.text(why, ui.theme.bad) ui.text("") end

    local left = auth.lockRemaining()
    if left > 0 then
        ui.text(("Login is locked for %d seconds."):format(math.ceil(left / 1000)), ui.theme.bad)
        local timer = os.startTimer(1)
        repeat
            local _, id = os.pullEventRaw("timer")
        until id == timer
        why = nil
    else
        local name = ui.input("Name")
        local password = ui.input("Password", "*")
        ui.text("Checking...", ui.theme.dim)
        local ok, err = auth.attempt(name, password)
        if ok then
            local session = auth.session(name, password)
            if session.keyReplaced then
                ui.message("zOS", "Your encryption key couldn't be opened, so you have a new one. " ..
                    "Anything encrypted with the old key can't be read for now. It was kept at " ..
                    session.keyReplaced .. ".", ui.theme.bad)
            end
            return session
        end
        why = err
    end
end
