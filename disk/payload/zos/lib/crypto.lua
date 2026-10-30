local crypto = {}

-- General Public Utilities

function crypto.toHex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

function crypto.fromHex(h)
  return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end

function crypto.isHex(s, len)
  return type(s) == "string" and #s % 2 == 0 and (len == nil or #s == len) and not s:find("[^0-9a-f]")
end

-- General Private Utilities

local function yield()
  os.queueEvent("zos:crypto")
  os.pullEventRaw("zos:crypto")
end

local function xorPad(key, byte)
  return (key:gsub(".", function(c) return string.char(bit32.bxor(c:byte(), byte)) end))
end

-- SHA256

local MOD = 2 ^ 32

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function sha256Pad(msg)
  local len = #msg
  local zeroes = (55 - len) % 64
  local bits = len * 8
  local tail = {}
  for i = 8, 1, -1 do
    tail[i] = string.char(bits % 256)
    bits = math.floor(bits / 256)
  end
  return msg .. "\128" .. string.rep("\0", zeroes) .. table.concat(tail)
end

local function sha256Block(msg, offset, H)
  local w = {}

  for i = 1, 16 do
    local a, b, c, d = msg:byte(offset + (i - 1) * 4, offset + (i - 1) * 4 + 3)
    w[i] = bit32.lshift(a, 24) + bit32.lshift(b, 16) + bit32.lshift(c, 8) + d
  end

  for i = 17, 64 do
    local v15, v2 = w[i - 15], w[i - 2]
    local s0 = bit32.bxor(bit32.rrotate(v15, 7), bit32.rrotate(v15, 18), bit32.rshift(v15, 3))
    local s1 = bit32.bxor(bit32.rrotate(v2, 17), bit32.rrotate(v2, 19), bit32.rshift(v2, 10))
    w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % MOD
  end

  local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]

  for i = 1, 64 do
    local s1 = bit32.bxor(bit32.rrotate(e, 6), bit32.rrotate(e, 11), bit32.rrotate(e, 25))
    local ch = bit32.bxor(bit32.band(e, f), bit32.band(bit32.bnot(e), g))
    local t1 = (h + s1 + ch + K[i] + w[i]) % MOD
    local s0 = bit32.bxor(bit32.rrotate(a, 2), bit32.rrotate(a, 13), bit32.rrotate(a, 22))
    local maj = bit32.bxor(bit32.band(a, b), bit32.band(a, c), bit32.band(b, c))
    local t2 = (s0 + maj) % MOD
    h, g, f, e, d, c, b, a = g, f, e, (d + t1) % MOD, c, b, a, (t1 + t2) % MOD
  end

  H[1] = (H[1] + a) % MOD
  H[2] = (H[2] + b) % MOD
  H[3] = (H[3] + c) % MOD
  H[4] = (H[4] + d) % MOD
  H[5] = (H[5] + e) % MOD
  H[6] = (H[6] + f) % MOD
  H[7] = (H[7] + g) % MOD
  H[8] = (H[8] + h) % MOD
end

local function sha256(msg)
  msg = sha256Pad(tostring(msg))

  local H = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  }

  for offset = 1, #msg, 64 do
    sha256Block(msg, offset, H)
  end

  local out = {}

  for i = 1, 8 do
    out[i] = string.format("%08x", H[i])
  end

  return table.concat(out)
end

crypto.sha256 = sha256

-- SHA512. 64-bit words are kept as two 32-bit halves, high then low.

