--[[ Strip Mine's saved job, the mine's record, the computers allowed to control it, and the words
for what it's doing.
The app and the service each load their own copy of this module, so everything between them goes
through files in /etc/strip-mine/ and events. Nothing yields between reading a file and writing it
back, so they can't overwrite each other's changes.

The service owns the job file while the job is running. The app only writes it to start a new
job, and asks the service for everything else with jobs.command.

The mine's record (see plan.newRecord) is what every job so far has dug, so the next job carries on
from it. A job is added to it once it's over, by jobs.settle. The record also keeps the settings
the last job was started with, so a remote computer can ask for more branches, and totals for the
whole mine. ]]

local miner = require("miner")
local plan = require("plan")
local util = require("util")

local jobs = {}

jobs.DIR = "/etc/strip-mine"
local JOB = fs.combine(jobs.DIR, "job")
local REMOTES = fs.combine(jobs.DIR, "remotes")
local REQUESTS = fs.combine(jobs.DIR, "requests")
local MINE = fs.combine(jobs.DIR, "mine")

jobs.PORT = 4204
jobs.COMMAND = "strip_mine_command" -- queued by the app, with the command
jobs.WAKE = "strip_mine_wake"       -- queued by the service, when there's a job to run

-- Commands the turtle's own screen and allowed computers can give. "more" starts a job digging
-- more branches, with the settings of the last one.
jobs.COMMANDS = { pause = true, home = true, resume = true, cancel = true, more = true }

local MAX_REQUESTS = 8

-- A job that isn't over, so a new one can't be started.
function jobs.isActive(job)
    return job ~= nil and (job.status == "running" or job.status == "paused" or job.status == "stuck")
end

-- The saved job, or nil if there's none, or it was saved by an older version that laid mines out
-- differently.
function jobs.load()
    local job = util.readTable(JOB)
    if type(job) ~= "table" or type(job.config) ~= "table" or job.config.version ~= plan.VERSION then return nil end
    return job
end

function jobs.save(job)
    local ok, err = util.writeTable(JOB, job)
    if not ok then error("Couldn't save the job: " .. tostring(err), 0) end
end

function jobs.clear() fs.delete(JOB) end

function jobs.command(op, arg) os.queueEvent(jobs.COMMAND, op, arg) end

-- The mine ---------------------------------------------------------------------------------------

local function newTotals() return { jobs = 0, blocks = 0, trips = 0, torches = 0, sealed = 0, items = {} } end

