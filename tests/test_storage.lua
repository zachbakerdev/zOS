-- Drives the real Storage app with scripted keys and a fake network of chests.
-- Run from the repository root: luajit tests/test_storage.lua
package.path = "tests/?.lua;" .. package.path

local sim = require("sim")

local failed, passed = 0, 0
local function check(name, ok)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name)
  end
end

local CONFIG = "etc/storage/config"
local STACK = 64

local function screenHas(c, text)
  local ok, err = pcall(sim.run, function() return c.screenText():find(text, 1, true) ~= nil end, 30)
  if not ok then
    print("Waiting for '" .. text .. "', the screen says:\n" .. c.screenText())
    error(err, 0)
  end
  return true
end

local function key(c, name) c.env.os.queueEvent("key", c.env.keys[name]) end
local function typed(c, text)
  for letter in text:gmatch(".") do c.env.os.queueEvent("char", letter) end
end

-- The screen row a piece of text is on.
local function rowOf(c, text)
  local y = 0
  for line in (c.screenText() .. "\n"):gmatch("(.-)\n") do
    y = y + 1
    if line:find(text, 1, true) then return y end
  end
end

local function finished(c)
  sim.run(function() return c.thread.done end, 30)
  return true
end

-- A chest of `size` slots. `stacks` is a list of { name, count, nbt } filling slots from 1.
local function chest(size, stacks)
  local slots = {}
  for i, s in ipairs(stacks or {}) do slots[i] = { name = s[1], count = s[2], nbt = s[3] } end
  return { size = size, slots = slots }
end

local function total(c, name)
  local count = 0
  for slot = 1, c.size do
    local item = c.slots[slot]
    if item and (not name or item.name == name) then count = count + item.count end
  end
  return count
end

