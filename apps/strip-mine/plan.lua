--[[ The layout of a strip mine, and what it costs. Nothing here touches the turtle or files, so the
app, the service and the tests all work out the same mine from the same settings.

Coordinates are relative to where the turtle starts, on the floor with the chest behind it: x is to
the right, y is up and z is forward. Facings are 0 forward (+z), 1 right (+x), 2 back (-z) and 3
left (-x), so turning right adds 1.

A mine is a corridor going forward from the start, with branches going sideways from it. Branches
sit in slots along the corridor, one every `pitch` blocks, and a slot has room for a branch on each
side. The corridor and the branches each have their own cross-section. The turtle walks one lane
through the middle of each, at that cross-section's height `travel`, and clears the rest of the
cross-section around it. The plan is the list of lane cells it visits, in order, each one next to
the last.

A mine is dug a few branches at a time, by one job after another. What earlier jobs dug is kept by
the app (see jobs.lua) as a record, and plan.assign works out from it what the next job digs: any
branch that was left short first, then new branches in the next free slots. The job's settings
hold that list, so everything here works the same from the settings alone. ]]

local plan = {}

-- Bumped when the settings a job is saved with change shape, so an old job isn't misread.
plan.VERSION = 2

plan.DIRS = { [0] = { 0, 1 }, { 1, 0 }, { 0, -1 }, { -1, 0 } }

plan.SIZES = {
    { id = "1x2", label = "1 wide, 2 high", width = 1, height = 2, travel = 0 },
    { id = "1x3", label = "1 wide, 3 high", width = 1, height = 3, travel = 1 },
    { id = "3x3", label = "3 wide, 3 high", width = 3, height = 3, travel = 1 },
}

plan.SIDES = {
    { id = "both", label = "Both sides", sides = { "l", "r" } },
    { id = "right", label = "To the right", sides = { "r" } },
    { id = "left", label = "To the left", sides = { "l" } },
}

-- Which way along x each side of the corridor is.
plan.SIGN = { l = -1, r = 1 }

-- The most branch slots along one corridor.
plan.MAX_SLOTS = 128

-- The settings that fix where everything in a mine is. They can't change once a mine is started.
plan.LAYOUT = { "corridor", "branch", "spacing", "side" }

-- Thrown away when the junk filter is on, unless it's needed for sealing.
plan.JUNK = {
    "minecraft:cobblestone", "minecraft:cobbled_deepslate", "minecraft:stone", "minecraft:deepslate",
    "minecraft:dirt", "minecraft:gravel", "minecraft:flint", "minecraft:sand", "minecraft:andesite",
    "minecraft:diorite", "minecraft:granite", "minecraft:tuff", "minecraft:calcite",
    "minecraft:netherrack", "minecraft:dripstone_block", "minecraft:pointed_dripstone",
}

-- Blocks that can fill a hole: solid, and they don't fall.
plan.FILLER = {
    ["minecraft:cobblestone"] = true, ["minecraft:cobbled_deepslate"] = true, ["minecraft:stone"] = true,
    ["minecraft:deepslate"] = true, ["minecraft:dirt"] = true, ["minecraft:andesite"] = true,
    ["minecraft:diorite"] = true, ["minecraft:granite"] = true, ["minecraft:tuff"] = true,
    ["minecraft:calcite"] = true, ["minecraft:netherrack"] = true,
}

-- What the turtle takes from the chest to refuel with, and how far each one goes.
plan.FUEL = { ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80, ["minecraft:coal_block"] = 800 }
plan.COAL = 80

plan.TORCH = "minecraft:torch"
local TORCHES = { ["minecraft:torch"] = true, ["minecraft:wall_torch"] = true }

plan.LIMITS = {
    keep = { 0, 15 * 64 },
    length = { 1, 256 },
    count = { 0, 64 },
    spacing = { 1, 16 },
    torches = { 0, 64 },
}

function plan.defaults()
    local junk = {}
    for i, name in ipairs(plan.JUNK) do junk[i] = name end
    return {
        length = 32, count = 4, spacing = 2, side = "both", corridor = "3x3", branch = "1x2",
        -- Whether branches an earlier job dug shorter than `length` are made longer.
        extend = false,
        torches = 12, vein = true, seal = true, junk = true, junkList = junk,
        -- How many of a junk item to carry each trip and put in the chest, by name.
        keep = {},
    }
