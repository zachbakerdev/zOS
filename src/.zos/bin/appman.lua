-- appman: install and manage apps from the Terminal. See specs/APPMAN.md.

local ctx = _G.zos
if not ctx then error("appman only runs in the zOS Terminal.", 0) end
local apps, update, system = ctx.require("apps"), ctx.require("update"), ctx.require("system")

local USAGE = [[
appman list                   Show installed apps
appman available              Show apps in the release
appman install <source> [-y]  Install an app
appman update [<id>...] [-y]  Update apps
appman remove <id> [-y]       Remove an app
appman help                   Show this list]]

local args, yes = {}, false
for _, arg in ipairs({ ... }) do
    if arg == "-y" or arg == "--yes" then
        yes = true
    elseif arg:sub(1, 1) == "-" then
        print(USAGE)
        error("Unknown option: " .. arg, 0)
    else
        args[#args + 1] = arg
    end
end

local function needAdmin(verb)
    if not ctx.admin then error("Only administrators can " .. verb .. " apps.", 0) end
end

local function ask(question)
    if yes then return true end
    write(question .. " (y/n) ")
    return (read() or ""):lower():sub(1, 1) == "y"
end

local function log(text)
    system.log(ctx.user .. " " .. text)
end

local function entryStatus(entry)
    if not entry.supported then return "needs zOS " .. entry.minZos end
    if entry.newer then return "update from " .. entry.current end
    if not entry.current then return "new" end
    if apps.compareVersions(entry.version, entry.current) < 0 then return "older than installed" end
    return "installed"
end

local function packageStatus(pkg)
    local current = apps.get(pkg.id)
    if not current then return "new" end
    local cmp = apps.compareVersions(pkg.manifest.version, current.version)
    if cmp > 0 then return "update from " .. current.version end
    if cmp < 0 then return "older than installed" end
    return "installed"
end

local function showPackage(pkg)
    local m = pkg.manifest
    print(m.name .. " " .. m.version .. "  (" .. packageStatus(pkg) .. ")")
    print("id: " .. pkg.id .. (m.author and ("   by " .. m.author) or ""))
    print(pkg.count .. " files, " .. ("%.1f KB"):format(pkg.size / 1024))
    if m.description and m.description ~= "" then print(m.description) end
    print("")
    if pkg.files["service.lua"] then
        print("This app runs in the background, even when nobody is logged in.")
    end
    print("Apps can read and change every file on this computer. Only install apps you trust.")
end

local function install(pkg)
    local app, err = apps.install(pkg)
    if not app then error(err, 0) end
    log("installed app " .. app.id .. " " .. app.version)
    print("Installed " .. app.name .. " " .. app.version .. ". It is " ..
        (app.protected and "on the desktop." or "in the Apps menu."))
end

-- The latest release's entry for an id, or nil and a reason.
local function releaseEntry(list, id)
    for _, entry in ipairs(list) do
        if entry.id == id then return entry end
    end
    return nil, id .. " isn't in the release."
end

local function getPackage(source)
    if source:match("^https?://") then return apps.download(source) end
    if source:sub(1, 9) == "pastebin:" then return apps.download(source:sub(10)) end
    return apps.readPackage(shell.resolve(source))
end

local function installFromSource(source)
    needAdmin("install")
    local pkg, err
    if apps.validId(source) then
        local list, listErr = update.checkApps()
        if not list then error(listErr, 0) end
        local entry, why = releaseEntry(list, source)
        if not entry then error(why, 0) end
        if not entry.supported then error(entry.name .. " needs zOS " .. entry.minZos .. ".", 0) end
        if entry.current and not entry.newer then
            print(entry.name .. " is up to date.")
            return
        end
        pkg, err = update.downloadApp(entry)
        if not pkg then error(err, 0) end
    else
        pkg, err = getPackage(source)
        if not pkg then error(err, 0) end
        if not apps.supports(pkg.manifest.minZos) then
            error(pkg.manifest.name .. " needs zOS " .. pkg.manifest.minZos .. ".", 0)
        end
        local current = apps.get(pkg.id)
        if current and apps.compareVersions(pkg.manifest.version, current.version) < 0 then
            if yes then error("That's older than the installed version.", 0) end
            print("This is older than the installed version.")
        end
    end
    showPackage(pkg)
    if ask("Install it?") then install(pkg) end
end

local function updateApps(ids)
    needAdmin("update")
    local list, err = update.checkApps()
    if not list then error(err, 0) end

    local targets, problems = {}, {}
    if #ids > 0 then
        for _, id in ipairs(ids) do
            local entry, why = releaseEntry(list, id)
            if not entry then
                problems[#problems + 1] = why
            elseif not entry.supported then
                problems[#problems + 1] = entry.name .. " needs zOS " .. entry.minZos .. "."
            elseif entry.newer then
                targets[#targets + 1] = entry
            else
                print(entry.name .. " is up to date.")
            end
        end
    else
        for _, entry in ipairs(list) do
            if entry.newer and entry.supported then targets[#targets + 1] = entry end
        end
        if #targets == 0 then
            print("Everything is up to date.")
            return
        end
        for _, entry in ipairs(targets) do print(entry.id .. " " .. entry.version .. " " .. entryStatus(entry)) end
        if not ask("Install " .. #targets .. " update(s)?") then return end
    end

    for _, entry in ipairs(targets) do
        local pkg, why = update.downloadApp(entry)
        local app = pkg
        if pkg then app, why = apps.install(pkg) end
        if app then
            log("installed app " .. app.id .. " " .. app.version)
            print("Updated " .. app.name .. " to " .. app.version .. ".")
        else
            problems[#problems + 1] = entry.name .. ": " .. tostring(why)
        end
    end
    if #problems > 0 then error(table.concat(problems, "\n"), 0) end
end

local function removeApp(id)
    needAdmin("remove")
    if not id then
        print(USAGE)
        error("Name an app to remove.", 0)
    end
    local app = apps.get(id)
    if not app then error("That app isn't installed.", 0) end
    if not ask("Remove " .. app.name .. "? Its data is kept.") then return end
    local ok, err = apps.remove(id)
    if not ok then error(err, 0) end
    log("removed app " .. id)
    print("Removed " .. app.name .. ". Its data is kept.")
end

local command = args[1]
if command == "list" then
    for _, app in ipairs(apps.list()) do print(app.id .. " " .. app.version .. " " .. app.name) end
elseif command == "available" then
    local list, err = update.checkApps()
    if not list then error(err, 0) end
    for _, entry in ipairs(list) do print(entry.id .. " " .. entry.version .. " " .. entryStatus(entry)) end
elseif command == "install" and args[2] and not args[3] then
    installFromSource(args[2])
elseif command == "update" then
    updateApps({ table.unpack(args, 2) })
elseif command == "remove" then
    removeApp(args[2])
elseif command == "help" then
    print(USAGE)
else
    print(USAGE)
    error("Unknown command.", 0)
end
