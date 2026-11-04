--[==[
tar.lua -- pure Lua tar archive library (POSIX.1-1988 ustar / POSIX.1-2001 pax).

Works on Lua 5.1 - 5.4 and CC: Tweaked, on strings only: there is no file
access. Optional:
  * compression.lua  -- transparent .tar.gz reading and writing

Writing produces POSIX pax archives: plain ustar headers, plus a pax
extended header ('x') only for entries whose metadata does not fit in ustar
(paths > 255 bytes, link targets > 100 bytes, sizes >= 8 GiB, large uid/gid,
long user/group names, fractional or negative timestamps). An archive with
no such entries is byte-for-byte plain ustar.

Reading accepts ustar, pax ('x' and 'g' headers), GNU (long names 'L'/'K',
base-256 numeric fields), star (130-byte prefix) and pre-POSIX v7 archives.
Header checksums are verified (signed and unsigned sums, as POSIX requires).

ENTRIES
  An entry is a table:
    name       path inside the archive ("dir/file.txt"; directories may end in "/")
    type       "file" (default), "directory", "symlink", "hardlink", "chardev",
               "blockdev", "fifo", "contiguous"
    data       file contents (string), for type "file" / "contiguous"
    mode       permission bits, number (e.g. 420 or tonumber("644", 8)) or
               octal string ("644"); default 644 for files, 755 for dirs
    mtime      Unix seconds (may be fractional); default os.time()
    uid, gid   numbers, default 0
    uname, gname   strings, default ""
    linkname   target of a symlink / hardlink
    devmajor, devminor   for chardev / blockdev
    atime, ctime   optional, written as pax records
    pax        optional table of extra pax records { ["key"] = "value" }

  Parsed entries additionally carry `size`, `typeflag` (the raw header byte)
  and `pax` (the merged extended attributes that applied, if any).

API
  tar.create(entries [, opts])          -> archive string | nil, errmsg
      opts.format       "pax" (default) or "ustar" (strict: fail if any entry
                        needs a pax header)
      opts.global_pax   table of records written once as a global ('g') header
      opts.record_size  pad output to a multiple of this (default 10240, the
                        POSIX default of 20 blocks; use 512 for no padding)
      opts.gzip         true or level 0..9: gzip the result (needs compression.lua)

  tar.parse(archive [, opts])           -> entries, global_pax | nil, errmsg
      gzip input is detected and decompressed automatically.
      opts.strict       require the two-block end-of-archive marker
]==]

local byte, char, sub, find, rep = string.byte, string.char, string.sub, string.find, string.rep
local format = string.format
local concat, sort = table.concat, table.sort
local floor = math.floor

local tar = { _VERSION = "1.0.0" }

local BLOCK = 512
local ZERO_BLOCK = rep("\0", BLOCK)

---------------------------------------------------------------------------
-- Error handling (same convention as compression.lua)
---------------------------------------------------------------------------

local function fail(msg)
    error({ tar_error = msg }, 0)
end

local function protect(f, ...)
    local ok, a, b = pcall(f, ...)
    if ok then return a, b end
    if type(a) == "table" and a.tar_error then
        return nil, a.tar_error
    end
    if type(a) == "table" and a.compression_error then
        return nil, a.compression_error
    end
    error(a, 0)
end

local function get_compression()
    local ok, mod = pcall(require, "compression")
    if not ok then fail("gzip support requires compression.lua") end
    return mod
end

---------------------------------------------------------------------------
-- Type flags
---------------------------------------------------------------------------

local TYPE_TO_FLAG = {
    file = "0", hardlink = "1", symlink = "2", chardev = "3",
    blockdev = "4", directory = "5", fifo = "6", contiguous = "7",
}
local FLAG_TO_TYPE = {
    ["0"] = "file", ["\0"] = "file", ["1"] = "hardlink", ["2"] = "symlink",
    ["3"] = "chardev", ["4"] = "blockdev", ["5"] = "directory",
    ["6"] = "fifo", ["7"] = "contiguous",
}
-- Types whose header is never followed by data blocks.
local HEADER_ONLY = {
    ["1"] = true, ["2"] = true, ["3"] = true,
    ["4"] = true, ["5"] = true, ["6"] = true,
}

---------------------------------------------------------------------------
-- Numeric fields
---------------------------------------------------------------------------

-- True when s consists only of the bytes in `set` (plain-byte check; avoids
-- "%z", which is not portable across Lua versions).
local function only_bytes(s, set)
    for i = 1, #s do
        if not set[byte(s, i)] then return false end
    end
    return true
