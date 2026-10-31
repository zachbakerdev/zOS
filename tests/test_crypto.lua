-- Known-answer tests for crypto.lua. Run from the repository root: luajit tests/test_crypto.lua
package.path = "tests/?.lua;disk/payload/zos/lib/?.lua;" .. package.path
require("cc_shim")

local cooperative = 0
os.getComputerID = function() return 1 end
os.getComputerLabel = function() return nil end
os.epoch = function() return math.floor(os.time() * 1000) end
os.queueEvent = function() cooperative = cooperative + 1 end
os.pullEventRaw = function() end

local crypto = require("crypto")
local hex, unhex = crypto.toHex, crypto.fromHex
local failed = 0

local function check(name, got, want)
  if got ~= want then
    failed = failed + 1
    print("FAIL " .. name .. "\n  got  " .. tostring(got) .. "\n  want " .. tostring(want))
  end
end

-- FIPS 180-4 vectors, including block-boundary padding.
check("sha512 abc", crypto.sha512("abc"),
  "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
check("sha512 empty", crypto.sha512(""),
  "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")

-- RFC 8032 section 7.1: seed, public key, message, signature.
local vectors = {
  { "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b" },
  { "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
    "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
    "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00" },
  { "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
    "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", "af82",
    "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a" },
}

for i, v in ipairs(vectors) do
  local seed, pk, msg, sig = unhex(v[1]), unhex(v[2]), unhex(v[3]), unhex(v[4])
  check("ed25519 public key " .. i, hex(crypto.signingPublicKey(seed)), v[2])
  check("ed25519 sign " .. i, hex(crypto.sign(seed, msg, pk)), v[4])
  check("ed25519 verify " .. i, crypto.verify(pk, msg, sig), true)
  check("ed25519 wrong message " .. i, crypto.verify(pk, msg .. "x", sig), false)
  local bad = sig:sub(1, 5) .. string.char(bit32.bxor(sig:byte(6), 1)) .. sig:sub(7)
  check("ed25519 bad signature " .. i, crypto.verify(pk, msg, bad), false)
end

-- S + L is the same scalar, so it verifies unless it's rejected for being too large.
do
  local v = vectors[1]
  local sig, carry, out = unhex(v[4]), 0, {}
  local L = unhex("edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010")
  for i = 1, 32 do
    local n = sig:byte(32 + i) + L:byte(i) + carry
    out[i], carry = string.char(n % 256), math.floor(n / 256)
  end
  check("ed25519 rejects S + L", crypto.verify(unhex(v[2]), "", sig:sub(1, 32) .. table.concat(out)), false)
end

check("ed25519 rejects off-curve key", crypto.verify(string.rep("\2", 32), "", string.rep("\0", 64)), false)
check("ed25519 rejects short signature", crypto.verify(unhex(vectors[1][2]), "", "x"), false)

local seed, pk = crypto.signingKeypair()
check("ed25519 sign and verify", crypto.verify(pk, "hello", crypto.sign(seed, "hello")), true)
check("crypto yields during signing", cooperative > 0, true)

local sk, public = crypto.keypair()
local _, otherPublic = crypto.keypair()
local sealed = crypto.sealTo(public, "for your eyes")
check("sealed to a key", crypto.openSealed(sk, public, sealed), "for your eyes")
check("sealed to another key", crypto.openSealed(crypto.randomBytes(32), otherPublic, sealed), nil)
check("sealed empty", crypto.openSealed(sk, public, crypto.sealTo(public, "")), "")
check("sealed rubbish", crypto.openSealed(sk, public, { eph = "zz" }), nil)
check("low-order key refused", crypto.sealTo(string.rep("\0", 32), "x"), nil)
local tampered = crypto.sealTo(public, "x")
tampered.eph = hex(select(2, crypto.keypair()))
check("sealed with a changed key", crypto.openSealed(sk, public, tampered), nil)

local locked = crypto.lock("hunter2", "secret")
check("locked", crypto.unlock("hunter2", locked), "secret")
check("wrong password", crypto.unlock("hunter3", locked), nil)
check("locked rubbish", crypto.unlock("hunter2", "x"), nil)
check("each lock has its own salt", crypto.lock("hunter2", "secret").salt ~= locked.salt, true)

if failed > 0 then os.exit(1) end
print("crypto: all passed")
