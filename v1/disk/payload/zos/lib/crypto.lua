--[[ zOS cryptography, in pure Lua.

  X25519 (RFC 7748)  Diffie-Hellman key agreement on Curve25519. Field arithmetic
                     follows TweetNaCl: 16 limbs of 16 bits, which keeps every
                     intermediate product exact in Lua's doubles.
  ChaCha20 (RFC 8439) stream cipher.
  HMAC-SHA256        message authentication and key derivation.

Strings passed in and out are raw bytes unless a function says otherwise. Long
computations yield regularly so ComputerCraft doesn't abort them for running too
long without yielding. ]]

local import = ...
local sha256 = import("sha256")

local band, bor, bxor, rshift, lrotate = bit32.band, bit32.bor, bit32.bxor, bit32.rshift, bit32.lrotate
local floor = math.floor
local MOD = 2 ^ 32

local crypto = {}

------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------

function crypto.toHex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

function crypto.fromHex(h)
  return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end

-- True if `s` is a lowercase hex string (of `len` characters, if given).
function crypto.isHex(s, len)
  return type(s) == "string" and #s % 2 == 0 and (len == nil or #s == len) and not s:find("[^0-9a-f]")
end

local function H(s) return crypto.fromHex(sha256(s)) end

-- Let other coroutines run. The filter means this coroutine skips any other
-- events that arrive meanwhile, which is fine for the short pauses used here.
local function yield()
  os.queueEvent("zos_crypto")
  os.pullEventRaw("zos_crypto")
end

------------------------------------------------------------------------------
-- HMAC-SHA256
------------------------------------------------------------------------------

local function xorPad(key, byte)
  return (key:gsub(".", function(c) return string.char(bxor(c:byte(), byte)) end))
end

