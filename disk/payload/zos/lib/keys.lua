--[[ zOS encryption keys.

Each user has an X25519 key pair:
  /etc/zos/keys/<user>.pub   public key (hex), shared with anyone who asks
  /etc/zos/keys/<user>.key   secret key, encrypted with a key derived from the
                             user's login password

The secret key is unlocked at login and kept in memory for the session, so
other users of the computer can't read it from disk.

Public keys of people on other computers are pinned the first time they are
seen ("trust on first use", like SSH) in /etc/zos/mail/known_keys, keyed by
user@<computer ID>. ]]

local import = ...
local crypto, sha256 = import("crypto"), import("sha256")

local keys = {}

keys.DIR = "/etc/zos/keys"
local KNOWN = "/etc/zos/mail/known_keys"
local ITERATIONS = 200

local function readTable(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local data = textutils.unserialise(f.readAll())
  f.close()
  return data
end

local function writeTable(path, value)
  fs.makeDir(fs.getDir(path))
  local f = fs.open(path, "w")
  f.write(textutils.serialise(value))
  f.close()
end

local function paths(user)
  return fs.combine(keys.DIR, user .. ".pub"), fs.combine(keys.DIR, user .. ".key")
end

-- Key-encryption key from the password (separate from the login hash).
local function passwordKey(password, salt)
  local h = sha256("zos-key|" .. salt .. "|" .. password)
  for _ = 2, ITERATIONS do h = sha256(h .. salt .. password) end
  return crypto.fromHex(h)
end

local function store(user, password, secretKey, publicKey)
  local pubPath, keyPath = paths(user)
  local salt = crypto.toHex(crypto.randomBytes(16))
  writeTable(keyPath, { salt = salt, box = crypto.seal(passwordKey(password, salt), secretKey) })
  local f = fs.open(pubPath, "w")
  f.write(crypto.toHex(publicKey))
  f.close()
end

local function unwrap(user, password)
  local _, keyPath = paths(user)
  local data = readTable(keyPath)
  if type(data) ~= "table" or type(data.salt) ~= "string" then return nil end
  local sk = crypto.open(passwordKey(password, data.salt), data.box)
  if sk and #sk == 32 then return sk end
end

-- A user's public key (raw bytes), or nil if they have none yet.
function keys.publicKey(user)
  local pubPath = paths(user)
  if not fs.exists(pubPath) then return nil end
  local f = fs.open(pubPath, "r")
  local hex = f.readAll():gsub("%s", "")
  f.close()
  return crypto.isHex(hex, 64) and crypto.fromHex(hex) or nil
end

function keys.hasKey(user)
  local _, keyPath = paths(user)
  return fs.exists(keyPath)
end

--[[ Unlock the user's secret key with their password, creating a key pair if
they don't have one (or it can't be unlocked, e.g. after an admin reset their
password). Returns secretKey, publicKey, created. ]]
function keys.unlock(user, password)
  local sk, pk = unwrap(user, password), keys.publicKey(user)
  if sk and pk then return sk, pk, false end
  sk, pk = crypto.keypair()
  store(user, password, sk, pk)
  return sk, pk, true
end

-- Re-encrypt the secret key after a password change.
function keys.rewrap(user, oldPassword, newPassword)
  local sk = unwrap(user, oldPassword)
  if not sk then return false end
  store(user, newPassword, sk, keys.publicKey(user))
  return true
end

-- Delete a user's key pair. A new one is made at their next login.
function keys.forget(user)
  for _, path in ipairs({ paths(user) }) do
    if fs.exists(path) then fs.delete(path) end
  end
end

function keys.reset()
  if fs.exists(keys.DIR) then fs.delete(keys.DIR) end
  if fs.exists(KNOWN) then fs.delete(KNOWN) end
end

-- Pinned public keys of remote users, by "user@<computer ID>".
function keys.known(address)
  local hex = (readTable(KNOWN) or {})[address]
  return hex and crypto.fromHex(hex) or nil
end

function keys.remember(address, publicKey)
  local db = readTable(KNOWN) or {}
  db[address] = crypto.toHex(publicKey)
  writeTable(KNOWN, db)
end

function keys.forgetKnown(address)
  local db = readTable(KNOWN) or {}
  db[address] = nil
  writeTable(KNOWN, db)
end

-- Sorted list of { address = ..., fingerprint = ... }.
function keys.knownList()
  local out = {}
  for address, hex in pairs(readTable(KNOWN) or {}) do
    out[#out + 1] = { address = address, fingerprint = crypto.fingerprint(crypto.fromHex(hex)) }
  end
  table.sort(out, function(a, b) return a.address < b.address end)
  return out
end

keys.fingerprint = crypto.fingerprint

return keys
