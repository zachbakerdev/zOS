--[==[
compression.lua -- pure Lua DEFLATE (RFC 1951) and GZIP (RFC 1952) library.

Requires the bit32 library (built into Lua 5.2; available as a rock for 5.1/5.3).

API
  compression.gzip(data [, opts])        -> gzip-encoded string
      opts.level       0..9 (default 6). 0 = stored blocks only.
      opts.name        original file name (FNAME), must not contain "\0"
      opts.comment     file comment (FCOMMENT), must not contain "\0"
      opts.mtime       modification time, Unix seconds (default 0 = none)
      opts.os          OS code (default 3 = Unix)
      opts.text        set FTEXT flag (hint that data is text)
      opts.header_crc  include FHCRC (CRC16 of header)
      opts.extra       FEXTRA: raw string, or array of { id = "AB", data = "..." }

  compression.gunzip(gzdata [, opts])    -> data, members | nil, errmsg
      Decodes all concatenated members. `members` is an array of header
      tables: { mtime, xfl, os, text, name, comment, extra, extra_fields,
      header_crc }. Trailing zero padding is ignored; other trailing data
      is an error unless opts.ignore_trailing is true.

  compression.crc32(data [, crc])        -> CRC-32 (running value optional)
]==]

local band, bor, bxor = bit32.band, bit32.bor, bit32.bxor
local lshift, rshift = bit32.lshift, bit32.rshift
local byte, char, sub, find = string.byte, string.char, string.sub, string.find
local concat, sort = table.concat, table.sort
local floor, min = math.floor, math.min
local unpack = table.unpack

local compression = { _VERSION = "1.0.0" }

local WSIZE = 32768             -- DEFLATE window size
local WMASK = WSIZE - 1

---------------------------------------------------------------------------
-- Error handling: data errors are raised as tables and turned into
-- `nil, message` at the API boundary. Genuine bugs propagate unchanged.
---------------------------------------------------------------------------

local function fail(msg)
    error({ compression_error = msg }, 0)
end

local function protect(f, ...)
    local ok, a, b = pcall(f, ...)
    if ok then return a, b end
    if type(a) == "table" and a.compression_error then
        return nil, a.compression_error
    end
    error(a, 0)
end

-- Convert t[i..j] (byte values) into a string.
local function bytes_to_string(t, i, j)
    local parts, n = {}, 0
    while i <= j do
        local k = i + 4095
        if k > j then k = j end
        n = n + 1
        parts[n] = char(unpack(t, i, k))
        i = k + 1
    end
    return concat(parts)
end

local function u16le(v)
    return char(band(v, 0xFF), band(rshift(v, 8), 0xFF))
end

local function u32le(v)
    return char(band(v, 0xFF), band(rshift(v, 8), 0xFF),
                band(rshift(v, 16), 0xFF), band(rshift(v, 24), 0xFF))
end

local function read_u16(s, p)
    local a, b = byte(s, p, p + 1)
    return a + b * 256
end

