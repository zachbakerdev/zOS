-- Pure-Lua SHA-256 for ComputerCraft (uses the bit32 library).
-- Returns a function: sha256(message) -> 64 character lowercase hex digest.

local band, bxor, bnot = bit32.band, bit32.bxor, bit32.bnot
local rrotate, rshift, lshift = bit32.rrotate, bit32.rshift, bit32.lshift
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

-- Pad the message to a multiple of 64 bytes, ending with its bit length.
local function pad(msg)
  local len = #msg
  local zeros = (55 - len) % 64
  local bits, tail = len * 8, {}
  for i = 8, 1, -1 do
    tail[i] = string.char(bits % 256)
    bits = math.floor(bits / 256)
  end
  return msg .. "\128" .. string.rep("\0", zeros) .. table.concat(tail)
end

local function block(msg, offset, H)
  local w = {}
  for i = 1, 16 do
    local a, b, c, d = msg:byte(offset + (i - 1) * 4, offset + (i - 1) * 4 + 3)
    w[i] = lshift(a, 24) + lshift(b, 16) + lshift(c, 8) + d
  end
  for i = 17, 64 do
    local v15, v2 = w[i - 15], w[i - 2]
    local s0 = bxor(rrotate(v15, 7), rrotate(v15, 18), rshift(v15, 3))
    local s1 = bxor(rrotate(v2, 17), rrotate(v2, 19), rshift(v2, 10))
    w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % MOD
  end

  local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
  for i = 1, 64 do
    local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
    local ch = bxor(band(e, f), band(bnot(e), g))
    local t1 = (h + S1 + ch + K[i] + w[i]) % MOD
    local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
    local maj = bxor(band(a, b), band(a, c), band(b, c))
    local t2 = (S0 + maj) % MOD
    h, g, f, e, d, c, b, a = g, f, e, (d + t1) % MOD, c, b, a, (t1 + t2) % MOD
  end

  H[1] = (H[1] + a) % MOD; H[2] = (H[2] + b) % MOD
  H[3] = (H[3] + c) % MOD; H[4] = (H[4] + d) % MOD
  H[5] = (H[5] + e) % MOD; H[6] = (H[6] + f) % MOD
  H[7] = (H[7] + g) % MOD; H[8] = (H[8] + h) % MOD
end

return function(msg)
  msg = pad(tostring(msg))
  local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
  for offset = 1, #msg, 64 do
    block(msg, offset, H)
  end
  local out = {}
  for i = 1, 8 do out[i] = string.format("%08x", H[i]) end
  return table.concat(out)
end
