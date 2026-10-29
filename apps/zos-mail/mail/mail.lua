--[[ zOS mail: messages between users on this and other computers.

Addresses look like `user@computer`, where computer is a computer ID or a label
(labels without spaces only). A bare `user` means a user on this computer.

Remote mail travels over rednet (any wired or wireless modem) on the "zos-mail"
protocol. The receiving computer's mail service stores the message and replies
with an acknowledgement, so the sender knows whether it was delivered. The
service also answers requests for its users' public keys.

Encryption: message bodies are encrypted with a key both sides can derive,
  shared = X25519(sender secret key, recipient public key)
         = X25519(recipient secret key, sender public key)
  key    = HMAC-SHA256(shared, "zos-mail-v1" .. senderPub .. recipientPub)
then sealed with ChaCha20 + HMAC-SHA256 (see crypto.lua). A message that
decrypts was therefore written by the holder of the sender key it names. The
sender can decrypt it too, so the copy in "sent" is the same envelope.
Subjects are not encrypted.

Messages are stored as files in /etc/zos/mail/<user>/{inbox,sent}/. Unread inbox
messages end in ".new", so counting unread mail only needs a directory listing.

This file ships with the Mail app (not in /zos/lib). Load it with
  loadfile(<app folder> .. "/mail.lua", nil, _G)(zos.import) ]]

local import = ...
local auth, crypto, keys = import("auth"), import("crypto"), import("keys")

local mail = {}

mail.PROTOCOL = "zos-mail"
mail.ROOT = "/etc/zos/mail"
local MAX_SUBJECT, MAX_BODY, MAX_ADDRESS = 64, 8192, 64
local TIMEOUT = 5

local function folderDir(user, folder) return fs.combine(mail.ROOT, user .. "/" .. folder) end

local function newId()
  return string.format("%d-%04d", os.epoch("utc"), math.random(0, 9999))
end

local function writeMessage(user, folder, file, msg)
  local dir = folderDir(user, folder)
  fs.makeDir(dir)
  local f = fs.open(fs.combine(dir, file), "w")
  f.write(textutils.serialise(msg))
  f.close()
end

-- Open every attached modem for rednet. Returns true if there is at least one.
function mail.openModems()
  local any = false
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      any = true
    end
  end
  return any
end

-- This computer's name in mail addresses.
function mail.hostname()
  local label = os.getComputerLabel()
  if label and not label:find("%s") then return label end
  return tostring(os.getComputerID())
end

function mail.address(user) return user .. "@" .. mail.hostname() end

-- Split an address into user and host (host is nil for a local address).
function mail.parse(address)
  local user, host = address:match("^%s*([%w_%-]+)@(%S+)%s*$")
  if user then return user, host end
  return address:match("^%s*([%w_%-]+)%s*$"), nil
end

local function isLocal(host)
  return host == nil or host == tostring(os.getComputerID()) or host == os.getComputerLabel()
end

-- Find the computer ID for a host name or ID.
function mail.resolve(host)
  if isLocal(host) then return os.getComputerID() end
  if not mail.openModems() then return nil, "No modem attached. Only local mail is possible." end
  if host:match("^%d+$") then return tonumber(host) end
  local id = rednet.lookup(mail.PROTOCOL, host)
  if not id then return nil, "Can't find a computer called '" .. host .. "'." end
  return id
end

-- Send a request to another computer's mail service and wait for its reply.
local function request(id, payload, replyType)
  payload.nonce = newId()
  rednet.send(id, payload, mail.PROTOCOL)
  local deadline = os.clock() + TIMEOUT
  while true do
    local left = deadline - os.clock()
    if left <= 0 then return nil, "No reply from computer #" .. id .. ". Is it running zOS and in range?" end
    local from, reply = rednet.receive(mail.PROTOCOL, left)
    if from == id and type(reply) == "table" and reply.type == replyType and reply.nonce == payload.nonce then
      return reply
    end
  end
end

-- Ask computer `id` for its user's public key.
local function fetchKey(id, user)
  if id == os.getComputerID() then
    local pk = keys.publicKey(user)
    if not pk then return nil, user .. " has no encryption key yet (they need to log in once)." end
    return pk
  end
  if not mail.openModems() then return nil, "No modem attached." end
  local reply, err = request(id, { type = "getkey", user = user }, "key")
  if not reply then return nil, err end
  if not crypto.isHex(reply.key, 64) then
    return nil, user .. "@" .. id .. " has no encryption key (an older zOS, or they haven't logged in yet)."
  end
  return crypto.fromHex(reply.key)
