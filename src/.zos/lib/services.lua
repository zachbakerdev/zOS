-- Background services: coroutines that run alongside the session, even with nobody logged in.

local system = require("system")

local services = {}

local running, order = {}, {}
local WAKE = "zos:service"

local function forget(id)
    running[id] = nil
    for i, other in ipairs(order) do
        if other == id then
            table.remove(order, i)
            break
        end
    end
end

-- Start fn under id, with the given arguments, replacing any service with that id.
function services.start(id, fn, ...)
    services.stop(id)
    running[id] = { co = coroutine.create(fn), args = table.pack(...), started = false }
    order[#order + 1] = id
    os.queueEvent(WAKE)
end

function services.stop(id)
    if running[id] then forget(id) end
end

function services.isRunning(id)
    return running[id] ~= nil
end

function services.list()
    local out = {}
    for i, id in ipairs(order) do out[i] = id end
    return out
end

-- Runs every service. Anything they draw goes to a hidden window. They never see Ctrl+T.
function services.run()
    local width, height = term.getSize()
    local hidden = window.create(term.current(), 1, 1, width, height, false)

    local function resume(id, entry, ...)
        local previous = term.redirect(hidden)
        local ok, filter = coroutine.resume(entry.co, ...)
        term.redirect(previous)
        if not ok then
            system.log("Service " .. id .. " crashed: " .. tostring(filter))
            if running[id] == entry then forget(id) end
        elseif coroutine.status(entry.co) == "dead" then
            if running[id] == entry then forget(id) end
        else
            entry.filter = filter
        end
    end

    local event = table.pack(WAKE)
    while true do
        -- A service can start or stop others, so go through a copy.
        for _, id in ipairs(services.list()) do
            local entry = running[id]
            if entry and not entry.started then
                entry.started = true
                resume(id, entry, table.unpack(entry.args, 1, entry.args.n))
            elseif entry and event[1] ~= "terminate" and (entry.filter == nil or entry.filter == event[1]) then
                resume(id, entry, table.unpack(event, 1, event.n))
            end
        end
        event = table.pack(os.pullEventRaw())
    end
end

return services
