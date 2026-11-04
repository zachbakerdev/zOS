-- Installs zOS from a zos.tar.gz system image. See "Installation" in specs/ZOS.md.
--
--     install                     uses zos.tar.gz next to this file, or else the latest release
--     install some/file.tar.gz    uses that image
--     install https://...         downloads that image
--
-- From nothing but a network connection:
--     wget run https://raw.githubusercontent.com/zachbakerdev/zOS/main/install.lua
--
-- Copy this file to a floppy as install.lua or startup.lua, next to zos.tar.gz, to make a setup disk.
-- As startup.lua it runs by itself when a computer without zOS boots with the disk inserted.
-- A zos.zr next to the image offers root servers to trust. See specs/formats/ZR_FORMAT.md.

local IMAGE_FILE = "zos.tar.gz"
local RELEASE_IMAGE = "https://github.com/zachbakerdev/zOS/releases/latest/download/" .. IMAGE_FILE
local MIN_FILE_SIZE = 500 -- CC: Tweaked counts each file and folder as at least this many bytes
local ROOTS_FILE, ROOTS_VERSION, ROOTS_METADATA = "zos.zr", 1, "zr:metadata"

local SYSTEM, APPS = "/.zos", "/.zos/apps"
local STAGE = "/.zos.install" -- the new system, until it's all on disk
local STARTUP, STARTUP_NEW = "/startup.lua", "/startup.lua.install"
local BACKUP = "/zos-backup"
local DATA = "/etc/zos"
local ROOTS = DATA .. "/net/roots" -- must match lib/trust.lua

-- These must match lib/update.lua.
local UPDATE = DATA .. "/update"
local NEW, READY, STARTUP_STAGED = UPDATE .. "/new", UPDATE .. "/ready", UPDATE .. "/startup.new"
local FAILED = UPDATE .. "/failed"

local TITLE = "zOS Installer"

local args = { ... }
local source = fs.getDir(shell.getRunningProgram())

-- The screen ------------------------------------------------------------------------------------
-- zOS isn't on the computer yet, so this can't use lib/ui.lua, but it should look the same.

local colour = term.isColour and term.isColour()
local theme = {
    bg = colors.black,
    fg = colors.white,
    dim = colour and colors.lightGray or colors.white,
    accent = colour and colors.cyan or colors.white,
    bad = colour and colors.red or colors.white,
    barBg = colour and colors.blue or colors.white,
    barFg = colour and colors.white or colors.black,
    selectBg = colour and colors.cyan or colors.white,
    selectFg = colors.black,
}

local function at(x, y, text, fg, bg)
    term.setCursorPos(x, y)
    term.setTextColor(fg or theme.fg)
    term.setBackgroundColor(bg or theme.bg)
    term.write(text)
end

local function wrap(text, width)
    local lines, line = {}, ""
    for word in text:gmatch("%S+") do
        local joined = line == "" and word or line .. " " .. word
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
    return lines
end

local function screen()
    local width = term.getSize()
    term.setCursorBlink(false)
    term.setBackgroundColor(theme.bg)
    term.clear()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(theme.barBg)
    term.clearLine()
    at(2, 1, TITLE:sub(1, width - 2), theme.barFg, theme.barBg)
    term.setBackgroundColor(theme.bg)
    term.setCursorPos(1, 3)
end

-- Write wrapped text, leaving the shell's colours and a free line for it when the program ends.
local function say(text, color)
    local width, height = term.getSize()
    local _, y = term.getCursorPos()
    for _, line in ipairs(wrap(text, width - 2)) do
        at(2, y, line, color)
        y = y + 1
        if y > height then
            term.scroll(1)
            y = height
        end
    end
    term.setTextColor(theme.fg)
    term.setCursorPos(1, y)
end