end

--[[ Find a recipient's public key. Remote keys are pinned the first time they're
seen. Returns the key, or nil plus an info table:
  { code = "nokey" | "keychanged", message = ..., address = ..., old = ..., new = ... } ]]
function mail.lookupKey(user, id)
  local address = user .. "@" .. id
  local pk, err = fetchKey(id, user)
  if not pk then return nil, { code = "nokey", message = err, address = address } end
  if id ~= os.getComputerID() then
    local pinned = keys.known(address)
    if pinned and pinned ~= pk then
      return nil, { code = "keychanged", address = address, old = pinned, new = pk,
        message = "The encryption key for " .. address .. " has changed." }
    end
    if not pinned then keys.remember(address, pk) end
  end
  return pk
end

local function messageKey(shared, fromPk, toPk)
  return crypto.hmac(shared, "zos-mail-v1" .. fromPk .. toPk)
end

function mail.encrypt(secretKey, publicKey, recipientKey, text)
  local box = crypto.seal(messageKey(crypto.shared(secretKey, recipientKey), publicKey, recipientKey), text)
  box.from, box.to = crypto.toHex(publicKey), crypto.toHex(recipientKey)
  return box
end

-- Decrypt a message's body with the reader's keys. Returns text or nil, error.
function mail.decrypt(msg, secretKey, publicKey)
  local enc = msg.enc
  local fromPk, toPk = crypto.fromHex(enc.from), crypto.fromHex(enc.to)
  local peer
  if toPk == publicKey then peer = fromPk
  elseif fromPk == publicKey then peer = toPk
  else return nil, "This message was encrypted for a different key (yours may have been reset)."
  end
  local text = crypto.open(messageKey(crypto.shared(secretKey, peer), fromPk, toPk), enc)
  if not text then return nil, "The message could not be decrypted. It may have been tampered with." end
  return text
end

