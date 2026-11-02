-- The item index: what each storage chest holds, saved so that the chests don't all have to be read
-- every time. It's kept on this computer, or on a floppy in a disk drive on the wired network, where
-- every computer using the same chests can share it.
--
-- The file is text, one line each, to fit a large network on a floppy:
--   storage-index 1
--   i <number> <item id> <nbt or -> [display name, for items with NBT]
--   c <chest> <size> <slot>,<item number>,<count> ...

local util = require("util")

local index = {}

local LOCAL = "/etc/storage/index"
local HEADER = "storage-index 1"

local function empty() return { chests = {}, names = {} } end

local function sorted(t)
    local keys = {}
    for key in pairs(t) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

-- Where config keeps its index, or nil and why it can't be reached.
function index.path(config)
    local drive = config.index and config.index.drive
    if not drive then return LOCAL end
    local ok, present = pcall(disk.hasData, drive)
    local mount = ok and present and disk.getMountPath(drive)
    if not mount then return nil, "The network drive " .. drive .. " isn't connected or has no floppy in it." end
    return fs.combine(mount, "storage/index")
end

local function encode(data)
    local lines, numbers, count = { HEADER }, {}, 0
    for _, name in ipairs(sorted(data.chests)) do
        local chest = data.chests[name]
        local parts = { "c", name, tostring(chest.size) }
        for _, slot in ipairs(sorted(chest.slots)) do
            local item = chest.slots[slot]
            local key = item.name .. "#" .. tostring(item.nbt)
            if not numbers[key] then
                count = count + 1
                numbers[key] = count
                local line = "i " .. count .. " " .. item.name .. " " .. (item.nbt or "-")
                local display = item.nbt and data.names[key]
                if display then line = line .. " " .. display:gsub("[\r\n]", " ") end
                lines[#lines + 1] = line
            end
            parts[#parts + 1] = slot .. "," .. numbers[key] .. "," .. item.count
        end
        lines[#lines + 1] = table.concat(parts, " ")
    end
    return table.concat(lines, "\n") .. "\n"
end

-- The index in `text`, or nil if it isn't one.
local function decode(text)
    local nextLine = text:gmatch("[^\n]+")
    if nextLine() ~= HEADER then return nil end
    local data, items = empty(), {}
    for line in nextLine do
        local kind, rest = line:match("^(%a) (.*)$")
        if kind == "i" then
            local number, id, nbt, name = rest:match("^(%d+) (%S+) (%S+) ?(.*)$")
            if number then
                if nbt == "-" then nbt = nil end
                items[tonumber(number)] = { id = id, nbt = nbt }
                if nbt and name ~= "" then data.names[id .. "#" .. nbt] = name end
            end
        elseif kind == "c" then
            local name, size, slots = rest:match("^(%S+) (%d+) ?(.*)$")
            if name then
                local chest = { size = tonumber(size), slots = {} }
                for slot, number, count in slots:gmatch("(%d+),(%d+),(%d+)") do
                    local item = items[tonumber(number)]
                    if item then
                        chest.slots[tonumber(slot)] = { name = item.id, nbt = item.nbt, count = tonumber(count) }
                    end
                end
                data.chests[name] = chest
            end
        end
    end
    return data
end

-- The index at `path`, or nil if there's none. A leftover ".new" file is a save that stopped short.
local function read(path)
    if not fs.exists(path) and fs.exists(path .. ".new") then path = path .. ".new" end
    if not fs.exists(path) then return nil end
    local text = util.readFile(path)
    return text and decode(text)
end

-- The saved index, as { chests = { name -> { size, slots = { slot -> { name, count, nbt } } } },
-- names = { key -> display name } }. It's empty if there's none yet. If it can't be reached, it's
-- empty and the reason comes second.
function index.load(config)
    local path, err = index.path(config)
    if not path then return empty(), err end
    return read(path) or empty()
end

-- Save the chests named in `changed` (name -> true) over what's saved now, so that what another
-- computer saved in the meantime is kept. With `changed` nil, `data` replaces the whole index.
-- Returns true, or false and why not.
function index.save(config, data, changed)
    local path, err = index.path(config)
    if not path then return false, err end

    local latest = data
    if changed then
        latest = read(path) or empty()
        for name in pairs(changed) do latest.chests[name] = data.chests[name] end
        for key, name in pairs(data.names) do latest.names[key] = latest.names[key] or name end
    end

    local temp = path .. ".new"
    local ok, writeErr = util.writeChecked(temp, encode(latest))
    if not ok then
        fs.delete(temp)
        return false, writeErr
    end
    if fs.exists(path) then fs.delete(path) end
    fs.move(temp, path)
    return true
end

-- Delete the index kept on this computer, which is out of date once another one has been used.
function index.deleteLocal()
    fs.delete(LOCAL)
    fs.delete(LOCAL .. ".new")
end

return index
