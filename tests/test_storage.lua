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
-- network can only see that network. `world.gone` names chests that have stopped answering, and
-- `world.stacks` gives item ids a stack size other than 64. `world.names` and `world.enchantments`
-- give items with that NBT a display name and enchantments.
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

  -- Disk drives on the network: name -> { mount, label }, with no mount for one without a floppy.
  env.disk = {
    hasData = function(name) return world.drives[name] ~= nil and world.drives[name].mount ~= nil end,
    getMountPath = function(name) return world.drives[name] and world.drives[name].mount end,
    getLabel = function(name) return world.drives[name] and world.drives[name].label end,
  }

  env.peripheral = setmetatable({
    getNames = function()
      local names = real.getNames()
      names[#names + 1] = world.modem
      for name in pairs(world.sides) do names[#names + 1] = name end
      for name in pairs(world.net) do names[#names + 1] = name end
      for name in pairs(world.drives) do names[#names + 1] = name end
      table.sort(names)
      return names
    end,
    isPresent = function(name)
      return not world.gone[name] and (world.sides[name] or world.net[name] or world.drives[name]) ~= nil
    end,
    getType = function(name) return world.net[name] and name or "minecraft:chest" end,
    hasType = function(name, kind)
      if world.modem == name or name == "top" then return kind == "modem" end
      if world.drives[name] then return kind == "drive" end
      return kind == "inventory" and (world.sides[name] or world.net[name]) ~= nil
    end,
    call = function(name, method, ...)
      local a, b, limit = ...
      if method == "isWireless" then return name ~= world.modem end
      if method == "getNamesRemote" then
        local names = {}
        for remote in pairs(world.net) do names[#names + 1] = remote end
        for remote in pairs(world.drives) do names[#names + 1] = remote end
        table.sort(names)
        return names
      end
      if method == "size" then return chestOf(name).size end
      if method == "list" then
        world.lists = (world.lists or 0) + 1
        local out = {}
        for slot, item in pairs(chestOf(name).slots) do out[slot] = sim.copy(item) end
        return out
      end
      if method == "getItemDetail" then
        local item = chestOf(name).slots[a]
        world.details = (world.details or 0) + 1
        return item and {
          name = item.name, count = item.count,
          displayName = world.names and world.names[item.nbt]
            or (item.name == "minecraft:enchanted_book" and "Enchanted Book")
            or (item.nbt and "Named " .. item.nbt),
          maxCount = world.stacks and world.stacks[item.name] or STACK,
          enchantments = world.enchantments and world.enchantments[item.nbt],
        }
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
  world.drives = world.drives or {}
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

-- Pick the highlighted item, and recall `amount` of it, or fill the I/O chest if that's nil.
local function pick(c, amount)
  key(c, "enter")
  screenHas(c, "Amount:")
  typed(c, amount or "")
  key(c, "enter")
end

-- Pick the highlighted item when only one is stored, which recalls it without asking how many.
local function pickOnly(c)
  key(c, "enter")
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
  key(c, "home") key(c, "up") key(c, "enter")
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
  key(c, "home") key(c, "up") key(c, "enter")
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
  key(c, "home") key(c, "up") key(c, "enter")
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
  key(c, "home") key(c, "up") key(c, "enter")
  screenHas(c, "Store all")
  key(c, "enter")
  check("sides: stores", screenHas(c, "Stored 4 items"))
  check("sides: moved", total(right) == 4 and total(left) == 0)
end

-- Settings keep what's there.
do
  local c = ready(chest(27), chest(27), chest(27), { spare = chest(27) })
  screenHas(c, "Store all")
  key(c, "end") key(c, "up") key(c, "enter")
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

-- Removing chests that have gone from the settings.
do
  local function settings(c)
    screenHas(c, "Store all")
    key(c, "end") key(c, "up") key(c, "enter")
    screenHas(c, "I/O chest: io")
  end

  local c = ready(chest(27), chest(27), chest(27))
  settings(c)
  check("disconnected: hidden with nothing to remove", not c.screenText():find("Disconnected", 1, true))

  local world = { net = { io = chest(27), a = chest(27), b = chest(27) } }
  c = start(world)
  c.env.require("util").writeTable("/" .. CONFIG, { io = "io", allowed = { a = true, gone1 = true, gone2 = true, gone3 = true } })
  settings(c)
  check("disconnected: counted", screenHas(c, "Disconnected chests: 3"))
  check("disconnected: doesn't count towards storage", screenHas(c, "Storage chests: 1"))
  key(c, "down") key(c, "down") key(c, "enter")
  check("disconnected: lists them", screenHas(c, "gone2"))
  key(c, "down") key(c, "enter")
  sim.advance(1)
  check("disconnected: removes one", screenHas(c, "gone3") and not c.screenText():find("gone2", 1, true))
  key(c, "down") key(c, "down") key(c, "enter")
  check("disconnected: done goes back", screenHas(c, "Disconnected chests: 2"))
  check("disconnected: not saved yet", config(c).allowed.gone2)
  key(c, "enter")
  screenHas(c, "Remove all")
  key(c, "down") key(c, "down") key(c, "enter")
  check("disconnected: the entry goes with the last one", screenHas(c, "Save"))
  sim.advance(1)
  check("disconnected: all removed", not c.screenText():find("Disconnected", 1, true))
  key(c, "home") key(c, "up") key(c, "enter")
  screenHas(c, "Store all")
  local cfg = config(c)
  check("disconnected: saved", not cfg.allowed.gone1 and not cfg.allowed.gone2 and not cfg.allowed.gone3)
  check("disconnected: keeps the others", cfg.allowed.a)
end

-- Going back throws the removal away, and a missing I/O chest is left to be replaced.
do
  local world = { net = { io = chest(27), a = chest(27) } }
  local c = start(world)
  c.env.require("util").writeTable("/" .. CONFIG, { io = "gone", allowed = { a = true, b = true } })
  screenHas(c, "Store all")
  key(c, "end") key(c, "up") key(c, "enter")
  check("disconnected: one left", screenHas(c, "Disconnected chests: 1"))
  key(c, "down") key(c, "down") key(c, "enter")
  screenHas(c, "Remove all")
  key(c, "down") key(c, "enter")
  sim.advance(1)
  screenHas(c, "I/O chest: gone")
  check("disconnected: removed for now", not c.screenText():find("Disconnected", 1, true))
  key(c, "backspace")
  screenHas(c, "Store all")
  check("disconnected: back saves nothing", config(c).allowed.b)
end

-- A chest that's found by another name, or that's there but can't be used, hasn't gone.
do
  local c = start({})
  local missing = c.env.require("array").missing({ io = "io", allowed = { left = true, right = true, far = true } },
    { { name = "chest0", side = "left" } }, { { name = "right" } })
  check("missing: only what wasn't found", #missing == 1 and missing[1] == "far")
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

-- Storing and recalling read the chests and then move items, with a bar for each.
do
  local function watch(c)
    local seen = {}
    local real = c.env.peripheral.call
    c.env.peripheral = setmetatable({
      call = function(name, method, ...)
        if method == "list" or method == "pushItems" then seen[#seen + 1] = c.screenText() end
        return real(name, method, ...)
      end,
    }, { __index = c.env.peripheral })
    return seen
  end
  local function saw(seen, text)
    return table.concat(seen, "\n"):find(text, 1, true) ~= nil
  end

  local io = chest(27, { { "x:a", 1 }, { "x:b", 1 } })
  local c = ready(io, chest(27), chest(27))
  local seen = watch(c)
  screenHas(c, "Store all")
  key(c, "enter")
  screenHas(c, "Stored 2 items")
  check("store bar: says what it's doing", saw(seen, "Storing items"))
  check("store bar: reads the chests", saw(seen, "Read 1 of 2 chests"))
  check("store bar: moves the stacks", saw(seen, "Moved 1 of 2 stacks"))
  check("store bar: draws the bar", saw(seen, "50%"))

  local c2 = ready(chest(27), chest(27, { { "x:a", 64 }, { "x:a", 64 } }), chest(27, { { "x:b", 1 } }))
  local seen2 = watch(c2)
  recallFirst(c2, "a")
  check("recall bar: searching reads the chests", saw(seen2, "Read 1 of 2 chests"))
  screenHas(c2, "A x128")
  for i = #seen2, 1, -1 do seen2[i] = nil end
  pick(c2)
  screenHas(c2, "Recalled 128 A")
  check("recall bar: says what it's doing", saw(seen2, "Recalling A"))
  check("recall bar: moves the stacks", saw(seen2, "Moved 1 of 2 stacks"))

  local c3 = ready(chest(27, { { "x:a", 1 }, { "x:b", 1 } }), chest(27, { { "x:a", 1 } }), chest(27))
  local steps = {}
  sim.call(c3, function()
    local array = c3.env.require("array")
    array.store(array.load() or { io = "io", allowed = { a = true, b = true } }, "x:a#nil", nil, function(done, total, kind)
      steps[#steps + 1] = done .. "/" .. total .. kind
    end)
  end)
  check("store bar: counts only what it'll move",
    table.concat(steps, " ") == "0/2chest 1/2chest 2/2chest 0/1stack 1/1stack")

  -- Recalling counts only the stacks it needs, and finishes the bar when the I/O chest fills up.
  local function recallSteps(ioChest, a, amount)
    local c4 = ready(ioChest, a, chest(27))
    local recallSteps = {}
    sim.call(c4, function()
      local array = c4.env.require("array")
      array.recall({ io = "io", allowed = { a = true, b = true } }, "x:a#nil", amount, function(done, total, kind)
        if kind == "stack" then recallSteps[#recallSteps + 1] = done .. "/" .. total end
      end)
    end)
    return table.concat(recallSteps, " ")
  end
  check("recall bar: only the stacks it needs",
    recallSteps(chest(27), chest(27, { { "x:a", 64 }, { "x:a", 64 }, { "x:a", 64 } }), { count = 70 }) == "0/2 1/2 2/2")
  check("recall bar: ends when the chest is full",
    recallSteps(chest(1), chest(27, { { "x:a", 64 }, { "x:a", 64 }, { "x:a", 64 } })) == "0/3 1/3 3/3")
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
  pick(c)
  check("recall: reports", screenHas(c, "Recalled 100 Iron Ingot."))
  check("recall: all of them", total(io, "minecraft:iron_ingot") == 100 and total(a, "minecraft:iron_ingot") == 0)
  check("recall: back to the list", screenHas(c, "Item:") and screenHas(c, "Dirt x5"))
  check("recall: gone from the list", not c.screenText():find("Iron Ingot x", 1, true))
  typed(c, "d")
  sim.advance(1)
  check("recall: typing clears the report", not c.screenText():find("Recalled", 1, true))
  key(c, "backspace") key(c, "backspace")
  check("recall: back to the menu", screenHas(c, "Store all"))
  check("recall: items stay in the I/O chest", total(io, "minecraft:iron_ingot") == 100)
end

-- Several items can be recalled one after another.
do
  local io = chest(27)
  local a = chest(27, { { "minecraft:iron_ingot", 10 }, { "minecraft:stick", 5 }, { "minecraft:coal", 8 } })
  local c = ready(io, a, chest(27))
  recallFirst(c, "iron")
  pick(c)
  screenHas(c, "Recalled 10 Iron Ingot.")
  typed(c, "stick")
  screenHas(c, "Stick x5")
  pick(c, "3")
  check("several: reports the second", screenHas(c, "Recalled 3 Stick."))
  check("several: shows what's left", screenHas(c, "Stick x2"))
  check("several: both in the I/O chest", total(io, "minecraft:iron_ingot") == 10 and total(io, "minecraft:stick") == 3)
end

-- Stops when the chest is full.
do
  local io = chest(2, { { "minecraft:dirt", 7 } })
  local a = chest(27, { { "minecraft:iron_ingot", 64 }, { "minecraft:iron_ingot", 64 }, { "minecraft:iron_ingot", 64 } })
  local c = ready(io, a, chest(27))
  recallFirst(c, "IRON")
  screenHas(c, "Iron Ingot x192")
  pick(c)
  check("full: stops at the chest's size", screenHas(c, "Recalled 64 Iron Ingot."))
  check("full: says what's left", screenHas(c, "128 stayed in storage"))
  check("full: left in storage", total(a) == 128 and total(io, "minecraft:dirt") == 7)
end

-- A full chest recalls nothing.
do
  local c = ready(chest(1, { { "minecraft:dirt", 64 } }), chest(27, { { "minecraft:stone", 3 } }), chest(27))
  recallFirst(c, "stone")
  screenHas(c, "Stone x3")
  pick(c)
  check("recall into a full chest", screenHas(c, "The I/O chest is full"))
  check("recall into a full chest: still listed", screenHas(c, "Stone x3"))
end

-- How many to recall: a number of items, or of stacks with an s after it, smallest stacks first.
do
  local io = chest(27)
  local a = chest(27, { { "minecraft:iron_ingot", 64 }, { "minecraft:iron_ingot", 10 }, { "minecraft:iron_ingot", 64 } })
  local b = chest(27, { { "minecraft:iron_ingot", 36 } })
  local c = ready(io, a, b)
  recallFirst(c, "iron")
  check("stacks: shown in the list", screenHas(c, "Iron Ingot x174 (2s+46)"))
  key(c, "enter")
  check("amount: asked", screenHas(c, "Amount:"))
  check("amount: explains stacks", screenHas(c, "2s is 128"))
  typed(c, "0s12s3x")
  check("amount: only a number and an s", screenHas(c, "Amount: 12s") and not c.screenText():find("12s3", 1, true))
  key(c, "backspace") key(c, "backspace") key(c, "backspace")
  typed(c, "40")
  key(c, "enter")
  check("amount: that many", screenHas(c, "Recalled 40 Iron Ingot."))
  check("amount: smallest stacks first", total(io) == 40 and a.slots[2] == nil and total(b) == 6 and total(a) == 128)

  pick(c, "1s")
  check("amount: a stack", screenHas(c, "Recalled 64 Iron Ingot."))
  check("amount: a stack from the smallest", total(io) == 104 and total(b) == 0 and total(a) == 70)

  pick(c, "500")
  check("amount: more than there are", screenHas(c, "Recalled 70 Iron Ingot. That's all there were."))
  check("amount: all of them", total(io) == 174)
end

-- Backspace goes back from the amount to the list, and an item that doesn't stack isn't counted in stacks.
do
  local io = chest(27)
  local a = chest(27, { { "minecraft:diamond_sword", 1 }, { "minecraft:diamond_sword", 1 }, { "minecraft:diamond_sword", 1 } })
  local c, world = ready(io, a, chest(27))
  world.stacks = { ["minecraft:diamond_sword"] = 1 }
  recallFirst(c, "sword")
  check("unstackable: no stacks shown", screenHas(c, "Diamond Sword x3") and not c.screenText():find("(3s)", 1, true))
  key(c, "enter")
  check("unstackable: a stack is one", screenHas(c, "2s is 2."))
  typed(c, "1")
  key(c, "backspace") key(c, "backspace")
  check("amount: backspace goes back", screenHas(c, "Item:"))
  check("amount: nothing recalled", total(io) == 0)
  pick(c, "2s")
  check("unstackable: stacks of one", screenHas(c, "Recalled 2 Diamond Sword."))
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
  pickOnly(c)
  check("only one: recalled without asking how many", screenHas(c, "Recalled 1 Named bbb.")
    and not c.screenText():find("Amount:", 1, true))
  check("only one: no note that it was all of them", not c.screenText():find("all there were", 1, true))
  check("nbt: moved the right one", io.slots[1].nbt == "bbb" and a.slots[1].nbt == "aaa")
end

-- Enchanted books are named after what's on them.
do
  local BOOK = "minecraft:enchanted_book"
  local io = chest(27)
  local a = chest(27, { { BOOK, 1, "s5" }, { BOOK, 1, "mu" }, { BOOK, 1, "lucky" }, { BOOK, 1, "odd" } })
  local c, world = ready(io, a, chest(27))
  world.enchantments = {
    s5 = { { name = "minecraft:sharpness", level = 5, displayName = "Sharpness V" } },
    mu = {
      { name = "minecraft:mending", level = 1, displayName = "Mending" },
      { name = "minecraft:unbreaking", level = 3, displayName = "Unbreaking III" },
    },
    lucky = { { name = "minecraft:fortune", level = 3, displayName = "Fortune III" } },
    odd = { { name = "minecraft:frost_walker", level = 2 } },
  }
  world.names = { lucky = "Lucky" }
  recallFirst(c, "")
  check("book: its enchantment", screenHas(c, "Book: Sharpness V x1"))
  check("book: all of them", screenHas(c, "Book: Mending, Unbreaking III x1"))
  check("book: renamed", screenHas(c, "Lucky (Fortune III) x1"))
  check("book: no display name", screenHas(c, "Book: Frost Walker 2 x1"))
  typed(c, "mending")
  screenHas(c, "1/4")
  check("book: found by enchantment", screenHas(c, "Book: Mending, Unbreaking III"))
  pickOnly(c)
  check("book: recalled", screenHas(c, "Recalled 1 Book: Mending, Unbreaking III."))
  check("book: the right one", total(io) == 1 and io.slots[1].nbt == "mu")
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
  pick(c)
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
  screenHas(c, "Amount:")
  key(c, "enter")
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

-- The item index ------------------------------------------------------------------------------------

local INDEX = "etc/storage/index"

local function settings(c)
  screenHas(c, "Store all")
  key(c, "end") key(c, "up") key(c, "enter")
  screenHas(c, "Item index:")
end

local function menuTo(c, label)
  for _ = 1, 10 do
    local row = rowOf(c, label)
    if row then
      c.env.os.queueEvent("mouse_click", 1, 2, row)
      return
    end
    sim.advance(1)
  end
  error("no " .. label .. " on screen:\n" .. c.screenText())
end

local function backToMenu(c)
  sim.advance(1)
  key(c, "enter")
  screenHas(c, "Store all")
end

-- The chests are read once, and after that the index answers.
do
  local a = chest(27, { { "x:a", 5 } })
  local c, world = ready(chest(27), a, chest(27, { { "x:b", 2 } }))
  recallFirst(c, "")
  screenHas(c, "A x5")
  check("index: saved after the first read", c.files[INDEX] ~= nil)
  local lists = world.lists
  key(c, "backspace")
  recallFirst(c, "")
  screenHas(c, "B x2")
  check("index: not read again", world.lists == lists)
  check("index: keeps stack sizes", c.files[INDEX]:find("\ns %d+ 64\n") ~= nil)
  key(c, "backspace")
  local details = world.details
  a.slots[1].count = 70
  settings(c)
  menuTo(c, "Rebuild item index")
  screenHas(c, "Counted")
  check("index: stack sizes aren't asked for again", world.details == details)
end

-- Storing and recalling keep it up to date, reading only the chests they touched.
do
  local io = chest(27, { { "x:new", 7 } })
  local a, b = chest(27, { { "x:a", 5 } }), chest(27, { { "x:b", 1 } })
  local c, world = ready(io, a, b)
  recallFirst(c, "")
  screenHas(c, "A x5")
  key(c, "backspace")
  screenHas(c, "Store all")
  local lists = world.lists
  key(c, "home") key(c, "enter")
  screenHas(c, "Stored 7 items")
  check("index: store reads the I/O chest and where it put them", world.lists - lists == 2)
  backToMenu(c)
  lists = world.lists
  recallFirst(c, "new")
  check("index: knows what was stored", screenHas(c, "New x7"))
  check("index: without reading", world.lists == lists)
  pick(c)
  screenHas(c, "Recalled 7 New")
  check("index: recall checks the chest that holds it", world.lists - lists == 1)
  typed(c, "new")
  check("index: knows it was taken", screenHas(c, "Nothing matches that"))
end

-- Recalling checks the chests first, so a chest changed by hand can't send the wrong item.
do
  local io = chest(27)
  local a = chest(27, { { "x:a", 10 }, { "x:a", 10 } })
  local c = ready(io, a, chest(27))
  recallFirst(c, "")
  screenHas(c, "A x20")
  key(c, "backspace")
  a.slots[1] = { name = "x:z", count = 3 }
  recallFirst(c, "a")
  screenHas(c, "A x20")
  pick(c)
  check("stale: recalls what's really there", screenHas(c, "Recalled 10 A."))
  check("stale: only that item", total(io, "x:a") == 10 and total(io, "x:z") == 0)
  typed(c, "z")
  check("stale: the index is corrected", screenHas(c, "Z x3"))
end

-- Rebuilding finds what was changed by hand.
do
  local a = chest(27, { { "x:a", 1 } })
  local c, world = ready(chest(27), a, chest(27))
  recallFirst(c, "")
  screenHas(c, "A x1")
  key(c, "backspace")
  a.slots[2] = { name = "x:hand", count = 4 }
  recallFirst(c, "hand")
  check("rebuild: not seen before", screenHas(c, "Nothing matches that"))
  key(c, "backspace") key(c, "backspace") key(c, "backspace") key(c, "backspace") key(c, "backspace")
  settings(c)
  menuTo(c, "Rebuild item index")
  check("rebuild: reports", screenHas(c, "Counted 5 items in 2 chests."))
  key(c, "enter")
  check("rebuild: back to settings", screenHas(c, "Rebuild item index"))
  key(c, "backspace")
  local lists = world.lists
  recallFirst(c, "hand")
  check("rebuild: found", screenHas(c, "Hand x4"))
  check("rebuild: kept", world.lists == lists)
end

do
  local c = start({ net = { io = chest(27), a = chest(27) } })
  screenHas(c, "Storage - Setup")
  check("rebuild: not offered before setup", not c.screenText():find("Rebuild", 1, true))
  check("index: here by default", screenHas(c, "Item index: this computer"))
end

-- A chest that's ticked again is read again, since it may have changed while it wasn't.
do
  local b = chest(27, { { "x:b", 1 } })
  local c = ready(chest(27), chest(27), b)
  recallFirst(c, "")
  screenHas(c, "B x1")
  key(c, "backspace")
  local function toggleB()
    settings(c)
    key(c, "home") key(c, "down") key(c, "enter")
    screenHas(c, "] b")
    menuTo(c, "] b")
    sim.advance(1)
    key(c, "backspace")
    key(c, "home") key(c, "up") key(c, "enter")
    screenHas(c, "Store all")
  end
  toggleB()
  b.slots[1] = { name = "x:changed", count = 2 }
  toggleB()
  check("re-ticked: saved", config(c).allowed.b)
  recallFirst(c, "")
  check("re-ticked: read again", screenHas(c, "Changed x2"))
end

-- A book already in the index as a plain Enchanted Book is named again when its chest is read.
do
  local BOOK = "minecraft:enchanted_book"
  local c, world = ready(chest(27), chest(27, { { BOOK, 1, "s5" } }), chest(27))
  recallFirst(c, "")
  check("old book: plain before", screenHas(c, "Enchanted Book x1"))
  key(c, "backspace")
  world.enchantments = { s5 = { { name = "minecraft:sharpness", level = 5, displayName = "Sharpness V" } } }
  settings(c)
  menuTo(c, "Rebuild item index")
  screenHas(c, "Counted")
  key(c, "enter")
  key(c, "backspace")
  recallFirst(c, "")
  check("old book: named after a rebuild", screenHas(c, "Book: Sharpness V x1"))
end

-- On a network drive -------------------------------------------------------------------------------

local SHARED = "disk/storage/index"

do
  local world = { net = { io = chest(27), a = chest(27, { { "x:a", 3 } }) }, drives = { drive_0 = { mount = "disk", label = "Index" } } }
  local c = start(world)
  c.env.require("util").writeTable("/" .. CONFIG, { io = "io", allowed = { a = true } })
  settings(c)
  check("drive: shown", screenHas(c, "Item index: this computer"))
  menuTo(c, "Item index")
  check("drive: listed", screenHas(c, 'drive_0 "Index"'))
  menuTo(c, "drive_0")
  check("drive: chosen", screenHas(c, "Item index: network drive drive_0"))
  key(c, "home") key(c, "up") key(c, "enter")
  screenHas(c, "Store all")
  check("drive: saved", config(c).index.drive == "drive_0")
  recallFirst(c, "")
  screenHas(c, "A x3")
  check("drive: index on the floppy", c.files[SHARED] ~= nil and c.files[INDEX] == nil)

  -- Another computer with the same chests and drive uses it without reading them.
  local shared = c.files[SHARED]
  local c2 = start(world, { [SHARED] = shared })
  c2.env.require("util").writeTable("/" .. CONFIG, { io = "io", allowed = { a = true }, index = { drive = "drive_0" } })
  world.lists = 0
  recallFirst(c2, "")
  check("drive: shared", screenHas(c2, "A x3"))
  check("drive: nothing read", world.lists == 0)
end

do
  local world = { net = { io = chest(27), a = chest(27) }, drives = { drive_0 = {} } }
  local c = start(world)
  c.env.require("util").writeTable("/" .. CONFIG, { io = "io", allowed = { a = true } })
  settings(c)
  menuTo(c, "Item index")
  menuTo(c, "drive_0")
  check("drive: needs a floppy", screenHas(c, "There's no floppy in drive_0"))
  key(c, "enter")
  key(c, "backspace")
  check("drive: still here", screenHas(c, "Item index: this computer"))
end

do
  local c = start({ net = { io = chest(27), a = chest(27) } })
  c.env.require("util").writeTable("/" .. CONFIG, { io = "io", allowed = { a = true } })
  settings(c)
  menuTo(c, "Item index")
  check("drive: says how when there are none", screenHas(c, "Look for network drives"))
end

-- Without its drive, it still works, and says the index wasn't saved.
do
  local io = chest(27, { { "x:a", 2 } })
  local c = ready(io, chest(27), chest(27))
  c.env.require("util").writeTable("/" .. CONFIG, { io = "io", allowed = { a = true, b = true }, index = { drive = "drive_9" } })
  screenHas(c, "Store all")
  key(c, "home") key(c, "enter")
  check("drive gone: stores", screenHas(c, "Stored 2 items"))
  check("drive gone: says so", screenHas(c, "The item index wasn't saved: The network drive") and screenHas(c, "drive_9 isn't connected"))
end

-- Moving back to this computer throws away its old copy, which missed what happened meanwhile.
do
  local world = { net = { io = chest(27), a = chest(27) }, drives = { drive_0 = { mount = "disk" } } }
  local c = start(world, { [INDEX] = "storage-index 1\ni 1 x:old -\nc a 27 1,1,9\n" })
  c.env.require("util").writeTable("/" .. CONFIG, { io = "io", allowed = { a = true }, index = { drive = "drive_0" } })
  settings(c)
  menuTo(c, "Item index")
  menuTo(c, "This computer")
  key(c, "home") key(c, "up") key(c, "enter")
  screenHas(c, "Store all")
  check("back here: old copy gone", c.files[INDEX] == nil)
end

-- Saving keeps what another computer saved in the meantime, and the format survives a round trip.
do
  local c = start({})
  local result
  sim.call(c, function()
    local index = c.env.require("index")
    local cfg = { io = "io", allowed = {} }
    local mine = index.load(cfg)
    local theirs = index.load(cfg)
    theirs.chests.b = { size = 9, slots = { [2] = { name = "x:b", count = 3 } } }
    index.save(cfg, theirs, { b = true })
    mine.chests.a = { size = 27, slots = { [1] = { name = "x:sword", count = 1, nbt = "abc" }, [5] = { name = "x:a", count = 64 } } }
    mine.names["x:sword#abc"] = "Sharp One"
    index.save(cfg, mine, { a = true })
    result = index.load(cfg)
  end)
  check("merge: keeps theirs", result.chests.b and result.chests.b.slots[2].count == 3)
  check("merge: and mine", result.chests.a and result.chests.a.slots[5].count == 64 and result.chests.a.size == 27)
  check("format: nbt", result.chests.a.slots[1].nbt == "abc" and result.chests.a.slots[1].nbt ~= nil)
  check("format: names", result.names["x:sword#abc"] == "Sharp One")
  check("format: no nbt", result.chests.a.slots[5].nbt == nil)
end

do
  local c = ready(chest(27), chest(27, { { "x:a", 1 } }), chest(27))
  c.files[INDEX] = "not an index"
  recallFirst(c, "")
  check("damaged: read again", screenHas(c, "A x1"))
end

-- Auto chests ---------------------------------------------------------------------------------------

local function autoConfig(c, targets)
  c.env.require("util").writeTable("/" .. CONFIG, {
    io = "io", allowed = { a = true, b = true }, auto = { auto = { targets = targets } },
  })
end

local COAL, TORCH = "x:coal#nil", "x:torch#nil"

-- Balancing: too many goes back, too few comes out, and anything not listed is stored.
do
  local a = chest(27, { { "x:coal", 64 }, { "x:coal", 36 } })
  local b = chest(27)
  local auto = chest(9, { { "x:coal", 10 }, { "x:dirt", 5 }, { "x:torch", 64 }, { "x:torch", 16 } })
  local c = ready(chest(27), a, b, { auto = auto })
  local targets = { { key = COAL, id = "x:coal", name = "Coal", count = 64 }, { key = TORCH, id = "x:torch", name = "Torch", count = 64 } }
  autoConfig(c, targets)
  local array = c.env.require("array")
  local result = sim.call(c, function() return array.balance(array.load(), "auto", targets) end)
  check("balance: tops up", total(auto, "x:coal") == 64)
  check("balance: takes the extra out", total(auto, "x:torch") == 64)
  check("balance: stores what isn't listed", total(auto, "x:dirt") == 0 and total(a, "x:dirt") + total(b, "x:dirt") == 5)
  check("balance: counts", result.stored == 21 and result.recalled == 54)
  check("balance: storage has the rest", total(a, "x:coal") + total(b, "x:coal") == 46)
  check("balance: lets go of the lock", not c.files["etc/storage/lock"])
  local stored = sim.call(c, function() return array.items(array.load()) end)
  local found = {}
  for _, item in ipairs(stored) do found[item.id] = item.count end
  check("balance: the index keeps up", found["x:coal"] == 46 and found["x:torch"] == 16 and found["x:dirt"] == 5)

  local again = sim.call(c, function() return array.balance(array.load(), "auto", targets) end)
  check("balance: nothing to do reads nothing", again.stored == 0 and again.recalled == 0)

  -- Short of something storage doesn't have: it brings what there is.
  local more = { { key = COAL, id = "x:coal", name = "Coal", count = 200 } }
  local partial = sim.call(c, function() return array.balance(array.load(), "auto", more) end)
  check("balance: brings what there is", total(auto, "x:coal") == 110 and partial.recalled == 46)
  check("balance: stores what's no longer listed", total(auto, "x:torch") == 0)
end

-- A lock left behind by a restart doesn't stop anything.
do
  local c = ready(chest(27, { { "x:a", 3 } }), chest(27), chest(27))
  c.env.require("util").writeTable("/etc/storage/lock", { time = 1e9 })
  screenHas(c, "Store all")
  key(c, "enter")
  check("lock: an old one is ignored", screenHas(c, "Stored 3 items"))
  check("lock: let go of afterwards", not c.files["etc/storage/lock"])
end

-- The service keeps it stocked while something takes from it and puts things in.
do
  local a = chest(27, { { "x:coal", 64 }, { "x:coal", 64 }, { "x:torch", 64 } })
  local auto = chest(9)
  local c = ready(chest(27), a, chest(27), { auto = auto })
  autoConfig(c, { { key = COAL, id = "x:coal", name = "Coal", count = 64 }, { key = TORCH, id = "x:torch", name = "Torch", count = 32 } })
  local fn = assert(loadfile("apps/storage/service.lua"))
  setfenv(fn, c.env)
  local service = sim.spawn(c, fn, { id = "storage" })
  sim.advance(1)
  check("service: fills it at the start", total(auto, "x:coal") == 64 and total(auto, "x:torch") == 32)

  -- A turtle takes coal and leaves what it dug.
  auto.slots[1].count = 20
  auto.slots[5] = { name = "x:diamond", count = 3 }
  auto.slots[6] = { name = "x:cobblestone", count = 64 }
  sim.advance(6)
  check("service: tops it up", total(auto, "x:coal") == 64)
  check("service: stores what was left", total(auto, "x:diamond") == 0 and total(auto, "x:cobblestone") == 0)
  check("service: into storage", total(a, "x:diamond") == 3)
  check("service: still running", not service.done)

  -- The app changes the targets: the service looks straight away.
  local cfg = c.env.require("array").load()
  cfg.auto.auto.targets[2].count = 10
  c.env.require("array").save(cfg)
  c.env.os.queueEvent("storage_auto")
  sim.advance(0.5)
  check("service: looks when woken", total(auto, "x:torch") == 10)
end

-- Setting one up from the menu.
do
  local a = chest(27, { { "x:coal", 64 }, { "x:coal", 64 } })
  local auto = chest(9, { { "x:torch", 5 } })
  local c, world = ready(chest(27), a, chest(27), { auto = auto })
  screenHas(c, "Store all")
  key(c, "down") key(c, "down") key(c, "enter")
  screenHas(c, "Add a chest")
  key(c, "enter")
  screenHas(c, "Find it by adding an item")
  check("auto: storage chests aren't offered", not c.screenText():find("\n a +\n")
    and not c.screenText():find("\n io +\n") and c.screenText():find("\n auto +\n"))
  key(c, "down") key(c, "enter")
  screenHas(c, "Add an item")
  check("auto: saved", config(c).auto.auto ~= nil)
  key(c, "enter")
  screenHas(c, "Item:")
  check("auto: offers what's in the chest too", screenHas(c, "Torch x5"))
  typed(c, "coal")
  key(c, "enter")
  screenHas(c, "Amount:")
  typed(c, "1s")
  key(c, "enter")
  screenHas(c, "Coal: 64 (has 0)")
  local targets = config(c).auto.auto.targets
  check("auto: target saved", #targets == 1 and targets[1].key == COAL and targets[1].count == 64)

  -- Change it, then remove the chest.
  key(c, "enter")
  screenHas(c, "Keep 64")
  key(c, "enter")
  screenHas(c, "Amount:")
  typed(c, "10")
  key(c, "enter")
  screenHas(c, "Coal: 10")
  check("auto: changed", config(c).auto.auto.targets[1].count == 10)

  -- Settings can't use it for storage while it's an auto chest, and saving keeps it.
  key(c, "backspace")
  screenHas(c, "Auto chests")
  key(c, "backspace")
  screenHas(c, "Store all")
  key(c, "end") key(c, "up") key(c, "enter")
  screenHas(c, "Storage chests: 2")
  key(c, "down") key(c, "enter")
  screenHas(c, "Done")
  check("auto: not offered for storage", not c.screenText():find("auto", 1, true))
  key(c, "backspace")
  key(c, "end") key(c, "enter")
  screenHas(c, "Store all")
  check("auto: settings keep it", config(c).auto.auto and config(c).auto.auto.targets[1].count == 10)

  key(c, "home") key(c, "down") key(c, "down") key(c, "enter")
  screenHas(c, "Add a chest")
  key(c, "enter")
  screenHas(c, "Stop managing this chest")
  key(c, "end") key(c, "up") key(c, "enter")
  screenHas(c, "Add a chest")
  check("auto: removed", next(config(c).auto) == nil)
  check("auto: the items stay", total(auto, "x:torch") == 5)
end

if failed > 0 then
  print(("%d passed, %d FAILED"):format(passed, failed))
  os.exit(1)
end
print(("storage: all %d passed"):format(passed))
