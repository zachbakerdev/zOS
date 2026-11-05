--[[ Digs a strip mine, one step of the plan at a time, and keeps going after the turtle is unloaded.

Everything it needs to carry on is in the job table, which is saved before every move and turn. A
saved move or turn may or may not have happened when the turtle stopped:

- A move uses one fuel, so the fuel level says whether it happened.
- A turn uses none, so the turtle looks around. Cells it has already dug have to be open, so a facing
  that would put a dug cell where there's a block is wrong. It turns right to look further, and
  each of those turns is saved too, as a set of facings it could have.

Work that isn't a move or a turn is simply done again: digging an empty cell or looking at a wall
twice does no harm. The unit of work is the step: walk into the next lane cell, then clear and look
around its cross-section. Anything that leaves the lane, such as following a vein, keeps a trail
in job.path, so the turtle can always walk back to the lane and start the step again.

job fields:
  config            the settings, from plan.check
  status            "running", "paused", "stuck", "finished" or "cancelled"
  phase             "work" at the steps, "out" to the chest, "chest" at it, or "back" to the steps
  reason            why it's going to or is at the chest: "start", "full", "fuel", "home",
                    "cancel", "done" or "paused"
  goal              "home" or "cancel" when asked to stop, until it gets to the chest
  step, stage       the step being worked on, and "enter" before walking into it or "slice" after
  pos               { x, y, z, f }
  path              the trail back to the lane, as a list of { x, y, z }
  pending           the move or turn that may have happened: { kind = "move", to, fuel } or
                    { kind = "turn", f }
  unsure            { options = list of { x, y, z, f }, turning } while it works out which is right
  seen              what it last saw in nearby cells, as a list of { key, name or false for
                    nothing }, newest last
  holes             cells it dug outside the plan, such as veins and niches, by key
  chestName         what the chest is, for telling which way the turtle faces at the start
  message           why it's stuck
  stats             counts for the summary ]]

local plan = require("plan")

local miner = {}

local DIRS = plan.DIRS
local VEIN_REACH = 8     -- how far from the lane it follows a vein
local VEIN_CELLS = 64    -- the most cells of one vein it digs
local MARGIN = 20        -- fuel kept spare beyond the walk home
local RETRIES = 20       -- tries at digging out falling blocks, or moving past something
local KEEP_FUEL = 64     -- coal kept in the turtle after unloading
local KEEP_TORCHES = 64
local REMEMBER = 96      -- cells it remembers seeing, for finding its way after a restart
local HOLES = 500        -- cells dug outside the plan that it remembers

miner.LOST = "Strip Mine lost track of where it is."

local function stuck(message) error({ stuck = message }, 0) end

-- A new job, which starts by visiting the chest to unload and refuel.
function miner.newJob(config)
    return {
        config = config, status = "running", phase = "chest", reason = "start",
        step = 1, stage = "enter", pos = { x = 0, y = 0, z = 0, f = 0 }, path = {},
        stats = { blocks = 0, trips = 0, torches = 0, sealed = 0, items = {}, started = nil },
    }
end

--[[ io:
  turtle   the turtle API
  chest    returns the chest in front as an inventory peripheral, or nil if it can't be wrapped
  save     called with the job whenever it changes
  poll     returns the next command ("pause", "home" or "cancel"), or nil
  wait     waits a number of seconds ]]
