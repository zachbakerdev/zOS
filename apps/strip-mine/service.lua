--[[ Runs the strip mine on a turtle, whether or not anyone is logged in, so a job carries on by
itself after the turtle is unloaded. It also answers computers in range: anyone can see what it's
doing, and the computers someone at the turtle has allowed can pause it, bring it home, resume it
or cancel it. Computers and pocket computers have nothing to run, since they only watch. ]]

local app = ...
if not turtle then return end

local jobs = require("jobs")
local miner = require("miner")
local net = require("net")
local system = require("system")
local util = require("util")

local queue = {}     -- commands for the running job
local running = false

local function chest()
    local ok, wrapped = pcall(peripheral.wrap, "front")
    if ok and wrapped and wrapped.list and wrapped.pushItems and wrapped.size then return wrapped end
end

local io = {
    turtle = turtle,
    chest = chest,
    chestName = "front",
    save = jobs.save,
    poll = function() return table.remove(queue, 1) end,
    wait = util.wait,
    now = function() return os.epoch("utc") end,
}

local function mining()
    while true do
        local job = jobs.load()
        if job and job.status == "running" then
            running = true
            local ok, err = pcall(function() miner.new(job, io).run() end)
            running, queue = false, {}
            if not ok then
                system.log(app.id .. ": " .. tostring(err))
                -- Couldn't even save: wait to be asked again rather than trying over and over.
                os.pullEventRaw(jobs.WAKE)
            end
        else
            os.pullEventRaw(jobs.WAKE)
        end
    end
end

-- Does what the app or an allowed computer asked. Returns true, or false and why not.
local function command(op)
    if running then
        if op == "pause" or op == "home" or op == "cancel" then
            queue[#queue + 1] = op
            return true
        end
        if op == "start" or op == "resume" then return true end
        return false, "It's busy mining."
    end
    local job = jobs.load()
    if op == "start" then
        os.queueEvent(jobs.WAKE)
        return true
    end
    if not jobs.isActive(job) then return false, "There's no mine to change." end
    if op == "pause" then return true end
    if op == "putback" then
        miner.new(job, io).putBack()
        job.status, job.message = "running", nil
    elseif job.lost then
        -- It doesn't know where it is, so it can't walk anywhere.
        if op ~= "cancel" then return false, "It has to be put back at the start first." end
        job.status, job.message, job.lost = "cancelled", nil, nil
    elseif op == "resume" then
        job.status, job.message = "running", nil
    elseif op == "home" or op == "cancel" then
        if job.phase == "chest" and op == "cancel" then
            job.status = "cancelled"
        elseif not (job.phase == "chest" and job.status == "paused") then
            job.status, job.message = "running", nil
            queue = { op }
        end
    else
        return false, "Unknown command."
    end
    jobs.save(job)
    os.queueEvent(jobs.WAKE)
    return true
end

local function local_()
    while true do
        local _, op = os.pullEventRaw(jobs.COMMAND)
        if type(op) == "string" then
            local ok, err = pcall(command, op)
            if not ok then system.log(app.id .. ": " .. tostring(err)) end
        end
    end
end

local function fuelLevel()
    local level = turtle.getFuelLevel()
    return level == "unlimited" and "unlimited" or level
end

local function name()
    return os.getComputerLabel() or ("Turtle " .. os.getComputerID())
end

local function handle(msg)
    local p = msg.payload
    if type(p) ~= "table" or type(p.op) ~= "string" then return { error = "Bad request" } end
    local key = msg.peer and msg.peer.key
    local allowed = type(key) == "string" and jobs.isAllowed(key)
    if p.op == "status" then
        return { name = name(), allowed = allowed, job = jobs.summary(jobs.load(), fuelLevel()) }
    elseif p.op == "pair" then
        if allowed then return { allowed = true } end
        jobs.addRequest({
            key = key, fingerprint = msg.peer.fingerprint, id = msg.from,
            name = type(p.name) == "string" and p.name:sub(1, 32) or nil, asked = os.epoch("utc"),
        })
        return { pending = true }
    elseif p.op == "command" then
        if not allowed then return { error = "This computer isn't allowed to control " .. name() .. ".", denied = true } end
        if type(p.command) ~= "string" or not jobs.COMMANDS[p.command] then return { error = "Unknown command." } end
        local ok, err = command(p.command)
        return { ok = ok, error = err }
    end
    return { error = "Unknown request" }
end

local function requests()
    net.listen(jobs.PORT)
    while true do
        local msg = net.receive(jobs.PORT)
        if msg then
            local ok, reply = pcall(handle, msg)
            if not ok then
                system.log(app.id .. ": " .. tostring(reply))
                reply = { error = "Something went wrong" }
            end
            net.reply(msg, reply)
        end
    end
end

-- Lets computers in range find this turtle. Anyone can answer a probe, so they treat this as a claim.
local function announcing()
    while true do
        local _, probe = os.pullEventRaw(net.PROBE_EVENT)
        if type(probe) == "table" and probe.port == jobs.PORT then
            local text = jobs.describe(jobs.summary(jobs.load()))
            net.answerProbe(probe, { name = name(), status = text })
        end
    end
end

parallel.waitForAll(mining, local_, requests, announcing)
