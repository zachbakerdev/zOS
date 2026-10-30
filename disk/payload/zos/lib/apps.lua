--[[ zOS apps: .app packages, installing, removing and running them.

An app is installed as /apps/<id>/, holding:

  app.manifest   { name = "Notes", description = "...", version = "1.0", priority = 10, author = "..." }
  main.lua       run from the desktop with `...` = session, app
  service.lua    optional: started at boot with `...` = app, runs in the background
  ...            any other files the app needs

Apps are distributed as .app files (made by tools/make_apps.py): one serialised table,

  { format = "zos-app", formatVersion = 1, id = "notes", files = { ["main.lua"] = "...", ... } }

App code can require its own modules (from its folder) and the zOS system
libraries such as "ui". Apps with a lower priority are listed first. Installing
replaces the app's folder, so apps should keep their data somewhere else. ]]

local util = require("util")
local system = require("system")
local services = require("services")

local apps = {}

apps.DIR = "/apps"
apps.FORMAT_VERSION = 1
apps.DEFAULT_PRIORITY = 100
-- Built-in apps that can be upgraded but not removed.
apps.PROTECTED = { appman = true }

function apps.validId(id)
    return type(id) == "string" and id:match("^[a-z0-9_%-]+$") ~= nil and #id <= 32
end

-- A relative path made of plain names: no "..", no hidden files, no leading "/".
local function validPath(path)
    if type(path) ~= "string" or path == "" or #path > 128 then return false end
    for part in (path .. "/"):gmatch("(.-)/") do
        if not part:match("^[%w_%-][%w_%.%-]*$") then return false end
    end
    return true
end

-- Must match check_manifest in tools/make_apps.py.
local function checkManifest(m)
    if type(m) ~= "table" then return false, "app.manifest isn't a table" end
    if type(m.name) ~= "string" or m.name:match("^%s*$") then return false, "app.manifest has no name" end
    if type(m.version) ~= "string" or m.version:match("^%s*$") then return false, "app.manifest has no version" end
    for _, key in ipairs({ "description", "author" }) do
        if m[key] ~= nil and type(m[key]) ~= "string" then return false, "app.manifest's " .. key .. " isn't text" end
    end
    if m.priority ~= nil and type(m.priority) ~= "number" then return false, "app.manifest's priority isn't a number" end
    return true
end

local function info(id, dir, m)
    local service = fs.combine(dir, "service.lua")
    return {
        id = id,
        name = m.name,
        description = m.description or "",
        version = m.version,
        author = m.author,
        priority = m.priority or apps.DEFAULT_PRIORITY,
        dir = "/" .. dir,
        main = "/" .. fs.combine(dir, "main.lua"),
        service = (fs.exists(service) and not fs.isDir(service)) and ("/" .. service) or nil,
        protected = apps.PROTECTED[id] == true,
    }
end

------------------------------------------------------------------------------
-- Packages
------------------------------------------------------------------------------

-- Check and unpack the text of a .app file. Returns a package
-- { id, manifest, files, count, size }, or nil and an error message.
function apps.parse(text)
    local pkg = type(text) == "string" and textutils.unserialize(text)
    if type(pkg) ~= "table" or pkg.format ~= "zos-app" then return nil, "This isn't a .app file." end
    if pkg.formatVersion ~= apps.FORMAT_VERSION then
        return nil, "This app was packaged for a different version of zOS (format " ..
            tostring(pkg.formatVersion) .. ")."
    end
    if not apps.validId(pkg.id) then return nil, "The app has an invalid id." end
    if type(pkg.files) ~= "table" then return nil, "The app has no files." end

    local count, size = 0, 0
    for path, data in pairs(pkg.files) do
        if not validPath(path) or type(data) ~= "string" then
            return nil, "The app contains a bad file name: " .. tostring(path)
        end
        count, size = count + 1, size + #data
    end
    if not pkg.files["main.lua"] then return nil, "The app has no main.lua." end
    for _, name in ipairs({ "main.lua", "service.lua" }) do
        if pkg.files[name] then
            local ok, err = load(pkg.files[name], "=" .. pkg.id .. "/" .. name, "t", {})
            if not ok then return nil, "The app's " .. name .. " is broken: " .. tostring(err) end
        end
    end

    local manifest = textutils.unserialize(pkg.files["app.manifest"] or "")
    local ok, err = checkManifest(manifest)
    if not ok then return nil, err end

    return { id = pkg.id, manifest = manifest, files = pkg.files, count = count, size = size }
end

function apps.readPackage(path)
    if not fs.exists(path) or fs.isDir(path) then return nil, "No file at " .. path end
    local f = fs.open(path, "rb")
    local text = f.readAll()
    f.close()
    return apps.parse(text)
end

-- Download a .app file. `source` is a URL or a Pastebin code.
function apps.download(source)
    if not http then return nil, "The HTTP API is disabled on this server." end
    local url = source
    if not source:match("^https?://") then
        url = "https://pastebin.com/raw/" .. textutils.urlEncode(source)
    end
    local res, err = http.get(url, nil, true)
    if not res then return nil, "Download failed: " .. tostring(err) end
    local text = res.readAll()
    res.close()
    return apps.parse(text)
end

------------------------------------------------------------------------------
-- Installed apps
------------------------------------------------------------------------------

-- Every installed app, lowest priority first.
function apps.list()
    local found = {}
    if not fs.isDir(apps.DIR) then return found end
    for _, id in ipairs(fs.list(apps.DIR)) do
        local dir = fs.combine(apps.DIR, id)
        local m = apps.validId(id) and util.readTable(fs.combine(dir, "app.manifest"))
        if m and checkManifest(m) and fs.exists(fs.combine(dir, "main.lua")) then
            found[#found + 1] = info(id, dir, m)
        end
    end
    table.sort(found, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a.name:lower() < b.name:lower()
    end)
    return found
end

function apps.get(id)
    if not apps.validId(id) then return nil end
    local dir = fs.combine(apps.DIR, id)
    local m = util.readTable(fs.combine(dir, "app.manifest"))
    if m and checkManifest(m) then return info(id, dir, m) end
end

-- Compare version strings by their numbers: -1 if a is older than b, 0 if equal, 1 if newer.
function apps.compareVersions(a, b)
    local function numbers(v)
        local out = {}
        for n in tostring(v):gmatch("%d+") do out[#out + 1] = tonumber(n) end
        return out
    end
    local x, y = numbers(a), numbers(b)
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p < q and -1 or 1 end
    end
    return 0
end

-- The environment app code runs in. `require` finds the app's own modules first,
-- then the system libraries, which are shared with zOS.
local function environment(app)
    local env = setmetatable({ shell = shell }, { __index = _G })
    local localRequire, package = require("cc.require").make(env, app.dir)
    env.package = package
    env.require = function(name)
        local rel = name:gsub("%.", "/")
        local own = fs.combine(app.dir, rel)
        if fs.exists(own .. ".lua") or fs.exists(fs.combine(own, "init.lua")) then
            return localRequire(name)
        end
        return require(name)
    end
    return env
end

function apps.startService(app)
    if not app.service then return false end
    local fn, err = loadfile(app.service, nil, environment(app))
    if not fn then
        system.log("service '" .. app.id .. "' failed to load: " .. tostring(err))
        return false, err
    end
    services.start(app.id, fn, app)
    return true
end

-- Start the services of every installed app, in priority order.
function apps.startServices()
    for _, app in ipairs(apps.list()) do apps.startService(app) end
end

-- Install (or replace) a package from apps.parse. Returns the installed app, or nil and an error.
function apps.install(pkg)
    local dest = fs.combine(apps.DIR, pkg.id)
    local tmp = fs.combine(apps.DIR, ".installing-" .. pkg.id)
    if fs.exists(tmp) then fs.delete(tmp) end

    -- Write everything to a temporary folder first, so a full disk leaves the old version intact.
    local ok, err = pcall(function()
        for path, data in pairs(pkg.files) do
            local full = fs.combine(tmp, path)
            fs.makeDir(fs.getDir(full))
            local f, openErr = fs.open(full, "wb")
            if not f then error("Can't write " .. path .. ": " .. tostring(openErr), 0) end
            f.write(data)
            f.close()
        end
    end)
    if not ok then
        if fs.exists(tmp) then fs.delete(tmp) end
        return nil, tostring(err)
    end

    services.stop(pkg.id)
    if fs.exists(dest) then fs.delete(dest) end
    fs.move(tmp, dest)

    local app = apps.get(pkg.id)
    apps.startService(app)
    return app
end

function apps.remove(id)
    local app = apps.get(id)
    if not app then return nil, "'" .. tostring(id) .. "' isn't installed." end
    if app.protected then return nil, app.name .. " is part of zOS and can't be removed." end
    services.stop(id)
    fs.delete(fs.combine(apps.DIR, id))
    return true
end

-- Run an app's main.lua. Returns false and the error if it crashed.
function apps.launch(app, session)
    local fn, err = loadfile(app.main, nil, environment(app))
    if not fn then return false, err end

    local screen = term.current()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    local ok, runErr = pcall(fn, session, app)
    term.redirect(screen)
    term.setCursorBlink(false)
    return ok, runErr
end

return apps
