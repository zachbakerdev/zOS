-- The chests behind the Storage app: finding them, saving which to use, and moving items.
--
-- CC: Tweaked only moves items between inventories that can see each other. A chest attached by
-- its side can reach other sides, and one on a wired network can reach that network, but neither
-- can reach the other. A chest beside the computer that also has its own wired modem shows up
-- under both names, so it's used by its network name.

local index = require("index")
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
-- onProgress(done, total, "chest") is called as each one is read, and not at all if there aren't any.
function array.discover(onProgress)
    local networked, sides, usable, unlinked = reach(), {}, {}, {}
    local bySignature = {}

    local inventories = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "inventory") then inventories[#inventories + 1] = name end
    end

    if onProgress and #inventories > 0 then onProgress(0, #inventories, "chest") end
    for i, name in ipairs(inventories) do
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
        if onProgress then onProgress(i, #inventories, "chest") end
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

-- Disk drives on a wired network, which any computer on it can use, sorted by name. Each has name,
-- and label if its floppy has one; one without a floppy has empty set.
function array.drives()
    local found = {}
    for name in pairs(reach()) do
        if peripheral.hasType(name, "drive") then
            local ok, hasData = pcall(disk.hasData, name)
            local drive = { name = name, empty = not (ok and hasData) }
            if not drive.empty then drive.label = disk.getLabel(name) end
            found[#found + 1] = drive
        end
    end
    table.sort(found, function(a, b) return a.name < b.name end)
    return found
end

-- Whether items can move between two chests from discover.
function array.connected(a, b)
    if not a.networks or not b.networks then return not a.networks and not b.networks end
    for modem in pairs(a.networks) do
        if b.networks[modem] then return true end
    end
    return false
end

-- The allowed chests that discover didn't find, sorted by name. A chest found under another name,
-- or that's there but can't be used, is still connected. The I/O chest is replaced, not removed.
function array.missing(config, chests, unlinked)
    local found = {}
    for _, list in ipairs({ chests, unlinked }) do
        for _, chest in ipairs(list) do
            found[chest.name] = true
            if chest.side then found[chest.side] = true end
        end
    end

    local names = {}
    for name in pairs(config.allowed) do
        if not found[name] and name ~= config.io then names[#names + 1] = name end
    end
    table.sort(names)
    return names
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

local BOOK = "minecraft:enchanted_book"

-- The name `detail` shows, with what an enchanted book holds: "Book: Sharpness V, Mending", or
-- "Its Own Name (Mending)" if it was renamed.
local function detailName(item, detail)
    local name = detail and detail.displayName or readable(item.name)
    if item.name ~= BOOK or not detail or type(detail.enchantments) ~= "table" then return name end
    local parts = {}
    for _, enchantment in ipairs(detail.enchantments) do
        parts[#parts + 1] = enchantment.displayName
            or readable(tostring(enchantment.name)) .. " " .. tostring(enchantment.level or "")
    end
    if #parts == 0 then return name end
    if name == "Enchanted Book" then return "Book: " .. table.concat(parts, ", ") end
    return name .. " (" .. table.concat(parts, ", ") .. ")"
end

-- Whether the index has a name for `item`. A book named before its enchantments were shown is asked again.
local function hasName(data, item)
    local name = data.names[keyOf(item)]
    if not name then return false end
    return item.name ~= BOOK or name:find("^Book: ") ~= nil or name:find("%)$") ~= nil
end

local function itemName(data, item)
    return item.nbt and data.names[keyOf(item)] or readable(item.name)
end

-- Reading the array ------------------------------------------------------------------------------

local function allowedNames(config)
    local names = {}
    for name in pairs(config.allowed) do
        if name ~= config.io then names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

-- Read one chest into the index. Returns false, leaving what the index had, if it doesn't answer.
-- Items with NBT can be renamed, so their names are asked for, but only once. So is each item's
-- stack size. An enchanted book's name says what's on it.
local function readChest(data, name)
    local contents, size = ask(name, "list"), ask(name, "size")
    if not contents or not size then return false end
    local chest = { size = size, slots = {} }
    for slot, item in pairs(contents) do
        chest.slots[slot] = { name = item.name, count = item.count, nbt = item.nbt }
        local key = keyOf(item)
        local needsName = item.nbt and not hasName(data, item)
        if needsName or not data.stacks[key] then
            local detail = ask(name, "getItemDetail", slot)
            if needsName then data.names[key] = detailName(item, detail) end
            if detail and detail.maxCount then data.stacks[key] = detail.maxCount end
        end
    end
    data.chests[name] = chest
    return true
end

-- Read each of `names` into the state's index, counting those that don't answer as offline.
local function readChests(state, names, onProgress)
    if onProgress and #names > 0 then onProgress(0, #names, "chest") end
    for i, name in ipairs(names) do
        if readChest(state.data, name) then
            state.changed[name] = true
        else
            state.offline = state.offline + 1
            state.answered[name] = nil
        end
        if onProgress then onProgress(i, #names, "chest") end
    end
end

-- The storage chests as the index has them. Each chest has name, free and holds.
-- Items are (key -> { key, id, name, count, stack, slots = { { chest, slot, count } } }), where stack
-- is how many fit in one stack, if that's known.
local function view(state)
    local chests, items = {}, {}
    for _, name in ipairs(state.names) do
        local saved = state.answered[name] and state.data.chests[name]
        if saved then
            local chest = { name = name, free = saved.size, holds = {} }
            chests[#chests + 1] = chest
            for _, slot in ipairs(sortedSlots(saved.slots)) do
                local item = saved.slots[slot]
                local key = keyOf(item)
                chest.free = chest.free - 1
                chest.holds[key] = true
                items[key] = items[key] or {
                    key = key, id = item.name, name = itemName(state.data, item), count = 0, slots = {},
                    stack = state.data.stacks[key],
                }
                items[key].count = items[key].count + item.count
                table.insert(items[key].slots, { chest = name, slot = slot, count = item.count })
            end
        end
    end
    return chests, items
end

-- The index, with every allowed chest that's connected in it. Only chests it doesn't have yet are
-- read. A chest that isn't connected counts as offline and is left out, but the index keeps it.
-- onProgress(done, total, "chest") is called as each one is read, and not at all if none are.
local function open(config, onProgress)
    local data, err = index.load(config)
    local state = {
        config = config, data = data, err = err, changed = {}, offline = 0,
        names = allowedNames(config), answered = {},
    }
    local unread = {}
    for _, name in ipairs(state.names) do
        if peripheral.isPresent(name) then
            state.answered[name] = true
            if not data.chests[name] then unread[#unread + 1] = name end
        else
            state.offline = state.offline + 1
        end
    end
    readChests(state, unread, onProgress)
    return state
end

-- Save what changed. Returns why it couldn't be, or nil.
local function close(state)
    if state.err then return state.err end
    if not next(state.changed) then return nil end
    local ok, err = index.save(state.config, state.data, state.changed)
    if not ok then return err end
end

local function byName(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.key < b.key
end

-- Everything in storage, sorted by name, how many chests didn't answer, and why the index couldn't
-- be saved, if it couldn't.
function array.items(config, onProgress)
    local state = open(config, onProgress)
    local _, items = view(state)
    local found = {}
    for _, item in pairs(items) do found[#found + 1] = item end
    table.sort(found, byName)
    return found, state.offline, close(state)
end

-- Forget what the index has for `names`, so that they're read again next time.
function array.forget(config, names)
    local data = index.load(config)
    local changed = {}
    for _, name in ipairs(names) do
        data.chests[name], changed[name] = nil, true
    end
    if next(changed) then index.save(config, data, changed) end
end

-- Read every allowed chest again, and replace the index with what they hold. Returns
-- { chests, items, offline, indexError }, where chests is how many were read and items how many they hold.
-- onProgress is called as for array.items.
function array.rebuild(config, onProgress)
    -- Names and stack sizes belong to the item, not the chest, so they're kept.
    local old = index.load(config)
    local state = {
        config = config, data = { chests = {}, names = old.names, stacks = old.stacks }, changed = {}, offline = 0,
        names = allowedNames(config), answered = {},
    }
    readChests(state, state.names, onProgress)
    local chests, items = 0, 0
    for _, chest in pairs(state.data.chests) do
        chests = chests + 1
        for _, item in pairs(chest.slots) do items = items + item.count end
    end
    local ok, err = index.save(config, state.data)
    return { chests = chests, items = items, offline = state.offline, indexError = not ok and err or nil }
end

-- Why the index can't be used, or nil if it can.
function array.indexProblem(config)
    local _, err = index.path(config)
    return err
end

-- Delete the index kept on this computer.
array.deleteLocalIndex = index.deleteLocal

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

-- Move as much of a slot as `chest` takes, and return how many moved. `touched` gets its name.
local function pushTo(touched, chest, from, slot, limit)
    touched[chest.name] = true
    local moved = ask(from, "pushItems", chest.name, slot, limit)
    if moved == nil then -- it has gone, so nothing else should try it
        chest.free, chest.holds = 0, {}
        return 0
    end
    return moved
end

-- Move a slot into the array, joining stacks of the same item first. Returns how many moved.
local function pushToArray(touched, chests, from, slot, key, count)
    local left = count
    for _, chest in ipairs(chests) do
        if left == 0 then break end
        if chest.holds[key] then left = left - pushTo(touched, chest, from, slot, left) end
    end
    for _, chest in ipairs(chests) do
        if left == 0 then break end
        if not chest.holds[key] and chest.free > 0 then
            local moved = pushTo(touched, chest, from, slot, left)
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
-- Returns { moved, left, offline, indexError }, where left didn't fit, or nil if the I/O chest has gone.
-- onProgress is called as for array.items, and then with (done, total, "stack") as each stack is moved.
-- The chests it moved items into are read again afterwards, since only they know which slots they used.
function array.store(config, key, limit, onProgress)
    local contents = ask(config.io, "list")
    if not contents then return nil end
    local state = open(config, onProgress)
    local chests = view(state)

    local slots = {}
    for _, slot in ipairs(sortedSlots(contents)) do
        if not key or keyOf(contents[slot]) == key then slots[#slots + 1] = slot end
    end

    local moved, wanted, touched = 0, 0, {}
    if onProgress and #slots > 0 then onProgress(0, #slots, "stack") end
    for i, slot in ipairs(slots) do
        local item = contents[slot]
        local count = item.count
        if limit then count = math.min(count, limit - wanted) end
        if count > 0 then
            wanted = wanted + count
            moved = moved + pushToArray(touched, chests, config.io, slot, keyOf(item), count)
        end
        if onProgress then onProgress(i, #slots, "stack") end
    end

    for name in pairs(touched) do
        if readChest(state.data, name) then state.changed[name] = true end
    end
    return { moved = moved, left = wanted - moved, offline = state.offline, indexError = close(state) }
end

-- Move the item `key` into the I/O chest: amount.count of them, amount.stacks stacks of them, or as
-- many as fit if amount is nil. The smallest stacks go first, so that storage gets slots back.
-- Returns { moved, left, full, offline, indexError }, where left stayed in the array and full is true if
-- the I/O chest filled up first, or nil if the I/O chest has gone. onProgress is called as for
-- array.store. The chests the index says hold it are read first, in case it's out of date.
function array.recall(config, key, amount, onProgress)
    if not ask(config.io, "size") then return nil end
    amount = amount or {}
    local state = open(config, onProgress)
    local _, items = view(state)
    local holders, seen = {}, {}
    for _, place in ipairs(items[key] and items[key].slots or {}) do
        if not seen[place.chest] then holders[#holders + 1], seen[place.chest] = place.chest, true end
    end
    readChests(state, holders, onProgress)

    _, items = view(state)
    local item = items[key]
    if not item then return { moved = 0, left = 0, full = false, offline = state.offline, indexError = close(state) } end

    local limit = amount.count or (amount.stacks and amount.stacks * (item.stack or 64)) or item.count
    local places = item.slots
    table.sort(places, function(a, b)
        if a.count ~= b.count then return a.count < b.count end
        if a.chest ~= b.chest then return a.chest < b.chest end
        return a.slot < b.slot
    end)
    -- Only the stacks it needs, so that the bar counts those.
    local planned, enough = 0, 0
    while planned < #places and enough < limit do
        planned = planned + 1
        enough = enough + places[planned].count
    end

    local moved, full = 0, false
    if onProgress and planned > 0 then onProgress(0, planned, "stack") end
    for i = 1, planned do
        local place = places[i]
        local wanted = math.min(place.count, limit - moved)
        local count = ask(place.chest, "pushItems", config.io, place.slot, wanted)
        if count then
            moved = moved + count
            local slots = state.data.chests[place.chest].slots
            slots[place.slot].count = place.count - count
            if count >= place.count then slots[place.slot] = nil end
            state.changed[place.chest] = true
            full = count < wanted
        end
        -- A full chest ends it early, so the bar jumps to the end with it.
        if onProgress then onProgress(full and planned or i, planned, "stack") end
        if full then break end
    end
    return { moved = moved, left = item.count - moved, full = full, offline = state.offline, indexError = close(state) }
end

return array
