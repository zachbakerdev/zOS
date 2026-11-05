--[[ Watches and controls strip-mining turtles from a computer or pocket computer. Anyone in range
can see what a turtle is doing. To control it, this computer asks, and someone at the turtle
allows it there after comparing fingerprints.

Probe answers are only claims, so a turtle found by probing is pinned by its key from the first
status that comes back, and every later request goes only to that key. ]]

local ui = require("ui")
local crypto = require("crypto")
local jobs = require("jobs")
local minemap = require("minemap")
local net = require("net")
local plan = require("plan")
local trust = require("trust")

local TITLE = "Strip Mine"
local POLL = 2 -- seconds between asking a turtle how it's doing

local function plural(n, word, many) return n .. " " .. (n == 1 and word or many or word .. "s") end

local function myFingerprint()
    return crypto.fingerprint(select(2, trust.identity()))
end

local function find()
    ui.screen(TITLE)
    ui.text("Looking for turtles...")
    local found = net.probe(jobs.PORT, 2, ui.loading()) or {}
    local turtles = {}
    for _, answer in ipairs(found) do
        if answer.from ~= os.getComputerID() and type(answer.data) == "table" then
            turtles[#turtles + 1] = {
                id = answer.from,
                name = type(answer.data.name) == "string" and answer.data.name:sub(1, 32) or ("Turtle " .. answer.from),
                status = type(answer.data.status) == "string" and answer.data.status:sub(1, 64) or "",
            }
        end
    end
    table.sort(turtles, function(a, b) return a.id < b.id end)
    return turtles
end

-- Sends a request to the turtle, or asks how it's doing if there's no payload.
local function ask(turtle, payload, onProgress)
    return net.request(turtle.id, jobs.PORT, payload or { op = "status" },
        { key = turtle.key, timeout = 5, onProgress = onProgress })
end

local function pair(turtle)
    ui.screen(TITLE .. " - Ask")
    ui.text("Asking " .. turtle.name .. "...")
    local reply, err = ask(turtle, { op = "pair", name = os.getComputerLabel() }, ui.loading())
    if not reply then return ui.message(TITLE, "Couldn't reach it: " .. tostring(err), ui.theme.bad) end
    if type(reply.payload) == "table" and reply.payload.allowed then
        return ui.message(TITLE, "This computer can already control it.", ui.theme.good)
    end
    ui.message(TITLE, "Asked. At the turtle, open Strip Mine and choose Remote control to allow it. " ..
        "It shows this fingerprint, which should match:\n\n" .. myFingerprint() ..
        "\n\nThe turtle's fingerprint is:\n" .. tostring(turtle.fingerprint))
end

local function send(turtle, op, count)
    local reply, err = ask(turtle, { op = "command", command = op, count = count })
    if not reply then return ui.message(TITLE, "Couldn't reach it: " .. tostring(err), ui.theme.bad) end
    local p = type(reply.payload) == "table" and reply.payload or {}
    if p.denied then
        ui.screen(TITLE)
        ui.text("This computer isn't allowed to control " .. turtle.name .. " yet.")
        ui.text("")
        if ui.confirm("Ask it?") then pair(turtle) end
    elseif not p.ok then
        ui.message(TITLE, tostring(p.error or "It didn't do that."), ui.theme.bad)
    end
end

local KEYS = {
    running = { { "p", "pause", "pause" }, { "h", "home", "home" }, { "c", "cancel", "cancel" } },
    paused = { { "r", "resume", "resume" }, { "h", "home", "home" }, { "c", "cancel", "cancel" } },
    stuck = { { "r", "resume", "retry" }, { "c", "cancel", "cancel" } },
}

-- How many more branches to dig, or nil.
local function askCount()
    local range, err = plan.LIMITS.count, nil
    while true do
        ui.screen(TITLE .. " - Dig more")
        ui.text("How many more branches to dig, with the settings the turtle last used. Any it left " ..
            "short are finished first.", ui.theme.dim)
        ui.text("")
        if err then
            ui.text(err, ui.theme.bad)
            ui.text("")
        end
        local typed = ui.input(("1 to %d"):format(range[2]), nil, "4")
        if typed == "" then return nil end
        local n = tonumber(typed)
        if n and n == math.floor(n) and n >= 1 and n <= range[2] then return n end
        err = ("Enter a whole number from 1 to %d."):format(range[2])
    end
end

