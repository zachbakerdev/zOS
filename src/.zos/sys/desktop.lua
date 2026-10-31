-- The desktop: lists the apps, Settings, and how to leave. Returns when the user logs out.

local apps = require("apps")
local system = require("system")
local ui = require("ui")
local update = require("update")

local session = ...

local function status()
    return session.user .. (session.admin and " (admin)" or "")
end

local function showError(app, err)
    system.log(app.name .. " crashed: " .. tostring(err))
    ui.message(app.name, app.name .. " crashed:\n\n" .. tostring(err), ui.theme.bad)
end

local function settings()
    local path = system.ROOT .. "/sys/settings.lua"
    local fn, err = load(require("util").readFile(path) or "", "@" .. path, "t", _ENV)
    if fn then fn(session) else error(err, 0) end
end

local selected = 1
while true do
    local list = apps.list()
    local items, actions = {}, {}
    local function add(item, action)
        items[#items + 1] = item
        actions[#items] = action
    end

    for _, app in ipairs(list) do
        add({ label = app.name, hint = app.description }, function()
            local ok, err = apps.launch(app, session)
            if not ok then showError(app, err) end
        end)
    end
    add({ label = "Settings", hint = "Passwords, users, network and updates" }, settings)
    add({ label = "Log out", hint = "Return to the login screen", fg = ui.theme.dim }, "logout")
    local staged = update.stagedVersion()
    add({ label = staged and ("Reboot (installs " .. staged .. ")") or "Reboot", fg = ui.theme.dim }, system.reboot)
    add({ label = "Shut down", fg = ui.theme.dim }, system.shutdown)

    selected = ui.menu({ title = "zOS", status = status, items = items, selected = selected })
    local action = actions[selected]
    if action == "logout" then return end
    local ok, err = pcall(action)
    if not ok then
        system.log("Desktop: " .. tostring(err))
        ui.message("zOS", tostring(err), ui.theme.bad)
    end
end
