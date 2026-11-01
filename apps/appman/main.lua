-- zOS App Manager: install .za images from GitHub, disks, files or the web, and remove apps.
-- Only administrators can install or remove apps, since apps can change any file.

local session = ...
local ui = require("ui")
local apps = require("apps")
local system = require("system")
local update = require("update")

local TITLE = "App Manager"

local function kb(bytes)
    return ("%.1f KB"):format(bytes / 1024)
end

-- How a package compares with what's installed, e.g. "new" or "update from 1.0.0".
local function status(pkg)
    local current = apps.get(pkg.id)
    if not current then
        return apps.supports(pkg.manifest.minZos) and "new" or ("needs zOS " .. pkg.manifest.minZos)
    end
    local cmp = apps.compareVersions(pkg.manifest.version, current.version)
    if not apps.supports(pkg.manifest.minZos) then return "needs zOS " .. pkg.manifest.minZos end
    if cmp > 0 then return "update from " .. current.version end
    if cmp < 0 then return "older than installed " .. current.version end
    return "installed"
end

-- Newer versions of zOS are in Settings, for anyone who can install them.
local function needsZos(name, minZos)
    ui.message(TITLE, name .. " needs zOS " .. minZos .. " or newer, and this computer has zOS " ..
        system.VERSION .. ". Check Settings > Updates.", ui.theme.bad)
end

local function install(pkg)
    local m = pkg.manifest
    if not session.admin then
        return ui.message(TITLE, "Only administrators can install apps.", ui.theme.bad)
    end
    if not apps.supports(m.minZos) then return needsZos(m.name, m.minZos) end

    ui.screen(TITLE)
    ui.text(m.name .. " " .. m.version .. "  (" .. status(pkg) .. ")", ui.theme.accent)
    ui.text("id: " .. pkg.id .. (m.author and ("   by " .. m.author) or ""), ui.theme.dim)
    ui.text(pkg.count .. " files, " .. kb(pkg.size), ui.theme.dim)
    ui.text("")
    if m.description and m.description ~= "" then
        ui.text(m.description)
        ui.text("")
    end
    if pkg.files["service.lua"] then
        ui.text("This app runs in the background, even when nobody is logged in.", ui.theme.accent)
    end
    ui.text("Apps can read and change every file on this computer. Only install apps you trust.", ui.theme.dim)
    ui.text("")
    local current = apps.get(pkg.id)
    if current and current.protected and apps.compareVersions(m.version, current.version) < 0 then
        ui.text("This is older than the version that came with zOS.", ui.theme.bad)
    end
    if not ui.confirm(current and "Replace the installed version?" or "Install it?") then return end

    local app, err = apps.install(pkg)
    if not app then
        return ui.message(TITLE, "Couldn't install " .. m.name .. ":\n\n" .. err, ui.theme.bad)
    end
    system.log(session.user .. " installed app " .. app.id .. " " .. app.version)
    ui.message(TITLE, "Installed " .. app.name .. " " .. app.version .. ". It is on the desktop.", ui.theme.good)
end