local function hintsFor(turtle, s, mapping)
    local hints = {}
    for _, k in ipairs(s and not s.lost and KEYS[s.status] or {}) do hints[#hints + 1] = k[1]:upper() .. ":" .. k[3] end
    if s and s.canMore and turtle.allowed then hints[#hints + 1] = "D:dig more" end
    if not turtle.allowed then hints[#hints + 1] = "A:ask" end
    hints[#hints + 1] = mapping and "V:status" or "V:map"
    hints[#hints + 1] = "Q:back"
    return hints
end

local function footer(hints)
    local width, rows = term.getSize()
    local lines = ui.wrap(table.concat(hints, "  "), width - 2)
    for i, text in ipairs(lines) do ui.at(2, rows - #lines + i, text, ui.theme.dim) end
    return #lines
end

local function drawMap(turtle, s, problem)
    local _, rows = term.getSize()
    ui.screen(TITLE .. " - " .. turtle.name, s and s.percent and (s.percent .. "%") or nil)
    if problem then
        ui.text(problem, ui.theme.bad)
    elseif s then
        local text, color = jobs.describe(s)
        ui.text(text, color and ui.theme[color] or ui.theme.fg)
    end
    local used = footer(hintsFor(turtle, s, true))
    ui.at(2, rows - used, minemap.LEGEND, ui.theme.dim)
    minemap.draw(s and s.map, 4, rows - used - 1)
end

local function draw(turtle, s, problem, mapping)
    if mapping then return drawMap(turtle, s, problem) end
    local width, height = term.getSize()
    ui.screen(TITLE .. " - " .. turtle.name, s and s.percent and (s.percent .. "%") or nil)
    if problem then
        ui.text(problem, ui.theme.bad)
        ui.text("Trying again...", ui.theme.dim)
    elseif s then
        local text, color = jobs.describe(s)
        ui.text(text, color and ui.theme[color] or ui.theme.fg)
        if s.message then ui.text(s.message, ui.theme.bad) end
        if s.status ~= "idle" then
            local stats = s.stats or {}
            ui.text(("Step %d of %d"):format(math.min(s.step or 1, s.steps or 1), s.steps or 1), ui.theme.dim)
            ui.text("Fuel " .. tostring(s.fuel) .. ", " .. plural(stats.trips or 0, "trip"), ui.theme.dim)
            if s.pos then
                ui.text(("At %d, %d, %d from the start"):format(s.pos.x or 0, s.pos.y or 0, s.pos.z or 0), ui.theme.dim)
            end
            local finds = jobs.finds(stats, 3)
            if finds ~= "" then ui.text("Found: " .. finds) end
        end
        local t = s.totals
        if t then
            ui.text(("Mine: %s, %s found"):format(plural(t.branches, "branch", "branches"),
                jobs.finds(t, 2) ~= "" and jobs.finds(t, 2) or "nothing"), ui.theme.dim)
        end
    else
        ui.text("Asking...", ui.theme.dim)
    end
    footer(hintsFor(turtle, s, false))
end

local function watch(turtle)
    local summary, problem, mapping
    local timer = os.startTimer(0)
    while true do
        local event, a = os.pullEvent()
        if event == "timer" and a == timer then
            local reply, err = ask(turtle)
            if reply and type(reply.payload) == "table" and type(reply.payload.job) == "table" then
                -- Pinned from now on.
                turtle.key = turtle.key or reply.peer.key
                turtle.fingerprint = reply.peer.fingerprint
                turtle.allowed = reply.payload.allowed == true
                summary, problem = reply.payload.job, nil
            else
                problem = "Couldn't reach it: " .. tostring(err or "it didn't answer properly")
            end
            draw(turtle, summary, problem, mapping)
            timer = os.startTimer(POLL)
        elseif event == "key" and a == keys.backspace then
            return
        elseif event == "char" then
            local c = a:lower()
            if c == "q" then return end
            if c == "a" then
                pair(turtle)
            elseif c == "v" then
                mapping = not mapping
            elseif c == "d" and summary and summary.canMore and turtle.allowed then
                local n = askCount()
                if n then send(turtle, "more", n) end
            else
                for _, k in ipairs(summary and not summary.lost and KEYS[summary.status] or {}) do
                    if c == k[1] then
                        local go = true
                        if k[2] == "cancel" then
                            ui.screen(TITLE .. " - Cancel")
                            ui.text("The turtle goes back to its chest, unloads and stops.")
                            ui.text("")
                            go = ui.confirm("Cancel its mine?")
                        end
                        if go then send(turtle, k[2]) end
                    end
                end
            end
            draw(turtle, summary, problem, mapping)
            timer = os.startTimer(0)
        end
    end
end

return function()
    local turtles = find()
    local selected = 1
    while true do
        local items = {}
        for _, t in ipairs(turtles) do
            items[#items + 1] = { label = t.name, hint = t.status, turtle = t, submenu = true }
        end
        if #turtles == 0 then
            items[#items + 1] = { label = "No turtles found", fg = ui.theme.dim,
                hint = "They need Strip Mine and a modem" }
        end
        items[#items + 1] = { label = "Look again", again = true, hint = "Find turtles in range" }
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }
        selected = ui.menu({ title = TITLE, items = items, selected = selected, back = true })
        local item = selected and items[selected]
        if not item or item.label == "Back" then return end
        if item.again then
            turtles = find()
        elseif item.turtle then
            watch(item.turtle)
        end
    end
end