function miner.new(job, io)
    local t = io.turtle
    local cfg = job.config
    local shape = plan.shape(cfg)
    local steps = plan.steps(cfg)
    local walkable = plan.walkable(cfg, steps)
    job.seen = job.seen or {}
    job.holes = job.holes or {}
    local junk = {}
    for _, name in ipairs(cfg.junkList) do junk[name] = true end
    local P = job.pos
    local travelling = false -- on the way to or from the chest, where a full inventory doesn't matter
    local self = { steps = steps, shape = shape }

    local function save() io.save(job) end

    local function fuel()
        local level = t.getFuelLevel()
        return level == "unlimited" and math.huge or level
    end

    -- Inventory --------------------------------------------------------------------------------

    local function detail(slot) return t.getItemCount(slot) > 0 and t.getItemDetail(slot) or nil end

    local function freeSlots()
        local free = 0
        for slot = 1, 16 do
            if t.getItemCount(slot) == 0 then free = free + 1 end
        end
        return free
    end

    local function findSlot(test)
        for slot = 1, 16 do
            local item = detail(slot)
            if item and test(item.name) then return slot end
        end
    end

    local function count(test)
        local n = 0
        for slot = 1, 16 do
            local item = detail(slot)
            if item and test(item.name) then n = n + item.count end
        end
        return n
    end

    local function isFuel(name) return plan.FUEL[name] ~= nil end
    local function isTorch(name) return name == plan.TORCH end
    local function isFiller(name) return plan.FILLER[name] == true end

    --[[ Throws away junk, keeping one stack of something to seal holes with, and as many of each
    item as the settings say to keep and take to the chest. `drop` is the turtle's drop function to
    use, so that it doesn't go into the chest. ]]
    local function dropJunk(drop)
        if not cfg.junk then return end
        local reserve
        if cfg.seal then
            local most = 0
            for slot = 1, 16 do
                local item = detail(slot)
                if item and junk[item.name] and isFiller(item.name) and item.count > most then
                    reserve, most = slot, item.count
                end
            end
        end
        local keep = {}
        for name, n in pairs(cfg.keep or {}) do keep[name] = n end
        for slot = 1, 16 do
            local item = detail(slot)
            if item and junk[item.name] and slot ~= reserve then
                local kept = math.min(item.count, keep[item.name] or 0)
                keep[item.name] = (keep[item.name] or 0) - kept
                if kept < item.count then
                    t.select(slot)
                    ;(drop or t.drop)(item.count - kept)
                end
            end
        end
        t.select(1)
    end

    -- Makes room before digging, or stops the step to go and unload.
    local function makeRoom()
        if travelling or freeSlots() > 0 then return end
        dropJunk()
        if freeSlots() == 0 then error({ trip = "full" }, 0) end
    end

    local function refuelTo(target)
        for slot = 1, 16 do
            local item = detail(slot)
            if fuel() >= target then break end
            if item and isFuel(item.name) then
                t.select(slot)
                while fuel() < target and t.getItemCount(slot) > 0 do
                    if not t.refuel(1) then break end
                end
            end
        end
        t.select(1)
    end

    -- Moving -----------------------------------------------------------------------------------

    local ACT = {
        fwd = { dig = "dig", move = "forward", inspect = "inspect", place = "place", attack = "attack" },
        up = { dig = "digUp", move = "up", inspect = "inspectUp", place = "placeUp", attack = "attackUp" },
        down = { dig = "digDown", move = "down", inspect = "inspectDown", place = "placeDown", attack = "attackDown" },
    }

    local function target(d)
        if d == "up" then return P.x, P.y + 1, P.z end
        if d == "down" then return P.x, P.y - 1, P.z end
        return P.x + DIRS[P.f][1], P.y, P.z + DIRS[P.f][2]
    end

    -- Remembers what's in the cell in direction d: a block's name, or false for nothing. A hole
    -- outside the plan is remembered for longer, since nothing else says it's there.
    local function note(d, name)
        local x, y, z = target(d)
        local k = plan.key(x, y, z)
        for i = #job.seen, 1, -1 do
            if job.seen[i][1] == k then table.remove(job.seen, i) break end
        end
        job.seen[#job.seen + 1] = { k, name }
        if #job.seen > REMEMBER then table.remove(job.seen, 1) end
        if plan.inside(shape, cfg, x, y, z) then return end
        for i = #job.holes, 1, -1 do
            if job.holes[i] == k then table.remove(job.holes, i) end
        end
        if name == false then
            job.holes[#job.holes + 1] = k
            if #job.holes > HOLES then table.remove(job.holes, 1) end
        end
    end

    local function look(d)
        local ok, block = t[ACT[d].inspect]()
        if ok then return block end
        return nil
    end

    local function inspect(d)
        local block = look(d)
        note(d, block and block.name or false)
        return block
    end

    local function turnTo(f)
        if P.f == f then return end
        while P.f ~= f do
            local right = (f - P.f) % 4 ~= 3
            local nf = (P.f + (right and 1 or 3)) % 4
            job.pending = { kind = "turn", f = nf }
            save()
            if right then t.turnRight() else t.turnLeft() end
            P.f = nf
        end
        job.pending = nil
        save()
    end

    -- Puts a block where a hole or a liquid is. Returns whether it did.
    local function seal(d)
        local slot = findSlot(function(name) return isFiller(name) end)
        if not slot then return false end
        local name = detail(slot).name
        t.select(slot)
        local ok = t[ACT[d].place]()
        t.select(1)
        if ok then
            job.stats.sealed = job.stats.sealed + 1
            note(d, name)
        end
        return ok
    end

    -- Empties the cell in direction d, digging again for anything that falls into it.
    local function clear(d)
        for _ = 1, RETRIES do
            local block = inspect(d)
            if not block then return end
            if plan.isLiquid(block) then
                -- Turtles go through liquids, but a block put there and dug out again takes a
                -- source block away, so it doesn't keep flowing into the tunnel.
                if cfg.seal and seal(d) then
                    t[ACT[d].dig]()
                end
                return
            end
            makeRoom()
            local ok, why = t[ACT[d].dig]()
            if ok then
                job.stats.blocks = job.stats.blocks + 1
                note(d, false)
            elseif inspect(d) then
                local x, y, z = target(d)
                if tostring(why):find("Unbreakable", 1, true) then
                    stuck(("There's an unbreakable block in the way at %d, %d, %d."):format(x, y, z))
                elseif tostring(why):find("tool", 1, true) then
                    stuck("The turtle can't dig. It needs a pickaxe.")
                end
                stuck(("The turtle can't dig at %d, %d, %d: %s."):format(x, y, z, tostring(why)))
            end
        end
        stuck("Something keeps falling in front of the turtle.")
    end

    local checkCommands -- below, since it starts trips

    local function move(d)
        local x, y, z = target(d)
        for attempt = 1, RETRIES do
            clear(d)
            if fuel() < 1 then refuelTo(plan.COAL) end
            local before = fuel()
            if before < 1 then stuck("The turtle ran out of fuel. Give it coal, then choose Resume.") end
            -- An unlimited level can't be saved as a number, and can't show whether it moved anyway.
            job.pending = { kind = "move", to = { x = x, y = y, z = z }, fuel = before ~= math.huge and before or nil }
            save()
            local ok = t[ACT[d].move]()
            if ok then
                P.x, P.y, P.z = x, y, z
                job.pending = nil
                if before == math.huge then save() end
                return
            end
            job.pending = nil
            -- A mob or a player, or gravel landing just after it was dug.
            t[ACT[d].attack]()
            if attempt > 2 then io.wait(0.5) end
        end
        stuck(("Something is blocking the way at %d, %d, %d."):format(x, y, z))
    end

    local function at(c) return P.x == c[1] and P.y == c[2] and P.z == c[3] end

    -- Moves into a cell next to this one.
    local function step(c)
        if at(c) then return end
        local dx, dy, dz = c[1] - P.x, c[2] - P.y, c[3] - P.z
        if math.abs(dx) + math.abs(dy) + math.abs(dz) ~= 1 then stuck(miner.LOST) end
        if dy == 1 then return move("up") end
        if dy == -1 then return move("down") end
        for f = 0, 3 do
            if DIRS[f][1] == dx and DIRS[f][2] == dz then turnTo(f) end
        end
        move("fwd")
    end

    -- Leaves the lane (or a cell off it) in direction d, leaving a trail back. A step into a vein
    -- notes the direction and facing, so the vein can be picked up again after a restart.
    local function push(d, vein)
        local x, y, z = target(d)
        job.path[#job.path + 1] = { P.x, P.y, P.z, vein = vein and d or nil, f = vein and P.f or nil }
        -- Saved before digging, so a vein's first cell isn't forgotten.
        if vein then save() end
        move(d)
        return x, y, z
    end

    -- Back along the trail. The cell is dropped from the trail only once it's reached, so that if
    -- the turtle stops on the way the trail still leads from where it is.
    local function unwind(depth)
        depth = depth or 0
        while #job.path > depth do
            step(job.path[#job.path])
            job.path[#job.path] = nil
        end
        save()
    end

    -- Walks to a cell in the lane, the way in or the start.
    local function goTo(c)
        local route = plan.route(walkable, { P.x, P.y, P.z }, c)
        if not route then stuck(miner.LOST) end
        for i = 2, #route do
            checkCommands()
            step(route[i])
        end
    end

    local function lane(i)
        if i < 1 then return { 0, 0, 0 } end
        return { steps[i].x, shape.travel, steps[i].z }
    end

    -- Where the turtle goes back to after the chest: the step it's on, or the one before if it
    -- hasn't walked into it yet.
    local function anchor()
        if job.stage == "enter" then return lane(job.step - 1) end
        return lane(job.step)
    end

    -- Looking around ---------------------------------------------------------------------------

    local veinCells

    local vein

    -- Looks all round a vein cell it came into in direction d, facing f.
    local function explore(d, f)
        local function try(dir)
            if #job.path >= VEIN_REACH or veinCells >= VEIN_CELLS then return end
            if plan.isOre(inspect(dir)) then vein(dir) end
        end
        try("up")
        try("down")
        -- Every side but the one it came in from, starting with the one it faces.
        local turns = { 0, 1, 3, 2 }
        if P.f ~= f then turns = { (P.f - f) % 4, 0, 1, 2, 3 } end
        local done = {}
        for _, turn in ipairs(turns) do
            if not done[turn] and (d ~= "fwd" or turn ~= 2) then
                done[turn] = true
                turnTo((f + turn) % 4)
                try("fwd")
            end
        end
    end

    vein = function(d)
        veinCells = veinCells + 1
        local depth = #job.path
        push(d, true)
        explore(d, P.f)
        unwind(depth)
    end

    -- After a restart in a vein: finish looking round each cell of it on the way back.
    local function resumeVein()
        veinCells = 0
        while #job.path > 0 and job.path[#job.path].vein do
            local top = job.path[#job.path]
            if at(top) then
                -- It stopped before stepping in.
                if top.vein == "fwd" then turnTo(top.f) end
                move(top.vein)
            end
            explore(top.vein, top.f)
            step(top)
            job.path[#job.path] = nil
        end
        save()
    end

    -- Looks at the cell in direction d, from inside the cross-section. `floor` is true below it.
    local function check(d, floor)
        local block = inspect(d)
        if block and cfg.vein and plan.isOre(block) then
            veinCells = 0
            vein(d)
            block = inspect(d)
        end
        if cfg.seal and ((block and plan.isLiquid(block)) or (floor and not block)) then
            seal(d)
        end
    end

    -- Clears the cross-section of step i from its lane cell, and looks at what's around it.
    local function slice(i)
        local s = steps[i]
        local looking = cfg.vein or cfg.seal
        local left, right = (s.dir + 3) % 4, (s.dir + 1) % 4
        for o = -shape.half, shape.half do
            local base = #job.path
            if o ~= 0 then
                turnTo(o < 0 and left or right)
                push("fwd")
            end
            local sides = {}
            if o <= 0 and o == -shape.half then sides[#sides + 1] = left end
            if o >= 0 and o == shape.half then sides[#sides + 1] = right end
            if looking then
                local function level(y)
                    -- Facing whichever side it already faces first saves a turn.
                    if #sides == 2 and P.f == sides[2] then sides[1], sides[2] = sides[2], sides[1] end
                    for _, f in ipairs(sides) do
                        turnTo(f)
                        check("fwd")
                    end
                    if y == 0 then check("down", true) end
                    if y == shape.height - 1 then check("up") end
                end
                local column = #job.path
                level(P.y)
                for _ = P.y - 1, 0, -1 do
                    push("down")
                    level(P.y)
                end
                unwind(column)
                for _ = P.y + 1, shape.height - 1 do
                    push("up")
                    level(P.y)
                end
                unwind(column)
            else
                if P.y < shape.height - 1 then clear("up") end
                if P.y > 0 then clear("down") end
            end
            unwind(base)
        end
    end

    local function torch(i)
        local s = steps[i]
        if not s.torch then return end
        local slot = findSlot(isTorch)
        if not slot then
            job.stats.noTorches = true
            return
        end
        if s.torch == true then
            local below = inspect("down")
            if below then return end
            t.select(slot)
            if t.placeDown() then
                job.stats.torches = job.stats.torches + 1
                note("down", false)
            end
        else
            turnTo(s.torch)
            local wall = inspect("fwd")
            if plan.isTorch(wall) then return end
            if wall and not plan.isLiquid(wall) then clear("fwd") end
            t.select(findSlot(isTorch) or slot)
            if t.place() then
                job.stats.torches = job.stats.torches + 1
                note("fwd", false)
            end
        end
        t.select(1)
    end

    -- Commands ---------------------------------------------------------------------------------

    checkCommands = function()
        while true do
            local op = io.poll()
            if not op then return end
            if op == "pause" then
                job.status = "paused"
                save()
                error({ halt = true }, 0)
            elseif op == "home" or op == "cancel" then
                if job.goal ~= "cancel" then job.goal = op end
                save()
                if job.phase == "out" or job.phase == "chest" then
                    if job.reason ~= "done" and job.reason ~= "cancel" then job.reason = job.goal end
                    save()
                else
                    error({ trip = job.goal }, 0)
                end
            end
        end
    end

    -- Finding its way after a restart ----------------------------------------------------------

    --[[ What's known to be in nearby cells: false for open, because the turtle has been through or
    dug them, or the name of a block it saw or put there. ]]
    local function known()
        local open = {}
        local function add(x, y, z) open[plan.key(x, y, z)] = false end
        local reached = job.stage == "slice" and job.step or job.step - 1
        for i = 1, math.min(reached, #steps) do
            add(steps[i].x, shape.travel, steps[i].z)
            if steps[i].slice and i < job.step then
                for _, c in ipairs(plan.section(shape, steps[i])) do add(c[1], c[2], c[3]) end
            end
        end
        if reached >= 1 then
            for _, c in ipairs(plan.entry(cfg)) do add(c[1], c[2], c[3]) end
        end
        add(0, 0, 0)
        for _, c in ipairs(job.path) do add(c[1], c[2], c[3]) end
        for _, k in ipairs(job.holes) do open[k] = false end
        for _, entry in ipairs(job.seen) do
            local name = entry[2]
            -- Liquids move, and so do blocks that fall.
            local moves = name and (name:find("water", 1, true) or name:find("lava", 1, true)
                or name == "minecraft:gravel" or name == "minecraft:sand")
            if moves then open[entry[1]] = nil else open[entry[1]] = name end
        end
        open[plan.key(0, 0, -1)] = job.chestName or true
        return open
    end

    local function rotate(options)
        local out = {}
        for _, o in ipairs(options) do out[#out + 1] = { x = o.x, y = o.y, z = o.z, f = (o.f + 1) % 4 } end
        return out
    end

    local function dedupe(options)
        local seen, out = {}, {}
        for _, o in ipairs(options) do
            local k = plan.key(o.x, o.y, o.z) .. "," .. o.f
            if not seen[k] then
                seen[k] = true
                out[#out + 1] = o
            end
        end
        return out
    end

    -- Keeps the options that fit what the turtle can see from here.
    local function fitting(options, knew)
        local seen = { fwd = look("fwd"), up = look("up"), down = look("down") }
        local kept = {}
        for _, o in ipairs(options) do
            local cells = {
                fwd = { o.x + DIRS[o.f][1], o.y, o.z + DIRS[o.f][2] },
                up = { o.x, o.y + 1, o.z }, down = { o.x, o.y - 1, o.z },
            }
            local fits = true
            for d, c in pairs(cells) do
                local was, now = knew[plan.key(c[1], c[2], c[3])], seen[d]
                if was == false then
                    if not plan.couldBeDug(now) then fits = false end
                elseif was == true then
                    -- The chest, before it's known what kind.
                    if not plan.isContainer(now) then fits = false end
                elseif was then
                    if not now or now.name ~= was then fits = false end
                elseif plan.isContainer(now) then
                    -- The chest is the only container it knows of.
                    fits = false
                end
            end
            if fits then kept[#kept + 1] = o end
        end
        return kept
    end

    local function shift(options, dy)
        for _, o in ipairs(options) do o.y = o.y + dy end
        P.y = P.y + dy
        local top = job.path[#job.path]
        if top and at(top) then job.path[#job.path] = nil end
    end

    --[[ Works out which of job.unsure.options is right, by looking around and turning right to look
    further. Every wall of a shaft can look the same, so when the options are all in one place
    and the trail leads straight up or down, it goes that way first, since that doesn't depend on
    which way it faces. ]]
    local function resolve()
        local u = job.unsure
        local options = u.options
        if u.turning then
            for _, o in ipairs(rotate(options)) do options[#options + 1] = o end
        end
        if u.moving and fuel() < u.moving.fuel then shift(options, u.moving.dy) end
        options = dedupe(options)
        local knew = known()
        local turns = 0
        while true do
            options = fitting(options, knew)
            if #options <= 1 then break end
            local o, top = options[1], job.path[#job.path]
            local together = true
            for _, other in ipairs(options) do
                if other.x ~= o.x or other.y ~= o.y or other.z ~= o.z then together = false end
            end
            if together and top and top[1] == o.x and top[3] == o.z and math.abs(top[2] - o.y) == 1
                and fuel() ~= math.huge then
                local dy = top[2] - o.y
                job.unsure = { options = options, moving = { dy = dy, fuel = fuel() } }
                save()
                local moved
                if dy > 0 then moved = t.up() else moved = t.down() end
                if not moved then break end
                shift(options, dy)
                job.unsure = { options = options }
                save()
                turns = 0
            elseif turns < 3 then
                job.unsure = { options = options, turning = true }
                save()
                t.turnRight()
                options = rotate(options)
                job.unsure = { options = options }
                save()
                turns = turns + 1
            else
                break
            end
        end
        if #options ~= 1 then
            job.unsure = nil
            job.lost = true
            save()
            stuck(miner.LOST)
        end
        local o = options[1]
        P.x, P.y, P.z, P.f = o.x, o.y, o.z, o.f
        job.unsure = nil
        save()
    end

    local function recover()
        local p = job.pending
        if p then
            job.pending = nil
            if p.kind == "move" then
                local level = t.getFuelLevel()
                if level ~= "unlimited" and p.fuel then
                    if level < p.fuel then P.x, P.y, P.z = p.to.x, p.to.y, p.to.z end
                else
                    job.unsure = { options = {
                        { x = P.x, y = P.y, z = P.z, f = P.f }, { x = p.to.x, y = p.to.y, z = p.to.z, f = P.f },
                    } }
                end
            elseif p.kind == "turn" then
                job.unsure = { options = { { x = P.x, y = P.y, z = P.z, f = P.f }, { x = P.x, y = P.y, z = P.z, f = p.f } } }
            end
            save()
        end
        if job.unsure then resolve() end
    end

    -- The chest --------------------------------------------------------------------------------

    -- Moves an item the turtle wants to the chest's first slot, which is where suck takes from.
    local function toFront(chest, test)
        local ok, list = pcall(chest.list)
        if not ok or type(list) ~= "table" then return nil end
        local from
        for slot, item in pairs(list) do
            if test(item.name) and (not from or slot < from) then from = slot end
        end
        if not from then return false end
        if from == 1 then return true end
        local name = io.chestName or "front"
        if list[1] then
            local size = chest.size()
            local empty
            for slot = 2, size do
                if not list[slot] then empty = slot break end
            end
            if not empty then return nil end
            if not pcall(chest.pushItems, name, 1, nil, empty) then return nil end
        end
        local moved = pcall(chest.pushItems, name, from, nil, 1)
        return moved or nil
    end

    local function emptySlot()
        for slot = 1, 16 do
            if t.getItemCount(slot) == 0 then return slot end
        end
    end

    -- With no way to sort the chest: take whatever comes, and put back what isn't wanted.
    local function takeUnsorted(test, limit)
        local took, back = 0, {}
        while took < limit do
            local slot = emptySlot()
            if not slot then break end
            t.select(slot)
            if not t.suck() then break end
            local item = detail(slot)
            if item and test(item.name) then took = took + item.count else back[#back + 1] = slot end
        end
        for _, slot in ipairs(back) do
            t.select(slot)
            t.drop()
        end
        t.select(1)
        return took
    end

    -- Takes up to `limit` of an item from the chest. Returns how many it took.
    local function take(test, limit)
        local took = 0
        local chest = io.chest()
        while took < limit do
            local slot = emptySlot()
            if not slot then break end
            local ready = chest and toFront(chest, test)
            if ready == false then break end
            if ready == nil then return took + takeUnsorted(test, limit - took) end
            t.select(slot)
            if not t.suck(math.min(64, limit - took)) then break end
            local item = detail(slot)
            if not item or not test(item.name) then
                t.drop()
                break
            end
            took = took + item.count
        end
        t.select(1)
        return took
    end

    local function unload()
        dropJunk(t.dropUp)
        local fuelKept, torchesKept, fillerKept = 0, 0, false
        for slot = 1, 16 do
            local item = detail(slot)
            if item then
                local keep = false
                if isFuel(item.name) and fuelKept < KEEP_FUEL then
                    keep, fuelKept = true, fuelKept + item.count
                elseif isTorch(item.name) and cfg.torches > 0 and torchesKept < KEEP_TORCHES then
                    keep, torchesKept = true, torchesKept + item.count
                elseif isFiller(item.name) and cfg.seal and not fillerKept then
                    keep, fillerKept = true, true
                end
                if not keep then
                    t.select(slot)
                    if not t.drop() then
                        t.select(1)
                        stuck("The chest is full. Empty it, then choose Resume.")
                    end
                    local left = t.getItemCount(slot)
                    if job.reason ~= "start" then
                        job.stats.items[item.name] = (job.stats.items[item.name] or 0) + item.count - left
                        save()
                    end
                end
            end
        end
        t.select(1)
    end

    local function atChest()
        turnTo(2)
        local front = inspect("fwd")
        if not front then
            stuck("There's no chest behind the start. Put one there, then choose Resume.")
        end
        job.chestName = front.name
        unload()

        local left = plan.estimate(cfg, steps, job.step).fuel + MARGIN
        local limit = t.getFuelLimit()
        local wanted = math.min(limit == "unlimited" and math.huge or limit, left)
        if fuel() < wanted then
            refuelTo(wanted)
            while fuel() < wanted do
                if take(isFuel, 64) == 0 then break end
                refuelTo(wanted)
            end
        end
        if cfg.torches > 0 then
            local have = count(isTorch)
            if have < KEEP_TORCHES then take(isTorch, KEEP_TORCHES - have) end
            if count(isTorch) > 0 then job.stats.noTorches = nil end
        end
        -- Enough to reach the next step and get back, at least.
        local i = math.min(job.step, #steps)
        local needed = 2 * plan.homeBound(shape, steps[i].x, steps[i].z) + VEIN_REACH * 2 + MARGIN
        if job.reason ~= "done" and job.reason ~= "cancel" and fuel() < math.min(needed, wanted) then
            stuck(("Needs fuel: put coal or charcoal in the chest, then choose Resume. It has %d " ..
                "and needs at least %d."):format(fuel(), needed))
        end
        job.stats.trips = job.stats.trips + (job.reason == "start" and 0 or 1)
    end

    -- Phases -----------------------------------------------------------------------------------

    local function startTrip(reason)
        job.phase, job.reason = "out", reason
        save()
    end

    local function work()
        while true do
            checkCommands()
            local i = job.step
            if i > #steps then return startTrip("done") end
            if job.stage == "enter" then
                unwind()
                local s = steps[i]
                local need = plan.homeBound(shape, s.x, s.z) + plan.sliceMoves(cfg, shape) + VEIN_REACH * 2 + MARGIN
                if fuel() < need then refuelTo(need + 10 * plan.COAL) end
                if fuel() < need then return startTrip("fuel") end
                if freeSlots() == 0 then dropJunk() end
                if freeSlots() == 0 then return startTrip("full") end
                goTo(lane(i))
                job.stage = "slice"
                save()
            end
            if cfg.vein then resumeVein() end
            unwind()
            if steps[i].slice then
                slice(i)
                torch(i)
            end
            job.step, job.stage = i + 1, "enter"
            save()
        end
    end

    local function out()
        unwind()
        travelling = true
        goTo({ 0, 0, 0 })
        travelling = false
        job.phase = "chest"
        save()
    end

    local function chest()
        atChest()
        local reason = job.reason
        if reason == "home" then
            job.goal, job.reason, job.status = nil, "paused", "paused"
        elseif reason == "cancel" or reason == "done" then
            turnTo(0)
            job.goal = nil
            job.status = reason == "done" and "finished" or "cancelled"
            job.stats.finished = io.now and io.now() or nil
        else
            job.phase = "back"
        end
        save()
    end

    local function back()
        travelling = true
        goTo(anchor())
        travelling = false
        job.phase = "work"
        save()
    end

    local PHASES = { work = work, out = out, chest = chest, back = back }

    -- Runs until the job stops for any reason, with its status saying why.
    function self.run()
        local ok, err = pcall(function()
            recover()
            job.lost = nil
            while job.status == "running" do
                local ok2, err2 = pcall(PHASES[job.phase])
                travelling = false
                if not ok2 then
                    if type(err2) == "table" and err2.trip then
                        unwind()
                        startTrip(err2.trip)
                    else
                        error(err2, 0)
                    end
                end
            end
        end)
        t.select(1)
        if not ok then
            if type(err) == "table" and err.halt then
                -- Paused, and already saved.
            elseif type(err) == "table" and err.stuck then
                job.status, job.message = "stuck", err.stuck
            else
                job.status, job.message = "stuck", "Something went wrong: " .. tostring(err)
            end
            save()
        end
        return job
    end

    -- After the turtle has been picked up and put back at the start by hand.
    function self.putBack()
        P.x, P.y, P.z, P.f = 0, 0, 0, 0
        job.path, job.pending, job.unsure, job.lost = {}, nil, nil, nil
        if job.phase ~= "chest" then job.phase = job.phase == "out" and "chest" or "back" end
        save()
    end

    -- How far through the plan it is, as a fraction.
    function self.progress()
        return math.min(1, (job.step - 1) / #steps)
    end

    return self
end

return miner
