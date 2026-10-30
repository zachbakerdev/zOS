--[[ zOS updates: finds, checks and stores new versions of zOS from GitHub releases.

Each release has two files (made by tools/make_update.py):

  zos-update.manifest   the version, size and SHA-256 of the bundle
  zos-update.bundle     a serialised table of the new system files and every app
  zos-apps.manifest     the version, size and SHA-256 of each .app in the release

Everything comes from RELEASES over HTTPS, and that connection is what's trusted: whatever GitHub
serves for this repository runs as system code. The sizes and hashes catch damaged downloads, not
deliberate changes. Manifests are parsed as plain text and must end with an "end" line, so a
cut-off one isn't mistaken for a whole one. Each kind starts with its own header.

This library never touches /zos. It stores the update in STAGED, and /startup.lua swaps it in at
the next boot, before any zOS code has loaded. If the new version can't boot, /startup.lua puts
the old one back. finish() runs once a boot gets far enough to prove the new version works. ]]

local crypto = require("crypto")
local system = require("system")
local apps = require("apps")

local update = {}

update.RELEASES = "https://github.com/zachbakerdev/zOS/releases"
update.CHECK_INTERVAL = 6 * 60 * 60 -- seconds
update.FIRST_CHECK = 30 -- seconds after boot

-- Must match /startup.lua.
local DIR = "/etc/zos/update"
local STAGED = DIR .. "/new"
local READY = STAGED .. "/ready"
local OLD = DIR .. "/old"
local BAD = DIR .. "/bad"
local TRIAL = DIR .. "/trial"
local FAILED = DIR .. "/failed"

local FORMAT_VERSION = 1
local MIN_FILE_SIZE = 500 -- CC: Tweaked counts every file as at least this many bytes

update.latest = nil -- the newest version found, from check()
local busy = false

local function readFile(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "rb")
    local text = f.readAll()
    f.close()
    return text
end

local function writeFile(path, data)
    fs.makeDir(fs.getDir(path))
    local f, err = fs.open(path, "wb")
    if not f then error("Can't write " .. path .. ": " .. tostring(err), 0) end
    f.write(data)
    f.close()
    if readFile(path) ~= data then error("Writing " .. path .. " failed. Is the disk full?", 0) end
end

local function get(url)
    if not http then return nil, "The HTTP API is disabled on this server." end
    local res, err = http.get(url, nil, true)
    if not res then return nil, "Download failed: " .. tostring(err) end
    local text = res.readAll()
    res.close()
    return text
end

-- The version waiting to be installed at the next boot, if any.
function update.stagedVersion()
    if fs.exists(STAGED .. "/zos") then return readFile(READY) end
end

-- The version that failed to boot and was rolled back, if any.
function update.failedVersion()
    return readFile(FAILED)
end

-- The text of a manifest, or nil if it's the wrong kind or cut off.
local function manifestBody(text, header)
    return text:match("^(" .. header .. " 1\n.-)end\n$")
end

function update.parseManifest(text)
    local body = manifestBody(text, "zos%-update")
    if not body then return nil, "The update information is damaged." end
    local info = {
        version = body:match("\nversion=([%d%.]+)\n"),
        size = tonumber(body:match("\nsize=(%d+)\n")),
        sha256 = body:match("\nsha256=(%x+)\n"),
    }
    if not info.version or not info.size or not info.sha256 then
        return nil, "The update information is damaged."
    end
    return info
end

-- Look for a newer version. Returns its info, false if this is the newest, or nil and an error.
function update.check()
    local text, err = get(update.RELEASES .. "/latest/download/zos-update.manifest")
    if not text then return nil, err end
    local info
    info, err = update.parseManifest(text)
    if not info then return nil, err end
    if apps.compareVersions(info.version, system.VERSION) <= 0 then
        update.latest = nil
        return false
    end
    update.latest = info
    return info
end

-- Check an unpacked bundle. Returns the files to store as (path -> data), or nil and an error.
local function checkBundle(bundle, info)
    if type(bundle) ~= "table" or bundle.format ~= "zos-update" or bundle.formatVersion ~= FORMAT_VERSION then
        return nil, "This update needs a newer version of zOS. Install it from a setup disk."
    end
    if bundle.version ~= info.version then return nil, "The update is for a different version." end
    if type(bundle.files) ~= "table" or not bundle.files["zos/boot.lua"] then
        return nil, "The update has no system files."
    end

    local files = {}
    for path, data in pairs(bundle.files) do
        if not (path == "startup.lua" or path:sub(1, 4) == "zos/") or not apps.validPath(path) then
            return nil, "The update contains a bad file name: " .. tostring(path)
        end
        if path:match("%.lua$") then
            local ok, err = load(data, "=" .. path, "t", {})
            if not ok then return nil, "The update's " .. path .. " is broken: " .. tostring(err) end
        end
        files[path] = data
    end
    -- Replacing /startup.lua is the one step that isn't safe to interrupt, so skip it if possible.
    if files["startup.lua"] == readFile("/startup.lua") then files["startup.lua"] = nil end

    for id, text in pairs(bundle.apps or {}) do
        local pkg, err = apps.parse(text)
        if not pkg or pkg.id ~= id then return nil, "The update's app '" .. id .. "' is broken: " .. tostring(err) end
        files["apps/" .. id .. ".app"] = text
    end
    return files
end

