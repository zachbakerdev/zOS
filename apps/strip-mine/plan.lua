--[[ The layout of a strip mine, and what it costs. Nothing here touches the turtle or files, so the
app, the service and the tests all work out the same mine from the same settings.

Coordinates are relative to where the turtle starts, on the floor with the chest behind it: x is to
the right, y is up and z is forward. Facings are 0 forward (+z), 1 right (+x), 2 back (-z) and 3
left (-x), so turning right adds 1.

A mine is a corridor running sideways from the start, with tunnels going forward from it. The turtle
walks one lane through the middle of every tunnel and corridor, at height `travel`, and clears the
rest of the tunnel's cross-section around it. The plan is the list of lane cells it visits, in
order, each one adjacent to the last. ]]

local plan = {}

plan.DIRS = { [0] = { 0, 1 }, { 1, 0 }, { 0, -1 }, { -1, 0 } }

plan.SIZES = {
    { id = "1x2", label = "1 wide, 2 high", width = 1, height = 2, travel = 0 },
    { id = "1x3", label = "1 wide, 3 high", width = 1, height = 3, travel = 1 },
    { id = "3x3", label = "3 wide, 3 high", width = 3, height = 3, travel = 1 },
}

plan.SIDES = {
    { id = "right", label = "To the right" },
    { id = "left", label = "To the left" },
    { id = "both", label = "Both sides" },
}

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
    count = { 1, 64 },
    spacing = { 1, 16 },
    torches = { 0, 64 },
}

