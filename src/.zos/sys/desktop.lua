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

-- A menu item for each app this session can open, either the built-in ones or all the others.
local function appItems(builtin)
    local items = {}
    for _, app in ipairs(apps.list()) do
        if app.protected == builtin and apps.canRun(app, session) then
            items[#items + 1] = { label = app.name, hint = app.description, action = function()
                local ok, err = apps.launch(app, session)
                if not ok then showError(app, err) end
            end }
        end
    end
    return items
end

local function appsMenu()
    local selected = 1
    while true do
        local items = appItems(false)
        if #items == 0 then items[1] = { label = "No apps installed", fg = ui.theme.dim } end
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }
        selected = ui.menu({ title = "Apps", status = status, items = items, selected = selected, back = true })
        if not selected or not items[selected].action then return end
        items[selected].action()
    end
end

local selected = 1
while true do
    local items = { { label = "Apps", hint = "Apps you've installed", submenu = true, action = appsMenu } }
    local function add(item, action)
        item.action = action
        items[#items + 1] = item
    end

    for _, item in ipairs(appItems(true)) do items[#items + 1] = item end
    add({ label = "Settings", hint = "Passwords, users, security and updates" }, settings)
    add({ label = "Log out", hint = "Return to the login screen", fg = ui.theme.dim }, "logout")
    local staged = update.stagedVersion()
    add({ label = staged and ("Reboot (installs " .. staged .. ")") or "Reboot", fg = ui.theme.dim }, system.reboot)
    add({ label = "Shut down", fg = ui.theme.dim }, system.shutdown)

    selected = ui.menu({ title = "zOS", status = status, items = items, selected = selected })
    local action = items[selected].action
    if action == "logout" then return end
    local ok, err = pcall(action)
    if not ok then
        system.log("Desktop: " .. tostring(err))
        ui.message("zOS", tostring(err), ui.theme.bad)
    end
end
