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
