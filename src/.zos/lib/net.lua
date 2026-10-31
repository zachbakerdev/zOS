-- Encrypted, authenticated messages between computers. See specs/libs/NET.md.
--
-- A receiver queues packets and does no crypto, so none are lost during slow work. One worker then
-- handles packets and outgoing jobs. It never waits for the other computer: each step runs to its
-- end and leaves its state in a table, so two computers that write to each other at the same
-- moment can't hold each other up.

local crypto = require("crypto")
local keys = require("keys")
local services = require("services")
local trust = require("trust")
local util = require("util")

local net = {
    EVENT = "net_message",
    PROBE_EVENT = "net_probe",
    ROOT_PORT = 4200,
    MAX_PAYLOAD = 32768,
}

local VERSION = 1
local PROTOCOL = "zos-net-1"

local MAX_SESSIONS = 64
local SESSION_LIFETIME = 3600000
local MAX_HALF_OPEN = 4
local HANDSHAKE_TIMEOUT = 15000
local HELLO_RETRY = 5000
local ACK_TIMEOUT = 6000
local MAX_DATA_QUEUE = 64
local MAX_HANDSHAKE_QUEUE = 8
local MAX_PROBES_PER_TICK = 8
local MAX_PROBE_ANSWERS = 16
local INBOX_SIZE = 32
local MESSAGE_MEMORY = 60000
local MAX_DEPTH = 16
local MAX_PORT = 65533 -- rednet uses the last two channels
local RENEW_BEFORE = 7 * 24 * 3600 * 1000
local RENEW_DELAY, RENEW_EVERY = 30, 3600

local WAKE = "zos:net_work"
local DONE = "zos:net_done"

local toHex, fromHex, isHex = crypto.toHex, crypto.fromHex, crypto.isHex

local myId = os.getComputerID()
local running = false

local function now() return os.epoch("utc") end
local function homeChannel(id) return 30000 + id % 30000 end
local function validPort(port) return type(port) == "number" and port >= 0 and port <= MAX_PORT and port % 1 == 0 end

-- Payload encoding: read only as data, because textutils.unserialize runs code ------------------

