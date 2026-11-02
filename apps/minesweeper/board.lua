-- The rules of Minesweeper. Nothing here touches the screen.

local board = {}

local function cellAt(b, x, y)
    if x < 1 or y < 1 or x > b.cols or y > b.rows then return nil end
    return b.cells[(y - 1) * b.cols + x]
end
board.cell = cellAt

-- Call fn(cell, x, y) for each cell around x, y.
local function neighbours(b, x, y, fn)
    for dy = -1, 1 do
        for dx = -1, 1 do
            local cell = (dx ~= 0 or dy ~= 0) and cellAt(b, x + dx, y + dy)
            if cell then fn(cell, x + dx, y + dy) end
        end
    end
end

-- The largest board of up to cols by rows that fits, with the same share of mines as the full one.
function board.fit(cols, rows, mines, maxCols, maxRows)
    local fitCols, fitRows = math.min(cols, maxCols), math.min(rows, maxRows)
    return fitCols, fitRows, math.floor(mines * (fitCols * fitRows) / (cols * rows))
end

-- state is "ready" until the first cell is opened, then "playing", then "won" or "lost".
function board.new(cols, rows, mines)
    local b = { cols = cols, rows = rows, mines = mines, flags = 0, opened = 0, state = "ready", cells = {} }
    for i = 1, cols * rows do
        b.cells[i] = { mine = false, open = false, flag = false, count = 0 }
    end
    return b
end

-- Put mines on a list of { x, y }, and start the game.
function board.layMines(b, list)
    for _, spot in ipairs(list) do
        cellAt(b, spot[1], spot[2]).mine = true
    end
    for y = 1, b.rows do
        for x = 1, b.cols do
            neighbours(b, x, y, function(other)
                if other.mine then
                    local cell = cellAt(b, x, y)
                    cell.count = cell.count + 1
                end
            end)
        end
    end
    b.state = "playing"
end

-- Scatter the mines, keeping them off the first cell and, if there's room, the cells around it, so
-- the first move always opens an area to work from.
local function scatter(b, firstX, firstY)
    local spots
    local function collect(keepClear)
        spots = {}
        for y = 1, b.rows do
            for x = 1, b.cols do
                if not keepClear(x, y) then spots[#spots + 1] = { x, y } end
            end
        end
    end
    collect(function(x, y) return math.abs(x - firstX) <= 1 and math.abs(y - firstY) <= 1 end)
    if #spots < b.mines then
        collect(function(x, y) return x == firstX and y == firstY end)
    end
    local chosen = {}
    for i = 1, b.mines do
        local j = math.random(i, #spots)
        spots[i], spots[j] = spots[j], spots[i]
        chosen[i] = spots[i]
    end
    board.layMines(b, chosen)
end

local function win(b)
    b.state = "won"
    b.flags = b.mines
    for _, cell in ipairs(b.cells) do
        cell.flag = cell.mine
    end
end

-- Open a cell. A cell with no mines around it opens its neighbours too, without touching flags.
function board.open(b, x, y)
    if b.state == "won" or b.state == "lost" then return end
    local cell = cellAt(b, x, y)
    if not cell or cell.open or cell.flag then return end
    if b.state == "ready" then scatter(b, x, y) end

    if cell.mine then
        cell.open = true
        b.state = "lost"
        return
    end

    local stack = { { x, y } }
    while #stack > 0 do
        local spot = table.remove(stack)
        local current = cellAt(b, spot[1], spot[2])
        if not current.open and not current.flag then
            current.open = true
            b.opened = b.opened + 1
            if current.count == 0 then
                neighbours(b, spot[1], spot[2], function(other, nx, ny)
                    if not other.open and not other.flag then stack[#stack + 1] = { nx, ny } end
                end)
            end
        end
    end
    if b.opened == b.cols * b.rows - b.mines then win(b) end
end

function board.flag(b, x, y)
    if b.state == "won" or b.state == "lost" then return end
    local cell = cellAt(b, x, y)
    if not cell or cell.open then return end
    cell.flag = not cell.flag
    b.flags = b.flags + (cell.flag and 1 or -1)
end

-- On an open number with that many flags around it, open everything else around it.
function board.chord(b, x, y)
    local cell = cellAt(b, x, y)
    if not cell or not cell.open or cell.mine or cell.count == 0 then return end
    local flags = 0
    neighbours(b, x, y, function(other)
        if other.flag then flags = flags + 1 end
    end)
    if flags ~= cell.count then return end
    neighbours(b, x, y, function(_, nx, ny) board.open(b, nx, ny) end)
end

return board
