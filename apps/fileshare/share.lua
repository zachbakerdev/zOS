--[[ zOS File Share: the lists of trusted computers and shared files, and both ends of the protocol.

Computers talk directly, with no server between them. A computer only serves another once
someone has compared that computer's fingerprint and added it, so both sides have to add each
other. net.lua proves which key each message came from, and this file checks that key against
the trusted list for every request.

Files get a second layer of encryption, under a key only the two trusted keys can arrive at. A
net.lua session is picked by computer id, so without this a reply could go down a session with
some other key that a root server had vouched for. The client's first message comes from a
trusted key, and the server signs both ephemeral keys, so:

  open   client -> server   client's ephemeral key
         server -> client   server's ephemeral key, signature over both and both identities
  call   client -> server   sealed: seq, op, argument
         server -> client   sealed: seq, "ok" or "err", result

The client checks the signature against the key it stored when the fingerprint was compared,
and sends nothing sealed until it has. seq only goes up and the answer repeats it, so an answer
can't be swapped for another. A download starts with `get`, which keeps a copy of the file in
memory: it can't change partway through, and hashing it whole would run too long without
yielding. Each chunk is sealed and tied to its request, so size is all that's left to check. ]]

local crypto = require("crypto")
local net = require("net")
local system = require("system")
local trust = require("trust")
local util = require("util")

local share = {}

share.PORT = 4201
share.CHUNK = 8192 -- sealing doubles this, and net.lua takes 32 KB

local PROTOCOL = "zos-share-1"
local DIR = "/etc/zos/fileshare"
local PEERS = fs.combine(DIR, "peers")
local FILES = fs.combine(DIR, "files")

local MAX_NAME = 48
local MAX_CHANNELS = 8
local CHANNEL_IDLE = 300000 -- ms
local OPEN_TIMEOUT = 30 -- seconds; signing and key agreement are slow
local CALL_TIMEOUT = 15
local TRIES = 3
-- Top-level folders holding password hashes and private keys, or nothing worth sharing.
local PRIVATE = { etc = true, zos = true, rom = true, ["startup.lua"] = true }

local function now()
    return os.epoch("utc")
end

------------------------------------------------------------------------------
-- Trusted computers
------------------------------------------------------------------------------

local function loadPeers()
    return util.readTable(PEERS) or {}
end

-- Every trusted computer as { key, id, name, fingerprint }, sorted by name.
function share.peers()
    local out = {}
    for key, peer in pairs(loadPeers()) do
        peer.key, peer.fingerprint = key, trust.fingerprint(crypto.fromHex(key))
        out[#out + 1] = peer
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

function share.isTrusted(key)
    return loadPeers()[key] ~= nil
end

-- The trusted computer that goes by this id, if any.
function share.peerById(id)
    for _, peer in ipairs(share.peers()) do
        if peer.id == id then return peer end
    end
end

function share.trustPeer(found)
    local peers = loadPeers()
    peers[found.key] = { id = found.id, name = found.name, added = now() }
    util.writeTable(PEERS, peers)
end

function share.forgetPeer(key)
    local peers = loadPeers()
    peers[key] = nil
    util.writeTable(PEERS, peers)
end

------------------------------------------------------------------------------
-- Shared files
------------------------------------------------------------------------------

-- Names come from other computers and end up in a path, so "/" and a leading "." can't be in one.
function share.validName(name)
    return type(name) == "string" and #name <= MAX_NAME and name:match("^[%w_%-][%w_%.%- ]*$") ~= nil
end

local function loadFiles()
    return util.readTable(FILES) or {}
end

-- Every shared file that's still there, as { name, path, size }, sorted by name.
function share.files()
    local out = {}
    for name, path in pairs(loadFiles()) do
        if fs.exists(path) and not fs.isDir(path) then
            out[#out + 1] = { name = name, path = path, size = fs.getSize(path) }
        end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

-- Share a file under its own name. Returns the name, or nil and a reason.
function share.addFile(path)
    path = fs.combine("/", path)
    if PRIVATE[path:match("^[^/]*"):lower()] then return nil, "Files in /" .. path:match("^[^/]*") .. " can't be shared." end
    if not fs.exists(path) then return nil, "There's no file called /" .. path .. "." end
    if fs.isDir(path) then return nil, "Only single files can be shared." end
    local name = path:match("[^/]+$")
    if not share.validName(name) then
        return nil, "File names are 1-" .. MAX_NAME .. " letters, digits, spaces, ., - or _, and can't start with a dot."
    end
    local files = loadFiles()
    if files[name] and files[name] ~= path then return nil, "Another file called " .. name .. " is already shared." end
    files[name] = path
    util.writeTable(FILES, files)
    return name
end

function share.removeFile(name)
    local files = loadFiles()
    files[name] = nil
    util.writeTable(FILES, files)
end

------------------------------------------------------------------------------
-- Keys
------------------------------------------------------------------------------

local function transcriptOf(ephClient, ephServer, keyClient, keyServer)
    return crypto.fromHex(crypto.sha256(PROTOCOL .. ephClient .. ephServer .. keyClient .. keyServer))
end

-- Returns the channel's keys, or nil if the other side sent a key that gives away the secret.
local function deriveKeys(sk, peerEph, transcript)
    local secret = crypto.x25519(sk, peerEph)
    if secret == string.rep("\0", 32) then return nil end
    local prk = crypto.hmac(transcript, secret)
    return {
        id = crypto.toHex(crypto.hmac(prk, "channel")):sub(1, 16),
        clientKey = crypto.hmac(prk, "client"),
        serverKey = crypto.hmac(prk, "server"),
    }
end

------------------------------------------------------------------------------
-- Serving
------------------------------------------------------------------------------

local channels = {} -- channel id -> { key, clientKey, serverKey, seq, expires, transfer, data }

-- Drop idle channels, and with them any file they hold in memory.
function share.sweep()
    local t = now()
    for id, channel in pairs(channels) do
        if channel.expires <= t then channels[id] = nil end
    end
end

local function dropOldestChannel()
    local count, oldest = 0, nil
    for id, channel in pairs(channels) do
        count = count + 1
        if not oldest or channel.expires < channels[oldest].expires then oldest = id end
    end
    if count >= MAX_CHANNELS then channels[oldest] = nil end
end

local function onOpen(msg, payload)
    if not crypto.isHex(payload.eph, 64) then return end
    local ephClient = crypto.fromHex(payload.eph)
    local seed, public = trust.identity()
    local sk, ephServer = crypto.keypair()
    local transcript = transcriptOf(ephClient, ephServer, crypto.fromHex(msg.peer.key), public)
    local channel = deriveKeys(sk, ephClient, transcript)
    if not channel then return end

    share.sweep()
    dropOldestChannel()
    channel.key, channel.seq, channel.transfer, channel.expires = msg.peer.key, 0, 0, now() + CHANNEL_IDLE
    channels[channel.id] = channel
    net.reply(msg, { eph = crypto.toHex(ephServer), sig = crypto.toHex(crypto.sign(seed, transcript, public)) })
end

local OPS = {}

function OPS.list()
    local lines = {}
    for _, file in ipairs(share.files()) do lines[#lines + 1] = file.name .. "\t" .. file.size end
    return table.concat(lines, "\n")
end

function OPS.get(channel, name)
    local path = loadFiles()[name]
    if not path or not fs.exists(path) or fs.isDir(path) then return nil, name .. " isn't shared any more." end
    local f = fs.open(path, "rb")
    if not f then return nil, "Couldn't read " .. name .. "." end
    channel.data = f.readAll() or ""
    f.close()
    channel.transfer = channel.transfer + 1
    return channel.transfer .. "\n" .. #channel.data
end

function OPS.chunk(channel, arg)
    local transfer, index = arg:match("^(%d+) (%d+)$")
    if not channel.data or tonumber(transfer) ~= channel.transfer then return nil, "The download has ended." end
    local start = tonumber(index) * share.CHUNK
    return channel.data:sub(start + 1, start + share.CHUNK)
end

function OPS.done(channel)
    channel.data = nil
    return ""
end

local function onCall(msg, payload)
    local channel = type(payload.cid) == "string" and channels[payload.cid]
    if not channel or channel.key ~= msg.peer.key then return net.reply(msg, { error = "expired" }) end
    local plain = crypto.open(channel.clientKey, payload.box)
    local seq, op, arg = (plain or ""):match("^(%d+)\n(%a+)\n(.*)$")
    seq = tonumber(seq)
    if not seq or seq <= channel.seq or not OPS[op] then return end

    channel.seq, channel.expires = seq, now() + CHANNEL_IDLE
    local result, err = OPS[op](channel, arg)
    local body = result and ("ok\n" .. result) or ("err\n" .. err)
    net.reply(msg, { box = crypto.seal(channel.serverKey, seq .. "\n" .. body) })
end

-- Answer a message from the port. The trusted list is read each time, so forgetting a computer
-- takes effect at once. Everyone gets a hello: it's how they see the fingerprint to compare.
function share.serve(msg)
    local payload = msg.payload
    if type(payload) ~= "table" then return end
    if payload.op == "hello" then return net.reply(msg, { name = trust.defaultName() }) end
    if not share.isTrusted(msg.peer.key) then return net.reply(msg, { error = "untrusted" }) end
    if payload.op == "open" then return onOpen(msg, payload) end
    if payload.op == "call" then return onCall(msg, payload) end
end

------------------------------------------------------------------------------
-- Finding and checking computers
------------------------------------------------------------------------------

local function displayName(name, id)
    return trust.validName(name) and name or ("computer-" .. id)
end

-- Computers in range, as { id, name }. None of this is proven; share.hello is what shows the key.
function share.find(timeout)
    local answers, err = net.probe(share.PORT, timeout)
    if not answers then return nil, err end
    local found, known = {}, {}
    for _, answer in ipairs(answers) do
        if not known[answer.from] then
            known[answer.from] = true
            local data = answer.data
            found[#found + 1] = { id = answer.from, name = displayName(type(data) == "table" and data.name, answer.from) }
        end
    end
    table.sort(found, function(a, b) return a.id < b.id end)
    return found
end

-- Have a computer prove which key it holds. Returns { id, name, key, fingerprint, certified }.
function share.hello(id)
    local reply, err = net.request(id, share.PORT, { op = "hello" }, { timeout = OPEN_TIMEOUT })
    if not reply then return nil, err end
    local peer = reply.peer
    return {
        id = id,
        key = peer.key,
        fingerprint = peer.fingerprint,
        name = peer.name or displayName(type(reply.payload) == "table" and reply.payload.name, id),
        certified = peer.verified,
    }
end

------------------------------------------------------------------------------
-- Connecting and downloading
------------------------------------------------------------------------------

local function connectChannel(channel)
    local sk, ephClient = crypto.keypair()
    local reply, err = net.request(channel.peer.id, share.PORT, { op = "open", eph = crypto.toHex(ephClient) },
        { timeout = OPEN_TIMEOUT })
    if not reply then return nil, err end
    if reply.peer.key ~= channel.peer.key then
        return nil, "This computer's fingerprint has changed. It may not be the computer you verified."
    end

    local answer = reply.payload
    if type(answer) ~= "table" then return nil, "The computer sent a bad answer." end
    if answer.error == "untrusted" then
        return nil, channel.peer.name .. " hasn't added this computer yet. Add this computer on it too."
    end
    if not crypto.isHex(answer.eph, 64) or not crypto.isHex(answer.sig, 128) then
        return nil, "The computer sent a bad answer."
    end

    local _, public = trust.identity()
    local ephServer, peerKey = crypto.fromHex(answer.eph), crypto.fromHex(channel.peer.key)
    local transcript = transcriptOf(ephClient, ephServer, public, peerKey)
    if not crypto.verify(peerKey, transcript, crypto.fromHex(answer.sig)) then
        return nil, "The computer couldn't prove it holds the verified key."
    end
    local derived = deriveKeys(sk, ephServer, transcript)
    if not derived then return nil, "The computer sent a bad answer." end

    channel.id, channel.clientKey, channel.serverKey, channel.seq = derived.id, derived.clientKey, derived.serverKey, 0
    return channel
end

-- Set up encryption with a trusted computer, from share.peers. Returns a channel for share.list
-- and share.download, or nil and a reason.
function share.connect(peer)
    return connectChannel({ peer = peer })
end

local function readAnswer(channel, seq, reply)
    if reply.peer.key ~= channel.peer.key then return nil, "This computer's fingerprint has changed." end
    local answer = reply.payload
    local plain = type(answer) == "table" and crypto.open(channel.serverKey, answer.box)
    if not plain then return nil, "The computer sent a bad answer." end
    local got, status = plain:match("^(%d+)\n(%a+)\n")
    if tonumber(got) ~= seq then return nil, "The computer sent a bad answer." end
    local body = plain:sub(#got + #status + 3)
    if status == "ok" then return body end
    return nil, body
end

-- Run an operation on the other computer. An idle channel is replaced once if it has expired.
local function call(channel, op, arg)
    local lastErr
    local renewed = false
    local tries = 0
    while tries < TRIES do
        tries = tries + 1
        channel.seq = channel.seq + 1
        local seq = channel.seq
        local box = crypto.seal(channel.clientKey, seq .. "\n" .. op .. "\n" .. (arg or ""))
        local reply, err = net.request(channel.peer.id, share.PORT, { op = "call", cid = channel.id, box = box },
            { timeout = CALL_TIMEOUT })
        if reply and type(reply.payload) == "table" and reply.payload.error and not renewed
                and reply.peer.key == channel.peer.key then
            renewed = true
            tries = tries - 1
            local ok, why = connectChannel(channel)
            if not ok then return nil, why end
        elseif reply then
            return readAnswer(channel, seq, reply)
        else
            lastErr = err
        end
    end
    return nil, lastErr
end

-- The files a connected computer shares, as a list of { name, size }.
function share.list(channel)
    local body, err = call(channel, "list")
    if not body then return nil, err end
    local out = {}
    for name, size in body:gmatch("([^\t\n]+)\t(%d+)") do
        if share.validName(name) then out[#out + 1] = { name = name, size = tonumber(size) } end
    end
    return out
end

-- A path in `dir` that nothing is using: name, then "name (1)" and so on.
local function freePath(dir, name)
    local path = fs.combine(dir, name)
    local stem, ext = name:match("^(.*)(%.[^.]*)$")
    stem, ext = stem or name, ext or ""
    local n = 0
    while fs.exists(path) do
        n = n + 1
        path = fs.combine(dir, stem .. " (" .. n .. ")" .. ext)
    end
    return path
end

-- Fetch a shared file into `dir`. It's held in memory until it's all here, so a failure leaves
-- nothing behind. onProgress(bytes, size) is called after each chunk. Returns the path it was
-- saved to, or nil and a reason.
function share.download(channel, name, dir, onProgress)
    if not share.validName(name) then return nil, "That file name isn't safe to use." end
    local body, err = call(channel, "get", name)
    if not body then return nil, err end
    local transfer, size = body:match("^(%d+)\n(%d+)$")
    size = tonumber(size)
    if not size then return nil, "The computer sent a bad answer." end

    fs.makeDir(dir)
    if size > fs.getFreeSpace(dir) then return nil, "There isn't enough free space for " .. name .. "." end

    local parts, got = {}, 0
    while got < size do
        local want = math.min(share.CHUNK, size - got)
        local chunk, why = call(channel, "chunk", transfer .. " " .. #parts)
        if not chunk then return nil, why end
        if #chunk ~= want then return nil, "The computer sent part of the file wrongly." end
        parts[#parts + 1] = chunk
        got = got + want
        if onProgress then onProgress(got, size) end
    end
    call(channel, "done")

    local path = freePath(dir, name)
    local f, openErr = fs.open(path, "wb")
    if not f then return nil, "Couldn't save the file: " .. tostring(openErr) end
    f.write(table.concat(parts))
    f.close()
    system.log("fileshare: downloaded " .. name .. " from computer " .. channel.peer.id)
    return path
end

return share