-- Ask which of `items` ({ label, hint, fg, mode }) to use, like the desktop's menu. The selected
-- item's hint is at the bottom of the screen. Returns that item's mode.
local function menu(question, items)
    local selected = 1
    while true do
        local width, height = term.getSize()
        screen()
        say(question, theme.accent)
        say("")
        local _, top = term.getCursorPos()
        for i, item in ipairs(items) do
            local chosen = i == selected
            local label = item.label:sub(1, width - 2)
            at(1, top + i - 1, " " .. label .. string.rep(" ", width - #label - 1),
                chosen and theme.selectFg or item.fg, chosen and theme.selectBg or theme.bg)
        end
        local hint = wrap(items[selected].hint, width - 2)
        for i, line in ipairs(hint) do at(2, height - #hint + i, line, theme.dim) end

        local event, a, _, y = os.pullEvent()
        if event == "key" then
            if a == keys.up then
                selected = selected > 1 and selected - 1 or #items
            elseif a == keys.down then
                selected = selected < #items and selected + 1 or 1
            elseif a == keys.enter or a == keys.numPadEnter then
                return items[selected].mode
            end
        elseif event == "mouse_scroll" then
            selected = math.max(1, math.min(#items, selected + a))
        elseif event == "mouse_click" and items[y - top + 1] then
            return items[y - top + 1].mode
        end
    end
end

local function fail(text)
    say(text, theme.bad)
    say("Nothing was changed on this computer.")
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
    say("Downloading " .. url)
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
    local path = fs.combine(source, IMAGE_FILE)
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

-- zOS isn't on the computer yet, so this can't use lib/compression.lua or lib/tar.lua. It reads
-- only what ./package writes: one gzip member holding a ustar archive of files and folders.
-- See specs/formats/TGZ_FORMAT.md.

local DAMAGED = "This isn't a " .. IMAGE_FILE .. " image, or it's damaged."
local byte, char = string.byte, string.char

-- CC kills a program that runs too long without yielding, so long loops call this now and then.
local function yield()
    os.queueEvent("zos_install_yield")
    os.pullEvent("zos_install_yield")
end

local POW = {}
for i = 0, 31 do POW[i] = 2 ^ i end

local CRC = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        c = c % 2 == 1 and bit32.bxor(0xEDB88320, bit32.rshift(c, 1)) or bit32.rshift(c, 1)
    end
    CRC[i] = c
end

local function crc32(s)
    local crc, bxor, band, rshift = 0xFFFFFFFF, bit32.bxor, bit32.band, bit32.rshift
    for i = 1, #s do
        crc = bxor(rshift(crc, 8), CRC[band(bxor(crc, byte(s, i)), 255)])
        if i % 65536 == 0 then yield() end
    end
    return bxor(crc, 0xFFFFFFFF)
end

-- A canonical Huffman code from code lengths lengths[0..n-1], decoded as in zlib's puff.c.
local function huffman(lengths, n)
    local count, offset, symbol = {}, {}, {}
    for len = 0, 15 do count[len] = 0 end
    for i = 0, n - 1 do count[lengths[i]] = count[lengths[i]] + 1 end
    local left = 1
    for len = 1, 15 do
        left = left * 2 - count[len]
        if left < 0 then fail(DAMAGED) end
    end
    offset[1] = 0
    for len = 1, 14 do offset[len + 1] = offset[len] + count[len] end
    for i = 0, n - 1 do
        local len = lengths[i]
        if len ~= 0 then
            symbol[offset[len]] = i
            offset[len] = offset[len] + 1
        end
    end
    return { count = count, symbol = symbol }
end

local LENGTH_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
    99, 115, 131, 163, 195, 227, 258 }
local LENGTH_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5,
    5, 5, 0 }
local DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025,
    1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
    12, 12, 13, 13 }
local CODE_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local fixedLit, fixedDist
do
    local lengths = {}
    for i = 0, 287 do lengths[i] = i < 144 and 8 or i < 256 and 9 or i < 280 and 7 or 8 end
    fixedLit = huffman(lengths, 288)
    for i = 0, 29 do lengths[i] = 5 end
    fixedDist = huffman(lengths, 30)
end

-- The DEFLATE stream (RFC 1951) in s from byte pos, as a string, and the position after it.
local function inflate(s, pos)
    local buffer, count = 0, 0 -- bits read but not used yet, least significant first
    local out, n = {}, 0

    local function bits(want)
        while count < want do
            local b = byte(s, pos)
            if not b then fail(DAMAGED) end
            buffer = buffer + b * POW[count]
            pos, count = pos + 1, count + 8
        end
        local value = buffer % POW[want]
        buffer, count = (buffer - value) / POW[want], count - want
        return value
    end

    local function decode(h)
        local code, first, index = 0, 0, 0
        for len = 1, 15 do
            code = code + bits(1)
            local c = h.count[len]
            if code - c < first then return h.symbol[index + code - first] end
            index, first, code = index + c, (first + c) * 2, code * 2
        end
        fail(DAMAGED)
    end

    local function codes(lit, dist)
        local steps = 0
        while true do
            local sym = decode(lit)
            if sym < 256 then
                n = n + 1
                out[n] = sym
            elseif sym == 256 then
                return
            else
                sym = sym - 256
                if sym > 29 then fail(DAMAGED) end
                local len = LENGTH_BASE[sym] + bits(LENGTH_EXTRA[sym])
                local d = decode(dist) + 1
                if d > 30 then fail(DAMAGED) end
                local back = DIST_BASE[d] + bits(DIST_EXTRA[d])
                if back > n then fail(DAMAGED) end
                for _ = 1, len do
                    n = n + 1
                    out[n] = out[n - back]
                end
            end
            steps = steps + 1
            if steps % 32768 == 0 then yield() end
        end
    end

    repeat
        local last, kind = bits(1), bits(2)
        if kind == 0 then
            buffer, count = 0, 0 -- a stored block starts on a byte
            local a, b, c, d = byte(s, pos, pos + 3)
            if not d or a + b * 256 + c + d * 256 ~= 65535 then fail(DAMAGED) end
            local len = a + b * 256
            if pos + 3 + len > #s then fail(DAMAGED) end
            for i = pos + 4, pos + 3 + len do
                n = n + 1
                out[n] = byte(s, i)
            end
            pos = pos + 4 + len
        elseif kind == 1 then
            codes(fixedLit, fixedDist)
        elseif kind == 2 then
            local nlen, ndist, ncode = bits(5) + 257, bits(5) + 1, bits(4) + 4
            if nlen > 286 or ndist > 30 then fail(DAMAGED) end
            local lengths = {}
            for i = 0, 18 do lengths[i] = 0 end
            for i = 1, ncode do lengths[CODE_ORDER[i]] = bits(3) end
            local lencode = huffman(lengths, 19)
            lengths = {}
            local i = 0
            while i < nlen + ndist do
                local sym = decode(lencode)
                if sym < 16 then
                    lengths[i], i = sym, i + 1
                else
                    local value, times = 0, 0
                    if sym == 16 then
                        if i == 0 then fail(DAMAGED) end
                        value, times = lengths[i - 1], 3 + bits(2)
                    elseif sym == 17 then
                        times = 3 + bits(3)
                    else
                        times = 11 + bits(7)
                    end
                    if i + times > nlen + ndist then fail(DAMAGED) end
                    for _ = 1, times do lengths[i], i = value, i + 1 end
                end
            end
            if lengths[256] == 0 then fail(DAMAGED) end
            local distLengths = {}
            for j = 0, ndist - 1 do distLengths[j] = lengths[nlen + j] end
            codes(huffman(lengths, nlen), huffman(distLengths, ndist))
        else
            fail(DAMAGED)
        end
    until last == 1

    local parts = {}
    for i = 1, n, 4096 do parts[#parts + 1] = char(table.unpack(out, i, math.min(i + 4095, n))) end
    return table.concat(parts), pos
end

local function u32(s, pos)
    local a, b, c, d = byte(s, pos, pos + 3)
    if not d then fail(DAMAGED) end
    return a + b * 256 + c * 65536 + d * 16777216
end

-- The data in a gzip file (RFC 1952) with one member.
local function gunzip(s)
    local id1, id2, method, flags = byte(s, 1, 4)
    if id1 ~= 31 or id2 ~= 139 or method ~= 8 or not flags or flags >= 32 then fail(DAMAGED) end
    local pos = 11
    local function flag(value) return math.floor(flags / value) % 2 == 1 end
    if flag(4) then
        local a, b = byte(s, pos, pos + 1)
        if not b then fail(DAMAGED) end
        pos = pos + 2 + a + b * 256
    end
    for _, value in ipairs({ 8, 16 }) do -- the file name and comment
        if flag(value) then
            pos = s:find("\0", pos, true)
            if not pos then fail(DAMAGED) end
            pos = pos + 1
        end
    end
    if flag(2) then pos = pos + 2 end
    local data
    data, pos = inflate(s, pos)
    if pos + 7 ~= #s or u32(s, pos) ~= crc32(data) or u32(s, pos + 4) ~= #data % 2 ^ 32 then
        fail(DAMAGED)
    end
    return data
end

local function field(h, from, len)
    return (h:sub(from, from + len - 1):match("^[^\0]*"))
end

local function octal(h, from, len)
    local digits = h:sub(from, from + len - 1):gsub("\0", " "):match("^ *([0-7]+) *$")
    if not digits then fail(DAMAGED) end
    return tonumber(digits, 8)
end

-- The entries of a ustar archive as { name, folder, data }.
local function untar(s)
    local entries, pos = {}, 1
    while true do
        local h = s:sub(pos, pos + 511)
        if #h < 512 then fail(DAMAGED) end
        if not h:find("[^\0]") then return entries end
        local sum = 256 -- the checksum field counts as eight spaces
        for i = 1, 512 do
            if i < 149 or i > 156 then sum = sum + byte(h, i) end
        end
        if octal(h, 149, 8) ~= sum then fail(DAMAGED) end
        local name = field(h, 1, 100)
        if h:sub(258, 262) == "ustar" and field(h, 346, 155) ~= "" then
            name = field(h, 346, 155) .. "/" .. name
        end
        local kind, size = h:sub(157, 157), octal(h, 125, 12)
        if kind ~= "0" and kind ~= "\0" and kind ~= "5" then
            fail("The image contains something that isn't a file or folder: " .. name)
        end
        local data = s:sub(pos + 512, pos + 511 + size)
        if #data < size then fail(DAMAGED) end
        entries[#entries + 1] = { name = name, folder = kind == "5" or name:sub(-1) == "/", data = data }
        pos = pos + 512 + math.ceil(size / 512) * 512
    end
end

-- The files in the image as (path -> data). See "Reading an image" in specs/formats/TGZ_FORMAT.md.
local function parseImage(text)
    local files = {}
    for _, entry in ipairs(untar(gunzip(text))) do
        local name = entry.name:gsub("^%./", "")
        if not entry.folder then
            local path = "/" .. name
            if not validPath(path) then fail("The image contains a bad file name: " .. entry.name) end
            if files[path] then fail("The image contains " .. path .. " twice.") end
            files[path] = entry.data
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
    local version = system and system:match('VERSION%s*=%s*"(%d+%.%d+%.%d+)"')
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

-- Checking the root servers ----------------------------------------------------------------------

-- The image's own crypto library. The installer has none, and it needs no other library to load.
local function loadCrypto(files)
    local text = files[SYSTEM .. "/lib/crypto.lua"]
    local fn = text and load(text, "@crypto.lua", "t", _ENV)
    local ok, crypto = pcall(fn or error)
    if not ok or type(crypto) ~= "table" then fail("This image can't check the root servers next to it.") end
    return crypto
end

local function validRoot(crypto, tld, root)
    return type(tld) == "string" and #tld <= 16 and tld:match("^[a-z0-9][a-z0-9%-]*$")
        and type(root) == "table" and crypto.isHex(root.key, 64) and crypto.isHex(root.sig, 128)
        and type(root.name) == "string" and #root.name <= 32 and root.name:match("^[%w%-_ %.]+$")
        and type(root.host) == "number" and root.host >= 0 and root.host % 1 == 0
end

-- The root servers in the .zr file next to the image, sorted by name, or nil if there isn't one.
-- See "Reading a file" in specs/formats/ZR_FORMAT.md.
local function readRoots(imagePath, files)
    local path = imagePath and fs.combine(fs.getDir(imagePath), ROOTS_FILE)
    if not path or not fs.exists(path) or fs.isDir(path) then return nil end
    say("Checking the root servers...")
    local data = textutils.unserialize(readFile(path) or "")
    if type(data) ~= "table" or type(data[ROOTS_METADATA]) ~= "table" or type(data.roots) ~= "table" then
        fail(ROOTS_FILE .. " is damaged.")
    end
    if data[ROOTS_METADATA].version ~= ROOTS_VERSION then fail(ROOTS_FILE .. " needs a newer installer.") end

    local crypto = loadCrypto(files)
    local roots, keys = {}, {}
    for tld, root in pairs(data.roots) do
        if not validRoot(crypto, tld, root) or keys[root.key] then fail(ROOTS_FILE .. " is damaged.") end
        local signed = "zos-zone-1|" .. tld .. "|" .. root.key
        if not crypto.verify(crypto.fromHex(root.key), signed, crypto.fromHex(root.sig)) then
            fail("The signature of " .. root.name .. " in " .. ROOTS_FILE .. " is wrong.")
        end
        keys[root.key] = true
        roots[#roots + 1] = {
            key = root.key, name = root.name, host = root.host, tld = tld,
            fingerprint = crypto.fingerprint(crypto.fromHex(root.key)),
        }
    end
    table.sort(roots, function(a, b) return a.name:lower() < b.name:lower() end)
    return #roots > 0 and roots or nil
end

-- What's on this computer: "current" can be upgraded, "damaged" can only be replaced, and nil is
-- a computer without zOS.
local function detect()
    if fs.exists(SYSTEM .. "/boot.lua") and fs.exists(STARTUP) then return "current" end
    if fs.exists(SYSTEM) or fs.exists(DATA .. "/users.db") then return "damaged" end
end

-- Choosing what to do --------------------------------------------------------------------------

local CANCEL = { label = "Cancel", hint = "Leaves this computer as it is.", fg = theme.dim }

local function chooseMode(found, version)
    local reinstall = {
        label = "Clean reinstall",
        hint = "Deletes all accounts, keys and settings. Apps and user files stay.",
        fg = theme.bad,
        mode = "reinstall",
    }
    if found == "current" then
        return menu("zOS is already installed. Install zOS " .. version .. "?", {
            {
                label = "Upgrade",
                hint = "Keeps users, apps and settings, and rolls back if it doesn't boot.",
                mode = "upgrade",
            },
            reinstall,
            CANCEL,
        })
    elseif found == "damaged" then
        return menu("This computer has a damaged zOS, which can't be upgraded. Install zOS " .. version .. "?", {
            reinstall,
            CANCEL,
        })
    end
    return menu("Install zOS " .. version .. " on computer #" .. os.getComputerID() .. "?", {
        { label = "Install", hint = "Moves startup files to " .. BACKUP .. ".", mode = "install" },
        CANCEL,
    })
end

local function trustedRoots()
    local all = fs.exists(ROOTS) and textutils.unserialize(readFile(ROOTS) or "")
    return type(all) == "table" and all or {}
end

-- Which of the file's roots to trust. A person has to compare each fingerprint, and a domain that
-- another root already owns here stays with it, because a disk mustn't take a domain over.
local function chooseRoots(roots, mode)
    local trusted, chosen = mode == "reinstall" and {} or trustedRoots(), {}
    for _, root in ipairs(roots) do
        local owner
        for key, other in pairs(trusted) do
            if other.tld == root.tld and key ~= root.key then owner = other end
        end
        if owner then
            menu(root.name .. " claims ." .. root.tld .. ", but " .. tostring(owner.name) ..
                " owns that here, so it won't be added.", {
                { label = "Continue", hint = "Remove the other root server first to use this one.", mode = true },
            })
        elseif not trusted[root.key] then
            local trustIt = menu("Trust root server " .. root.name .. " for ." .. root.tld ..
                "? Compare this fingerprint with the one the server shows: " .. root.fingerprint, {
                { label = "Trust", hint = "It can certify any name in ." .. root.tld .. ".", mode = true },
                { label = "Skip", hint = "Installs zOS without it.", mode = false },
            })
            if trustIt then chosen[#chosen + 1] = root end
        end
    end
    return chosen
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

-- The system is already in place, so a failure here is reported and doesn't stop the install.
local function trustRoots(roots)
    if #roots == 0 then return end
    local all = trustedRoots()
    for _, root in ipairs(roots) do
        all[root.key] = { key = root.key, name = root.name, host = root.host, tld = root.tld }
    end
    local temp = ROOTS .. ".new"
    local ok, why = writeChecked(temp, textutils.serialize(all))
    if ok then
        fs.delete(ROOTS)
        fs.move(temp, ROOTS)
    else
        fs.delete(temp)
        say("Couldn't save the root servers: " .. tostring(why), theme.bad)
        sleep(3)
    end
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
    screen()
    local text, imagePath = findImage()
    say("Checking the image...")
    local files = parseImage(text)
    text = nil -- it's the biggest thing in memory
    local version = checkComplete(files)
    checkTarget(files)
    local roots = readRoots(imagePath, files)

    local found = detect()
    local mode = chooseMode(found, version)
    if not mode then
        screen()
        say("Cancelled. Nothing was changed.")
        return
    end
    local chosen = roots and chooseRoots(roots, mode) or {}

    os.pullEvent = os.pullEventRaw -- Ctrl+T mustn't be able to leave a half-installed system
    screen()
    say("Installing zOS " .. version .. "...")
    if mode == "upgrade" then
        upgrade(files, version)
    else
        install(files, mode, found)
    end
    trustRoots(chosen)

    ejectSource(imagePath)
    say("Done. Restarting...", theme.accent)
    sleep(1)
    os.reboot()
    while true do os.pullEventRaw() end
end

main()
