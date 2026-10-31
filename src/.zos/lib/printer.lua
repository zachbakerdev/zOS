-- Printing text across as many pages as it needs.

local ui = require("ui")

local printer = {}

local WIDTH, HEIGHT = 25, 21

local function find()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "printer" then return name end
    end
end

function printer.available()
    return find() ~= nil
end

-- Text as pages of lines. Blank lines separate sections, which stay whole if they fit on a page.
local function paginate(text)
    local pages, page = {}, {}
    for section in (text .. "\n\n"):gmatch("(.-)\n\n") do
        local lines = ui.wrap(section, WIDTH)
        local needed = #lines + (#page > 0 and 1 or 0)
        if #page + needed > HEIGHT and #page > 0 then
            pages[#pages + 1] = page
            page = {}
        elseif #page > 0 then
            page[#page + 1] = ""
        end
        for _, line in ipairs(lines) do
            if #page == HEIGHT then
                pages[#pages + 1] = page
                page = {}
            end
            page[#page + 1] = line
        end
    end
    if #page > 0 then pages[#pages + 1] = page end
    return pages
end

-- Print text. Returns true, or nil and a reason.
function printer.print(title, text)
    local name = find()
    if not name then return nil, "There's no printer.\nAttach one and try again." end
    local pages = paginate(text)
    if peripheral.call(name, "getPaperLevel") < #pages then return nil, "The printer needs paper." end
    if peripheral.call(name, "getInkLevel") < #pages then return nil, "The printer needs ink." end

    for number, lines in ipairs(pages) do
        if not peripheral.call(name, "newPage") then return nil, "The printer couldn't start a page." end
        peripheral.call(name, "setPageTitle", title .. (#pages > 1 and (" " .. number .. "/" .. #pages) or ""))
        for row, line in ipairs(lines) do
            peripheral.call(name, "setCursorPos", 1, row)
            peripheral.call(name, "write", line)
        end
        if not peripheral.call(name, "endPage") then
            return nil, ("The output tray filled up after %d of %d pages. Empty it and print again."):format(
                number - 1, #pages)
        end
    end
    return true
end

return printer