local K512 = {
  0x428a2f98, 0xd728ae22, 0x71374491, 0x23ef65cd, 0xb5c0fbcf, 0xec4d3b2f, 0xe9b5dba5, 0x8189dbbc,
  0x3956c25b, 0xf348b538, 0x59f111f1, 0xb605d019, 0x923f82a4, 0xaf194f9b, 0xab1c5ed5, 0xda6d8118,
  0xd807aa98, 0xa3030242, 0x12835b01, 0x45706fbe, 0x243185be, 0x4ee4b28c, 0x550c7dc3, 0xd5ffb4e2,
  0x72be5d74, 0xf27b896f, 0x80deb1fe, 0x3b1696b1, 0x9bdc06a7, 0x25c71235, 0xc19bf174, 0xcf692694,
  0xe49b69c1, 0x9ef14ad2, 0xefbe4786, 0x384f25e3, 0x0fc19dc6, 0x8b8cd5b5, 0x240ca1cc, 0x77ac9c65,
  0x2de92c6f, 0x592b0275, 0x4a7484aa, 0x6ea6e483, 0x5cb0a9dc, 0xbd41fbd4, 0x76f988da, 0x831153b5,
  0x983e5152, 0xee66dfab, 0xa831c66d, 0x2db43210, 0xb00327c8, 0x98fb213f, 0xbf597fc7, 0xbeef0ee4,
  0xc6e00bf3, 0x3da88fc2, 0xd5a79147, 0x930aa725, 0x06ca6351, 0xe003826f, 0x14292967, 0x0a0e6e70,
  0x27b70a85, 0x46d22ffc, 0x2e1b2138, 0x5c26c926, 0x4d2c6dfc, 0x5ac42aed, 0x53380d13, 0x9d95b3df,
  0x650a7354, 0x8baf63de, 0x766a0abb, 0x3c77b2a8, 0x81c2c92e, 0x47edaee6, 0x92722c85, 0x1482353b,
  0xa2bfe8a1, 0x4cf10364, 0xa81a664b, 0xbc423001, 0xc24b8b70, 0xd0f89791, 0xc76c51a3, 0x0654be30,
  0xd192e819, 0xd6ef5218, 0xd6990624, 0x5565a910, 0xf40e3585, 0x5771202a, 0x106aa070, 0x32bbd1b8,
  0x19a4c116, 0xb8d2d0c8, 0x1e376c08, 0x5141ab53, 0x2748774c, 0xdf8eeb99, 0x34b0bcb5, 0xe19b48a8,
  0x391c0cb3, 0xc5c95a63, 0x4ed8aa4a, 0xe3418acb, 0x5b9cca4f, 0x7763e373, 0x682e6ff3, 0xd6b2b8a3,
  0x748f82ee, 0x5defb2fc, 0x78a5636f, 0x43172f60, 0x84c87814, 0xa1f0ab72, 0x8cc70208, 0x1a6439ec,
  0x90befffa, 0x23631e28, 0xa4506ceb, 0xde82bde9, 0xbef9a3f7, 0xb2c67915, 0xc67178f2, 0xe372532b,
  0xca273ece, 0xea26619c, 0xd186b8c7, 0x21c0c207, 0xeada7dd6, 0xcde0eb1e, 0xf57d4f7f, 0xee6ed178,
  0x06f067aa, 0x72176fba, 0x0a637dc5, 0xa2c898a6, 0x113f9804, 0xbef90dae, 0x1b710b35, 0x131c471b,
  0x28db77f5, 0x23047d84, 0x32caab7b, 0x40c72493, 0x3c9ebe0a, 0x15c9bebc, 0x431d67c4, 0x9c100d4c,
  0x4cc5d4be, 0xcb3e42b6, 0x597f299c, 0xfc657e2a, 0x5fcb6fab, 0x3ad6faec, 0x6c44198c, 0x4a475817,
}

local function rotr64(h, l, n)
  if n > 32 then
    h, l = l, h
    n = n - 32
  end
  return bit32.bor(bit32.rshift(h, n), bit32.lshift(l, 32 - n)), bit32.bor(bit32.rshift(l, n), bit32.lshift(h, 32 - n))
end

local function shr64(h, l, n)
  return bit32.rshift(h, n), bit32.bor(bit32.rshift(l, n), bit32.lshift(h, 32 - n))
end

local function sha512Pad(msg)
  local len = #msg
  local zeroes = (111 - len) % 128
  local bits = len * 8
  local tail = {}
  for i = 16, 1, -1 do
    tail[i] = string.char(bits % 256)
    bits = math.floor(bits / 256)
  end
  return msg .. "\128" .. string.rep("\0", zeroes) .. table.concat(tail)
end