-- Every .za file in the top folder of each floppy.
local function findOnDisks()
    local found = {}
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "drive" and disk.hasData(side) then
            local root = disk.getMountPath(side)
            for _, name in ipairs(fs.list(root)) do
                local path = fs.combine(root, name)
                if name:match("%.za$") and not fs.isDir(path) then
                    local pkg, err = apps.readPackage(path)
                    found[#found + 1] = { path = path, pkg = pkg, err = err }
                end
            end
        end
    end
    return found
end

local function fromDisk()
    ui.screen(TITLE)
    ui.text("Looking for .za files...", ui.theme.dim)
    local found = findOnDisks()
    if #found == 0 then
        return ui.message(TITLE, "No .za files found. Put a floppy with apps on it in a disk drive " ..
            "next to this computer.", ui.theme.bad)
    end

    local items = {}
    for _, entry in ipairs(found) do
        if entry.pkg then
            local m = entry.pkg.manifest
            items[#items + 1] = { label = m.name .. " " .. m.version .. "  (" .. status(entry.pkg) .. ")",
                hint = "/" .. entry.path }
        else
            items[#items + 1] = { label = fs.getName(entry.path) .. "  (can't be read)", hint = entry.err,
                fg = ui.theme.bad }
        end
    end
    items[#items + 1] = { label = "Back", fg = ui.theme.dim }

    local choice = ui.menu({ title = TITLE .. " - Install from disk", items = items, back = true })
    local entry = choice and found[choice]
    if not entry then return end
    if not entry.pkg then return ui.message(TITLE, entry.err, ui.theme.bad) end
    install(entry.pkg)
end

local function fromFile()
    ui.screen(TITLE)
    ui.text("Enter the path of a .za file, e.g. disk/notes.za", ui.theme.dim)
    ui.text("")
    local path = ui.input("Path")
    if path == "" then return end
    local pkg, err = apps.readPackage(fs.combine(path, ""))
    if not pkg then return ui.message(TITLE, err, ui.theme.bad) end
    install(pkg)
end

local function fromWeb()
    ui.screen(TITLE)
    ui.text("Download a .za file. Enter a full URL or a Pastebin code.", ui.theme.dim)
    ui.text("")
    local source = ui.input("URL or Pastebin code")
    if source == "" then return end
    ui.text("Downloading...", ui.theme.dim)
    local pkg, err = apps.download(source)
    if not pkg then return ui.message(TITLE, err, ui.theme.bad) end
    install(pkg)
end

local function githubStatus(entry)
    if not entry.supported then return "needs zOS " .. entry.minZos end
    if entry.newer then return "update from " .. entry.current end
    if not entry.current then return "new" end
    return apps.compareVersions(entry.version, entry.current) < 0 and "older than installed" or "installed"
end

-- Download and install every update without asking about each one.
local function updateAll(updates)
    ui.screen(TITLE .. " - Update all")
    for _, entry in ipairs(updates) do
        ui.text(entry.name .. " " .. entry.version .. "  (" .. githubStatus(entry) .. ")")
    end
    ui.text("")
    if not ui.confirm("Install " .. #updates .. " update(s)?") then return end

    local problems = {}
    for _, entry in ipairs(updates) do
        ui.text("Updating " .. entry.name .. "...", ui.theme.dim)
        local pkg, err = update.downloadApp(entry)
        local app = pkg
        if pkg then app, err = apps.install(pkg) end
        if app then
            system.log(session.user .. " installed app " .. app.id .. " " .. app.version)
        else
            problems[#problems + 1] = entry.name .. ": " .. tostring(err)
        end
    end
    if #problems > 0 then return ui.message(TITLE, table.concat(problems, "\n\n"), ui.theme.bad) end
    ui.message(TITLE, "Everything is up to date.", ui.theme.good)
end

local function fromGitHub()
    ui.screen(TITLE)
    ui.text("Checking GitHub for apps...", ui.theme.dim)
    local list, listErr = update.checkApps()
    if not list then return ui.message(TITLE, listErr, ui.theme.bad) end

    local updates = {}
    for _, entry in ipairs(list) do
        if entry.newer and entry.supported then updates[#updates + 1] = entry end
    end

    local items = {}
    if #updates > 0 then items[1] = { label = "Update all (" .. #updates .. ")", hint = "Install every update" } end
    local first = #items
    for _, entry in ipairs(list) do
        items[#items + 1] = { label = entry.name .. " " .. entry.version .. "  (" .. githubStatus(entry) .. ")",
            hint = entry.description,
            fg = ((entry.current and not entry.newer) or not entry.supported) and ui.theme.dim or nil }
    end
    items[#items + 1] = { label = "Back", fg = ui.theme.dim }

    local choice = ui.menu({ title = TITLE .. " - GitHub", items = items, back = true })
    if choice == nil or choice == #items then return end

    local entry = list[choice - first]
    if entry and not entry.supported then return needsZos(entry.name, entry.minZos) end
    if entry and entry.current and not entry.newer then
        return ui.message(TITLE, entry.name .. " is up to date.", ui.theme.good)
    end
    if not session.admin then
        return ui.message(TITLE, "Only administrators can install apps.", ui.theme.bad)
    end
    if not entry then return updateAll(updates) end
    ui.screen(TITLE)
    ui.text("Downloading " .. entry.name .. "...", ui.theme.dim)
    local pkg, err = update.downloadApp(entry)
    if not pkg then return ui.message(TITLE, err, ui.theme.bad) end
    install(pkg)
end

local function manage(app)
    ui.screen(TITLE)
    ui.text(app.name .. " " .. app.version, ui.theme.accent)
    ui.text("id: " .. app.id .. (app.author and ("   by " .. app.author) or ""), ui.theme.dim)
    ui.text("")
    if app.description ~= "" then
        ui.text(app.description)
        ui.text("")
    end
    if app.service then ui.text("Runs in the background.", ui.theme.dim) ui.text("") end
    if app.protected then
        return ui.message(TITLE, app.name .. " is part of zOS and can't be removed.", ui.theme.dim)
    end
    if not session.admin then
        ui.text("Only administrators can remove apps.", ui.theme.dim)
        return ui.waitEnter()
    end
    if not ui.confirm("Remove " .. app.name .. "?") then return end
    local ok, err = apps.remove(app.id)
    if ok then system.log(session.user .. " removed app " .. app.id) end
    ui.message(TITLE, ok and ("Removed " .. app.name .. ".") or err, ok and ui.theme.good or ui.theme.bad)
end

local function installed()
    local selected = 1
    while true do
        local list = apps.list()
        local items = {}
        for _, app in ipairs(list) do
            items[#items + 1] = { label = app.name .. " " .. app.version, hint = app.description }
        end
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }
        selected = ui.menu({ title = TITLE .. " - Installed apps", items = items, selected = selected, back = true })
        if selected == nil or not list[selected] then return end
        manage(list[selected])
    end
end

local selected = 1
while true do
    local items = {
        { label = "Get apps from GitHub", hint = "Install and update apps, needs the HTTP API", action = fromGitHub },
        { label = "Install from disk", hint = "Find .za files on floppy disks", action = fromDisk },
        { label = "Install from file...", hint = "Enter the path of a .za file", action = fromFile },
        { label = "Install from URL or Pastebin...", hint = "Needs the HTTP API", action = fromWeb },
        { label = "Installed apps (" .. #apps.list() .. ")", hint = "View or remove apps", action = installed },
        { label = "Back", fg = ui.theme.dim },
    }
    selected = ui.menu({ title = TITLE, items = items, selected = selected, back = true })
    if selected == nil or not items[selected].action then return end
    items[selected].action()
end
