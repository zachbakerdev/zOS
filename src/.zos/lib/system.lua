-- The version, system log, settings and boot policy.

local util = require("util")

local system = {
    VERSION = "1.1.0",
    ROOT = "/.zos",
    DATA = "/etc/zos",
}

local LOG = system.DATA .. "/system.log"
local CONFIG = system.DATA .. "/config"
local MAX_LOG = 32768

function system.log(text)
    local line = ("[%d] %s\n"):format(math.floor(os.epoch("utc") / 1000), tostring(text))
    if fs.exists(LOG) and fs.getSize(LOG) > MAX_LOG then
        local old = util.readFile(LOG) or ""
        util.writeFile(LOG, old:sub(-math.floor(MAX_LOG / 2)))
    end
    fs.makeDir(system.DATA)
    local f = fs.open(LOG, "a")
    if f then
        f.write(line)
        f.close()
    end
end

function system.config()
    return util.readTable(CONFIG) or {}
end

function system.setConfig(changes)
    local config = system.config()
    for k, v in pairs(changes) do config[k] = v end
    util.writeTable(CONFIG, config)
end

function system.secureBoot()
    return system.config().secureBoot ~= false
end

-- CraftOS reads this setting before it runs /startup.lua, so it has to be right on disk before
-- the computer next starts, whatever a shell has done to it since.
function system.applyBootPolicy()
    if not settings then return end
    settings.set("shell.allow_disk_startup", not system.secureBoot())
    settings.save("/.settings")
end

function system.setSecureBoot(on, user)
    system.setConfig({ secureBoot = on })
    system.applyBootPolicy()
    system.log(tostring(user) .. " turned secure boot " .. (on and "on" or "off"))
end

function system.reboot()
    system.applyBootPolicy()
    os.reboot()
end

function system.shutdown()
    system.applyBootPolicy()
    os.shutdown()
end

return system
