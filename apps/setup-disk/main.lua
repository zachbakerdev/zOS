-- zOS Setup Disk: erase a floppy and put the latest release's installer and image on it.
--
-- The disk is only erased once both downloads are checked and known to fit, so a failed download
-- can't cost anyone their floppy.

local apps = require("apps")
local crypto = require("crypto")
local image = require("image")
local ui = require("ui")
local update = require("update")
local util = require("util")

local TITLE = "Setup Disk"
local MIN_FILE_SIZE = 500 -- CC: Tweaked counts each file as at least this many bytes

-- Every floppy that can be written to, as { side, mount, id, label }.
local function findDisks()
    local found = {}
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "drive" and disk.hasData(side) then
            local mount = disk.getMountPath(side)
            if mount and not fs.isReadOnly(mount) then
                found[#found + 1] = { side = side, mount = mount, id = disk.getID(side), label = disk.getLabel(side) }
            end
        end
    end
    return found
end

local function describe(d)
    if d.label then return '"' .. d.label .. '" (/' .. d.mount .. ")" end
    return "/" .. d.mount
end

-- The floppy could be swapped during the downloads, and that one was never agreed to.
local function stillThere(d)
    return disk.hasData(d.side) and disk.getID(d.side) == d.id and disk.getMountPath(d.side) == d.mount
end

-- Wait for something to change. Returns false if the user went back instead.
local function waitForDisk()
    ui.screen(TITLE)
    ui.text("Put a floppy in a disk drive next to this computer.")
    ui.text("")
    ui.text("Backspace: back", ui.theme.dim)
    while true do
        local event, value = os.pullEvent()
        if event == "disk" or event == "peripheral" then return true end
        if event == "key" and value == keys.backspace then return false end
    end
end

local function chooseDisk()
    while true do
        local disks = findDisks()
        if #disks == 1 then return disks[1] end
        if #disks > 1 then
            local items = {}
            for i, d in ipairs(disks) do
                items[i] = { label = describe(d), hint = #fs.list(d.mount) .. " items, drive " .. d.side }
            end
            local choice = ui.menu({ title = TITLE .. " - Choose a disk", items = items, back = true })
            return choice and disks[choice]
        end
        if not waitForDisk() then return nil end
    end
end

-- The version, size and SHA-256 of the latest image, or nil and a reason.
local function latestRelease()
    local text, err = util.get(update.RELEASES .. "latest/download/zos-update.manifest")
    if not text then return nil, err end
    local info, lines = {}, {}
    for line in text:gmatch("[^\n]+") do
        lines[#lines + 1] = line
        local key, value = line:match("^(%w+)=(.*)$")
        if key then info[key] = value end
    end
    info.size = tonumber(info.size)
    if lines[1] ~= "zos-update 1" or lines[#lines] ~= "end" or not apps.validVersion(info.version)
        or not info.size or not crypto.isHex(info.sha256, 64) then
        return nil, "The release list is damaged."
    end
    return info
end

-- The latest image and installer, checked, or nil and a reason. Both come from the same release,
-- even if a new one is published in the meantime.
local function download()
    ui.text("Finding the latest release...")
    local info, err = latestRelease()
    if not info then return nil, err end
    local base = update.RELEASES .. "download/v" .. info.version .. "/"

    ui.text("Downloading zOS " .. info.version .. "...")
    local zi
    zi, err = util.get(base .. "zos.zi", true)
    if not zi then return nil, err end
    if #zi ~= info.size then return nil, "The download is the wrong size." end
    if crypto.sha256(zi) ~= info.sha256 then return nil, "The download has changed." end
    local files
    files, err = image.parse(zi)
    if not files then return nil, err end
    if not files["/.zos/boot.lua"] or not files["/startup.lua"] then
        return nil, "The image isn't a complete system."
    end

    ui.text("Downloading the installer...")
    local installer
    installer, err = util.get(base .. "install.lua", true)
    if not installer then return nil, err end
    local fn
    fn, err = load(installer, "@install.lua", "t", {})
    if not fn then return nil, "The installer doesn't compile: " .. tostring(err) end

    return { version = info.version, zi = zi, installer = installer }
end

local function fits(d, release)
    local capacity = fs.getCapacity(d.mount)
    local needed = math.max(#release.zi, MIN_FILE_SIZE) + math.max(#release.installer, MIN_FILE_SIZE)
    if type(capacity) == "number" and capacity < needed then
        return nil, ("A setup disk needs %d KB, but this disk only holds %d KB."):format(
            math.ceil(needed / 1000), math.floor(capacity / 1000))
    end
    return true
end

-- The installer goes last: it's what makes the disk boot, and a disk with only an installer on it
-- would quietly download zOS rather than use its own image.
local function write(d, release)
    for _, name in ipairs(fs.list(d.mount)) do
        fs.delete(fs.combine(d.mount, name))
    end
    for _, file in ipairs({ { "zos.zi", release.zi }, { "startup.lua", release.installer } }) do
        local ok, why = util.writeChecked(fs.combine(d.mount, file[1]), file[2])
        if not ok then error("Couldn't write " .. file[1] .. ": " .. tostring(why), 0) end
    end
end

local function makeDisk(d)
    ui.screen(TITLE)
    local count = #fs.list(d.mount)
    ui.text("Disk: " .. describe(d))
    ui.text(count == 1 and "It has 1 item on it." or "It has " .. count .. " items on it.", ui.theme.dim)
    ui.text("")
    ui.text("This deletes everything on the disk.", ui.theme.bad)
    if not ui.confirm("Erase it and make a setup disk?") then return end

    ui.screen(TITLE)
    local release, err = download()
    if not release then
        return ui.message(TITLE, "The download failed, so the disk wasn't erased.\n\n" .. err, ui.theme.bad)
    end
    if not stillThere(d) then
        return ui.message(TITLE, "The disk was taken out or changed, so nothing was erased.", ui.theme.bad)
    end
    local ok
    ok, err = fits(d, release)
    if not ok then return ui.message(TITLE, err .. " Nothing was erased.", ui.theme.bad) end

    ui.text("Writing to the disk...")
    ok, err = pcall(write, d, release)
    if not ok then
        return ui.message(TITLE, "The disk was erased, but it isn't a setup disk.\n\n" .. tostring(err), ui.theme.bad)
    end
    ui.message(TITLE, "This is now a zOS " .. release.version .. " setup disk. A computer without zOS " ..
        "installs it when it boots with this disk inserted.", ui.theme.good)
end

local d = chooseDisk()
if d then makeDisk(d) end