--[[ Check that an encrypted message's sender key belongs to the address it
claims to be from. Returns:
  "verified"   matches the key on record for that user and computer
  "changed"    does NOT match: possibly forged, or the sender's key was reset
  "unverified" no key on record and their computer couldn't be reached ]]
function mail.checkSender(msg)
  local user = msg.from:match("^([%w_%-]+)@")
  if not user then return "unverified" end
  local fromPk = crypto.fromHex(msg.enc.from)
  local id = msg.via or os.getComputerID()
  if id == os.getComputerID() then
    return keys.publicKey(user) == fromPk and "verified" or "changed"
  end
  local address = user .. "@" .. id
  local pinned = keys.known(address)
  if not pinned then
    pinned = fetchKey(id, user)
    if not pinned then return "unverified" end
    keys.remember(address, pinned)
  end
  return pinned == fromPk and "verified" or "changed"
end

-- Check an incoming message and copy just the fields we expect.
local function clean(msg)
  if type(msg) ~= "table" then return nil, "Malformed message." end
  for _, key in ipairs({ "rcpt", "to", "from", "subject", "body" }) do
    if type(msg[key]) ~= "string" then return nil, "Malformed message." end
  end
  if #msg.subject > MAX_SUBJECT or #msg.body > MAX_BODY or #msg.from > MAX_ADDRESS or #msg.to > MAX_ADDRESS then
    return nil, "Message too large."
  end
  local m = {
    rcpt = msg.rcpt,
    to = msg.to,
    from = msg.from,
    subject = msg.subject,
    body = msg.body,
    time = tonumber(msg.time) or os.epoch("utc"),
  }
  local enc = msg.enc
  if enc ~= nil then
    if type(enc) ~= "table" or not crypto.isHex(enc.from, 64) or not crypto.isHex(enc.to, 64)
        or not crypto.isHex(enc.nonce, 24) or not crypto.isHex(enc.tag, 64)
        or not crypto.isHex(enc.ct) or #enc.ct > 2 * MAX_BODY then
      return nil, "Malformed message."
    end
    m.enc = { from = enc.from, to = enc.to, nonce = enc.nonce, ct = enc.ct, tag = enc.tag }
  end
  return m
end

-- Store a message in a local user's inbox. `via` is the sending computer's ID
-- (nil for local mail).
function mail.deliver(msg, via)
  local m, err = clean(msg)
  if not m then return false, err end
  if not auth.exists(m.rcpt) then
    return false, "There is no user '" .. m.rcpt .. "' on " .. mail.hostname() .. "."
  end
  m.via = via
  writeMessage(m.rcpt, "inbox", newId() .. ".new", m)
  os.queueEvent("zos_mail", m.rcpt)
  return true
end

--[[ Send a message from a local user.
  opts.secretKey, opts.publicKey  the sender's unlocked keys (required to encrypt)
  opts.plain                      send unencrypted
  opts.trustNewKey                accept (and pin) a changed recipient key
Returns true, or false, an error message and (for key problems) an info table
from mail.lookupKey. ]]
function mail.send(fromUser, address, subject, body, opts)
  opts = opts or {}
  local user, host = mail.parse(address)
  if not user then return false, "Addresses look like user@computer." end
  if #body > MAX_BODY then return false, "Message too long (max " .. MAX_BODY .. " characters)." end
  local id, err = mail.resolve(host)
  if not id then return false, err end

  local msg = {
    rcpt = user,
    to = user .. "@" .. (isLocal(host) and mail.hostname() or host),
    from = mail.address(fromUser),
    subject = subject,
    body = body,
    time = os.epoch("utc"),
  }

  if not opts.plain then
    if not opts.secretKey then
      return false, "Your encryption key isn't unlocked. Log out and back in.", { code = "locked" }
    end
    local pk, info = mail.lookupKey(user, id)
    if not pk and info.code == "keychanged" and opts.trustNewKey then
      keys.remember(info.address, info.new)
      pk = info.new
    end
    if not pk then return false, info.message, info end
    msg.enc = mail.encrypt(opts.secretKey, opts.publicKey, pk, body)
    msg.body = ""
  end

  local m
  m, err = clean(msg)
  if not m then return false, err end

  local ok
  if id == os.getComputerID() then
    ok, err = mail.deliver(msg)
  else
    local reply
    reply, err = request(id, { type = "deliver", msg = msg }, "ack")
    ok = reply ~= nil and reply.ok == true
    if reply then err = reply.err end
  end
  if ok then writeMessage(fromUser, "sent", newId(), m) end
  return ok, err
end

-- Messages in a folder ("inbox" or "sent"), newest first.
function mail.list(user, folder)
  local dir, out = folderDir(user, folder), {}
  if not fs.isDir(dir) then return out end
  for _, file in ipairs(fs.list(dir)) do
    local f = fs.open(fs.combine(dir, file), "r")
    local m = textutils.unserialise(f.readAll())
    f.close()
    if type(m) == "table" then
      m.file = file
      m.read = not file:match("%.new$")
      out[#out + 1] = m
    end
  end
  table.sort(out, function(a, b) return (a.time or 0) > (b.time or 0) end)
  return out
end

function mail.unread(user)
  local dir, n = folderDir(user, "inbox"), 0
  if not fs.isDir(dir) then return 0 end
  for _, file in ipairs(fs.list(dir)) do
    if file:match("%.new$") then n = n + 1 end
  end
  return n
end

function mail.markRead(user, msg)
  if msg.read then return end
  local dir = folderDir(user, "inbox")
  local file = msg.file:gsub("%.new$", "")
  fs.move(fs.combine(dir, msg.file), fs.combine(dir, file))
  msg.file, msg.read = file, true
end

function mail.delete(user, folder, msg)
  fs.delete(fs.combine(folderDir(user, folder), msg.file))
end

-- Background service: accept mail and answer key requests. Never returns.
function mail.service()
  mail.openModems()
  while true do
    local event, sender, message, protocol = os.pullEventRaw()
    if event == "rednet_message" and protocol == "dns" and type(message) == "table"
        and message.sType == "lookup" and message.sProtocol == mail.PROTOCOL then
      -- Answer rednet.lookup ourselves rather than calling rednet.host once at
      -- boot, so the reply always uses the current label, even one set later.
      local label = os.getComputerLabel()
      if label and label == mail.hostname() and (message.sHostname == nil or message.sHostname == label) then
        rednet.send(sender, { sType = "lookup response", sHostname = label, sProtocol = mail.PROTOCOL }, "dns")
      end
    elseif event == "rednet_message" and protocol == mail.PROTOCOL and type(message) == "table" then
      if message.type == "deliver" then
        local ok, err = mail.deliver(message.msg, sender)
        rednet.send(sender, { type = "ack", nonce = message.nonce, ok = ok, err = err }, mail.PROTOCOL)
      elseif message.type == "getkey" and auth.validName(message.user) then
        local pk = keys.publicKey(message.user)
        rednet.send(sender, { type = "key", nonce = message.nonce, key = pk and crypto.toHex(pk) }, mail.PROTOCOL)
      end
    elseif event == "peripheral" then
      mail.openModems() -- a modem may have been attached
    end
  end
end

return mail
