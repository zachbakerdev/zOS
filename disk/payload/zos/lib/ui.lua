-- Small terminal UI toolkit shared by the zOS system, its apps and the installer.

local ui = {}

-- Basic computers only render greyscale, so fall back to safe colours there.
local colour = term.isColour()
local function pick(c, mono) if colour then return c end return mono end

ui.theme = {
  bg = colors.black,
  fg = colors.white,
  barBg = pick(colors.blue, colors.white),
  barFg = pick(colors.white, colors.black),
  selBg = pick(colors.cyan, colors.white),
  selFg = colors.black,
  dim = colors.lightGray,
  accent = pick(colors.yellow, colors.white),
  bad = pick(colors.red, colors.white),
  good = pick(colors.lime, colors.white),
}

function ui.at(x, y, text, fg, bg)
  term.setCursorPos(x, y)
  if fg then term.setTextColor(fg) end
  if bg then term.setBackgroundColor(bg) end
  term.write(text)
end

function ui.center(y, text, fg, bg)
  local w = term.getSize()
  ui.at(math.max(1, math.floor((w - #text) / 2) + 1), y, text, fg, bg)
end

-- Draw a full-width bar with text on the left and (optionally) the right.
function ui.bar(y, left, right, fg, bg)
  local w = term.getSize()
  term.setCursorPos(1, y)
  term.setBackgroundColor(bg or ui.theme.barBg)
  term.setTextColor(fg or ui.theme.barFg)
  term.clearLine()
  term.write(" " .. (left or ""))
  if right and #right > 0 then
    term.setCursorPos(math.max(1, w - #right), y)
    term.write(right)
  end
  term.setBackgroundColor(ui.theme.bg)
  term.setTextColor(ui.theme.fg)
end

-- Clear the screen, draw the title bar and park the cursor on line 3.
function ui.screen(title, right)
  term.setBackgroundColor(ui.theme.bg)
  term.setTextColor(ui.theme.fg)
  term.clear()
  ui.bar(1, title, right)
  term.setCursorPos(2, 3)
end

function ui.wrap(text, width)
  local lines = {}
  for para in (text .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in para:gmatch("%S+") do
      if #line == 0 then
        line = word
      elseif #line + 1 + #word <= width then
        line = line .. " " .. word
      else
        lines[#lines + 1] = line
        line = word
      end
      while #line > width do
        lines[#lines + 1] = line:sub(1, width)
        line = line:sub(width + 1)
      end
    end
    lines[#lines + 1] = line
  end
  return lines
end

-- Write wrapped text at the cursor (with a 1 column margin) and move to the next line.
function ui.text(text, fg)
  local w = term.getSize()
  local _, y = term.getCursorPos()
  term.setBackgroundColor(ui.theme.bg)
  term.setTextColor(fg or ui.theme.fg)
  for _, line in ipairs(ui.wrap(text or "", w - 2)) do
    term.setCursorPos(2, y)
    term.write(line)
    y = y + 1
  end
  term.setCursorPos(2, y)
  term.setTextColor(ui.theme.fg)
end

-- Prompt for a line of input. `mask` hides typed characters (e.g. "*").
function ui.input(label, mask, default)
  if label then ui.text(label, ui.theme.accent) end
  local _, y = term.getCursorPos()
  term.setCursorPos(2, y)
  term.setTextColor(ui.theme.dim)
  term.write("> ")
  term.setTextColor(ui.theme.fg)
  local value = read(mask, nil, nil, default)
  local _, ny = term.getCursorPos()
  term.setCursorPos(2, ny)
  return value
end

-- Wait for Enter (or a click). Enter is used because it doesn't emit a
-- `char` event that could leak into the next read().
function ui.waitEnter(text)
  ui.text(text or "Press Enter to continue.", ui.theme.dim)
  while true do
    local e, k = os.pullEventRaw()
    if (e == "key" and (k == keys.enter or k == keys.numPadEnter)) or e == "mouse_click" then return end
  end
end

function ui.message(title, text, colour)
  ui.screen(title)
  ui.text(text, colour)
  ui.text("")
  ui.waitEnter()
end

-- Ask a yes/no question on the current screen.
function ui.confirm(question)
  ui.text(question .. " [y/n]", ui.theme.accent)
  while true do
    local _, ch = os.pullEventRaw("char")
    ch = ch:lower()
    if ch == "y" or ch == "n" then
      ui.text(ch == "y" and "Yes" or "No", ui.theme.dim)
      return ch == "y"
    end
  end
end

--[[ Scrollable selection list.
  opts.title   title bar text
  opts.status  function returning text for the right of the title bar (refreshed every second)
  opts.items   { { label = "...", hint = "...", fg = colour }, ... }
  opts.selected initially selected index
  opts.back    allow Backspace to return nil
  Returns the chosen index, or nil if the user went back. ]]
function ui.menu(opts)
  local items, t = opts.items, ui.theme
  local sel = math.max(1, math.min(opts.selected or 1, #items))
  local scroll, top = 0, 3
  local timer = os.startTimer(1)

  local function draw()
    local w, h = term.getSize()
    local rows = h - 4
    if sel - scroll > rows then scroll = sel - rows end
    if sel <= scroll then scroll = sel - 1 end

    term.setBackgroundColor(t.bg)
    term.clear()
    ui.bar(1, opts.title, opts.status and opts.status())
    for i = 1, rows do
      local idx = scroll + i
      local item = items[idx]
      if item then
        local y = top + i - 1
        term.setCursorPos(1, y)
        if idx == sel then
          term.setBackgroundColor(t.selBg)
          term.clearLine()
          ui.at(2, y, "> " .. item.label, t.selFg)
        else
          term.setBackgroundColor(t.bg)
          ui.at(2, y, "  " .. item.label, item.fg or t.fg)
        end
      end
    end
    term.setBackgroundColor(t.bg)
    if scroll > 0 then ui.at(w - 1, top, "^", t.dim) end
    if scroll + rows < #items then ui.at(w - 1, top + rows - 1, "v", t.dim) end

    local hint = items[sel] and items[sel].hint
    local keysHelp = opts.back and "Enter: open  Bksp: back" or "Enter: open"
    ui.bar(h, (hint and #hint > 0) and hint or keysHelp, nil, t.dim, t.bg)
    return rows
  end

  while true do
    local rows = draw()
    local e, a, _, y = os.pullEventRaw()
    if e == "key" then
      if a == keys.up then sel = sel > 1 and sel - 1 or #items
      elseif a == keys.down then sel = sel < #items and sel + 1 or 1
      elseif a == keys.home then sel = 1
      elseif a == keys["end"] then sel = #items
      elseif a == keys.enter or a == keys.numPadEnter then return sel
      elseif a == keys.backspace and opts.back then return nil
      end
    elseif e == "mouse_click" then
      local idx = scroll + y - top + 1
      if y >= top and y < top + rows and items[idx] then return idx end
    elseif e == "mouse_scroll" then
      sel = math.max(1, math.min(#items, sel + a))
    elseif e == "timer" and a == timer then
      timer = os.startTimer(1)
    end
  end
end

-- Scrollable read-only text view. `actions` maps lowercase characters to return
-- values (e.g. { r = "reply" }). Backspace or q returns nil.
function ui.pager(title, text, help, actions)
  actions = actions or {}
  local scroll = 0
  while true do
    local w, h = term.getSize()
    local lines = ui.wrap(text, w - 2)
    local rows = h - 3
    scroll = math.max(0, math.min(scroll, #lines - rows))

    term.setBackgroundColor(ui.theme.bg)
    term.clear()
    ui.bar(1, title)
    for i = 1, rows do
      if lines[scroll + i] then ui.at(2, 2 + i, lines[scroll + i], ui.theme.fg) end
    end
    if scroll + rows < #lines then ui.at(w - 1, h - 1, "v", ui.theme.dim) end
    ui.bar(h, help or "Up/Down: scroll  Q: back", nil, ui.theme.dim, ui.theme.bg)

    local e, a = os.pullEventRaw()
    if e == "key" then
      if a == keys.up then scroll = scroll - 1
      elseif a == keys.down then scroll = scroll + 1
      elseif a == keys.pageUp then scroll = scroll - rows
      elseif a == keys.pageDown then scroll = scroll + rows
      elseif a == keys.backspace then return nil
      end
    elseif e == "char" then
      a = a:lower()
      if a == "q" then return nil end
      if actions[a] ~= nil then return actions[a] end
    elseif e == "mouse_scroll" then
      scroll = scroll + a
    end
  end
end

-- Prompt for a new username until `validate(name)` accepts it.
-- `redraw` repaints the surrounding screen before each attempt.
function ui.newUsername(validate, redraw, default)
  local err
  while true do
    redraw()
    if err then ui.text(err, ui.theme.bad) ui.text("") end
    local name = ui.input("Username", nil, default)
    local ok, why = validate(name)
    if ok then return name end
    err = why
  end
end

-- Prompt for a new password (entered twice) until it is valid and matches.
function ui.newPassword(validate, redraw, label)
  local err
  while true do
    redraw()
    if err then ui.text(err, ui.theme.bad) ui.text("") end
    local p1 = ui.input(label or "Choose a password", "*")
    local ok, why = validate(p1)
    if ok then
      local p2 = ui.input("Type it again to confirm", "*")
      if p1 == p2 then return p1 end
      why = "Passwords do not match."
    end
    err = why
  end
end

return ui
