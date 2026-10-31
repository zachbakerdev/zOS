-- Hashing, encryption, key agreement and signatures in pure Lua. See specs/libs/CRYPTO.md.

local crypto = {}

local band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
local lshift, rshift = bit32.lshift, bit32.rshift
local lrotate, rrotate = bit32.lrotate, bit32.rrotate
local floor = math.floor
local byte, char, rep = string.byte, string.char, string.rep
local concat = table.concat
local unpack = table.unpack or unpack

local TWO32 = 4294967296

-- Long work yields now and then, or CC: Tweaked kills the program. See "Performance" in the spec.
local YIELD_EVERY = 400
local work = 0
local function pause(cost)
    work = work + cost
    if work >= YIELD_EVERY then
        work = 0
        os.queueEvent("zos:crypto")
        os.pullEventRaw("zos:crypto")
    end
end

-- Utilities ------------------------------------------------------------------------------------

function crypto.toHex(s)
    return (s:gsub(".", function(c) return ("%02x"):format(byte(c)) end))
end

function crypto.fromHex(h)
    return (h:gsub("%x%x", function(pair) return char(tonumber(pair, 16)) end))
end

function crypto.isHex(s, len)
    if type(s) ~= "string" or #s % 2 ~= 0 or not s:match("^[0-9a-f]*$") then return false end
    return len == nil or #s == len
end

local toHex, fromHex, isHex = crypto.toHex, crypto.fromHex, crypto.isHex

-- A table of the bytes of s, numbered from 0.
local function bytes(s)
    local out = {}
    for i = 1, #s do out[i - 1] = byte(s, i) end
    return out
end

-- The string of bytes t[0] to t[n - 1].
local function fromBytes(t, n)
    local out = {}
    for i = 0, n - 1 do out[i + 1] = char(t[i]) end
    return concat(out)
end

-- SHA-256 --------------------------------------------------------------------------------------

-- The length of a message of len bytes, in bits, as the 8 bytes that end its padding.
local function bigEndianLength(len)
    local bits, out = len * 8, {}
    for i = 8, 1, -1 do
        out[i] = char(bits % 256)
        bits = floor(bits / 256)
    end
    return concat(out)
end

local K256 = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}

local function sha256Raw(msg)
    local h0, h1, h2, h3, h4, h5, h6, h7 = unpack({
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    })
    local len = #msg
    msg = msg .. "\128" .. rep("\0", (55 - len) % 64)
        .. bigEndianLength(len)

    local w = {}
    for block = 1, #msg, 64 do
        for i = 1, 16 do
            local a, b, c, d = byte(msg, block + i * 4 - 4, block + i * 4 - 1)
            w[i] = a * 16777216 + b * 65536 + c * 256 + d
        end
        for i = 17, 64 do
            local x, y = w[i - 15], w[i - 2]
            local s0 = bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
            local s1 = bxor(rrotate(y, 17), rrotate(y, 19), rshift(y, 10))
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % TWO32
        end

        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
        for i = 1, 64 do
            local s1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = h + s1 + ch + K256[i] + w[i]
            local s0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            h, g, f, e, d, c, b, a = g, f, e, (d + t1) % TWO32, c, b, a, (t1 + s0 + maj) % TWO32
        end
        h0, h1, h2, h3 = (h0 + a) % TWO32, (h1 + b) % TWO32, (h2 + c) % TWO32, (h3 + d) % TWO32
        h4, h5, h6, h7 = (h4 + e) % TWO32, (h5 + f) % TWO32, (h6 + g) % TWO32, (h7 + h) % TWO32
        pause(4)
    end

    local out = {}
    for i, v in ipairs({ h0, h1, h2, h3, h4, h5, h6, h7 }) do
        out[i] = char(floor(v / 16777216) % 256, floor(v / 65536) % 256, floor(v / 256) % 256, v % 256)
    end
    return concat(out)
end

function crypto.sha256(msg)
    return toHex(sha256Raw(msg))
end

-- SHA-512, with each 64-bit word held as a high and a low half -------------------------------------

