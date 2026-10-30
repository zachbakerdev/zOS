-- zOS boot sequence. Started by /startup.lua with { shell = ..., require = ... }.

local ctx = ...

-- System libraries and programs share one environment, with require rooted at /zos/lib.
local env = setmetatable({}, { __index = _G })
env.require, env.package = ctx.require("cc.require").make(env, "/zos/lib")
env.package.path = "/zos/lib/?.lua;" .. env.package.path
env.shell = ctx.shell -- for apps
local require = env.require

local ui = require("ui")
local system = require("system")

local function halt(action)
    action()
    while true do os.pullEventRaw() end
end

local function splash(step, total, label)
    local w, h = term.getSize()
    local mid = math.floor(h / 2)
    term.setBackgroundColor(ui.theme.bg)
    term.clear()
    ui.center(mid - 2, "z O S", ui.theme.accent)
    ui.center(mid - 1, "version " .. system.VERSION, ui.theme.dim)

    local barW = math.min(30, w - 4)
    local x = math.floor((w - barW) / 2) + 1
    local filled = math.floor(barW * step / total)
    ui.at(x, mid + 1, string.rep(" ", filled), nil, ui.theme.selBg)
    ui.at(x + filled, mid + 1, string.rep(" ", barW - filled), nil, colors.gray)
    term.setBackgroundColor(ui.theme.bg)
    ui.center(mid + 3, label, ui.theme.dim)
end

local stages = {
    { "Applying boot policy", system.applyBootPolicy },
    { "Loading system libraries", function()
        for _, name in ipairs({ "util", "crypto", "auth", "keys", "services", "apps", "trust", "net" }) do require(name) end
    end },
    { "Starting networking", function()
        -- Logging in matters more than the network, so a failure here mustn't stop the boot.
        local ok, err = pcall(require("net").start)
        if not ok then system.log("networking failed to start: " .. tostring(err)) end
    end },
    { "Starting app services", function() require("apps").startServices() end },
}

for i, stage in ipairs(stages) do
    splash(i - 1, #stages, stage[1] .. "...")
    stage[2]()
    sleep(0.15)
end
splash(#stages, #stages, "Ready")
sleep(0.3)

-- System screens live in /zos/sys and are loaded fresh each time they're run.
local function run(name, ...)
    local fn, err = loadfile("/zos/sys/" .. name .. ".lua", nil, env)
    if not fn then error(err, 0) end
    return fn(...)
end

local auth, crypto = require("auth"), require("crypto")

-- One login -> desktop -> logout cycle.
local function session()
    local user, secretKey, publicKey = run("login")
    local action = run("desktop", {
        user = user,
        admin = auth.isAdmin(user),
        since = os.epoch("utc"),
        secretKey = secretKey,
        publicKey = publicKey,
    }, run)
    crypto.clearCache()
    if action == "reboot" or action == "shutdown" then
        system.applyBootPolicy()
        halt(action == "reboot" and os.reboot or os.shutdown)
    end
end

local function sessions()
    while true do
        local ok, err = pcall(session)
        crypto.clearCache()
        os.pullEvent = os.pullEventRaw
        if not ok then
            system.log("session error: " .. tostring(err))
            ui.message("zOS - System error", "Something went wrong:\n\n" .. tostring(err) ..
                "\n\nYou have been logged out.", ui.theme.bad)
        end
    end
end

-- App services run alongside the sessions, even while nobody is logged in.
parallel.waitForAny(sessions, require("services").run)
