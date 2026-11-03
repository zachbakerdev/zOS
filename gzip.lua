-- gzip: create and extract .gz files (DEFLATE, RFC 1951, inside the gzip wrapper, RFC 1952).
--
-- As a program:
--   gzip -c <file> [output]      compress to <file>.gz
--   gzip -d <file.gz> [output]   extract to <file>
--
-- As a library:
--   local gzip = require("gzip")
--   local packed = gzip.compress(text, { name = "notes.txt", level = 6 })
--   local text, nameOrErr = gzip.decompress(packed)
--
-- Extraction handles every DEFLATE block type, so it reads files made by real gzip.
-- Compression uses LZ77 with fixed Huffman codes: simpler than gzip's dynamic codes,
-- and usually within 10-25% of its size.

local gzip = {}

local floor, char, byte, concat = math.floor, string.char, string.byte, table.concat
local unpack = table.unpack or unpack

-- CC has bit32; LuaJIT has bit; plain Lua 5.3+ has operators instead.
local bxor, band, rshift
local hasBit, bit = pcall(require, "bit")
if bit32 then
    bxor, band, rshift = bit32.bxor, bit32.band, bit32.rshift
elseif hasBit then
    local function u(x) return x % 4294967296 end
    bxor = function(a, b) return u(bit.bxor(a, b)) end
    band = function(a, b) return u(bit.band(a, b)) end
    rshift = function(a, n) return u(bit.rshift(a, n)) end
else
    bxor, band, rshift = load([[return
        function(a, b) return a ~ b end,
        function(a, b) return a & b end,
        function(a, n) return a >> n end]])()
end

local P = {} -- powers of two
for i = 0, 32 do P[i] = floor(2 ^ i) end

-- CC kills a program that runs too long without yielding, so long loops call this now and then.
local function yield()
    if os.queueEvent and os.pullEvent then
        os.queueEvent("gzip_yield")
        os.pullEvent("gzip_yield")
    end
end

local crcTable
function gzip.crc32(s, crc)
    if not crcTable then
        crcTable = {}
        for i = 0, 255 do
            local c = i
            for _ = 1, 8 do
                if c % 2 == 1 then c = bxor(rshift(c, 1), 0xEDB88320) else c = rshift(c, 1) end
            end
            crcTable[i] = c
        end
    end
    crc = bxor(crc or 0, 0xFFFFFFFF)
    for i = 1, #s do
        crc = bxor(crcTable[band(bxor(crc, byte(s, i)), 0xFF)], rshift(crc, 8))
        if i % 65536 == 0 then yield() end
    end
    return bxor(crc, 0xFFFFFFFF)
end

