-- tar: create, list and extract tar archives from the Terminal. See specs/ARCHIVES.md.

local ctx = _G.zos
if not ctx then error("tar only runs in the zOS Terminal.", 0) end
local tarlib, compression = ctx.require("tar"), ctx.require("compression")

local USAGE = [[
tar -c [-z] -f <archive> <path>...  Create an archive
tar -x -f <archive> [-C <folder>]   Extract an archive
tar -t -f <archive>                 List an archive
  -z  gzip it (.tar.gz). Implied by a
      .gz or .tgz name; extracting and
      listing detect it by themselves
  -v  show each file
Options can be grouped: tar czf a.tar.gz docs]]

local function usage(message)
    print(USAGE)
    error(message, 0)
end

-- Options, GNU style: "-czf out", "czf out" (as the first argument), "--create", "--file=out".
local LONG = {
    create = "c", extract = "x", get = "x", list = "t", gzip = "z", gunzip = "z",
    verbose = "v", file = "f", directory = "C", help = "h",
}
local TAKES_VALUE = { f = true, C = true }

local mode, gz, verbose, archive, folder
local paths = {}

local function setOption(letter, nextValue)
    if letter == "c" or letter == "x" or letter == "t" then
        if mode and mode ~= letter then usage("Choose one of -c, -x and -t.") end
        mode = letter
    elseif letter == "z" then
        gz = true
    elseif letter == "v" then
        verbose = true
    elseif letter == "f" then
        archive = nextValue("-f")
    elseif letter == "C" then
        folder = nextValue("-C")
    elseif letter == "h" then
        print(USAGE)
        mode = "h"
    else
        usage("Unknown option: -" .. letter)
    end
end

