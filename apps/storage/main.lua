-- zOS Storage: one chest for putting items in and taking them out, and any number of others that
-- hold them. The config is global, in /etc/storage/, so anyone who can log in can change it.

local array = require("array")
local ui = require("ui")

local TITLE = "Storage"
local POLL_SECONDS = 0.5 -- how often to look for a chest being changed

local function plural(count, word)
    return count .. " " .. word .. (count == 1 and "" or "s")
end

local function chestLabel(chest)
    return chest.name .. (chest.side and " (" .. chest.side .. ")" or "")
end

local function chestHint(chest)
    return chest.size .. " slots, " .. chest.used .. " used"
end

local function byName(chests, name)
    for _, chest in ipairs(chests) do
        if chest.name == name then return chest end
    end
end

-- Setup ------------------------------------------------------------------------------------------

local NO_MODEM = "The chest next to the computer can't reach the network. Put a wired modem on the " ..
    "chest and right-click the modem to connect it, then try again."

-- Wait for one chest to change, and return it. Returns nil if the user cancelled. A chest fed by a
-- hopper changes by itself, so a change in several chests at once proves nothing.
local function findChest(chests, unlinked, text)
    ui.screen(TITLE .. " - Find a chest")
    ui.text(text)
    ui.text("")
    ui.text("Backspace: cancel", ui.theme.dim)

    local before = array.snapshot(chests, unlinked)
    while true do
        local timer = os.startTimer(POLL_SECONDS)
        while true do
            local event, value = os.pullEvent()
            if event == "timer" and value == timer then break end
            if event == "key" and value == keys.backspace then return nil end
        end

        local after = array.snapshot(chests, unlinked)
        local changed = {}
        for _, chest in ipairs(chests) do
            if before[chest.name] and after[chest.name] ~= before[chest.name] then
                changed[#changed + 1] = chest
            end
        end
        if #changed == 1 then return changed[1] end
        if #changed == 0 then
            for _, chest in ipairs(unlinked) do
                if before[chest.name] and after[chest.name] ~= before[chest.name] then
                    ui.message(TITLE, NO_MODEM, ui.theme.bad)
                    return nil
                end
            end
        end
        before = after
    end
end

local function chooseIo(draft, chests, unlinked)
    local items = { { label = "Find it by adding an item", hint = "Put an item in the chest you want" } }
    for _, chest in ipairs(chests) do
        items[#items + 1] = {
            label = (chest.name == draft.io and "(*) " or "( ) ") .. chestLabel(chest),
            hint = chestHint(chest),
        }
    end
    local choice = ui.menu({ title = TITLE .. " - I/O chest", items = items, back = true })
    if not choice then return end
    if choice == 1 then
        local chest = findChest(chests, unlinked, "Put any item in the chest to use for input and output.")
        if chest then draft.io = chest.name end
    else
        draft.io = chests[choice - 1].name
    end
end

local function chooseStorage(draft, chests, unlinked)
    local io = byName(chests, draft.io)
    local selected = 1
    while true do
        local usable = {}
        for _, chest in ipairs(chests) do
            if chest.name ~= draft.io and (not io or array.connected(io, chest)) then
                usable[#usable + 1] = chest
            end
        end

        local items = {}
        for i, chest in ipairs(usable) do
            items[i] = {
                label = (draft.allowed[chest.name] and "[x] " or "[ ] ") .. chestLabel(chest),
                hint = chestHint(chest),
            }
        end
        items[#items + 1] = { label = "Find a chest", hint = "Change a chest to select it here" }
        items[#items + 1] = { label = "Done" }

        local choice = ui.menu({ title = TITLE .. " - Storage chests", items = items, selected = selected, back = true })
        if not choice or choice == #items then return end
        if choice == #items - 1 then
            local chest = findChest(usable, unlinked, "Add or take an item from the chest to find it in the list.")
            for i, candidate in ipairs(usable) do
                if candidate == chest then selected = i end
            end
        else
            local name = usable[choice].name
            draft.allowed[name] = not draft.allowed[name] or nil
            selected = choice
        end
    end
end

-- The chest beside the computer, if there's one to default to. Asks for help if it can't tell.
local function defaultIo(chests, unlinked)
    if #unlinked == 0 then
        for _, chest in ipairs(chests) do
            if chest.side or not chest.networks then return chest.name end
        end
        return nil
    end
    if unlinked[1].candidates == 0 then
        ui.message(TITLE, NO_MODEM, ui.theme.bad)
        return nil
    end
    local chest = findChest(chests, unlinked,
        "Put any item in the chest next to the computer, so that it can be found on the network.")
    return chest and chest.name
end

-- What a chest is ticked for on first use. Anything else, such as a furnace, has to be chosen.
local function looksLikeStorage(chest)
    return chest.type:find("chest", 1, true) or chest.type:find("barrel", 1, true)
end

-- Wait until something is connected. Returns false if the user went back.
local function waitForChests()
    while true do
        ui.screen(TITLE .. " - Setup")
        ui.text("Looking for chests...")
        ui.text("")
        local _, row = term.getCursorPos()
        local chests, unlinked = array.discover(function(done, total)
            ui.loadingBar(row, done, total, "Read " .. done .. " of " .. plural(total, "chest"))
        end)
        if #chests > 0 then return chests, unlinked end
        local choice = ui.menu({
            title = TITLE .. " - No chests found",
            items = { { label = "Look again", hint = "Connect chests with right-clicked wired modems" } },
            back = true,
        })
        if not choice then return false end
    end
end

-- Show the setup screen. Returns the saved config, or nil if nothing was saved.
local function setup(config)
    local chests, unlinked = waitForChests()
    if not chests then return nil end

    local draft = { io = config and config.io, allowed = {} }
    for name in pairs(config and config.allowed or {}) do draft.allowed[name] = true end
    if not config then
        draft.io = defaultIo(chests, unlinked)
        for _, chest in ipairs(chests) do
            if looksLikeStorage(chest) then draft.allowed[chest.name] = true end
        end
    end

    local selected = 1
    while true do
        local io = byName(chests, draft.io)
        local count = 0
        for _, chest in ipairs(chests) do
            if draft.allowed[chest.name] and chest ~= io and (not io or array.connected(io, chest)) then
                count = count + 1
            end
        end

        local choice = ui.menu({
            title = TITLE .. " - Setup",
            selected = selected,
            back = true,
            items = {
                {
                    label = "I/O chest: " .. (draft.io or "not set"), submenu = true,
                    hint = "Where items go in and come out",
                },
                { label = "Storage chests: " .. count, submenu = true, hint = "Which chests can hold items" },
                { label = "Save" },
            },
        })
        selected = choice or selected
        if not choice then return nil end
        if choice == 1 then
            chooseIo(draft, chests, unlinked)
        elseif choice == 2 then
            chooseStorage(draft, chests, unlinked)
        elseif not draft.io then
            ui.message(TITLE, "Choose an I/O chest first.", ui.theme.bad)
        elseif count == 0 then
            ui.message(TITLE, "Choose at least one storage chest first.", ui.theme.bad)
        else
            -- Keeps chests that are only away for now, but not ones that can't be reached.
            draft.allowed[draft.io] = nil
            for _, chest in ipairs(chests) do
                if io and not array.connected(io, chest) then draft.allowed[chest.name] = nil end
            end
            local ok, err = array.save(draft)
            if ok then return draft end
            ui.message(TITLE, "Couldn't save the settings: " .. tostring(err), ui.theme.bad)
        end
    end
end

-- Using it ---------------------------------------------------------------------------------------

local NO_IO = "The I/O chest isn't connected. Check its modem, or choose another in Settings."

local function offlineNote(result)
    if result.offline == 0 then return "" end
    return "\n\n" .. plural(result.offline, "storage chest") .. " didn't respond."
end

local function storedText(result)
    local text = "Stored " .. plural(result.moved, "item") .. "."
    if result.left > 0 then
        text = text .. "\n\nStorage is full, so " .. result.left .. " stayed in the I/O chest."
    end
    return text .. offlineNote(result)
end

local function storeAll(config)
    ui.screen(TITLE)
    ui.text("Storing items...")
    local result = array.store(config)
    if not result then return ui.message(TITLE, NO_IO, ui.theme.bad) end
    ui.message(TITLE, storedText(result), result.left > 0 and ui.theme.bad or ui.theme.good)
end

-- Show what was recalled, with the return button as the only way on.
local function waitForReturn(text)
    ui.screen(TITLE)
    ui.text(text, ui.theme.good)
    ui.text("")
    local width = term.getSize()
    local _, y = term.getCursorPos()
    local label = " Return items to storage"
    ui.at(1, y, label:sub(1, width) .. string.rep(" ", width - #label), ui.theme.selectFg, ui.theme.selectBg)
    ui.at(2, y + 1, "Press Enter or click", ui.theme.dim)

    while true do
        local event, a, _, clickY = os.pullEvent()
        if event == "key" and (a == keys.enter or a == keys.numPadEnter) then return end
        if event == "mouse_click" and clickY == y then return end
    end
end

local function recallItem(config, item)
    ui.screen(TITLE)
    ui.text("Recalling " .. item.name .. "...")
    local result = array.recall(config, item.key)
    if not result then return ui.message(TITLE, NO_IO, ui.theme.bad) end
    if result.moved == 0 then
        local reason = result.left > 0 and "The I/O chest is full." or "There are none left in storage."
        return ui.message(TITLE, "Nothing was recalled. " .. reason .. offlineNote(result), ui.theme.bad)
    end

    local text = "Recalled " .. result.moved .. " " .. item.name .. "."
    if result.left > 0 then text = text .. " The I/O chest is full, so " .. result.left .. " stayed in storage." end
    waitForReturn(text .. "\n\nTake what you need from the I/O chest." .. offlineNote(result))

    ui.screen(TITLE)
    ui.text("Returning items...")
    local returned = array.store(config, item.key, result.moved)
    if not returned then return ui.message(TITLE, NO_IO, ui.theme.bad) end
    ui.message(TITLE, storedText(returned), returned.left > 0 and ui.theme.bad or ui.theme.good)
end

-- Filter `stored` as the user types. Returns the chosen item, or nil if they cancelled.
local function chooseItem(stored, offline)
    local LABEL = "Item: "
    local FIRST_ROW = 5
    local text, found = "", stored
    local selected, top = 1, 1

    local function setText(value)
        text, found = value, array.match(stored, value)
        selected, top = 1, 1
    end

    term.setCursorBlink(true)
    while true do
        local width, height = term.getSize()
        local lastRow = height - 2
        local rows = math.max(1, lastRow - FIRST_ROW + 1)
        if selected < top then top = selected end
        if selected >= top + rows then top = selected - rows + 1 end

        ui.screen(TITLE .. " - Recall", #found .. "/" .. #stored)
        for i = 0, rows - 1 do
            local item = found[top + i]
            if not item then break end
            local chosen = top + i == selected
            local label = (item.name .. " x" .. item.count):sub(1, width - 2)
            ui.at(1, FIRST_ROW + i, " " .. label .. string.rep(" ", width - #label - 1),
                chosen and ui.theme.selectFg or ui.theme.fg, chosen and ui.theme.selectBg or ui.theme.bg)
        end
        if #found == 0 then ui.at(2, FIRST_ROW, "Nothing matches that.", ui.theme.bad) end
        if text == "" then ui.at(2, height - 1, "Backspace: cancel", ui.theme.dim) end

        local hint = found[selected] and found[selected].id
        if not hint and offline > 0 then hint = plural(offline, "storage chest") .. " didn't respond." end
        if hint then ui.at(2, height, hint:sub(1, width - 2), ui.theme.dim) end

        -- Last, so that the cursor is left at the end of the text.
        local shown = text:sub(-math.max(1, width - #LABEL - 3))
        ui.at(2, 3, LABEL, ui.theme.accent)
        ui.at(2 + #LABEL, 3, shown)

        local event, a, b, c = os.pullEvent()
        if event == "char" or event == "paste" then
            setText(text .. a)
        elseif event == "key" then
            if a == keys.backspace then
                -- Holding it to clear the text stops there, instead of leaving the screen too.
                if text ~= "" then
                    setText(text:sub(1, -2))
                elseif not b then
                    term.setCursorBlink(false)
                    return nil
                end
            elseif #found > 0 then
                if a == keys.up then
                    selected = selected > 1 and selected - 1 or #found
                elseif a == keys.down then
                    selected = selected < #found and selected + 1 or 1
                elseif a == keys.pageUp then
                    selected = math.max(1, selected - rows)
                elseif a == keys.pageDown then
                    selected = math.min(#found, selected + rows)
                elseif a == keys.enter or a == keys.numPadEnter then
                    term.setCursorBlink(false)
                    return found[selected]
                end
            end
        elseif event == "mouse_scroll" and #found > 0 then
            selected = math.max(1, math.min(#found, selected + a))
        elseif event == "mouse_click" then
            local item = c >= FIRST_ROW and c <= lastRow and found[top + c - FIRST_ROW]
            if item then
                term.setCursorBlink(false)
                return item
            end
        end
    end
end

local function recall(config)
    ui.screen(TITLE .. " - Recall")
    ui.text("Searching...")
    local stored, offline = array.items(config)
    if #stored == 0 then
        return ui.message(TITLE, "There's nothing in storage." .. offlineNote({ offline = offline }), ui.theme.bad)
    end

    local item = chooseItem(stored, offline)
    if item then recallItem(config, item) end
end

local function main()
    local config = array.load() or setup(nil)
    if not config then return end

    local selected = 1
    while true do
        local choice = ui.menu({
            title = TITLE,
            selected = selected,
            items = {
                { label = "Store all", hint = "Move everything in the I/O chest into storage" },
                { label = "Recall item", submenu = true, hint = "Fill the I/O chest with an item" },
                { label = "Settings", submenu = true, hint = "Choose the I/O and storage chests" },
                { label = "Exit" },
            },
        })
        selected = choice
        if choice == 1 then
            storeAll(config)
        elseif choice == 2 then
            recall(config)
        elseif choice == 3 then
            config = setup(config) or config
        else
            return
        end
    end
end

main()