-- A byte array as a string, in chunks small enough for unpack.
local function toString(bytes, n)
    local parts = {}
    for i = 1, n, 4096 do
        parts[#parts + 1] = char(unpack(bytes, i, math.min(i + 4095, n)))
    end
    return concat(parts)
end

---------------------------------------------------------------------------
-- Tables shared by both directions (RFC 1951 section 3.2.5)

local LBASE = { [0] = 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXT = { [0] = 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DBASE = { [0] = 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DEXT = { [0] = 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local CL_ORDER = { [0] = 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local function fixedLengths()
    local lit, dist = {}, {}
    for i = 0, 287 do lit[i] = (i < 144 and 8) or (i < 256 and 9) or (i < 280 and 7) or 8 end
    for i = 0, 31 do dist[i] = 5 end
    return lit, dist
end

local function reverse(code, len)
    local r = 0
    for _ = 1, len do
        r = r * 2 + code % 2
        code = floor(code / 2)
    end
    return r
end

-- Canonical Huffman codes for the given lengths (indexed from 0), bit-reversed
-- because DEFLATE sends codes starting from their most significant bit.
local function canonicalCodes(lengths, n)
    local count, nextCode = {}, {}
    for i = 0, 15 do count[i] = 0 end
    for s = 0, n - 1 do
        local l = lengths[s] or 0
        count[l] = count[l] + 1
    end
    count[0] = 0
    local code = 0
    for bits = 1, 15 do
        code = (code + count[bits - 1]) * 2
        nextCode[bits] = code
    end
    local codes = {}
    for s = 0, n - 1 do
        local l = lengths[s] or 0
        if l > 0 then
            local c = nextCode[l]
            if c >= P[l] then error("invalid Huffman code lengths", 0) end
            nextCode[l] = c + 1
            codes[s] = reverse(c, l)
        end
    end
    return codes
end

---------------------------------------------------------------------------
-- Inflate

-- A lookup table indexed by the next `bits` input bits; each code fills every slot it prefixes.
local function decodeTable(lengths, n)
    local codes = canonicalCodes(lengths, n)
    local maxLen = 0
    for s = 0, n - 1 do
        if (lengths[s] or 0) > maxLen then maxLen = lengths[s] end
    end
    local sym, len = {}, {}
    for s = 0, n - 1 do
        local l = lengths[s] or 0
        if l > 0 then
            for i = codes[s], P[maxLen] - 1, P[l] do
                sym[i], len[i] = s, l
            end
        end
    end
    return { sym = sym, len = len, bits = maxLen }
end

local fixedLitTable, fixedDistTable

-- Raw DEFLATE data starting at `pos`. Returns the output bytes, their count,
-- and the position just after the compressed data.
function gzip.inflate(data, pos)
    pos = pos or 1
    local dataLen = #data
    local bitBuf, bitCnt = 0, 0
    local out, n = {}, 0
    local work = 0

    local function need(k)
        while bitCnt < k and pos <= dataLen do
            bitBuf = bitBuf + byte(data, pos) * P[bitCnt]
            pos = pos + 1
            bitCnt = bitCnt + 8
        end
    end

    local function bits(k)
        if k == 0 then return 0 end
        need(k)
        if bitCnt < k then error("unexpected end of data", 0) end
        local v = bitBuf % P[k]
        bitBuf = (bitBuf - v) / P[k]
        bitCnt = bitCnt - k
        return v
    end

    local function decode(t)
        need(t.bits)
        local i = bitBuf % P[t.bits]
        local l = t.len[i]
        if not l then error("invalid Huffman code", 0) end
        if l > bitCnt then error("unexpected end of data", 0) end
        bitBuf = (bitBuf - bitBuf % P[l]) / P[l]
        bitCnt = bitCnt - l
        return t.sym[i]
    end

    local function readDynamic()
        local nlit, ndist, nclen = bits(5) + 257, bits(5) + 1, bits(4) + 4
        if nlit > 286 or ndist > 30 then error("invalid dynamic block header", 0) end
        local cl = {}
        for i = 0, 18 do cl[i] = 0 end
        for i = 0, nclen - 1 do cl[CL_ORDER[i]] = bits(3) end
        local clTable = decodeTable(cl, 19)

        local lengths, i, total = {}, 0, nlit + ndist
        while i < total do
            local s = decode(clTable)
            if s < 16 then
                lengths[i] = s
                i = i + 1
            else
                local rep, val = 0, 0
                if s == 16 then
                    if i == 0 then error("invalid length repeat", 0) end
                    val, rep = lengths[i - 1], 3 + bits(2)
                elseif s == 17 then
                    rep = 3 + bits(3)
                else
                    rep = 11 + bits(7)
                end
                if i + rep > total then error("invalid length repeat", 0) end
                for _ = 1, rep do
                    lengths[i] = val
                    i = i + 1
                end
            end
        end
        if (lengths[256] or 0) == 0 then error("missing end-of-block code", 0) end

        local litLen, distLen = {}, {}
        for j = 0, nlit - 1 do litLen[j] = lengths[j] end
        for j = 0, ndist - 1 do distLen[j] = lengths[nlit + j] end
        return decodeTable(litLen, nlit), decodeTable(distLen, ndist)
    end

    repeat
        local final = bits(1)
        local kind = bits(2)
        if kind == 0 then
            -- Stored: skip to a byte boundary, read LEN and NLEN, then copy LEN bytes as they are.
            bits(bitCnt % 8)
            local len, nlen = bits(16), bits(16)
            if len + nlen ~= 65535 then error("corrupt stored block", 0) end
            pos = pos - floor(bitCnt / 8) -- hand back whole bytes still in the bit buffer
            bitBuf, bitCnt = 0, 0
            if pos + len - 1 > dataLen then error("unexpected end of data", 0) end
            for i = pos, pos + len - 1 do
                n = n + 1
                out[n] = byte(data, i)
            end
            pos = pos + len
        elseif kind == 1 or kind == 2 then
            local lit, dist
            if kind == 1 then
                if not fixedLitTable then
                    local l, d = fixedLengths()
                    fixedLitTable, fixedDistTable = decodeTable(l, 288), decodeTable(d, 32)
                end
                lit, dist = fixedLitTable, fixedDistTable
            else
                lit, dist = readDynamic()
            end

            while true do
                local s = decode(lit)
                if s < 256 then
                    n = n + 1
                    out[n] = s
                elseif s == 256 then
                    break
                else
                    s = s - 257
                    if s > 28 then error("invalid length code", 0) end
                    local length = LBASE[s] + bits(LEXT[s])
                    local d = decode(dist)
                    if d > 29 then error("invalid distance code", 0) end
                    local distance = DBASE[d] + bits(DEXT[d])
                    if distance > n then error("distance too far back", 0) end
                    local from = n - distance
                    for i = 1, length do out[n + i] = out[from + i] end -- may overlap; that's intended
                    n = n + length
                end
                work = work + 1
                if work >= 16384 then
                    work = 0
                    yield()
                end
            end
        else
            error("invalid block type", 0)
        end
    until final == 1

    pos = pos - floor(bitCnt / 8)
    return out, n, pos
end

---------------------------------------------------------------------------
-- Deflate

local function storedBlocks(data)
    local parts, len, i = {}, #data, 1
    repeat
        local n = math.min(65535, len - i + 1)
        local final = (i + n > len) and 1 or 0
        local nlen = 65535 - n
        parts[#parts + 1] = char(final, n % 256, floor(n / 256), nlen % 256, floor(nlen / 256))
        parts[#parts + 1] = data:sub(i, i + n - 1)
        i = i + n
    until i > len
    return concat(parts)
end

local litCode, litLen, distCode, lenCodeOf, distCodeOf

local function buildEncoder()
    local l, d = fixedLengths()
    litCode, litLen, distCode = canonicalCodes(l, 288), l, canonicalCodes(d, 30)
    lenCodeOf, distCodeOf = {}, {}
    for code = 0, 28 do
        for v = LBASE[code], math.min(LBASE[code] + P[LEXT[code]] - 1, 258) do
            lenCodeOf[v] = code -- code 28 is set last, so 258 gets its own code as required
        end
    end
    for code = 0, 29 do
        for v = DBASE[code], DBASE[code] + P[DEXT[code]] - 1 do distCodeOf[v] = code end
    end
end

-- Raw DEFLATE: one fixed-Huffman block, or stored blocks if that comes out smaller.
-- Level 1-9 sets how many earlier matches are tried at each position.
function gzip.deflate(data, level)
    level = level or 6
    local len = #data
    if level <= 0 or len == 0 then return storedBlocks(data) end
    if not litCode then buildEncoder() end
    local maxChain = P[math.min(level, 9) + 1]

    local b = {}
    for i = 1, len, 4096 do
        local chunk = { byte(data, i, math.min(i + 4095, len)) }
        for j = 1, #chunk do b[i + j - 1] = chunk[j] end
    end

    local out, on = {}, 0
    local bitBuf, bitCnt = 0, 0
    local function put(v, k)
        bitBuf = bitBuf + v * P[bitCnt]
        bitCnt = bitCnt + k
        while bitCnt >= 8 do
            local low = bitBuf % 256
            on = on + 1
            out[on] = low
            bitBuf = (bitBuf - low) / 256
            bitCnt = bitCnt - 8
        end
    end

    put(1, 1) -- last block
    put(1, 2) -- fixed Huffman

    -- head[key] is the latest position starting with those 3 bytes; prev chains to earlier ones.
    local head, prev = {}, {}
    local function insert(j)
        local key = b[j] * 65536 + b[j + 1] * 256 + b[j + 2]
        prev[j] = head[key]
        head[key] = j
    end

    local i, work = 1, 0
    while i <= len do
        local bestLen, bestDist = 0, 0
        if i + 2 <= len then
            local limit = math.min(258, len - i + 1)
            local cand = head[b[i] * 65536 + b[i + 1] * 256 + b[i + 2]]
            local chain = maxChain
            while cand and i - cand <= 32768 and chain > 0 do
                if b[cand + bestLen] == b[i + bestLen] then
                    local l = 3 -- every candidate already shares the first 3 bytes
                    while l < limit and b[cand + l] == b[i + l] do l = l + 1 end
                    if l > bestLen then
                        bestLen, bestDist = l, i - cand
                        if l == limit then break end
                    end
                end
                cand = prev[cand]
                chain = chain - 1
            end
            insert(i)
        end

        if bestLen >= 3 then
            local lc = lenCodeOf[bestLen]
            local sym = 257 + lc
            put(litCode[sym], litLen[sym])
            if LEXT[lc] > 0 then put(bestLen - LBASE[lc], LEXT[lc]) end
            local dc = distCodeOf[bestDist]
            put(distCode[dc], 5)
            if DEXT[dc] > 0 then put(bestDist - DBASE[dc], DEXT[dc]) end
            for j = i + 1, math.min(i + bestLen - 1, len - 2) do insert(j) end
            i = i + bestLen
        else
            local c = b[i]
            put(litCode[c], litLen[c])
            i = i + 1
        end

        work = work + 1
        if work >= 8192 then
            work = 0
            yield()
        end
    end

    put(litCode[256], litLen[256])
    if bitCnt > 0 then put(0, 8 - bitCnt) end

    -- Incompressible data costs up to 9 bits a byte here; stored blocks cost 5 bytes per 64 KB.
    if on > len + 5 * (floor(len / 65535) + 1) then return storedBlocks(data) end
    return toString(out, on)
end

---------------------------------------------------------------------------
-- gzip wrapper

local function u32(n)
    return char(n % 256, floor(n / 256) % 256, floor(n / 65536) % 256, floor(n / 16777216) % 256)
end

local function readU32(s, pos)
    local a, b, c, d = byte(s, pos, pos + 3)
    if not d then error("file is truncated", 0) end
    return a + b * 256 + c * 65536 + d * 16777216
end

-- opts: name (stored in the header), mtime (seconds since 1970), level (0-9, default 6).
function gzip.compress(data, opts)
    opts = opts or {}
    local level = opts.level or 6
    local flags, name = 0, ""
    if opts.name and opts.name ~= "" then
        flags, name = 8, opts.name:gsub("%z", "") .. "\0"
    end
    local xfl = (level >= 9 and 2) or (level <= 1 and 4) or 0
    return "\31\139\8" .. char(flags) .. u32(opts.mtime or 0) .. char(xfl, 255) .. name
        .. gzip.deflate(data, level)
        .. u32(gzip.crc32(data)) .. u32(#data % 4294967296)
end

-- Returns the data and the original file name (if stored), or nil and an error.
-- Joins concatenated members the way gzip -d does.
function gzip.decompress(data)
    local ok, result, name = pcall(function()
        local parts, pos, name = {}, 1, nil
        repeat
            if byte(data, pos) ~= 31 or byte(data, pos + 1) ~= 139 then error("not a gzip file", 0) end
            if byte(data, pos + 2) ~= 8 then error("unsupported compression method", 0) end
            local flags = byte(data, pos + 3) or 0
            pos = pos + 10
            if floor(flags / 4) % 2 == 1 then -- FEXTRA
                local lo, hi = byte(data, pos, pos + 1)
                if not hi then error("file is truncated", 0) end
                pos = pos + 2 + lo + hi * 256
            end
            for bit = 8, 16, 8 do -- FNAME, then FCOMMENT: zero-terminated strings
                if floor(flags / bit) % 2 == 1 then
                    local z = data:find("\0", pos, true)
                    if not z then error("file is truncated", 0) end
                    if bit == 8 then name = name or data:sub(pos, z - 1) end
                    pos = z + 1
                end
            end
            if floor(flags / 2) % 2 == 1 then pos = pos + 2 end -- FHCRC

            local out, n, after = gzip.inflate(data, pos)
            local text = toString(out, n)
            if readU32(data, after) ~= gzip.crc32(text) then error("CRC check failed", 0) end
            if readU32(data, after + 4) ~= n % 4294967296 then error("length check failed", 0) end
            parts[#parts + 1] = text
            pos = after + 8
        until byte(data, pos) ~= 31 -- stops at the end, or at zero padding some tools add
        return concat(parts), name
    end)
    if not ok then return nil, result end
    return result, name
end

---------------------------------------------------------------------------
-- Command line

local args = { ... }
local mode = args[1]
if mode ~= "-c" and mode ~= "-d" then
    if shell and mode == nil then
        print("Usage: gzip -c <file> [output]")
        print("       gzip -d <file.gz> [output]")
    end
    return gzip -- loaded with require, or nothing to do
end

local function resolve(p) return shell and shell.resolve(p) or p end
local function exists(p)
    if fs then return fs.exists(p) end
    local f = io.open(p, "rb")
    if f then f:close() end
    return f ~= nil
end
local function readFile(p)
    local f = (fs and fs.open or io.open)(p, "rb")
    if not f then return nil end
    local s = fs and f.readAll() or f:read("*a")
    if fs then f.close() else f:close() end
    return s or ""
end
local function writeFile(p, s)
    local f = (fs and fs.open or io.open)(p, "wb")
    if not f then return false end
    if fs then f.write(s); f.close() else f:write(s); f:close() end
    return true
end
local fail = printError or function(m) io.stderr:write(m, "\n") end

if not args[2] then
    fail("Usage: gzip " .. mode .. " <file> [output]")
    return
end
local input = resolve(args[2])
if not exists(input) or (fs and fs.isDir(input)) then
    fail("No such file: " .. args[2])
    return
end
local data = readFile(input)
if not data then
    fail("Can't read " .. args[2])
    return
end

local result, output
if mode == "-c" then
    output = args[3] and resolve(args[3]) or input .. ".gz"
    result = gzip.compress(data, { name = input:match("[^/]+$"), mtime = os.epoch and floor(os.epoch("utc") / 1000) or os.time() })
else
    local err
    result, err = gzip.decompress(data)
    if not result then
        fail(args[2] .. ": " .. err)
        return
    end
    output = args[3] and resolve(args[3]) or input:gsub("%.gz$", "")
    if output == input then output = input .. ".out" end
end

if exists(output) then
    fail(output .. " already exists")
    return
end
if not writeFile(output, result) then
    fail("Can't write " .. output)
    return
end
print(("%s -> %s (%d -> %d bytes)"):format(args[2], output, #data, #result))
