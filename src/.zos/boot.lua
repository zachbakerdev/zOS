-- The boot sequence: boot policy, libraries, networking, updates and services, then sessions.

local ROOT = "/.zos"

-- System libraries are shared, so that every app gets the same services and apps that booted the
-- computer. Each loads once, in an environment that shares this require.
local libEnv = setmetatable({}, { __index = _ENV })
local loaded = {}

local function readFile(path)
    local f = fs.open(path, "rb")
    if not f then return nil end
    local text = f.readAll()
    f.close()
    return text
end

function libEnv.require(name)
    if loaded[name] ~= nil then return loaded[name] end
    local path = ROOT .. "/lib/" .. name .. ".lua"
    local text = readFile(path)
    if not text then
        if ccRequire then return ccRequire(name) end
        error("No library called " .. name, 2)
    end
    local fn, err = load(text, "@" .. path, "t", libEnv)
    if not fn then error(err, 0) end
    local value = fn(name)
    loaded[name] = value == nil and true or value
    return loaded[name]
end

local require = libEnv.require

local function splash(title, step, total)
    local width, height = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setTextColor(colors.white)
    term.setCursorPos(math.floor((width - 3) / 2), math.floor(height / 2) - 1)
    term.write("zOS")
    term.setTextColor(colors.lightGray)
    term.setCursorPos(math.max(1, math.floor((width - #title) / 2)), math.floor(height / 2) + 1)
    term.write(title)
    local full = math.floor(step / total * (width - 8))
    term.setCursorPos(5, math.floor(height / 2) + 3)
    term.write(string.rep("=", full) .. string.rep("-", width - 8 - full))
end

-- 1. Apply the boot policy, before anything that could fail.
splash("Securing boot", 1, 5)
local system = require("system")
system.applyBootPolicy()

-- 2. Load the system libraries.
splash("Loading libraries", 2, 5)
local apps = require("apps")
local services = require("services")
local update = require("update")
local auth = require("auth")
require("crypto")
require("ui")

if shell then shell.setPath(shell.path() .. ":" .. ROOT .. "/bin") end

-- 3. Start networking. A failure here must not stop the boot.
splash("Starting networking", 3, 5)
local ok, err = pcall(function() require("net").start() end)
if not ok then system.log("Networking didn't start: " .. tostring(err)) end

local function runScreen(name, ...)
    local path = ROOT .. "/sys/" .. name .. ".lua"
    local text = readFile(path)
    if not text then error("Missing " .. path, 0) end -- load("") would quietly do nothing
    local fn, loadError = load(text, "@" .. path, "t", libEnv)
    if not fn then error(loadError, 0) end
    return fn(...)
end

-- How many times in a row the login screen can crash before recovery takes over.
local MAX_LOGIN_CRASHES = 5

-- Runs alongside the session loop from here on.
local function sessions()
    if auth.count() == 0 then runScreen("setup") end
    local crashes = 0
    while true do
        local good, failure = pcall(function()
            local session = runScreen("login")
            crashes = 0
            if session then
                system.log(session.user .. " logged in")
                runScreen("desktop", session)
                system.log(session.user .. " logged out")
                require("crypto").clearCache()
            end
        end)
        if not good then
            system.log("The session crashed: " .. tostring(failure))
            crashes = crashes + 1
            if crashes >= MAX_LOGIN_CRASHES then
                error("The login screen keeps crashing: " .. tostring(failure), 0)
            end
            sleep(1) -- so that a crash that happens every time can't spin without yielding
        end
    end
end

-- 4. Finish any update. This is what proves that the new version boots, so a failure in the
-- steps above rolls it back, and a failure here doesn't.
splash("Finishing updates", 4, 5)
ok, err = pcall(update.finish)
if not ok then system.log("Finishing the update failed: " .. tostring(err)) end

-- 5. Start app services and the update service.
splash("Starting services", 5, 5)
apps.startServices()
services.start("zos:update", update.service)

parallel.waitForAny(sessions, services.run)
error("The session loop ended.", 0)
