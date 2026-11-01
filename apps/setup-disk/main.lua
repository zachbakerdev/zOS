-- zOS Setup Disk: erase a floppy and put the latest release's installer and image on it, with
-- any root servers the computers it installs should trust. See specs/formats/ZR_FORMAT.md.
--
-- The disk is only erased once both downloads are checked and known to fit, so a failed download
-- can't cost anyone their floppy.

local apps = require("apps")
local crypto = require("crypto")
local image = require("image")
local net = require("net")
local trust = require("trust")
local ui = require("ui")
local update = require("update")
local util = require("util")

local TITLE = "Setup Disk"
local MIN_FILE_SIZE = 500 -- CC: Tweaked counts each file as at least this many bytes
local ROOT_SERVER_CONFIG = "/etc/root-server/config" -- documented in specs/formats/ZR_FORMAT.md

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

-- Root servers ------------------------------------------------------------------------------

-- The root servers that can go on a disk, each with its signed zone, and the names of those that
-- can't. A root's zone signature isn't kept when it's trusted, so each is asked for it.
local function rootsToOffer()
    local offers, missing, seen = {}, {}, {}

    local function offer(zone, name, host)
        if trust.verifyZone(zone, zone.root) and trust.validTld(zone.tld) and trust.validName(name)
            and not seen[zone.root] then
            seen[zone.root] = true
            offers[#offers + 1] = {
                key = zone.root, tld = zone.tld, sig = zone.sig, name = name, host = host,
                fingerprint = crypto.fingerprint(crypto.fromHex(zone.root)),
            }
            return true
        end
    end

    -- This computer's own root server, which it doesn't need to trust to vouch for.
    local own = util.readTable(ROOT_SERVER_CONFIG)
    if own and type(own.zone) == "table" and type(own.name) == "string" then
        offer(own.zone, own.name, os.getComputerID())
    end

    local trusted = trust.roots()
    if #trusted > 0 then ui.text("Asking root servers for their zones...") end
    for _, root in ipairs(trusted) do
        if not seen[root.key] then
            local reply = net.request(root.host, net.ROOT_PORT, { op = "zone" })
            local zone = reply and reply.payload
            if type(zone) ~= "table" or zone.root ~= root.key or not offer(zone, root.name, root.host) then
                missing[#missing + 1] = root.name
            end
        end
    end
    return offers, missing
end

-- Which offers to embed, as (top-level domain -> offer), or nil to go back. Keying by domain is
-- what keeps it to one root each: choosing another replaces the one chosen before.
local function chooseRoots(offers)
    local chosen, selected = {}, 1
    while true do
        local items = {}
        for i, o in ipairs(offers) do
            local current = chosen[o.tld]
            items[i] = {
                label = (current == o and "[x] " or "[ ] ") .. o.name .. "  ." .. o.tld,
                hint = o.fingerprint .. (current and current ~= o and "  replaces " .. current.name or ""),
            }
        end
        items[#items + 1] = { label = "Continue", hint = "One root server for each top-level domain" }
        local choice = ui.menu({ title = TITLE .. " - Trusted roots", items = items, selected = selected, back = true })
        if not choice then return nil end
        if choice == #items then return chosen end
        local o = offers[choice]
        chosen[o.tld] = chosen[o.tld] ~= o and o or nil
        selected = choice
    end
end

-- The text of a .zr file holding `chosen`, or nil if it's empty.
local function packRoots(chosen)
    local roots = {}
    for tld, o in pairs(chosen) do
        roots[tld] = { key = o.key, name = o.name, host = o.host, sig = o.sig }
    end
    if next(roots) then return textutils.serialize({ ["zr:metadata"] = { version = 1 }, roots = roots }) end
end

-- What goes on the disk, as text or false for none, or nil to go back.
local function pickRoots()
    ui.screen(TITLE)
    local offers, missing = rootsToOffer()
    if #missing > 0 then
        ui.message(TITLE, "These root servers didn't answer, so they can't go on the disk:\n\n" ..
            table.concat(missing, "\n"), ui.theme.bad)
    end
    if #offers == 0 then return false end
    local chosen = chooseRoots(offers)
    if not chosen then return nil end
    return packRoots(chosen) or false
end

-- The release --------------------------------------------------------------------------------

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
    if release.roots then needed = needed + math.max(#release.roots, MIN_FILE_SIZE) end
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
    local files = { { "zos.zi", release.zi } }
    if release.roots then files[#files + 1] = { "zos.zr", release.roots } end
    files[#files + 1] = { "startup.lua", release.installer }
    for _, file in ipairs(files) do
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

    local roots = pickRoots()
    if roots == nil then return end

    ui.screen(TITLE)
    local release, err = download()
    if not release then
        return ui.message(TITLE, "The download failed, so the disk wasn't erased.\n\n" .. err, ui.theme.bad)
    end
    release.roots = roots or nil
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