local function read_u32(s, p)
    local a, b, c, d = byte(s, p, p + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

---------------------------------------------------------------------------
-- CRC-32 (ISO 3309 / ITU-T V.42, as used by gzip)
---------------------------------------------------------------------------

local CRC_TABLE = {}
for n = 0, 255 do
    local c = n
    for _ = 1, 8 do
        if band(c, 1) == 1 then
            c = bxor(rshift(c, 1), 0xEDB88320)
        else
            c = rshift(c, 1)
        end
    end
    CRC_TABLE[n] = c
end

local function crc32(s, crc)
    local c = bxor(crc or 0, 0xFFFFFFFF)
    local len = #s
    local i = 1
    -- Process 8 bytes per string.byte call to cut call overhead.
    while i + 7 <= len do
        local b1, b2, b3, b4, b5, b6, b7, b8 = byte(s, i, i + 7)
        c = bxor(rshift(c, 8), CRC_TABLE[band(bxor(c, b1), 0xFF)])
        c = bxor(rshift(c, 8), CRC_TABLE[band(bxor(c, b2), 0xFF)])
        c = bxor(rshift(c, 8), CRC_TABLE[band(bxor(c, b3), 0xFF)])
        c = bxor(rshift(c, 8), CRC_TABLE[band(bxor(c, b4), 0xFF)])
        c = bxor(rshift(c, 8), CRC_TABLE[band(bxor(c, b5), 0xFF)])
        c = bxor(rshift(c, 8), CRC_TABLE[band(bxor(c, b6), 0xFF)])
        c = bxor(rshift(c, 8), CRC_TABLE[band(bxor(c, b7), 0xFF)])
        c = bxor(rshift(c, 8), CRC_TABLE[band(bxor(c, b8), 0xFF)])
        i = i + 8
    end
    while i <= len do
        c = bxor(rshift(c, 8), CRC_TABLE[band(bxor(c, byte(s, i)), 0xFF)])
        i = i + 1
    end
    return bxor(c, 0xFFFFFFFF)
end

compression.crc32 = crc32

---------------------------------------------------------------------------
-- DEFLATE constants (RFC 1951 section 3.2.5)
---------------------------------------------------------------------------

local LBASE = { [0] = 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXT = { [0] = 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DBASE = { [0] = 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DEXT = { [0] = 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
-- Order in which code length code lengths are transmitted.
local CLORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local function reverse_bits(code, len)
    local r = 0
    for _ = 1, len do
        r = bor(lshift(r, 1), band(code, 1))
        code = rshift(code, 1)
    end
    return r
end

-- Canonical Huffman codes from code lengths (RFC 1951 section 3.2.2).
-- Returns codes already bit-reversed, ready for an LSB-first bit writer.
local function canonical_codes(lengths, n)
    local count = {}
    for l = 0, 15 do count[l] = 0 end
    for s = 0, n - 1 do
        local l = lengths[s]
        count[l] = count[l] + 1
    end
    count[0] = 0
    local nextcode, code = {}, 0
    for l = 1, 15 do
        code = lshift(code + count[l - 1], 1)
        nextcode[l] = code
    end
    local codes = {}
    for s = 0, n - 1 do
        local l = lengths[s]
        if l > 0 then
            codes[s] = reverse_bits(nextcode[l], l)
            nextcode[l] = nextcode[l] + 1
        else
            codes[s] = 0
        end
    end
    return codes
end

---------------------------------------------------------------------------
-- Inflate (decompression)
---------------------------------------------------------------------------

-- Build a lookup table indexed by the next `maxlen` input bits (LSB-first).
-- Each entry is symbol * 16 + code length. Enforces the same validity rules
-- as zlib: no over-subscribed codes, and no incomplete codes except a single
-- code of length 1 (literal/length and distance codes only). A distance code
-- with no codes at all is permitted (block of literals only).
local function build_decoder(lengths, n, what)
    local count = {}
    for l = 0, 15 do count[l] = 0 end
    for s = 0, n - 1 do
        local l = lengths[s]
        count[l] = count[l] + 1
    end
    local maxlen = 0
    for l = 15, 1, -1 do
        if count[l] > 0 then maxlen = l; break end
    end
    local tab = {}
    if maxlen == 0 then
        if what == "code length" then fail("invalid code lengths set") end
        return tab, 0
    end
    local left = 1
    for l = 1, 15 do
        left = left * 2 - count[l]
        if left < 0 then fail("invalid " .. what .. " code: over-subscribed") end
    end
    if left > 0 and (what == "code length" or maxlen ~= 1) then
        fail("invalid " .. what .. " code: incomplete")
    end

    count[0] = 0
    local nextcode, code = {}, 0
    for l = 1, 15 do
        code = (code + count[l - 1]) * 2
        nextcode[l] = code
    end
    local size = lshift(1, maxlen)
    for s = 0, n - 1 do
        local l = lengths[s]
        if l > 0 then
            local c = nextcode[l]
            nextcode[l] = c + 1
            local entry = s * 16 + l
            for i = reverse_bits(c, l), size - 1, lshift(1, l) do
                tab[i] = entry
            end
        end
    end
    return tab, maxlen
end

-- Fixed Huffman codes (RFC 1951 section 3.2.6).
local FIXED_LLENS, FIXED_DLENS = {}, {}
for s = 0, 143 do FIXED_LLENS[s] = 8 end
for s = 144, 255 do FIXED_LLENS[s] = 9 end
for s = 256, 279 do FIXED_LLENS[s] = 7 end
for s = 280, 287 do FIXED_LLENS[s] = 8 end
for s = 0, 31 do FIXED_DLENS[s] = 5 end

local FIXED_LTAB, FIXED_LMAX = build_decoder(FIXED_LLENS, 288, "literal/length")
local FIXED_DTAB, FIXED_DMAX = build_decoder(FIXED_DLENS, 32, "distance")
local FIXED_LCODES = canonical_codes(FIXED_LLENS, 288)
local FIXED_DCODES = canonical_codes(FIXED_DLENS, 32)

local FLUSH_AT = 3 * WSIZE   -- output buffer size that triggers a flush

-- Decode one raw DEFLATE stream from s starting at byte index pos.
-- Returns the decompressed string and the index just past the stream.
local function inflate_stream(s, pos)
    local slen = #s
    local bitbuf, bitcnt = 0, 0
    local out, on = {}, 0          -- sliding output buffer (>= 32K history)
    local parts, np = {}, 0        -- completed output chunks
    local flushed = 0              -- bytes moved from `out` into `parts`

    local function getbits(n)
        while bitcnt < n do
            if pos > slen then fail("unexpected end of compressed data") end
            bitbuf = bor(bitbuf, lshift(byte(s, pos), bitcnt))
            pos = pos + 1
            bitcnt = bitcnt + 8
        end
        local v = band(bitbuf, lshift(1, n) - 1)
        bitbuf = rshift(bitbuf, n)
        bitcnt = bitcnt - n
        return v
    end

    -- Returns the decoded symbol, or nil for an invalid code.
    local function decode(tab, maxlen)
        while bitcnt < maxlen and pos <= slen do
            bitbuf = bor(bitbuf, lshift(byte(s, pos), bitcnt))
            pos = pos + 1
            bitcnt = bitcnt + 8
        end
        local e = tab[band(bitbuf, lshift(1, maxlen) - 1)]
        if e == nil then
            if bitcnt < maxlen then fail("unexpected end of compressed data") end
            return nil
        end
        local l = band(e, 15)
        if l > bitcnt then fail("unexpected end of compressed data") end
        bitbuf = rshift(bitbuf, l)
        bitcnt = bitcnt - l
        return rshift(e, 4)
    end

    local function flush()
        local emit = on - WSIZE
        np = np + 1
        parts[np] = bytes_to_string(out, 1, emit)
        for i = 1, WSIZE do out[i] = out[i + emit] end
        flushed = flushed + emit
        on = WSIZE
    end

    local final
    repeat
        final = getbits(1)
        local btype = getbits(2)

        if btype == 0 then
            -- Stored block: skip to byte boundary, then LEN / NLEN / data.
            getbits(bitcnt % 8)
            pos = pos - bitcnt / 8          -- give back whole buffered bytes
            bitbuf, bitcnt = 0, 0
            if pos + 3 > slen then fail("unexpected end of compressed data") end
            local len = read_u16(s, pos)
            local nlen = read_u16(s, pos + 2)
            if len + nlen ~= 65535 then fail("invalid stored block lengths") end
            pos = pos + 4
            local stop = pos + len - 1
            if stop > slen then fail("unexpected end of compressed data") end
            local i = pos
            while i <= stop do
                local j = i + 4095
                if j > stop then j = stop end
                local chunk = { byte(s, i, j) }
                for k = 1, #chunk do
                    on = on + 1
                    out[on] = chunk[k]
                end
                if on >= FLUSH_AT then flush() end
                i = j + 1
            end
            pos = stop + 1

        elseif btype == 1 or btype == 2 then
            local ltab, lmax, dtab, dmax
            if btype == 1 then
                ltab, lmax, dtab, dmax = FIXED_LTAB, FIXED_LMAX, FIXED_DTAB, FIXED_DMAX
            else
                local hlit = getbits(5) + 257
                local hdist = getbits(5) + 1
                local hclen = getbits(4) + 4
                if hlit > 286 then fail("too many length symbols") end
                if hdist > 30 then fail("too many distance symbols") end

                local cl = {}
                for i = 0, 18 do cl[i] = 0 end
                for i = 1, hclen do cl[CLORDER[i]] = getbits(3) end
                local ctab, cmax = build_decoder(cl, 19, "code length")

                local lens, n, total = {}, 0, hlit + hdist
                while n < total do
                    local sym = decode(ctab, cmax)
                    if sym == nil then fail("invalid code lengths set") end
                    if sym < 16 then
                        lens[n] = sym
                        n = n + 1
                    else
                        local val, rep
                        if sym == 16 then
                            if n == 0 then fail("invalid bit length repeat") end
                            val, rep = lens[n - 1], 3 + getbits(2)
                        elseif sym == 17 then
                            val, rep = 0, 3 + getbits(3)
                        else
                            val, rep = 0, 11 + getbits(7)
                        end
                        if n + rep > total then fail("invalid bit length repeat") end
                        for _ = 1, rep do
                            lens[n] = val
                            n = n + 1
                        end
                    end
                end
                if lens[256] == 0 then fail("invalid code -- missing end-of-block") end

                local ll, dl = {}, {}
                for i = 0, hlit - 1 do ll[i] = lens[i] end
                for i = 0, hdist - 1 do dl[i] = lens[hlit + i] end
                ltab, lmax = build_decoder(ll, hlit, "literal/length")
                dtab, dmax = build_decoder(dl, hdist, "distance")
            end

            while true do
                local sym = decode(ltab, lmax)
                if sym == nil then fail("invalid literal/length code") end
                if sym < 256 then
                    on = on + 1
                    out[on] = sym
                    if on >= FLUSH_AT then flush() end
                elseif sym == 256 then
                    break
                else
                    sym = sym - 257
                    if sym >= 29 then fail("invalid literal/length code") end
                    local len = LBASE[sym]
                    local e = LEXT[sym]
                    if e > 0 then len = len + getbits(e) end

                    local dsym = decode(dtab, dmax)
                    if dsym == nil or dsym >= 30 then fail("invalid distance code") end
                    local dist = DBASE[dsym]
                    e = DEXT[dsym]
                    if e > 0 then dist = dist + getbits(e) end
                    if dist > on + flushed then fail("invalid distance too far back") end

                    local from = on - dist
                    for k = 1, len do out[on + k] = out[from + k] end
                    on = on + len
                    if on >= FLUSH_AT then flush() end
                end
            end
        else
            fail("invalid block type")
        end
    until final == 1

    np = np + 1
    parts[np] = bytes_to_string(out, 1, on)
    -- Unused whole bytes still sitting in the bit buffer belong to whatever
    -- follows the stream; the partial last byte is padding.
    return concat(parts), pos - floor(bitcnt / 8)
end

---------------------------------------------------------------------------
-- Deflate (compression)
---------------------------------------------------------------------------

-- Length (3..258) -> length code index (0..28); distance (1..32768) -> code.
local LEN_SYM, DIST_SYM = {}, {}
for c = 0, 28 do
    for l = LBASE[c], LBASE[c] + lshift(1, LEXT[c]) - 1 do
        if l <= 258 then LEN_SYM[l] = c end
    end
end
LEN_SYM[258] = 28
for c = 0, 29 do
    for d = DBASE[c], DBASE[c] + lshift(1, DEXT[c]) - 1 do DIST_SYM[d] = c end
end

local CL_EXTRA = { [16] = 2, [17] = 3, [18] = 7 }

-- Huffman code lengths for freq[0..n-1], limited to `limit` bits.
-- Uses the two-queue Huffman construction; if the tree is too deep the
-- frequencies are flattened and the tree rebuilt (always terminates, and the
-- resulting code is always complete).
local function huffman_lengths(freq, n, limit)
    local lengths, syms = {}, {}
    for i = 0, n - 1 do
        lengths[i] = 0
        if freq[i] > 0 then syms[#syms + 1] = i end
    end
    local k = #syms
    if k == 0 then return lengths end
    if k == 1 then
        lengths[syms[1]] = 1
        return lengths
    end

    local w = {}
    for i = 1, k do w[i] = freq[syms[i]] end

    while true do
        local order = {}
        for i = 1, k do order[i] = i end
        sort(order, function(a, b)
            if w[a] ~= w[b] then return w[a] < w[b] end
            return a < b
        end)

        local weight, parent = {}, {}
        for i = 1, k do weight[i] = w[order[i]] end
        local li, ii, nextnode = 1, k + 1, k + 1
        for _ = 1, k - 1 do
            local a, b
            if li <= k and (ii >= nextnode or weight[li] <= weight[ii]) then
                a = li; li = li + 1
            else
                a = ii; ii = ii + 1
            end
            if li <= k and (ii >= nextnode or weight[li] <= weight[ii]) then
                b = li; li = li + 1
            else
                b = ii; ii = ii + 1
            end
            weight[nextnode] = weight[a] + weight[b]
            parent[a], parent[b] = nextnode, nextnode
            nextnode = nextnode + 1
        end

        local root = nextnode - 1
        local depth = { [root] = 0 }
        local maxd = 0
        for i = root - 1, 1, -1 do
            local d = depth[parent[i]] + 1
            depth[i] = d
            if i <= k and d > maxd then maxd = d end
        end

        if maxd <= limit then
            for i = 1, k do lengths[syms[order[i]]] = depth[i] end
            return lengths
        end
        for i = 1, k do w[i] = floor((w[i] + 1) / 2) end
    end
end

-- Make sure at least two symbols have nonzero frequency so every Huffman
-- code we emit is complete (as required by strict decoders such as zlib).
local function ensure_two(freq, n)
    local f, used = {}, 0
    for i = 0, n - 1 do
        f[i] = freq[i]
        if f[i] > 0 then used = used + 1 end
    end
    local i = 0
    while used < 2 and i < n do
        if f[i] == 0 then
            f[i] = 1
            used = used + 1
        end
        i = i + 1
    end
    return f
end

-- Per-level parameters (as in zlib): good_length, max_lazy, nice_length,
-- max_chain, lazy evaluation.
local LEVELS = {
    [1] = { 4, 4, 8, 4, false },
    [2] = { 4, 5, 16, 8, false },
    [3] = { 4, 6, 32, 32, false },
    [4] = { 4, 4, 16, 16, true },
    [5] = { 8, 16, 32, 32, true },
    [6] = { 8, 16, 128, 128, true },
    [7] = { 8, 32, 128, 256, true },
    [8] = { 32, 128, 258, 1024, true },
    [9] = { 32, 258, 258, 4096, true },
}

local BLOCK_TOKENS = 32768   -- symbols per block before a flush
local TOO_FAR = 4096         -- length-3 matches farther than this are dropped
local CHUNK = 262144         -- input bytes loaded into the match buffer at a time

local function deflate_raw(s, level)
    local n = #s

    -- Bit writer ------------------------------------------------------
    local outparts, onp = {}, 0
    local ob, obn = {}, 0
    local bb, bc = 0, 0

    local function putbits(v, nb)
        bb = bor(bb, lshift(v, bc))
        bc = bc + nb
        while bc >= 8 do
            obn = obn + 1
            ob[obn] = band(bb, 0xFF)
            bb = rshift(bb, 8)
            bc = bc - 8
        end
        if obn >= 4096 then
            onp = onp + 1
            outparts[onp] = char(unpack(ob, 1, obn))
            obn = 0
        end
    end

    local function flush_ob()
        if obn > 0 then
            onp = onp + 1
            outparts[onp] = char(unpack(ob, 1, obn))
            obn = 0
        end
    end

    local function align()
        if bc > 0 then putbits(0, 8 - bc) end
    end

    local function put_stored(raw, final)
        local len, p = #raw, 1
        repeat
            local chunk = min(len - p + 1, 65535)
            local last = p + chunk > len
            putbits((final and last) and 1 or 0, 1)
            putbits(0, 2)
            align()
            putbits(chunk, 16)
            putbits(65535 - chunk, 16)
            flush_ob()
            onp = onp + 1
            outparts[onp] = sub(raw, p, p + chunk - 1)
            p = p + chunk
        until p > len
    end

    local function finish()
        align()
        flush_ob()
        return concat(outparts)
    end

    if level == 0 then
        put_stored(s, true)
        return finish()
    end

    -- Token buffer ----------------------------------------------------
    local tl, td, ntok = {}, {}, 0      -- literal byte / match length, distance
    local lfreq, dfreq = {}, {}
    local block_start, covered = 1, 0

    local function reset_block()
        ntok = 0
        for i = 0, 285 do lfreq[i] = 0 end
        for i = 0, 29 do dfreq[i] = 0 end
        lfreq[256] = 1                    -- end-of-block
    end
    reset_block()

    local function write_tokens(lcodes, llens, dcodes, dlens)
        for i = 1, ntok do
            local d, v = td[i], tl[i]
            if d == 0 then
                putbits(lcodes[v], llens[v])
            else
                local c = LEN_SYM[v]
                local sym = 257 + c
                putbits(lcodes[sym], llens[sym])
                local e = LEXT[c]
                if e > 0 then putbits(v - LBASE[c], e) end
                c = DIST_SYM[d]
                putbits(dcodes[c], dlens[c])
                e = DEXT[c]
                if e > 0 then putbits(d - DBASE[c], e) end
            end
        end
        putbits(lcodes[256], llens[256])
    end

    local function flush_block(block_end, final)
        local rawlen = block_end - block_start + 1
        local fbit = final and 1 or 0

        -- Dynamic Huffman trees.
        local llens = huffman_lengths(ensure_two(lfreq, 286), 286, 15)
        local dlens = huffman_lengths(ensure_two(dfreq, 30), 30, 15)
        local hlit = 286
        while hlit > 257 and llens[hlit - 1] == 0 do hlit = hlit - 1 end
        local hdist = 30
        while hdist > 1 and dlens[hdist - 1] == 0 do hdist = hdist - 1 end

        -- Run-length encode the combined code length sequence.
        local seq, total = {}, 0
        for i = 0, hlit - 1 do total = total + 1; seq[total] = llens[i] end
        for i = 0, hdist - 1 do total = total + 1; seq[total] = dlens[i] end

        local rsym, rext, rn = {}, {}, 0
        local cfreq = {}
        for i = 0, 18 do cfreq[i] = 0 end
        local function add(sym, ext)
            rn = rn + 1
            rsym[rn], rext[rn] = sym, ext
            cfreq[sym] = cfreq[sym] + 1
        end
        local i = 1
        while i <= total do
            local v, run = seq[i], 1
            while i + run <= total and seq[i + run] == v do run = run + 1 end
            local r = run
            if v == 0 then
                while r >= 11 do
                    local c = min(r, 138)
                    add(18, c - 11)
                    r = r - c
                end
                if r >= 3 then
                    add(17, r - 3)
                    r = 0
                end
                for _ = 1, r do add(0, 0) end
            else
                add(v, 0)
                r = r - 1
                while r >= 3 do
                    local c = min(r, 6)
                    add(16, c - 3)
                    r = r - c
                end
                for _ = 1, r do add(v, 0) end
            end
            i = i + run
        end

        local clens = huffman_lengths(ensure_two(cfreq, 19), 19, 7)
        local hclen = 19
        while hclen > 4 and clens[CLORDER[hclen]] == 0 do hclen = hclen - 1 end

        -- Compare encoded sizes (in bits).
        local extra = 0
        for c = 0, 28 do extra = extra + lfreq[257 + c] * LEXT[c] end
        for c = 0, 29 do extra = extra + dfreq[c] * DEXT[c] end

        local dyn = 3 + 14 + 3 * hclen + extra
        for j = 1, rn do
            local sy = rsym[j]
            dyn = dyn + clens[sy] + (CL_EXTRA[sy] or 0)
        end
        local fixed = 3 + extra
        for sy = 0, 285 do
            dyn = dyn + lfreq[sy] * llens[sy]
            fixed = fixed + lfreq[sy] * FIXED_LLENS[sy]
        end
        for c = 0, 29 do
            dyn = dyn + dfreq[c] * dlens[c]
            fixed = fixed + dfreq[c] * 5
        end
        local chunks = rawlen > 0 and floor((rawlen + 65534) / 65535) or 1
        local stored = chunks * 42 + rawlen * 8

        if stored < fixed and stored < dyn then
            put_stored(sub(s, block_start, block_end), final)
        elseif fixed <= dyn then
            putbits(fbit, 1)
            putbits(1, 2)
            write_tokens(FIXED_LCODES, FIXED_LLENS, FIXED_DCODES, FIXED_DLENS)
        else
            putbits(fbit, 1)
            putbits(2, 2)
            putbits(hlit - 257, 5)
            putbits(hdist - 1, 5)
            putbits(hclen - 4, 4)
            for j = 1, hclen do putbits(clens[CLORDER[j]], 3) end
            local ccodes = canonical_codes(clens, 19)
            for j = 1, rn do
                local sy = rsym[j]
                putbits(ccodes[sy], clens[sy])
                if sy >= 16 then putbits(rext[j], CL_EXTRA[sy]) end
            end
            write_tokens(canonical_codes(llens, 286), llens,
                         canonical_codes(dlens, 30), dlens)
        end

        block_start = block_end + 1
        reset_block()
    end

    local function emit_lit(b, p)
        ntok = ntok + 1
        tl[ntok], td[ntok] = b, 0
        lfreq[b] = lfreq[b] + 1
        covered = p
    end

    local function emit_match(len, dist, p)
        ntok = ntok + 1
        tl[ntok], td[ntok] = len, dist
        local ls = 257 + LEN_SYM[len]
        lfreq[ls] = lfreq[ls] + 1
        local ds = DIST_SYM[dist]
        dfreq[ds] = dfreq[ds] + 1
        covered = p + len - 1
    end

    -- Input buffer: buf[i] is the byte at absolute position i + off. --
    local buf, off, bufend = {}, 0, 0

    local function refill(p)
        local from = p - WSIZE - 2
        if from < 1 then from = 1 end
        local to = bufend + CHUNK
        if to > n then to = n end
        local nb, k, i = {}, 0, from
        while i <= to do
            local j = i + 4095
            if j > to then j = to end
            local t = { byte(s, i, j) }
            for x = 1, #t do
                k = k + 1
                nb[k] = t[x]
            end
            i = j + 1
        end
        buf, off, bufend = nb, from - 1, to
    end

    -- Hash chains: head[hash] = most recent position, prev[pos & WMASK] =
    -- previous position with the same hash.
    local head, prev = {}, {}

    local function insert(p)       -- caller guarantees p + 2 <= n
        local i = p - off
        local h = band(bxor(lshift(buf[i], 10), lshift(buf[i + 1], 5), buf[i + 2]), 0x7FFF)
        local old = head[h]
        prev[band(p, WMASK)] = old
        head[h] = p
        return old
    end

    local function longest_match(p, cand, best, chain, nice)
        local maxlen = n - p + 1
        if maxlen > 258 then maxlen = 258 end
        if best >= maxlen then return 0 end
        local limit = p - WSIZE
        local pi = p - off
        local b0, b1, b2 = buf[pi], buf[pi + 1], buf[pi + 2]
        local bestpos
        while cand and cand >= limit do
            local ci = cand - off
            if buf[ci + best] == buf[pi + best] and buf[ci] == b0
               and buf[ci + 1] == b1 and buf[ci + 2] == b2 then
                local l = 3
                while l < maxlen and buf[ci + l] == buf[pi + l] do l = l + 1 end
                if l > best then
                    best, bestpos = l, cand
                    if l >= nice or l >= maxlen then break end
                end
            end
            chain = chain - 1
            if chain <= 0 then break end
            local nx = prev[band(cand, WMASK)]
            if nx == nil or nx >= cand then break end
            cand = nx
        end
        if bestpos then return best, bestpos end
        return 0
    end

    local cfg = LEVELS[level]
    local good, max_lazy, nice, max_chain, lazy = cfg[1], cfg[2], cfg[3], cfg[4], cfg[5]
    local pos = 1

    if not lazy then
        -- Greedy matching (levels 1-3).
        while pos <= n do
            if bufend < n and pos + 262 > bufend then refill(pos) end
            local h
            if pos + 2 <= n then h = insert(pos) end
            local l, mp = 0, nil
            if h and pos - h <= WSIZE then
                l, mp = longest_match(pos, h, 2, max_chain, nice)
            end
            if l >= 3 and not (l == 3 and pos - mp > TOO_FAR) then
                emit_match(l, pos - mp, pos)
                if l <= max_lazy then
                    for q = pos + 1, pos + l - 1 do
                        if q + 2 <= n then insert(q) end
                    end
                end
                pos = pos + l
            else
                emit_lit(buf[pos - off], pos)
                pos = pos + 1
            end
            if ntok >= BLOCK_TOKENS then flush_block(covered, false) end
        end
    else
        -- Lazy matching (levels 4-9): defer a match by one byte to see if
        -- a longer one starts at the next position.
        local mlen, mpos = 2, nil
        local avail = false
        while pos <= n do
            if bufend < n and pos + 262 > bufend then refill(pos) end
            local h
            if pos + 2 <= n then h = insert(pos) end
            local plen, ppos = mlen, mpos
            mlen, mpos = 2, nil
            if h and plen < max_lazy and pos - h <= WSIZE then
                local chain = max_chain
                if plen >= good then chain = floor(chain / 4) + 1 end
                local l, mp = longest_match(pos, h, plen, chain, nice)
                if l >= 3 and not (l == 3 and pos - mp > TOO_FAR) then
                    mlen, mpos = l, mp
                end
            end

            if plen >= 3 and mlen <= plen then
                local start = pos - 1
                emit_match(plen, start - ppos, start)
                local last = start + plen - 1
                for q = pos + 1, last do
                    if q + 2 <= n then insert(q) end
                end
                pos = last + 1
                avail = false
                mlen, mpos = 2, nil
                if ntok >= BLOCK_TOKENS then flush_block(covered, false) end
            elseif avail then
                emit_lit(buf[pos - 1 - off], pos - 1)
                pos = pos + 1
                if ntok >= BLOCK_TOKENS then flush_block(covered, false) end
            else
                avail = true
                pos = pos + 1
            end
        end
        if avail then emit_lit(buf[pos - 1 - off], pos - 1) end
    end

    flush_block(n, true)
    return finish()
end

local function check_level(level, fname)
    if level == nil then return 6 end
    if type(level) ~= "number" or level ~= floor(level) or level < 0 or level > 9 then
        error(fname .. ": level must be an integer 0..9", 3)
    end
    return level
end

---------------------------------------------------------------------------
-- GZIP (RFC 1952)
---------------------------------------------------------------------------

local FTEXT, FHCRC, FEXTRA, FNAME, FCOMMENT = 1, 2, 4, 8, 16
local DEFAULT_OS = 3 -- Unix

function compression.gzip(data, opts)
    if type(data) ~= "string" then error("gzip: expected string", 2) end
    opts = opts or {}
    local level = check_level(opts.level, "gzip")

    local flg = 0
    local extra = opts.extra
    if extra ~= nil then
        if type(extra) == "table" then
            local t = {}
            for i, f in ipairs(extra) do
                if type(f.id) ~= "string" or #f.id ~= 2 then
                    error("gzip: extra field " .. i .. " needs a 2-byte id", 2)
                end
                local d = f.data or ""
                if #d > 65535 then error("gzip: extra field " .. i .. " too long", 2) end
                t[i] = f.id .. u16le(#d) .. d
            end
            extra = concat(t)
        elseif type(extra) ~= "string" then
            error("gzip: extra must be a string or array of fields", 2)
        end
        if #extra > 65535 then error("gzip: extra field too long", 2) end
        flg = flg + FEXTRA
    end
    local name, comment = opts.name, opts.comment
    if name then
        if find(name, "\0", 1, true) then error("gzip: name contains NUL", 2) end
        flg = flg + FNAME
    end
    if comment then
        if find(comment, "\0", 1, true) then error("gzip: comment contains NUL", 2) end
        flg = flg + FCOMMENT
    end
    if opts.text then flg = flg + FTEXT end
    if opts.header_crc then flg = flg + FHCRC end

    local mtime = opts.mtime or 0
    if type(mtime) ~= "number" or mtime < 0 or mtime > 4294967295 then
        error("gzip: mtime must be 0..2^32-1", 2)
    end
    mtime = floor(mtime)
    local os_code = opts.os or DEFAULT_OS
    local xfl = (level == 9 and 2) or (level == 1 and 4) or 0

    local h = { "\31\139\8", char(flg), u32le(mtime), char(xfl, os_code) }
    if extra then h[#h + 1] = u16le(#extra); h[#h + 1] = extra end
    if name then h[#h + 1] = name .. "\0" end
    if comment then h[#h + 1] = comment .. "\0" end
    local header = concat(h)
    if opts.header_crc then
        header = header .. u16le(band(crc32(header), 0xFFFF))
    end

    return concat({
        header,
        deflate_raw(data, level),
        u32le(crc32(data)),
        u32le(#data % 4294967296),
    })
end

local function gunzip_impl(s, opts)
    local slen = #s
    local pos = 1
    local outs, members = {}, {}

    local function need(count, what)
        if pos + count - 1 > slen then
            fail("unexpected end of file (truncated gzip " .. what .. ")")
        end
    end

    repeat
        local hstart = pos
        need(10, "header")
        local id1, id2, cm, flg = byte(s, pos, pos + 3)
        if id1 ~= 31 or id2 ~= 139 then fail("not in gzip format") end
        if cm ~= 8 then fail("unknown compression method " .. cm) end
        if flg >= 32 then fail("reserved header flag bits set") end

        local hdr = {
            mtime = read_u32(s, pos + 4),
            xfl = byte(s, pos + 8),
            os = byte(s, pos + 9),
            text = band(flg, FTEXT) ~= 0,
        }
        pos = pos + 10

        if band(flg, FEXTRA) ~= 0 then
            need(2, "header")
            local xlen = read_u16(s, pos)
            pos = pos + 2
            need(xlen, "header")
            local extra = sub(s, pos, pos + xlen - 1)
            pos = pos + xlen
            hdr.extra = extra
            -- Parse SI1 SI2 LEN data subfields if well formed.
            local fields, p, ok = {}, 1, true
            while p <= xlen do
                if p + 3 > xlen then ok = false; break end
                local len = read_u16(extra, p + 2)
                if p + 3 + len > xlen then ok = false; break end
                fields[#fields + 1] = { id = sub(extra, p, p + 1), data = sub(extra, p + 4, p + 3 + len) }
                p = p + 4 + len
            end
            if ok then hdr.extra_fields = fields end
        end
        if band(flg, FNAME) ~= 0 then
            local z = find(s, "\0", pos, true)
            if not z then fail("unexpected end of file (truncated gzip header)") end
            hdr.name = sub(s, pos, z - 1)
            pos = z + 1
        end
        if band(flg, FCOMMENT) ~= 0 then
            local z = find(s, "\0", pos, true)
            if not z then fail("unexpected end of file (truncated gzip header)") end
            hdr.comment = sub(s, pos, z - 1)
            pos = z + 1
        end
        if band(flg, FHCRC) ~= 0 then
            need(2, "header")
            local stored = read_u16(s, pos)
            if stored ~= band(crc32(sub(s, hstart, pos - 1)), 0xFFFF) then
                fail("header CRC16 mismatch")
            end
            hdr.header_crc = stored
            pos = pos + 2
        end

        local data
        data, pos = inflate_stream(s, pos)

        need(8, "trailer")
        local crc, isize = read_u32(s, pos), read_u32(s, pos + 4)
        pos = pos + 8
        if crc ~= crc32(data) then fail("CRC32 mismatch (data corrupted)") end
        if isize ~= #data % 4294967296 then fail("ISIZE mismatch (data corrupted)") end

        outs[#outs + 1] = data
        members[#members + 1] = hdr

        -- A gzip file is a series of members; anything else after the last
        -- member must be zero padding (or explicitly ignored).
        local more = false
        if pos <= slen then
            if byte(s, pos) == 31 and byte(s, pos + 1) == 139 then
                more = true
            elseif not opts.ignore_trailing then
                for i = pos, slen do
                    if byte(s, i) ~= 0 then fail("trailing garbage after gzip data") end
                end
            end
        end
    until not more

    return concat(outs), members
end

function compression.gunzip(s, opts)
    if type(s) ~= "string" then error("gunzip: expected string", 2) end
    return protect(gunzip_impl, s, opts or {})
end

return compression
