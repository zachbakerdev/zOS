-- zOS Minesweeper. Best times belong to each user, in ~/.config/minesweeper/.

local session, app = ...

local board = require("board")
local ui = require("ui")
local util = require("util")

local TITLE = "Minesweeper"
local BEST_FILE = "/home/" .. session.user .. "/.config/" .. app.id .. "/best"
local LEVELS = {
    { label = "Easy", cols = 9, rows = 9, mines = 10 },
    { label = "Medium", cols = 16, rows = 16, mines = 40 },
    { label = "Hard", cols = 30, rows = 16, mines = 99 },
}

-- Every cell also differs by its character, so nothing here relies on colour.
local theme = ui.theme
local colour = term.isColour and term.isColour()
local NUMBERS = colour and {
    colors.lightBlue, colors.lime, colors.red, colors.magenta,
    colors.orange, colors.cyan, colors.white, colors.lightGray,
} or {}
local HIDDEN_BG = colour and colors.gray or theme.bg

local function clock(seconds)
    return ("%d:%02d"):format(math.floor(seconds / 60), seconds % 60)
end

-- The level as it fits this screen. A level cut down to fit is a different game, so it has its own
-- best time.
local function fitted(level)
    local width, height = term.getSize()
    local cols, rows, mines = board.fit(level.cols, level.rows, level.mines, width, height - 2)
    return { cols = cols, rows = rows, mines = mines, key = cols .. "x" .. rows .. "x" .. mines }
end

-- What a cell shows: its character, text colour and background.
local function look(cell, over)
    if cell.open and cell.mine then return "*", colors.black, colour and theme.bad or theme.fg end
    if cell.open then
        if cell.count == 0 then return " ", theme.fg, theme.bg end
        return tostring(cell.count), NUMBERS[cell.count] or theme.fg, theme.bg
    end
    if over and cell.flag and not cell.mine then return "X", theme.bad, theme.bg end
    if cell.flag then return "F", over and theme.good or theme.bad, HIDDEN_BG end
    if over and cell.mine then return "*", theme.bad, theme.bg end
    return ".", theme.dim, HIDDEN_BG
end

-- Play one game, recording a best time as soon as it's won. Returns whether to play another.
local function play(level, best)
    local b = board.new(level.cols, level.rows, level.mines)
    local width, height = term.getSize()
    local cellWidth = level.cols * 2 <= width and 2 or 1
    local left = math.floor((width - level.cols * cellWidth) / 2) + 1
    local top = 2 + math.floor((height - 2 - level.rows) / 2)
    local cursorX, cursorY = math.ceil(level.cols / 2), math.ceil(level.rows / 2)
    local started, finished

    local function over() return b.state == "won" or b.state == "lost" end
    local function elapsed()
        return started and math.floor((finished or os.clock()) - started) or 0
    end

    local function drawCell(x, y)
        local text, fg, bg = look(board.cell(b, x, y), over())
        if x == cursorX and y == cursorY and not over() then fg, bg = theme.selectFg, theme.selectBg end
        ui.at(left + (x - 1) * cellWidth, top + y - 1, text .. (" "):rep(cellWidth - 1), fg, bg)
    end

    local function drawBoard()
        for y = 1, b.rows do
            for x = 1, b.cols do drawCell(x, y) end
        end
    end

    local function drawStatus()
        local text = (b.mines - b.flags) .. " left " .. clock(elapsed())
        ui.at(width - 13, 1, ("%13s"):format(text), theme.barFg, theme.barBg)
    end

    local function drawFooter(text, color)
        ui.at(1, height, (" %-" .. (width - 1) .. "s"):format(text), color or theme.dim)
    end

    ui.screen(TITLE)
    term.setCursorBlink(false)
    drawBoard()
    drawStatus()
    drawFooter("Space:open F:flag Q:menu")

    local function moveCursor(dx, dy)
        local oldX, oldY = cursorX, cursorY
        cursorX = (cursorX + dx - 1) % b.cols + 1
        cursorY = (cursorY + dy - 1) % b.rows + 1
        drawCell(oldX, oldY)
        drawCell(cursorX, cursorY)
    end

    -- Do a move, then start or stop the clock if it started or ended the game.
    local function act(move)
        local before = b.state
        move(b, cursorX, cursorY)
        if b.state == "playing" and before == "ready" then started = os.clock() end
        if over() then finished = os.clock() end
        drawBoard()
        drawStatus()
        if b.state == "lost" then
            drawFooter("Boom! R:again Q:menu", theme.bad)
        elseif b.state == "won" then
            local record = not best[level.key] or elapsed() < best[level.key]
            if record then
                best[level.key] = elapsed()
                -- If this can't be saved, the time still counts until the app closes.
                util.writeTable(BEST_FILE, best)
            end
            drawFooter((record and "New best!" or "You won!") .. " R:again Q:menu", theme.good)
        end
    end

    local function openOrChord()
        act(board.cell(b, cursorX, cursorY).open and board.chord or board.open)
    end

    local tick = os.startTimer(1)
    while true do
        local event, a, x, y = os.pullEvent()
        if event == "timer" and a == tick and not over() then
            tick = os.startTimer(1)
            drawStatus()
        elseif event == "key" then
            if a == keys.q or a == keys.backspace then
                return false
            elseif a == keys.r then
                return true
            elseif over() then -- only leaving or starting again is left to do
            elseif a == keys.left then moveCursor(-1, 0)
            elseif a == keys.right then moveCursor(1, 0)
            elseif a == keys.up then moveCursor(0, -1)
            elseif a == keys.down then moveCursor(0, 1)
            elseif a == keys.f then act(board.flag)
            elseif a == keys.space or a == keys.enter or a == keys.numPadEnter then openOrChord()
            end
        elseif event == "mouse_click" and not over() then
            local cellX = math.floor((x - left) / cellWidth) + 1
            local cellY = y - top + 1
            if board.cell(b, cellX, cellY) then
                moveCursor(cellX - cursorX, cellY - cursorY)
                if a == 1 then openOrChord()
                elseif a == 2 then act(board.flag)
                else act(board.chord)
                end
            end
        end
    end
end

local best = util.readTable(BEST_FILE) or {}
local selected = 1
while true do
    local items = {}
    for i, level in ipairs(LEVELS) do
        local size = fitted(level)
        local hint = size.cols .. "x" .. size.rows .. ", " .. size.mines .. " mines"
        if best[size.key] then hint = hint .. ", best " .. clock(best[size.key]) end
        items[i] = { label = level.label, hint = hint }
    end
    items[#items + 1] = { label = "Quit" }

    local choice = ui.menu({ title = TITLE, items = items, selected = selected, back = true })
    if not choice or choice == #items then return end
    selected = choice

    local level = fitted(LEVELS[choice])
    while play(level, best) do end
end
