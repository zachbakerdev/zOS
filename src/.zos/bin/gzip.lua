-- gzip: compress and decompress files from the Terminal. See specs/ARCHIVES.md.

local ctx = _G.zos
if not ctx then error("gzip only runs in the zOS Terminal.", 0) end
local compression = ctx.require("compression")

local USAGE = [[
gzip [-k] [-f] [-1..-9] <file>...  Compress
gzip -d [-k] [-f] <file>...        Decompress
  file -> file.gz, or back again
  -k  keep the original file
  -f  replace a file that's in the way
  -1  fastest ... -9  smallest (6)
gunzip <file>... is gzip -d]]

local function usage(message)
    print(USAGE)
    error(message, 0)
end

local LONG = { decompress = "d", uncompress = "d", keep = "k", force = "f", help = "h", fast = "1", best = "9" }

local decompress, keep, force, help, level = false, false, false, false, nil
local files = {}

local function setOption(letter)
    if letter == "d" then
        decompress = true
    elseif letter == "k" then
        keep = true
    elseif letter == "f" then
        force = true
    elseif letter:match("^%d$") then
        level = tonumber(letter)
        if level < 1 then usage("The level is 1 to 9.") end
    elseif letter == "h" then
        help = true
    else
        usage("Unknown option: -" .. letter)
    end
end

local onlyFiles = false
for _, arg in ipairs({ ... }) do
    if onlyFiles or arg:sub(1, 1) ~= "-" then
        files[#files + 1] = arg
    elseif arg == "--" then
        onlyFiles = true
    elseif arg:sub(1, 2) == "--" then
        local letter = LONG[arg:sub(3)]
        if not letter then usage("Unknown option: " .. arg) end
        setOption(letter)
    else
        for letter in arg:sub(2):gmatch(".") do setOption(letter) end
    end
end
if help then print(USAGE) return end
if decompress and level then usage("-1 to -9 are only for compressing.") end
if #files == 0 then usage("Name the files to " .. (decompress and "decompress." or "compress.")) end

local function display(path) return "/" .. path end

local function readFile(path)
    local f, err = fs.open(path, "rb")
    if not f then error("can't read it: " .. tostring(err), 0) end
    local data = f.readAll() or ""
    f.close()
    return data
end

local function writeFile(path, data)
    local f, err = fs.open(path, "wb")
    if not f then error("can't write " .. display(path) .. ": " .. tostring(err), 0) end
    local ok, writeErr = pcall(f.write, data)
    f.close()
    if not ok then
        fs.delete(path) -- don't leave half a file behind
        error("can't write " .. display(path) .. ": " .. tostring(writeErr), 0)
    end
end

local function modified(path)
    local ok, attributes = pcall(fs.attributes, path)
    local ms = ok and type(attributes) == "table" and attributes.modified or os.epoch("utc")
    return math.floor(ms / 1000)
end

-- What file.gz decompresses to: file, and file.tgz to file.tar.
local function decompressedName(path)
    if path:match("%.tgz$") then return path:sub(1, -5) .. ".tar" end
    if path:match("%.gz$") and #fs.getName(path) > 3 then return path:sub(1, -4) end
    return nil
end

local function percent(before, after)
    if before == 0 then return "0%" end
    return string.format("%.0f%%", (1 - after / before) * 100)
end

local function process(arg)
    local path = shell.resolve(arg)
    if not fs.exists(path) then error("no such file", 0) end
    if fs.isDir(path) then error("it's a folder. Use tar to archive a folder first", 0) end

    local out
    if decompress then
        out = decompressedName(path)
        if not out then error("unknown suffix, expected .gz or .tgz", 0) end
    else
        if decompressedName(path) then error("it is already compressed", 0) end
        out = path .. ".gz"
    end
    if fs.exists(out) then
        if fs.isDir(out) then error(display(out) .. " is a folder", 0) end
        if not force then error(display(out) .. " already exists. Use -f to replace it", 0) end
    end
    if fs.isReadOnly(out) then error(display(out) .. " is read-only", 0) end

    local input = readFile(path)
    local output
    if decompress then
        local data, err = compression.gunzip(input)
        if not data then error("not a valid gzip file: " .. err, 0) end
        output = data
    else
        os.queueEvent("zos_gzip") -- compressing can take a while, so start with a fresh time slice
        os.pullEvent("zos_gzip")
        output = compression.gzip(input, { level = level, name = fs.getName(path), mtime = modified(path) })
    end

    local old = fs.exists(out) and fs.getSize(out) or 0
    if #output > fs.getFreeSpace(fs.getDir(out)) + old then
        error("not enough space for " .. display(out), 0)
    end
    writeFile(out, output)
    if not keep then fs.delete(path) end

    local compressed, plain = decompress and #input or #output, decompress and #output or #input
    print(string.format("%s -> %s (%s saved)", display(path), display(out), percent(plain, compressed)))
end

local failed = 0
for _, arg in ipairs(files) do
    local ok, err = pcall(process, arg)
    if not ok then
        printError(arg .. ": " .. tostring(err))
        failed = failed + 1
    end
end
if failed > 0 then error("", 0) end
