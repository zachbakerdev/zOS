-- The chests behind the Storage app: finding them, saving which to use, and moving items.
--
-- CC: Tweaked only moves items between inventories that can see each other. A chest attached by
-- its side can reach other sides, and one on a wired network can reach that network, but neither
-- can reach the other. A chest beside the computer that also has its own wired modem shows up
-- under both names, so it's used by its network name.

local util = require("util")

local array = {}

local CONFIG = "/etc/storage/config"

-- One peripheral method's result, or nil if the chest has gone. Ctrl+T still stops the app.
local function ask(name, method, ...)
    local ok, result = pcall(peripheral.call, name, method, ...)
    if ok then return result end
    if result == "Terminated" then error(result, 0) end
    return nil
end

local function sortedSlots(items)
    local slots = {}
    for slot in pairs(items) do slots[#slots + 1] = slot end
    table.sort(slots)
    return slots
end

-- Text that changes whenever a chest's contents do, or nil if it has gone.
local function signature(name)
    local items = ask(name, "list")
    if not items then return nil end
    local parts = { tostring(ask(name, "size")) }
    for _, slot in ipairs(sortedSlots(items)) do
        local item = items[slot]
        parts[#parts + 1] = slot .. ":" .. item.name .. ":" .. item.count .. ":" .. tostring(item.nbt)
    end
    return table.concat(parts, "|"), #parts - 1
end

-- Which wired modems can reach each network peripheral, as (name -> { modem -> true }).
local function reach()
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") and ask(name, "isWireless") == false then
            for _, remote in ipairs(ask(name, "getNamesRemote") or {}) do
                found[remote] = found[remote] or {}
                found[remote][name] = true
            end
        end
    end
    return found
end

-- What's connected, as (chests that can be used, chests beside the computer that can't). Each has
-- name, type, size, used and networks; a chest that's also beside the computer has side. An unusable one
-- has candidates: how many chests it could be, if it does have a modem and is just empty.
function array.discover()
    local networked, sides, usable, unlinked = reach(), {}, {}, {}
    local bySignature = {}

    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "inventory") then
            local sig, used = signature(name)
            if sig then
                local chest = {
                    name = name, type = peripheral.getType(name), used = used, size = ask(name, "size"), sig = sig,
                }
                if networked[name] then
                    chest.networks = networked[name]
                    usable[#usable + 1] = chest
                    bySignature[sig] = bySignature[sig] or {}
                    table.insert(bySignature[sig], chest)
                else
                    sides[#sides + 1] = chest
                end
            end
        end
    end

    if #usable == 0 then
        usable = sides
    else
        for _, chest in ipairs(sides) do
            local matches = bySignature[chest.sig] or {}
            if #matches == 1 and chest.used > 0 then
                matches[1].side = chest.name
            else
                chest.candidates = #matches
                unlinked[#unlinked + 1] = chest
            end
        end
    end

    table.sort(usable, function(a, b) return a.name < b.name end)
    return usable, unlinked
end

-- Whether items can move between two chests from discover.
function array.connected(a, b)
    if not a.networks or not b.networks then return not a.networks and not b.networks end
    for modem in pairs(a.networks) do
        if b.networks[modem] then return true end
    end
    return false
end

-- The current signature of each chest in each list, by name.
function array.snapshot(...)
    local signatures = {}
    for _, chests in ipairs({ ... }) do
        for _, chest in ipairs(chests) do signatures[chest.name] = signature(chest.name) end
    end
    return signatures
end

-- The config, as { io = name, allowed = { name -> true } }, or nil if it's not been set up.
function array.load()
    local config = util.readTable(CONFIG)
    if config and type(config.io) == "string" and type(config.allowed) == "table" then return config end
    return nil
end

function array.save(config)
    return util.writeTable(CONFIG, config)
end

-- Names and matching ---------------------------------------------------------------------------

local function keyOf(item)
    return item.name .. "#" .. tostring(item.nbt)
end

-- "minecraft:iron_ingot" as "Iron Ingot".
local function readable(id)
    local words = (id:match(":(.*)$") or id):gsub("_", " ")
    return (words:gsub("(%a)(%w*)", function(first, rest) return first:upper() .. rest end))
end

local displayNames = {} -- key -> name. Items with NBT can be renamed, so those are asked for once.

local function displayName(chest, slot, item)
    if not item.nbt then return readable(item.name) end
    local key = keyOf(item)
    if not displayNames[key] then
        local detail = ask(chest, "getItemDetail", slot)
        displayNames[key] = detail and detail.displayName or readable(item.name)
    end
    return displayNames[key]
end

-- Reading the array ------------------------------------------------------------------------------

-- Every allowed chest that answers, and how many didn't. Each chest has name, free and holds.
-- Items are (key -> { key, id, name, count, slots = { { chest, slot, count } } }).
local function scan(config)
    local names = {}
    for name in pairs(config.allowed) do
        if name ~= config.io then names[#names + 1] = name end
    end
    table.sort(names)

    local chests, items, offline = {}, {}, 0
    for _, name in ipairs(names) do
        local contents, size = ask(name, "list"), ask(name, "size")
        if contents and size then
            local chest = { name = name, free = size, holds = {} }
            chests[#chests + 1] = chest
            for _, slot in ipairs(sortedSlots(contents)) do
                local item = contents[slot]
                local key = keyOf(item)
                chest.free = chest.free - 1
                chest.holds[key] = true
                items[key] = items[key] or {
                    key = key, id = item.name, name = displayName(name, slot, item), count = 0, slots = {},
                }
                items[key].count = items[key].count + item.count
                table.insert(items[key].slots, { chest = name, slot = slot, count = item.count })
            end
        else
            offline = offline + 1
        end
    end
    return chests, items, offline
end

local function byName(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.key < b.key
end

-- Everything in storage, sorted by name, and how many chests didn't answer.
function array.items(config)
    local _, items, offline = scan(config)
    local found = {}
    for _, item in pairs(items) do found[#found + 1] = item end
    table.sort(found, byName)
    return found, offline
end

local function startsWord(text, at)
    return at == 1 or not text:sub(at - 1, at - 1):find("%w")
end

-- How well lower-case `text` fits, or 0 if it doesn't. `phrase` appearing whole beats its letters
-- being scattered, and is best at the start of a word. Scattered letters are best close together.
local function fuzzyScore(text, phrase, letters)
    local best, at = 0, text:find(phrase, 1, true)
    while at do
        best = math.max(best, (startsWord(text, at) and 2000 or 1000) - at)
        at = text:find(phrase, at + 1, true)
    end
    if best > 0 then return best end

    local first, last
    for i = 1, #letters do
        last = text:find(letters:sub(i, i), (last or 0) + 1, true)
        if not last then return 0 end
        first = first or last
    end
    return math.max(1, 500 - (last - first))
end

-- The `items` that fit `text`, best first. Their letters must appear in order in the name or id, but
-- not together. Every id shares a few namespaces, so only a literal match counts for that part.
function array.match(items, text)
    local phrase = text:lower()
    local letters = phrase:gsub("%s", "")
    if letters == "" then return items end

    local scores, found = {}, {}
    for _, item in ipairs(items) do
        local id = item.id:lower()
        local score = math.max(
            fuzzyScore(item.name:lower(), phrase, letters),
            fuzzyScore(id:match(":(.*)$") or id, phrase, letters),
            id:find(phrase, 1, true) and 1 or 0)
        if score > 0 then
            scores[item] = score
            found[#found + 1] = item
        end
    end
    table.sort(found, function(a, b)
        if scores[a] ~= scores[b] then return scores[a] > scores[b] end
        return byName(a, b)
    end)
    return found
end

-- Moving items -----------------------------------------------------------------------------------

-- Move as much of a slot as `chest` takes, and return how many moved.
local function pushTo(chest, from, slot, limit)
    local moved = ask(from, "pushItems", chest.name, slot, limit)
    if moved == nil then -- it has gone, so nothing else should try it
        chest.free, chest.holds = 0, {}
        return 0
    end
    return moved
end

-- Move a slot into the array, joining stacks of the same item first. Returns how many moved.
local function pushToArray(chests, from, slot, key, count)
    local left = count
    for _, chest in ipairs(chests) do
        if left == 0 then break end
        if chest.holds[key] then left = left - pushTo(chest, from, slot, left) end
    end
    for _, chest in ipairs(chests) do
        if left == 0 then break end
        if not chest.holds[key] and chest.free > 0 then
            local moved = pushTo(chest, from, slot, left)
            if moved > 0 then
                -- One stack from one slot takes up exactly one new slot.
                chest.free, chest.holds[key] = chest.free - 1, true
                left = left - moved
            end
        end
    end
    return count - left
end

-- Move the I/O chest's items into the array: all of them, or at most `limit` of the item `key`.
-- Returns { moved, left, offline }, where left didn't fit, or nil if the I/O chest has gone.
function array.store(config, key, limit)
    local contents = ask(config.io, "list")
    if not contents then return nil end
    local chests, _, offline = scan(config)

    local moved, wanted = 0, 0
    for _, slot in ipairs(sortedSlots(contents)) do
        local item = contents[slot]
        local itemKey = keyOf(item)
        if not key or itemKey == key then
            local count = item.count
            if limit then count = math.min(count, limit - wanted) end
            if count > 0 then
                wanted = wanted + count
                moved = moved + pushToArray(chests, config.io, slot, itemKey, count)
            end
        end
    end
    return { moved = moved, left = wanted - moved, offline = offline }
end

-- Move as many of the item `key` as fit into the I/O chest. Returns { moved, left, offline }, where
-- left stayed in the array, or nil if the I/O chest has gone.
function array.recall(config, key)
    if not ask(config.io, "size") then return nil end
    local _, items, offline = scan(config)
    local item = items[key]
    if not item then return { moved = 0, left = 0, offline = offline } end

    local moved = 0
    for _, place in ipairs(item.slots) do
        local count = ask(place.chest, "pushItems", config.io, place.slot)
        if count then
            moved = moved + count
            if count < place.count then break end -- the I/O chest is full
        end
    end
    return { moved = moved, left = item.count - moved, offline = offline }
end

return array
