-- zOS Storage: one chest for putting items in and taking them out, and any number of others that
-- hold them. The config is global, in /etc/storage/, so anyone who can log in can change it. What
-- the chests hold is kept in an item index, so that they don't all have to be read each time.

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

-- Start a loading bar below the text on screen, and return the function that moves it on.
local function progressBar()
    ui.text("")
    local _, row = term.getCursorPos()
    return function(done, total, kind)
        local verb = kind == "chest" and "Read " or "Moved "
        ui.loadingBar(row, done, total, verb .. done .. " of " .. plural(total, kind))
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

-- The chests that aren't auto chests, which are the only ones setup can choose.
local function notAuto(draft, chests)
    local out = {}
    for _, chest in ipairs(chests) do
        if not (draft.auto and draft.auto[chest.name]) then out[#out + 1] = chest end
    end
    return out
end

local function chooseIo(draft, chests, unlinked)
    chests = notAuto(draft, chests)
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
        for _, chest in ipairs(notAuto(draft, chests)) do
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

-- Forget storage chests that have gone. Nothing changes until the setup screen saves.
local function removeDisconnected(draft, chests, unlinked)
    local selected = 1
    while true do
        local missing = array.missing(draft, chests, unlinked)
        if #missing == 0 then return end

        local items = {}
        for i, name in ipairs(missing) do
            items[i] = { label = name, hint = "Remove it. Items inside stay in the chest" }
        end
        items[#items + 1] = { label = "Remove all", hint = "Items inside stay in the chests" }
        items[#items + 1] = { label = "Done" }

        local choice = ui.menu({
            title = TITLE .. " - Disconnected chests", items = items, selected = selected, back = true,
        })
        if not choice or choice == #items then return end
        if choice == #items - 1 then
            for _, name in ipairs(missing) do draft.allowed[name] = nil end
            return
        end
        draft.allowed[missing[choice]] = nil
        selected = math.min(choice, #missing - 1)
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
        local chests, unlinked = array.discover(progressBar())
        if #chests > 0 then return chests, unlinked end
        local choice = ui.menu({
            title = TITLE .. " - No chests found",
            items = { { label = "Look again", hint = "Connect chests with right-clicked wired modems" } },
            back = true,
        })
        if not choice then return false end
    end
end

local function indexLabel(config)
    local drive = config and config.index and config.index.drive
    return drive and "network drive " .. drive or "this computer"
end

-- Choose where the item index is kept: here, or on a floppy in a disk drive on the network.
local function chooseIndex(draft)
    while true do
        local current = draft.index and draft.index.drive
        local drives = array.drives()
        local items = {
            { label = (current and "( ) " or "(*) ") .. "This computer", hint = "Only this computer uses it" },
        }
        for _, drive in ipairs(drives) do
            local label = drive.name .. (drive.label and ' "' .. drive.label .. '"' or "")
            items[#items + 1] = {
                label = (drive.name == current and "(*) " or "( ) ") .. label,
                hint = drive.empty and "Put a floppy in this drive to use it"
                    or "Shared by every computer that uses these chests",
            }
        end
        if #drives == 0 then
            items[#items + 1] = {
                label = "Look for network drives", hint = "Connect a disk drive to the network with a wired modem",
            }
        end

        local choice = ui.menu({ title = TITLE .. " - Item index", items = items, back = true })
        if not choice then return end
        if choice == 1 then
            draft.index = nil
            return
        end
        local drive = drives[choice - 1]
        if drive and drive.empty then
            local text = "There's no floppy in " .. drive.name .. ". Put one in, then choose it again."
            ui.message(TITLE, text, ui.theme.bad)
        elseif drive then
            draft.index = { drive = drive.name }
            return
        end
    end
end

-- Notes start with a blank line, or with `gap` instead.
local function offlineNote(result, gap)
    if result.offline == 0 then return "" end
    return (gap or "\n\n") .. plural(result.offline, "storage chest") .. " didn't respond."
end

local function indexNote(result, gap)
    if not result.indexError then return "" end
    return (gap or "\n\n") .. "The item index wasn't saved: " .. result.indexError
end

local function rebuildIndex(config)
    ui.screen(TITLE .. " - Item index")
    ui.text("Counting every item...")
    local result = array.rebuild(config, progressBar())
    local text = "Counted " .. plural(result.items, "item") .. " in " .. plural(result.chests, "chest") .. "."
    local bad = result.indexError or result.offline > 0
    ui.message(TITLE, text .. offlineNote(result) .. indexNote(result), bad and ui.theme.bad or ui.theme.good)
end

-- Save the draft, and keep the item index in step with it. Returns true, or false and why not.
local function saveSetup(config, draft)
    local ok, err = array.save(draft)
    if not ok then return false, err end

    -- The copy on this computer missed whatever happened while another one was used.
    local wasLocal = config and not config.index
    if not draft.index and not wasLocal then array.deleteLocalIndex() end

    -- A chest that's ticked again may have changed while it wasn't.
    local added = {}
    for name in pairs(draft.allowed) do
        if not (config and config.allowed[name]) then added[#added + 1] = name end
    end
    array.forget(draft, added)
    return true
end

-- Show the setup screen. Returns the saved config, or nil if nothing was saved.
local function setup(config)
    local chests, unlinked = waitForChests()
    if not chests then return nil end

    local draft = { io = config and config.io, allowed = {}, index = config and config.index, auto = config and config.auto or {} }
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

        local items = {
            {
                label = "I/O chest: " .. (draft.io or "not set"), submenu = true, action = "io",
                hint = "Where items go in and come out",
            },
            {
                label = "Storage chests: " .. count, submenu = true, action = "storage",
                hint = "Which chests can hold items",
            },
        }
        local missing = array.missing(draft, chests, unlinked)
        if #missing > 0 then
            items[#items + 1] = {
                label = "Disconnected chests: " .. #missing, submenu = true, action = "missing",
                hint = "Remove chests that are no longer connected",
            }
        end
        items[#items + 1] = {
            label = "Item index: " .. indexLabel(draft), submenu = true, action = "index",
            hint = "Where the list of stored items is kept",
        }
        if config then
            items[#items + 1] = {
                label = "Rebuild item index", action = "rebuild",
                hint = "Count every item again, if chests were changed by hand",
            }
        end
        items[#items + 1] = { label = "Save", action = "save" }

        local choice = ui.menu({ title = TITLE .. " - Setup", selected = selected, back = true, items = items })
        selected = choice or selected
        if not choice then return nil end
        local action = items[choice].action
        if action == "io" then
            chooseIo(draft, chests, unlinked)
        elseif action == "storage" then
            chooseStorage(draft, chests, unlinked)
        elseif action == "missing" then
            removeDisconnected(draft, chests, unlinked)
        elseif action == "index" then
            chooseIndex(draft)
        elseif action == "rebuild" then
            rebuildIndex(config)
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
            local ok, err = saveSetup(config, draft)
            if ok then return draft end
            ui.message(TITLE, "Couldn't save the settings: " .. tostring(err), ui.theme.bad)
        end
    end
end

-- Using it ---------------------------------------------------------------------------------------

local NO_IO = "The I/O chest isn't connected. Check its modem, or choose another in Settings."

local function storedText(result)
    local text = "Stored " .. plural(result.moved, "item") .. "."
    if result.left > 0 then
        text = text .. "\n\nStorage is full, so " .. result.left .. " stayed in the I/O chest."
    end
    return text .. offlineNote(result) .. indexNote(result)
end

local function storeAll(config)
    ui.screen(TITLE)
    ui.text("Storing items...")
    local result = array.store(config, nil, nil, progressBar())
    if not result then return ui.message(TITLE, NO_IO, ui.theme.bad) end
    ui.message(TITLE, storedText(result), result.left > 0 and ui.theme.bad or ui.theme.good)
end

-- "100", or "100 (1s+36)" once there's at least a stack, in the stacks that chooseAmount takes.
local function countLabel(item)
    local stack = item.stack
    if not stack or stack <= 1 or item.count < stack then return tostring(item.count) end
    local extra = item.count % stack
    return item.count .. " (" .. math.floor(item.count / stack) .. "s" .. (extra > 0 and "+" .. extra or "") .. ")"
end

-- Recall `amount` of `item`. Returns what happened and its colour, or nil if the I/O chest has gone.
local function recallItem(config, item, amount)
    ui.screen(TITLE .. " - Recall")
    ui.text("Recalling " .. item.name .. "...")
    local result = array.recall(config, item.key, amount, progressBar())
    if not result then
        ui.message(TITLE, NO_IO, ui.theme.bad)
        return nil
    end

    local text, color = "Recalled " .. result.moved .. " " .. item.name .. ".", ui.theme.good
    if result.moved == 0 then
        text = "Nothing was recalled. " .. (result.full and "The I/O chest is full." or "There are none left in storage.")
        color = ui.theme.bad
    elseif result.full then
        text = text .. " The I/O chest is full"
        text = text .. (result.left > 0 and ", so " .. result.left .. " stayed in storage." or ".")
        color = ui.theme.bad
    elseif amount and result.left == 0 then
        text = text .. " That's all there were."
    end
    return text .. offlineNote(result, " ") .. indexNote(result, " "), color
end

-- Filter `stored` as the user types. Returns the chosen item, or nil if they cancelled. `status` is
-- what the last recall did, shown until the user starts typing.
local function chooseItem(stored, offline, status, statusColor, title)
    local LABEL = "Item: "
    local text, found = "", stored
    local selected, top = 1, 1

    local function setText(value)
        text, found = value, array.match(stored, value)
        selected, top, status = 1, 1, nil
    end

    term.setCursorBlink(true)
    while true do
        local width, height = term.getSize()
        local statusLines = status and ui.wrap(status, width - 2) or {}
        local firstRow = 5 + (status and #statusLines + 1 or 0)
        local lastRow = height - 2
        local rows = math.max(1, lastRow - firstRow + 1)
        if selected < top then top = selected end
        if selected >= top + rows then top = selected - rows + 1 end

        ui.screen(TITLE .. " - " .. (title or "Recall"), #found .. "/" .. #stored)
        for i, line in ipairs(statusLines) do ui.at(2, 4 + i, line, statusColor) end
        for i = 0, rows - 1 do
            local item = found[top + i]
            if not item then break end
            local chosen = top + i == selected
            local label = (item.name .. " x" .. countLabel(item)):sub(1, width - 2)
            ui.at(1, firstRow + i, " " .. label .. string.rep(" ", width - #label - 1),
                chosen and ui.theme.selectFg or ui.theme.fg, chosen and ui.theme.selectBg or ui.theme.bg)
        end
        if #found == 0 then ui.at(2, firstRow, "Nothing matches that.", ui.theme.bad) end
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
            local item = c >= firstRow and c <= lastRow and found[top + c - firstRow]
            if item then
                term.setCursorBlink(false)
                return item
            end
        end
    end
end

-- Ask how many of `item` to recall. Returns { count = n } or { stacks = n }, nil to fill the I/O
-- chest, or false if the user went back. Only a number, with an s after it for stacks, can be typed.
local function chooseAmount(item, title, help)
    local LABEL = "Amount: "
    local stack = item.stack or 64
    local text = ""

    term.setCursorBlink(true)
    while true do
        local _, height = term.getSize()
        ui.screen(TITLE .. " - " .. (title or "Recall"))
        ui.text(item.name .. " x" .. countLabel(item), ui.theme.accent)
        ui.text("")
        ui.text("")
        ui.text("")
        ui.text(help or "Type how many, or leave it empty to fill the I/O chest.", ui.theme.dim)
        ui.text("Add s for stacks: 2s is " .. 2 * stack .. ".", ui.theme.dim)
        if text == "" then ui.at(2, height - 1, "Backspace: back", ui.theme.dim) end
        ui.at(2, 5, LABEL, ui.theme.accent)
        ui.at(2 + #LABEL, 5, text)

        local event, a, b = os.pullEvent()
        if event == "char" or event == "paste" then
            for letter in a:gmatch(".") do
                local stacks = text:find("s", 1, true)
                if letter:find("%d") and not stacks and #text < 6 and not (text == "" and letter == "0") then
                    text = text .. letter
                elseif letter:lower() == "s" and text ~= "" and not stacks then
                    text = text .. "s"
                end
            end
        elseif event == "key" then
            if a == keys.backspace then
                if text ~= "" then
                    text = text:sub(1, -2)
                elseif not b then
                    term.setCursorBlink(false)
                    return false
                end
            elseif a == keys.enter or a == keys.numPadEnter then
                term.setCursorBlink(false)
                if text == "" then return nil end
                local number = tonumber(text:match("%d+"))
                return text:find("s", 1, true) and { stacks = number } or { count = number }
            end
        end
    end
end

-- Recall items one after another, until the user goes back. They stay in the I/O chest until Store all.
local function recall(config)
    local status, statusColor
    while true do
        ui.screen(TITLE .. " - Recall")
        ui.text("Searching...")
        local stored, offline, indexError = array.items(config, progressBar())
        if #stored == 0 then
            local result = { offline = offline, indexError = indexError }
            local text = status and status .. "\n\nThere's nothing left in storage." or "There's nothing in storage."
            return ui.message(TITLE, text .. offlineNote(result) .. indexNote(result), statusColor or ui.theme.bad)
        end

        local amount
        repeat
            local item = chooseItem(stored, offline, status, statusColor)
            if not item then return end
            -- With only one stored there's nothing to choose, so skip straight to recalling it.
            if item.count == 1 then
                amount = nil
            else
                amount = chooseAmount(item)
            end
            if amount ~= false then
                status, statusColor = recallItem(config, item, amount)
                if not status then return end
            end
        until amount ~= false
    end
end

-- Auto chests -------------------------------------------------------------------------------------

local AUTO = "Auto chest"

local function saveAuto(config)
    local ok, err = array.save(config)
    if not ok then return ui.message(TITLE, "Couldn't save the settings: " .. tostring(err), ui.theme.bad) end
    os.queueEvent(array.WAKE)
end

-- Choose a chest to keep stocked. Returns its name, or nil.
local function chooseAutoChest(config)
    ui.screen(TITLE .. " - " .. AUTO)
    ui.text("Looking for chests...")
    local chests, unlinked = array.discover(progressBar())
    local io = byName(chests, config.io)
    local usable = {}
    for _, chest in ipairs(chests) do
        if chest.name ~= config.io and not config.allowed[chest.name] and not config.auto[chest.name]
            and (not io or array.connected(io, chest)) then
            usable[#usable + 1] = chest
        end
    end
    if #usable == 0 then
        ui.message(TITLE, "Every chest on the network is already used. Connect another with a wired " ..
            "modem, or untick a storage chest in Settings.", ui.theme.bad)
        return nil
    end
    local items = { { label = "Find it by adding an item", hint = "Put an item in the chest you want" } }
    for _, chest in ipairs(usable) do items[#items + 1] = { label = chestLabel(chest), hint = chestHint(chest) } end
    local choice = ui.menu({ title = TITLE .. " - Choose a chest", items = items, back = true })
    if not choice then return nil end
    if choice > 1 then return usable[choice - 1].name end
    local chest = findChest(usable, unlinked, "Put any item in the chest to keep stocked.")
    return chest and chest.name
end

-- Every item it could keep: what's in storage, and what's in the chest already.
local function itemsToKeep(config, name)
    ui.screen(TITLE .. " - " .. AUTO)
    ui.text("Searching...")
    local stored, offline = array.items(config, progressBar())
    local known = {}
    for _, item in ipairs(stored) do known[item.key] = true end
    for _, item in ipairs(array.itemsIn(name) or {}) do
        if not known[item.key] then stored[#stored + 1] = item end
    end
    table.sort(stored, function(a, b) return a.name < b.name end)
    return stored, offline
end

-- How many to keep, as a number of items, or nil if the user went back.
local function chooseTarget(item)
    local amount = chooseAmount(item, AUTO, "Type how many to keep in the chest.")
    if not amount then return nil end
    local count = amount.count or amount.stacks * (item.stack or 64)
    return count > 0 and count or nil
end

local function addTarget(config, name)
    local stored, offline = itemsToKeep(config, name)
    if #stored == 0 then
        return ui.message(TITLE, "There's nothing in storage or in the chest to choose from.", ui.theme.bad)
    end
    local item = chooseItem(stored, offline, nil, nil, AUTO)
    if not item then return end
    local count = chooseTarget(item)
    if not count then return end
    local targets = config.auto[name].targets
    for i, target in ipairs(targets) do
        if target.key == item.key then table.remove(targets, i) break end
    end
    targets[#targets + 1] = { key = item.key, id = item.id, name = item.name, count = count }
    table.sort(targets, function(a, b) return a.name < b.name end)
    saveAuto(config)
end

local function editTarget(config, name, target)
    local choice = ui.menu({
        title = TITLE .. " - " .. target.name, back = true,
        items = {
            { label = "Keep " .. target.count, hint = "Change how many to keep" },
            { label = "Stop keeping it", hint = "Anything left goes into storage" },
            { label = "Back", fg = ui.theme.dim },
        },
    })
    if choice == 1 then
        local count = chooseTarget({ name = target.name, count = target.count, stack = nil })
        if count then target.count = count end
    elseif choice == 2 then
        local targets = config.auto[name].targets
        for i, other in ipairs(targets) do
            if other == target then table.remove(targets, i) break end
        end
    else
        return
    end
    saveAuto(config)
end

local function editAuto(config, name)
    local selected = 1
    while true do
        local auto = config.auto[name]
        if not auto then return end
        local counts = array.counts(name)
        local items = {}
        for _, target in ipairs(auto.targets) do
            local has = counts and " (has " .. (counts[target.key] or 0) .. ")" or ""
            items[#items + 1] = {
                label = target.name .. ": " .. target.count .. has, target = target, submenu = true,
                hint = "Change how many to keep",
            }
        end
        items[#items + 1] = { label = "Add an item", action = "add", submenu = true, hint = "Keep some of an item in it" }
        items[#items + 1] = { label = "Stop managing this chest", action = "remove", hint = "Items in it stay there" }
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }
        selected = ui.menu({
            title = TITLE .. " - " .. name, status = counts and nil or "not connected",
            items = items, selected = selected, back = true,
        })
        local item = selected and items[selected]
        if not item or item.label == "Back" then return end
        if item.target then
            editTarget(config, name, item.target)
        elseif item.action == "add" then
            addTarget(config, name)
        elseif item.action == "remove" then
            config.auto[name] = nil
            saveAuto(config)
            return
        end
    end
end

local function autoChests(config)
    local selected = 1
    while true do
        local names = {}
        for name in pairs(config.auto) do names[#names + 1] = name end
        table.sort(names)
        local items = {}
        for _, name in ipairs(names) do
            items[#items + 1] = {
                label = name, name = name, submenu = true,
                hint = #config.auto[name].targets == 0 and "Everything put in it is stored"
                    or plural(#config.auto[name].targets, "item") .. " kept stocked",
            }
        end
        items[#items + 1] = { label = "Add a chest", action = "add", submenu = true, hint = "Keep a chest stocked with items" }
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }
        selected = ui.menu({ title = TITLE .. " - Auto chests", items = items, selected = selected, back = true })
        local item = selected and items[selected]
        if not item or item.label == "Back" then return end
        if item.name then
            editAuto(config, item.name)
        else
            local name = chooseAutoChest(config)
            if name then
                config.auto[name] = { targets = {} }
                saveAuto(config)
                editAuto(config, name)
            end
        end
    end
end

local function main()
    local config = array.load() or setup(nil)
    if not config then return end
    config.auto = config.auto or {}

    local selected = 1
    while true do
        local choice = ui.menu({
            title = TITLE,
            selected = selected,
            items = {
                { label = "Store all", hint = "Move everything in the I/O chest into storage" },
                { label = "Recall item", submenu = true, hint = "Fill the I/O chest with an item" },
                { label = "Auto chests", submenu = true, hint = "Keep chests stocked with set amounts" },
                { label = "Settings", submenu = true, hint = "Choose the chests and where the item index is kept" },
                { label = "Exit" },
            },
        })
        selected = choice
        if choice == 1 then
            storeAll(config)
        elseif choice == 2 then
            recall(config)
        elseif choice == 3 then
            autoChests(config)
        elseif choice == 4 then
            config = setup(config) or config
            config.auto = config.auto or {}
        else
            return
        end
    end
end

main()
