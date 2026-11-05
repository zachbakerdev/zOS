--[[ zOS Strip Mine. On a turtle, this is where a mine is set up and watched. The digging happens in
service.lua, so it carries on after leaving the app, logging out or being unloaded. On a computer
or pocket computer, it watches and controls the turtles in range instead, from monitor.lua. ]]

local session, app = ...
if not turtle then return require("monitor")(session, app) end

local ui = require("ui")
local crypto = require("crypto")
local jobs = require("jobs")
local miner = require("miner")
local plan = require("plan")
local trust = require("trust")
local util = require("util")

local TITLE = "Strip Mine"
local SETTINGS = "/home/" .. session.user .. "/.config/" .. app.id .. "/settings"
local REFRESH = 1 -- seconds between redrawing the status

local function plural(n, word, many) return n .. " " .. (n == 1 and word or many or word .. "s") end

local function fuelText(level)
    if level == "unlimited" then return "unlimited" end
    return tostring(level)
end

local function loadSettings()
    return plan.check(util.readTable(SETTINGS) or {}) or plan.defaults()
end

local function saveSettings(config) util.writeTable(SETTINGS, config) end

-- Asks for a whole number in a range. Returns nil if nothing was typed.
local function askNumber(title, text, current, range)
    local err
    while true do
        ui.screen(TITLE .. " - " .. title)
        ui.text(text, ui.theme.dim)
        ui.text("")
        if err then
            ui.text(err, ui.theme.bad)
            ui.text("")
        end
        local typed = ui.input(("%d to %d"):format(range[1], range[2]), nil, tostring(current))
        if typed == "" then return nil end
        local n = tonumber(typed)
        if n and n == math.floor(n) and n >= range[1] and n <= range[2] then return n end
        err = ("Enter a whole number from %d to %d."):format(range[1], range[2])
    end
end