end

local function find(list, id)
    for _, entry in ipairs(list) do
        if entry.id == id then return entry end
    end
end

function plan.size(id) return find(plan.SIZES, id) end
function plan.side(config) return find(plan.SIDES, config.side) end

-- The settings with anything missing taken from the defaults, or nil and why they can't be used.
function plan.check(config)
    if type(config) ~= "table" then return nil, "Those settings aren't a table." end
    local out = plan.defaults()
    for key, value in pairs(config) do out[key] = value end
    -- Settings saved before there was a separate corridor size.
    if config.size ~= nil and config.branch == nil then out.branch = config.size end
    out.size, out.connect = nil, nil
    for key, range in pairs(plan.LIMITS) do
        local n = out[key]
        if key == "keep" then n = 0 end
        if type(n) ~= "number" or n ~= math.floor(n) or n < range[1] or n > range[2] then
            return nil, ("The %s has to be a whole number from %d to %d."):format(key, range[1], range[2])
        end
    end
    if not plan.size(out.corridor) then return nil, "That corridor size isn't one of the choices." end
    if not plan.size(out.branch) then return nil, "That branch size isn't one of the choices." end
    if not plan.side(out) then return nil, "That side isn't one of the choices." end
    if type(out.junkList) ~= "table" then return nil, "The junk list isn't a list." end
    for _, name in ipairs(out.junkList) do
        if type(name) ~= "string" then return nil, "The junk list has something that isn't a name in it." end
    end
    if type(out.keep) ~= "table" then return nil, "The amounts of junk to keep aren't a table." end
    local range = plan.LIMITS.keep
    for name, n in pairs(out.keep) do
        if type(name) ~= "string" or type(n) ~= "number" or n ~= math.floor(n) or n < range[1] or n > range[2] then
            return nil, ("Junk to keep has to be a whole number from %d to %d."):format(range[1], range[2])
        end
    end
    for _, key in ipairs({ "extend", "vein", "seal", "junk" }) do out[key] = out[key] == true end
    return out
end

-- Block kinds --------------------------------------------------------------------------------------

function plan.isOre(block)
    if type(block) ~= "table" or type(block.name) ~= "string" then return false end
    local tags = type(block.tags) == "table" and block.tags or {}
    return tags["c:ores"] or tags["forge:ores"] or block.name:find("_ore$") ~= nil
        or block.name == "minecraft:ancient_debris"
end

function plan.isLiquid(block)
    if type(block) ~= "table" then return false end
    local tags = type(block.tags) == "table" and block.tags or {}
    return block.name == "minecraft:water" or block.name == "minecraft:lava"
        or tags["minecraft:water"] or tags["minecraft:lava"] or false
end

function plan.isTorch(block)
    return type(block) == "table" and TORCHES[block.name] == true
end

-- Whether the turtle could have dug or walked through here: nothing, a liquid or a torch.
function plan.isOpen(block)
    return block == nil or plan.isLiquid(block) or plan.isTorch(block)
end

-- Whether this looks like something to keep items in.
function plan.isContainer(block)
    if type(block) ~= "table" or type(block.name) ~= "string" then return false end
    return block.name:find("chest", 1, true) ~= nil or block.name:find("barrel", 1, true) ~= nil
        or block.name:find("shulker_box", 1, true) ~= nil
end

-- Whether a cell the turtle dug could hold this now. Liquid can flow in, and water can make a new
-- source, but lava can't, so a lava source means the cell was never dug.
function plan.couldBeDug(block)
    if block == nil or plan.isTorch(block) then return true end
    if not plan.isLiquid(block) then return false end
    local tags = type(block.tags) == "table" and block.tags or {}
    if block.name == "minecraft:lava" or tags["minecraft:lava"] then
        local level = type(block.state) == "table" and block.state.level
        return type(level) == "number" and level > 0
    end
    return true
end

-- Layout -------------------------------------------------------------------------------------------

local function section(id)
    local size = plan.size(id)
    return { id = size.id, width = size.width, height = size.height, travel = size.travel, half = (size.width - 1) / 2 }
end

--[[ The mine's measurements, for a job's settings:
  corridor, branch  each cross-section: width, height, travel (the lane's height) and half (how far
                    it reaches either side of the lane)
  pitch             lane to lane, from one branch slot to the next. Slot k's lane is at z = k * pitch
  lengths           how long this job leaves each branch it works on, as lengths[slot][side]
  corridorEnd       the z the corridor reaches once this job is done ]]