function plan.defaults()
    local junk = {}
    for i, name in ipairs(plan.JUNK) do junk[i] = name end
    return {
        length = 32, count = 4, spacing = 2, side = "right", size = "1x2", connect = false,
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

function plan.size(config) return find(plan.SIZES, config.size) end
function plan.side(config) return find(plan.SIDES, config.side) end

-- The settings with anything missing taken from the defaults, or nil and why they can't be used.
function plan.check(config)
    if type(config) ~= "table" then return nil, "Those settings aren't a table." end
    local out = plan.defaults()
    for key, value in pairs(config) do out[key] = value end
    for key, range in pairs(plan.LIMITS) do
        local n = out[key]
        if key == "keep" then n = 0 end
        if type(n) ~= "number" or n ~= math.floor(n) or n < range[1] or n > range[2] then
            return nil, ("The %s has to be a whole number from %d to %d."):format(key, range[1], range[2])
        end
    end
    if not plan.size(out) then return nil, "That tunnel size isn't one of the choices." end
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
    for _, key in ipairs({ "connect", "vein", "seal", "junk" }) do out[key] = out[key] == true end
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

--[[ The mine's measurements:
  width, height, travel  the cross-section, and the height of the lane in it
  half                   how far the cross-section reaches either side of the lane
  pitch                  lane to lane, from one tunnel to the next
  near, far              the z of the near and far corridors' lanes
  xs                     each tunnel's x, in the order they're dug ]]
function plan.shape(config)
    local size = plan.size(config)
    local half = (size.width - 1) / 2
    local pitch = config.spacing + size.width
    local xs = {}
    for k = 0, config.count - 1 do
        if config.side == "right" then
            xs[#xs + 1] = k * pitch
        elseif config.side == "left" then
            xs[#xs + 1] = 0 - k * pitch
        else
            xs[#xs + 1] = (k - math.floor((config.count - 1) / 2)) * pitch
        end
    end
    -- The near corridor's lane is pushed forward as far as the cross-section reaches, so a wide
    -- corridor doesn't dig out the chest.
    return {
        width = size.width, height = size.height, travel = size.travel, half = half, pitch = pitch,
        near = half, far = half + config.length, xs = xs,
    }
end

local function key(x, y, z) return x .. "," .. y .. "," .. z end
plan.key = key

local function facingOf(dx, dz)
    for f = 0, 3 do
        if plan.DIRS[f][1] == dx and plan.DIRS[f][2] == dz then return f end
    end
end

local function sign(n) return n > 0 and 1 or n < 0 and -1 or 0 end

--[[ The lane cells in the order they're visited. Each step is
  x, z    where it is. The lane is at y = shape.travel
  dir     the facing the tunnel runs in here, for the cross-section
  slice   whether to clear the cross-section and look around. False for cells already done, and
          for walking back along a tunnel
  torch   the facing to put a torch in a niche in the wall, for a 1x2 lane, or true to put it on
          the floor below a raised lane. Nil for none
  tunnel  which tunnel it's in, by its place in shape.xs, or nil for a corridor ]]
function plan.steps(config)
    local shape = plan.shape(config)
    local steps, sliced = {}, {}
    local x, z = 0, shape.near
    local N = config.torches

    local function torchFor(cx, cz, f, tunnel)
        if N == 0 then return nil end
        local along = (f % 2 == 0) and (cz - shape.near) or cx
        if along == 0 or along % N ~= 0 then return nil end
        -- Not right next to the chest, which may be a double chest.
        if not tunnel and cz == shape.near and math.abs(cx) <= 1 then return nil end
        if shape.travel > 0 then return true end
        -- A niche on the side away from the tunnels.
        if tunnel then return 3 end
        return cz == shape.near and 2 or 0
    end

    local function add(cx, cz, f, mine, tunnel)
        local k = key(cx, 0, cz)
        local slice = mine and not sliced[k]
        if slice then sliced[k] = true end
        steps[#steps + 1] = {
            x = cx, z = cz, dir = f, slice = slice, tunnel = tunnel,
            torch = slice and torchFor(cx, cz, f, tunnel) or nil,
        }
    end

    -- Along a straight line, not including where it starts.
    local function go(tx, tz, mine, tunnel)
        local dx, dz = sign(tx - x), sign(tz - z)
        local f = facingOf(dx, dz)
        while x ~= tx or z ~= tz do
            x, z = x + dx, z + dz
            add(x, z, f, mine, tunnel)
        end
    end

    local first = shape.xs[1]
    add(0, shape.near, first > 0 and 1 or first < 0 and 3 or 0, true, nil)
    if first ~= 0 then go(first, shape.near, true) end

    for k, tx in ipairs(shape.xs) do
        local last = k == #shape.xs
        if config.connect then
            -- Up one tunnel, along the far corridor, down the next.
            local out = k % 2 == 1
            go(tx, out and shape.far or shape.near, true, k)
            if not last then go(shape.xs[k + 1], z, true) end
        else
            go(tx, shape.far, true, k)
            go(tx, shape.near, false, k)
            if not last then go(shape.xs[k + 1], shape.near, true) end
        end
    end

    if config.connect then
        -- The serpentine joins every other pair of tunnels at each end. Fill in the rest of both
        -- corridors, nearest gap first, then go home.
        local lo, hi = math.min(0, shape.xs[1], shape.xs[#shape.xs]), math.max(0, shape.xs[1], shape.xs[#shape.xs])
        local lanes = {}
        for _, s in ipairs(steps) do lanes[key(s.x, 0, s.z)] = true end
        local gaps = {}
        for cx = lo, hi do
            for _, cz in ipairs({ shape.near, shape.far }) do
                lanes[key(cx, 0, cz)] = true
                if not sliced[key(cx, 0, cz)] and (cz == shape.near or (cx >= math.min(shape.xs[1], shape.xs[#shape.xs])
                    and cx <= math.max(shape.xs[1], shape.xs[#shape.xs]))) then
                    gaps[#gaps + 1] = { cx, cz }
                end
            end
        end
        local function walkTo(tx, tz)
            local route = plan.route(lanes, { x, 0, z }, { tx, 0, tz })
            for i = 2, #route do
                local c = route[i]
                local f = facingOf(c[1] - x, c[3] - z)
                local tunnel
                for k, kx in ipairs(shape.xs) do
                    if kx == c[1] and c[3] ~= shape.near and c[3] ~= shape.far then tunnel = k end
                end
                x, z = c[1], c[3]
                add(x, z, f, true, tunnel)
            end
        end
        while true do
            local best, bestDistance
            for i, g in ipairs(gaps) do
                if not sliced[key(g[1], 0, g[2])] then
                    local d = math.abs(g[1] - x) + math.abs(g[2] - z)
                    if not best or d < bestDistance then best, bestDistance = i, d end
                end
            end
            if not best then break end
            walkTo(gaps[best][1], gaps[best][2])
        end
        walkTo(0, shape.near)
    else
        go(0, shape.near, false)
    end
    steps[1].dir = steps[2] and steps[2].dir or 0
    return steps
end

-- From the start, on the floor, up and forward to the first lane cell.
function plan.entry(config)
    local shape = plan.shape(config)
    local cells = { { 0, 0, 0 } }
    for y = 1, shape.travel do cells[#cells + 1] = { 0, y, 0 } end
    for z = 1, shape.near do cells[#cells + 1] = { 0, shape.travel, z } end
    return cells
end

-- Where the turtle can go: every lane cell of the plan and the way in. Cells it hasn't reached yet
-- are in the plan anyway, so cutting through them on the way to the chest only digs them early.
function plan.walkable(config, steps)
    local shape = plan.shape(config)
    local cells = {}
    for _, step in ipairs(steps) do cells[key(step.x, shape.travel, step.z)] = true end
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
    return math.abs(x) + math.abs(z - shape.near) + shape.pitch + shape.near + shape.travel
end

-- Whether a cell is in any tunnel or corridor of the mine.
function plan.inside(shape, config, x, y, z)
    if y < 0 or y >= shape.height then return false end
    local lo, hi = 0, 0
    for _, tx in ipairs(shape.xs) do
        lo, hi = math.min(lo, tx), math.max(hi, tx)
        if math.abs(x - tx) <= shape.half and z >= shape.near - shape.half and z <= shape.far + shape.half then
            return true
        end
    end
    if x < lo - shape.half or x > hi + shape.half then return false end
    if math.abs(z - shape.near) <= shape.half then return true end
    return config.connect and math.abs(z - shape.far) <= shape.half
end

-- The cross-section of a step, as a list of { x, y, z }.
function plan.section(shape, step)
    local cells = {}
    local right = plan.DIRS[(step.dir + 1) % 4]
    for o = -shape.half, shape.half do
        for y = 0, shape.height - 1 do
            cells[#cells + 1] = { step.x + o * right[1], y, step.z + o * right[2] }
        end
    end
    return cells
end

-- Cost ----------------------------------------------------------------------------------------------

-- Moves to clear one cross-section, beyond stepping into it.
function plan.sliceMoves(config, shape)
    local looking = config.vein or config.seal
    local columns = shape.width
    local sideways = (columns - 1) * 2
    local vertical = looking and 2 * (shape.height - 1) or 0
    return sideways + columns * vertical
end

--[[ What's left of the job from step `from` on: { fuel, blocks }. Fuel includes the walk home and
an allowance for following veins and going to the chest. Blocks counts what the cross-sections
hold, before veins. ]]
function plan.estimate(config, steps, from)
    local shape = plan.shape(config)
    from = from or 1
    local moves, slices = 0, 0
    for i = from, #steps do
        moves = moves + 1
        if steps[i].slice then slices = slices + 1 end
    end
    moves = moves + slices * plan.sliceMoves(config, shape) + 2 * (shape.travel + shape.near)
    local blocks = slices * shape.width * shape.height
    -- Veins add about a tenth, and each trip to the chest walks out and back.
    local extra = config.vein and math.ceil(moves / 10) or 0
    local trips = math.ceil(blocks / (config.junk and 900 or 600))
    local reach = math.abs(shape.xs[#shape.xs]) + config.length
    return { fuel = moves + extra + trips * reach, blocks = blocks }
end

-- How many coal that much fuel takes.
function plan.coal(fuel) return math.ceil(fuel / plan.COAL) end

return plan
