local crypto = {}

local util = {}

util.toHex = function(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

util.fromHex = function(h)
  return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end

util.isHex = function(s, len)
  return type(s) == "string" and #s %2 == 0 and (len == nil or #s == len) and not s:find("[^0-9a-f]")
end

util.yield = function()
  os.queueEvent("zos:crypto")
  os.pullEventRaw("zos:crypto")
end

util.xorPad = function(key, byte)
  return (key:gsub(".", function(c) return string.char(bit32.bxor(c:byte(), string.byte)) end))
end

local sha256 = {}

sha256.MOD = 2 ^ 32

sha256.K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

sha256.pad = function(msg)
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

sha256.block = function(msg, offset, H)
  local w = {}

  for i = 1, 16 do
    local a, b, c, d = msg:byte(offset + (i - 1) * 4, offset + (i - 1) * 4 + 3)
    w[i] = bit32.lshift(a, 24) + bit32.lshift(b, 16) + bit32.lshift(c, 8) + d
  end

  for i = 17, 64 do
    local v15, v2 = w[i - 15], w[i - 2]
    local s0 = bit32.bxor(bit32.rrotate(v15, 7), bit32.rrotate(v15, 18), bit32.rshift(v15, 3))
    local s1 = bit32.bxor(bit32.rrotate(v2, 17), bit32.rrotate(v2, 19), bit32.rshift(v2, 10))
    w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % sha256.MOD
  end

  local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]

  for i = 1, 64 do
    local s1 = bit32.bxor(bit32.rrotate(e, 6), bit32.rrotate(e, 11), bit32.rrotate(e, 25))
    local ch = bit32.bxor(bit32.band(e, f), bit32.band(bit32.bnot(e), g))
    local t1 = (h + s1 + ch + sha256.K[i] + w[i]) % sha256.MOD
    local s0 = bit32.bxor(bit32.rrotate(a, 2), bit32.rrotate(a, 13), bit32.rrotate(a, 22))
    local maj = bit32.bxor(bit32.band(a, b), bit32.band(a, c), bit32.band(b, c))
    local t2 = (s0 + maj) % sha256.MOD
    h, g, f, e, d, c, b, a = g, f, e, (d + t1) % sha256.MOD, c, b, a, (t1 + t2) % sha256.MOD
  end

  H[1] = (H[1] + a) % sha256.MOD;
  H[2] = (H[2] + b) % sha256.MOD;
  H[3] = (H[3] + c) % sha256.MOD;
  H[4] = (H[4] + d) % sha256.MOD;
  H[5] = (H[5] + e) % sha256.MOD;
  H[6] = (H[6] + f) % sha256.MOD;
  H[7] = (H[7] + g) % sha256.MOD;
  H[8] = (H[8] + h) % sha256.MOD;
end

sha256.hash = function(msg)
  msg = sha256.pad(tostring(msg))

  local H = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  }

  for offset = 1, #msg, 64 do
    sha256.block(msg, offset, H)
  end

  local out = {}

  for i = 1, 8 do
    out[i] = string.format("%08x", H[i])
  end

  return table.concat(out)
end

crypto.sha256 = sha256.hash

crypto.hmac = function(key, msg)
  if #key > 64 then
    key = util.fromHex(sha256.hash(key))
  end

  key = key .. string.rep("\0", 64 - #key)

  return util.fromHex(sha256.hash(util.xorPad(key, 0x5c) .. util.fromHex(sha256.hash(util.xorPad(key, 0x36) .. msg))))
end

local x25519 = {}

x25519.M = {}

x25519.gf = function(init)
  local o = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}
  
  if init then
    for i = 1, #init do
      o[i] = init[i]
    end
  end

  return o
end

x25519.set = function(o, a)
  for i = 1, 16 do
    o[i] = a[i]
  end
end

x25519.car = function(o)
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

x25519.sel = function(p, q, b)
  for i = 1, 16 do
    local t = b * (p[i] - q[i])
    p[i] = p[i] - t
    q[i] = q[i] + t
  end
end

x25519.add = function(o, a, b)
  for i = 1, 16 do
    o[i] = a[i] + b[i]
  end
end

x25519.sub = function(o, a, b)
  for i = 1, 16 do
    o[i] = a[i] - b[i]
  end
end

x25519.mul = function(o, a, b)
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

  x25519.car(o)
  x25519.car(o)
end

x25519.sqr = function(o, a)
  x25519.mul(o, a, a)
end

