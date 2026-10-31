local util = require("util")

local system = {}

system.VERSION = "2.2.0"

local CONFIG = "/etc/zos/config"
local LOG = "/etc/zos/system.log"

function system.log(text)
    fs.makeDir(fs.getDir(LOG))
    local f = fs.open(LOG, "a")
    f.writeLine(os.date("%Y-%m-%d %H:%M:%S ") .. text)
    f.close()
end

function system.config()
    local config = util.readTable(CONFIG)
    return type(config) == "table" and config or {}
end

function system.resetConfig()
    if fs.exists(CONFIG) then
        fs.delete(CONFIG)
    end
end

-- Secure boot stops CraftOS booting from floppies, which would skip the login.
function system.secureBootEnabled()
    return system.config().secureBoot ~= false
end

-- CraftOS reads shell.allow_disk_startup before it runs /startup.lua, so it has
-- to be saved to /.settings rather than only set for this boot.
function system.applyBootPolicy()
    settings.set("shell.allow_disk_startup", not system.secureBootEnabled())
    settings.set("shell.allow_startup", true)
    settings.set("motd.enable", false)
    settings.save("/.settings")
end

-- Whether new versions of zOS download by themselves and install at the next boot.
function system.autoUpdateEnabled()
    return system.config().autoUpdate ~= false
end

function system.setAutoUpdate(enabled, by)
    local config = system.config()
    config.autoUpdate = enabled == true
    util.writeTable(CONFIG, config)
    system.log("automatic updates " .. (enabled and "enabled" or "disabled") .. " by " .. tostring(by))
end

function system.setSecureBoot(enabled, by)
    local config = system.config()
    config.secureBoot = enabled == true
    util.writeTable(CONFIG, config)
    system.applyBootPolicy()
    system.log("secure boot " .. (enabled and "enabled" or "disabled") .. " by " .. tostring(by))
end

return system