local function cycle(list, id)
    for i, entry in ipairs(list) do
        if entry.id == id then return list[i % #list + 1].id end
    end
    return list[1].id
end

-- The junk list ------------------------------------------------------------------------------------

local function inventoryNames(skip)
    local names, seen = {}, {}
    for slot = 1, 16 do
        local item = turtle.getItemDetail(slot)
        if item and not seen[item.name] and not skip[item.name] then
            seen[item.name] = true
            names[#names + 1] = item.name
        end
    end
    table.sort(names)
    return names
end

-- How many of one junk item to keep, or taking it off the list.
local function editJunkItem(config, name)
    local short = name:gsub("^minecraft:", "")
    local keep = config.keep[name] or 0
    local choice = ui.menu({
        title = TITLE .. " - " .. short, back = true,
        items = {
            { label = "Keep: " .. (keep > 0 and keep .. " a trip" or "none"),
              hint = "Carry some to the chest, and seal with them" },
            { label = "Take it off the list", hint = "Keep all of it, like anything else" },
            { label = "Back", fg = ui.theme.dim },
        },
    })
    if choice == 1 then
        local n = askNumber("Keep " .. short, "How many to carry back to the chest each trip. It's used to " ..
            "seal holes first, if sealing is on, and the rest is thrown away. 0 throws it all away.",
            keep, plan.LIMITS.keep)
        if n then config.keep[name] = n > 0 and n or nil end
    elseif choice == 2 then
        for i, listed in ipairs(config.junkList) do
            if listed == name then table.remove(config.junkList, i) break end
        end
        config.keep[name] = nil
    end
end

local function editJunk(config)
    local selected = 1
    while true do
        local listed = {}
        for _, name in ipairs(config.junkList) do listed[name] = true end
        local items = {
            { label = "Junk filter: " .. (config.junk and "on" or "off"), action = "toggle",
              hint = "Throw these away instead of carrying them" },
            { label = "Add from the turtle", action = "add", submenu = true,
              hint = "Put a block in the turtle to add it" },
        }
        for _, name in ipairs(config.junkList) do
            local keep = config.keep[name] or 0
            items[#items + 1] = {
                label = name:gsub("^minecraft:", "") .. (keep > 0 and " (keep " .. keep .. ")" or ""), name = name,
                submenu = true, hint = keep > 0 and "Brings " .. keep .. " a trip to the chest" or "Thrown away",
            }
        end
        items[#items + 1] = { label = "Reset the list", action = "reset", hint = "Back to the usual stone, dirt and gravel" }
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }
        selected = ui.menu({ title = TITLE .. " - Junk", items = items, selected = selected, back = true })
        local item = selected and items[selected]
        if not item or item.label == "Back" then return end
        if item.action == "toggle" then
            config.junk = not config.junk
        elseif item.action == "reset" then
            config.junkList = plan.defaults().junkList
        elseif item.action == "add" then
            local names = inventoryNames(listed)
            if #names == 0 then
                ui.message(TITLE, "There's nothing in the turtle that isn't on the list already. Put a " ..
                    "block of what you want thrown away in the turtle, then try again.")
            else
                local choices = {}
                for _, name in ipairs(names) do choices[#choices + 1] = { label = name:gsub("^minecraft:", ""), name = name } end
                local pick = ui.menu({ title = TITLE .. " - Add junk", items = choices, back = true })
                if pick then table.insert(config.junkList, choices[pick].name) end
            end
        elseif item.name then
            editJunkItem(config, item.name)
        end
        saveSettings(config)
    end
end

-- Starting -----------------------------------------------------------------------------------------

local function start(config)
    local steps = plan.steps(config)
    local estimate = plan.estimate(config, steps)
    local level = turtle.getFuelLevel()
    ui.screen(TITLE .. " - Start")
    ui.text("The turtle should be on the floor where the mine starts, facing the way the tunnels go, " ..
        "with a chest right behind it.")
    ui.text("")
    ui.text(("Needs about %d fuel (%s). It has %s, and takes more from the chest."):format(
        estimate.fuel, plural(plan.coal(estimate.fuel), "coal"), fuelText(level)), ui.theme.dim)
    if config.torches > 0 then ui.text("Put torches in the chest or the turtle.", ui.theme.dim) end
    ui.text("")
    if not ui.confirm("Start mining?") then return false end
    local job = miner.newJob(config)
    job.stats.started = os.epoch("utc")
    jobs.save(job)
    jobs.command("start")
    return true
end

local function setup()
    local config = loadSettings()
    local selected = 1
    while true do
        local size, side = plan.size(config), plan.side(config)
        local estimate = plan.estimate(config, plan.steps(config))
        local items = {
            { label = "Length: " .. plural(config.length, "block"), key = "length",
              hint = "How far each tunnel goes" },
            { label = "Tunnels: " .. config.count, key = "count", hint = "How many tunnels to dig" },
            { label = "Spacing: " .. plural(config.spacing, "block"), key = "spacing",
              hint = "Solid blocks left between tunnels" },
            { label = "Side: " .. side.label, key = "side", hint = "Which way the tunnels spread out" },
            { label = "Size: " .. size.label, key = "size", hint = "The tunnels' cross-section" },
            { label = "Far ends: " .. (config.connect and "joined" or "not joined"), key = "connect",
              hint = "Join the tunnels at the far end too" },
            { label = "Torches: " .. (config.torches > 0 and "every " .. config.torches or "off"), key = "torches",
              hint = "How far apart to put torches" },
            { label = "Vein mining: " .. (config.vein and "on" or "off"), key = "vein",
              hint = "Dig out ore it sees in the walls" },
            { label = "Seal hazards: " .. (config.seal and "on" or "off"), key = "seal",
              hint = "Fill holes in the floor, block lava and water" },
            { label = "Junk: " .. (config.junk and plural(#config.junkList, "item") or "kept"), key = "junk",
              submenu = true, hint = "What to throw away" },
            { label = "Start mining", key = "start", fg = ui.theme.good,
              hint = ("About %d fuel, %s"):format(estimate.fuel, plural(plan.coal(estimate.fuel), "coal")) },
            { label = "Back", fg = ui.theme.dim },
        }
        selected = ui.menu({ title = TITLE .. " - New mine", items = items, selected = selected, back = true })
        local key = selected and items[selected].key
        if not key then return end
        if key == "length" then
            config.length = askNumber("Length", "How many blocks forward each tunnel goes, from the corridor.",
                config.length, plan.LIMITS.length) or config.length
        elseif key == "count" then
            config.count = askNumber("Tunnels", "How many tunnels to dig.", config.count, plan.LIMITS.count) or config.count
        elseif key == "spacing" then
            config.spacing = askNumber("Spacing", "How many solid blocks to leave between tunnels. 2 finds " ..
                "almost every ore while vein mining is on.", config.spacing, plan.LIMITS.spacing) or config.spacing
        elseif key == "torches" then
            config.torches = askNumber("Torches", "How many blocks apart to put torches. 0 puts none.",
                config.torches, plan.LIMITS.torches) or config.torches
        elseif key == "side" then
            config.side = cycle(plan.SIDES, config.side)
        elseif key == "size" then
            config.size = cycle(plan.SIZES, config.size)
        elseif key == "connect" or key == "vein" or key == "seal" then
            config[key] = not config[key]
        elseif key == "junk" then
            editJunk(config)
        elseif key == "start" then
            saveSettings(config)
            if start(config) then return true end
        end
        saveSettings(config)
    end
end

-- Remote control -----------------------------------------------------------------------------------

local function remoteLabel(entry)
    return (entry.name or "Computer") .. " #" .. tostring(entry.id)
end

local function remotes()
    local selected = 1
    while true do
        local items = {}
        for _, request in ipairs(jobs.requests()) do
            items[#items + 1] = { label = "Asking: " .. remoteLabel(request), request = request, fg = ui.theme.accent,
                hint = "Enter: allow or refuse it" }
        end
        for _, remote in ipairs(jobs.remotes()) do
            items[#items + 1] = { label = remoteLabel(remote), remote = remote, hint = "Enter: stop allowing it" }
        end
        items[#items + 1] = { label = "How to add one", help = true, hint = "Ask from another computer" }
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }
        selected = ui.menu({ title = TITLE .. " - Remote control", items = items, selected = selected, back = true })
        local item = selected and items[selected]
        if not item or item.label == "Back" then return end
        if item.help then
            ui.message(TITLE, "On a computer or pocket computer in range, open Strip Mine, choose this " ..
                "turtle and press A to ask. The request shows up here.\n\nThis turtle's fingerprint, to " ..
                "compare on the other computer:\n" .. crypto.fingerprint(select(2, trust.identity())))
        elseif item.request then
            ui.screen(TITLE .. " - Allow?")
            ui.text(remoteLabel(item.request) .. " wants to pause, resume and cancel this turtle's mine.")
            ui.text("")
            ui.text("Check that its screen shows this fingerprint:", ui.theme.dim)
            ui.text(tostring(item.request.fingerprint), ui.theme.accent)
            ui.text("")
            if ui.confirm("Allow it?") then
                jobs.allow(item.request)
            else
                jobs.dropRequest(item.request.key)
            end
        elseif item.remote then
            ui.screen(TITLE .. " - Remote control")
            ui.text(remoteLabel(item.remote))
            ui.text(tostring(item.remote.fingerprint), ui.theme.dim)
            ui.text("")
            if ui.confirm("Stop allowing it to control this turtle?") then jobs.forget(item.remote.key) end
        end
    end
end

-- Watching -----------------------------------------------------------------------------------------

local KEYS = {
    running = { { "p", "pause", "pause" }, { "h", "home", "home" }, { "c", "cancel", "cancel" } },
    paused = { { "r", "resume", "resume" }, { "h", "home", "home" }, { "c", "cancel", "cancel" } },
    stuck = { { "r", "resume", "retry" }, { "c", "cancel", "cancel" } },
    lost = { { "b", "putback", "put back" }, { "c", "cancel", "cancel" } },
}

local function keysFor(s)
    if s.lost then return KEYS.lost end
    return KEYS[s.status] or {}
end

local function drawStatus(s)
    local width = term.getSize()
    ui.screen(TITLE, s.percent and (s.percent .. "%") or nil)
    local text, color = jobs.describe(s)
    ui.text(text, color and ui.theme[color] or ui.theme.fg)
    if s.message then ui.text(s.message, ui.theme.bad) end
    if s.lost then
        ui.text("Carry it back to where the mine starts, on the floor facing forward with the chest " ..
            "behind it, then press B.", ui.theme.dim)
    end
    ui.text(("Step %d of %d, fuel %s"):format(math.min(s.step, s.steps), s.steps, fuelText(s.fuel)), ui.theme.dim)
    local stats = s.stats or {}
    ui.text(("%s dug, %s, %s"):format(plural(stats.blocks or 0, "block"), plural(stats.trips or 0, "trip"),
        plural(stats.torches or 0, "torch", "torches")), ui.theme.dim)
    if stats.noTorches then ui.text("Out of torches.", ui.theme.accent) end
    local finds = jobs.finds(stats, 4)
    if finds ~= "" then ui.text("Found: " .. finds) end
    local waiting = #jobs.requests()
    if waiting > 0 then ui.text(plural(waiting, "computer") .. " asking for remote control: M", ui.theme.accent) end
    local hints = {}
    for _, k in ipairs(keysFor(s)) do hints[#hints + 1] = k[1]:upper() .. ":" .. k[3] end
    hints[#hints + 1] = "M:remote"
    hints[#hints + 1] = "Q:leave"
    local _, rows = term.getSize()
    local lines = ui.wrap(table.concat(hints, "  "), width - 2)
    for i, text in ipairs(lines) do ui.at(2, rows - #lines + i, text, ui.theme.dim) end
end

-- The live status of a job that isn't over. Returns "quit" to leave the app, or nil once the job ends.
local function watch()
    while true do
        local job = jobs.load()
        if not jobs.isActive(job) then return end
        local s = jobs.summary(job, turtle.getFuelLevel())
        drawStatus(s)
        local timer = os.startTimer(REFRESH)
        while true do
            local event, a = os.pullEvent()
            if event == "timer" and a == timer then break end
            if event == "key" and a == keys.backspace then return "quit" end
            if event == "char" then
                local c = a:lower()
                if c == "q" then return "quit" end
                if c == "m" then
                    remotes()
                    break
                end
                for _, k in ipairs(keysFor(s)) do
                    if c == k[1] then
                        if k[2] == "cancel" then
                            ui.screen(TITLE .. " - Cancel")
                            ui.text(s.lost and "This ends the job where it is." or
                                "The turtle goes back to the chest, unloads and stops. This mine can't be carried on.")
                            ui.text("")
                            if ui.confirm("Cancel the mine?") then jobs.command("cancel") end
                        else
                            jobs.command(k[2])
                        end
                    end
                end
                break
            end
        end
    end
end

local function lastJob(job)
    local s = jobs.summary(job, turtle.getFuelLevel())
    local stats = s.stats or {}
    local lines = {
        (jobs.describe(s)),
        ("%d tunnels, %d long, %d apart, %s"):format(s.config.count, s.config.length, s.config.spacing, s.config.size),
        plural(stats.blocks or 0, "block") .. " dug",
        plural(stats.trips or 0, "trip") .. " to the chest",
        plural(stats.torches or 0, "torch", "torches") .. " placed",
        plural(stats.sealed or 0, "hole") .. " sealed",
    }
    if stats.started and stats.finished then
        lines[#lines + 1] = ("Took %d minutes"):format(math.floor((stats.finished - stats.started) / 60000 + 0.5))
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Put in the chest:"
    local finds = jobs.finds(stats)
    lines[#lines + 1] = finds ~= "" and finds or "nothing"
    ui.pager(TITLE .. " - Last mine", table.concat(lines, "\n"))
end

local selected = 1
while true do
    local job = jobs.load()
    if jobs.isActive(job) then
        if watch() == "quit" then return end
    else
        local waiting = #jobs.requests()
        local items = {
            { label = "New mine", action = setup, submenu = true, hint = "Choose the size and start" },
        }
        if job then
            items[#items + 1] = { label = "Last mine: " .. (jobs.describe(jobs.summary(job))), action = function() lastJob(job) end,
                hint = "What it found" }
        end
        items[#items + 1] = { label = "Remote control" .. (waiting > 0 and " (" .. waiting .. " asking)" or ""),
            action = remotes, submenu = true, hint = "Computers that can control it" }
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }
        selected = ui.menu({ title = TITLE, items = items, selected = selected, back = true })
        if not selected or not items[selected].action then return end
        items[selected].action()
    end
end