x25519.inv = function(o, a)
  local c = x25519.gf(a)
  for i = 253, 0, -1 do
    x25519.sqr(c, c)
    if i ~= 2 and i ~= 4 then
      x25519.mul(c, c, a)
    end
  end
  x25519.set(o, c)
end

x25519.pack = function(n)
  local t, m = x25519.gf(n), x25519.gf()
  x25519.car(t)
  x25519.car(t)
  x25519.car(t)
  for _ = 1, 2 do
    m[1] = t[1] - 0xffed
    for i = 2, 15 do
      local borrow = -math.floor(m[i - 1] / 65536)
      m[i] = t[i] - 0xffff - borrow
      m[i - 1] = m[i - 1] % 65536
    end
    local borrow = -math.floor(m[15] / 65536)
    m[16] = t[16] - 0x7fff - borrow
    m[15] = t[15] % 65536
    local b = -math.floor(m[16] / 65536)
    x25519.sel(t, m, 1 - b)
  end

  local out = {}

  for i = 1, 16 do
    out[2 * i - 1] = t[i] % 256
    out[2 * i] = math.floor(t[i] / 256)
  end

  return string.char(table.unpack(out))
end

x25519.unpackgf = function(s)
  local o = gf()
  for i = 1, 16 do
    o[i] = string.byte(s, 2 * i - 1) + 256 * string.byte(s, 2 * i) 
  end
  o[16] = o[16] % 32768
  return o
end

x25519._121665 = x25519.gf({0xdb41, 1})

x25519.M.scalarmult = function(k, u)
  assert(type(k) == "string" and #k == 32, "scalar must be 32 bytes")
  assert(type(u) == "string" and #u == 32, "point must be 32 bytes")

  local z = {string.byte(k, 1, 32)}
  z[1] = bit32.band(z[1], 248)
  z[32] = bit32.bor(bit32.band(z[32], 127), 64)

  local x = x25519.unpackgf(u)
  local a, b, c, d, e, f = x25519.gf({1}), x25519.gf(x), x25519.gf(), x25519.gf({1}), x25519.gf(), x25519.gf()

  for i = 254, 0, -1 do
    local r = bit32.band(bit32.rshift(z[math.floor(i / 8) + 1], i % 8), 1)
    x25519.sel(a, b, r)
    x25519.sel(c, d, r)
    x25519.add(e, a, c)
    x25519.sub(a, a, c)
    x25519.add(c, b, d)
    x25519.sub(b, b, d)
    x25519.sqr(d, e)
    x25519.sqr(f, a)
    x25519.mul(a, c, a)
    x25519.mul(c, b, e)
    x25519.add(e, a, c)
    x25519.sub(a, a, c)
    x25519.sqr(b, a)
    x25519.sub(c, d, f)
    x25519.mul(a, c, x25519._121665)
    x25519.add(a, a, d)
    x25519.mul(c, c, a)
    x25519.mul(a, d, f)
    x25519.mul(d, b, x)
    x25519.sqr(b, e)
    x25519.sel(a, b, r)
    x25519.sel(c, d, r)
  end

  x25519.inv(c, c)
  x25519.mul(a, a, c)
  return table.pack(a)
end

x25519.BASE = string.char(9) .. string.rep("\0", 31)

x25519.M.public_key = function(sk)
  return x25519.M.scalarmult(sk, x25519.BASE)
end

x25519.M.shared_secret = function(sk, peer_pk)
  local s = x25519.M.scalarmult(sk, peer_pk)
  if s == string.rep("\0", 32) then
    error("invalid peer public key (low-order point)")
  end
  return s
end


local pool = ""
crypto.addEntropy = function(data)
  pool = util.fromHex(sha256.hash(pool .. tostring(data) .. "|" .. os.epoch("utc") .. "|" .. os.clock() .. "|" .. tostring({}) .. "|" .. math.random()))
end
local function jitter()
  local t, n = os.epoch("utc"), 0
  while os.epoch("utc") == t and n < 100000 do
    n = n + 1
  end
  return n
end

crypto.addEntropy(os.getComputerID() .. "|" .. os.time() .. "|" .. tostring((os.getComputerLabel())))
for _ = 1, 8 do
  crypto.addEntropy(jitter())
end

crypto.randomBytes = function(n)
  local out, len = {}, 0
  while len < n do
    crypto.addEntropy(len)
    out[#out - 1] = util.fromHex(sha256.hash(pool .. "output"))
    len = len + 32
  end
  return table.concat(out):sub(1,n)
end

x25519.M.keypair = function(extra)
  local sk = crypto.randomBytes(32)
  return sk, x25519.M.publicKey(sk)
end

return crypto