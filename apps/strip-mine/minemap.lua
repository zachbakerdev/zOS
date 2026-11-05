--[[ A top-down map of a mine, drawn from jobs.mapData. Forward is up the screen: the corridor runs
up the middle, or along one edge when branches only go one way, and each row is one slot of
branches, with the chest in the bottom row. Branches are scaled to fit, the longest across the
room there is. When there are more slots than rows, it shows the ones around the turtle. ]]

local ui = require("ui")

local minemap = {}

minemap.LEGEND = "=dug -to dig @turtle"

-- Draws the map over rows top to bottom of the screen.
function minemap.draw(data, top, bottom)
    local width = term.getSize()
    if not data then
        ui.at(2, top, "Nothing dug here yet.", ui.theme.dim)
        return
    end
    local rows = bottom - top + 1
    if rows < 2 then return end

    local cx
    if data.side == "right" then
        cx = 2
    elseif data.side == "left" then
        cx = width - 1
    else
        cx = math.floor((width + 1) / 2)
    end
    local room
    if data.side == "right" then
        room = width - 1 - cx
    elseif data.side == "left" then
        room = cx - 2
    else
        room = math.min(cx - 2, width - 1 - cx)
    end
    local longest = 1
    for _, s in ipairs(data.slots) do
        for i = 1, 4 do longest = math.max(longest, s[i]) end
    end
    local function cells(length)
        if length <= 0 then return 0 end
        return math.max(1, math.floor(length * room / longest + 0.5))
    end

    -- The slot the turtle is nearest, with 0 meaning by the chest.
    local pos, here = data.pos, nil
    if pos then here = math.max(0, math.floor(pos.z / data.pitch + 0.5)) end

    local count, show = #data.slots, rows - 1
    local lo = 1
    if count > show then
        local focus = here and math.max(here, 1) or count
        lo = math.max(1, math.min(focus - math.floor(show / 2), count - show + 1))
    end
    local hi = math.min(count, lo + show - 1)

    local good, dim, accent = ui.theme.good, ui.theme.dim, ui.theme.accent
    for k = lo, hi do
        local y = bottom - 1 - (k - lo)
        local s = data.slots[k]
        ui.at(cx, y, data.corridor >= k * data.pitch and "|" or ":", data.corridor >= k * data.pitch and good or dim)
        local leftDug, leftAll = cells(s[1]), cells(math.max(s[1], s[3]))
        if leftAll > 0 then
            ui.at(cx - leftAll, y, ("-"):rep(leftAll - leftDug), dim)
            ui.at(cx - leftDug, y, ("="):rep(leftDug), good)
        end
        local rightDug, rightAll = cells(s[2]), cells(math.max(s[2], s[4]))
        if rightAll > 0 then
            ui.at(cx + 1, y, ("="):rep(rightDug), good)
            ui.at(cx + 1 + rightDug, y, ("-"):rep(rightAll - rightDug), dim)
        end
    end
    if lo > 1 then ui.at(cx, bottom, "v", dim) else ui.at(cx, bottom, "#", accent) end
    if hi < count then ui.at(cx, top, "^", dim) end

    if pos and (here == 0 and lo == 1 or here >= lo and here <= hi) then
        local y = here == 0 and bottom or bottom - 1 - (here - lo)
        local along = math.abs(pos.x) - data.half
        local col = cx
        if along > 0 then col = pos.x < 0 and cx - cells(along) or cx + cells(along) end
        ui.at(col, y, "@", accent)
    end
end

return minemap