local function encodeInto(value, out, depth)
    local kind = type(value)
    if kind == "string" then
        out[#out + 1] = "s" .. #value .. ":" .. value
    elseif kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then error("bad number", 0) end
        out[#out + 1] = "n" .. ("%.17g"):format(value) .. ";"
    elseif kind == "boolean" then
        out[#out + 1] = value and "t" or "f"
    elseif kind == "nil" then
        out[#out + 1] = "z"
    elseif kind == "table" then
        if depth >= MAX_DEPTH then error("too deep", 0) end
        out[#out + 1] = "{"
        for k, v in pairs(value) do
            encodeInto(k, out, depth + 1)
            encodeInto(v, out, depth + 1)
        end
        out[#out + 1] = "}"
    else
        error("can't send a " .. kind, 0)
    end
end

local function encode(value)
    local out = {}
    encodeInto(value, out, 0)
    return table.concat(out)
end

local function decodeAt(s, at, depth)
    local tag = s:sub(at, at)
    if tag == "s" then
        local digits = s:match("^%d+", at + 1)
        if not digits or #digits > 6 or s:sub(at + 1 + #digits, at + 1 + #digits) ~= ":" then error("bad", 0) end
        local start, len = at + 2 + #digits, tonumber(digits)
        if start + len - 1 > #s then error("bad", 0) end
        return s:sub(start, start + len - 1), start + len
    elseif tag == "n" then
        local text = s:match("^[%d%.eE%+%-]+", at + 1)
        local value = text and tonumber(text)
        if not value or s:sub(at + 1 + #text, at + 1 + #text) ~= ";" then error("bad", 0) end
        return value, at + 2 + #text
    elseif tag == "t" then
        return true, at + 1
    elseif tag == "f" then
        return false, at + 1
    elseif tag == "z" then
        return nil, at + 1
    elseif tag == "{" then
        if depth >= MAX_DEPTH then error("bad", 0) end
        local t = {}
        at = at + 1
        while s:sub(at, at) ~= "}" do
            local key, value
            key, at = decodeAt(s, at, depth + 1)
            value, at = decodeAt(s, at, depth + 1)
            if key == nil then error("bad", 0) end
            t[key] = value
        end
        return t, at + 1
    end
    error("bad", 0)
end

-- The value in s, or false if it's damaged. Packets come from anyone, so nothing here may raise
-- an error that gets out, and the same goes for a value of nil.
local function decode(s)
    local ok, value, finish = pcall(decodeAt, s, 1, 0)
    if ok and finish == #s + 1 then return true, value end
    return false
end

-- Modems ---------------------------------------------------------------------------------------

local ports = {}  -- port -> { inbox, modem, verified }

function net.modems()
    local out = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then out[#out + 1] = name end
    end
    return out
end

local function openOn(channel, modem)
    for _, name in ipairs(net.modems()) do
        if modem == nil or modem == name then peripheral.call(name, "open", channel) end
    end
end

local function openAll()
    openOn(homeChannel(myId))
    for port, info in pairs(ports) do openOn(port, info.modem) end
end

local function transmit(channel, packet, reply)
    packet.zn, packet.src = VERSION, myId
    for _, name in ipairs(net.modems()) do
        peripheral.call(name, "transmit", channel, reply or homeChannel(myId), packet)
    end
end

-- Queues ---------------------------------------------------------------------------------------

local dataQueue, handshakeQueue, jobs = {}, {}, {}
local probes = {}         -- nonce -> { answers }
local probesThisTick, probeTick = 0, nil

local wakeWanted = false

local function wake()
    wakeWanted = true
    os.queueEvent(WAKE)
end

local function push(queue, item, limit)
    if #queue >= limit then return end
    queue[#queue + 1] = item
    wake()
end

local function onProbe(side, packet, channel)
    local tick = os.clock()
    if tick ~= probeTick then probeTick, probesThisTick = tick, 0 end
    if probesThisTick >= MAX_PROBES_PER_TICK then return end
    probesThisTick = probesThisTick + 1
    if ports[channel] and type(packet.nonce) == "string" and #packet.nonce <= 64 then
        os.queueEvent(net.PROBE_EVENT, { port = channel, nonce = packet.nonce, from = packet.src, side = side })
    end
end

local function onBeacon(packet)
    local probe = type(packet.nonce) == "string" and probes[packet.nonce]
    if probe and #probe.answers < MAX_PROBE_ANSWERS then
        probe.answers[#probe.answers + 1] = { data = packet.data, from = packet.src }
    end
end

local function receiver()
    openAll()
    while true do
        local event, side, channel, _, packet = os.pullEventRaw()
        if event == "peripheral" then
            openAll()
        elseif event == "modem_message" and type(packet) == "table" and packet.zn == VERSION
            and type(packet.src) == "number" and packet.src ~= myId then
            local kind = packet.t
            if kind == "probe" then
                onProbe(side, packet, channel)
            elseif kind == "beacon" then
                onBeacon(packet)
            elseif packet.dst == myId or kind == "hello" then
                packet.side, packet.channel = side, channel
                if kind == "data" or kind == "ack" then
                    push(dataQueue, packet, MAX_DATA_QUEUE)
                elseif kind == "hello" or kind == "resp" or kind == "auth" or kind == "done" then
                    push(handshakeQueue, packet, MAX_HANDSHAKE_QUEUE)
                end
            end
        end
    end
end

-- Sessions and peers ---------------------------------------------------------------------------

local sessions, currentFor = {}, {} -- by session id, and each computer's newest, by its id
local sessionOrder = {}

local function dropSession(session)
    sessions[session.sid] = nil
    if currentFor[session.peer] == session then currentFor[session.peer] = nil end
    for i, sid in ipairs(sessionOrder) do
        if sid == session.sid then
            table.remove(sessionOrder, i)
            break
        end
    end
end

local function addSession(session)
    while #sessionOrder >= MAX_SESSIONS do dropSession(sessions[sessionOrder[1]]) end
    session.created = now()
    sessions[session.sid] = session
    sessionOrder[#sessionOrder + 1] = session.sid
    currentFor[session.peer] = session
end

local function live(session)
    return session and now() - session.created < SESSION_LIFETIME
end

-- What's known about the sender of a session. Worked out each time, so that removing a root
-- takes effect at once.
local function peerOf(session)
    local names, first = trust.namesFor(session.certs, session.peer, session.keyHex)
    return {
        id = session.peer,
        key = session.keyHex,
        fingerprint = crypto.fingerprint(session.key),
        verified = first ~= nil,
        name = first and first.name or nil,
        root = first and first.root or nil,
        names = names,
    }
end

-- Whether a peer may use this key. A certificate for the id overrides a pin.
local function checkPin(id, keyHex, certs)
    local address = "net:" .. id
    local key = fromHex(keyHex)
    local _, certified = trust.namesFor(certs, id, keyHex)
    local pinned = keys.known(address)
    if pinned and pinned ~= key and not certified then
        return nil, "Computer " .. id .. " has a different key than before. An admin can forget the " ..
            "old one in Settings > Encryption keys > Trusted keys."
    end
    if pinned ~= key then keys.remember(address, key) end
    return true
end

-- Handshakes -----------------------------------------------------------------------------------

local outgoing = {}      -- computer id -> handshake we started
local halfOpen = {}      -- handshake id -> handshake we're answering

local function deriveKeys(sharedSecret, transcript)
    local prk = crypto.hmac(transcript, sharedSecret)
    local function k(label) return crypto.hmac(prk, label) end
    return {
        aHandshake = k("a handshake"), bHandshake = k("b handshake"),
        aEnc = k("a enc"), bEnc = k("b enc"), aMac = k("a mac"), bMac = k("b mac"),
    }
end

local function makeTranscript(ephA, ephB)
    return fromHex(crypto.sha256(PROTOCOL .. ephA .. ephB))
end

local function hsId(transcript)
    return toHex(transcript):sub(1, 32)
end

local function identityBody(sig)
    local _, public = trust.identity()
    return encode({ key = toHex(public), certs = trust.certs(), sig = toHex(sig) })
end

-- The fields of a decrypted identity, or nil if they aren't sound.
local function parseIdentity(plain)
    if not plain then return nil end
    local ok, body = decode(plain)
    if not ok or type(body) ~= "table" or not isHex(body.key, 64) or not isHex(body.sig, 128) then
        return nil
    end
    return body.key, fromHex(body.key), type(body.certs) == "table" and body.certs or {}, fromHex(body.sig)
end

local function failJob(job, why)
    job.done, job.ok, job.err = true, false, why
    os.queueEvent(DONE)
end

local function startHandshake(id, port)
    local secret, public = crypto.keypair()
    local hs = { peer = id, port = port, secret = secret, public = public, sent = now(), started = now() }
    outgoing[id] = hs
    transmit(port, { t = "hello", eph = toHex(public), dst = id })
    return hs
end

local function onHello(packet)
    local info = ports[packet.channel]
    if not info or not isHex(packet.eph, 64) or packet.dst ~= myId then return end
    local count = 0
    for sid, hs in pairs(halfOpen) do
        if now() - hs.started > HANDSHAKE_TIMEOUT then
            halfOpen[sid] = nil
        else
            count = count + 1
        end
    end
    if count >= MAX_HALF_OPEN then return end

    local ephA = fromHex(packet.eph)
    local secret, ephB = crypto.keypair()
    local ok, sharedSecret = pcall(crypto.shared, secret, ephA)
    if not ok then return end
    local transcript = makeTranscript(ephA, ephB)
    local derived = deriveKeys(sharedSecret, transcript)
    crypto.clearCache()

    local seed, public = trust.identity()
    local sig = crypto.sign(seed, "zos-net-1|resp|" .. transcript .. public, public)
    local id = hsId(transcript)
    halfOpen[id] = { peer = packet.src, keys = derived, transcript = transcript, started = now() }
    transmit(homeChannel(packet.src), {
        t = "resp", dst = packet.src, eph = toHex(ephB),
        box = crypto.seal(derived.bHandshake, identityBody(sig)),
    })
end

local function onResp(packet)
    local hs = outgoing[packet.src]
    if not hs or hs.finishing or not isHex(packet.eph, 64) then return end
    local ephB = fromHex(packet.eph)
    local ok, sharedSecret = pcall(crypto.shared, hs.secret, ephB)
    if not ok then return end
    local transcript = makeTranscript(hs.public, ephB)
    local derived = deriveKeys(sharedSecret, transcript)
    crypto.clearCache()

    local keyHex, key, certs, sig = parseIdentity(crypto.open(derived.bHandshake, packet.box))
    if not keyHex then return end
    if not crypto.verify(key, "zos-net-1|resp|" .. transcript .. key, sig) then return end
    local allowed, why = checkPin(hs.peer, keyHex, certs)
    if not allowed then
        hs.why = why -- ignored, not a failure: anyone can answer a hello
        return
    end

    local seed, public = trust.identity()
    local mine = crypto.sign(seed, "zos-net-1|auth|" .. transcript .. key .. public, public)
    local id = hsId(transcript)
    hs.finishing, hs.sid, hs.keys, hs.keyHex, hs.key, hs.certs = true, id, derived, keyHex, key, certs
    hs.transcript = transcript
    hs.started = now()
    transmit(homeChannel(hs.peer), {
        t = "auth", dst = hs.peer, hs = id, box = crypto.seal(derived.aHandshake, identityBody(mine)),
    })
end

local function onAuth(packet)
    local hs = type(packet.hs) == "string" and halfOpen[packet.hs]
    if not hs or hs.peer ~= packet.src then return end
    local keyHex, key, certs, sig = parseIdentity(crypto.open(hs.keys.aHandshake, packet.box))
    if not keyHex then return end
    local _, public = trust.identity()
    if not crypto.verify(key, "zos-net-1|auth|" .. hs.transcript .. public .. key, sig) then return end
    if not checkPin(hs.peer, keyHex, certs) then return end

    halfOpen[packet.hs] = nil
    addSession({
        sid = packet.hs, peer = hs.peer, key = key, keyHex = keyHex, certs = certs,
        sendEnc = hs.keys.bEnc, sendMac = hs.keys.bMac, recvEnc = hs.keys.aEnc, recvMac = hs.keys.aMac,
        sendSeq = 0, recvSeq = 0,
    })
    transmit(homeChannel(hs.peer), {
        t = "done", dst = hs.peer, hs = packet.hs,
        tag = toHex(crypto.hmac(hs.keys.bHandshake, "zos-net-1|done|" .. hs.transcript)),
    })
end

local function onDone(packet)
    local hs = outgoing[packet.src]
    if not hs or not hs.finishing or packet.hs ~= hs.sid then return end
    if packet.tag ~= toHex(crypto.hmac(hs.keys.bHandshake, "zos-net-1|done|" .. hs.transcript)) then return end
    outgoing[packet.src] = nil
    addSession({
        sid = hs.sid, peer = hs.peer, key = hs.key, keyHex = hs.keyHex, certs = hs.certs,
        sendEnc = hs.keys.aEnc, sendMac = hs.keys.aMac, recvEnc = hs.keys.bEnc, recvMac = hs.keys.bMac,
        sendSeq = 0, recvSeq = 0,
    })
end

-- Data -----------------------------------------------------------------------------------------

local function nonceFor(seq)
    local out = {}
    for i = 1, 12 do
        out[i] = string.char(seq % 256)
        seq = math.floor(seq / 256)
    end
    return table.concat(out)
end

local function dataTag(key, sid, src, dst, port, seq, ct)
    return toHex(crypto.hmac(key, table.concat({ "data", sid, src, dst, port, seq, ct }, "|")))
end

local function ackTag(key, sid, src, dst, seq, status)
    return toHex(crypto.hmac(key, table.concat({ "ack", sid, src, dst, seq, status }, "|")))
end

local function sendAck(session, seq, status)
    transmit(homeChannel(session.peer), {
        t = "ack", dst = session.peer, sid = session.sid, seq = seq, status = status,
        tag = ackTag(session.sendMac, session.sid, myId, session.peer, seq, status),
    })
end

local seen = {}    -- message ids already delivered -> when
local waiting = {} -- message id of a request -> its job, once delivered or on its way

local function sweepSeen()
    local cutoff = now() - MESSAGE_MEMORY
    for id, at in pairs(seen) do
        if at < cutoff then seen[id] = nil end
    end
end

local function message(session, body, packet, port)
    return {
        payload = body.p, port = port, from = session.peer, id = body.id,
        side = packet.side, peer = peerOf(session),
    }
end

local function deliver(session, body, packet)
    local msg = message(session, body, packet, packet.port)
    local inbox = ports[packet.port].inbox
    if #inbox >= INBOX_SIZE then table.remove(inbox, 1) end
    inbox[#inbox + 1] = msg
    os.queueEvent(net.EVENT, msg)
end

local function onData(packet)
    local session = type(packet.sid) == "string" and sessions[packet.sid]
    if not session or session.peer ~= packet.src or not live(session) then return end
    if type(packet.seq) ~= "number" or packet.seq % 1 ~= 0 or packet.seq <= session.recvSeq then return end
    if not isHex(packet.ct) or not isHex(packet.tag, 64) or type(packet.port) ~= "number" then return end
    local tag = dataTag(session.recvMac, session.sid, packet.src, myId, packet.port, packet.seq, packet.ct)
    if tag ~= packet.tag then return end
    session.recvSeq = packet.seq

    local ok, body = decode(crypto.chacha20(session.recvEnc, nonceFor(packet.seq), fromHex(packet.ct)))
    if not ok or type(body) ~= "table" or type(body.id) ~= "string" then return end

    if body.re ~= nil then
        local job = waiting[body.re]
        if not job or job.keyHex ~= session.keyHex or packet.channel ~= homeChannel(myId) then
            return sendAck(session, packet.seq, "closed")
        end
        sendAck(session, packet.seq, "ok")
        waiting[body.re] = nil
        job.reply = message(session, body, packet, job.port)
        job.done, job.ok = true, true
        os.queueEvent(DONE)
        return
    end

    local info = ports[packet.port]
    if not info or packet.channel ~= packet.port then return sendAck(session, packet.seq, "closed") end
    if info.modem and info.modem ~= packet.side then return sendAck(session, packet.seq, "closed") end
    if info.verified and not peerOf(session).verified then return sendAck(session, packet.seq, "denied") end

    sendAck(session, packet.seq, "ok")
    sweepSeen()
    local id = session.keyHex .. "|" .. body.id
    if seen[id] then return end
    seen[id] = now()
    deliver(session, body, packet)
end

local function onAck(packet)
    local session = type(packet.sid) == "string" and sessions[packet.sid]
    if not session or session.peer ~= packet.src or type(packet.seq) ~= "number" then return end
    if type(packet.status) ~= "string" or not isHex(packet.tag, 64) then return end
    if packet.tag ~= ackTag(session.recvMac, session.sid, packet.src, myId, packet.seq, packet.status) then
        return
    end
    for _, job in ipairs(jobs) do
        if job.session == session and job.seq == packet.seq and job.state == "ack" then
            job.status = packet.status
        end
    end
end

-- Jobs: sending one message, from first handshake to the ack -----------------------------------

local function sendData(job, session)
    session.sendSeq = session.sendSeq + 1
    local seq = session.sendSeq
    local plain = encode({ id = job.id, p = job.payload, re = job.re })
    local ct = toHex(crypto.chacha20(session.sendEnc, nonceFor(seq), plain))
    local dataPort = job.channelPort
    transmit(job.channel, {
        t = "data", dst = session.peer, sid = session.sid, port = dataPort, seq = seq, ct = ct,
        tag = dataTag(session.sendMac, session.sid, myId, session.peer, dataPort, seq, ct),
    })
    job.session, job.seq, job.state, job.deadline, job.status = session, seq, "ack", now() + ACK_TIMEOUT, nil
end

local function holdsName(peer, name, root)
    if root then return peer.names[root] == name end
    for _, held in pairs(peer.names) do
        if held == name then return true end
    end
    return false
end

-- Why this peer isn't who the caller asked for, if it isn't.
local function refusal(job, peer)
    local opts = job.opts
    if opts.key and peer.key ~= opts.key then return "That's computer " .. peer.id .. ", which has a different key." end
    if opts.verified and not peer.verified then return "That computer has no certificate from a trusted root." end
    if opts.expect and not holdsName(peer, opts.expect, opts.root) then
        return "That's computer " .. peer.id .. ", which is not '" .. opts.expect .. "'."
    end
end

local function stepJob(job)
    if job.state == "new" then
        local session = currentFor[job.peer]
        if live(session) then
            local why = refusal(job, peerOf(session))
            if why and (job.renegotiated or job.noHandshake) then return failJob(job, why) end
            if why then
                -- Certificates are swapped in the handshake, so a new one needs a new session.
                job.renegotiated = true
                dropSession(session)
                return stepJob(job)
            end
            job.keyHex = session.keyHex
            sendData(job, session)
            return
        end
        if session then dropSession(session) end
        if job.noHandshake then return failJob(job, "The other computer has gone.") end
        job.state, job.deadline = "handshake", now() + HANDSHAKE_TIMEOUT
        if not outgoing[job.peer] then startHandshake(job.peer, job.handshakePort) end
    elseif job.state == "handshake" then
        local hs = outgoing[job.peer]
        if live(currentFor[job.peer]) then
            job.state = "new"
            return stepJob(job)
        end
        if now() >= job.deadline then
            local why = hs and hs.why or "There was no answer from the other computer."
            if hs then outgoing[job.peer] = nil end
            return failJob(job, why)
        end
        if not hs then
            startHandshake(job.peer, job.handshakePort)
        elseif not hs.finishing and now() - hs.sent >= HELLO_RETRY then
            hs.sent = now()
            transmit(hs.port, { t = "hello", eph = toHex(hs.public), dst = hs.peer })
        end
    elseif job.state == "ack" then
        if job.status == "ok" then
            if job.expectReply then
                job.state, job.deadline = "reply", now() + job.timeout * 1000
                waiting[job.id] = job
            else
                job.done, job.ok = true, true
                os.queueEvent(DONE)
            end
        elseif job.status == "closed" then
            failJob(job, "That port is closed.")
        elseif job.status == "denied" then
            if job.renegotiated then return failJob(job, "That port only accepts verified computers.") end
            job.renegotiated = true
            dropSession(job.session)
            job.state = "new"
            return stepJob(job)
        elseif now() >= job.deadline then
            if job.retried then return failJob(job, "There was no answer from the other computer.") end
            job.retried = true
            dropSession(job.session)
            job.state = "new"
            return stepJob(job)
        end
    elseif job.state == "reply" and now() >= job.deadline then
        waiting[job.id] = nil
        failJob(job, "The other computer didn't reply.")
    end
end

local function stepJobs()
    for i = #jobs, 1, -1 do
        local job = jobs[i]
        if not job.done then
            local ok, err = pcall(stepJob, job)
            if not ok then failJob(job, tostring(err)) end
        end
        if job.done then table.remove(jobs, i) end
    end
end

local function handlePacket(packet)
    local kind = packet.t
    if kind == "data" then
        onData(packet)
    elseif kind == "ack" then
        onAck(packet)
    elseif kind == "hello" then
        onHello(packet)
    elseif kind == "resp" then
        onResp(packet)
    elseif kind == "auth" then
        onAuth(packet)
    elseif kind == "done" then
        onDone(packet)
    end
end

-- Crypto throws away events while it works, including this loop's timer and wake-ups, so neither
-- can be relied on to arrive: the next tick comes from the clock, and wakeWanted survives as a flag.
local function worker()
    local nextTick = 0
    while true do
        wakeWanted = false
        local packet = table.remove(dataQueue, 1) or table.remove(handshakeQueue, 1)
        if packet then
            pcall(handlePacket, packet) -- packets come from anyone
        end
        stepJobs()
        if #dataQueue == 0 and #handshakeQueue == 0 and not wakeWanted then
            if now() >= nextTick then
                os.startTimer(1)
                nextTick = now() + 1000
            end
            os.pullEventRaw()
        end
    end
end

-- Runs a job on the worker and waits for it. Each job has a time limit, so this always returns.
local function run(job)
    if not running then return nil, "Networking isn't running." end
    local ok, encoded = pcall(encode, job.payload)
    if not ok then return nil, "This can't be sent: " .. tostring(encoded) end
    if #encoded > net.MAX_PAYLOAD then return nil, "This is too big to send." end

    job.id = toHex(crypto.randomBytes(8))
    job.state = "new"
    jobs[#jobs + 1] = job
    wake()
    while not job.done do os.pullEventRaw(DONE) end
    if job.ok then return job.reply or true end
    return nil, job.err
end

local function newJob(id, port, payload, opts)
    opts = opts or {}
    return {
        peer = id, payload = payload, opts = opts, port = port,
        channel = port, channelPort = port, handshakePort = port,
        timeout = opts.timeout or 5,
    }
end

local function badTarget(id, port)
    if id == myId then return "A computer can't send to its own computer." end
    if type(id) ~= "number" or not validPort(port) then return "Bad computer id or port." end
end

function net.send(id, port, payload, opts)
    local bad = badTarget(id, port)
    if bad then return nil, bad end
    return run(newJob(id, port, payload, opts))
end

function net.request(id, port, payload, opts)
    local bad = badTarget(id, port)
    if bad then return nil, bad end
    local job = newJob(id, port, payload, opts)
    job.expectReply = true
    return run(job)
end

function net.reply(msg, payload)
    if type(msg) ~= "table" or type(msg.peer) ~= "table" then return nil, "That isn't a message." end
    local home = homeChannel(msg.from)
    local job = newJob(msg.from, msg.port, payload)
    job.re, job.channel, job.channelPort = msg.id, home, msg.port
    job.opts = { key = msg.peer.key }
    job.noHandshake = true -- only the key that asked can collect the answer
    return run(job)
end

-- Receiving ------------------------------------------------------------------------------------

function net.listen(port, opts)
    opts = opts or {}
    if not validPort(port) then return nil, "Ports are 0 to " .. MAX_PORT .. "." end
    if port == homeChannel(myId) then return nil, "That channel is used for replies." end
    local info = ports[port]
    if info then
        info.modem, info.verified = opts.modem, opts.verified
    else
        ports[port] = { inbox = {}, modem = opts.modem, verified = opts.verified }
    end
    openOn(port, opts.modem)
    return true
end

function net.close(port)
    if not ports[port] then return end -- which also keeps the home channel open
    ports[port] = nil
    for _, name in ipairs(net.modems()) do peripheral.call(name, "close", port) end
    os.queueEvent(net.EVENT)
end

function net.receive(port, timeout)
    local timer = timeout and os.startTimer(timeout)
    while true do
        local info = ports[port]
        if not info then return nil end
        if #info.inbox > 0 then return table.remove(info.inbox, 1) end
        local event, id = os.pullEventRaw()
        if event == "terminate" then return nil, "terminated" end
        if event == "timer" and id == timer then return nil, "timed out" end
    end
end

function net.isRunning()
    return running
end

-- Discovery ------------------------------------------------------------------------------------

function net.probe(port, timeout)
    local nonce = toHex(crypto.randomBytes(8))
    local probe = { answers = {} }
    probes[nonce] = probe
    transmit(port, { t = "probe", nonce = nonce })
    util.wait(timeout or 3)
    probes[nonce] = nil
    return probe.answers
end

function net.answerProbe(probe, data)
    transmit(homeChannel(probe.from), { t = "beacon", nonce = probe.nonce, data = data })
end

-- Root servers and hostnames ------------------------------------------------------------------

function net.findRoots(timeout)
    local out, seenKeys = {}, {}
    for _, answer in ipairs(net.probe(net.ROOT_PORT, timeout)) do
        local advert = answer.data
        if trust.verifyAdvert(advert) and not seenKeys[advert.key] then
            seenKeys[advert.key] = true
            out[#out + 1] = {
                name = advert.name, key = advert.key, host = answer.from,
                fingerprint = crypto.fingerprint(fromHex(advert.key)),
            }
        end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

-- A root's answers carry its own signature, which is what's checked here. Its signing key isn't
-- the key of the computer it runs on, so that computer can make a request fail but no more.
function net.requestCertificate(root, name)
    local reply, err = net.request(root.host, net.ROOT_PORT, { op = "certificate", name = name },
        { timeout = 15 })
    if not reply then return nil, err end
    local payload = reply.payload
    if type(payload) ~= "table" then return nil, "The root server sent a bad answer." end
    if payload.status == "issued" then
        local _, public = trust.identity()
        local cert = payload.cert
        if not trust.certIntact(cert) or cert.root ~= root.key or cert.key ~= toHex(public)
            or cert.id ~= myId or cert.name ~= name then
            return nil, "The root server sent a bad certificate."
        end
        trust.installCert(cert)
        return "issued"
    end
    if payload.status == "pending" or payload.status == "denied" then return payload.status end
    return nil, type(payload.message) == "string" and payload.message or "The root server refused."
end

-- A trusted root's top-level domain, by asking it the first time.
function net.tldOf(root)
    if root.tld then return root.tld end
    local reply, err = net.request(root.host, net.ROOT_PORT, { op = "zone" })
    if not reply then return nil, err end
    if not trust.verifyZone(reply.payload, root.key) then return nil, "The root server sent a bad zone." end
    trust.setRootTld(root.key, reply.payload.tld)
    return reply.payload.tld
end

function net.rootForTld(tld)
    local found
    local failure
    for _, root in ipairs(trust.roots()) do
        local theirs, err = net.tldOf(root)
        if theirs == tld then
            if found then return nil, "." .. tld .. " is claimed by two trusted root servers." end
            found = root
        elseif not theirs then
            failure = err
        end
    end
    if found then return found end
    return nil, failure or ("No trusted root owns ." .. tld .. ".")
end

function net.resolve(host)
    local label, tld = trust.parseHost(host)
    if not label then return nil, tld end
    local root, err = net.rootForTld(tld)
    if not root then return nil, err end
    local reply
    reply, err = net.request(root.host, net.ROOT_PORT, { op = "resolve", name = host })
    if not reply then return nil, err end
    local cert = type(reply.payload) == "table" and reply.payload.cert
    if not cert then return nil, "There's no host called " .. host .. "." end
    if not trust.certIntact(cert) or cert.root ~= root.key or cert.name ~= host then
        return nil, "The root server sent a bad certificate."
    end
    return { host = host, id = cert.id, key = cert.key, root = root.key }
end

function net.requestHost(host, port, payload, opts)
    local found, err = net.resolve(host)
    if not found then return nil, err end
    return net.request(found.id, port, payload, {
        key = found.key, expect = host, root = found.root, timeout = opts and opts.timeout,
    })
end

function net.isHost(peer, host)
    if type(peer) ~= "table" or type(peer.names) ~= "table" then return false end
    local label, tld = trust.parseHost(host)
    if not label then return false end
    for rootKey, name in pairs(peer.names) do
        if name == host then
            local root = trust.root(rootKey)
            if root and root.tld == tld then return true end
            if root and net.tldOf(root) == tld then return true end
        end
    end
    return false
end

-- Certificates are renewed in their last 7 days, for as long as the root server can be reached.
local function renewer()
    util.wait(RENEW_DELAY)
    while true do
        for _, cert in ipairs(trust.certs()) do
            local root = trust.root(cert.root)
            if root and cert.expires - now() < RENEW_BEFORE then
                pcall(net.requestCertificate, root, cert.name)
            end
        end
        util.wait(RENEW_EVERY)
    end
end

function net.start()
    if running then return end
    running = true
    trust.identity()
    services.start("net:receiver", receiver)
    services.start("net:worker", worker)
    services.start("net:renewer", renewer)
end

return net
