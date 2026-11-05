-- Tests Strip Mine's plan and miner against a simulated world, including turtles that lose power at
-- random moments and pick up where they left off.
-- Run from the repository root: luajit tests/test_strip_mine.lua

local DIR = "apps/strip-mine/"
local pack = table.pack or function(...) return { n = select("#", ...), ... } end
local unpack = table.unpack or unpack

local failed, passed = 0, 0
local function check(name, ok)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name)
  end
end

local function readHost(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  return data
end

-- Loads an app module the way require does on the turtle, with `turtle` and friends from `env`.
local loaded = {}
local function module(name, env)
  env = env or {}
  setmetatable(env, { __index = _G })
  env.require = function(n)
    if not loaded[n] then loaded[n] = module(n, env) end
    return loaded[n]
  end
  local fn = assert(load(readHost(DIR .. name .. ".lua"), "@" .. name, "t", env))
  return fn(name)
end

local plan = module("plan")
loaded.plan = plan
local miner = module("miner")

local function key(x, y, z) return x .. "," .. y .. "," .. z end

-- A plain serializer, so a saved job is copied the way a file would copy it.
local function serialize(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  local out = {}
  for k, x in pairs(v) do out[#out + 1] = "[" .. serialize(k) .. "]=" .. serialize(x) end
  return "{" .. table.concat(out, ",") .. "}"
end
local function unserialize(s) return assert(load("return " .. s:gsub("%[inf%]", "[math.huge]"):gsub("=inf", "=math.huge")))() end

-- The plan -------------------------------------------------------------------------------------------

-- Settings for a job, as plan.assign makes them, carrying on from `record` if there is one.
local function config(changes, record)
  local c = plan.defaults()
  for k, v in pairs(changes or {}) do c[k] = v end
  return plan.assign(assert(plan.check(c)), record)
end

local function adjacentAll(steps)
  for i = 2, #steps do
    local a, b = steps[i - 1], steps[i]
    if math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z) ~= 1 then return false, i end
  end
  return true
end

-- Every cell the cross-sections of a plan's sliced steps cover.
local function dugCells(c, steps)
  local shape, cells = plan.shape(c), {}
  for _, s in ipairs(steps or plan.steps(c)) do
    if s.slice then
      for _, cell in ipairs(plan.section(shape, s)) do cells[key(cell[1], cell[2], cell[3])] = true end
    end
  end
  return cells
end

local SIZES = { "1x2", "1x3", "3x3" }
for _, corridor in ipairs(SIZES) do
  for _, branch in ipairs(SIZES) do
    for _, side in ipairs({ "right", "left", "both" }) do
      for _, count in ipairs({ 1, 2, 3 }) do
        local name = ("plan %s/%s %s %d: "):format(corridor, branch, side, count)
        local c = config({ corridor = corridor, branch = branch, side = side, count = count, length = 5, spacing = 2 })
        local shape = plan.shape(c)
        local C, B = shape.corridor, shape.branch
        local steps = plan.steps(c)
        check(name .. "every step is next to the last", adjacentAll(steps))
        check(name .. "starts at the corridor's first cell", steps[1].x == 0 and steps[1].y == C.travel and steps[1].z == 0)
        check(name .. "ends back there", steps[#steps].x == 0 and steps[#steps].y == C.travel and steps[#steps].z == 0)
        check(name .. "has the work", #c.work == count and c.newBranches == count)
        local sliced = {}
        for _, s in ipairs(steps) do
          if s.slice then
            check(name .. "slices a cell once", not sliced[key(s.x, s.y, s.z)])
            sliced[key(s.x, s.y, s.z)] = true
          end
          if s.kind == "branch" then
            check(name .. "branch lanes are at the branch's height", s.y == B.travel)
            check(name .. "branches are outside the corridor", math.abs(s.x) > C.half)
          else
            check(name .. "the corridor's lane is in it", math.abs(s.x) <= C.half and s.y < C.height)
          end
        end
        local sides = {}
        for k, w in ipairs(c.work) do
          local z = plan.slotZ(shape, w.slot)
          sides[w.side] = true
          check(name .. "branches go in slots in order", k == 1 or w.slot >= c.work[k - 1].slot)
          for along = 1, 5 do
            check(name .. "digs branch " .. k .. " at " .. along,
              sliced[key(plan.SIGN[w.side] * (C.half + along), B.travel, z)])
          end
          check(name .. "doesn't dig past the end", not sliced[key(plan.SIGN[w.side] * (C.half + 6), B.travel, z)])
        end
        if side == "both" then
          check(name .. "branches go both ways", sides.l and (count == 1 or sides.r))
          check(name .. "fills both sides of a slot first", c.work[1].slot == 1 and (count == 1 or c.work[2].slot == 1))
        else
          check(name .. "branches go one way", not sides[side == "right" and "l" or "r"])
        end
        for z = 0, plan.slotZ(shape, c.work[#c.work].slot) do
          check(name .. "digs the corridor at " .. z, sliced[key(0, C.travel, z)])
        end
        check(name .. "doesn't dig the corridor past the last branch",
          not sliced[key(0, C.travel, plan.slotZ(shape, c.work[#c.work].slot) + 1)])
        for k, cell in pairs(dugCells(c, steps)) do
          local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
          check(name .. "inside knows every dug cell", plan.inside(shape, tonumber(x), tonumber(y), tonumber(z)))
        end
        check(name .. "the chest isn't dug", not dugCells(c, steps)[key(0, 0, -1)])
      end
    end
  end
end

-- Carrying on a mine: the next job skips what's dug, and finishes what was left short.
do
  local c = config({ count = 3, length = 6, side = "both" })
  local record = plan.newRecord(c)
  local steps = plan.steps(c)
  plan.record(record, c, steps, #steps + 1)
  check("record: the corridor", record.corridor == plan.slotZ(plan.shape(c), 2))
  check("record: slot 1 both sides", record.branches[1].l.dug == 6 and record.branches[1].r.dug == 6)
  check("record: slot 2 left", record.branches[2].l.dug == 6 and not record.branches[2].r)

  local c2 = config({ count = 2, length = 6 }, record)
  check("carry on: starts with the free side of slot 2", c2.work[1].slot == 2 and c2.work[1].side == "r"
    and c2.work[2].slot == 3 and c2.work[2].side == "l" and #c2.work == 2)
  local steps2 = plan.steps(c2)
  check("carry on: every step is next to the last", adjacentAll(steps2))
  local again = dugCells(c2, steps2)
  local before = dugCells(c, steps)
  local overlap = 0
  for k in pairs(again) do if before[k] then overlap = overlap + 1 end end
  check("carry on: digs nothing twice", overlap == 0)
  check("carry on: keeps the layout", (function()
    local c3 = config({ count = 1, spacing = 5, corridor = "1x2" }, record)
    return c3.spacing == c.spacing and c3.corridor == c.corridor
  end)())

  -- Stopped halfway along the second branch.
  local partial = plan.newRecord(c)
  local half
  for i, s in ipairs(steps) do
    if s.slice and s.kind == "branch" and s.tunnel == 2 and s.along == 3 then half = i + 1 end
  end
  plan.record(partial, c, steps, half)
  check("partial: records how far it got", partial.branches[1].r.dug == 3 and partial.branches[1].r.want == 6)
  check("partial: leaves out branches it never reached", not partial.branches[2])
  local c4 = config({ count = 1, length = 10 }, partial)
  check("partial: finishes it first", c4.work[1].slot == 1 and c4.work[1].side == "r" and c4.work[1].from == 3
    and c4.work[1].to == 6)
  check("partial: then a new one", c4.work[2].slot == 2 and c4.work[2].from == 0 and c4.work[2].to == 10 and #c4.work == 2)
  local first
  for _, s in ipairs(plan.steps(c4)) do
    if s.slice and s.kind == "branch" then first = first or s end
  end
  check("partial: starts digging where it stopped", first.along == 4)

  local c5 = config({ count = 0, length = 9, extend = true }, record)
  check("lengthen: makes every branch longer", #c5.work == 3 and c5.work[1].from == 6 and c5.work[1].to == 9)
  check("lengthen: nothing without it", #config({ count = 0, length = 9 }, record).work == 0)
end

do
  local c = config({ count = 4, length = 10, spacing = 2, torches = 4, corridor = "3x3", branch = "1x2" })
  local shape = plan.shape(c)
  local torches = {}
  for _, s in ipairs(plan.steps(c)) do
    if s.torch then torches[#torches + 1] = s end
  end
  check("torches go along the branches and corridor", #torches == 4 * 2 + 1)
  for _, s in ipairs(torches) do
    if s.kind == "branch" then
      check("torch in a branch is in a niche", s.torch == 2 and s.along % 4 == 0)
    else
      check("torch in the corridor is on the floor", s.torch == true)
      check("torch in the corridor stays out of a branch's row", s.z % shape.pitch ~= 0)
    end
  end
  check("torches off places none", (function()
    for _, s in ipairs(plan.steps(config({ torches = 0 }))) do if s.torch then return false end end
    return true
  end)())
end

check("settings: rejects a length of 0", not plan.check({ length = 0 }))
check("settings: rejects a fraction", not plan.check({ spacing = 1.5 }))
check("settings: rejects an unknown size", not plan.check({ branch = "5x5" }))
check("settings: rejects an unknown corridor", not plan.check({ corridor = "5x5" }))
check("settings: fills in defaults", plan.check({}).length == 32)
check("settings: takes an old tunnel size as the branch size", plan.check({ size = "1x3" }).branch == "1x3")

do
  local c = config({ count = 2, length = 8, side = "right", corridor = "1x2", branch = "1x2" })
  local steps = plan.steps(c)
  local walk = plan.walkable(c, steps)
  local z = plan.slotZ(plan.shape(c), 1)
  local route = plan.route(walk, { 8, 0, z }, { 0, 0, 0 })
  check("route finds the way home", route and #route == 8 + z + 1)
  check("route refuses cells outside the mine", plan.route(walk, { 1, 0, 1 }, { 0, 0, 0 }) == nil)
  local est = plan.estimate(c, steps)
  check("estimate counts the blocks", est.blocks == (8 * 2 + plan.slotZ(plan.shape(c), 2) + 1) * 2)
  check("estimate needs more fuel than steps", est.fuel > #steps)
end

-- A world and a turtle -----------------------------------------------------------------------------

local DROPS = {
  ["minecraft:stone"] = "minecraft:cobblestone", ["minecraft:iron_ore"] = "minecraft:raw_iron",
  ["minecraft:coal_ore"] = "minecraft:coal", ["minecraft:diamond_ore"] = "minecraft:diamond",
}
local FALLS = { ["minecraft:gravel"] = true, ["minecraft:sand"] = true }

local Power = {} -- yielded when the turtle loses power

-- opts: blocks (key -> name, over a default of stone), fuel, items (slot -> { name, count }), chest
-- (list of { name, count }), cut (actions until each power cut, a function), noPeripheral
local function newWorld(opts)
  local w = { blocks = {}, chest = {}, dropped = 0, lost = 0, actions = 0 }
  for k, v in pairs(opts.blocks or {}) do w.blocks[k] = v end
  w.blocks[key(0, 0, -1)] = "minecraft:chest"
  w.blocks[key(0, 0, 0)] = "air" -- where the turtle is
  for i, item in ipairs(opts.chest or {}) do w.chest[i] = { name = item[1], count = item[2] } end
  w.chestSize = 27

  function w.get(x, y, z)
    local b = w.blocks[key(x, y, z)]
    if b == "air" then return nil end
    if b then return b end
    if y < -6 then return "minecraft:bedrock" end
    return "minecraft:stone"
  end
  function w.set(x, y, z, name) w.blocks[key(x, y, z)] = name or "air" end

  local T = { x = 0, y = 0, z = 0, f = 0, fuel = opts.fuel or 0, limit = 20000, slot = 1, inv = {} }
  w.turtle = T
  for slot, item in pairs(opts.items or {}) do T.inv[slot] = { name = item[1], count = item[2] } end

  local cut = opts.cut
  local untilCut = cut and cut() or math.huge
  -- Each action may lose power before or after it happens, as an unloaded chunk would.
  local function act(fn)
    if w.tick then w.tick() end
    w.actions = w.actions + 1
    untilCut = untilCut - 1
    if untilCut <= 0 then
      untilCut = cut()
      if math.random() < 0.5 then coroutine.yield(Power) end
      local results = pack(fn())
      coroutine.yield(Power)
      return unpack(results, 1, results.n)
    end
    return fn()
  end

  local function ahead(d)
    if d == "up" then return T.x, T.y + 1, T.z end
    if d == "down" then return T.x, T.y - 1, T.z end
    local dir = plan.DIRS[T.f]
    return T.x + dir[1], T.y, T.z + dir[2]
  end

  local function isLiquid(name) return name == "minecraft:lava" or name == "minecraft:water" end

  local function settle(x, y, z)
    -- Anything that falls drops into the cell below it, all the way down a column.
    local above = w.get(x, y + 1, z)
    if above and FALLS[above] and not w.get(x, y, z) then
      w.set(x, y, z, above)
      w.set(x, y + 1, z, nil)
      settle(x, y + 1, z)
    end
  end

  local function add(name, count)
    for slot = 1, 16 do
      local item = T.inv[slot]
      if item and item.name == name and item.count < 64 then
        local n = math.min(count, 64 - item.count)
        item.count, count = item.count + n, count - n
      end
      if count == 0 then return end
    end
    for slot = 1, 16 do
      if not T.inv[slot] then
        T.inv[slot] = { name = name, count = math.min(64, count) }
        count = count - math.min(64, count)
      end
      if count == 0 then return end
    end
    w.lost = w.lost + count
  end

  local function moveFn(d)
    return function()
      return act(function()
        local x, y, z = ahead(d)
        local b = w.get(x, y, z)
        local unlimited = T.fuel == "unlimited"
        if not unlimited and T.fuel < 1 then return false, "Out of fuel" end
        if b and not isLiquid(b) then return false, "Movement obstructed" end
        if x == 0 and y == 0 and z == -1 then return false, "Movement obstructed" end
        T.x, T.y, T.z = x, y, z
        if not unlimited then T.fuel = T.fuel - 1 end
        return true
      end)
    end
  end

  local function digFn(d)
    return function()
      return act(function()
        local x, y, z = ahead(d)
        local b = w.get(x, y, z)
        if not b or isLiquid(b) then return false, "Nothing to dig here" end
        if b == "minecraft:bedrock" then return false, "Unbreakable block detected" end
        if b == "minecraft:chest" then return false, "Cannot break protected block" end
        w.set(x, y, z, nil)
        add(DROPS[b] or b, 1)
        settle(x, y, z)
        return true
      end)
    end
  end

  local function inspectFn(d)
    return function()
      local x, y, z = ahead(d)
      local b = w.get(x, y, z)
      if not b then return false, "No block to inspect" end
      local tags = {}
      if b:find("_ore$") then tags["c:ores"] = true end
      return true, { name = b, tags = tags, state = {} }
    end
  end

  local function detectFn(d)
    return function()
      local b = w.get(ahead(d))
      return b ~= nil and not isLiquid(b)
    end
  end

  local function placeFn(d)
    return function()
      return act(function()
        local item = T.inv[T.slot]
        if not item then return false, "No items to place" end
        local x, y, z = ahead(d)
        local b = w.get(x, y, z)
        if b and not isLiquid(b) then return false, "Cannot place block here" end
        if item.name == "minecraft:coal" or item.name == "minecraft:raw_iron" or item.name == "minecraft:diamond" then
          return false, "Cannot place item here"
        end
        w.set(x, y, z, item.name)
        item.count = item.count - 1
        if item.count == 0 then T.inv[T.slot] = nil end
        return true
      end)
    end
  end

  local function facingChest(d)
    if d ~= "fwd" then return false end
    local x, y, z = ahead(d)
    return x == 0 and y == 0 and z == -1
  end

  local function dropFn(d)
    return function(n)
      return act(function()
        local item = T.inv[T.slot]
        if not item then return false, "No items to drop" end
        n = math.min(n or item.count, item.count)
        if facingChest(d) then
          local left = n
          for i = 1, w.chestSize do
            local c = w.chest[i]
            if c and c.name == item.name and c.count < 64 then
              local m = math.min(left, 64 - c.count)
              c.count, left = c.count + m, left - m
            end
          end
          for i = 1, w.chestSize do
            if left == 0 then break end
            if not w.chest[i] then
              w.chest[i] = { name = item.name, count = left }
              left = 0
            end
          end
          if left == n then return false, "No space for items" end
          n = n - left
        else
          w.dropped = w.dropped + n
        end
        item.count = item.count - n
        if item.count == 0 then T.inv[T.slot] = nil end
        return true
      end)
    end
  end

  local function suckFn(d)
    return function(n)
      return act(function()
        if not facingChest(d) then return false, "No items to take" end
        for i = 1, w.chestSize do
          local c = w.chest[i]
          if c then
            local item = T.inv[T.slot]
            if item and item.name ~= c.name then return false, "No space for items" end
            local m = math.min(n or 64, c.count, 64 - (item and item.count or 0))
            if m == 0 then return false, "No space for items" end
            if item then item.count = item.count + m else T.inv[T.slot] = { name = c.name, count = m } end
            c.count = c.count - m
            if c.count == 0 then w.chest[i] = nil end
            return true
          end
        end
        return false, "No items to take"
      end)
    end
  end

  local t = {
    forward = moveFn("fwd"), up = moveFn("up"), down = moveFn("down"),
    dig = digFn("fwd"), digUp = digFn("up"), digDown = digFn("down"),
    inspect = inspectFn("fwd"), inspectUp = inspectFn("up"), inspectDown = inspectFn("down"),
    detect = detectFn("fwd"), detectUp = detectFn("up"), detectDown = detectFn("down"),
    place = placeFn("fwd"), placeUp = placeFn("up"), placeDown = placeFn("down"),
    drop = dropFn("fwd"), dropUp = dropFn("up"), dropDown = dropFn("down"),
    suck = suckFn("fwd"), suckUp = suckFn("up"), suckDown = suckFn("down"),
    attack = function() return false end, attackUp = function() return false end,
    attackDown = function() return false end,
  }
  function t.turnLeft() return act(function() T.f = (T.f + 3) % 4 return true end) end
  function t.turnRight() return act(function() T.f = (T.f + 1) % 4 return true end) end
  function t.select(slot) T.slot = slot return true end
  function t.getSelectedSlot() return T.slot end
  function t.getItemCount(slot) return T.inv[slot or T.slot] and T.inv[slot or T.slot].count or 0 end
  function t.getItemDetail(slot)
    local item = T.inv[slot or T.slot]
    return item and { name = item.name, count = item.count } or nil
  end
  function t.getFuelLevel() return T.fuel end
  function t.getFuelLimit() return T.fuel == "unlimited" and "unlimited" or T.limit end
  function t.refuel(n)
    return act(function()
      local item = T.inv[T.slot]
      if not item or not plan.FUEL[item.name] then return false, "Items not combustible" end
      if T.fuel == "unlimited" then return true end
      n = math.min(n or item.count, item.count)
      T.fuel = math.min(T.limit, T.fuel + n * plan.FUEL[item.name])
      item.count = item.count - n
      if item.count == 0 then T.inv[T.slot] = nil end
      return true
    end)
  end
  w.api = t

  -- The chest as an inventory peripheral.
  w.peripheral = {
    size = function() return w.chestSize end,
    list = function()
      local out = {}
      for i = 1, w.chestSize do
        if w.chest[i] then out[i] = { name = w.chest[i].name, count = w.chest[i].count } end
      end
      return out
    end,
    pushItems = function(to, from, limit, slot)
      assert(to == "front")
      local c = w.chest[from]
      if not c then return 0 end
      if w.chest[slot] then error("slot taken") end
      w.chest[slot], w.chest[from] = c, nil
      return c.count
    end,
  }
  if opts.noPeripheral then w.peripheral = nil end
  return w
end

local wrong -- times the saved job didn't match the turtle

-- Runs a job to the end, restarting from the saved job whenever the power goes. Returns the final
-- job and how many times it restarted.
local function runJob(w, job, opts)
  opts = opts or {}
  local saved = serialize(job)
  local restarts = 0
  local commands = opts.commands or {}
  local tick = 0
  local io = {
    turtle = w.api,
    chest = function() return w.peripheral end,
    save = function(j)
      saved = serialize(j)
      if opts.cancelWhen and not opts.cancelled and opts.cancelWhen(j) then opts.cancelled = true end
    end,
    poll = function()
      tick = tick + 1
      if opts.cancelled == true then
        opts.cancelled = "sent"
        return "cancel"
      end
      local c = commands[tick]
      return c
    end,
    wait = function() end,
    now = function() return 0 end,
  }
  for _ = 1, 10000 do
    local current = unserialize(saved)
    local m = miner.new(current, io)
    local co = coroutine.create(m.run)
    local ok, result = coroutine.resume(co)
    if not ok then error(debug.traceback(co, result), 0) end
    if result == Power then
      restarts = restarts + 1
      -- What's saved has to allow for where the turtle really is.
      local j, T = unserialize(saved), w.turtle
      local function is(o) return o.x == T.x and o.y == T.y and o.z == T.z and o.f == T.f end
      local p, ok2 = j.pending, false
      if j.unsure then
        local dy = j.unsure.moving and j.unsure.moving.dy or 0
        for _, o in ipairs(j.unsure.options) do
          if is(o) or (j.unsure.turning and is({ x = o.x, y = o.y, z = o.z, f = (o.f + 1) % 4 }))
            or is({ x = o.x, y = o.y + dy, z = o.z, f = o.f }) then
            ok2 = true
          end
        end
      elseif p and p.kind == "move" then
        ok2 = is(j.pos) or is({ x = p.to.x, y = p.to.y, z = p.to.z, f = j.pos.f })
      elseif p and p.kind == "turn" then
        ok2 = is(j.pos) or is({ x = j.pos.x, y = j.pos.y, z = j.pos.z, f = p.f })
      else
        ok2 = is(j.pos)
      end
      if not ok2 then
        wrong = (wrong or 0) + 1
        print(("saved %s pending %s, but the turtle is at %d,%d,%d f%d"):format(serialize(j.pos), serialize(p), T.x, T.y, T.z, T.f))
      end
    else
      current = unserialize(saved)
      if current.status == "stuck" and current.lost and opts.putBack then
        -- What a player does: carry it back to the start and choose Put back at start.
        restarts, opts.lost = restarts + 1, (opts.lost or 0) + 1
        local T = w.turtle
        T.x, T.y, T.z, T.f = 0, 0, 0, 0
        local again = miner.new(current, io)
        again.putBack()
        current.status = "running"
        saved = serialize(current)
      elseif current.status ~= "running" then
        return current, restarts, opts.lost or 0
      end
    end
  end
  error("the job never finished")
end

-- Where the things to find are, around the first branch the job digs.
local function spots(c)
  local shape = plan.shape(c)
  local C, B = shape.corridor, shape.branch
  local w = c.work[1]
  local z = plan.slotZ(shape, w.slot)
  local function X(along) return plan.SIGN[w.side] * (C.half + along) end
  local wall = z + B.half + 1
  return {
    iron = { { X(3), 0, wall }, { X(3), 0, wall + 1 }, { X(3), 0, wall + 2 }, { X(3), 1, wall + 1 } },
    diamonds = { { X(5), -1, z }, { X(5), -2, z } },
    lava = { X(2), 0, z - B.half - 1 },
    hole = { { X(4), -1, z }, { X(4), -2, z } },
    gravel = { X(6), B.height, z },
    coal = { X(1), B.height, z },
  }
end

-- A world with things to find: veins in the walls, a lava pool, a hole in the floor and gravel.
local function features(c)
  local at, b = spots(c), {}
  local function put(cell, name) b[key(cell[1], cell[2], cell[3])] = name end
  for _, cell in ipairs(at.iron) do put(cell, "minecraft:iron_ore") end
  for _, cell in ipairs(at.diamonds) do put(cell, "minecraft:diamond_ore") end
  put(at.lava, "minecraft:lava")
  for _, cell in ipairs(at.hole) do put(cell, "air") end
  for dy = 0, 2 do put({ at.gravel[1], at.gravel[2] + dy, at.gravel[3] }, "minecraft:gravel") end
  put(at.coal, "minecraft:coal_ore")
  return b
end

local function expectations(name, c, w, job, opts)
  opts = opts or {}
  local shape = plan.shape(c)
  local T = w.turtle
  local function get(cell) return w.get(cell[1], cell[2], cell[3]) end
  check(name .. "finishes: " .. tostring(job.message), job.status == "finished")
  check(name .. "ends at the start", T.x == 0 and T.y == 0 and T.z == 0)
  check(name .. "faces forward at the end", T.f == 0)
  local open = true
  for _, s in ipairs(plan.steps(c)) do
    if s.slice then
      for _, cell in ipairs(plan.section(shape, s)) do
        local b = get(cell)
        if b and b ~= "minecraft:torch" then
          open = false
          if opts.verbose then print(name .. "left " .. b .. " at " .. key(cell[1], cell[2], cell[3])) end
        end
      end
    end
  end
  check(name .. "clears every cross-section", open)
  check(name .. "leaves the chest", w.get(0, 0, -1) == "minecraft:chest")
  local at = spots(c)
  if c.vein and (opts.lost or 0) == 0 then
    local veinGone = true
    for _, cell in ipairs(at.iron) do if get(cell) == "minecraft:iron_ore" then veinGone = false end end
    check(name .. "follows the iron vein", veinGone)
    check(name .. "digs diamonds out of the floor", get(at.diamonds[1]) ~= "minecraft:diamond_ore"
      and get(at.diamonds[2]) ~= "minecraft:diamond_ore")
    if not opts.restarted then
      check(name .. "mines the coal in the ceiling", not get(at.coal))
    end
  end
  if c.seal then
    check(name .. "seals the lava", get(at.lava) ~= "minecraft:lava")
    check(name .. "fills the hole in the floor", plan.FILLER[get(at.hole[1]) or "air"])
  end
  local chest = {}
  for _, item in pairs(w.chest) do chest[item.name] = (chest[item.name] or 0) + item.count end
  if c.vein and (opts.lost or 0) == 0 then
    check(name .. "puts the iron in the chest", (chest["minecraft:raw_iron"] or 0) >= 4)
    check(name .. "puts the diamonds in the chest", (chest["minecraft:diamond"] or 0) >= 2)
    if not opts.restarted then
      -- A power cut just after unloading can lose the count of one stack.
      check(name .. "counts what it collected", (job.stats.items["minecraft:raw_iron"] or 0) >= 4)
    end
  end
  if c.junk then
    check(name .. "keeps junk out of the chest", (chest["minecraft:cobblestone"] or 0) == 0)
  end
  check(name .. "loses nothing for lack of space", w.lost == 0)
  return chest
end

-- One run of each pair of sizes, without power cuts.
for _, corridor in ipairs(SIZES) do
  for _, branch in ipairs(SIZES) do
    local c = config({ corridor = corridor, branch = branch, count = 3, length = 8, spacing = 2, torches = 4 })
    local w = newWorld({ blocks = features(c), chest = { { "minecraft:coal", 64 }, { "minecraft:torch", 32 } } })
    local job = runJob(w, miner.newJob(c))
    local name = ("mine %s/%s: "):format(corridor, branch)
    expectations(name, c, w, job, { verbose = true })
    local torches = 0
    for _, b in pairs(w.blocks) do if b == "minecraft:torch" then torches = torches + 1 end end
    check(name .. "places torches", torches == job.stats.torches and torches >= 6)
    check(name .. "refuels from the chest", job.stats.trips >= 0 and w.turtle.fuel > 0)
  end
end

-- Power cuts, again and again.
local totalRestarts, totalLost = 0, 0
for ci, corridor in ipairs(SIZES) do
  for bi, branch in ipairs(SIZES) do
    for seed = 1, 3 do
      math.randomseed(seed * 7 + ci * 3 + bi)
      local c = config({ corridor = corridor, branch = branch, count = 3, length = 7, spacing = 1, torches = 3,
        side = ({ "right", "left", "both" })[(seed + ci + bi) % 3 + 1] })
      local w = newWorld({
        blocks = features(c), chest = { { "minecraft:coal", 64 }, { "minecraft:torch", 64 } },
        cut = function() return math.random(1, 60) end,
      })
      local job, restarts, lost = runJob(w, miner.newJob(c), { putBack = true })
      local name = ("power cuts %s/%s %s seed %d: "):format(corridor, branch, c.side, seed)
      check(name .. "restarted many times", restarts > 5)
      totalRestarts, totalLost = totalRestarts + restarts, totalLost + lost
      expectations(name, c, w, job, { restarted = true, verbose = true, lost = lost })
    end
  end
end

-- With unlimited fuel, moves can't be told from the fuel level, so it looks around instead.
for seed = 1, 4 do
  math.randomseed(seed * 13)
  local c = config({ branch = ({ "1x2", "1x3", "3x3", "1x2" })[seed], corridor = ({ "3x3", "1x2", "1x3", "1x3" })[seed],
    count = 2, length = 6, torches = 3 })
  local w = newWorld({ blocks = features(c), fuel = "unlimited", chest = { { "minecraft:torch", 64 } },
    cut = function() return math.random(1, 60) end })
  local job, restarts, lost = runJob(w, miner.newJob(c), { putBack = true })
  local name = ("unlimited fuel seed %d: "):format(seed)
  check(name .. "restarted", restarts > 5)
  expectations(name, c, w, job, { restarted = true, lost = lost })
  totalRestarts, totalLost = totalRestarts + restarts, totalLost + lost
end

print(("power cuts: %d restarts, lost %d times"):format(totalRestarts, totalLost))
check("power cuts: always knows where it might be", not wrong)
check("power cuts: hardly ever lost", totalLost * 50 < totalRestarts)

-- One job after another in the same mine: each digs only what's new, and a cancelled branch is
-- finished by the next job.
for _, cut in ipairs({ false, true }) do
  math.randomseed(cut and 99 or 1)
  local name = "carry on" .. (cut and " with power cuts: " or ": ")
  local first = config({ count = 3, length = 6, torches = 0, vein = false })
  local w = newWorld({ chest = { { "minecraft:coal", 64 } }, cut = cut and function() return math.random(1, 60) end or nil })
  local firstSteps = plan.steps(first)
  -- Partway along the second branch.
  local job = runJob(w, miner.newJob(first), { putBack = true, cancelWhen = function(j)
    local s = firstSteps[j.step]
    return s and s.tunnel == 2 and s.along == 4 and j.stage == "enter"
  end })
  check(name .. "the first job was cancelled", job.status == "cancelled")
  local record = plan.newRecord(first)
  plan.record(record, first, plan.steps(first), job.step)
  local shortest
  for _, slot in pairs(record.branches) do
    for _, b in pairs(slot) do if b.dug < b.want then shortest = b end end
  end
  check(name .. "left a branch short", shortest ~= nil)
  local second = config({ count = 2, length = 6, torches = 0, vein = false }, record)
  check(name .. "the next job finishes it", second.work[1].from > 0 and second.work[1].to == 6)
  local dugBefore = w.actions
  job = runJob(w, miner.newJob(second), { putBack = true })
  check(name .. "the second job finishes", job.status == "finished")
  plan.record(record, second, plan.steps(second), math.huge)
  local all = 0
  for _, slot in pairs(record.branches) do
    for _, b in pairs(slot) do
      all = all + 1
      check(name .. "every branch is dug in full", b.dug == 6)
    end
  end
  local C = plan.shape(second).corridor
  check(name .. "every branch is open", (function()
    for k, slot in pairs(record.branches) do
      for side in pairs(slot) do
        for along = 1, 6 do
          if w.get(plan.SIGN[side] * (C.half + along), 0, plan.slotZ(plan.shape(second), k)) then return false end
        end
      end
    end
    return true
  end)())
  check(name .. "and none past them", w.get(0, C.travel, record.corridor + 1) ~= nil)
  check(name .. "the record adds up", all >= 2 + #second.work - 1 and dugBefore < w.actions)
end

-- A full inventory: it goes back to unload, and the junk filter keeps cobblestone out of the chest.
for _, junk in ipairs({ true, false }) do
  local c = config({ branch = "3x3", count = 3, length = 40, junk = junk, vein = false, seal = false, torches = 0 })
  local w = newWorld({ chest = { { "minecraft:coal", 64 } } })
  local job = runJob(w, miner.newJob(c))
  local name = "inventory, junk filter " .. (junk and "on" or "off") .. ": "
  check(name .. "finishes", job.status == "finished")
  if junk then
    check(name .. "never needs a trip", job.stats.trips == 1)
    check(name .. "throws junk away", w.dropped > 0)
  else
    check(name .. "goes back to unload", job.stats.trips > 1)
    local cobble = 0
    for _, item in pairs(w.chest) do if item.name == "minecraft:cobblestone" then cobble = cobble + item.count end end
    check(name .. "unloads everything", cobble > 64 and w.lost == 0)
  end
end

-- Keeping some junk: it seals with it and brings the rest to the chest, up to the amount each trip.
do
  local c = config({ count = 2, length = 20, vein = false, torches = 0, keep = { ["minecraft:cobblestone"] = 100 } })
  local w = newWorld({ blocks = features(c), chest = { { "minecraft:coal", 64 } } })
  local job = runJob(w, miner.newJob(c))
  local cobble = 0
  for _, item in pairs(w.chest) do if item.name == "minecraft:cobblestone" then cobble = cobble + item.count end end
  check("keep: finishes", job.status == "finished")
  check("keep: brings some to the chest", cobble > 0 and cobble <= 100 * job.stats.trips)
  check("keep: still throws the rest away", w.dropped > 0)
  check("keep: still seals the lava", (function() local l = spots(c).lava return w.get(l[1], l[2], l[3]) ~= "minecraft:lava" end)())
  check("keep: counts it", job.stats.items["minecraft:cobblestone"] == cobble)
end
check("settings: rejects a bad amount to keep", not plan.check({ keep = { ["minecraft:dirt"] = -1 } }))
check("settings: an amount to keep", plan.check({ keep = { ["minecraft:dirt"] = 64 } }).keep["minecraft:dirt"] == 64)

-- Running out of fuel: it comes back for more, and stops if there's none.
do
  local c = config({ count = 1, length = 40, vein = false, seal = false, torches = 0, junk = true })
  local w = newWorld({ chest = { { "minecraft:charcoal", 1 } } })
  local job = runJob(w, miner.newJob(c))
  check("fuel: stops when the chest has too little", job.status == "stuck" and job.message:find("fuel", 1, true))
  w.chest[1] = { name = "minecraft:coal", count = 10 }
  job.status = "running"
  job = runJob(w, job)
  check("fuel: carries on after more is added", job.status == "finished")
  w.turtle.fuel = 0
end

do
  -- Without a chest to sort, it still finds coal behind other things.
  local c = config({ count = 1, length = 4, vein = false, seal = false, torches = 0 })
  local w = newWorld({ noPeripheral = true, chest = { { "minecraft:dirt", 5 }, { "minecraft:coal", 4 } } })
  local job = runJob(w, miner.newJob(c))
  check("unsorted chest: finds the coal", job.status == "finished")
  check("unsorted chest: puts the dirt back", w.chest[1] and w.chest[1].name == "minecraft:dirt" or
    (function() for _, i in pairs(w.chest) do if i.name == "minecraft:dirt" then return true end end end)())
end

do
  local c = config({ count = 1, length = 4 })
  local w = newWorld({})
  w.blocks[key(0, 0, -1)] = "air"
  local job = runJob(w, miner.newJob(c))
  check("no chest: says so", job.status == "stuck" and job.message:find("no chest", 1, true))
end

do
  -- Bedrock in the way.
  local c = config({ count = 1, length = 6, vein = false, seal = false, torches = 0 })
  local w = newWorld({ blocks = { [key(0, 0, 3)] = "minecraft:bedrock" }, chest = { { "minecraft:coal", 8 } } })
  local job = runJob(w, miner.newJob(c))
  check("bedrock: stops and says where", job.status == "stuck" and job.message:find("0, 0, 3", 1, true))
end

-- Commands -------------------------------------------------------------------------------------------

do
  local c = config({ count = 2, length = 10, torches = 0 })
  local w = newWorld({ chest = { { "minecraft:coal", 64 } } })
  local job = runJob(w, miner.newJob(c), { commands = { [30] = "pause" } })
  check("pause: stops where it is", job.status == "paused" and (w.turtle.x ~= 0 or w.turtle.z ~= 0))
  local step = job.step
  job.status = "running"
  job = runJob(w, job, { commands = { [5] = "home" } })
  check("home: goes back to the chest and waits", job.status == "paused" and job.phase == "chest"
    and w.turtle.x == 0 and w.turtle.y == 0 and w.turtle.z == 0 and w.turtle.f == 2)
  check("home: kept its place", job.step >= step)
  job.status = "running"
  job = runJob(w, job, { commands = { [20] = "cancel" } })
  check("cancel: goes back and ends the job", job.status == "cancelled" and w.turtle.x == 0 and w.turtle.z == 0)
end

do
  -- Picked up and put back at the start after getting lost.
  local c = config({ count = 1, length = 10, torches = 0 })
  local w = newWorld({ chest = { { "minecraft:coal", 64 } } })
  local job = runJob(w, miner.newJob(c), { commands = { [12] = "pause" } })
  job.pending = nil
  job.lost = true
  w.turtle.x, w.turtle.y, w.turtle.z, w.turtle.f = 0, 0, 0, 0
  local m = miner.new(job, { turtle = w.api, chest = function() return w.peripheral end, save = function() end,
    poll = function() end, wait = function() end })
  m.putBack()
  job.status = "running"
  job = runJob(w, job)
  check("put back: finishes from the start", job.status == "finished")
end

-- The app, on simulated computers ----------------------------------------------------------------

package.path = "tests/?.lua;" .. package.path
local sim = require("sim")

local function has(s, text) return type(s) == "string" and s:find(text, 1, true) ~= nil end
local function screenHas(c, text, limit)
  local ok, err = pcall(sim.run, function() return has(c.screenText(), text) end, limit or 60)
  if not ok then
    print("Waiting for '" .. text .. "' on computer " .. c.id .. ", the screen says:\n" .. c.screenText())
    error(err, 0)
  end
  return true
end
local function press(c, name) c.env.os.queueEvent("key", c.env.keys[name]) end
local function char(c, ch) c.env.os.queueEvent("char", ch) end
local function line(c, text) c.env.os.queueEvent("sim_line", text) end
local function down(c, n) for _ = 1, n do press(c, "down") end end
-- Types a key until the screen shows `text`, since a remote can miss keys while it's asking the turtle.
local function charUntil(c, ch, text)
  for _ = 1, 10 do
    char(c, ch)
    if pcall(sim.run, function() return has(c.screenText(), text) end, 3) then return true end
  end
  return screenHas(c, text, 1)
end

local APP = { id = "strip-mine", name = "Strip Mine", version = "1.0.0" }

local function openApp(c, user)
  local fn = assert(loadfile(DIR .. "main.lua"))
  setfenv(fn, c.env)
  return sim.spawn(c, fn, { user = user or "me", admin = false }, APP)
end

-- A turtle in a world, running the service. Each turtle action waits for an event, as in the game.
local function turtleComputer(id, w)
  local c = sim.computer(id, { width = 39, label = "Digger" })
  c.appDir = DIR
  c.env.turtle = w.api
  local real = c.env.peripheral
  c.env.peripheral = setmetatable({
    wrap = function(name) if name == "front" then return w.peripheral end end,
  }, { __index = real })
  w.tick = function()
    -- About as long as a turtle takes to do anything.
    local id = c.env.os.startTimer(0.4)
    repeat
      local _, done = coroutine.yield("timer")
    until done == id
  end
  local fn = assert(loadfile(DIR .. "service.lua"))
  setfenv(fn, c.env)
  c.service = sim.spawn(c, fn, APP)
  return c
end

do
  local w = newWorld({ chest = { { "minecraft:coal", 64 }, { "minecraft:torch", 64 } },
    blocks = { [key(0, 1, 3)] = "minecraft:diamond_ore" } })
  local t = turtleComputer(5, w)
  openApp(t)
  screenHas(t, "New mine")
  press(t, "enter")
  screenHas(t, "Length: 32 blocks")
  press(t, "enter")
  screenHas(t, "1 to 256")
  line(t, "5")
  screenHas(t, "Length: 5 blocks")
  down(t, 1)
  press(t, "enter")
  screenHas(t, "0 to 64")
  line(t, "2")
  screenHas(t, "Branches: 2")
  down(t, 4)
  press(t, "enter") -- the branch size
  screenHas(t, "Branch size: 1 wide, 3 high")
  check("app: the corridor is 3x3 to start with", has(t.screenText(), "Corridor size: 3 wide, 3 high"))
  press(t, "end")
  press(t, "up")
  screenHas(t, "2 new branches")
  press(t, "enter")
  screenHas(t, "Start mining?")
  char(t, "y")
  screenHas(t, "Last job: Finished", 600)
  local tjobs = t.env.require("jobs")
  check("app: the job finished", tjobs.load().status == "finished")
  check("app: the settings are kept", has(t.files["home/me/.config/strip-mine/settings"], "length"))
  -- Slot 1 is 3 blocks along a 3 wide corridor, and has a branch each side.
  check("app: digs 1x3 branches both ways", not w.get(6, 2, 3) and not w.get(-6, 2, 3)
    and w.get(7, 0, 3) and w.get(-7, 0, 3))
  check("app: digs a 3x3 corridor", not w.get(1, 2, 2) and not w.get(-1, 0, 3) and w.get(2, 1, 2))
  check("app: the diamond is in the chest", (function()
    for _, item in pairs(w.chest) do if item.name == "minecraft:diamond" then return true end end
  end)())
  check("app: the mine has a record", tjobs.mine() and tjobs.mine().branches[1].l.dug == 5)
  down(t, 3)
  press(t, "enter")
  screenHas(t, "diamond 1")
  press(t, "backspace")

  -- Again: it carries on with the next slot.
  press(t, "home")
  press(t, "enter")
  screenHas(t, "Dig more")
  screenHas(t, "(fixed)")
  down(t, 4)
  press(t, "enter")
  screenHas(t, "can't change")
  press(t, "enter")
  press(t, "end")
  press(t, "up")
  screenHas(t, "2 new branches")
  press(t, "enter")
  screenHas(t, "Start mining?")
  char(t, "y")
  screenHas(t, "Last job: Finished", 600)
  check("app: the next job digs the next slot", not w.get(6, 2, 6) and not w.get(-6, 2, 6) and not w.get(0, 1, 6))
  check("app: and nothing past it", w.get(0, 1, 7) ~= nil)
  check("app: the record has both jobs", tjobs.mine().branches[2].r.dug == 5 and tjobs.mine().totals.jobs == 2)
  press(t, "down")
  press(t, "enter")
  screenHas(t, "=dug")
  check("map: shows the corridor and branches", has(t.screenText(), "=====|=====") and has(t.screenText(), "#"))
  press(t, "q")
  press(t, "down")
  press(t, "enter")
  screenHas(t, "4 branches, 20 blocks long")
  check("totals: adds up both jobs", has(t.screenText(), "2 jobs"))
  press(t, "backspace")

  -- A longer mine to watch and control from a pocket computer.
  local job = assert(tjobs.newJob(assert(plan.check({ length = 60, count = 4, torches = 0 }))))
  tjobs.save(job)
  t.env.os.queueEvent("strip_mine_command", "start")
  screenHas(t, "Mining")
  char(t, "v")
  screenHas(t, "@turtle")
  press(t, "q")
  screenHas(t, "V:map")

  local p = sim.computer(6, { width = 26, label = "Pocket" })
  p.appDir = DIR
  openApp(p)
  screenHas(p, "Digger")
  press(p, "enter")
  screenHas(p, "Mining")
  screenHas(p, "A:ask")
  char(p, "p")
  screenHas(p, "allowed to control")
  char(p, "y")
  screenHas(p, "Asked.")
  local fingerprint = p.env.require("crypto").fingerprint(select(2, p.env.require("trust").identity()))
  check("monitor: shows its own fingerprint", has(p.screenText(), fingerprint:sub(1, 10)))
  press(p, "enter")

  -- At the turtle: allow it.
  screenHas(t, "asking for remote control")
  char(t, "m")
  screenHas(t, "Asking: Pocket #6")
  press(t, "enter")
  screenHas(t, "Allow it?")
  check("turtle: shows the pocket's fingerprint", has(t.screenText(), fingerprint:sub(1, 10)))
  char(t, "y")
  screenHas(t, "Pocket #6")
  press(t, "backspace")

  -- Now the pocket computer can pause it, and resume it.
  sim.advance(3)
  char(p, "p")
  screenHas(p, "Paused in the mine")
  check("monitor: paused it", t.env.require("jobs").load().status == "paused")
  screenHas(t, "Paused in the mine")
  char(p, "h")
  screenHas(p, "Paused at the chest", 300)
  check("monitor: brought it home", w.turtle.x == 0 and w.turtle.y == 0 and w.turtle.z == 0)
  char(p, "r")
  screenHas(p, "Mining", 300)
  char(t, "c")
  screenHas(t, "Cancel the mine?")
  char(t, "y")
  screenHas(t, "Last job: Cancelled", 600)
  check("turtle: cancelled it at the chest", w.turtle.x == 0 and w.turtle.z == 0)
  screenHas(p, "Cancelled")
  check("cancel: the record keeps what it dug", tjobs.mine().totals.jobs == 3)

  -- The pocket computer can look at the map, and ask for more branches.
  charUntil(p, "v", "V:status")
  check("monitor: shows the map", has(p.screenText(), "=dug") and has(p.screenText(), "|"))
  charUntil(p, "v", "V:map")
  check("monitor: shows the mine's totals", has(p.screenText(), "Mine: "))
  charUntil(p, "d", "How many more")
  line(p, "1")
  screenHas(p, "Mining", 300)
  check("remote: started a job with the last settings", tjobs.load().config.length == 60
    and tjobs.load().config.newBranches == 1)
  char(p, "c")
  screenHas(p, "Cancel its mine?")
  char(p, "y")
  screenHas(p, "Cancelled", 600)

  -- A computer that wasn't allowed can't do anything.
  local stranger = sim.computer(7, { label = "Stranger" })
  local reply = sim.call(stranger, function()
    return stranger.env.require("net").request(5, 4204, { op = "command", command = "resume" }, { timeout = 5 })
  end, 60)
  check("remote: refuses a computer it doesn't know", reply and reply.payload.denied == true)
end

if failed > 0 then
  print(("strip-mine: %d passed, %d FAILED"):format(passed, failed))
  os.exit(1)
end
print(("strip-mine: all %d passed"):format(passed))
