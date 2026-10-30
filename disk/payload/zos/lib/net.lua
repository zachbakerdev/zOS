--[[ Encrypted, authenticated networking over modems.

  net.listen(port, { modem = "top", verified = true })
  net.close(port)
  net.receive(port, timeout)                                          -- next message, or nil and a reason
  net.send(id, port, payload, { verified = true, expect = "name" })   -- true, or nil and a reason
  net.request(id, port, payload, { timeout = 5, ... })                -- reply message, or nil and a reason
  net.reply(msg, payload)

A message that decrypts and authenticates goes into its port's inbox and queues a `net_message`
event, each carrying one table:

  { port, payload, from = id, id, side, peer = { id, key, fingerprint, verified, name, root } }

Nothing else does: packets that fail any check are dropped silently. `verified` means the peer
has a current certificate for its computer id from a root server you trust, and `peer.name` is
the name on it. `expect` also requires that name. See trust.lua for what happens without a
certificate.

The event reaches every program on the computer and is gone if nobody is waiting at that moment,
for example during a net.reply. net.receive keeps its place, so servers should use that.

The port is the modem channel. Each computer also listens on a home channel, which carries
handshake replies, acks and replies to requests. Only an answer to a request this computer is
waiting on is accepted there. Payloads can be anything but functions.

Blocking calls ignore Ctrl+T, because terminate also reaches background services, which mustn't
die from a keypress. Each has a time limit, except net.receive, which returns nil on terminate.

Handshake (a -> b). Each side signs both ephemeral keys with its identity, so an attacker needs
the identity key to impersonate either side, and recording traffic doesn't help them later.

  hello   a's ephemeral key
  resp    b's ephemeral key, then encrypted: b's identity, certificates and signature
  auth    encrypted: a's identity, certificates and signature
  done    b has checked a

Signing and key agreement take long enough that events would be lost while they ran (crypto
yields with an event filter), so two services split the work. The receiver never does crypto
and only queues packets. The worker does everything else, one item at a time, which also means
nothing here needs locking. net.send hands the worker a job and waits for its result. ]]

local crypto = require("crypto")
local services = require("services")
local system = require("system")
local trust = require("trust")

local net = {}

net.ROOT_PORT = 4200 -- root servers listen here
net.EVENT = "net_message"
net.PROBE_EVENT = "net_probe"

local VERSION = 1
local PROTOCOL = "zos-net-1"
local RECEIVER, WORKER, RENEWER = "zos:net-receiver", "zos:net-worker", "zos:net-renewer"
local WAKE, RESULT, BEACON, REPLY = "zos_net_wake", "zos_net_result", "zos_net_beacon", "zos_net_reply"

local HOME_BASE, HOME_RANGE = 30000, 30000
local MAX_PORT = 65533 -- rednet uses the last two channels
local MAX_PAYLOAD = 32768 -- bytes, once encoded
local MAX_HANDSHAKE_BOX = 8192 -- hex characters
local MAX_DATA_QUEUE = 64
local MAX_INBOX = 32 -- messages kept per port; the oldest go first
local MAX_HANDSHAKE_QUEUE = 8
local MAX_HALF_OPEN = 4 -- handshakes other computers have started that aren't finished
local MAX_SESSIONS = 64
local MAX_PROBES = 8 -- answered per tick
local MAX_BEACONS = 16 -- looked at per probe
local MAX_DEPTH = 16

local TICK = 1
local HANDSHAKE_TIMEOUT = 15000 -- ms, per step; signature checks are slow
local ACK_TIMEOUT = 6000 -- ms; long enough for the peer to finish a handshake with someone else
local SESSION_LIFETIME = 3600000 -- ms; a new handshake means new keys
local SEEN_LIFETIME = 60000 -- ms
local RENEW_DELAY = 30 -- seconds after boot, since a computer may not stay up for long
local RENEW_INTERVAL = 3600 -- seconds
local RENEW_BEFORE = 7 * 24 * 3600 * 1000 -- ms before a certificate expires

local ID = os.getComputerID()