end
local NUL_OR_SPACE = { [0] = true, [32] = true }
local NUL_ONLY = { [0] = true }

local function is_int(n)
    return type(n) == "number" and n == floor(n) and n == n
end

-- True when n fits in an octal field of `width` bytes (width-1 digits + NUL).
local function fits_octal(n, width)
    return is_int(n) and n >= 0 and n < 8 ^ (width - 1)
end

local function octal(n, width)
    local digits, d = {}, width - 1
    for i = d, 1, -1 do
        local r = n % 8
        digits[i] = char(48 + r)
        n = (n - r) / 8
    end
    return concat(digits) .. "\0"
end

-- Decimal formatting for pax records (integers exactly, fractions trimmed).
local function decimal(n)
    if is_int(n) and math.abs(n) < 2 ^ 53 then
        return format("%.0f", n)
    end
    local s = format("%.9f", n):gsub("0+$", ""):gsub("%.$", "")
    return s
end

local function parse_numeric(h, off, len, what)
    local b = byte(h, off)
    if b >= 128 then
        -- GNU base-256: high bit set; 0xFF-led values are negative.
        local v = 0
        if b >= 192 then
            for i = off, off + len - 1 do v = v * 256 + (255 - byte(h, i)) end
            return -(v + 1)
        end
        v = b - 128
        for i = off + 1, off + len - 1 do v = v * 256 + byte(h, i) end
        return v
    end
    local field = sub(h, off, off + len - 1)
    local digits, rest = field:match("^ *([0-7]*)(.*)$")
    if not only_bytes(rest, NUL_OR_SPACE) then
        fail("invalid " .. what .. " field in header")
    end
    local v = 0
    for i = 1, #digits do v = v * 8 + (byte(digits, i) - 48) end
    return v
end

---------------------------------------------------------------------------
-- String fields
---------------------------------------------------------------------------

local function cstr(h, off, len)
    local f = sub(h, off, off + len - 1)
    local z = find(f, "\0", 1, true)
    if z then f = sub(f, 1, z - 1) end
    return f
end

