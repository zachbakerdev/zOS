-- Printing plain text on an attached printer. Sections, separated by blank lines, stay on one
-- page if they can, so that a label doesn't end up on a different page from its value.

local ui = require("ui")

local printer = {}

-- The size of a printed page. Printers only report this once a page has been started, which is
-- too late to count the pages a document needs.
local WIDTH, HEIGHT = 25, 21

function printer.find()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "printer" then return name end
    end
end

local function paginate(text)
    local pages, page = {}, {}
    for section in (text .. "\n\n"):gmatch("(.-)\n\n") do
        local lines = ui.wrap(section, WIDTH)
        if #page > 0 and #page + 1 + #lines > HEIGHT then
            pages[#pages + 1] = page
            page = {}
        end
        if #page > 0 then page[#page + 1] = "" end
        for _, line in ipairs(lines) do
            if #page == HEIGHT then
                pages[#pages + 1] = page
                page = {}
            end
            page[#page + 1] = line
        end
    end
    pages[#pages + 1] = page
    return pages
end

-- Print a document. Returns the number of pages, or nil and a reason. Checks for enough paper
-- and ink first, so that a document doesn't stop halfway because of them.
function printer.print(title, text)
    local name = printer.find()
    if not name then return nil, "This computer has no printer. Attach one and try again." end

    local pages = paginate(text)
    local need = #pages .. (#pages == 1 and " page" or " pages")
    if peripheral.call(name, "getPaperLevel") < #pages then
        return nil, "The printer needs paper for " .. need .. "."
    elseif peripheral.call(name, "getInkLevel") < #pages then
        return nil, "The printer needs ink for " .. need .. "."
    end

    for i, page in ipairs(pages) do
        local started = peripheral.call(name, "newPage")
        if started then
            peripheral.call(name, "setPageTitle", #pages > 1 and (title .. " " .. i .. "/" .. #pages) or title)
            for y, line in ipairs(page) do
                peripheral.call(name, "setCursorPos", 1, y)
                peripheral.call(name, "write", line)
            end
        end
        if not started or not peripheral.call(name, "endPage") then
            return nil, "The printer stopped after " .. (i - 1) .. " of " .. need ..
                ". Empty its output tray and try again."
        end
    end
    return #pages
end

return printer
