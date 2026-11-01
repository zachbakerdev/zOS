-- Finds, checks and stages updates, and lists the apps in the latest release.
-- /startup.lua does the swap at boot. See "Updates" in specs/ZOS.md.

local apps = require("apps")
local crypto = require("crypto")
local image = require("image")
local system = require("system")
local util = require("util")

local update = {
    RELEASES = "https://github.com/zachbakerdev/zOS/releases/",
}

local DIR = system.DATA .. "/update"
local NEW = DIR .. "/new"
local OLD = DIR .. "/old"
local STARTUP = DIR .. "/startup.new"
local READY = DIR .. "/ready"
local TRIAL = DIR .. "/trial"
local FAILED = DIR .. "/failed"
local APPS_DUE = DIR .. "/apps-due"

local FIRST_CHECK, CHECK_EVERY = 30, 6 * 3600

local function lastReleaseUrl(name)
    return update.RELEASES .. "latest/download/" .. name
end

local function releaseUrl(version, name)
    return update.RELEASES .. "download/v" .. version .. "/" .. name
end

-- key=value lines between a header and an "end" line, or nil. Without the end line, a download
-- that was cut off could look complete.
local function parseManifest(text, header)
    if type(text) ~= "string" then return nil end
    local lines = {}
    for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
    if lines[1] ~= header or lines[#lines] ~= "end" then return nil end
    return lines
end

-- What's on offer. Returns a table if there's something newer, false if not, or nil and a reason.
function update.check()
    local text, err = util.get(lastReleaseUrl("zos-update.manifest"))
    if not text then return nil, err end
    local lines = parseManifest(text, "zos-update 1")
    if not lines then return nil, "The update list is damaged." end
    local info = {}
    for i = 2, #lines - 1 do
        local key, value = lines[i]:match("^(%w+)=(.*)$")
        if key then info[key] = value end
    end
    info.size = tonumber(info.size)
    if not apps.validVersion(info.version) or not info.size or not crypto.isHex(info.sha256, 64) then
        return nil, "The update list is damaged."
    end
    if apps.compareVersions(info.version, system.VERSION) <= 0 then return false end
    return info
end

function update.stagedVersion()
    if not fs.exists(READY) then return nil end
    return util.readFile(READY)
end

function update.failedVersion()
    return fs.exists(FAILED) and util.readFile(FAILED) or nil
end

function update.discard()
    fs.delete(READY)
    fs.delete(NEW)
    fs.delete(STARTUP)
end

local function stage(path, data)
    local ok, why = util.writeChecked(path, data)
    if not ok then
        update.discard()
        return nil, "Couldn't store the update: " .. tostring(why)
    end
    return true
end

-- Download, check and stage a version. Nothing in /.zos is touched: the swap happens at boot.
function update.download(info)
    local text, err = util.get(releaseUrl(info.version, "zos.zi"), true)
    if not text then return nil, "The download failed: " .. err end
    if #text ~= info.size then return nil, "The download is the wrong size." end
    if crypto.sha256(text) ~= info.sha256 then return nil, "The download has changed." end
    local files
    files, err = image.parse(text)
    if not files then return nil, err end
    if not files["/.zos/boot.lua"] or not files["/startup.lua"] then
        return nil, "The image isn't a complete system."
    end
    local free = fs.getFreeSpace("/")
    if type(free) == "number" and free < image.spaceNeeded(files) then
        return nil, "There isn't enough disk space."
    end

    update.discard()
    for path, data in pairs(files) do
        -- Apps change at the finish stage and arrive as .za images, so a rollback can't leave
        -- them ahead of the system.
        if path:sub(1, 6) == "/.zos/" and path:sub(1, 11) ~= "/.zos/apps/" then
            local ok, why = stage(NEW .. path:sub(6), data)
            if not ok then return nil, why end
        end
    end
    local ok, why = stage(STARTUP, files["/startup.lua"])
    if not ok then return nil, why end
    if fs.exists(FAILED) and util.readFile(FAILED) == info.version then fs.delete(FAILED) end
    ok, why = stage(READY, info.version) -- last, so a boot never sees half an update
    if not ok then return nil, why end
    system.log("Update " .. info.version .. " is ready")
    return true
end

-- Apps in the release --------------------------------------------------------------------------

local function parseAppLine(line)
    local fields = {}
    for field in (line .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = field end
    if #fields < 7 or not apps.validId(fields[1]) or not apps.validVersion(fields[2]) or not tonumber(fields[3])
        or not crypto.isHex(fields[4], 64) or (fields[5] ~= "" and not apps.validVersion(fields[5])) then
        return nil
    end
    return {
        id = fields[1], version = fields[2], size = tonumber(fields[3]), sha256 = fields[4],
        minZos = fields[5] ~= "" and fields[5] or nil, name = fields[6], description = fields[7],
    }
end

local function rank(entry)
    if not entry.supported then return 4 end
    if entry.newer then return 1 end
    if not entry.current then return 2 end
    return 3
end

function update.checkApps()
    local text, err = util.get(lastReleaseUrl("zos-apps.manifest"))
    if not text then return nil, err end
    local lines = parseManifest(text, "zos-apps 1")
    local release = lines and lines[2] and lines[2]:match("^release=(.+)$")
    if not release then return nil, "The list of apps is damaged." end

    local list = {}
    for i = 3, #lines - 1 do
        local body = lines[i]:match("^app=(.*)$")
        local entry = body and parseAppLine(body)
        if not entry then return nil, "The list of apps is damaged." end
        local installed = apps.get(entry.id)
        entry.release = release
        entry.current = installed and installed.version or nil
        entry.newer = installed ~= nil and apps.compareVersions(entry.version, installed.version) > 0
        entry.supported = apps.supports(entry.minZos)
        list[#list + 1] = entry
    end
    table.sort(list, function(a, b)
        if rank(a) ~= rank(b) then return rank(a) < rank(b) end
        return a.name:lower() < b.name:lower()
    end)
    return list
end

function update.downloadApp(entry)
    local text, err = util.get(releaseUrl(entry.release, entry.id .. ".za"), true)
    if not text then return nil, "The download failed: " .. err end
    if #text ~= entry.size or crypto.sha256(text) ~= entry.sha256 then
        return nil, "The download has changed."
    end
    local pkg
    pkg, err = apps.parse(text)
    if not pkg then return nil, err end
    if pkg.id ~= entry.id or pkg.manifest.version ~= entry.version then
        return nil, "The download isn't the app that was listed."
    end
    return pkg
end

-- Finish stage ---------------------------------------------------------------------------------

-- Upgrade installed apps and install any protected app that's missing. Returns whether every one
-- got done.
local function updateApps()
    local list, err = update.checkApps()
    if not list then
        system.log("Couldn't list the apps in the release: " .. tostring(err))
        return false
    end
    local complete = true
    for _, entry in ipairs(list) do
        if entry.supported and (entry.newer or (not entry.current and apps.PROTECTED[entry.id])) then
            local pkg, why = update.downloadApp(entry)
            local installed = pkg
            if pkg then installed, why = apps.install(pkg) end
            if not installed then
                system.log("Couldn't update " .. entry.id .. ": " .. tostring(why))
                complete = false
            end
        end
    end
    return complete
end

-- Do any app updates that are due. They stay due until they all work, so a computer that was
-- offline when the update finished catches up later.
function update.finishApps()
    if not fs.exists(APPS_DUE) then return end
    local ok, complete = pcall(updateApps)
    if not ok then
        system.log("Updating apps failed: " .. tostring(complete))
    elseif complete then
        fs.delete(APPS_DUE)
    end
end

-- The boot has got far enough to count as good. Replace /startup.lua, delete the old version, then
-- update the apps. Apps come last, so that trouble with them can't roll the system back.
function update.finish()
    if fs.exists(TRIAL) then
        local version = util.readFile(TRIAL)
        if fs.exists(STARTUP) then
            fs.delete("/startup.lua.new")
            fs.move(STARTUP, "/startup.lua.new")
            fs.delete("/startup.lua")
            fs.move("/startup.lua.new", "/startup.lua")
        end
        util.writeFile(APPS_DUE, tostring(version))
        fs.delete(OLD)
        fs.delete(TRIAL)
        system.log("Updated to zOS " .. tostring(version))
    end
    update.finishApps()
end

-- One round of the background service.
function update.tick()
    update.finishApps()
    if system.config().autoUpdate == false then return end
    local info = update.check()
    if not info or info.version == update.stagedVersion() or info.version == update.failedVersion() then return end
    local ok, err = update.download(info)
    if not ok then system.log("Couldn't download update " .. info.version .. ": " .. tostring(err)) end
end

function update.service()
    util.wait(FIRST_CHECK)
    while true do
        local ok, err = pcall(update.tick)
        if not ok then system.log("Update check failed: " .. tostring(err)) end
        util.wait(CHECK_EVERY)
    end
end

return update
