--[[ Keeps auto chests stocked, whether or not anyone is logged in. Every few seconds it looks at
each one: anything it has more of than its target, or that has no target, goes into storage, and
anything it has less of is brought out of storage. It looks straight away when the app changes an
auto chest. ]]

local app = ...
local array = require("array")
local system = require("system")

local EVERY = 5 -- seconds between looks

-- Waits for the next look, which the app can bring forward.
local function nap()
    local timer = os.startTimer(EVERY)
    repeat
        local event, id = os.pullEventRaw()
    until (event == "timer" and id == timer) or event == array.WAKE
end

local reported = {} -- the last problem with each chest, so the log isn't filled with the same one

local function report(name, problem)
    if reported[name] ~= problem and problem then system.log(app.id .. ": " .. name .. ": " .. problem) end
    reported[name] = problem
end

while true do
    local config = array.load()
    for name, auto in pairs(config and config.auto or {}) do
        local ok, result = pcall(array.balance, config, name, auto.targets)
        if not ok then
            report(name, tostring(result))
        elseif not result then
            report(name, "the chest isn't connected")
        else
            report(name, result.indexError and "the item index wasn't saved: " .. result.indexError or nil)
        end
    end
    nap()
end