do
    local args = { ... }
    local i = 1
    local function nextValue(flag)
        i = i + 1
        local value = args[i]
        if value == nil or value == "" then usage(flag .. " needs a value.") end
        return value
    end
    local onlyPaths = false
    while i <= #args do
        local arg = args[i]
        if onlyPaths or arg:sub(1, 1) ~= "-" and not (i == 1 and arg:match("^[cxtzvfh]+$")) then
            paths[#paths + 1] = arg
        elseif arg == "--" then
            onlyPaths = true
        elseif arg:sub(1, 2) == "--" then
            local name, value = arg:match("^%-%-([^=]+)=(.*)$")
            name = name or arg:sub(3)
            local letter = LONG[name]
            if not letter then usage("Unknown option: " .. arg) end
            if TAKES_VALUE[letter] then
                setOption(letter, function(flag) return value or nextValue(flag) end)
            elseif value then
                usage(arg .. " doesn't take a value.")
            else
                setOption(letter)
            end
        else
            -- A group of letters. A letter that takes a value takes the next argument, in order,
            -- so "-cf out" and "-fc out" both work, like GNU tar.
            for letter in arg:gsub("^%-", ""):gmatch(".") do setOption(letter, nextValue) end
        end
        i = i + 1
    end
end

if mode == "h" then return end
if not mode then usage("Choose one of -c, -x and -t.") end
if not archive then
    -- Forgiving: "tar -c out.tar docs" uses the first path as the archive.
    archive = table.remove(paths, 1)
    if not archive then usage("Name the archive with -f.") end
end

local function display(path) return "/" .. path end

-- CraftOS stops a program that runs for too long without yielding, so long jobs take a break.
local lastBreak = os.clock()
local function breathe()
    if os.clock() - lastBreak >= 1 then
        os.queueEvent("zos_tar")
        os.pullEvent("zos_tar")
        lastBreak = os.clock()
    end
end

local function readFile(path)
    local f, err = fs.open(path, "rb")
    if not f then error("Can't read " .. display(path) .. ": " .. tostring(err), 0) end
    local data = f.readAll() or ""
    f.close()
    return data
end

local function writeFile(path, data)
    local f, err = fs.open(path, "wb")
    if not f then error("Can't write " .. display(path) .. ": " .. tostring(err), 0) end
    local ok, writeErr = pcall(f.write, data)
    f.close()
    if not ok then error("Can't write " .. display(path) .. ": " .. tostring(writeErr), 0) end
end

-- Unix seconds of the last change, or now if the file system can't say.
local function modified(path)
    local ok, attributes = pcall(fs.attributes, path)
    local ms = ok and type(attributes) == "table" and attributes.modified or os.epoch("utc")
    return math.floor(ms / 1000)
end

local function formatSize(n)
    if n < 1000 then return n .. " B" end
    if n < 1000000 then return string.format("%.1f KB", n / 1000) end
    return string.format("%.1f MB", n / 1000000)
end

local archivePath = shell.resolve(archive)

---------------------------------------------------------------------------
-- tar -c
---------------------------------------------------------------------------

local function create()
    if #paths == 0 then usage("Name the files and folders to archive.") end
    if archivePath:match("%.t?gz$") then gz = true end

    local cwd = shell.dir()
    local entries, seen, files, bytes = {}, {}, 0, 0

    local function add(path, name)
        breathe()
        if path == archivePath then return end -- never archive the archive into itself
        if fs.isDir(path) then
            if name ~= "" and not seen[name .. "/"] then
                seen[name .. "/"] = true
                entries[#entries + 1] = { name = name .. "/", type = "directory", mode = "755", mtime = modified(path) }
                if verbose then print(name .. "/") end
            end
            local children = fs.list(path)
            table.sort(children)
            for _, child in ipairs(children) do
                add(fs.combine(path, child), name == "" and child or name .. "/" .. child)
            end
        elseif not seen[name] then
            seen[name] = true
            local data = readFile(path)
            entries[#entries + 1] = { name = name, data = data, mode = "644", mtime = modified(path) }
            files, bytes = files + 1, bytes + #data
            if verbose then print(name) end
        end
    end

    for _, arg in ipairs(paths) do
        local path = shell.resolve(arg)
        if not fs.exists(path) then error("No such file or folder: " .. arg, 0) end
        -- Names are relative to the current folder, as given. Anything outside it keeps its full
        -- path without the leading /, which is what GNU tar does.
        local name = path
        if path == cwd then
            name = ""
        elseif cwd ~= "" and path:sub(1, #cwd + 1) == cwd .. "/" then
            name = path:sub(#cwd + 2)
        end
        if name == "" and path == "" then
            -- The root: leave out the read-only ROM, which CraftOS always provides.
            local children = fs.list("")
            table.sort(children)
            for _, child in ipairs(children) do
                if not fs.isReadOnly(child) then add(child, child) end
            end
        else
            add(path, name)
        end
    end

    local data, err = tarlib.create(entries, { format = "ustar", record_size = 512 })
    if not data then error("Can't create the archive: " .. err, 0) end
    breathe()
    if gz then data = compression.gzip(data) end

    local dir = fs.getDir(archivePath)
    if fs.isDir(archivePath) then error(display(archivePath) .. " is a folder.", 0) end
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local old = fs.exists(archivePath) and fs.getSize(archivePath) or 0
    if #data > fs.getFreeSpace(dir) + old then
        error("Not enough space for " .. display(archivePath) .. " (" .. formatSize(#data) .. ").", 0)
    end
    writeFile(archivePath, data)
    print(string.format("Archived %d file%s (%s) to %s, %s.", files, files == 1 and "" or "s",
        formatSize(bytes), display(archivePath), formatSize(#data)))
end

---------------------------------------------------------------------------
-- tar -t and tar -x
---------------------------------------------------------------------------

local function readArchive()
    if not fs.exists(archivePath) or fs.isDir(archivePath) then error("No such archive: " .. archive, 0) end
    local data = readFile(archivePath)
    breathe()
    local entries, err = tarlib.parse(data)
    if not entries then error("Can't read " .. display(archivePath) .. ": " .. err, 0) end
    return entries
end

local function list()
    if #paths > 0 then usage("tar -t doesn't take paths.") end
    for _, e in ipairs(readArchive()) do
        if verbose then
            local kind = e.type == "directory" and "d" or e.type == "file" and "-" or "?"
            print(string.format("%s %9s  %s", kind, e.type == "file" and formatSize(e.size) or "", e.name))
        else
            print(e.name)
        end
    end
end

-- The archive's name for a file, as a list of segments, or nil and the reason it can't be used.
local function segments(name)
    local parts = {}
    for part in name:gsub("\\", "/"):gmatch("[^/]+") do
        if part == ".." then return nil, "goes outside the folder" end
        if part ~= "." then parts[#parts + 1] = part end
    end
    return parts
end

local function extract()
    if #paths > 0 then usage("tar -x doesn't take paths. Use -C to choose a folder.") end
    local target = folder and shell.resolve(folder) or shell.dir()
    if fs.exists(target) and not fs.isDir(target) then error(display(target) .. " isn't a folder.", 0) end

    -- Check everything before writing anything, so that a bad archive changes nothing.
    local plan, kinds, skipped = {}, {}, 0
    for _, e in ipairs(readArchive()) do
        local parts, why = segments(e.name)
        if not parts then error("Unsafe path in the archive: " .. e.name .. " (" .. why .. ")", 0) end
        if #parts > 0 then
            if e.type ~= "file" and e.type ~= "contiguous" and e.type ~= "directory" then
                printError("Skipping " .. e.name .. ": " .. e.type .. "s aren't supported.")
                skipped = skipped + 1
            else
                local isDir = e.type == "directory"
                local path = fs.combine(target, table.concat(parts, "/"))
                -- Every parent has to be a folder, and stay one.
                for i = 1, #parts - 1 do
                    local parent = fs.combine(target, table.concat(parts, "/", 1, i))
                    if kinds[parent] == "file" or kinds[parent] == nil and fs.exists(parent) and not fs.isDir(parent) then
                        error("Can't extract " .. e.name .. ": " .. display(parent) .. " is a file.", 0)
                    end
                    kinds[parent] = "dir"
                end
                local existing = kinds[path] or (fs.exists(path) and (fs.isDir(path) and "dir" or "file"))
                if existing and existing ~= (isDir and "dir" or "file") then
                    error("Can't extract " .. e.name .. ": " .. display(path) .. " is a " ..
                        (existing == "dir" and "folder" or "file") .. ".", 0)
                end
                if fs.isReadOnly(path) then error("Can't extract " .. e.name .. ": " .. display(path) .. " is read-only.", 0) end
                kinds[path] = isDir and "dir" or "file"
                plan[#plan + 1] = { path = path, name = e.name, data = not isDir and (e.data or "") or nil }
            end
        end
    end

    local files, bytes = 0, 0
    if not fs.exists(target) then fs.makeDir(target) end
    for _, step in ipairs(plan) do
        breathe()
        if step.data then
            local dir = fs.getDir(step.path)
            if not fs.exists(dir) then fs.makeDir(dir) end
            writeFile(step.path, step.data)
            files, bytes = files + 1, bytes + #step.data
        elseif not fs.exists(step.path) then
            fs.makeDir(step.path)
        end
        if verbose then print(step.name) end
    end
    print(string.format("Extracted %d file%s (%s) to %s.", files, files == 1 and "" or "s",
        formatSize(bytes), display(target)))
    if skipped > 0 then error("Skipped " .. skipped .. " entr" .. (skipped == 1 and "y" or "ies") .. ".", 0) end
end

if mode == "c" then create() elseif mode == "t" then list() else extract() end