function plan.shape(config)
    local C, B = section(config.corridor), section(config.branch)
    local shape = { corridor = C, branch = B, pitch = config.spacing + B.width, lengths = {} }
    local reach = math.max(config.corridorDug or -1, 0)
    for _, w in ipairs(config.work or {}) do
        local slot = shape.lengths[w.slot] or {}
        shape.lengths[w.slot] = slot
        slot[w.side] = math.max(slot[w.side] or 0, w.to)
        reach = math.max(reach, w.slot * shape.pitch)
    end
    shape.corridorEnd = reach
    return shape
end

-- The z of a slot's lane.
function plan.slotZ(shape, slot) return slot * shape.pitch end

local function key(x, y, z) return x .. "," .. y .. "," .. z end
plan.key = key

-- Records -----------------------------------------------------------------------------------------

--[[ What has been dug in a mine, kept from one job to the next:
  layout     the settings in plan.LAYOUT, which every job in the mine uses
  corridor   the z the corridor has been dug to, or -1 before any of it
  branches   branches[slot][side] = { dug, want }: how far it has been dug, and how far a job set
             out to dig it. Only branches with some of them dug are here ]]
function plan.newRecord(config)
    local layout = {}
    for _, k in ipairs(plan.LAYOUT) do layout[k] = config[k] end
    return { layout = layout, corridor = -1, branches = {} }
end

--[[ A job's settings, from what the person chose and the mine's record, or nil for a new mine. It
adds:
  version       plan.VERSION
  corridorDug   the record's corridor
  work          what to dig, in order, as a list of { slot, side, from, to }: each branch from
                `from` blocks out to `to`. Branches left short come first, in the same pass outward
                as the `count` new ones
  newBranches   how many of the work items are new branches ]]