local K512H = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2, 0xca273ece, 0xd186b8c7,
    0xeada7dd6, 0xf57d4f7f, 0x06f067aa, 0x0a637dc5, 0x113f9804, 0x1b710b35,
    0x28db77f5, 0x32caab7b, 0x3c9ebe0a, 0x431d67c4, 0x4cc5d4be, 0x597f299c,
    0x5fcb6fab, 0x6c44198c
}
local K512L = {
    0xd728ae22, 0x23ef65cd, 0xec4d3b2f, 0x8189dbbc, 0xf348b538, 0xb605d019,
    0xaf194f9b, 0xda6d8118, 0xa3030242, 0x45706fbe, 0x4ee4b28c, 0xd5ffb4e2,
    0xf27b896f, 0x3b1696b1, 0x25c71235, 0xcf692694, 0x9ef14ad2, 0x384f25e3,
    0x8b8cd5b5, 0x77ac9c65, 0x592b0275, 0x6ea6e483, 0xbd41fbd4, 0x831153b5,
    0xee66dfab, 0x2db43210, 0x98fb213f, 0xbeef0ee4, 0x3da88fc2, 0x930aa725,
    0xe003826f, 0x0a0e6e70, 0x46d22ffc, 0x5c26c926, 0x5ac42aed, 0x9d95b3df,
    0x8baf63de, 0x3c77b2a8, 0x47edaee6, 0x1482353b, 0x4cf10364, 0xbc423001,
    0xd0f89791, 0x0654be30, 0xd6ef5218, 0x5565a910, 0x5771202a, 0x32bbd1b8,
    0xb8d2d0c8, 0x5141ab53, 0xdf8eeb99, 0xe19b48a8, 0xc5c95a63, 0xe3418acb,
    0x7763e373, 0xd6b2b8a3, 0x5defb2fc, 0x43172f60, 0xa1f0ab72, 0x1a6439ec,
    0x23631e28, 0xde82bde9, 0xb2c67915, 0xe372532b, 0xea26619c, 0x21c0c207,
    0xcde0eb1e, 0xee6ed178, 0x72176fba, 0xa2c898a6, 0xbef90dae, 0x131c471b,
    0x23047d84, 0x40c72493, 0x15c9bebc, 0x9c100d4c, 0xcb3e42b6, 0xfc657e2a,
    0x3ad6faec, 0x4a475817
}

-- The high and low halves of a 64-bit word rotated right by n, where n isn't 0 or 32.
local function rotr64(hi, lo, n)
    if n < 32 then
        return bor(rshift(hi, n), lshift(lo, 32 - n)), bor(rshift(lo, n), lshift(hi, 32 - n))
    end
    n = n - 32
    return bor(rshift(lo, n), lshift(hi, 32 - n)), bor(rshift(hi, n), lshift(lo, 32 - n))
end

local function shr64(hi, lo, n)
    return rshift(hi, n), bor(rshift(lo, n), lshift(hi, 32 - n))
end

