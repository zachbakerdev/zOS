-- Tests the rules of Minesweeper, then drives the real app with scripted keys and clicks.
-- Run from the repository root: luajit tests/test_minesweeper.lua
package.path = "tests/?.lua;" .. package.path

local sim = require("sim")

local failed, passed = 0, 0
local function check(name, ok)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name)
  end
end

local board = assert(loadfile("apps/minesweeper/board.lua"))()

-- The rules ---------------------------------------------------------------------------------------

local function laid(cols, rows, list)
  local b = board.new(cols, rows, #list)
  board.layMines(b, list)
  return b
end

for seed = 1, 200 do
  math.randomseed(seed)
  local x, y = math.random(1, 9), math.random(1, 9)
  local b = board.new(9, 9, 10)
  board.open(b, x, y)
  local mines = 0
  for _, cell in ipairs(b.cells) do
    if cell.mine then mines = mines + 1 end
  end
  check("lays every mine", mines == 10)
  check("first cell is safe", b.state ~= "lost" and board.cell(b, x, y).count == 0)
end

do
  -- 8 of 9 cells mined: there's no room to clear the neighbours, but the first cell stays safe.
  local b = board.new(3, 3, 8)
  board.open(b, 2, 2)
  check("crowded board: first cell is safe", board.cell(b, 2, 2).open and not board.cell(b, 2, 2).mine)
  check("crowded board: that wins it", b.state == "won")
end

do
  local b = laid(3, 3, { { 1, 1 }, { 3, 3 } })
  check("counts corners", board.cell(b, 2, 2).count == 2)
  check("counts edges", board.cell(b, 2, 1).count == 1)
  check("doesn't count far mines", board.cell(b, 3, 1).count == 0)
end

do
  local b = laid(5, 5, { { 1, 1 } })
  board.flag(b, 5, 5)
  board.open(b, 3, 3)
  check("floods open", board.cell(b, 5, 1).open and board.cell(b, 1, 5).open)
  check("flood stops at numbers", board.cell(b, 2, 2).open and not board.cell(b, 1, 1).open)
  check("flood leaves flags", not board.cell(b, 5, 5).open and b.state == "playing")
  board.flag(b, 5, 5)
  board.open(b, 5, 5)
  check("opening the last safe cell wins", b.state == "won")
  check("winning flags the mines", board.cell(b, 1, 1).flag and b.flags == 1)
end

do
  local b = laid(3, 3, { { 1, 1 } })
  board.flag(b, 1, 1)
  board.open(b, 1, 1)
  check("a flag protects its cell", b.state == "playing" and not board.cell(b, 1, 1).open)
  board.flag(b, 1, 1)
  check("flags come off", b.flags == 0)
  board.open(b, 1, 1)
  check("opening a mine loses", b.state == "lost")
  board.flag(b, 2, 2)
  board.open(b, 3, 3)
  check("nothing happens after the end", b.flags == 0 and b.opened == 0)
end

do
  local b = laid(3, 1, { { 3, 1 } })
  board.open(b, 2, 1)
  board.chord(b, 2, 1)
  check("chord needs enough flags", not board.cell(b, 1, 1).open)
  board.flag(b, 3, 1)
  board.chord(b, 2, 1)
  check("chord opens the rest", board.cell(b, 1, 1).open and b.state == "won")
end

do
  local b = laid(3, 1, { { 3, 1 } })
  board.open(b, 2, 1)
  board.flag(b, 1, 1)
  board.chord(b, 2, 1)
  check("chord on a wrong flag loses", b.state == "lost")
end

do
  check("fit leaves a board that fits alone", select(3, board.fit(9, 9, 10, 51, 17)) == 10)
  local cols, rows, mines = board.fit(30, 16, 99, 26, 18)
  check("fit shrinks for pocket computers", cols == 26 and rows == 16 and mines == 85)
  cols, rows, mines = board.fit(30, 16, 99, 39, 11)
  check("fit shrinks for turtles", cols == 30 and rows == 11 and mines == 68)
end

-- The app -----------------------------------------------------------------------------------------

local function screenHas(c, text)
  local ok, err = pcall(sim.run, function() return c.screenText():find(text, 1, true) ~= nil end, 30)
  if not ok then
    print("Waiting for '" .. text .. "', the screen says:\n" .. c.screenText())
    error(err, 0)
  end
  return true
end

local function key(c, name) c.env.os.queueEvent("key", c.env.keys[name]) end
local function click(c, button, x, y) c.env.os.queueEvent("mouse_click", button, x, y) end
local function settle() sim.advance(0.1) end

-- A computer running Minesweeper. c.boards lists the boards it has made, newest last.
local function start(files, width)
  for _, other in pairs(sim.computers) do sim.powerOff(other) end
  local c = sim.computer(1, { files = files or {}, width = width })
  c.appDir = "apps/minesweeper/"
  local real = c.env.require("board")
  local new = real.new
  c.boards = {}
  real.new = function(...)
    local b = new(...)
    c.boards[#c.boards + 1] = b
    return b
  end
  local fn = assert(loadfile("apps/minesweeper/main.lua"))
  setfenv(fn, c.env)
  c.thread = sim.spawn(c, fn, { user = "me", admin = false }, { id = "minesweeper" })
  return c
end

-- The screen position of a cell on the Easy board of a 51 wide computer, which uses wide cells.
local function easySpot(x, y) return 16 + (x - 1) * 2 + 1, 6 + y - 1 end

-- Choose Easy and open the cell in the middle with the keyboard.
local function startEasy(c)
  screenHas(c, "Easy")
  key(c, "enter")
  screenHas(c, "10 left")
  key(c, "space")
  settle()
  return c.boards[#c.boards]
end

-- Open every safe cell with the mouse.
local function clear(c, b)
  for y = 1, b.rows do
    for x = 1, b.cols do
      if not board.cell(b, x, y).mine and not board.cell(b, x, y).open then
        click(c, 1, easySpot(x, y))
        settle()
      end
    end
  end
end

do
  local c = start()
  local b = startEasy(c)
  check("game: keyboard opens a safe first cell", board.cell(b, 5, 5).open and b.state == "playing")
  check("game: keeps the title", c.screenText():find("Minesweeper", 1, true) ~= nil)
  check("game: draws closed cells", c.screenText():find(". . ", 1, true) ~= nil)

  sim.advance(5)
  check("game: the clock runs", c.screenText():find("0:0[456]") ~= nil)

  -- Walk to a closed cell and flag it, wrapping left around the edge of the board on the way.
  local flagged
  for y = 1, b.rows do
    for x = 1, b.cols do
      if not flagged and not board.cell(b, x, y).open then flagged = { x, y } end
    end
  end
  for _ = 1, (5 - flagged[1]) % 9 do key(c, "left") end
  for _ = 1, (5 - flagged[2]) % 9 do key(c, "up") end
  key(c, "f")
  settle()
  check("game: F flags the cursor's cell", board.cell(b, flagged[1], flagged[2]).flag)
  screenHas(c, "9 left")
  key(c, "f")
  settle()

  click(c, 2, easySpot(flagged[1], flagged[2]))
  settle()
  check("game: right click flags", board.cell(b, flagged[1], flagged[2]).flag)
  click(c, 2, easySpot(flagged[1], flagged[2]))
  settle()
  click(c, 2, 1, 1)
  settle()
  check("game: clicks off the board do nothing", b.flags == 0)

  clear(c, b)
  check("game: clicks win the game", b.state == "won")
  screenHas(c, "New best!")
  check("game: a best time is saved before leaving the board",
    c.env.require("util").readTable("/home/me/.config/minesweeper/best") ~= nil)
  local shown = c.screenText()
  sim.advance(3)
  check("game: the clock stops at the end", c.screenText() == shown)
  key(c, "q")
  screenHas(c, ", best 0:")
  local saved = c.env.require("util").readTable("/home/me/.config/minesweeper/best")
  check("game: saves the best time for the user", saved and saved["9x9x10"] ~= nil)

  local firstBest = saved["9x9x10"]
  key(c, "enter")
  screenHas(c, "10 left")
  key(c, "space")
  settle()
  b = c.boards[#c.boards]
  sim.advance(firstBest + 10)
  clear(c, b)
  screenHas(c, "You won!")
  key(c, "r")
  screenHas(c, "10 left")
  check("game: R starts a new board", #c.boards == 3)
  key(c, "backspace")
  screenHas(c, "Quit")
  check("game: a slower win keeps the record",
    c.env.require("util").readTable("/home/me/.config/minesweeper/best")["9x9x10"] == firstBest)

  key(c, "backspace")
  sim.run(function() return c.thread.done end, 30)
  check("game: backspace leaves the menu", c.thread.done)
end

do
  local c = start()
  local b = startEasy(c)
  local mine
  for y = 1, b.rows do
    for x = 1, b.cols do
      if board.cell(b, x, y).mine then mine = mine or { x, y } end
    end
  end
  click(c, 1, easySpot(mine[1], mine[2]))
  screenHas(c, "Boom!")
  check("lose: shows the mines", select(2, c.screenText():gsub("%*", "")) == 10)
  local opened = b.opened
  click(c, 1, easySpot(1, 1))
  key(c, "space")
  settle()
  check("lose: the board stops taking moves", b.opened == opened)
  key(c, "q")
  screenHas(c, "Quit")
  check("lose: no best time", c.env.require("util").readTable("/home/me/.config/minesweeper/best") == nil)
end

do
  local c = start({}, 26)
  screenHas(c, "Hard")
  key(c, "up")
  key(c, "up")
  screenHas(c, "26x16, 85 mines")
  key(c, "enter")
  screenHas(c, "85 left")
  check("pocket: keeps the title", c.screenText():find("Minesweeper", 1, true) ~= nil)
  local b = c.boards[#c.boards]
  check("pocket: the board is cut down to fit", b.cols == 26 and b.rows == 16)
  for line in (c.screenText() .. "\n"):gmatch("(.-)\n") do
    check("pocket: nothing runs off the screen", #line <= 26)
  end
  screenHas(c, "Space:open F:flag Q:menu")
  key(c, "q")
  screenHas(c, "Quit")
end

print(passed .. " passed, " .. failed .. " failed")
os.exit(failed == 0 and 0 or 1)
