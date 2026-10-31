-- Reading .zi system images. See specs/formats/ZI_FORMAT.md.

local image = {}

image.FORMAT_VERSION = 1
image.METADATA = "zi:metadata"

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
function image.parse(text)
    if type(text) ~= "string" then return nil, "This isn't a .zi file." end
    local data = textutils.unserialize(text)
    if type(data) ~= "table" or type(data[image.METADATA]) ~= "table" then
        return nil, "This isn't a .zi file."
    end
    if data[image.METADATA].version ~= image.FORMAT_VERSION then
        return nil, "This image needs a newer version of zOS."
    end
    local files = {}
    for path, contents in pairs(data) do
        if path ~= image.METADATA then
            if type(path) ~= "string" or type(contents) ~= "string" then
                return nil, "The image contains a bad entry."
            end
            if not image.validPath(path) then
                return nil, "The image contains a bad file name: " .. path
            end
            files[path] = contents
        end
    end
    local bad = image.clash(files)
    if bad then return nil, "The image uses " .. bad .. " as both a file and a folder." end
    for path, contents in pairs(files) do
        if path:match("%.lua$") then
            local fn, err = load(contents, "@" .. path, "t", {})
            if not fn then return nil, "A file in the image doesn't compile: " .. tostring(err) end
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