local function sha512Raw(msg)
    local H = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    }
    local L = {
    0xf3bcc908, 0x84caa73b, 0xfe94f82b, 0x5f1d36f1,
    0xade682d1, 0x2b3e6c1f, 0xfb41bd6b, 0x137e2179
    }
    local len = #msg
    msg = msg .. "\128" .. rep("\0", (111 - len) % 128) .. rep("\0", 8)
        .. bigEndianLength(len)

    local wh, wl = {}, {}
    for block = 1, #msg, 128 do
        for i = 1, 16 do
            local at = block + i * 8 - 8
            local a, b, c, d, e, f, g, h = byte(msg, at, at + 7)
            wh[i] = a * 16777216 + b * 65536 + c * 256 + d
            wl[i] = e * 16777216 + f * 65536 + g * 256 + h
        end
        for i = 17, 80 do
            local xh, xl = wh[i - 15], wl[i - 15]
            local r1h, r1l = rotr64(xh, xl, 1)
            local r2h, r2l = rotr64(xh, xl, 8)
            local r3h, r3l = shr64(xh, xl, 7)
            local s0h, s0l = bxor(r1h, r2h, r3h), bxor(r1l, r2l, r3l)
            local yh, yl = wh[i - 2], wl[i - 2]
            r1h, r1l = rotr64(yh, yl, 19)
            r2h, r2l = rotr64(yh, yl, 61)
            r3h, r3l = shr64(yh, yl, 6)
            local lo = wl[i - 16] + s0l + wl[i - 7] + bxor(r1l, r2l, r3l)
            wl[i] = lo % TWO32
            wh[i] = (wh[i - 16] + s0h + wh[i - 7] + bxor(r1h, r2h, r3h) + floor(lo / TWO32)) % TWO32
        end

        local ah, bh, ch, dh, eh, fh, gh, hh = unpack(H)
        local al, bl, cl, dl, el, fl, gl, hl = unpack(L)
        for i = 1, 80 do
            local r1h, r1l = rotr64(eh, el, 14)
            local r2h, r2l = rotr64(eh, el, 18)
            local r3h, r3l = rotr64(eh, el, 41)
            local s1h, s1l = bxor(r1h, r2h, r3h), bxor(r1l, r2l, r3l)
            local chh = bxor(band(eh, fh), band(bnot(eh), gh))
            local chl = bxor(band(el, fl), band(bnot(el), gl))
            local t1l = hl + s1l + chl + K512L[i] + wl[i]
            local t1h = hh + s1h + chh + K512H[i] + wh[i] + floor(t1l / TWO32)
            t1l = t1l % TWO32

            r1h, r1l = rotr64(ah, al, 28)
            r2h, r2l = rotr64(ah, al, 34)
            r3h, r3l = rotr64(ah, al, 39)
            local s0h, s0l = bxor(r1h, r2h, r3h), bxor(r1l, r2l, r3l)
            local mh = bxor(band(ah, bh), band(ah, ch), band(bh, ch))
            local ml = bxor(band(al, bl), band(al, cl), band(bl, cl))

            hh, hl, gh, gl, fh, fl = gh, gl, fh, fl, eh, el
            local lo = dl + t1l
            el = lo % TWO32
            eh = (dh + t1h + floor(lo / TWO32)) % TWO32
            dh, dl, ch, cl, bh, bl = ch, cl, bh, bl, ah, al
            lo = t1l + s0l + ml
            al = lo % TWO32
            ah = (t1h + s0h + mh + floor(lo / TWO32)) % TWO32
        end

        for i, v in ipairs({ al, bl, cl, dl, el, fl, gl, hl }) do
            local lo = L[i] + v
            L[i] = lo % TWO32
            H[i] = (H[i] + ({ ah, bh, ch, dh, eh, fh, gh, hh })[i] + floor(lo / TWO32)) % TWO32
        end
        pause(8)
    end

    local out = {}
    for i = 1, 8 do
        local a, b = H[i], L[i]
        out[i] = char(floor(a / 16777216) % 256, floor(a / 65536) % 256, floor(a / 256) % 256, a % 256,
            floor(b / 16777216) % 256, floor(b / 65536) % 256, floor(b / 256) % 256, b % 256)
    end
    return concat(out)
end

function crypto.sha512(msg)
    return toHex(sha512Raw(msg))
end

-- HMAC-SHA256 ----------------------------------------------------------------------------------