local function pad_field(s, len)
    return s .. rep("\0", len - #s)
end

local function pad_block(n)
    return rep("\0", (BLOCK - n % BLOCK) % BLOCK)
end

---------------------------------------------------------------------------
-- Checksums
---------------------------------------------------------------------------

-- Returns unsigned and signed sums with the checksum field read as spaces.
local function header_sums(h)
    local u, s = 0, 0
    for i = 1, BLOCK, 64 do
        local bytes = { byte(h, i, i + 63) }
        for j = 1, 64 do
            local pos = i + j - 1
            local c = (pos >= 149 and pos <= 156) and 32 or bytes[j]
            u = u + c
            s = s + (c >= 128 and c - 256 or c)
        end
    end
    return u, s
end

---------------------------------------------------------------------------
-- Pax extended header records: "<len> <key>=<value>\n"
---------------------------------------------------------------------------

local function pax_record(key, value)
    local body = " " .. key .. "=" .. value .. "\n"
    local n = #body + #tostring(#body)
    if #tostring(n) ~= #tostring(#body) then n = #body + #tostring(n) end
    return n .. body
end

local function parse_pax(data, into)
    local p, len = 1, #data
    while p <= len do
        if byte(data, p) == 0 then
            -- Some writers pad the record area with NULs.
            if not only_bytes(sub(data, p), NUL_ONLY) then fail("malformed pax header") end
            break
        end
        local sp = find(data, " ", p, true)
        local n = sp and tonumber(sub(data, p, sp - 1))
        if not n or not sub(data, p, sp - 1):match("^%d+$") or n < 5 or p + n - 1 > len
                or byte(data, p + n - 1) ~= 10 then
            fail("malformed pax header record")
        end
        local kv = sub(data, sp + 1, p + n - 2)
        local eq = find(kv, "=", 1, true)
        if not eq or eq == 1 then fail("malformed pax header record") end
        local key, value = sub(kv, 1, eq - 1), sub(kv, eq + 1)
        if value == "" then
            into[key] = false          -- explicit deletion of an inherited value
        else
            into[key] = value
        end
        p = p + n
    end
    return into
end

local function pax_number(v, key)
    local n = tonumber(v)
    if not n or not v:match("^%-?%d+%.?%d*$") then
        fail("invalid pax " .. key .. " value: " .. v)
    end
    return n
end

---------------------------------------------------------------------------
-- Writer
---------------------------------------------------------------------------

-- Split a path into ustar (prefix, name), or nil if it cannot be split.
local function split_name(path)
    if #path <= 100 then return "", path end
    local i = 0
    while true do
        i = find(path, "/", i + 1, true)
        if not i then return nil end
        local plen, nlen = i - 1, #path - i
        if plen > 155 then return nil end
        if plen >= 1 and nlen >= 1 and nlen <= 100 then
            return sub(path, 1, i - 1), sub(path, i + 1)
        end
    end
end

local function build_header(f)
    local h = concat({
        pad_field(f.name, 100),
        octal(f.mode, 8),
        octal(f.uid, 8),
        octal(f.gid, 8),
        octal(f.size, 12),
        octal(f.mtime, 12),
        "        ",                     -- checksum placeholder
        f.typeflag,
        pad_field(f.linkname, 100),
        "ustar\0", "00",
        pad_field(f.uname, 32),
        pad_field(f.gname, 32),
        octal(f.devmajor, 8),
        octal(f.devminor, 8),
        pad_field(f.prefix, 155),
        rep("\0", 12),
    })
    local sum = header_sums(h)
    return sub(h, 1, 148) .. octal(sum, 7) .. " " .. sub(h, 157)
end

local function normalize_mode(mode, default, name)
    if mode == nil then return default end
    if type(mode) == "string" then
        if not mode:match("^[0-7]+$") then fail("invalid mode for " .. name .. ": " .. mode) end
        mode = tonumber(mode, 8)
    end
    if not is_int(mode) or mode < 0 or mode > 4095 then
        fail("invalid mode for " .. name .. ": " .. tostring(mode))
    end
    return mode
end

local function sorted_keys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    sort(keys)
    return keys
end

local function emit_pax(out, typeflag, hname, records, mtime)
    local data = concat(records)
    out[#out + 1] = build_header({
        name = hname, prefix = "", mode = 420, uid = 0, gid = 0,
        size = #data, mtime = mtime, typeflag = typeflag, linkname = "",
        uname = "", gname = "", devmajor = 0, devminor = 0,
    })
    out[#out + 1] = data
    out[#out + 1] = pad_block(#data)
end

local function write_entry(out, e, strict, now)
    if type(e) ~= "table" then fail("entry must be a table") end
    local name = e.name
    if type(name) ~= "string" or name == "" then fail("entry name must be a non-empty string") end
    if find(name, "\0", 1, true) then fail("entry name contains NUL: " .. name) end

    local typ = e.type
    if typ == nil then
        typ = (sub(name, -1) == "/" and e.data == nil) and "directory" or "file"
    end
    local typeflag = TYPE_TO_FLAG[typ]
    if not typeflag then fail("unknown entry type '" .. tostring(typ) .. "' for " .. name) end

    if typ == "directory" and sub(name, -1) ~= "/" then name = name .. "/" end

    local data = ""
    if typ == "file" or typ == "contiguous" then
        data = e.data or ""
        if type(data) ~= "string" then fail("entry data must be a string: " .. name) end
    elseif e.data ~= nil and e.data ~= "" then
        fail("entry of type " .. typ .. " cannot have data: " .. name)
    end

    local linkname = e.linkname or ""
    if (typ == "symlink" or typ == "hardlink") and linkname == "" then
        fail(typ .. " requires a linkname: " .. name)
    end
    if find(linkname, "\0", 1, true) then fail("linkname contains NUL: " .. name) end

    local records = {}
    local function need(key, value, why)
        if strict then fail(name .. ": " .. why .. " (not representable in ustar)") end
        records[key] = value
    end

    local f = {
        typeflag = typeflag,
        mode = normalize_mode(e.mode, typ == "directory" and 493 or
                              typ == "symlink" and 511 or 420, name),
        size = #data,
        linkname = linkname,
        devmajor = e.devmajor or 0,
        devminor = e.devminor or 0,
    }

    local prefix, short = split_name(name)
    if prefix then
        f.prefix, f.name = prefix, short
    else
        need("path", name, "path too long")
        f.prefix, f.name = "", sub(name, 1, 100)
    end

    if #linkname > 100 then
        need("linkpath", linkname, "link target too long")
        f.linkname = sub(linkname, 1, 100)
    end

    if not fits_octal(f.size, 12) then
        need("size", decimal(f.size), "file too large")
        f.size = 0
    end

    local mtime = e.mtime or now
    if type(mtime) ~= "number" then fail("mtime must be a number: " .. name) end
    if fits_octal(mtime, 12) then
        f.mtime = mtime
    else
        need("mtime", decimal(mtime), "mtime out of range or fractional")
        local m = floor(mtime)
        f.mtime = fits_octal(m, 12) and m or 0
    end

    for _, k in ipairs({ "uid", "gid" }) do
        local v = e[k] or 0
        if not is_int(v) or v < 0 then fail("invalid " .. k .. " for " .. name) end
        if fits_octal(v, 8) then
            f[k] = v
        else
            need(k, decimal(v), k .. " too large")
            f[k] = 0
        end
    end

    for _, k in ipairs({ "uname", "gname" }) do
        local v = e[k] or ""
        if type(v) ~= "string" or find(v, "\0", 1, true) then fail("invalid " .. k .. " for " .. name) end
        if #v <= 31 then
            f[k] = v
        else
            need(k, v, k .. " too long")
            f[k] = ""
        end
    end

    for _, k in ipairs({ "devmajor", "devminor" }) do
        if not fits_octal(f[k], 8) then fail("invalid " .. k .. " for " .. name) end
    end

    for _, k in ipairs({ "atime", "ctime" }) do
        if e[k] ~= nil then
            if type(e[k]) ~= "number" then fail(k .. " must be a number: " .. name) end
            need(k, decimal(e[k]), k .. " requires pax")
        end
    end

    if e.pax then
        for k, v in pairs(e.pax) do
            if type(k) ~= "string" or k == "" or find(k, "=", 1, true) or find(k, "\0", 1, true) then
                fail("invalid pax key for " .. name)
            end
            need(k, tostring(v), "custom pax records")
        end
    end

    if next(records) then
        local recs = {}
        for _, k in ipairs(sorted_keys(records)) do
            recs[#recs + 1] = pax_record(k, records[k])
        end
        local base = name:gsub("/$", ""):match("([^/]*)$")
        emit_pax(out, "x", "PaxHeaders.0/" .. sub(base, 1, 87), recs, f.mtime)
    end

    out[#out + 1] = build_header(f)
    out[#out + 1] = data
    out[#out + 1] = pad_block(#data)
end

local function create_impl(entries, opts)
    if type(entries) ~= "table" then fail("entries must be an array") end
    local strict = opts.format == "ustar"
    if opts.format ~= nil and opts.format ~= "ustar" and opts.format ~= "pax" then
        fail("unknown format: " .. tostring(opts.format))
    end
    local now = floor(os.time())
    local out = {}

    if opts.global_pax and next(opts.global_pax) then
        if strict then fail("global pax header not representable in ustar") end
        local recs = {}
        for _, k in ipairs(sorted_keys(opts.global_pax)) do
            recs[#recs + 1] = pax_record(k, tostring(opts.global_pax[k]))
        end
        emit_pax(out, "g", "pax_global_header", recs, now)
    end

    for _, e in ipairs(entries) do write_entry(out, e, strict, now) end

    out[#out + 1] = ZERO_BLOCK
    out[#out + 1] = ZERO_BLOCK
    local s = concat(out)

    local rs = opts.record_size or 10240
    if not is_int(rs) or rs < BLOCK or rs % BLOCK ~= 0 then
        fail("record_size must be a positive multiple of 512")
    end
    s = s .. rep("\0", (rs - #s % rs) % rs)

    if opts.gzip then
        local level = type(opts.gzip) == "number" and opts.gzip or nil
        s = get_compression().gzip(s, { level = level })
    end
    return s
end

function tar.create(entries, opts)
    local s, err = protect(create_impl, entries, opts or {})
    if s == nil then return nil, err end
    return s
end

---------------------------------------------------------------------------
-- Reader
---------------------------------------------------------------------------

local function parse_impl(s, opts)
    if byte(s, 1) == 31 and byte(s, 2) == 139 then
        local data, err = get_compression().gunzip(s)
        if not data then fail(err) end
        s = data
    end

    local slen, pos = #s, 1
    local entries, global = {}, {}
    local local_pax, long_name, long_link = nil, nil, nil
    local ended = false

    while pos <= slen do
        if pos + BLOCK - 1 > slen then fail("unexpected end of archive (truncated header)") end
        local h = sub(s, pos, pos + BLOCK - 1)

        if h == ZERO_BLOCK then
            local nxt = sub(s, pos + BLOCK, pos + 2 * BLOCK - 1)
            if opts.strict and nxt ~= ZERO_BLOCK then
                fail("incomplete end-of-archive marker")
            end
            ended = true
            break
        end

        local stored = parse_numeric(h, 149, 8, "checksum")
        local u, sg = header_sums(h)
        if stored ~= u and stored ~= sg then
            fail(format("header checksum mismatch at offset %d", pos - 1))
        end

        local typeflag = sub(h, 157, 157)
        local size = parse_numeric(h, 125, 12, "size")
        if typeflag == "x" or typeflag == "g" or typeflag == "L" or typeflag == "K" then
            -- Meta headers: always followed by `size` bytes of data.
        else
            local p = local_pax and local_pax.size
            if p == nil then p = global.size end
            if p then size = pax_number(p, "size") end
            if HEADER_ONLY[typeflag] then size = 0 end
        end
        if size < 0 then fail("negative size in header") end

        local dstart = pos + BLOCK
        local nextpos = dstart + size + (BLOCK - size % BLOCK) % BLOCK
        if nextpos - 1 > slen then fail("unexpected end of archive (truncated data)") end
        local data = sub(s, dstart, dstart + size - 1)
        pos = nextpos

        if typeflag == "x" then
            local_pax = parse_pax(data, local_pax or {})
        elseif typeflag == "g" then
            parse_pax(data, global)
        elseif typeflag == "L" then
            long_name = cstr(data, 1, #data)
        elseif typeflag == "K" then
            long_link = cstr(data, 1, #data)
        else
            local magic = sub(h, 258, 263)
            local name = cstr(h, 1, 100)
            if magic == "ustar\0" then
                local prefix
                if sub(h, 509, 512) == "tar\0" then
                    prefix = cstr(h, 346, 131)       -- star: prefix + atime/ctime
                else
                    prefix = cstr(h, 346, 155)
                end
                if prefix ~= "" then name = prefix .. "/" .. name end
            end
            local is_ustar = magic == "ustar\0" or sub(h, 258, 265) == "ustar  \0"

            local e = {
                name = name,
                typeflag = typeflag,
                type = FLAG_TO_TYPE[typeflag] or "file",
                mode = parse_numeric(h, 101, 8, "mode") % 4096,
                uid = parse_numeric(h, 109, 8, "uid"),
                gid = parse_numeric(h, 117, 8, "gid"),
                size = size,
                mtime = parse_numeric(h, 137, 12, "mtime"),
                linkname = cstr(h, 158, 100),
                uname = is_ustar and cstr(h, 266, 32) or "",
                gname = is_ustar and cstr(h, 298, 32) or "",
            }
            if typeflag == "3" or typeflag == "4" then
                e.devmajor = parse_numeric(h, 330, 8, "devmajor")
                e.devminor = parse_numeric(h, 338, 8, "devminor")
            end

            if long_name then e.name = long_name end
            if long_link then e.linkname = long_link end

            -- Merge global then local pax attributes (false = deleted).
            local pax, any = {}, false
            for k, v in pairs(global) do pax[k] = v end
            if local_pax then for k, v in pairs(local_pax) do pax[k] = v end end
            for k, v in pairs(pax) do
                if v == false then pax[k] = nil else any = true end
            end
            if any then
                e.pax = pax
                if pax.path then e.name = pax.path end
                if pax.linkpath then e.linkname = pax.linkpath end
                if pax.uname then e.uname = pax.uname end
                if pax.gname then e.gname = pax.gname end
                for _, k in ipairs({ "uid", "gid", "mtime", "atime", "ctime" }) do
                    if pax[k] then e[k] = pax_number(pax[k], k) end
                end
            end

            -- Pre-POSIX archives mark directories with a trailing slash.
            if typeflag == "\0" and sub(e.name, -1) == "/" then e.type = "directory" end
            if e.type == "file" or e.type == "contiguous" then e.data = data end

            entries[#entries + 1] = e
            local_pax, long_name, long_link = nil, nil, nil
        end
    end

    if not ended and opts.strict then fail("missing end-of-archive marker") end
    if local_pax or long_name or long_link then
        fail("unexpected end of archive (extended header without entry)")
    end

    local g = {}
    for k, v in pairs(global) do if v then g[k] = v end end
    return entries, g
end

function tar.parse(s, opts)
    if type(s) ~= "string" then error("tar.parse: expected string", 2) end
    return protect(parse_impl, s, opts or {})
end

return tar
