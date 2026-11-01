-- Finds, checks, installs, removes and runs apps. See specs/libs/APPS.md.

local builtin = require("builtin")
local image = require("image")
local services = require("services")
local system = require("system")
local util = require("util")

local apps = {
    DIR = "/.zos/apps",
    FORMAT_VERSION = 1,
    METADATA = "za:metadata",
    PROTECTED = {},
}

for _, id in ipairs(builtin) do apps.PROTECTED[id] = true end

-- Ids and paths --------------------------------------------------------------------------------

function apps.validId(id)
    return type(id) == "string" and #id >= 1 and #id <= 32 and id:match("^[a-z0-9_%-]+$") ~= nil and id ~= "zos"
end

function apps.validPath(path)
    if type(path) ~= "string" or #path < 1 or #path > 128 or path:sub(-1) == "/" then return false end
    for part in (path .. "/"):gmatch("(.-)/") do
        if not part:match("^[%w_%-][%w_%.%-]*$") then return false end
    end
    return true
end

-- Versions -------------------------------------------------------------------------------------

-- Every version is major.minor.patch. Keep this the same as VERSION in tools/make_apps.py.
local function versionParts(version)
    if type(version) ~= "string" then return nil end
    local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)$")
    if not major then return nil end
    return { tonumber(major), tonumber(minor), tonumber(patch) }
end

function apps.validVersion(version)
    return versionParts(version) ~= nil
end

function apps.compareVersions(a, b)
    local x = versionParts(a) or error("Not a version: " .. tostring(a), 2)
    local y = versionParts(b) or error("Not a version: " .. tostring(b), 2)
    for i = 1, 3 do
        if x[i] < y[i] then return -1 end
        if x[i] > y[i] then return 1 end
    end
    return 0
end

function apps.supports(minZos)
    return minZos == nil or apps.compareVersions(system.VERSION, minZos) >= 0
end

-- Manifests. Keep this the same as check_manifest in tools/make_apps.py.
local function checkManifest(m)
    if type(m) ~= "table" then return nil, "The manifest isn't a table." end
    if type(m.name) ~= "string" or not m.name:match("%S") then return nil, "The manifest has no name." end
    if not apps.validVersion(m.version) then return nil, "The manifest's version isn't like 1.0.0." end
    for _, field in ipairs({ "description", "author" }) do
        if m[field] ~= nil and type(m[field]) ~= "string" then
            return nil, "The manifest's " .. field .. " isn't text."
        end
    end
    if m.minZos ~= nil and not apps.validVersion(m.minZos) then
        return nil, "The manifest's minZos isn't like 1.0.0."
    end
    if m.admin ~= nil and type(m.admin) ~= "boolean" then return nil, "The manifest's admin isn't true or false." end
    return m
end

-- Packages -------------------------------------------------------------------------------------

function apps.parse(text)
    if type(text) ~= "string" then return nil, "This isn't a .za file." end
    local contents = textutils.unserialize(text)
    if type(contents) ~= "table" or type(contents[apps.METADATA]) ~= "table" then
        return nil, "This isn't a .za file."
    end
    local metadata = contents[apps.METADATA]
    if metadata.version ~= apps.FORMAT_VERSION then return nil, "This app needs a newer version of zOS." end
    if not apps.validId(metadata.id) then return nil, "The app has an invalid id." end

    local files, count, size = {}, 0, 0
    for path, data in pairs(contents) do
        if path ~= apps.METADATA then
            if not apps.validPath(path) or type(data) ~= "string" then
                return nil, "The app contains a bad file name: " .. tostring(path)
            end
            files[path], count, size = data, count + 1, size + #data
        end
    end
    local clash = image.clash(files)
    if clash then return nil, "The app uses " .. clash .. " as both a file and a folder." end

    if not files["main.lua"] then return nil, "The app has no main.lua." end
    for _, name in ipairs({ "main.lua", "service.lua" }) do
        if files[name] and not load(files[name], "@" .. name, "t", {}) then
            return nil, "The app's " .. name .. " doesn't compile."
        end
    end
    local manifest, err = checkManifest(files["app.manifest"] and textutils.unserialize(files["app.manifest"]))
    if not manifest then return nil, err end

    return { id = metadata.id, manifest = manifest, files = files, count = count, size = size }
end

function apps.readPackage(path)
    if not fs.exists(path) or fs.isDir(path) then return nil, "There's no file at " .. path .. "." end
    local text, err = util.readFile(path)
    if not text then return nil, err end
    return apps.parse(text)
end

function apps.download(source)
    local url = source
    if not source:match("^https?://") then
        url = "https://pastebin.com/raw/" .. textutils.urlEncode(source)
    end
    local text, err = util.get(url, true)
    if not text then return nil, "The download failed: " .. err end
    return apps.parse(text)
