-- Installs zOS from a .zi system image. See "Installation" in specs/ZOS.md.
--
--     install                 uses zos.zi next to this file, or else the latest release
--     install some/file.zi    uses that image
--     install https://...     downloads that image
--
-- From nothing but a network connection:
--     wget run https://raw.githubusercontent.com/zachbakerdev/zOS/main/install.lua
--
-- Copy this file to a floppy as install.lua or startup.lua, next to zos.zi, to make a setup disk.
-- As startup.lua it runs by itself when a computer without zOS boots with the disk inserted.

local RELEASE_IMAGE = "https://github.com/zachbakerdev/zOS/releases/latest/download/zos.zi"
local FORMAT_VERSION = 1
local METADATA = "zi:metadata"
local MIN_FILE_SIZE = 500 -- CC: Tweaked counts each file and folder as at least this many bytes

local SYSTEM, APPS = "/.zos", "/.zos/apps"
local STAGE = "/.zos.install" -- the new system, until it's all on disk
local STARTUP, STARTUP_NEW = "/startup.lua", "/startup.lua.install"
local BACKUP = "/zos-backup"
local DATA = "/etc/zos"

-- These must match lib/update.lua.
local UPDATE = DATA .. "/update"
local NEW, READY, STARTUP_STAGED = UPDATE .. "/new", UPDATE .. "/ready", UPDATE .. "/startup.new"
local FAILED = UPDATE .. "/failed"

local args = { ... }
local source = fs.getDir(shell.getRunningProgram())

local function fail(text)
    printError(text)
    print("Nothing was changed on this computer.")
    error("", 0) -- an empty message prints nothing more
end

local function readFile(path)
    local f = fs.open(path, "rb")
    if not f then return nil end
    local text = f.readAll()
    f.close()
    return text or ""
end

local function download(url)
    if not http then fail("This computer can't use HTTP, so it can't download zOS.") end
    print("Downloading " .. url)
    local response, err = http.get(url, nil, true)
    if not response then fail("The download failed: " .. tostring(err)) end
    local text = response.readAll()
    response.close()
    return text
end

-- The text of the image, and where it came from.
local function findImage()
    local wanted = args[1]
    if wanted and wanted:match("^https?://") then return download(wanted), nil end
    if wanted then
        local path = shell.resolve(wanted)
        local text = not fs.isDir(path) and readFile(path)
        if not text then fail("There's no image at " .. wanted) end
        return text, path
    end
    local path = fs.combine(source, "zos.zi")
    if fs.exists(path) and not fs.isDir(path) then return readFile(path), path end
    return download(RELEASE_IMAGE), nil
end

-- Checking the image, before anything changes ------------------------------------------------

local function validPath(path)
    if #path > 129 or not path:match("^/.") or path:sub(-1) == "/" then return false end
    for part in (path:sub(2) .. "/"):gmatch("(.-)/") do
        if not part:match("^[%w_%.%-]+$") or part:match("^%.+$") then return false end
    end
    local top = path:match("^/([^/]+)")
    return top ~= "rom" and not top:match("^disk%d*$")
end

local function parents(path)
    return function(_, current)
        local parent = current:match("^(.*)/[^/]*$")
        if parent and parent ~= "" then return parent end
    end, nil, path
end

-- The files in the image as (path -> data). See "Reading an image" in specs/formats/ZI_FORMAT.md.
local function parseImage(text)
    local data = textutils.unserialize(text)
    if type(data) ~= "table" or type(data[METADATA]) ~= "table" then
        fail("This isn't a .zi image, or it's damaged.")
    end
    if data[METADATA].version ~= FORMAT_VERSION then
        fail("This image needs a newer installer.")
    end
    local files = {}
    for path, contents in pairs(data) do
        if path ~= METADATA then
            if type(path) ~= "string" or type(contents) ~= "string" then
                fail("The image contains a bad entry.")
            end
            if not validPath(path) then fail("The image contains a bad file name: " .. path) end
            files[path] = contents
        end
    end
    for path, contents in pairs(files) do
        for parent in parents(path) do
            if files[parent] then fail("The image uses " .. parent .. " as both a file and a folder.") end
        end
        if path:match("%.lua$") then
            local fn, err = load(contents, "@" .. path, "t", {})
            if not fn then fail("A file in the image doesn't compile: " .. tostring(err)) end
        end
    end
    return files