--[[ The record of the mine dug from this spot, or nil if there isn't one. Beyond plan.newRecord's
fields it has id, settings (the last job's), totals, and settled (the id of the last job added). ]]
function jobs.mine()
    local mine = util.readTable(MINE)
    if type(mine) ~= "table" or type(mine.layout) ~= "table" or type(mine.branches) ~= "table" then return nil end
    return mine
end

local function saveMine(mine)
    local ok, err = util.writeTable(MINE, mine)
    if not ok then error("Couldn't save the mine: " .. tostring(err), 0) end
end

-- Starts afresh: the next job digs a new mine, with any layout.
function jobs.forgetMine() fs.delete(MINE) end

-- Whether a job belongs to the mine and hasn't been added to its record yet.
local function unsettled(job, mine)
    return job ~= nil and mine ~= nil and job.config.mine == mine.id and mine.settled ~= job.id
end

-- Adds the last job to the mine's record, once it's over. Safe to call any time.
function jobs.settle()
    local job, mine = jobs.load(), jobs.mine()
    if jobs.isActive(job) or not unsettled(job, mine) then return end
    local steps = plan.steps(job.config)
    plan.record(mine, job.config, steps, job.status == "finished" and #steps + 1 or job.step)
    local t, stats = mine.totals or newTotals(), job.stats or {}
    t.jobs = t.jobs + 1
    for _, k in ipairs({ "blocks", "trips", "torches", "sealed" }) do t[k] = t[k] + (stats[k] or 0) end
    for name, n in pairs(stats.items or {}) do t.items[name] = (t.items[name] or 0) + n end
    mine.totals, mine.settled = t, job.id
    saveMine(mine)
end

--[[ A new job from the settings the person chose, carrying on the mine there is, or starting one.
It isn't saved. Returns nil and why if there's nothing for it to dig. ]]
function jobs.newJob(settings)
    jobs.settle()
    local mine = jobs.mine()
    local config = plan.assign(settings, mine)
    if #config.work == 0 then
        if config.count > 0 then return nil, "There's no room for more branches along this corridor." end
        return nil, "There's nothing to dig: choose how many branches."
    end
    if not mine then
        mine = plan.newRecord(config)
        mine.id, mine.totals = os.epoch("utc"), newTotals()
    end
    mine.settings = settings
    saveMine(mine)
    config.mine = mine.id
    local job = miner.newJob(config, os.epoch("utc"))
    job.stats.started = os.epoch("utc")
    return job
end

-- The mine's record with a job's progress added, before it's settled.
local function current(job, mine)
    if not mine then return nil end
    if not unsettled(job, mine) then return mine end
    local copy = textutils.unserialize(textutils.serialize(mine))
    local steps = plan.steps(job.config)
    plan.record(copy, job.config, steps, job.status == "finished" and #steps + 1 or job.step)
    return copy
end

--[[ What the map shows, small enough to send to a remote:
  side, pitch, half   the layout, and how far the corridor reaches either side of its lane
  corridor            the z it's dug to
  slots               a list, from slot 1, of { left dug, right dug, left planned, right planned }
  pos                 where the turtle is, while a job is going ]]
function jobs.mapData(job, mine)
    mine = mine or jobs.mine()
    local now = current(job, mine)
    if not now then return nil end
    local planned = {}
    if jobs.isActive(job) and job.config.mine == mine.id then
        for _, w in ipairs(job.config.work) do
            planned[w.slot] = planned[w.slot] or {}
            planned[w.slot][w.side] = w.to
        end
    end
    local slots, last = {}, 0
    for k = 1, plan.MAX_SLOTS do
        local b, p = now.branches[k] or {}, planned[k] or {}
        local function dug(side) return b[side] and b[side].dug or 0 end
        local function want(side) return math.max(b[side] and b[side].want or 0, p[side] or 0) end
        slots[k] = { dug("l"), dug("r"), want("l"), want("r") }
        if slots[k][3] > 0 or slots[k][4] > 0 then last = k end
    end
    for k = last + 1, plan.MAX_SLOTS do slots[k] = nil end
    local C = plan.size(now.layout.corridor)
    return {
        side = now.layout.side, pitch = now.layout.spacing + plan.size(now.layout.branch).width,
        half = (C.width - 1) / 2, corridor = now.corridor, slots = slots,
        pos = jobs.isActive(job) and job.pos or nil,
    }
end

-- Totals for the whole mine, with the job going now added in.
function jobs.totals(job, mine)
    mine = mine or jobs.mine()
    if not mine then return nil end
    local t = textutils.unserialize(textutils.serialize(mine.totals or newTotals()))
    if unsettled(job, mine) then
        local stats = job.stats or {}
        t.jobs = t.jobs + 1
        for _, k in ipairs({ "blocks", "trips", "torches", "sealed" }) do t[k] = t[k] + (stats[k] or 0) end
        for name, n in pairs(stats.items or {}) do t.items[name] = (t.items[name] or 0) + n end
    end
    local now = current(job, mine)
    local branches, length = 0, 0
    for _, slot in pairs(now.branches) do
        for _, b in pairs(slot) do
            branches, length = branches + 1, length + b.dug
        end
    end
    t.branches, t.length, t.corridor = branches, length, math.max(0, now.corridor + 1)
    return t
end

-- Computers that may control the turtle --------------------------------------------------------

--[[ Each entry is { key, fingerprint, id, name, added }. A remote is allowed by its key, so a
computer that takes another's id can't use its place. ]]
function jobs.remotes() return util.readTable(REMOTES) or {} end

function jobs.isAllowed(key)
    for _, remote in ipairs(jobs.remotes()) do
        if remote.key == key then return true end
    end
    return false
end

function jobs.forget(key)
    local kept = {}
    for _, remote in ipairs(jobs.remotes()) do
        if remote.key ~= key then kept[#kept + 1] = remote end
    end
    util.writeTable(REMOTES, kept)
end

-- Computers that asked to be allowed, waiting for someone at the turtle to say yes.
function jobs.requests() return util.readTable(REQUESTS) or {} end

function jobs.dropRequest(key)
    local kept = {}
    for _, request in ipairs(jobs.requests()) do
        if request.key ~= key then kept[#kept + 1] = request end
    end
    util.writeTable(REQUESTS, kept)
end

function jobs.addRequest(request)
    jobs.dropRequest(request.key)
    local list = jobs.requests()
    table.insert(list, 1, request)
    while #list > MAX_REQUESTS do list[#list] = nil end
    util.writeTable(REQUESTS, list)
end

function jobs.allow(request)
    jobs.dropRequest(request.key)
    jobs.forget(request.key)
    local list = jobs.remotes()
    list[#list + 1] = {
        key = request.key, fingerprint = request.fingerprint, id = request.id, name = request.name,
        added = os.epoch("utc"),
    }
    util.writeTable(REMOTES, list)
end

-- Words ------------------------------------------------------------------------------------------

--[[ What a remote is told, and what the screens show: everything about the job that a person
might want, without the parts only the miner needs. ]]
-- The steps of the job last asked about, since working them out every second adds up.
local cached = {}
local function stepsOf(job)
    if cached.id ~= job.id then cached = { id = job.id, steps = plan.steps(job.config) } end
    return cached.steps
end

function jobs.summary(job, fuel)
    local mine = jobs.mine()
    local base = {
        fuel = fuel, map = jobs.mapData(job, mine), totals = jobs.totals(job, mine),
        canMore = mine ~= nil and type(mine.settings) == "table" and not jobs.isActive(job),
    }
    if not job then
        base.status = "idle"
        return base
    end
    local steps = stepsOf(job)
    local step = math.min(job.step or 1, #steps)
    local here = steps[step] or {}
    base.status, base.phase, base.reason, base.goal = job.status, job.phase, job.reason, job.goal
    base.message, base.lost, base.pos, base.stats = job.message, job.lost, job.pos, job.stats
    base.step, base.steps = job.step, #steps
    base.tunnel, base.tunnels, base.walking = here.tunnel, #job.config.work, not here.slice
    base.percent = math.floor(math.min(1, ((job.step or 1) - 1) / #steps) * 100)
    base.config = {
        length = job.config.length, count = job.config.count, spacing = job.config.spacing,
        corridor = job.config.corridor, branch = job.config.branch, side = job.config.side,
        branches = #job.config.work,
    }
    return base
end

local TRIPS = {
    start = "Getting fuel from the chest",
    full = "Going to unload: inventory full",
    fuel = "Going to refuel",
    home = "Going back to the chest",
    cancel = "Going back to cancel",
    done = "Done, going back to the chest",
}

-- One line saying what the turtle is doing, and the theme colour name to show it in.
function jobs.describe(s)
    if not s or s.status == "idle" then return "No mine started", "dim" end
    if s.status == "finished" then return "Finished", "good" end
    if s.status == "cancelled" then return "Cancelled", "dim" end
    if s.status == "stuck" then return s.lost and "Lost: needs putting back" or "Stopped: needs help", "bad" end
    if s.status == "paused" then
        return s.phase == "chest" and "Paused at the chest" or "Paused in the mine", "accent"
    end
    if s.phase == "out" then return TRIPS[s.reason] or "Going to the chest", nil end
    if s.phase == "chest" then return s.reason == "start" and TRIPS.start or "At the chest", nil end
    if s.phase == "back" then return "Going back to the mine", nil end
    if s.tunnel then
        return ("%s branch %d of %d"):format(s.walking and "Walking" or "Mining", s.tunnel, s.tunnels), nil
    end
    return s.walking and "Walking the corridor" or "Mining the corridor", nil
end

-- The best finds, as text such as "diamond 4, raw_iron 31".
function jobs.finds(stats, limit)
    local list = {}
    for name, count in pairs(stats and stats.items or {}) do
        list[#list + 1] = { name = name:gsub("^minecraft:", ""), count = count }
    end
    table.sort(list, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)
    local out = {}
    for i = 1, math.min(limit or #list, #list) do out[i] = list[i].name .. " " .. list[i].count end
    return table.concat(out, ", ")
end

return jobs
