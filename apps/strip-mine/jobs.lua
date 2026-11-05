--[[ Strip Mine's saved job, the computers allowed to control it, and the words for what it's doing.
The app and the service each load their own copy of this module, so everything between them goes
through files in /etc/strip-mine/ and events. Nothing yields between reading a file and writing it
back, so they can't overwrite each other's changes.

The service owns the job file while the job is running. The app only writes it to start a new
job, and asks the service for everything else with jobs.command. ]]

local plan = require("plan")
local util = require("util")

local jobs = {}

jobs.DIR = "/etc/strip-mine"
local JOB = fs.combine(jobs.DIR, "job")
local REMOTES = fs.combine(jobs.DIR, "remotes")
local REQUESTS = fs.combine(jobs.DIR, "requests")

jobs.PORT = 4204
jobs.COMMAND = "strip_mine_command" -- queued by the app, with the command
jobs.WAKE = "strip_mine_wake"       -- queued by the service, when there's a job to run

-- Commands the turtle's own screen and allowed computers can give.
jobs.COMMANDS = { pause = true, home = true, resume = true, cancel = true }

local MAX_REQUESTS = 8

-- A job that isn't over, so a new one can't be started.
function jobs.isActive(job)
    return job ~= nil and (job.status == "running" or job.status == "paused" or job.status == "stuck")
end

function jobs.load()
    local job = util.readTable(JOB)
    if type(job) ~= "table" or type(job.config) ~= "table" then return nil end
    return job
end

function jobs.save(job)
    local ok, err = util.writeTable(JOB, job)
    if not ok then error("Couldn't save the job: " .. tostring(err), 0) end
end

function jobs.clear() fs.delete(JOB) end

function jobs.command(op) os.queueEvent(jobs.COMMAND, op) end

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
function jobs.summary(job, fuel)
    if not job then return { status = "idle", fuel = fuel } end
    local steps = plan.steps(job.config)
    local step = math.min(job.step or 1, #steps)
    local shape = plan.shape(job.config)
    return {
        status = job.status, phase = job.phase, reason = job.reason, goal = job.goal,
        message = job.message, lost = job.lost,
        step = job.step, steps = #steps, tunnel = steps[step] and steps[step].tunnel,
        tunnels = #shape.xs, pos = job.pos,
        percent = math.floor(math.min(1, ((job.step or 1) - 1) / #steps) * 100),
        stats = job.stats, fuel = fuel,
        config = {
            length = job.config.length, count = job.config.count, spacing = job.config.spacing,
            size = job.config.size, side = job.config.side, connect = job.config.connect,
        },
    }
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
    if s.tunnel then return ("Mining tunnel %d of %d"):format(s.tunnel, s.tunnels), nil end
    return "Mining the corridor", nil
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