end

-- The zOS version in the image, which also shows that it's a whole system.
local function checkComplete(files)
    local system = files[SYSTEM .. "/lib/system.lua"]
    local version = system and system:match('VERSION%s*=%s*"([^"]+)"')
    if not version or not files[SYSTEM .. "/boot.lua"] or not files[STARTUP] then
        fail("The image isn't a complete system.")
    end
    return version
end

local function spaceNeeded(files)
    local total, dirs = 0, {}
    for path, contents in pairs(files) do
        total = total + math.max(#contents, MIN_FILE_SIZE)
        for parent in parents(path) do
            if not dirs[parent] then
                dirs[parent] = true
                total = total + MIN_FILE_SIZE
            end
        end
    end
    return total
end

-- Paths outside /.zos can't be swapped into place, so anything in their way has to stop setup.
local function checkTarget(files)
    local free = fs.getFreeSpace("/")
    if type(free) == "number" and free < spaceNeeded(files) then
        fail(("zOS needs %d KB of disk space, but only %d KB is free."):format(
            math.ceil(spaceNeeded(files) / 1000), math.floor(free / 1000)))
    end
    if fs.exists(SYSTEM) and not fs.isDir(SYSTEM) then fail(SYSTEM .. " is a file. Move it first.") end
    for path in pairs(files) do
        if path:sub(1, #SYSTEM + 1) ~= SYSTEM .. "/" and path ~= STARTUP then
            if fs.isDir(path) then fail(path .. " is a folder, but the image has a file there.") end
            for parent in parents(path) do
                if fs.exists(parent) and not fs.isDir(parent) then
                    fail(parent .. " is a file, but the image needs a folder there.")
                end
            end
        end
    end
end

-- What's on this computer: "current" can be upgraded, "damaged" can only be replaced, and nil is
-- a computer without zOS.
local function detect()
    if fs.exists(SYSTEM .. "/boot.lua") and fs.exists(STARTUP) then return "current" end
    if fs.exists(SYSTEM) or fs.exists(DATA .. "/users.db") then return "damaged" end
end

-- Choosing what to do --------------------------------------------------------------------------

local function ask(title, choices)
    print()
    print(title)
    for i, choice in ipairs(choices) do print(("  %d. %s"):format(i, choice.label)) end
    while true do
        write("Choose: ")
        local choice = choices[tonumber(read())]
        if choice then return choice.mode end
    end
end

local function chooseMode(found, version)
    if found == "current" then
        return ask("zOS is already installed. Install zOS " .. version .. "?", {
            { label = "Upgrade: keep users, apps and settings", mode = "upgrade" },
            { label = "Clean reinstall: delete all accounts and keys", mode = "reinstall" },
            { label = "Cancel" },
        })
    elseif found == "damaged" then
        return ask("This computer has a damaged zOS, which can't be upgraded.", {
            { label = "Clean reinstall zOS " .. version .. ": delete all accounts and keys", mode = "reinstall" },
            { label = "Cancel" },
        })
    end
    return ask("Install zOS " .. version .. " on computer #" .. os.getComputerID() .. "?", {
        { label = "Install: startup files move to " .. BACKUP, mode = "install" },
        { label = "Cancel" },
    })
end

-- Installing -----------------------------------------------------------------------------------

local function writeChecked(path, data)
    local f, err = fs.open(path, "wb")
    if not f then return nil, err end
    f.write(data)
    f.close()
    if readFile(path) ~= data then return nil, "the disk may be full" end
    return true
end

local function stageFile(path, data, undo)
    local ok, why = writeChecked(path, data)
    if not ok then
        undo()
        fail("Couldn't write " .. path .. ": " .. tostring(why))
    end
end

local function discardUpdate()
    fs.delete(READY)
    fs.delete(NEW)
    fs.delete(STARTUP_STAGED)
end

-- Stage the system as an update, so that the bootstrap swaps it in and can roll it back if it
-- doesn't boot. Like any update this leaves installed apps alone.
local function upgrade(files, version)
    discardUpdate()
    for path, data in pairs(files) do
        if path:sub(1, #SYSTEM + 1) == SYSTEM .. "/" and path:sub(1, #APPS + 1) ~= APPS .. "/" then
            stageFile(NEW .. path:sub(#SYSTEM + 1), data, discardUpdate)
        end
    end
    stageFile(STARTUP_STAGED, files[STARTUP], discardUpdate)
    fs.delete(FAILED)
    stageFile(READY, version, discardUpdate) -- last, so a boot never sees half an update
end

local function backUp(path)
    if not fs.exists(path) then return end
    fs.makeDir(BACKUP)
    local dest = fs.combine(BACKUP, fs.getName(path))
    fs.delete(dest)
    fs.copy(path, dest)
end

local function resetData()
    for _, name in ipairs({ "users.db", "LOCKOUT", "keys", "known_keys", "net", "config", "update" }) do
        fs.delete(fs.combine(DATA, name))
    end
end

-- Install or reinstall. /startup.lua is replaced by a rename at the very end, so the computer
-- never starts without a bootstrap, which would leave it at an open shell.
local function install(files, mode, found)
    local function undo()
        fs.delete(STAGE)
        fs.delete(STARTUP_NEW)
    end
    undo()
    for path, data in pairs(files) do
        if path:sub(1, #SYSTEM + 1) == SYSTEM .. "/" then
            stageFile(STAGE .. path:sub(#SYSTEM + 1), data, undo)
        end
    end
    stageFile(STARTUP_NEW, files[STARTUP], undo)
    backUp("/startup")
    if mode == "install" or found == "damaged" then backUp(STARTUP) end

    if mode == "reinstall" then resetData() end
    -- Installed apps aren't in the image, and aren't accounts or keys, so they stay.
    if fs.isDir(APPS) then
        for _, id in ipairs(fs.list(APPS)) do
            local dest = STAGE .. "/apps/" .. id
            if not fs.exists(dest) then
                fs.makeDir(STAGE .. "/apps")
                fs.move(APPS .. "/" .. id, dest)
            end
        end
    end
    fs.delete(SYSTEM)
    fs.move(STAGE, SYSTEM)

    -- Anything else in the image, outside the system folder.
    for path, data in pairs(files) do
        if path:sub(1, #SYSTEM + 1) ~= SYSTEM .. "/" and path ~= STARTUP then
            local ok, why = writeChecked(path, data)
            if not ok then error("Couldn't write " .. path .. ": " .. tostring(why), 0) end
        end
    end

    fs.delete("/startup") -- CraftOS would run this alongside /startup.lua
    fs.delete(STARTUP)
    fs.move(STARTUP_NEW, STARTUP)

    -- Disks mustn't boot from here on. A boot sets this too, but this disk may still be in.
    settings.set("shell.allow_disk_startup", false)
    settings.save("/.settings")
end

local function ejectSource(imagePath)
    if not imagePath or not disk then return end
    for _, side in ipairs(peripheral.getNames()) do
        local mount = disk.isPresent(side) and disk.getMountPath(side)
        if mount and (imagePath == mount or imagePath:sub(1, #mount + 1) == mount .. "/") then
            disk.eject(side)
        end
    end
end

local function main()
    local text, imagePath = findImage()
    print("Checking the image...")
    local files = parseImage(text)
    text = nil -- it's the biggest thing in memory
    local version = checkComplete(files)
    checkTarget(files)

    local found = detect()
    local mode = chooseMode(found, version)
    if not mode then
        print("Cancelled. Nothing was changed.")
        return
    end

    os.pullEvent = os.pullEventRaw -- Ctrl+T mustn't be able to leave a half-installed system
    print("Installing zOS " .. version .. "...")
    if mode == "upgrade" then
        upgrade(files, version)
    else
        install(files, mode, found)
    end

    ejectSource(imagePath)
    print("Done. Restarting...")
    sleep(1)
    os.reboot()
    while true do os.pullEventRaw() end
end

main()