-- Like the game, an inventory reached by its side can only see sides, and one reached over the
-- network can only see that network. `world.gone` names chests that have stopped answering.
local function fakePeripherals(env, world)
  local real = env.peripheral
  local function isSide(name) return world.sides[name] ~= nil end
  local function chestOf(name)
    if world.gone[name] then error("No peripheral attached", 0) end
    local c = world.sides[name] or world.net[name]
    if not c then error("No peripheral attached", 0) end
    return c
  end

  local function push(from, to, slot, limit)
    if isSide(from) ~= isSide(to) then error("Target '" .. to .. "' does not exist", 0) end
    local source, target = chestOf(from), chestOf(to)
    local item = source.slots[slot]
    if not item then return 0 end
    world.calls = world.calls + 1
    local left = math.min(item.count, limit or STACK)
    local moved = 0
    for i = 1, target.size do
      local there = target.slots[i]
      if left > 0 and there and there ~= item and there.name == item.name and there.nbt == item.nbt then
        local room = math.min(STACK - there.count, left)
        there.count, left, moved = there.count + room, left - room, moved + room
      end
    end
    for i = 1, target.size do
      if left > 0 and not target.slots[i] then
        target.slots[i] = { name = item.name, count = left, nbt = item.nbt }
        moved, left = moved + left, 0
      end
    end
    item.count = item.count - moved
    if item.count == 0 then source.slots[slot] = nil end
    return moved
  end

  env.peripheral = setmetatable({
    getNames = function()
      local names = real.getNames()
      names[#names + 1] = world.modem
      for name in pairs(world.sides) do names[#names + 1] = name end
      for name in pairs(world.net) do names[#names + 1] = name end
      table.sort(names)
      return names
    end,
    getType = function(name) return world.net[name] and name or "minecraft:chest" end,
    hasType = function(name, kind)
      if world.modem == name or name == "top" then return kind == "modem" end
      return kind == "inventory" and (world.sides[name] or world.net[name]) ~= nil
    end,
    call = function(name, method, ...)
      local a, b, limit = ...
      if method == "isWireless" then return name ~= world.modem end
      if method == "getNamesRemote" then
        local names = {}
        for remote in pairs(world.net) do names[#names + 1] = remote end
        table.sort(names)
        return names
      end
      if method == "size" then return chestOf(name).size end
      if method == "list" then
        local out = {}
        for slot, item in pairs(chestOf(name).slots) do out[slot] = sim.copy(item) end
        return out
      end
      if method == "getItemDetail" then
        local item = chestOf(name).slots[a]
        return item and { name = item.name, count = item.count, displayName = item.nbt and "Named " .. item.nbt }
      end
      if method == "pushItems" then return push(name, a, b, limit) end
      error("No such method " .. method, 0)
    end,
  }, { __index = real })
end

-- A computer running Storage. `world` has net (network name -> chest) and sides (side -> chest);
-- the same chest in both is one with a modem beside the computer.
local function start(world, files)
  for _, other in pairs(sim.computers) do sim.powerOff(other) end
  world.net, world.sides, world.gone, world.calls = world.net or {}, world.sides or {}, world.gone or {}, 0
  world.modem = world.modem or "back"
  local c = sim.computer(1, { files = files or {} })
  c.appDir = "apps/storage/"
  fakePeripherals(c.env, world)
  local fn = assert(loadfile("apps/storage/main.lua"))
  setfenv(fn, c.env)
  c.thread = sim.spawn(c, fn, { user = "me", admin = false }, { id = "storage" })
  return c
end

local function config(c) return c.env.require("util").readTable("/" .. CONFIG) end

-- A set-up computer with an I/O chest "io" and storage chests "a" and "b".
local function ready(ioChest, a, b, extra)
  local world = { net = { ["io"] = ioChest, ["a"] = a, ["b"] = b } }
  for name, value in pairs(extra or {}) do world.net[name] = value end
  local files = {}
  local c = start(world, files)
  c.env.require("util").writeTable("/" .. CONFIG, { io = "io", allowed = { a = true, b = true } })
  return c, world
end

local function recallFirst(c, search)
  screenHas(c, "Store all")
  key(c, "home")
  key(c, "down")
  key(c, "enter")
  screenHas(c, "Item:")
  typed(c, search)
end

-- First run ----------------------------------------------------------------------------------------

-- The chest beside the computer is the default, when its contents show which network chest it is.
do
  local beside = chest(27, { { "minecraft:dirt", 5 } })
  local world = {
    net = { ["minecraft:chest_0"] = chest(27), ["minecraft:chest_1"] = beside, ["minecraft:furnace_0"] = chest(3) },
    sides = { left = beside },
  }
  local files = {}
  local c = start(world, files)
  check("first run: asks for setup", screenHas(c, "Storage - Setup"))
  check("first run: defaults to the chest beside it", screenHas(c, "I/O chest: minecraft:chest_1"))
  check("first run: counts chests, not furnaces or itself", screenHas(c, "Storage chests: 1"))
  check("first run: saves nothing until asked", files[CONFIG] == nil)
  key(c, "down") key(c, "down") key(c, "enter")
  check("first run: moves on", screenHas(c, "Store all"))
  local cfg = config(c)
  check("first run: saves the chest", cfg.io == "minecraft:chest_1")
  check("first run: not storing in the I/O chest", not cfg.allowed["minecraft:chest_1"])
  check("first run: storage is allowed", cfg.allowed["minecraft:chest_0"])
  check("first run: a furnace isn't", not cfg.allowed["minecraft:furnace_0"])
end

-- An empty chest looks like every other empty chest, so it takes an item to find it.
do
  local beside = chest(27)
  local world = { net = { ["chest0"] = chest(27), ["chest1"] = beside, ["chest2"] = chest(27) }, sides = { left = beside } }
  local c = start(world)
  check("empty: asks for an item", screenHas(c, "Put any item in the chest next to the computer"))
  sim.advance(2)
  beside.slots[1] = { name = "minecraft:dirt", count = 1 }
  check("empty: finds it", screenHas(c, "I/O chest: chest1"))
end

-- Without a modem of its own, the chest can't reach the network, whatever the contents say.
do
  local world = { net = { ["chest0"] = chest(27, { { "minecraft:dirt", 1 } }) }, sides = { left = chest(27, { { "minecraft:stone", 1 } }) } }
  local c = start(world)
  check("no modem: says what to do", screenHas(c, "Put a wired modem on the"))
  key(c, "enter")
  check("no modem: nothing chosen", screenHas(c, "I/O chest: not set"))
  key(c, "down") key(c, "down") key(c, "enter")
  check("no modem: can't save without an I/O chest", screenHas(c, "Choose an I/O chest first"))
end

-- Changing a chest beside the computer that has no modem explains why it can't be used.
do
  local side = chest(27)
  local world = { net = { ["chest0"] = chest(27), ["chest1"] = chest(27) }, sides = { left = side } }
  local c = start(world)
  screenHas(c, "Put any item in the chest next to the computer")
  sim.advance(2)
  side.slots[1] = { name = "minecraft:dirt", count = 1 }
  check("no modem, empty: says what to do", screenHas(c, "Put a wired modem on the"))
end

-- Find a chest that isn't beside the computer, and turn one off.
do
  local target = chest(27)
  local world = { net = { ["chest0"] = chest(27), ["chest1"] = target, ["chest2"] = chest(27) } }
  local c = start(world)
  check("no default: asks", screenHas(c, "I/O chest: not set"))
  key(c, "enter")
  check("io menu: offers to find it", screenHas(c, "Find it by adding an item"))
  key(c, "enter")
  screenHas(c, "Put any item in the chest to use")
  sim.advance(2)
  target.slots[1] = { name = "minecraft:dirt", count = 1 }
  check("find: chooses the changed chest", screenHas(c, "I/O chest: chest1"))
  check("find: leaves two for storage", screenHas(c, "Storage chests: 2"))

  key(c, "down") key(c, "enter")
  check("toggle: lists chests", screenHas(c, "[x] chest0"))
  check("toggle: leaves out the I/O chest", not c.screenText():find("chest1", 1, true))
  key(c, "enter")
  check("toggle: turns one off", screenHas(c, "[ ] chest0"))
  key(c, "backspace")
  check("toggle: counted", screenHas(c, "Storage chests: 1"))
  key(c, "down") key(c, "enter")
  screenHas(c, "Store all")
  check("toggle: saved", not config(c).allowed.chest0 and config(c).allowed.chest2)
end

-- Two chests changing together, like one fed by a hopper, don't count.
do
  local one, two, three = chest(27), chest(27), chest(27)
  local c = start({ net = { chest0 = one, chest1 = two, chest2 = three } })
  screenHas(c, "I/O chest: not set")
  key(c, "enter") screenHas(c, "Find it") key(c, "enter")
  screenHas(c, "Put any item in the chest to use")
  sim.advance(2)
  one.slots[1], two.slots[1] = { name = "x:a", count = 1 }, { name = "x:a", count = 1 }
  sim.advance(2)
  check("find: ignores several changes", screenHas(c, "Put any item in the chest to use"))
  three.slots[1] = { name = "x:a", count = 1 }
  check("find: then finds one", screenHas(c, "I/O chest: chest2"))
end

do
  local c = start({})
  check("no chests: says so", screenHas(c, "No chests found"))
  key(c, "backspace")
  check("no chests: backspace leaves", finished(c))
  check("no chests: nothing saved", not c.files[CONFIG])
end

-- With no network at all, chests beside the computer can use each other.
do
  local left, right = chest(27, { { "x:a", 4 } }), chest(27)
  local c = start({ sides = { left = left, right = right } })
  screenHas(c, "I/O chest: left")
  key(c, "down") key(c, "down") key(c, "enter")
  screenHas(c, "Store all")
  key(c, "enter")
  check("sides: stores", screenHas(c, "Stored 4 items"))
  check("sides: moved", total(right) == 4 and total(left) == 0)
end

-- Settings keep what's there.
do
  local c = ready(chest(27), chest(27), chest(27), { spare = chest(27) })
  screenHas(c, "Store all")
  key(c, "down") key(c, "down") key(c, "enter")
  screenHas(c, "I/O chest: io")
  check("settings: keeps the count", screenHas(c, "Storage chests: 2"))
  key(c, "down") key(c, "enter")
  check("settings: a new chest starts off", screenHas(c, "[ ] spare"))
  key(c, "backspace") key(c, "backspace")
  check("settings: back returns", screenHas(c, "Store all"))
  check("settings: back saves nothing", not config(c).allowed.spare)
end

-- Reading the chests shows a loading bar, but only if there are chests to read.
do
  local function barsDuring(world, press)
    local c = start(world)
    local seen = {}
    local listed = {}
    local real = c.env.peripheral.call
    c.env.peripheral = setmetatable({
      call = function(name, method, ...)
        if method == "list" and not listed[name] then
          listed[name] = true
          seen[#seen + 1] = c.screenText()
        end
        return real(name, method, ...)
      end,
    }, { __index = c.env.peripheral })
    if press then press(c) end
    return c, seen
  end

  local c, seen = barsDuring({ net = { a = chest(27), b = chest(27), d = chest(27), e = chest(27) } })
  check("loading: reaches the setup screen", screenHas(c, "I/O chest"))
  local shown = table.concat(seen, "\n")
  check("loading: says what it's doing", shown:find("Looking for chests", 1, true) ~= nil)
  check("loading: shows the bar", shown:find("50%", 1, true) ~= nil and shown:find("=-", 1, true) ~= nil)
  check("loading: counts the chests", shown:find("Read 2 of 4 chests", 1, true) ~= nil)

  local empty = barsDuring({})
  check("loading: no chests", screenHas(empty, "No chests found"))
  check("loading: nothing to draw", empty.screenText():find("---", 1, true) == nil)

  local c2 = start({ net = { a = chest(27), b = chest(27) } })
  local steps = {}
  local function read()
    c2.env.require("array").discover(function(done, total) steps[#steps + 1] = done .. "/" .. total end)
  end
  sim.call(c2, read)
  check("loading: steps reach the end", table.concat(steps, " ") == "0/2 1/2 2/2")

  local c3 = start({})
  local called = false
  sim.call(c3, function() c3.env.require("array").discover(function() called = true end) end)
  check("loading: no progress without chests", not called)
end

-- Storing ------------------------------------------------------------------------------------------

do
  local io = chest(27, { { "minecraft:iron_ingot", 10 }, { "minecraft:dirt", 64 } })
  local a = chest(2, { { "minecraft:stone", 64 } })
  local b = chest(27, { { "minecraft:iron_ingot", 10 } })
  local c = ready(io, a, b, { other = chest(27, { { "minecraft:gold_ingot", 3 } }) })
  screenHas(c, "Store all")
  key(c, "enter")
  check("store: reports", screenHas(c, "Stored 74 items"))
  check("store: empties the I/O chest", total(io) == 0)
  check("store: joins existing stacks", b.slots[1].count == 20 and b.slots[2] == nil)
  check("store: uses free space", a.slots[2].name == "minecraft:dirt")
end

do
  local io = chest(27, { { "x:a", 64 }, { "x:b", 64 }, { "x:c", 64 } })
  local c = ready(io, chest(1), chest(1))
  screenHas(c, "Store all")
  key(c, "enter")
  check("store full: says so", screenHas(c, "Storage is full, so 64 stayed"))
  check("store full: keeps the rest", total(io) == 64)
end

do
  local io = chest(27, { { "x:a", 1 } })
  local b = chest(27)
  local c, world = ready(io, chest(27), b)
  world.gone.a = true
  screenHas(c, "Store all")
  key(c, "enter")
  check("offline: uses the others", screenHas(c, "Stored 1 item."))
  check("offline: says so", screenHas(c, "1 storage chest didn't respond"))
  check("offline: moved", total(b) == 1)
end

do
  local c, world = ready(chest(27), chest(27), chest(27))
  world.gone.io = true
  screenHas(c, "Store all")
  key(c, "enter")
  check("no I/O chest: says so", screenHas(c, "isn't connected"))
end

-- Recalling ----------------------------------------------------------------------------------------

do
  local io = chest(27)
  local a = chest(27, { { "minecraft:iron_ingot", 64 }, { "minecraft:dirt", 5 } })
  local b = chest(27, { { "minecraft:iron_ingot", 36 } })
  local c = ready(io, a, b)
  recallFirst(c, "iron in")
  screenHas(c, "1/2")
  check("search: matches the readable name", screenHas(c, "Iron Ingot x100"))
  check("search: leaves out others", not c.screenText():find("Dirt", 1, true))
  key(c, "enter")
  check("recall: reports", screenHas(c, "Recalled 100 Iron Ingot."))
  check("recall: all of them", total(io, "minecraft:iron_ingot") == 100 and total(a, "minecraft:iron_ingot") == 0)
  check("recall: highlights return", screenHas(c, "Return items to storage"))
  key(c, "backspace")
  c.env.os.queueEvent("char", "q")
  sim.advance(1)
  check("recall: return is the only way on", screenHas(c, "Return items to storage"))

  -- Someone takes some out.
  io.slots[1] = nil
  key(c, "enter")
  check("return: reports", screenHas(c, "Stored 36 items"))
  check("return: back in the array", total(io) == 0 and total(a) + total(b) == 41)
  key(c, "enter")
  check("return: on to the menu", screenHas(c, "Store all"))
end

-- Stops when the chest is full, and only returns what it recalled.
do
  local io = chest(2, { { "minecraft:dirt", 7 } })
  local a = chest(27, { { "minecraft:iron_ingot", 64 }, { "minecraft:iron_ingot", 64 }, { "minecraft:iron_ingot", 64 } })
  local c = ready(io, a, chest(27))
  recallFirst(c, "IRON")
  screenHas(c, "Iron Ingot x192")
  key(c, "enter")
  check("full: stops at the chest's size", screenHas(c, "Recalled 64 Iron Ingot."))
  check("full: says what's left", screenHas(c, "128 stayed in storage"))
  check("full: left in storage", total(a) == 128 and total(io, "minecraft:dirt") == 7)
  c.env.os.queueEvent("mouse_click", 1, 5, rowOf(c, "Return items"))
  check("return by click", screenHas(c, "Stored 64 items"))
  check("return: leaves what was already there", total(a) == 192 and total(io, "minecraft:dirt") == 7)
end

-- A full chest recalls nothing, so there's nothing to return.
do
  local c = ready(chest(1, { { "minecraft:dirt", 64 } }), chest(27, { { "minecraft:stone", 3 } }), chest(27))
  recallFirst(c, "stone")
  screenHas(c, "Stone x3")
  key(c, "enter")
  check("recall into a full chest", screenHas(c, "The I/O chest is full"))
  key(c, "enter")
  check("recall into a full chest: back to the menu", screenHas(c, "Store all"))
end

-- Items that differ by NBT are told apart, and renamed ones can be found by their name.
do
  local io = chest(27)
  local a = chest(27, { { "minecraft:diamond_sword", 1, "aaa" }, { "minecraft:diamond_sword", 1, "bbb" } })
  local c = ready(io, a, chest(27))
  recallFirst(c, "named bbb")
  screenHas(c, "1/2")
  check("nbt: found by display name", screenHas(c, "Named bbb x1"))
  check("nbt: only that one", not c.screenText():find("Named aaa", 1, true))
  key(c, "enter")
  screenHas(c, "Recalled 1 Named bbb")
  check("nbt: moved the right one", io.slots[1].nbt == "bbb" and a.slots[1].nbt == "aaa")
end

do
  local c = ready(chest(27), chest(27, { { "x:a", 1 } }), chest(27, { { "x:b", 1 } }))
  recallFirst(c, "")
  check("blank search lists all", screenHas(c, "A x1") and screenHas(c, "B x1"))
  key(c, "backspace")
  check("back from results", screenHas(c, "Store all"))
  recallFirst(c, "zzz")
  check("no matches", screenHas(c, "Nothing matches that"))
  key(c, "enter")
  key(c, "down")
  sim.advance(1)
  check("no matches: enter picks nothing", screenHas(c, "Nothing matches that"))
  key(c, "backspace") key(c, "backspace") key(c, "backspace")
  check("backspace edits the text", screenHas(c, "A x1"))
  key(c, "backspace")
  check("backspace on empty text cancels", screenHas(c, "Store all"))
end

-- Letters only have to appear in order, and the best fit comes first and starts highlighted.
do
  local io = chest(27)
  local a = chest(27, {
    { "minecraft:iron_ingot", 3 }, { "minecraft:string", 4 }, { "minecraft:diamond", 5 }, { "minecraft:iron_block", 6 },
  })
  local c = ready(io, a, chest(27))
  recallFirst(c, "irin")
  screenHas(c, "1/4")
  check("fuzzy: letters in order", screenHas(c, "Iron Ingot x3"))
  check("fuzzy: leaves out others", not c.screenText():find("Diamond", 1, true))
  key(c, "backspace") key(c, "backspace") key(c, "backspace") key(c, "backspace")
  screenHas(c, "4/4")
  typed(c, "ing")
  screenHas(c, "2/4")
  check("fuzzy: a whole word beats letters in a word", rowOf(c, "Iron Ingot x3") < rowOf(c, "String x4"))
  check("fuzzy: starts on the first", screenHas(c, "minecraft:iron_ingot"))
  key(c, "down")
  check("arrows: move down", screenHas(c, "minecraft:string"))
  key(c, "down")
  check("arrows: wrap", screenHas(c, "minecraft:iron_ingot"))
  key(c, "up")
  check("arrows: wrap back", screenHas(c, "minecraft:string"))
  typed(c, "o")
  check("typing goes back to the first", screenHas(c, "minecraft:iron_ingot"))
  key(c, "backspace")
  key(c, "down")
  screenHas(c, "minecraft:string")
  key(c, "enter")
  check("enter recalls the highlighted one", screenHas(c, "Recalled 4 String"))
  check("recall: moved it", total(io, "minecraft:string") == 4 and total(io, "minecraft:iron_ingot") == 0)
end

-- Holding backspace clears the text, but takes another press to leave.
do
  local c = ready(chest(27), chest(27, { { "x:a", 1 } }), chest(27))
  recallFirst(c, "a")
  screenHas(c, "1/1")
  c.env.os.queueEvent("key", c.env.keys.backspace, true)
  c.env.os.queueEvent("key", c.env.keys.backspace, true)
  check("held backspace stays", screenHas(c, "Backspace: cancel"))
  sim.advance(1)
  check("held backspace doesn't cancel", screenHas(c, "Item:"))
  key(c, "backspace")
  check("a new press does", screenHas(c, "Store all"))
end

-- Long lists scroll, and a click takes the row under it.
do
  local stacks = {}
  for i = 1, 20 do stacks[i] = { ("x:item%02d"):format(i), i } end
  local io = chest(27)
  local c = ready(io, chest(27, stacks), chest(27))
  recallFirst(c, "")
  screenHas(c, "Item01 x1")
  for _ = 1, 15 do key(c, "down") end
  check("scrolls to the highlight", screenHas(c, "Item16 x16"))
  check("scrolls the top away", not c.screenText():find("Item01", 1, true))
  c.env.os.queueEvent("mouse_click", 1, 5, rowOf(c, "Item16 x16"))
  check("click picks the row", screenHas(c, "Recalled 16 Item16"))
end

do
  local c = ready(chest(27), chest(27), chest(27))
  screenHas(c, "Store all")
  key(c, "home") key(c, "down") key(c, "enter")
  check("empty storage: says so", screenHas(c, "There's nothing in storage"))
end

do
  local c, world = ready(chest(27), chest(27, { { "x:a", 1 } }), chest(27))
  world.gone.b = true
  recallFirst(c, "zzz")
  check("offline: said when nothing matches", screenHas(c, "1 storage chest didn't respond"))
end

-- Chests that weren't allowed are left alone.
do
  local other = chest(27, { { "x:secret", 9 } })
  local c = ready(chest(27), chest(27, { { "x:a", 1 } }), chest(27), { other = other })
  recallFirst(c, "secret")
  check("not allowed: not searched", screenHas(c, "Nothing matches that"))
  check("not allowed: untouched", total(other) == 9)
end

if failed > 0 then
  print(("%d passed, %d FAILED"):format(passed, failed))
  os.exit(1)
end
print(("storage: all %d passed"):format(passed))