function crypto.hmac(key, msg)
    if #key > 64 then key = sha256Raw(key) end
    key = key .. rep("\0", 64 - #key)
    local inner = key:gsub(".", function(c) return char(bxor(byte(c), 0x36)) end)
    local outer = key:gsub(".", function(c) return char(bxor(byte(c), 0x5c)) end)
    return sha256Raw(outer .. sha256Raw(inner .. msg))
end

local hmac = crypto.hmac

function crypto.fingerprint(publicKey)
    local h = crypto.sha256(publicKey)
    return h:sub(1, 4) .. "-" .. h:sub(5, 8) .. "-" .. h:sub(9, 12) .. "-" .. h:sub(13, 16)
end

-- Random numbers -------------------------------------------------------------------------------

-- CC: Tweaked has no secure source of randomness. See "Security limitations" in the spec.
local pool, counter = "", 0

function crypto.addEntropy(data)
    pool = sha256Raw(pool .. "|" .. tostring(data) .. "|" .. tostring(os.epoch("utc")) .. "|" .. tostring(os.clock()))
end

function crypto.randomBytes(n)
    local out = {}
    for i = 1, math.ceil(n / 32) do
        counter = counter + 1
        crypto.addEntropy(counter)
        out[i] = sha256Raw(pool .. "|out|" .. counter)
    end
    return concat(out):sub(1, n)
end

crypto.addEntropy(tostring(os.getComputerID()) .. "|" .. tostring((os.getComputerLabel())) .. "|" .. tostring({}))
for _ = 1, 16 do crypto.addEntropy(math.random()) end

-- ChaCha20 -------------------------------------------------------------------------------------

local function le32(s, at)
    local a, b, c, d = byte(s, at, at + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function quarter(x, a, b, c, d)
    x[a] = (x[a] + x[b]) % TWO32
    x[d] = lrotate(bxor(x[d], x[a]), 16)
    x[c] = (x[c] + x[d]) % TWO32
    x[b] = lrotate(bxor(x[b], x[c]), 12)
    x[a] = (x[a] + x[b]) % TWO32
    x[d] = lrotate(bxor(x[d], x[a]), 8)
    x[c] = (x[c] + x[d]) % TWO32
    x[b] = lrotate(bxor(x[b], x[c]), 7)
end

function crypto.chacha20(key, nonce, data, counter0)
    assert(#key == 32 and #nonce == 12, "chacha20 needs a 32 byte key and a 12 byte nonce")
    local state = { 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574 }
    for i = 0, 7 do state[5 + i] = le32(key, 1 + i * 4) end
    state[13] = counter0 or 1
    for i = 0, 2 do state[14 + i] = le32(nonce, 1 + i * 4) end

    local out, x, stream = {}, {}, {}
    for offset = 0, #data - 1, 64 do
        for i = 1, 16 do x[i] = state[i] end
        for _ = 1, 10 do
            quarter(x, 1, 5, 9, 13)
            quarter(x, 2, 6, 10, 14)
            quarter(x, 3, 7, 11, 15)
            quarter(x, 4, 8, 12, 16)
            quarter(x, 1, 6, 11, 16)
            quarter(x, 2, 7, 12, 13)
            quarter(x, 3, 8, 9, 14)
            quarter(x, 4, 5, 10, 15)
        end
        for i = 1, 16 do
            local v = (x[i] + state[i]) % TWO32
            for j = 1, 4 do
                stream[(i - 1) * 4 + j] = v % 256
                v = floor(v / 256)
            end
        end
        local chunk = { byte(data, offset + 1, offset + 64) }
        for i = 1, #chunk do chunk[i] = bxor(chunk[i], stream[i]) end
        out[#out + 1] = char(unpack(chunk))
        state[13] = (state[13] + 1) % TWO32
        pause(2)
    end
    return concat(out)
end

-- Authenticated encryption ---------------------------------------------------------------------

function crypto.seal(key, plaintext)
    local nonce = crypto.randomBytes(12)
    local ct = crypto.chacha20(hmac(key, "zos-seal-enc"), nonce, plaintext)
    return {
        nonce = toHex(nonce),
        ct = toHex(ct),
        tag = toHex(hmac(hmac(key, "zos-seal-mac"), nonce .. ct)),
    }
end

function crypto.open(key, box)
    if type(box) ~= "table" or not isHex(box.nonce, 24) or not isHex(box.ct) or not isHex(box.tag, 64) then
        return nil
    end
    local nonce, ct = fromHex(box.nonce), fromHex(box.ct)
    if toHex(hmac(hmac(key, "zos-seal-mac"), nonce .. ct)) ~= box.tag then return nil end
    return crypto.chacha20(hmac(key, "zos-seal-enc"), nonce, ct)
end

-- Curve25519 field arithmetic: numbers mod 2^255 - 19 as 16 limbs of 16 bits -----------------------

local function gf(init)
    local o = {}
    for i = 1, 16 do o[i] = init and init[i] or 0 end
    return o
end

local function set(o, a)
    for i = 1, 16 do o[i] = a[i] end
end

local function carry(o)
    local c
    for i = 1, 16 do
        o[i] = o[i] + 65536
        c = floor(o[i] / 65536)
        if i < 16 then
            o[i + 1] = o[i + 1] + c - 1
        else
            o[1] = o[1] + 38 * (c - 1)
        end
        o[i] = o[i] - c * 65536
    end
end

local function swap(p, q, b)
    if b == 1 then
        for i = 1, 16 do p[i], q[i] = q[i], p[i] end
    end
end

local function add(o, a, b)
    for i = 1, 16 do o[i] = a[i] + b[i] end
end

local function sub(o, a, b)
    for i = 1, 16 do o[i] = a[i] - b[i] end
end

local function mul(o, a, b)
    local t = {}
    for i = 1, 31 do t[i] = 0 end
    for i = 1, 16 do
        local ai = a[i]
        for j = 1, 16 do
            local k = i + j - 1
            t[k] = t[k] + ai * b[j]
        end
    end
    for i = 1, 15 do t[i] = t[i] + 38 * t[i + 16] end
    for i = 1, 16 do o[i] = t[i] end
    carry(o)
    carry(o)
    pause(1)
end

local function square(o, a)
    mul(o, a, a)
end

local function invert(o, a)
    local c = gf(a)
    for i = 253, 0, -1 do
        square(c, c)
        if i ~= 2 and i ~= 4 then mul(c, c, a) end
    end
    set(o, c)
end

local function pow2523(o, a)
    local c = gf(a)
    for i = 250, 0, -1 do
        square(c, c)
        if i ~= 1 then mul(c, c, a) end
    end
    set(o, c)
end

-- The canonical 32 bytes of n, as a table numbered from 0.
local function pack25519(n)
    local t, m = gf(n), gf()
    carry(t)
    carry(t)
    carry(t)
    for _ = 1, 2 do
        m[1] = t[1] - 0xffed
        for i = 2, 15 do
            m[i] = t[i] - 0xffff - floor(m[i - 1] / 65536) % 2
            m[i - 1] = m[i - 1] % 65536
        end
        m[16] = t[16] - 0x7fff - floor(m[15] / 65536) % 2
        local b = floor(m[16] / 65536) % 2
        m[15] = m[15] % 65536
        swap(t, m, 1 - b)
    end
    local o = {}
    for i = 1, 16 do
        o[2 * i - 2] = t[i] % 256
        o[2 * i - 1] = floor(t[i] / 256)
    end
    return o
end

local function unpack25519(n)
    local o = gf()
    for i = 1, 16 do o[i] = n[2 * i - 2] + 256 * n[2 * i - 1] end
    o[16] = o[16] % 32768
    return o
end

local function neq25519(a, b)
    local x, y = pack25519(a), pack25519(b)
    for i = 0, 31 do
        if x[i] ~= y[i] then return true end
    end
    return false
end

local function parity(a)
    return pack25519(a)[0] % 2
end

-- X25519 ---------------------------------------------------------------------------------------

local C121665 = { 0xdb41, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
local BASE = "\9" .. rep("\0", 31)

function crypto.x25519(secret, public)
    local z = bytes(secret)
    z[31] = z[31] % 64 + 64
    z[0] = z[0] - z[0] % 8
    local x = unpack25519(bytes(public))
    local a, b, c, d = gf(), gf(x), gf(), gf()
    local e, f = gf(), gf()
    a[1], d[1] = 1, 1
    for i = 254, 0, -1 do
        local r = floor(z[floor(i / 8)] / 2 ^ (i % 8)) % 2
        swap(a, b, r)
        swap(c, d, r)
        add(e, a, c)
        sub(a, a, c)
        add(c, b, d)
        sub(b, b, d)
        square(d, e)
        square(f, a)
        mul(a, c, a)
        mul(c, b, e)
        add(e, a, c)
        sub(a, a, c)
        square(b, a)
        sub(c, d, f)
        mul(a, c, C121665)
        add(a, a, d)
        mul(c, c, a)
        mul(a, d, f)
        mul(d, b, x)
        square(b, e)
        swap(a, b, r)
        swap(c, d, r)
    end
    invert(c, c)
    mul(a, a, c)
    return fromBytes(pack25519(a), 32)
end

function crypto.publicKey(secret)
    return crypto.x25519(secret, BASE)
end

function crypto.keypair()
    local secret = crypto.randomBytes(32)
    return secret, crypto.publicKey(secret)
end

local sharedCache = {}

function crypto.shared(secret, peerPublic)
    local id = secret .. peerPublic
    if sharedCache[id] then return sharedCache[id] end
    local result = crypto.x25519(secret, peerPublic)
    if result == rep("\0", 32) then error("low-order public key", 0) end
    sharedCache[id] = result
    return result
end

function crypto.clearCache()
    sharedCache = {}
end

-- Public key and password encryption ----------------------------------------------------------

local function sealToKey(sharedSecret, eph, public)
    return hmac(sharedSecret, "zos-seal-to|" .. eph .. public)
end

function crypto.sealTo(public, plaintext)
    local secret, eph = crypto.keypair()
    local ok, sharedSecret = pcall(crypto.x25519, secret, public)
    if not ok or sharedSecret == rep("\0", 32) then return nil end
    local box = crypto.seal(sealToKey(sharedSecret, eph, public), plaintext)
    box.eph = toHex(eph)
    return box
end

function crypto.openSealed(secret, public, box)
    if type(box) ~= "table" or not isHex(box.eph, 64) then return nil end
    local eph = fromHex(box.eph)
    local sharedSecret = crypto.x25519(secret, eph)
    if sharedSecret == rep("\0", 32) then return nil end
    return crypto.open(sealToKey(sharedSecret, eph, public), box)
end

local PASSWORD_ROUNDS = 200

-- A 32-byte key from a password and a raw salt, slowly enough to make guessing harder.
function crypto.passwordKey(password, salt)
    local key = sha256Raw(salt .. password)
    for _ = 1, PASSWORD_ROUNDS do key = sha256Raw(key .. salt .. password) end
    return key
end

function crypto.lock(password, plaintext)
    local salt = crypto.randomBytes(16)
    crypto.addEntropy(password)
    return { salt = toHex(salt), box = crypto.seal(crypto.passwordKey(password, salt), plaintext) }
end

function crypto.unlock(password, locked)
    if type(locked) ~= "table" or not isHex(locked.salt, 32) then return nil end
    return crypto.open(crypto.passwordKey(password, fromHex(locked.salt)), locked.box)
end

-- Ed25519 --------------------------------------------------------------------------------------

local D = { 0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070,
    0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203 }
local D2 = { 0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0,
    0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406 }
local BX = { 0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c,
    0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169 }
local BY = { 0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
    0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666 }
local SQRT_M1 = { 0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43,
    0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83 }
local ONE = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
local ZERO = gf()

-- The group order, numbered from 0.
local L = bytes(fromHex("edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010"))

local function pointAdd(p, q)
    local a, b, c, d, e, f, g, h, t = gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf()
    sub(a, p[2], p[1])
    sub(t, q[2], q[1])
    mul(a, a, t)
    add(b, p[1], p[2])
    add(t, q[1], q[2])
    mul(b, b, t)
    mul(c, p[4], q[4])
    mul(c, c, D2)
    mul(d, p[3], q[3])
    add(d, d, d)
    sub(e, b, a)
    sub(f, d, c)
    add(g, d, c)
    add(h, b, a)
    mul(p[1], e, f)
    mul(p[2], h, g)
    mul(p[3], g, f)
    mul(p[4], e, h)
end

local function pointSwap(p, q, b)
    for i = 1, 4 do swap(p[i], q[i], b) end
end

local function pointPack(p)
    local zi, tx, ty = gf(), gf(), gf()
    invert(zi, p[3])
    mul(tx, p[1], zi)
    mul(ty, p[2], zi)
    local r = pack25519(ty)
    r[31] = r[31] + parity(tx) * 128
    return r
end

local function scalarMult(q, s)
    local p = { gf(), gf(ONE), gf(ONE), gf() }
    for i = 255, 0, -1 do
        local b = floor(s[floor(i / 8)] / 2 ^ (i % 8)) % 2
        pointSwap(p, q, b)
        pointAdd(q, p)
        pointAdd(p, p)
        pointSwap(p, q, b)
    end
    return p
end

local function scalarBase(s)
    local q = { gf(BX), gf(BY), gf(ONE), gf() }
    mul(q[4], BX, BY)
    return scalarMult(q, s)
end

-- The negative of the point packed in p, or nil if it isn't on the curve.
local function pointUnpackNeg(p)
    local r = { gf(), gf(), gf(ONE), gf() }
    local t, chk, num, den, den2, den4, den6 = gf(), gf(), gf(), gf(), gf(), gf(), gf()
    r[2] = unpack25519(p)
    square(num, r[2])
    mul(den, num, D)
    sub(num, num, r[3])
    add(den, r[3], den)
    square(den2, den)
    square(den4, den2)
    mul(den6, den4, den2)
    mul(t, den6, num)
    mul(t, t, den)
    pow2523(t, t)
    mul(t, t, num)
    mul(t, t, den)
    mul(t, t, den)
    mul(r[1], t, den)
    square(chk, r[1])
    mul(chk, chk, den)
    if neq25519(chk, num) then mul(r[1], r[1], SQRT_M1) end
    square(chk, r[1])
    mul(chk, chk, den)
    if neq25519(chk, num) then return nil end
    if parity(r[1]) == floor(p[31] / 128) then sub(r[1], ZERO, r[1]) end
    mul(r[4], r[1], r[2])
    return r
end

-- x (64 numbers from 0) mod L, as 32 bytes from 0.
local function modL(x)
    for i = 63, 32, -1 do
        local c = 0
        for j = i - 32, i - 13 do
            x[j] = x[j] + c - 16 * x[i] * L[j - (i - 32)]
            c = floor((x[j] + 128) / 256)
            x[j] = x[j] - c * 256
        end
        x[i - 12] = x[i - 12] + c
        x[i] = 0
    end
    local c = 0
    for j = 0, 31 do
        x[j] = x[j] + c - floor(x[31] / 16) * L[j]
        c = floor(x[j] / 256)
        x[j] = x[j] - c * 256
    end
    for j = 0, 31 do x[j] = x[j] - c * L[j] end
    local r = {}
    for i = 0, 31 do
        x[i + 1] = x[i + 1] + floor(x[i] / 256)
        r[i] = x[i] % 256
    end
    return r
end

local function reduce(hash)
    return modL(bytes(hash))
end

local function expandSeed(seed)
    local d = bytes(sha512Raw(seed))
    d[0] = d[0] - d[0] % 8
    d[31] = d[31] % 64 + 64
    return d
end

function crypto.signingPublicKey(seed)
    return fromBytes(pointPack(scalarBase(expandSeed(seed))), 32)
end

function crypto.signingKeypair()
    local seed = crypto.randomBytes(32)
    return seed, crypto.signingPublicKey(seed)
end

function crypto.sign(seed, msg, public)
    public = public or crypto.signingPublicKey(seed)
    local d = expandSeed(seed)
    local prefix = {}
    for i = 32, 63 do prefix[#prefix + 1] = char(d[i]) end
    local r = reduce(sha512Raw(concat(prefix) .. msg))
    local big = fromBytes(pointPack(scalarBase(r)), 32)
    local h = reduce(sha512Raw(big .. public .. msg))

    local x = {}
    for i = 0, 63 do x[i] = i < 32 and r[i] or 0 end
    for i = 0, 31 do
        for j = 0, 31 do x[i + j] = x[i + j] + h[i] * d[j] end
    end
    return big .. fromBytes(modL(x), 32)
end

-- S has to be below L, or a signature could be changed without its key.
local function scalarInRange(s)
    for i = 31, 0, -1 do
        if s[i] < L[i] then return true end
        if s[i] > L[i] then return false end
    end
    return false
end

function crypto.verify(public, msg, signature)
    if type(public) ~= "string" or type(signature) ~= "string" or type(msg) ~= "string" then return false end
    if #public ~= 32 or #signature ~= 64 then return false end
    local s = bytes(signature:sub(33))
    if not scalarInRange(s) then return false end
    local q = pointUnpackNeg(bytes(public))
    if not q then return false end
    local big = signature:sub(1, 32)
    local h = reduce(sha512Raw(big .. public .. msg))
    local p = scalarMult(q, h)
    pointAdd(p, scalarBase(s))
    return fromBytes(pointPack(p), 32) == big
end

return crypto