function crypto.hmac(key, msg)
  if #key > 64 then key = H(key) end
  key = key .. string.rep("\0", 64 - #key)
  return H(xorPad(key, 0x5c) .. H(xorPad(key, 0x36) .. msg))
end

------------------------------------------------------------------------------
-- ChaCha20
------------------------------------------------------------------------------

local function u32le(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return a + b * 0x100 + c * 0x10000 + d * 0x1000000
end

local function chachaBlock(key, nonce, counter)
  local s = { 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574 }
  for i = 0, 7 do s[5 + i] = u32le(key, 1 + i * 4) end
  s[13] = counter
  for i = 0, 2 do s[14 + i] = u32le(nonce, 1 + i * 4) end

  local x = {}
  for i = 1, 16 do x[i] = s[i] end
  local function qr(a, b, c, d)
    x[a] = (x[a] + x[b]) % MOD; x[d] = lrotate(bxor(x[d], x[a]), 16)
    x[c] = (x[c] + x[d]) % MOD; x[b] = lrotate(bxor(x[b], x[c]), 12)
    x[a] = (x[a] + x[b]) % MOD; x[d] = lrotate(bxor(x[d], x[a]), 8)
    x[c] = (x[c] + x[d]) % MOD; x[b] = lrotate(bxor(x[b], x[c]), 7)
  end
  for _ = 1, 10 do
    qr(1, 5, 9, 13); qr(2, 6, 10, 14); qr(3, 7, 11, 15); qr(4, 8, 12, 16)
    qr(1, 6, 11, 16); qr(2, 7, 12, 13); qr(3, 8, 9, 14); qr(4, 5, 10, 15)
  end

  local out = {}
  for i = 1, 16 do
    local v = (x[i] + s[i]) % MOD
    out[i] = string.char(v % 256, floor(v / 0x100) % 256, floor(v / 0x10000) % 256, floor(v / 0x1000000))
  end
  return table.concat(out)
end

-- Encrypt or decrypt `data` (the same operation). key: 32 bytes, nonce: 12 bytes.
function crypto.chacha20(key, nonce, data, counter)
  counter = counter or 1
  local out = {}
  for i = 1, #data, 64 do
    local stream = chachaBlock(key, nonce, counter)
    counter = counter + 1
    local chunk = data:sub(i, i + 63)
    local bytes = {}
    for j = 1, #chunk do bytes[j] = bxor(chunk:byte(j), stream:byte(j)) end
    out[#out + 1] = string.char(table.unpack(bytes))
    if #out % 32 == 0 then yield() end
  end
  return table.concat(out)
end

------------------------------------------------------------------------------
-- X25519
------------------------------------------------------------------------------

local function gf(init)
  local o = {}
  for i = 1, 16 do o[i] = init and init[i] or 0 end
  return o
end

-- Propagate carries so each limb is back in [0, 65535] (2^256 = 38 mod p).
local function car(o)
  for i = 1, 16 do
    local c = floor(o[i] / 65536)
    o[i] = o[i] - c * 65536
    if i < 16 then o[i + 1] = o[i + 1] + c else o[1] = o[1] + 38 * c end
  end
end

local function swap(p, q, bit)
  if bit == 1 then
    for i = 1, 16 do p[i], q[i] = q[i], p[i] end
  end
end

local function add(o, a, b) for i = 1, 16 do o[i] = a[i] + b[i] end end
local function sub(o, a, b) for i = 1, 16 do o[i] = a[i] - b[i] end end

local function mul(o, a, b)
  local t = {}
  for i = 1, 31 do t[i] = 0 end
  for i = 1, 16 do
    local ai = a[i]
    for j = 1, 16 do t[i + j - 1] = t[i + j - 1] + ai * b[j] end
  end
  for i = 1, 15 do t[i] = t[i] + 38 * t[i + 16] end
  for i = 1, 16 do o[i] = t[i] end
  car(o)
  car(o)
end

-- o = i^(p-2), the inverse of i mod p.
local function invert(o, i)
  local c = gf(i)
  for a = 253, 0, -1 do
    mul(c, c, c)
    if a ~= 2 and a ~= 4 then mul(c, c, i) end
    if a % 64 == 0 then yield() end
  end
  for k = 1, 16 do o[k] = c[k] end
end

local function pack(n)
  local t = gf(n)
  car(t); car(t); car(t)
  for _ = 1, 2 do -- subtract p if t >= p
    local m = { t[1] - 0xffed }
    for i = 2, 16 do
      local borrow = 0
      if m[i - 1] < 0 then m[i - 1], borrow = m[i - 1] + 65536, 1 end
      m[i] = t[i] - (i == 16 and 0x7fff or 0xffff) - borrow
    end
    if m[16] >= 0 then t = m end
  end
  local out = {}
  for i = 1, 16 do out[i] = string.char(t[i] % 256, floor(t[i] / 256)) end
  return table.concat(out)
end

local function unpack25519(s)
  local o = {}
  for i = 1, 16 do
    local lo, hi = s:byte(2 * i - 1, 2 * i)
    o[i] = lo + hi * 256
  end
  o[16] = o[16] % 32768
  return o
end

local K121665 = gf({ 0xdb41, 1 })

-- Montgomery ladder: returns the 32-byte result of scalar * point.
local function scalarmult(scalar, point)
  local z = { scalar:byte(1, 32) }
  z[1] = band(z[1], 248)
  z[32] = bor(band(z[32], 127), 64)

  local x = unpack25519(point)
  local a, b, c, d, e, f = gf(), gf(x), gf(), gf(), gf(), gf()
  a[1], d[1] = 1, 1
  for i = 254, 0, -1 do
    local bit = band(rshift(z[floor(i / 8) + 1], i % 8), 1)
    swap(a, b, bit); swap(c, d, bit)
    add(e, a, c); sub(a, a, c); add(c, b, d); sub(b, b, d)
    mul(d, e, e); mul(f, a, a); mul(a, c, a); mul(c, b, e)
    add(e, a, c); sub(a, a, c); mul(b, a, a); sub(c, d, f)
    mul(a, c, K121665); add(a, a, d); mul(c, c, a); mul(a, d, f)
    mul(d, b, x); mul(b, e, e)
    swap(a, b, bit); swap(c, d, bit)
    if i % 32 == 0 then yield() end
  end
  invert(c, c)
  mul(a, a, c)
  return pack(a)
end

local BASE = "\9" .. string.rep("\0", 31)

function crypto.x25519(scalar, point) return scalarmult(scalar, point) end
function crypto.publicKey(secretKey) return scalarmult(secretKey, BASE) end

------------------------------------------------------------------------------
-- Randomness
------------------------------------------------------------------------------

-- ComputerCraft has no secure random source, so we keep a SHA-256 pool fed by
-- clocks, timing jitter, table addresses and math.random, plus anything passed
-- to addEntropy (e.g. key-press timings).
local pool = ""

function crypto.addEntropy(data)
  pool = H(pool .. tostring(data) .. "|" .. os.epoch("utc") .. "|" .. os.clock() .. "|" ..
    tostring({}) .. "|" .. math.random())
end

local function jitter()
  -- How many iterations fit before the millisecond clock ticks varies run to run.
  local t, n = os.epoch("utc"), 0
  while os.epoch("utc") == t and n < 100000 do n = n + 1 end
  return n
end

-- The extra parentheses matter: on an unlabelled computer getComputerLabel()
-- returns no values at all (not nil), and tostring() with no argument errors.
crypto.addEntropy(os.getComputerID() .. "|" .. os.time() .. "|" .. tostring((os.getComputerLabel())))
for _ = 1, 8 do crypto.addEntropy(jitter()) end

function crypto.randomBytes(n)
  local out, len = {}, 0
  while len < n do
    crypto.addEntropy(len)
    out[#out + 1] = H(pool .. "output")
    len = len + 32
  end
  return table.concat(out):sub(1, n)
end

function crypto.keypair()
  local sk = crypto.randomBytes(32)
  return sk, crypto.publicKey(sk)
end

------------------------------------------------------------------------------
-- Shared secrets and authenticated encryption
------------------------------------------------------------------------------

-- X25519 is the slow part, so shared secrets are cached for the session. The
-- cache key includes the secret key, so only its owner can hit an entry.
local cache = {}

function crypto.shared(secretKey, publicKey)
  local id = secretKey .. publicKey
  if not cache[id] then
    local s = scalarmult(secretKey, publicKey)
    if s == string.rep("\0", 32) then error("Invalid public key", 0) end
    cache[id] = s
  end
  return cache[id]
end

function crypto.clearCache() cache = {} end

local function subkeys(key) return crypto.hmac(key, "zos-enc"), crypto.hmac(key, "zos-mac") end

-- Encrypt-then-MAC with a 32-byte key. Returns a table of hex strings.
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

-- Returns the plaintext, or nil if the box was tampered with or the key is wrong.
function crypto.open(key, box)
  if type(box) ~= "table" or not crypto.isHex(box.nonce, 24) or not crypto.isHex(box.ct)
      or not crypto.isHex(box.tag, 64) then
    return nil
  end
  local encKey, macKey = subkeys(key)
  local nonce, ct = crypto.fromHex(box.nonce), crypto.fromHex(box.ct)
  if crypto.toHex(crypto.hmac(macKey, nonce .. ct)) ~= box.tag then return nil end
  return crypto.chacha20(encKey, nonce, ct)
end

-- Short, human-comparable form of a public key, e.g. "3f2a 91c0 7be4 d815".
function crypto.fingerprint(publicKey)
  local h = sha256("zos-fingerprint" .. publicKey):sub(1, 16)
  return (h:gsub("(....)", "%1 "):gsub(" $", ""))
end

return crypto