function plan.assign(settings, record)
    local config = {}
    for k, v in pairs(settings) do config[k] = v end
    if record then
        for _, k in ipairs(plan.LAYOUT) do config[k] = record.layout[k] end
    end
    config.version = plan.VERSION
    config.corridorDug = record and record.corridor or -1
    local work, new = {}, 0
    local sides = plan.side(config).sides
    local branches = record and record.branches or {}
    for k = 1, plan.MAX_SLOTS do
        local slot = branches[k]
        for _, side in ipairs(sides) do
            local b = slot and slot[side]
            if b and b.dug > 0 then
                local want = config.extend and math.max(b.want, config.length) or b.want
                if b.dug < want then work[#work + 1] = { slot = k, side = side, from = b.dug, to = want } end
            elseif new < config.count then
                work[#work + 1] = { slot = k, side = side, from = 0, to = config.length }
                new = new + 1
            end
        end
    end
    config.work, config.newBranches = work, new
    return config
end

-- How far everything had been dug before step `upto`: { corridor, branches[slot][side] = length }.
-- Branches with nothing new dug aren't there.
function plan.progress(config, steps, upto)
    local out = { corridor = config.corridorDug, branches = {} }
    for i = 1, math.min(upto - 1, #steps) do
        local s = steps[i]
        if s.slice then
            if s.kind == "corridor" then
                out.corridor = math.max(out.corridor, s.z)
            else
                local b = out.branches[s.slot] or {}
                out.branches[s.slot] = b
                b[s.side] = math.max(b[s.side] or 0, s.along)
            end
        end
    end
    return out
end

-- Adds what a job dug before step `upto` to a mine's record.
function plan.record(record, config, steps, upto)
    local p = plan.progress(config, steps, upto)
    record.corridor = math.max(record.corridor, p.corridor)
    for _, w in ipairs(config.work) do
        local got = p.branches[w.slot] and p.branches[w.slot][w.side] or 0
        local slot = record.branches[w.slot] or {}
        local b = slot[w.side]
        if got > 0 or b then
            b = b or { dug = 0, want = 0 }
            b.dug, b.want = math.max(b.dug, got), math.max(b.want, w.to)
            slot[w.side] = b
            record.branches[w.slot] = slot
        end
    end
end

-- Steps ---------------------------------------------------------------------------------------------

local function sign(n) return n > 0 and 1 or n < 0 and -1 or 0 end

--[[ The lane cells in the order they're visited. Each step is
  x, y, z  where it is
  kind     "corridor" or "branch", for the cross-section
  dir      the facing the corridor or branch runs in here, for the cross-section
  slice    whether to clear the cross-section and look around. False for cells already done, and
           for walking back
  torch    the facing to put a torch in a niche in the wall, for a lane on the floor, or true to
           put it on the floor below a raised lane. Nil for none
  tunnel   which item of config.work it's on the way into or out of, or nil in the corridor
  slot, side, along   for a branch: where it is, and how many blocks out from the corridor

The turtle goes up the corridor, and out and back along each branch on the way. Where the corridor
and branches have their lanes at different heights, it changes height in the middle of the
corridor. It ends back at the corridor's first cell. ]]
function plan.steps(config)
    local shape = plan.shape(config)
    local C, B = shape.corridor, shape.branch
    local N = config.torches
    local steps, sliced = {}, {}
    local x, y, z = 0, C.travel, 0

    -- Torches in the corridor stay out of the rows branches leave from, so they're never in the
    -- way of the turtle changing height or of a branch's walls. One that would be there moves on
    -- to the next row clear of them.
    local function clearOfBranches(cz)
        local r = cz % shape.pitch
        return r > B.half and r < shape.pitch - B.half
    end
    local function corridorTorch(cz)
        if cz < 1 or not clearOfBranches(cz) then return false end
        while cz >= 1 do
            if cz % N == 0 then return true end
            cz = cz - 1
            if cz < 1 or clearOfBranches(cz) then return false end
        end
        return false
    end

    local function torchFor(s)
        if N == 0 then return nil end
        if s.kind == "corridor" then
            if not corridorTorch(s.z) then return nil end
            if C.travel > 0 then return true end
            -- A niche in the wall, away from the branches if they're only on one side.
            return config.side == "left" and 1 or 3
        end
        if s.along % N ~= 0 then return nil end
        if B.travel > 0 then return true end
        return 2
    end

    local function add(kind, cx, cy, cz, f, mine, info)
        local k = key(cx, cy, cz)
        local slice = mine and not sliced[k]
        if slice then sliced[k] = true end
        local s = { x = cx, y = cy, z = cz, dir = f, kind = kind, slice = slice }
        for name, v in pairs(info or {}) do s[name] = v end
        if slice then s.torch = torchFor(s) end
        steps[#steps + 1] = s
        x, y, z = cx, cy, cz
    end

    add("corridor", 0, C.travel, 0, 0, config.corridorDug < 0)
    for index, w in ipairs(config.work) do
        local zk = plan.slotZ(shape, w.slot)
        for cz = z + 1, zk do add("corridor", 0, C.travel, cz, 0, cz > config.corridorDug) end
        local s = plan.SIGN[w.side]
        local out, back = s > 0 and 1 or 3, s > 0 and 3 or 1
        local function info(along)
            return { tunnel = index, slot = w.slot, side = w.side, along = along }
        end
        if y ~= B.travel then add("corridor", 0, B.travel, zk, out, false, info()) end
        for o = 1, C.half do add("corridor", s * o, B.travel, zk, out, false, info()) end
        for along = 1, w.to do
            add("branch", s * (C.half + along), B.travel, zk, out, along > w.from, info(along))
        end
        for along = w.to - 1, 1, -1 do
            add("branch", s * (C.half + along), B.travel, zk, back, false, info(along))
        end
        for o = C.half, 0, -1 do add("corridor", s * o, B.travel, zk, back, false, info()) end
        -- Straight on to the other side of the same slot, without climbing back to the lane.
        local nextWork = config.work[index + 1]
        if y ~= C.travel and not (nextWork and nextWork.slot == w.slot) then
            add("corridor", 0, C.travel, zk, 0, false, info())
        end
    end
    for cz = z - 1, 0, -1 do add("corridor", 0, C.travel, cz, 2, false) end
    return steps
end

-- From the start, on the floor, up to the first lane cell.
function plan.entry(config)
    local C = section(config.corridor)
    local cells = {}
    for y = 0, C.travel do cells[#cells + 1] = { 0, y, 0 } end
    return cells
end

-- Where the turtle can go: every lane cell of the plan and the way in. Cells it hasn't reached yet
-- are in the plan anyway, so cutting through them on the way to the chest only digs them early.
function plan.walkable(config, steps)
    local cells = {}
    for _, step in ipairs(steps) do cells[key(step.x, step.y, step.z)] = true end
    for _, c in ipairs(plan.entry(config)) do cells[key(c[1], c[2], c[3])] = true end
    return cells
end

local NEIGHBOURS = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 }, { 0, 1, 0 }, { 0, -1, 0 } }

--[[ The shortest way from one walkable cell to another, as a list of { x, y, z } from `from` to
`to`, both included. Nil if there's none, which happens when `from` isn't walkable. ]]
function plan.route(walkable, from, to)
    local start, goal = key(from[1], from[2], from[3]), key(to[1], to[2], to[3])
    if start == goal then return { { from[1], from[2], from[3] } } end
    if not walkable[start] or not walkable[goal] then return nil end
    -- Search back from the goal, so each cell points the way to it.
    local next, queue, head = { [goal] = false }, { { to[1], to[2], to[3] } }, 1
    while queue[head] do
        local c = queue[head]
        head = head + 1
        for _, d in ipairs(NEIGHBOURS) do
            local n = { c[1] + d[1], c[2] + d[2], c[3] + d[3] }
            local k = key(n[1], n[2], n[3])
            if walkable[k] and next[k] == nil then
                next[k] = c
                if k == start then
                    local path, at = { n }, n
                    while next[key(at[1], at[2], at[3])] do
                        at = next[key(at[1], at[2], at[3])]
                        path[#path + 1] = at
                    end
                    return path
                end
                queue[#queue + 1] = n
            end
        end
    end
end

-- A distance the walk from this lane cell to the start can't be more than.
function plan.homeBound(shape, x, z)
    return math.abs(x) + math.abs(z) + shape.corridor.travel + 3
end

-- Whether a cell is in the corridor, or in a branch this job digs.
function plan.inside(shape, x, y, z)
    local C, B = shape.corridor, shape.branch
    if math.abs(x) <= C.half then
        return y >= 0 and y < C.height and z >= 0 and z <= shape.corridorEnd
    end
    if y < 0 or y >= B.height then return false end
    local k = math.floor((z + B.half) / shape.pitch)
    if k < 1 or math.abs(z - k * shape.pitch) > B.half then return false end
    local slot = shape.lengths[k]
    local length = slot and (x > 0 and slot.r or slot.l)
    return length ~= nil and math.abs(x) - C.half <= length
end

-- The cross-section of a step, as a list of { x, y, z }.
function plan.section(shape, step)
    local cs = shape[step.kind]
    local cells = {}
    local right = plan.DIRS[(step.dir + 1) % 4]
    for o = -cs.half, cs.half do
        for y = 0, cs.height - 1 do
            cells[#cells + 1] = { step.x + o * right[1], y, step.z + o * right[2] }
        end
    end
    return cells
end

-- Cost ----------------------------------------------------------------------------------------------

-- Moves to clear one cross-section `cs` (shape.corridor or shape.branch), beyond stepping into it.
function plan.sliceMoves(config, cs)
    local looking = config.vein or config.seal
    local columns = cs.width
    local sideways = (columns - 1) * 2
    local vertical = looking and 2 * (cs.height - 1) or 0
    return sideways + columns * vertical
end

--[[ What's left of the job from step `from` on: { fuel, blocks }. Fuel includes the walk home and
an allowance for following veins and going to the chest. Blocks counts what the cross-sections
hold, before veins. ]]
function plan.estimate(config, steps, from)
    local shape = plan.shape(config)
    from = from or 1
    local moves, blocks = 0, 0
    for i = from, #steps do
        moves = moves + 1
        local s = steps[i]
        if s.slice then
            local cs = shape[s.kind]
            moves = moves + plan.sliceMoves(config, cs)
            blocks = blocks + cs.width * cs.height
        end
    end
    moves = moves + 2 * shape.corridor.travel
    -- Veins add about a tenth, and each trip to the chest walks out and back.
    local extra = config.vein and math.ceil(moves / 10) or 0
    local trips = math.ceil(blocks / (config.junk and 900 or 600))
    local longest = 0
    for _, w in ipairs(config.work) do longest = math.max(longest, w.to) end
    local reach = shape.corridorEnd + shape.corridor.half + longest
    return { fuel = moves + extra + trips * reach, blocks = blocks }
end

-- How many coal that much fuel takes.
function plan.coal(fuel) return math.ceil(fuel / plan.COAL) end

return plan
