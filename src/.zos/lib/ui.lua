-- The terminal UI toolkit: screens, wrapped text, menus, prompts and a pager.

local ui = {}

local colour = term.isColour and term.isColour()
ui.theme = {
    bg = colors.black,
    fg = colors.white,
    dim = colour and colors.lightGray or colors.white,
    accent = colour and colors.cyan or colors.white,
    good = colour and colors.lime or colors.white,
    bad = colour and colors.red or colors.white,
    barBg = colour and colors.blue or colors.white,
    barFg = colour and colors.white or colors.black,
    selectBg = colour and colors.cyan or colors.white,
    selectFg = colors.black,
}
local theme = ui.theme

local function resolve(value)
    if type(value) == "function" then return value() end
    return value
end

-- Text split into lines of at most width characters, breaking at spaces where it can.
function ui.wrap(text, width)
    local lines = {}
    for paragraph in (tostring(text) .. "\n"):gmatch("(.-)\n") do
        local line = ""
        for space, word in paragraph:gmatch("(%s*)(%S+)") do
            local joined = line == "" and word or line .. space .. word
            if #joined <= width then
                line = joined
            else
                if line ~= "" then lines[#lines + 1] = line end
                while #word > width do
                    lines[#lines + 1] = word:sub(1, width)
                    word = word:sub(width + 1)
                end
                line = word
            end
        end
        lines[#lines + 1] = line
    end
    return lines
end

function ui.at(x, y, text, fg, bg)
    term.setCursorPos(x, y)
    term.setTextColor(fg or theme.fg)
    term.setBackgroundColor(bg or theme.bg)
    term.write(text)
end

local function bar(y, left, right, fg, bg)
    local width = term.getSize()
    term.setCursorPos(1, y)
    term.setBackgroundColor(bg or theme.barBg)
    term.clearLine()
    right = right and tostring(right) or ""
    local room = width - 2 - (#right > 0 and #right + 1 or 0)
    if room < 8 then right, room = "", width - 2 end
    ui.at(2, y, tostring(left):sub(1, room), fg or theme.barFg, bg or theme.barBg)
    if right ~= "" then ui.at(width - #right, y, right, fg or theme.barFg, bg or theme.barBg) end
end

-- Clear the screen and draw its title bar, leaving the cursor where text starts.
function ui.screen(title, status)
    term.setBackgroundColor(theme.bg)
    term.setTextColor(theme.fg)
    term.clear()
    bar(1, title, resolve(status))
    term.setBackgroundColor(theme.bg)
    term.setCursorPos(2, 3)
end

-- Write wrapped text and move to the next line.
function ui.text(text, color)
    local width, height = term.getSize()
    local _, y = term.getCursorPos()
    for _, line in ipairs(ui.wrap(text, width - 2)) do
        if y > height then
            if term.scroll then term.scroll(1) end
            y = height
        end
        ui.at(2, y, line, color or theme.fg, theme.bg)
        y = y + 1
    end
    term.setCursorPos(2, y)
end

-- Ask for a line of text. mask hides what's typed. Returns "" if nothing was entered.
function ui.input(label, mask, default)
    if label then
        local width = term.getSize()
        if #label + 4 > width / 2 then
            ui.text(label, theme.dim)
            label = nil
        end
    end
    local _, y = term.getCursorPos()
    term.setCursorPos(2, y)
    term.setTextColor(theme.accent)
    term.setBackgroundColor(theme.bg)
    if label then term.write(label .. ": ") else term.write("> ") end
    term.setTextColor(theme.fg)
    term.setCursorBlink(true)
    local line = read(mask, nil, nil, default)
    term.setCursorBlink(false)
    term.setCursorPos(2, select(2, term.getCursorPos()))
    return line or ""
end

-- Ask for a line of text with its label on the line above. Otherwise as for ui.input.
function ui.field(label, mask, default)
    ui.text(label .. ":", theme.accent)
    return ui.input(nil, mask, default)
end

function ui.waitEnter(prompt)
    ui.text(prompt or "Press Enter to continue.", theme.dim)
    while true do
        local _, key = os.pullEvent("key")
        if key == keys.enter or key == keys.numPadEnter then return end
    end
end

-- Show text on its own screen until Enter is pressed.
function ui.message(title, text, color)
    ui.screen(title)
    ui.text(text, color)
    ui.text("")
    ui.waitEnter()
end

-- Ask a yes/no question. Y is yes, and N or Backspace is no.
function ui.confirm(question)
    ui.text(question, theme.accent)
    ui.text("Y: yes   N: no", theme.dim)
    while true do
        local event, value = os.pullEvent()
        if event == "char" then
            local c = value:lower()
            if c == "y" then return true end
            if c == "n" then return false end
        elseif event == "key" and value == keys.backspace then
            return false
        end
    end
end

-- A scrolling list. options: title, status, items ({ label, hint, fg }), selected, back.
-- Returns the chosen index, or nil if back is set and the user went back.
function ui.menu(options)
    local items = options.items
    local selected = math.max(1, math.min(options.selected or 1, #items))
    local top = 1

    while true do
        local width, height = term.getSize()
        local firstRow, lastRow = 3, height - 2
        local rows = math.max(1, lastRow - firstRow + 1)
        if selected < top then top = selected end
        if selected >= top + rows then top = selected - rows + 1 end

        ui.screen(options.title, options.status)
        for i = 0, rows - 1 do
            local item = items[top + i]
            if not item then break end
            local chosen = top + i == selected
            local fg = chosen and theme.selectFg or item.fg or theme.fg
            local bg = chosen and theme.selectBg or theme.bg
            local label = item.label:sub(1, width - 2)
            ui.at(1, firstRow + i, " " .. label .. string.rep(" ", width - #label - 1), fg, bg)
        end
        local hint = items[selected] and items[selected].hint
        if hint then ui.at(2, height, tostring(hint):sub(1, width - 2), theme.dim) end

        local event, a, _, y = os.pullEvent()
        if event == "key" then
            if a == keys.up then
                selected = selected > 1 and selected - 1 or #items
            elseif a == keys.down then
                selected = selected < #items and selected + 1 or 1
            elseif a == keys.pageUp then
                selected = math.max(1, selected - rows)
            elseif a == keys.pageDown then
                selected = math.min(#items, selected + rows)
            elseif a == keys.home then
                selected = 1
            elseif a == keys["end"] then
                selected = #items
            elseif a == keys.enter or a == keys.numPadEnter then
                return selected
            elseif a == keys.backspace and options.back then
                return nil
            end
        elseif event == "mouse_scroll" then
            selected = math.max(1, math.min(#items, selected + a))
        elseif event == "mouse_click" then
            local index = top + y - firstRow
            if y >= firstRow and y <= lastRow and items[index] then return index end
        end
    end
end

-- Show long text. Q or Backspace goes back. `actions` maps other characters to return values.
function ui.pager(title, text, footer, actions)
    local width, height = term.getSize()
    local lines = ui.wrap(text, width - 2)
    local rows = height - 3
    local top = 1
    local last = math.max(1, #lines - rows + 1)
    footer = footer or "Q: back"

    while true do
        ui.screen(title)
        for i = 0, rows - 1 do
            local line = lines[top + i]
            if line then ui.at(2, 3 + i, line) end
        end
        ui.at(2, height, footer:sub(1, width - 2), theme.dim)

        local event, value = os.pullEvent()
        if event == "key" then
            if value == keys.up then
                top = math.max(1, top - 1)
            elseif value == keys.down then
                top = math.min(last, top + 1)
            elseif value == keys.pageUp then
                top = math.max(1, top - rows)
            elseif value == keys.pageDown then
                top = math.min(last, top + rows)
            elseif value == keys.backspace then
                return nil
            end
        elseif event == "mouse_scroll" then
            top = math.max(1, math.min(last, top + value))
        elseif event == "char" then
            local c = value:lower()
            if actions and actions[c] then return actions[c] end
            if c == "q" then return nil end
        end
    end
end

return ui