local function sha512Block(msg, offset, H)
  local wh, wl = {}, {}

  for i = 1, 16 do
    local p = offset + (i - 1) * 8
    local a, b, c, d, e, f, g, h = msg:byte(p, p + 7)
    wh[i] = a * 0x1000000 + b * 0x10000 + c * 0x100 + d
    wl[i] = e * 0x1000000 + f * 0x10000 + g * 0x100 + h
  end

  for i = 17, 80 do
    local h15, l15, h2, l2 = wh[i - 15], wl[i - 15], wh[i - 2], wl[i - 2]
    local a1, a2 = rotr64(h15, l15, 1)
    local b1, b2 = rotr64(h15, l15, 8)
    local c1, c2 = shr64(h15, l15, 7)
    local d1, d2 = rotr64(h2, l2, 19)
    local e1, e2 = rotr64(h2, l2, 61)
    local f1, f2 = shr64(h2, l2, 6)
    local lo = wl[i - 16] + bit32.bxor(a2, b2, c2) + wl[i - 7] + bit32.bxor(d2, e2, f2)
    local hi = wh[i - 16] + bit32.bxor(a1, b1, c1) + wh[i - 7] + bit32.bxor(d1, e1, f1) + math.floor(lo / MOD)
    wh[i], wl[i] = hi % MOD, lo % MOD
  end

  local ah, al, bh, bl, ch, cl, dh, dl = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
  local eh, el, fh, fl, gh, gl, hh, hl = H[9], H[10], H[11], H[12], H[13], H[14], H[15], H[16]

  for i = 1, 80 do
    local a1, a2 = rotr64(eh, el, 14)
    local b1, b2 = rotr64(eh, el, 18)
    local c1, c2 = rotr64(eh, el, 41)
    local chh = bit32.bxor(bit32.band(eh, fh), bit32.band(bit32.bnot(eh), gh))
    local chl = bit32.bxor(bit32.band(el, fl), bit32.band(bit32.bnot(el), gl))
    local lo1 = hl + bit32.bxor(a2, b2, c2) + chl + K512[2 * i] + wl[i]
    local hi1 = (hh + bit32.bxor(a1, b1, c1) + chh + K512[2 * i - 1] + wh[i] + math.floor(lo1 / MOD)) % MOD
    lo1 = lo1 % MOD

    local d1, d2 = rotr64(ah, al, 28)
    local e1, e2 = rotr64(ah, al, 34)
    local f1, f2 = rotr64(ah, al, 39)
    local majh = bit32.bxor(bit32.band(ah, bh), bit32.band(ah, ch), bit32.band(bh, ch))
    local majl = bit32.bxor(bit32.band(al, bl), bit32.band(al, cl), bit32.band(bl, cl))
    local lo2 = bit32.bxor(d2, e2, f2) + majl
    local hi2 = bit32.bxor(d1, e1, f1) + majh

    hh, hl, gh, gl, fh, fl = gh, gl, fh, fl, eh, el
    local lo = dl + lo1
    eh, el = (dh + hi1 + math.floor(lo / MOD)) % MOD, lo % MOD
    dh, dl, ch, cl, bh, bl = ch, cl, bh, bl, ah, al
    lo = lo1 + lo2
    ah, al = (hi1 + hi2 + math.floor(lo / MOD)) % MOD, lo % MOD
  end

  local v = {ah, al, bh, bl, ch, cl, dh, dl, eh, el, fh, fl, gh, gl, hh, hl}
  for i = 15, 1, -2 do
    local lo = H[i + 1] + v[i + 1]
    H[i] = (H[i] + v[i] + math.floor(lo / MOD)) % MOD
    H[i + 1] = lo % MOD
  end
end

function crypto.sha512(msg)
  msg = sha512Pad(tostring(msg))

  local H = {
    0x6a09e667, 0xf3bcc908, 0xbb67ae85, 0x84caa73b, 0x3c6ef372, 0xfe94f82b, 0xa54ff53a, 0x5f1d36f1,
    0x510e527f, 0xade682d1, 0x9b05688c, 0x2b3e6c1f, 0x1f83d9ab, 0xfb41bd6b, 0x5be0cd19, 0x137e2179,
  }

  for offset = 1, #msg, 128 do
    sha512Block(msg, offset, H)
  end

  local out = {}

  for i = 1, 16 do
    out[i] = string.format("%08x", H[i])
  end

  return table.concat(out)
end

-- HMAC

