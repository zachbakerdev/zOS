-- Background services. Each one is a coroutine that runs alongside the session,
-- even while nobody is logged in. A service that crashes is logged and stopped
-- without affecting the session or other services.

local system = require("system")

local services = {}

local WAKE = "zos_services" -- queued so run() notices a newly started service
local running = {} -- id -> { co, args, filter, started, seq }
local seq = 0
local screen -- services draw to a hidden window, never over the session

function services.start(id, fn, ...)
    seq = seq + 1
    running[id] = { co = coroutine.create(fn), args = table.pack(...), seq = seq }
    os.queueEvent(WAKE)
end

function services.stop(id)
    running[id] = nil
end

function services.isRunning(id)
    return running[id] ~= nil
end

local function resume(id, task, ...)
    local previous = term.redirect(screen)
    local ok, filter = coroutine.resume(task.co, ...)
    term.redirect(previous)
    if running[id] ~= task then return end -- stopped or replaced while it ran
    if not ok then
        running[id] = nil
        system.log("service '" .. id .. "' crashed: " .. tostring(filter))
    elseif coroutine.status(task.co) == "dead" then
        running[id] = nil
    else
        task.filter = filter
    end
end

-- Runs every service, forever. Started by boot.lua alongside the session.
function services.run()
    local w, h = term.native().getSize()
    screen = window.create(term.native(), 1, 1, w, h, false)
    while true do
        local event = table.pack(os.pullEventRaw())
        local ids = {}
        for id in pairs(running) do ids[#ids + 1] = id end
        table.sort(ids, function(a, b) return running[a].seq < running[b].seq end)
        for _, id in ipairs(ids) do
            local task = running[id]
            if task and not task.started then
                task.started = true
                resume(id, task, table.unpack(task.args, 1, task.args.n))
            elseif task and (task.filter == nil or task.filter == event[1] or event[1] == "terminate") then
                resume(id, task, table.unpack(event, 1, event.n))
            end
        end
    end
end

return services
