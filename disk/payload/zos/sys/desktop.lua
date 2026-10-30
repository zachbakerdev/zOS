-- zOS desktop, shown after login. Returns "logout", "reboot" or "shutdown".

local session, run = ...
local ui = require("ui")
local apps = require("apps")
local system = require("system")

local function status()
    return session.user .. "  " .. textutils.formatTime(os.time(), false)
end

-- Installed apps first, then the system items. Rebuilt each time, since apps can be installed or removed.
local function items()
    local list = {}
    for _, app in ipairs(apps.list()) do
        list[#list + 1] = { label = app.name, hint = app.description, app = app }
    end
    for _, item in ipairs({
        { label = "Settings", hint = "Password, keys, users, secure boot and computer label", screen = "settings" },
        { label = "Log out", hint = "Return to the login screen", action = "logout", fg = ui.theme.dim },
        { label = "Reboot", hint = "Restart the computer", action = "reboot", fg = ui.theme.dim },
        { label = "Shut down", hint = "Turn the computer off", action = "shutdown", fg = ui.theme.dim },
    }) do
        list[#list + 1] = item
    end
    return list
end

local selected = 1
while true do
    local list = items()
    selected = ui.menu({ title = "zOS", status = status, items = list, selected = selected })
    local item = list[selected]
    if item.action then return item.action end
    if item.app then
        local ok, err = apps.launch(item.app, session)
        if not ok then
            system.log("app '" .. item.app.id .. "' crashed: " .. tostring(err))
            ui.message(item.app.name, "The app crashed:\n\n" .. tostring(err), ui.theme.bad)
        end
    else
        run(item.screen, session)
    end
end