function crypto.hmac(key, msg)
  if #key > 64 then
    key = crypto.fromHex(sha256(key))
  end

  key = key .. string.rep("\0", 64 - #key)

  return crypto.fromHex(sha256(xorPad(key, 0x5c) .. crypto.fromHex(sha256(xorPad(key, 0x36) .. msg))))
end

-- x25519 and Encryption

local function u32le(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return a + b * 0x100 + c * 0x10000 + d * 0x1000000
end

local function chachaBlock(key, nonce, counter)
  local s = {0x61707865, 0x3320646e, 0x79622d32, 0x6b206574}
  for i = 0, 7 do
    s[5 + i] = u32le(key, 1 + i * 4)
  end
  s[13] = counter
  for i = 0, 2 do
    s[14 + i] = u32le(nonce, 1 + i * 4)
  end

  local x = {}
  for i = 1, 16 do
    x[i] = s[i]
  end

  local function qr(a, b, c, d)
    x[a] = (x[a] + x[b]) % MOD
    x[d] = bit32.lrotate(bit32.bxor(x[d], x[a]), 16)
    x[c] = (x[c] + x[d]) % MOD
    x[b] = bit32.lrotate(bit32.bxor(x[b], x[c]), 12)
    x[a] = (x[a] + x[b]) % MOD
    x[d] = bit32.lrotate(bit32.bxor(x[d], x[a]), 8)
    x[c] = (x[c] + x[d]) % MOD
    x[b] = bit32.lrotate(bit32.bxor(x[b], x[c]), 7)
  end

  for _ = 1, 10 do
    qr(1, 5, 9, 13)
    qr(2, 6, 10, 14)
    qr(3, 7, 11, 15)
    qr(4, 8, 12, 16)
    qr(1, 6, 11, 16)
    qr(2, 7, 12, 13)
    qr(3, 8, 9, 14)
    qr(4, 5, 10, 15)
  end

  local out = {}

  for i = 1, 16 do
    local v = (x[i] + s[i]) % MOD
    out[i] = string.char(v % 256, math.floor(v / 0x100) % 256, math.floor(v / 0x10000) % 256, math.floor(v / 0x1000000))
  end

  return table.concat(out)
end

function crypto.chacha20(key, nonce, data, counter)
  counter = counter or 1
  local out = {}
  for i = 1, #data, 64 do
    local stream = chachaBlock(key, nonce, counter)
    counter = counter + 1
    local chunk = data:sub(i, i + 63)
    local bytes = {}
    for j = 1, #chunk do
      bytes[j] = bit32.bxor(chunk:byte(j), stream:byte(j))
    end
    out[#out + 1] = string.char(table.unpack(bytes))
    if #out % 32 == 0 then
      yield()
    end
  end
  return table.concat(out)
end

local function gf(init)
  local o = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}

  if init then
    for i = 1, #init do
      o[i] = init[i]
    end
  end

  return o
end

local function set(o, a)
  for i = 1, 16 do
    o[i] = a[i]
  end
end

local function car(o)
  for i = 1, 16 do
    local c = math.floor(o[i] / 65536)
    o[i] = o[i] - c * 65536
    if i < 16 then
      o[i + 1] = o[i + 1] + c
    else
      o[1] = o[1] + 38 * c
    end
  end
end

local function sel(p, q, b)
  for i = 1, 16 do
    local t = b * (p[i] - q[i])
    p[i] = p[i] - t
    q[i] = q[i] + t
  end
end

local function add(o, a, b)
  for i = 1, 16 do
    o[i] = a[i] + b[i]
  end
end

local function sub(o, a, b)
  for i = 1, 16 do
    o[i] = a[i] - b[i]
  end
end

local function mul(o, a, b)
  local t = {}

  for i = 1, 31 do
    t[i] = 0
  end

  for i = 1, 16 do
    local ai = a[i]
    for j = 1, 16 do
      t[i + j - 1] = t[i + j - 1] + ai * b[j]
    end
  end

  for i = 1, 15 do
    t[i] = t[i] + 38 * t[i + 16]
  end

  for i = 1, 16 do
    o[i] = t[i]
  end

  car(o)
  car(o)
end

local function sqr(o, a)
  mul(o, a, a)
end

local function inv(o, a)
  local c = gf(a)
  for i = 253, 0, -1 do
    sqr(c, c)
    if i ~= 2 and i ~= 4 then
      mul(c, c, a)
    end
    if i % 64 == 0 then
      yield()
    end
  end
  set(o, c)
end

local function pack(n)
  local t, m = gf(n), gf()
  car(t)
  car(t)
  car(t)
  for _ = 1, 2 do
    m[1] = t[1] - 0xffed
    for i = 2, 15 do
      local borrow = -math.floor(m[i - 1] / 65536)
      m[i] = t[i] - 0xffff - borrow
      m[i - 1] = m[i - 1] % 65536
    end
    local borrow = -math.floor(m[15] / 65536)
    m[16] = t[16] - 0x7fff - borrow
    m[15] = m[15] % 65536
    local b = -math.floor(m[16] / 65536)
    sel(t, m, 1 - b)
  end

  local out = {}

  for i = 1, 16 do
    out[2 * i - 1] = t[i] % 256
    out[2 * i] = math.floor(t[i] / 256)
  end

  return string.char(table.unpack(out))
end

local function unpackgf(s)
  local o = gf()
  for i = 1, 16 do
    o[i] = string.byte(s, 2 * i - 1) + 256 * string.byte(s, 2 * i)
  end
  o[16] = o[16] % 32768
  return o
end

local _121665 = gf({0xdb41, 1})

local function scalarmult(k, u)
  assert(type(k) == "string" and #k == 32, "scalar must be 32 bytes")
  assert(type(u) == "string" and #u == 32, "point must be 32 bytes")

  local z = {string.byte(k, 1, 32)}
  z[1] = bit32.band(z[1], 248)
  z[32] = bit32.bor(bit32.band(z[32], 127), 64)

  local x = unpackgf(u)
  local a, b, c, d, e, f = gf({1}), gf(x), gf(), gf({1}), gf(), gf()

  for i = 254, 0, -1 do
    local r = bit32.band(bit32.rshift(z[math.floor(i / 8) + 1], i % 8), 1)
    sel(a, b, r)
    sel(c, d, r)
    add(e, a, c)
    sub(a, a, c)
    add(c, b, d)
    sub(b, b, d)
    sqr(d, e)
    sqr(f, a)
    mul(a, c, a)
    mul(c, b, e)
    add(e, a, c)
    sub(a, a, c)
    sqr(b, a)
    sub(c, d, f)
    mul(a, c, _121665)
    add(a, a, d)
    mul(c, c, a)
    mul(a, d, f)
    mul(d, b, x)
    sqr(b, e)
    sel(a, b, r)
    sel(c, d, r)
    if i % 32 == 0 then
      yield()
    end
  end

  inv(c, c)
  mul(a, a, c)
  return pack(a)
end

local BASE = string.char(9) .. string.rep("\0", 31)

crypto.x25519 = scalarmult

function crypto.publicKey(sk)
  return scalarmult(sk, BASE)
end

local cache = {}

function crypto.shared(sk, peerPk)
  local id = sk .. peerPk
  if not cache[id] then
    local s = scalarmult(sk, peerPk)
    if s == string.rep("\0", 32) then
      error("invalid peer public key (low-order point)")
    end
    cache[id] = s
  end
  return cache[id]
end

function crypto.clearCache()
  cache = {}
end

-- Ed25519 signatures (RFC 8032). Points are { X, Y, Z, T } in extended coordinates.

local D = gf({0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070, 0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203})
local D2 = gf({0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0, 0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406})
local BX = gf({0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c, 0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169})
local BY = gf({0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666})
local SQRTM1 = gf({0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43, 0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83})

-- The group order, least significant byte first, indexed from 0.
local L = {[0] = 0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10}

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

local function pointZero()
  return {gf(), gf({1}), gf({1}), gf()}
end

local function pointBase()
  local p = {gf(BX), gf(BY), gf({1}), gf()}
  mul(p[4], BX, BY)
  return p
end

local function parity(a)
  return bit32.band(pack(a):byte(1), 1)
end

local function pointPack(p)
  local zi, x, y = gf(), gf(), gf()
  inv(zi, p[3])
  mul(x, p[1], zi)
  mul(y, p[2], zi)
  local s = pack(y)
  return s:sub(1, 31) .. string.char(bit32.bxor(s:byte(32), parity(x) * 128))
end

local function scalarBase(s)
  local p, q = pointZero(), pointBase()
  for i = 255, 0, -1 do
    local b = bit32.band(bit32.rshift(s:byte(math.floor(i / 8) + 1), i % 8), 1)
    for j = 1, 4 do sel(p[j], q[j], b) end
    pointAdd(q, p)
    pointAdd(p, p)
    for j = 1, 4 do sel(p[j], q[j], b) end
    if i % 32 == 0 then
      yield()
    end
  end
  return p
end

-- Reduce the 64 bytes in x (indexed from 0) modulo L.
local function modL(x)
  for i = 63, 32, -1 do
    local carry = 0
    for j = i - 32, i - 13 do
      x[j] = x[j] + carry - 16 * x[i] * L[j - (i - 32)]
      carry = math.floor((x[j] + 128) / 256)
      x[j] = x[j] - carry * 256
    end
    x[i - 12] = x[i - 12] + carry
    x[i] = 0
  end
  local carry = 0
  for j = 0, 31 do
    x[j] = x[j] + carry - math.floor(x[31] / 16) * L[j]
    carry = math.floor(x[j] / 256)
    x[j] = x[j] % 256
  end
  for j = 0, 31 do
    x[j] = x[j] - carry * L[j]
  end
  local r = {}
  for i = 0, 31 do
    x[i + 1] = x[i + 1] + math.floor(x[i] / 256)
    r[i] = x[i] % 256
  end
  return r
end

local function reduce(hex)
  local x = {}
  for i = 0, 63 do
    x[i] = tonumber(hex:sub(2 * i + 1, 2 * i + 2), 16)
  end
  return modL(x)
end

local function scalarString(r)
  local out = {}
  for i = 0, 31 do
    out[i + 1] = string.char(r[i])
  end
  return table.concat(out)
end

local function expandSeed(seed)
  local h = crypto.fromHex(crypto.sha512(seed))
  local first = string.char(bit32.band(h:byte(1), 248))
  local last = string.char(bit32.bor(bit32.band(h:byte(32), 127), 64))
  return first .. h:sub(2, 31) .. last, h:sub(33)
end

-- A new signing key: returns a 32-byte seed and the 32-byte public key.
function crypto.signingKeypair()
  local seed = crypto.randomBytes(32)
  return seed, crypto.signingPublicKey(seed)
end

function crypto.signingPublicKey(seed)
  return pointPack(scalarBase((expandSeed(seed))))
end

-- Returns a 64-byte signature of msg. `publicKey` saves working it out again.
function crypto.sign(seed, msg, publicKey)
  local a, prefix = expandSeed(seed)
  publicKey = publicKey or crypto.signingPublicKey(seed)

  local r = reduce(crypto.sha512(prefix .. msg))
  local R = pointPack(scalarBase(scalarString(r)))
  local h = reduce(crypto.sha512(R .. publicKey .. msg))

  local x = {}
  for i = 0, 63 do
    x[i] = i < 32 and r[i] or 0
  end
  for i = 0, 31 do
    for j = 0, 31 do
      x[i + j] = x[i + j] + h[i] * a:byte(j + 1)
    end
  end

  return R .. scalarString(modL(x))
end

-- Decode a public key into the negated point, or nil if it isn't on the curve.
local function pointUnpackNeg(s)
  local x, y, z, t = gf(), unpackgf(s), gf({1}), gf()
  local num, den, den2, den4, den6, c, chk = gf(), gf(), gf(), gf(), gf(), gf(), gf()

  sqr(num, y)
  mul(den, num, D)
  sub(num, num, z)
  add(den, z, den)
  sqr(den2, den)
  sqr(den4, den2)
  mul(den6, den4, den2)
  mul(c, den6, num)
  mul(c, c, den)

  -- c ^ ((p - 5) / 8)
  local b = gf(c)
  for i = 250, 0, -1 do
    sqr(b, b)
    if i ~= 1 then
      mul(b, b, c)
    end
    if i % 64 == 0 then
      yield()
    end
  end

  mul(b, b, num)
  mul(b, b, den)
  mul(b, b, den)
  mul(x, b, den)

  sqr(chk, x)
  mul(chk, chk, den)
  if pack(chk) ~= pack(num) then
    mul(x, x, SQRTM1)
  end
  sqr(chk, x)
  mul(chk, chk, den)
  if pack(chk) ~= pack(num) then
    return nil
  end

  if parity(x) == bit32.rshift(s:byte(32), 7) then
    sub(x, gf(), x)
  end
  mul(t, x, y)
  return {x, y, z, t}
end

-- Signature scalars must be below L, or one valid signature could be changed into another.
local function scalarIsCanonical(s)
  for i = 31, 0, -1 do
    local b = s:byte(i + 1)
    if b ~= L[i] then
      return b < L[i]
    end
  end
  return false
end

function crypto.verify(publicKey, msg, signature)
  if type(publicKey) ~= "string" or #publicKey ~= 32 or type(signature) ~= "string" or #signature ~= 64 then
    return false
  end
  local R, S = signature:sub(1, 32), signature:sub(33)
  if not scalarIsCanonical(S) then
    return false
  end
  local A = pointUnpackNeg(publicKey)
  if not A then
    return false
  end

  local h = scalarString(reduce(crypto.sha512(R .. publicKey .. msg)))

  -- Work out [h]A + [S]B one bit at a time, sharing the doublings.
  local B, both, p = pointBase(), {gf(A[1]), gf(A[2]), gf(A[3]), gf(A[4])}, pointZero()
  pointAdd(both, B)
  for i = 255, 0, -1 do
    pointAdd(p, p)
    local byte, shift = math.floor(i / 8) + 1, i % 8
    local hb = bit32.band(bit32.rshift(h:byte(byte), shift), 1)
    local sb = bit32.band(bit32.rshift(S:byte(byte), shift), 1)
    if hb + sb == 2 then
      pointAdd(p, both)
    elseif hb == 1 then
      pointAdd(p, A)
    elseif sb == 1 then
      pointAdd(p, B)
    end
    if i % 32 == 0 then
      yield()
    end
  end

  return pointPack(p) == R
end

local pool = ""

local function addEntropy(data)
  pool = crypto.fromHex(sha256(pool .. tostring(data) .. "|" .. os.epoch("utc") .. "|" .. os.clock() .. "|" .. tostring({}) .. "|" .. math.random()))
end

local function jitter()
  local t, n = os.epoch("utc"), 0
  while os.epoch("utc") == t and n < 100000 do
    n = n + 1
  end
  return n
end

crypto.addEntropy = addEntropy

addEntropy(os.getComputerID() .. "|" .. os.time() .. "|" .. tostring((os.getComputerLabel())))
for _ = 1, 8 do
  addEntropy(jitter())
end

function crypto.randomBytes(n)
  local out, len = {}, 0
  while len < n do
    addEntropy(len)
    out[#out + 1] = crypto.fromHex(sha256(pool .. "output"))
    len = len + 32
  end
  return table.concat(out):sub(1, n)
end

function crypto.keypair()
  local sk = crypto.randomBytes(32)
  return sk, crypto.publicKey(sk)
end

local function subkeys(key)
  return crypto.hmac(key, "zos-enc"), crypto.hmac(key, "zos-mac")
end

function crypto.seal(key, plaintext)
  local encKey, macKey = subkeys(key)
  local nonce = crypto.randomBytes(12)
  local ct = crypto.chacha20(encKey, nonce, plaintext)
  return {
    nonce = crypto.toHex(nonce),
    ct = crypto.toHex(ct),
    tag = crypto.toHex(crypto.hmac(macKey, nonce .. ct)),
  }
end

function crypto.open(key, box)
  if type(box) ~= "table" or not crypto.isHex(box.nonce, 24) or not crypto.isHex(box.ct)
      or not crypto.isHex(box.tag, 64) then
    return nil
  end
  local encKey, macKey = subkeys(key)
  local nonce, ct = crypto.fromHex(box.nonce), crypto.fromHex(box.ct)
  if crypto.toHex(crypto.hmac(macKey, nonce .. ct)) ~= box.tag then
    return nil
  end
  return crypto.chacha20(encKey, nonce, ct)
end

function crypto.fingerprint(publicKey)
  local h = sha256("zos-fingerprint" .. publicKey):sub(1, 16)
  return (h:gsub("(....)", "%1 "):gsub(" $", ""))
end

return crypto