local function stage(files, version)
    local space = 0
    for _, data in pairs(files) do space = space + math.max(#data, MIN_FILE_SIZE) end
    if fs.exists(STAGED) then fs.delete(STAGED) end
    local free = fs.getFreeSpace("/")
    if free ~= "unlimited" and free < space then
        return nil, ("The update needs %.0f KB but only %.0f KB is free."):format(space / 1024, free / 1024)
    end
    local ok, err = pcall(function()
        for path, data in pairs(files) do writeFile(STAGED .. "/" .. path, data) end
        writeFile(READY, version) -- last, so /startup.lua never sees half an update
    end)
    if not ok then
        fs.delete(STAGED)
        return nil, tostring(err)
    end
    return true
end

-- Download the update from check() and store it for the next boot.
function update.download(info)
    if busy then return nil, "An update is already downloading." end
    busy = true
    local ok, result, err = pcall(function()
        local text, getErr = get(update.RELEASES .. "/download/v" .. info.version .. "/zos-update.bundle")
        if not text then return nil, getErr end
        if #text ~= info.size or crypto.sha256(text) ~= info.sha256 then
            return nil, "The download is damaged or has been changed."
        end
        local files, checkErr = checkBundle(textutils.unserialize(text), info)
        if not files then return nil, checkErr end
        return stage(files, info.version)
    end)
    busy = false
    if not ok then return nil, tostring(result) end
    if result then system.log("zOS " .. info.version .. " downloaded, installing at the next boot") end
    return result, err
end

-- Every app in the latest release: updates, new apps, installed apps, then any this zOS is too old
-- for. Returns the list, or nil and an error. Each entry is { id, version, size, sha256, minZos,
-- name, description, release, current = installed version or nil, newer = true if it's a higher
-- version than installed, supported = false if this zOS is too old for it }.
function update.checkApps()
    local text, err = get(update.RELEASES .. "/latest/download/zos-apps.manifest")
    if not text then return nil, err end
    local body = manifestBody(text, "zos%-apps")
    if not body then return nil, "The app list is damaged." end

    local release = body:match("\nrelease=([%d%.]+)\n")
    if not release then return nil, "The app list is damaged." end
    local list = {}
    for line in body:gmatch("\napp=([^\n]*)") do
        local id, version, size, sha256, minZos, name, description =
            line:match("^([^\t]+)\t([^\t]+)\t(%d+)\t(%x+)\t([^\t]*)\t([^\t]+)\t([^\t]*)$")
        if not id or not apps.validId(id) then return nil, "The app list is damaged." end
        local installed = apps.get(id)
        list[#list + 1] = {
            id = id, version = version, size = tonumber(size), sha256 = sha256, name = name,
            minZos = minZos ~= "" and minZos or nil, supported = apps.supports(minZos ~= "" and minZos or nil),
            description = description, release = release,
            current = installed and installed.version,
            newer = installed ~= nil and apps.compareVersions(version, installed.version) > 0,
        }
    end

    local function rank(entry)
        if not entry.supported then return 4 end
        return entry.newer and 1 or (entry.current and 3 or 2)
    end
    table.sort(list, function(a, b)
        if rank(a) ~= rank(b) then return rank(a) < rank(b) end
        return a.name:lower() < b.name:lower()
    end)
    return list
end

-- Download an app from checkApps() and check it. Returns a package for apps.install.
function update.downloadApp(entry)
    local text, err = get(update.RELEASES .. "/download/v" .. entry.release .. "/" .. entry.id .. ".app")
    if not text then return nil, err end
    if #text ~= entry.size or crypto.sha256(text) ~= entry.sha256 then
        return nil, "The download is damaged or has been changed."
    end
    local pkg
    pkg, err = apps.parse(text)
    if not pkg then return nil, err end
    if pkg.id ~= entry.id or pkg.manifest.version ~= entry.version then
        return nil, "The download doesn't match the app list."
    end
    return pkg
end

-- Called during boot, once the new version has got this far. Updates the apps and clears up.
function update.finish()
    if readFile(TRIAL) == system.VERSION then
        local dir = STAGED .. "/apps"
        for _, name in ipairs(fs.exists(dir) and fs.list(dir) or {}) do
            local pkg, err = apps.readPackage(dir .. "/" .. name)
            local installed = pkg and apps.get(pkg.id)
            if not pkg then
                system.log("update: " .. name .. ": " .. tostring(err))
            elseif installed and apps.compareVersions(installed.version, pkg.manifest.version) < 0
                or (not installed and apps.PROTECTED[pkg.id]) then
                local ok, app, installErr = pcall(apps.install, pkg)
                if not ok or not app then
                    system.log("update: " .. name .. ": " .. tostring(ok and installErr or app))
                end
            end
        end
        if fs.exists(FAILED) then fs.delete(FAILED) end
        system.log("zOS updated to " .. system.VERSION)
    end
    if not update.stagedVersion() and fs.exists(STAGED) then fs.delete(STAGED) end
    for _, path in ipairs({ OLD, BAD, TRIAL }) do
        if fs.exists(path) then fs.delete(path) end
    end
end

-- One round of the background service.
function update.tick()
    local info, err = update.check()
    if not info then return false, err end
    if not system.autoUpdateEnabled() or info.version == update.failedVersion()
        or info.version == update.stagedVersion() then
        return false
    end
    local ok, downloadErr = update.download(info)
    if not ok then system.log("update failed: " .. tostring(downloadErr)) end
    return ok
end

-- The background service, started at boot.
function update.run()
    sleep(update.FIRST_CHECK)
    while true do
        pcall(update.tick)
        sleep(update.CHECK_INTERVAL)
    end
end

return update
