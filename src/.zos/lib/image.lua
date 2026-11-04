-- Reading zos.tar.gz system images. See specs/formats/TGZ_FORMAT.md.

local tar = require("tar")

local image = {}

-- CC: Tweaked counts each file and folder as at least this many bytes.
local MIN_FILE_SIZE = 500

function image.validPath(path)
    if type(path) ~= "string" or #path > 129 or not path:match("^/.") then return false end
    if path:sub(-1) == "/" then return false end
    for part in (path:sub(2) .. "/"):gmatch("(.-)/") do
        if not part:match("^[%w_%.%-]+$") or part:match("^%.+$") then return false end
    end
    local top = path:match("^/([^/]+)")
    return top ~= "rom" and not top:match("^disk%d*$")
end

-- A path that's used as both a file and a folder, or nil. Paths may be absolute or relative.
function image.clash(files)
    for path in pairs(files) do
        local parent = path
        while true do
            parent = parent:match("^(.*)/[^/]*$")
            if not parent or parent == "" then break end
            if files[parent] then return parent end
        end
    end
end

-- The files of an image as (path -> data), or nil and a reason.
function image.parse(data)
    if type(data) ~= "string" or data:sub(1, 2) ~= "\31\139" then
        return nil, "This isn't a .tar.gz file."
    end
    local entries, err = tar.parse(data)
    if not entries then return nil, "The image is damaged: " .. tostring(err) end
    local files = {}
    for _, entry in ipairs(entries) do
        local name = entry.name:gsub("^%./", "")
        local kind = entry.typeflag
        if kind ~= "0" and kind ~= "\0" and kind ~= "5" then
            return nil, "The image contains something that isn't a file or folder: " .. entry.name
        end
        if entry.type ~= "directory" then
            local path = "/" .. name
            if not image.validPath(path) then
                return nil, "The image contains a bad file name: " .. entry.name
            end
            if files[path] then return nil, "The image contains " .. path .. " twice." end
            files[path] = entry.data
        end
    end
    local bad = image.clash(files)
    if bad then return nil, "The image uses " .. bad .. " as both a file and a folder." end
    for path, contents in pairs(files) do
        if path:match("%.lua$") then
            local fn, why = load(contents, "@" .. path, "t", {})
            if not fn then return nil, "A file in the image doesn't compile: " .. tostring(why) end
        end
    end
    return files
end

-- The bytes the files take up on disk, including their folders.
function image.spaceNeeded(files)
    local total, dirs = 0, {}
    for path, contents in pairs(files) do
        total = total + math.max(#contents, MIN_FILE_SIZE)
        local parent = path:match("^(.*)/[^/]*$")
        while parent and parent ~= "" and not dirs[parent] do
            dirs[parent] = true
            total = total + MIN_FILE_SIZE
            parent = parent:match("^(.*)/[^/]*$")
        end
    end
    return total
end

return image