local listeners = {} -- port -> { modem, verified, inbox }
local sessions = {}  -- session id -> session
local latest = {}    -- computer id -> session id to send with
local initiated = {} -- computer id -> handshake this computer started
local answered = {}  -- handshake id -> handshake another computer started
local answeredCount = 0
local jobs = {}      -- job id -> job waiting on a handshake or an ack
local awaiting = {}  -- message id -> { from, reply } for each net.request in progress
local seen = {}      -- peer key .. message id -> ms when it can be forgotten
local jobQueue, dataQueue, handshakeQueue = {}, {}, {}
local probesThisTick = 0
local jobCounter = 0

local function homeChannel(id)
    return HOME_BASE + id % HOME_RANGE
end

local function now()
    return os.epoch("utc")
end

local function isId(n)
    return type(n) == "number" and n >= 0 and n == math.floor(n)
end

local function isPort(n)
    return isId(n) and n <= MAX_PORT
end

------------------------------------------------------------------------------
-- Payload encoding. Packets come from anyone, so this reads data and never runs it,
-- which textutils.unserialize would.
------------------------------------------------------------------------------

local function encodeValue(v, out, depth)
    local kind = type(v)
    if depth > MAX_DEPTH then error("payload is nested too deeply", 0) end
    if kind == "nil" then
        out[#out + 1] = "n"
    elseif kind == "boolean" then
        out[#out + 1] = v and "T" or "F"
    elseif kind == "number" then
        if v ~= v or v == math.huge or v == -math.huge then error("payload has a non-finite number", 0) end
        out[#out + 1] = "d" .. string.format("%.17g", v) .. ";"
    elseif kind == "string" then
        out[#out + 1] = "s" .. #v .. ":" .. v
    elseif kind == "table" then
        out[#out + 1] = "{"
        for key, value in pairs(v) do
            encodeValue(key, out, depth + 1)
            encodeValue(value, out, depth + 1)
        end
        out[#out + 1] = "}"
    else
        error("can't send a " .. kind, 0)
    end
end

local function decodeValue(s, pos, depth)
    if depth > MAX_DEPTH then error("too deep", 0) end
    local tag = s:sub(pos, pos)
    if tag == "n" then
        return nil, pos + 1
    elseif tag == "T" or tag == "F" then
        return tag == "T", pos + 1
    elseif tag == "d" then
        local stop = assert(s:find(";", pos, true))
        return assert(tonumber(s:sub(pos + 1, stop - 1))), stop + 1
    elseif tag == "s" then
        local stop = assert(s:find(":", pos, true))
        local len = assert(tonumber(s:sub(pos + 1, stop - 1)))
        assert(len >= 0 and stop + len <= #s)
        return s:sub(stop + 1, stop + len), stop + len + 1
    elseif tag == "{" then
        local t = {}
        pos = pos + 1
        while s:sub(pos, pos) ~= "}" do
            local key, value
            key, pos = decodeValue(s, pos, depth + 1)
            value, pos = decodeValue(s, pos, depth + 1)
            t[assert(key)] = value
        end
        return t, pos + 1
    end
    error("bad tag", 0)
end

local function encode(v)
    local out = {}
    encodeValue(v, out, 1)
    return table.concat(out)
end

-- Returns ok, value.
local function decode(s)
    local ok, value, pos = pcall(decodeValue, s, 1, 1)
    if ok and pos == #s + 1 then return true, value end
    return false
end

------------------------------------------------------------------------------
-- Modems
------------------------------------------------------------------------------

-- Names of the attached modems.
function net.modems()
    local names = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then names[#names + 1] = name end
    end
    return names
end

local function openPort(port, modem)
    for _, name in ipairs(modem and { modem } or net.modems()) do
        if peripheral.getType(name) == "modem" then peripheral.call(name, "open", port) end
    end
end

local function openAll()
    openPort(homeChannel(ID))
    for port, listener in pairs(listeners) do openPort(port, listener.modem) end
end

local function transmit(side, channel, packet)
    packet.zn, packet.src = VERSION, ID
    for _, name in ipairs(side and { side } or net.modems()) do
        if peripheral.getType(name) == "modem" then
            peripheral.call(name, "transmit", channel, homeChannel(ID), packet)
        end
    end
end

------------------------------------------------------------------------------
-- Sessions
------------------------------------------------------------------------------

local function hmacHex(key, msg)
    return crypto.toHex(crypto.hmac(key, msg))
end

local function deriveKeys(secret, transcript, initiator)
    local prk = crypto.hmac(transcript, secret)
    local function key(label) return crypto.hmac(prk, label) end
    local mine, theirs = initiator and "a" or "b", initiator and "b" or "a"
    return {
        id = hmacHex(prk, "session"):sub(1, 16),
        myHandshake = key(mine .. " handshake"),
        peerHandshake = key(theirs .. " handshake"),
        sendEnc = key(mine .. " enc"),
        sendMac = key(mine .. " mac"),
        recvEnc = key(theirs .. " enc"),
        recvMac = key(theirs .. " mac"),
    }
end

local function addSession(derived, peer, certs, side)
    local count, oldest = 0, nil
    for id, session in pairs(sessions) do
        count = count + 1
        if not oldest or session.expires < sessions[oldest].expires then oldest = id end
    end
    if count >= MAX_SESSIONS then sessions[oldest] = nil end

    derived.peer, derived.certs, derived.side, derived.sendSeq, derived.recvSeq = peer, certs, side, 0, 0
    derived.expires = now() + SESSION_LIFETIME
    sessions[derived.id] = derived
    latest[peer.id] = derived.id
    return derived
end

local function sessionFor(id)
    local session = sessions[latest[id]]
    if session and session.expires > now() then return session end
end

local function dropSession(id)
    if latest[id] then sessions[latest[id]] = nil end
    latest[id] = nil
end

-- The peer as things stand now, not as they were at the handshake.
local function currentPeer(session)
    session.peer = trust.describe(session.peer.id, session.peer.key, session.certs)
    return session.peer
end

local function nonce(seq)
    local bytes = {}
    local n = seq
    for i = 1, 12 do
        bytes[i] = string.char(n % 256)
        n = math.floor(n / 256)
    end
    return table.concat(bytes)
end

-- Everything an attacker might want to change is covered by the tag, not only the contents.
-- The last separator keeps the digits of seq apart from the ciphertext that follows.
local function dataHeader(sid, src, dst, port, seq, kind)
    return table.concat({ kind, sid, src, dst, port, string.format("%.0f", seq) }, "|") .. "|"
end

------------------------------------------------------------------------------
-- Jobs: messages this computer is sending
------------------------------------------------------------------------------

local function finish(job, ok, err)
    jobs[job.id] = nil
    os.queueEvent(RESULT, job.id, ok, err)
end

local function refusal(peer, job)
    if (job.verified or job.expect) and not peer.verified then
        return "computer " .. peer.id .. " has no certificate from a trusted root"
    end
    if job.expect and peer.name ~= job.expect then
        return "computer " .. peer.id .. " is '" .. tostring(peer.name) .. "', not '" .. job.expect .. "'"
    end
end

local startHandshake

local function transmitJob(job, session)
    local why = refusal(currentPeer(session), job)
    if why then
        if job.renegotiated then return finish(job, false, why) end
        -- The peer may have got a certificate since this session began, so ask it again.
        -- Other messages on this session may still be waiting for acks, so it's kept.
        job.renegotiated = true
        latest[job.to] = nil
        return startHandshake(job)
    end

    session.sendSeq = session.sendSeq + 1
    local seq = session.sendSeq
    local header = dataHeader(session.id, ID, job.to, job.port, seq, "data")
    local ct = crypto.chacha20(session.sendEnc, nonce(seq), job.body)
    job.waitingFor = session.id .. seq
    job.deadline = now() + ACK_TIMEOUT
    jobs[job.id] = job
    transmit(session.side, job.port, {
        t = "data", dst = job.to, sid = session.id, port = job.port, seq = seq,
        ct = crypto.toHex(ct), tag = hmacHex(session.sendMac, header .. ct),
    })
end

function startHandshake(job)
    local shake = initiated[job.to]
    if shake then
        shake.jobs[#shake.jobs + 1] = job
        return
    end
    local sk, pk = crypto.keypair()
    initiated[job.to] = { sk = sk, pk = pk, jobs = { job }, deadline = now() + HANDSHAKE_TIMEOUT }
    transmit(nil, job.port, { t = "hello", dst = job.to, eph = crypto.toHex(pk) })
end

local function runJob(job)
    local session = sessionFor(job.to)
    if session then return transmitJob(job, session) end
    startHandshake(job)
end

local function failHandshake(id, why)
    local shake = initiated[id]
    initiated[id] = nil
    for _, job in ipairs(shake.jobs) do finish(job, false, why) end
end

------------------------------------------------------------------------------
-- Handshake
------------------------------------------------------------------------------

local function transcriptOf(ephA, ephB)
    return crypto.fromHex(crypto.sha256(PROTOCOL .. ephA .. ephB))
end

local function sharedSecret(sk, peerEph)
    local secret = crypto.x25519(sk, peerEph)
    if secret ~= string.rep("\0", 32) then return secret end
end

local function credentials(context)
    local seed, public = trust.identity()
    return encode({
        key = crypto.toHex(public),
        certs = trust.certs(),
        sig = crypto.toHex(crypto.sign(seed, context(public), public)),
    })
end

-- Open and check the peer's sealed credentials. Returns its public key and certificates.
local function readCredentials(key, box, context)
    if type(box) ~= "table" or type(box.ct) ~= "string" or #box.ct > MAX_HANDSHAKE_BOX then return nil end
    local plain = crypto.open(key, box)
    if not plain then return nil end
    local ok, creds = decode(plain)
    if not ok or type(creds) ~= "table" or not crypto.isHex(creds.key, 64) or not crypto.isHex(creds.sig, 128) then
        return nil
    end
    local public = crypto.fromHex(creds.key)
    if not crypto.verify(public, context(public), crypto.fromHex(creds.sig)) then return nil end
    return public, creds.certs
end

-- b signs without knowing who a is, but its key is sealed under the shared secret, which only a
-- could have worked out. a's signature names b, so a can't be presented to someone else.
local function responderContext(transcript)
    return function(publicB) return PROTOCOL .. "|resp|" .. transcript .. publicB end
end

local function initiatorContext(transcript, publicB)
    return function(publicA) return PROTOCOL .. "|auth|" .. transcript .. publicB .. publicA end
end

local function onHello(p)
    if answeredCount >= MAX_HALF_OPEN or not crypto.isHex(p.eph, 64) then return end
    local ephA = crypto.fromHex(p.eph)
    local sk, ephB = crypto.keypair()
    local secret = sharedSecret(sk, ephA)
    if not secret then return end

    local transcript = transcriptOf(ephA, ephB)
    local derived = deriveKeys(secret, transcript, false)
    local shakeId = derived.id
    local _, public = trust.identity()

    answered[shakeId] = {
        src = p.src, side = p.side, transcript = transcript, derived = derived, public = public,
        deadline = now() + HANDSHAKE_TIMEOUT,
    }
    answeredCount = answeredCount + 1

    transmit(p.side, homeChannel(p.src), {
        t = "resp", dst = p.src, eph = crypto.toHex(ephB),
        box = crypto.seal(derived.myHandshake, credentials(responderContext(transcript))),
    })
end

local function onResp(p)
    local shake = initiated[p.src]
    if not shake or shake.derived or not crypto.isHex(p.eph, 64) then return end
    local ephB = crypto.fromHex(p.eph)
    local secret = sharedSecret(shake.sk, ephB)
    if not secret then return end

    local transcript = transcriptOf(shake.pk, ephB)
    local derived = deriveKeys(secret, transcript, true)
    local publicB, certs = readCredentials(derived.peerHandshake, p.box, responderContext(transcript))
    if not publicB then return end -- not from b; keep waiting for the real answer

    -- hello is broadcast, so anyone can answer in this computer's name with a key of their own.
    -- Giving up here would let them stop every connection, so wait for the real answer.
    local peer, why = trust.evaluate(p.src, publicB, certs)
    if not peer then
        if not shake.refused then system.log("net: refused a connection: " .. why) end
        shake.refused = why
        return
    end

    shake.derived, shake.peer, shake.certs, shake.side = derived, peer, certs, p.side
    shake.deadline = now() + HANDSHAKE_TIMEOUT
    transmit(p.side, homeChannel(p.src), {
        t = "auth", dst = p.src, hs = derived.id,
        box = crypto.seal(derived.myHandshake, credentials(initiatorContext(transcript, publicB))),
    })
end

local function onAuth(p)
    local shake = type(p.hs) == "string" and answered[p.hs]
    if not shake or shake.src ~= p.src then return end
    local publicA, certs = readCredentials(shake.derived.peerHandshake, p.box,
        initiatorContext(shake.transcript, shake.public))
    if not publicA then return end

    answered[p.hs] = nil
    answeredCount = answeredCount - 1

    local peer, why = trust.evaluate(p.src, publicA, certs)
    if not peer then return system.log("net: refused a connection: " .. why) end

    addSession(shake.derived, peer, certs, shake.side)
    transmit(shake.side, homeChannel(p.src), {
        t = "done", dst = p.src, hs = p.hs, tag = hmacHex(shake.derived.myHandshake, "done"),
    })
end

local function onDone(p)
    local shake = initiated[p.src]
    if not shake or not shake.derived or p.hs ~= shake.derived.id
            or p.tag ~= hmacHex(shake.derived.peerHandshake, "done") then
        return
    end
    initiated[p.src] = nil
    local session = addSession(shake.derived, shake.peer, shake.certs, shake.side)
    for _, job in ipairs(shake.jobs) do
        job.renegotiated = true -- this session is as new as it gets
        transmitJob(job, session)
    end
end

------------------------------------------------------------------------------
-- Data
------------------------------------------------------------------------------

local function ack(session, seq, status)
    local body = dataHeader(session.id, ID, session.peer.id, 0, seq, "ack") .. "|" .. status
    transmit(session.side, homeChannel(session.peer.id), {
        t = "ack", dst = session.peer.id, sid = session.id, seq = seq, status = status,
        tag = hmacHex(session.sendMac, body),
    })
end

local function onData(p)
    local session = sessions[p.sid]
    if not session or session.peer.id ~= p.src or not isId(p.seq) or p.seq <= session.recvSeq
            or not isPort(p.port) or not crypto.isHex(p.ct) or type(p.tag) ~= "string" or #p.ct > 2 * MAX_PAYLOAD then
        return
    end
    local ct = crypto.fromHex(p.ct)
    local header = dataHeader(p.sid, p.src, ID, p.port, p.seq, "data")
    if hmacHex(session.recvMac, header .. ct) ~= p.tag then return end

    -- Authentic from here on, so this number can be trusted and replays of it refused.
    session.recvSeq = p.seq
    session.side = p.side

    local peer = currentPeer(session)
    local isHome = p.port == homeChannel(ID)
    local listener = listeners[p.port]
    if not isHome then
        if not listener or (listener.modem and listener.modem ~= p.side) then return ack(session, p.seq, "closed") end
        if listener.verified and not peer.verified then return ack(session, p.seq, "denied") end
    end

    local ok, body = decode(crypto.chacha20(session.recvEnc, nonce(p.seq), ct))
    if not ok or type(body) ~= "table" or type(body.id) ~= "string" then return end

    -- The home channel can't be closed, so nothing but an expected reply gets through it.
    local waiting = isHome and body.re ~= nil and awaiting[body.re] or nil
    if isHome and not (waiting and waiting.from == p.src) then return ack(session, p.seq, "closed") end

    ack(session, p.seq, "ok")

    -- A retry after a lost ack arrives on a new session, so sequence numbers don't catch it.
    local mark = session.peer.key .. body.id
    if seen[mark] then return end
    seen[mark] = now() + SEEN_LIFETIME

    local msg = { port = p.port, payload = body.p, from = p.src, id = body.id, side = p.side, peer = peer }
    if waiting then
        waiting.reply = msg
        os.queueEvent(REPLY)
        return
    end
    listener.inbox[#listener.inbox + 1] = msg
    if #listener.inbox > MAX_INBOX then table.remove(listener.inbox, 1) end
    os.queueEvent(net.EVENT, msg)
end

local function onAck(p)
    local session = sessions[p.sid]
    if not session or session.peer.id ~= p.src or not isId(p.seq) or type(p.status) ~= "string" then return end
    local body = dataHeader(p.sid, p.src, ID, 0, p.seq, "ack") .. "|" .. p.status
    if p.tag ~= hmacHex(session.recvMac, body) then return end

    local waitingFor = p.sid .. p.seq
    for _, job in pairs(jobs) do
        if job.waitingFor == waitingFor then
            if p.status == "ok" then
                finish(job, true)
            elseif p.status == "denied" then
                finish(job, false, "port " .. job.port .. " only accepts verified computers")
            else
                finish(job, false, "port " .. job.port .. " is closed on computer " .. job.to)
            end
            return
        end
    end
end

------------------------------------------------------------------------------
-- Services
------------------------------------------------------------------------------

local function expire()
    local t = now()
    for id, shake in pairs(initiated) do
        if shake.deadline <= t then failHandshake(id, shake.refused or ("no answer from computer " .. id)) end
    end
    for id, shake in pairs(answered) do
        if shake.deadline <= t then
            answered[id] = nil
            answeredCount = answeredCount - 1
        end
    end
    for id, session in pairs(sessions) do
        if session.expires <= t then sessions[id] = nil end
    end
    for mark, expires in pairs(seen) do
        if expires <= t then seen[mark] = nil end
    end
    -- No ack: the peer may have rebooted and lost the session, so try once with a new one.
    for _, job in pairs(jobs) do
        if job.deadline and job.deadline <= t then
            if job.retried then
                finish(job, false, "no answer from computer " .. job.to)
            else
                job.retried, job.deadline, job.waitingFor = true, nil, nil
                dropSession(job.to)
                runJob(job)
            end
        end
    end
end

local HANDLERS = { hello = onHello, resp = onResp, auth = onAuth, done = onDone, data = onData, ack = onAck }

local function wake()
    os.queueEvent(WAKE)
end

local function push(queue, item, limit)
    if #queue < limit then
        queue[#queue + 1] = item
        wake()
    end
end

local function onModemMessage(side, channel, reply, p)
    if type(p) ~= "table" or p.zn ~= VERSION or not isId(p.src) then return end

    if p.t == "probe" then
        if listeners[channel] and probesThisTick < MAX_PROBES and type(p.nonce) == "string" then
            probesThisTick = probesThisTick + 1
            os.queueEvent(net.PROBE_EVENT, { port = channel, nonce = p.nonce, side = side, reply = reply })
        end
    elseif p.t == "beacon" then
        os.queueEvent(BEACON, p.nonce, p.data, p.src)
    elseif p.dst == ID then
        p.side = side
        if p.t == "data" or p.t == "ack" then
            push(dataQueue, p, MAX_DATA_QUEUE)
        elseif p.t == "resp" or p.t == "auth" or p.t == "done" then
            push(handshakeQueue, p, MAX_HANDSHAKE_QUEUE)
        elseif p.t == "hello" then
            local listener = listeners[channel]
            if channel == homeChannel(ID) or (listener and (not listener.modem or listener.modem == side)) then
                push(handshakeQueue, p, MAX_HANDSHAKE_QUEUE)
            end
        end
    end
end

local function receiver()
    local timer = os.startTimer(TICK)
    while true do
        local e, a, b, c, d = os.pullEventRaw()
        if e == "modem_message" then
            onModemMessage(a, b, c, d)
        elseif e == "timer" and a == timer then
            timer = os.startTimer(TICK)
            probesThisTick = 0
            wake()
        elseif e == "peripheral" and peripheral.getType(a) == "modem" then
            pcall(openAll)
        end
    end
end

local function nextItem()
    if jobQueue[1] then return table.remove(jobQueue, 1), runJob end
    local packet = table.remove(dataQueue, 1) or table.remove(handshakeQueue, 1)
    if packet then return packet, HANDLERS[packet.t] end
end

local function worker()
    while true do
        expire()
        local item, handler = nextItem()
        if item then
            local ok, err = pcall(handler, item)
            if not ok then system.log("net: " .. tostring(err)) end
        else
            os.pullEventRaw(WAKE)
        end
    end
end

-- Certificates are short-lived, so swap them for new ones before they run out.
local function renewer()
    local wait = RENEW_DELAY
    while true do
        local timer = os.startTimer(wait)
        repeat
            local _, id = os.pullEventRaw("timer")
        until id == timer
        wait = RENEW_INTERVAL
        for _, cert in ipairs(trust.certs()) do
            local root = trust.root(cert.root)
            if root and cert.expires - now() < RENEW_BEFORE then
                local status, message = net.requestCertificate({ key = cert.root, host = root.host }, cert.name)
                if status ~= "issued" then
                    system.log("net: couldn't renew the certificate from " .. root.name .. ": " .. tostring(message))
                end
            end
        end
    end
end

-- Started by boot.lua.
function net.start()
    trust.identity()
    openAll()
    services.start(RECEIVER, receiver)
    services.start(WORKER, worker)
    services.start(RENEWER, renewer)
end

function net.isRunning()
    return services.isRunning(WORKER)
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

-- Listen on a port. opts.modem limits it to one modem, and opts.verified refuses any computer
-- without a certificate from a trusted root. A modem attached later is picked up by itself.
function net.listen(port, opts)
    if not isPort(port) then return nil, "ports are whole numbers from 0 to " .. MAX_PORT end
    if port == homeChannel(ID) then return nil, "port " .. port .. " is reserved for this computer" end
    opts = opts or {}
    if opts.modem and peripheral.getType(opts.modem) ~= "modem" then
        return nil, "there's no modem called " .. tostring(opts.modem)
    end
    local ok, err = pcall(openPort, port, opts.modem)
    if not ok then return nil, err end -- modems can only have so many channels open
    local inbox = listeners[port] and listeners[port].inbox or {}
    listeners[port] = { modem = opts.modem, verified = opts.verified == true, inbox = inbox }
    return true
end

-- The next message on a listening port. Messages wait here, so none are missed while the caller
-- is busy. Returns nil and a reason if `timeout` seconds pass or on terminate.
function net.receive(port, timeout)
    local listener = listeners[port]
    if not listener then return nil, "not listening on port " .. tostring(port) end
    local timer = timeout and os.startTimer(timeout)
    while true do
        if listeners[port] ~= listener then return nil, "port " .. port .. " was closed" end
        local msg = table.remove(listener.inbox, 1)
        if msg then return msg end
        local e, a = os.pullEventRaw()
        if e == "terminate" then
            return nil, "terminated"
        elseif e == "timer" and a == timer then
            return nil, "timed out"
        end
    end
end

function net.close(port)
    local listener = listeners[port]
    if not listener then return end
    listeners[port] = nil
    if port == homeChannel(ID) then return end
    for _, name in ipairs(listener.modem and { listener.modem } or net.modems()) do
        if peripheral.getType(name) == "modem" then peripheral.call(name, "close", port) end
    end
end

local function newJob(to, port, payload, opts)
    if not isId(to) then return nil, "computer ids are whole numbers" end
    if to == ID then return nil, "modems can't send to their own computer" end
    if not isPort(port) then return nil, "ports are whole numbers from 0 to " .. MAX_PORT end
    if not net.isRunning() then return nil, "networking isn't running" end
    if #net.modems() == 0 then return nil, "no modem attached" end
    opts = opts or {}

    jobCounter = jobCounter + 1
    local msgId = crypto.toHex(crypto.randomBytes(8))
    local encoded, body = pcall(encode, { id = msgId, re = opts.re, p = payload })
    if not encoded then return nil, body end
    if #body > MAX_PAYLOAD then return nil, "payload is too big (over " .. MAX_PAYLOAD .. " bytes)" end

    return {
        id = jobCounter, msgId = msgId, to = to, port = port, body = body,
        verified = opts.verified == true, expect = opts.expect,
    }
end

-- Hand a job to the worker and wait for it.
local function runAndWait(job)
    jobQueue[#jobQueue + 1] = job
    wake()
    while true do
        local e, a, b, c = os.pullEventRaw(RESULT)
        if e == RESULT and a == job.id then return b, c end
    end
end

-- Send to a port on another computer, making a session first if there isn't one. Returns true
-- once the other computer has decrypted it. If an ack is lost the message is sent again, and
-- the other computer ignores the repeat.
function net.send(to, port, payload, opts)
    local job, err = newJob(to, port, payload, opts)
    if not job then return nil, err end
    local ok, why = runAndWait(job)
    if ok then return true end
    return nil, why
end

-- Send a message and wait for net.reply. Returns the reply's message table.
function net.request(to, port, payload, opts)
    opts = opts or {}
    local job, err = newJob(to, port, payload, opts)
    if not job then return nil, err end
    local waiting = { from = to }
    awaiting[job.msgId] = waiting
    local ok, why = runAndWait(job)
    if ok and not waiting.reply then
        local timer = os.startTimer(opts.timeout or 5)
        while not waiting.reply do
            local e, a = os.pullEventRaw()
            if e == "timer" and a == timer then break end
        end
    end
    awaiting[job.msgId] = nil
    if not ok then return nil, why end
    if waiting.reply then return waiting.reply end
    return nil, "computer " .. to .. " didn't reply"
end

-- Answer a message that came from net.request. Fails if the sender isn't waiting for one.
function net.reply(msg, payload, opts)
    opts = opts or {}
    opts.re = msg.id
    return net.send(msg.from, homeChannel(msg.from), payload, opts)
end

-- Broadcast on a port and collect the answers to net.PROBE_EVENT. This isn't encrypted, because
-- it reaches computers nothing is known about yet, so don't believe what comes back without
-- checking it. Returns a list of { data, from }.
function net.probe(port, timeout)
    if #net.modems() == 0 then return nil, "no modem attached" end
    local id = crypto.toHex(crypto.randomBytes(8))
    transmit(nil, port, { t = "probe", nonce = id })
    local found = {}
    local timer = os.startTimer(timeout or 3)
    while true do
        local e, a, b, c = os.pullEventRaw()
        if e == "timer" and a == timer then
            return found
        elseif e == BEACON and a == id and #found < MAX_BEACONS then
            found[#found + 1] = { data = b, from = c }
        end
    end
end

-- Answer a net.PROBE_EVENT.
function net.answerProbe(probe, data)
    transmit(probe.side, probe.reply, { t = "beacon", nonce = probe.nonce, data = data })
end

------------------------------------------------------------------------------
-- Root servers
------------------------------------------------------------------------------

-- Every root server in range, as { name, key, host, fingerprint }. An advert with a bad signature
-- is left out. Being listed proves only that the server holds the key it shows, so a person has
-- to compare the fingerprint before it's trusted.
function net.findRoots(timeout)
    local answers, err = net.probe(net.ROOT_PORT, timeout)
    if not answers then return nil, err end
    local found, known = {}, {}
    for _, answer in ipairs(answers) do
        local advert = answer.data
        if type(advert) == "table" and type(advert.key) == "string" and not known[advert.key]
                and trust.checkAdvert(advert) then
            known[advert.key] = true
            found[#found + 1] = {
                name = advert.name,
                key = advert.key,
                host = advert.host,
                fingerprint = trust.fingerprint(crypto.fromHex(advert.key)),
            }
        end
    end
    table.sort(found, function(a, b) return a.name:lower() < b.name:lower() end)
    return found
end

-- Ask a root server to sign this computer's key under `name`. Safe to repeat: the root answers
-- with where the request has got to. Returns "issued", "pending" or "denied", or nil and a reason.
-- The handshake proves that this computer holds the key, and the certificate that comes back is
-- checked against the root's key, so a root server's computer doesn't have to be trusted itself.
function net.requestCertificate(root, name)
    local reply, err = net.request(root.host, net.ROOT_PORT, { op = "certificate", name = name }, { timeout = 10 })
    if not reply then return nil, err end
    local answer = reply.payload
    if type(answer) ~= "table" then return nil, "the root server sent a bad answer" end
    if answer.status == "issued" then
        local _, public = trust.identity()
        local cert = answer.cert
        if not trust.checkCert(cert, crypto.toHex(public)) or cert.root ~= root.key or cert.name ~= name
                or cert.id ~= ID then
            return nil, "the root server sent a bad certificate"
        end
        trust.installCert(cert)
        -- Peers only see certificates at a handshake, so start new sessions to show this one.
        latest = {}
        return "issued"
    elseif answer.status == "pending" or answer.status == "denied" then
        return answer.status
    end
    return nil, tostring(answer.message or "the root server refused")
end

return net