end

-- Installed apps -------------------------------------------------------------------------------

local function record(id)
    local dir = apps.DIR .. "/" .. id
    local main = dir .. "/main.lua"
    if not apps.validId(id) or not fs.exists(main) then return nil end
    local manifest = checkManifest(util.readTable(dir .. "/app.manifest"))
    if not manifest then return nil end
    local service = dir .. "/service.lua"
    return {
        id = id,
        name = manifest.name,
        description = manifest.description or "",
        version = manifest.version,
        author = manifest.author,
        minZos = manifest.minZos,
        admin = manifest.admin == true,
        dir = dir,
        main = main,
        service = fs.exists(service) and service or nil,
        protected = apps.PROTECTED[id] == true,
    }
end

function apps.get(id)
    return record(id)
end

function apps.list()
    local out = {}
    if fs.exists(apps.DIR) then
        for _, id in ipairs(fs.list(apps.DIR)) do
            local app = record(id)
            if app then out[#out + 1] = app end
        end
    end
    table.sort(out, function(a, b)
        local x, y = a.name:lower(), b.name:lower()
        if x ~= y then return x < y end
        return a.id < b.id
    end)
    return out
end

-- Changing apps --------------------------------------------------------------------------------

function apps.install(pkg)
    if not apps.supports(pkg.manifest.minZos) then
        return nil, pkg.manifest.name .. " needs zOS " .. pkg.manifest.minZos .. " or newer."
    end
    local free = fs.getFreeSpace("/")
    if type(free) == "number" and free < image.spaceNeeded(pkg.files) then
        return nil, "There isn't enough disk space."
    end

    -- Nothing here yields, so Ctrl+T can't stop it partway.
    local temp = apps.DIR .. "/.installing-" .. pkg.id
    fs.delete(temp)
    for path, data in pairs(pkg.files) do
        local ok, err = util.writeChecked(temp .. "/" .. path, data)
        if not ok then
            fs.delete(temp)
            return nil, "Couldn't write " .. path .. ": " .. tostring(err)
        end
    end

    services.stop(pkg.id)
    local dir = apps.DIR .. "/" .. pkg.id
    fs.delete(dir)
    fs.move(temp, dir)

    local app = record(pkg.id)
    if not app then return nil, "The app was installed but can't be read." end
    if app.service then apps.startService(app) end
    return app
end

function apps.remove(id)
    local app = record(id)
    if not app then return nil, "That app isn't installed." end
    if app.protected then return nil, app.name .. " is part of zOS and can't be removed." end
    services.stop(id)
    fs.delete(app.dir)
    return true
end

-- Running apps ---------------------------------------------------------------------------------

-- Each app's code runs in its own environment, where require looks in its folder first.
local function environment(app)
    local env = setmetatable({}, { __index = _ENV })
    local loaded = {}
    local systemRequire = require

    env.require = function(name)
        if loaded[name] ~= nil then return loaded[name] end
        local relative = name:gsub("%.", "/")
        local path = app.dir .. "/" .. relative .. ".lua"
        if not fs.exists(path) then return systemRequire(name) end
        local fn, err = util.loadFile(path, env)
        if not fn then error(err, 0) end
        local value = fn(name)
        loaded[name] = value == nil and true or value
        return loaded[name]
    end
    return env
end

-- os.pullEvent as CraftOS has it, so that Ctrl+T stops an app. zOS itself runs with the raw one.
local function pullEvent(filter)
    local event = table.pack(os.pullEventRaw(filter))
    if event[1] == "terminate" then error("Terminated", 0) end
    return table.unpack(event, 1, event.n)
end

-- Whether this session may open the app. Services don't depend on it, since they have no user.
function apps.canRun(app, session)
    return not app.admin or session.admin == true
end

function apps.launch(app, session)
    if not apps.canRun(app, session) then return false, "Only administrators can open " .. app.name .. "." end
    local fn, err = util.loadFile(app.main, environment(app))
    if not fn then return false, err end

    local screen = term.current()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)

    local saved = os.pullEvent
    os.pullEvent = pullEvent
    local ok, failure = pcall(fn, session, app)
    os.pullEvent = saved

    term.redirect(screen)
    term.setCursorBlink(false)
    if not ok and failure == "Terminated" then return true end
    if not ok then return false, tostring(failure) end
    return true
end

function apps.startService(app)
    if not app.service then return false end
    local fn, err = util.loadFile(app.service, environment(app))
    if not fn then
        system.log("Service " .. app.id .. " won't load: " .. tostring(err))
        return false
    end
    services.start(app.id, fn, app)
    return true
end

function apps.startServices()
    for _, app in ipairs(apps.list()) do apps.startService(app) end
end

return apps
