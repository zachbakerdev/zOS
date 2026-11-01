-- End-to-end tests of net.lua, trust.lua and the root-server app, using several simulated
-- computers and an attacker on the wire. Run from the repository root: luajit tests/test_net.lua
package.path = "tests/?.lua;" .. package.path

local sim = require("sim")

local failed, passed = 0, 0
local function check(name, got, ...)
  local want = true
  if select("#", ...) > 0 then want = ... end
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name .. ": got " .. tostring(got) .. ", want " .. tostring(want))
  end
end

local function send(c, ...)
  local args = { ... }
  return sim.call(c, function() return c.net.send(table.unpack(args)) end)
end

local function has(s, text)
  return s:find(text, 1, true) ~= nil
end

local function wireText()
  local parts = {}
  local function walk(v)
    if type(v) == "table" then
      for k, x in pairs(v) do walk(k) walk(x) end
    else
      parts[#parts + 1] = tostring(v)
    end
  end
  walk(sim.wire)
  return table.concat(parts, " ")
end

local function trustOf(c) return c.env.require("trust") end
local function cryptoOf(c) return c.env.require("crypto") end

local function reset()
  for id, c in pairs(sim.computers) do sim.powerOff(c) end
  sim.wire, sim.onPacket = {}, nil
end

-- A computer running the root-server app's service, already set up.
local function rootServer(id, name)
  local c = sim.computer(id)
  c.appDir = "apps/root-server/"
  c.db = c.env.require("rootdb")
  sim.call(c, function() c.db.setup(name) end)
  local fn = assert(loadfile("apps/root-server/service.lua"))
  setfenv(fn, c.env)
  sim.spawn(c, fn)
  sim.advance(1)
  return c
end

-- Have `root` sign `c` as `name`, with `c` trusting it.
local function certify(c, root, name)
  local found = sim.call(c, function() return c.net.findRoots(2) end)
  local entry
  for _, r in ipairs(found) do if r.host == root.id then entry = r end end
  trustOf(c).addRoot(entry.key, entry.name, entry.host)
  local status = sim.call(c, function() return c.net.requestCertificate(entry, name) end)
  check("first request is pending", status, "pending")
  local _, public = trustOf(c).identity()
  sim.call(root, function() return root.db.approve(cryptoOf(c).toHex(public), name, c.id) end)
  status = sim.call(c, function() return c.net.requestCertificate(entry, name) end)
  check("approved request is issued", status, "issued")
  return entry
end

-- Basic delivery ------------------------------------------------------------

do
  local a, b = sim.computer(1), sim.computer(2)
  check("listen", b.net.listen(5000))
  local inbox = sim.inbox(b)

  local secret = "the-cake-is-a-lie"
  local ok, err = send(a, 2, 5000, { text = secret, n = 42, list = { 1, 2, { true } }, big = 1700000000123 })
  check("send", ok, true)
  check("no error", err, nil)
  sim.advance(1)
  check("one event", #inbox, 1)
  local msg = inbox[1]
  check("payload text", msg.payload.text, secret)
  check("payload number", msg.payload.n, 42)
  check("payload nested", msg.payload.list[3][1], true)
  check("payload large number", msg.payload.big, 1700000000123)
  check("port", msg.port, 5000)
  check("from", msg.from, 1)
  check("side", msg.side, "top")
  check("unverified by default", msg.peer.verified, false)
  check("peer fingerprint", msg.peer.fingerprint, cryptoOf(a).fingerprint(select(2, trustOf(a).identity())))
  check("plaintext not on the wire", has(wireText(), secret), false)

  -- binary and nil-free edge payloads
  local binary = string.char(0, 255, 10, 13) .. ":{}"
  ok = send(a, 2, 5000, binary)
  sim.advance(1)
  check("binary payload", inbox[2].payload, binary)
  ok = send(a, 2, 5000, nil)
  check("nil payload sends", ok, true)
  sim.advance(1)
  check("nil payload arrives", #inbox, 3)

  -- the session is reused, so no more handshakes
  local hellos = 0
  for _, p in ipairs(sim.wire) do if p.message.t == "hello" then hellos = hellos + 1 end end
  check("one handshake", hellos, 1)

  -- closed ports, unreachable computers, bad arguments
  local nope, why = send(a, 2, 5001, "x")
  check("closed port fails", nope, nil)
  check("closed port says why", has(tostring(why), "no answer") or has(tostring(why), "closed"))
  nope, why = send(a, 99, 5000, "x")
  check("unknown computer", nope, nil)
  check("bad port", (a.net.listen(70000)), nil)
  nope, why = send(a, 2, 5000, function() end)
  check("function payload", nope, nil)
  check("function payload says why", has(tostring(why), "function"))
  b.net.close(5000)
  nope = send(a, 2, 5000, "x")
  check("closed after close", nope, nil)
end

-- Requests -------------------------------------------------------------------

reset()
do
  local a, b = sim.computer(1), sim.computer(2)
  b.net.listen(5000)
  sim.spawn(b, function()
    while true do
      local _, msg = b.env.os.pullEventRaw("net_message")
      b.net.reply(msg, { echo = msg.payload })
    end
  end)
  local reply, err = sim.call(a, function() return a.net.request(2, 5000, "ping") end)
  check("request", reply and reply.payload.echo, "ping")
  check("request has no error", err, nil)
  reply = sim.call(a, function() return a.net.request(2, 5000, "ping2") end)
  check("second request", reply and reply.payload.echo, "ping2")

  -- a server that's busy replying doesn't lose what arrives meanwhile
  local server = sim.computer(4)
  server.net.listen(7000)
  sim.spawn(server, function()
    while true do
      local msg = server.net.receive(7000)
      if msg then
        server.env.require("crypto").sign(string.rep("k", 32), "busy") -- filtered yields, like signing
        server.net.reply(msg, msg.from)
      end
    end
  end)
  local got = {}
  for _, id in ipairs({ 1, 2, 5, 6 }) do
    local client = sim.computers[id] or sim.computer(id)
    sim.spawn(client, function()
      local r = client.net.request(4, 7000, "hi", { timeout = 30 })
      got[#got + 1] = r and r.payload
    end)
  end
  sim.run(function() return #got == 4 end)
  local all = true
  for _, v in ipairs(got) do all = all and v ~= nil end
  check("every request was answered", all)

  -- receive
  local e = sim.computer(7)
  e.net.listen(8000)
  check("receive times out", select(2, sim.call(e, function() return e.net.receive(8000, 1) end)), "timed out")
  check("receive on a closed port", (sim.call(e, function() return e.net.receive(8001) end)), nil)
  sim.call(a, function() return a.net.send(7, 8000, "one") end)
  sim.call(a, function() return a.net.send(7, 8000, "two") end)
  sim.advance(1)
  local first = sim.call(e, function() return e.net.receive(8000) end)
  local second = sim.call(e, function() return e.net.receive(8000) end)
  check("receive keeps messages in order", first.payload == "one" and second.payload == "two")
  check("home channel can't be listened on", (e.net.listen(30007)), nil)

  -- terminate doesn't raise from blocking calls, and a waiting receive just returns
  local finished
  local t = sim.spawn(a, function() finished = { a.net.send(2, 5000, "through terminate") } end)
  a.env.os.queueEvent("terminate")
  sim.run(function() return t.done end)
  check("terminate doesn't stop a send", finished[1], true)
  local r = sim.spawn(e, function() return e.net.receive(8000) end)
  sim.advance(0.1)
  e.env.os.queueEvent("terminate")
  sim.run(function() return r.done end)
  check("terminate ends a receive", r.done)

  -- terminate never reaches a service, which could be waiting in os.pullEvent or sleep
  local terminated = false
  e.env.require("services").start("watcher", function()
    while true do
      if e.env.os.pullEventRaw() == "terminate" then terminated = true end
    end
  end)
  sim.advance(0.1)
  e.env.os.queueEvent("terminate")
  sim.advance(0.1)
  check("terminate skips services", not terminated)
  e.env.require("services").stop("watcher")

  -- a port nobody answers on
  local c = sim.computer(3)
  c.net.listen(6000)
  local none, why = sim.call(a, function() return a.net.request(3, 6000, "x", { timeout = 2 }) end)
  check("no reply", none, nil)
  check("no reply says why", has(tostring(why), "didn't reply"))
end

-- Attacks on the wire --------------------------------------------------------

reset()
do
  local a, b = sim.computer(1), sim.computer(2)
  b.net.listen(5000)
  local inbox = sim.inbox(b)
  send(a, 2, 5000, "first")
  sim.advance(1)
  check("baseline", #inbox, 1)

  local data
  for _, p in ipairs(sim.wire) do if p.message.t == "data" then data = p end end

  sim.deliver(sim.copy(data), 1)
  sim.advance(1)
  check("replay is dropped", #inbox, 1)

  sim.advance(90) -- longer than duplicate messages are remembered
  sim.deliver(sim.copy(data), 1)
  sim.advance(1)
  check("old replay is dropped", #inbox, 1)

  local forged = sim.copy(data)
  forged.message.seq = forged.message.seq + 10
  sim.deliver(forged, 1)
  sim.advance(1)
  check("changed sequence number is dropped", #inbox, 1)

  forged = sim.copy(data)
  forged.message.seq = forged.message.seq + 1
  local ct = forged.message.ct
  forged.message.ct = (ct:sub(1, 1) == "0" and "1" or "0") .. ct:sub(2)
  sim.deliver(forged, 1)
  sim.advance(1)
  check("changed ciphertext is dropped", #inbox, 1)

  forged = sim.copy(data)
  forged.message.port = 5001
  forged.channel = 5001
  b.net.listen(5001)
  sim.deliver(forged, 1)
  sim.advance(1)
  check("redirected port is dropped", #inbox, 1)

  -- digits can't move between the sequence number and the ciphertext
  local baseHellos, moved = 0, nil
  for i = 1, 400 do
    send(a, 2, 5000, "n" .. i)
    local last = sim.wire[#sim.wire - 1]
    for j = #sim.wire, 1, -1 do
      if sim.wire[j].message.t == "data" then last = sim.wire[j] break end
    end
    local byte = tonumber(last.message.ct:sub(1, 2), 16)
    if byte >= 48 and byte <= 57 then moved = sim.copy(last) break end
  end
  check("found a ciphertext starting with a digit", moved ~= nil)
  moved.message.seq = moved.message.seq * 10 + (tonumber(moved.message.ct:sub(1, 2), 16) - 48)
  moved.message.ct = moved.message.ct:sub(3)
  sim.deliver(moved, 1)
  sim.advance(1)
  local wireBefore = #sim.wire
  check("still sending after moving digits", send(a, 2, 5000, "after"), true)
  local rehandshook = false
  for i = wireBefore + 1, #sim.wire do rehandshook = rehandshook or sim.wire[i].message.t == "hello" end
  check("moved digits don't break the session", rehandshook, false)

  -- changes made in flight, so the sequence number is still unused and the nonce still right
  local function tamperOnce(change)
    local done = false
    sim.onPacket = function(p)
      if p.message.t == "data" and not done then
        done = true
        change(p.message)
      end
    end
  end

  local text = string.rep("A", 300)
  tamperOnce(function(m)
    local mid = math.floor(#m.ct / 4) * 2 + 1
    local byte = tonumber(m.ct:sub(mid, mid + 1), 16)
    m.ct = m.ct:sub(1, mid - 1) .. string.format("%02x", (byte + 1) % 256) .. m.ct:sub(mid + 2)
  end)
  check("send survives a bit flip", send(a, 2, 5000, text), true)
  sim.advance(1)
  check("bit flip is dropped and the retry is intact", inbox[#inbox].payload, text)

  local count5001 = 0
  b.net.listen(5001)
  sim.spawn(b, function()
    while true do
      local _, msg = b.env.os.pullEventRaw("net_message")
      if msg.port == 5001 then count5001 = count5001 + 1 end
    end
  end)
  tamperOnce(function(m) m.port = 5001 end)
  sim.onPacket = (function(inner)
    return function(p)
      inner(p)
      if p.message.t == "data" then p.channel = p.message.port end
    end
  end)(sim.onPacket)
  local sent, whyNot = send(a, 2, 5000, "for 5000")
  check("send survives a changed port", sent, true)
  sim.advance(1)
  check("changed port is dropped", count5001, 0)
  sim.onPacket = nil

  local JUNK = { "text", 5, {}, { zn = 1 }, { zn = 1, src = "x", dst = 2, t = "data" },
    { zn = 1, src = 1, dst = 2, t = "data", sid = {}, seq = -1, ct = "zz" },
    { zn = 1, src = 1, dst = 2, t = "hello", eph = "short" },
    { zn = 1, src = 1, dst = 2, t = "auth", hs = 5, box = 1 },
    { zn = 1, src = 1, dst = 2, t = "resp", eph = string.rep("0", 64), box = {} },
    { zn = 1, src = 1, dst = 2, t = "hello", eph = string.rep("0", 64) }, -- low-order point
    { zn = 1, src = 1, dst = 2, t = "nonsense" } }
  local before = #inbox
  for _, junk in ipairs(JUNK) do
    sim.deliver({ from = 66, channel = 5000, reply = 1, message = junk })
  end
  sim.advance(1)
  check("junk is dropped", #inbox, before)
  check("still works after junk", send(a, 2, 5000, "second"), true)
  sim.advance(1)
  check("delivered after junk", #inbox, before + 1)

  -- forged acks can't make a send look delivered
  local c = sim.computer(3)
  c.net.listen(5000)
  local cbox = sim.inbox(c)
  sim.call(a, function() return a.net.send(3, 5000, "warmup") end)
  local dropping = true
  sim.onPacket = function(p)
    if dropping and p.message.t == "data" then
      sim.deliver({ from = 66, channel = p.reply, reply = 0, message = {
        zn = 1, src = 3, dst = 1, t = "ack", sid = p.message.sid, seq = p.message.seq, status = "ok", tag = string.rep("0", 64),
      } })
      return false
    end
  end
  sim.advance(0.2)
  local before = #cbox
  local thread = sim.spawn(a, function() return a.net.send(3, 5000, "lost") end)
  sim.advance(4)
  check("forged ack ignored, send still waiting", thread.done == true, false)
  dropping = false
  sim.run(function() return thread.done end)
  sim.advance(1)
  check("retry delivered it", #cbox, before + 1)
  sim.onPacket = nil
end

-- A man in the middle, swapping ephemeral keys, can't complete a handshake.
reset()
do
  local a, b = sim.computer(1), sim.computer(2)
  b.net.listen(5000)
  local inbox = sim.inbox(b)
  local evil = cryptoOf(a).toHex(select(2, cryptoOf(a).keypair()))
  sim.onPacket = function(p)
    if p.message.t == "hello" or p.message.t == "resp" then p.message.eph = evil end
  end
  local ok, why = send(a, 2, 5000, "x")
  check("mitm fails", ok, nil)
  sim.onPacket = nil
  sim.advance(1)
  check("mitm delivers nothing", #inbox, 0)
end

-- Knowing a public key isn't enough: the handshake has to be signed with its secret key.
reset()
do
  local a, b = sim.computer(1), sim.computer(2)
  b.net.listen(5000)
  check("real peer", send(a, 2, 5000, "x"), true)
  local victim = select(2, trustOf(b).identity())
  sim.powerOff(b)

  local imposter = sim.computer(2)
  imposter.net.listen(5000)
  local box = sim.inbox(imposter)
  local evilSeed = trustOf(imposter).identity()
  trustOf(imposter).identity = function() return evilSeed, victim end
  sim.setClock(sim.now() + 3700 * 1000) -- so the old session can't be reused
  sim.advance(2)
  local ok = send(a, 2, 5000, "secret")
  check("claiming someone's key without its secret fails", ok, nil)
  sim.advance(1)
  check("that imposter got nothing", #box, 0)
end

-- One forged answer in someone else's name mustn't stop the real handshake.
reset()
do
  local a, b = sim.computer(1), sim.computer(2)
  b.net.listen(5000)
  send(a, 2, 5000, "pin it")
  sim.setClock(sim.now() + 3700 * 1000)
  sim.advance(2)

  -- the real answer is held back until the forged one has landed, so the order is certain
  local attacker = sim.computer(66)
  local held
  local function answer(p)
    local crypto, trust = cryptoOf(attacker), trustOf(attacker)
    local ephA = crypto.fromHex(p.message.eph)
    local sk, ephB = crypto.keypair()
    local transcript = crypto.fromHex(crypto.sha256("zos-net-1" .. ephA .. ephB))
    local prk = crypto.hmac(transcript, crypto.x25519(sk, ephA))
    local seed, public = trust.identity()
    local context = "zos-net-1|resp|" .. transcript .. public
    local hex = crypto.toHex(public)
    local sig = crypto.toHex(crypto.sign(seed, context, public))
    local plain = "{s3:keys" .. #hex .. ":" .. hex .. "s5:certs{}s3:sigs" .. #sig .. ":" .. sig .. "}"
    sim.deliver({ from = 66, channel = p.reply, reply = 0, message = {
      zn = 1, src = 2, dst = 1, t = "resp", eph = crypto.toHex(ephB),
      box = crypto.seal(crypto.hmac(prk, "b handshake"), plain) } })
    while not held do attacker.env.os.pullEventRaw("timer") end
    local timer = attacker.env.os.startTimer(3)
    repeat local _, id = attacker.env.os.pullEventRaw("timer") until id == timer
    sim.deliver(held)
    held = false
  end
  local timer = attacker.env.os.startTimer(1)
  sim.onPacket = function(p)
    if p.message.t == "hello" and p.from == 1 then
      sim.spawn(attacker, answer, sim.copy(p))
      attacker.env.os.startTimer(1)
      attacker.env.os.startTimer(2)
    elseif p.message.t == "resp" and p.from == 2 and held == nil then
      held = sim.copy(p)
      return false
    end
  end
  check("real handshake survives a forged answer", send(a, 2, 5000, "x"), true)
  sim.onPacket = nil
end

-- Pinning --------------------------------------------------------------------

reset()
do
  local a, b = sim.computer(1), sim.computer(2)
  b.net.listen(5000)
  check("first contact is pinned", send(a, 2, 5000, "x"), true)

  -- computer 2 is replaced by something with the same id and a different key
  sim.powerOff(b)
  local imposter = sim.computer(2)
  imposter.net.listen(5000)
  local box = sim.inbox(imposter)
  local ok, why = send(a, 2, 5000, "secret")
  check("changed key is refused", ok, nil)
  check("changed key says why", has(tostring(why), "different key"))
  sim.advance(1)
  check("imposter got nothing", #box, 0)
end

-- A rebooted peer loses its sessions --------------------------------------------

reset()
do
  local a, b = sim.computer(1), sim.computer(2)
  b.net.listen(5000)
  check("before reboot", send(a, 2, 5000, "one"), true)
  local files = b.files
  sim.powerOff(b)
  b = sim.computer(2, { files = files })
  b.net.listen(5000)
  local box = sim.inbox(b)
  check("same key survives a reboot", send(a, 2, 5000, "two"), true)
  sim.advance(1)
  check("delivered once after reboot", #box, 1)
end

-- A lost ack means a resend, which mustn't be delivered twice.
reset()
do
  local a, b = sim.computer(1), sim.computer(2)
  b.net.listen(5000)
  local box = sim.inbox(b)
  send(a, 2, 5000, "warmup")
  sim.advance(1)
  local dropped = false
  sim.onPacket = function(p)
    if p.message.t == "ack" and not dropped then
      dropped = true
      return false
    end
  end
  check("send survives a lost ack", send(a, 2, 5000, "once"), true)
  sim.advance(1)
  check("not delivered twice", #box, 2)
  sim.onPacket = nil
end

-- Both computers starting a handshake at once.
reset()
do
  local a, b = sim.computer(1), sim.computer(2)
  a.net.listen(5000)
  b.net.listen(5000)
  local boxA, boxB = sim.inbox(a), sim.inbox(b)
  local t1 = sim.spawn(a, function() return a.net.send(2, 5000, "from a") end)
  local t2 = sim.spawn(b, function() return b.net.send(1, 5000, "from b") end)
  sim.run(function() return t1.done and t2.done end)
  sim.advance(1)
  check("crossed handshakes a", #boxA, 1)
  check("crossed handshakes b", #boxB, 1)
  check("sessions keep working", send(a, 2, 5000, "again"), true)
  check("sessions keep working back", send(b, 1, 5000, "again"), true)
end

-- Expired sessions are replaced.
reset()
do
  local a, b = sim.computer(1), sim.computer(2)
  b.net.listen(5000)
  send(a, 2, 5000, "x")
  sim.setClock(sim.now() + 3700 * 1000)
  sim.advance(2)
  local count = #sim.wire
  check("send after session expiry", send(a, 2, 5000, "y"), true)
  local hello = false
  for i = count + 1, #sim.wire do hello = hello or sim.wire[i].message.t == "hello" end
  check("expiry forces a new handshake", hello)
end

-- Root servers ---------------------------------------------------------------

reset()
do
  local root = rootServer(10, "Overworld Root")
  local other = rootServer(11, "Nether Root")
  local a, b, c = sim.computer(1), sim.computer(2), sim.computer(3)

  local found = sim.call(a, function() return a.net.findRoots(2) end)
  check("finds both roots", #found, 2)
  check("sorted by name", found[1].name, "Nether Root")
  check("name and fingerprint", found[2].name == "Overworld Root" and found[2].fingerprint == root.db.fingerprint())
  check("host", found[2].host, 10)

  -- a forged advert (someone else's name, wrong signature) is left out
  local forged = sim.copy(root.db.config().advert)
  forged.name = "Fake Root"
  forged.key = cryptoOf(a).toHex(select(2, cryptoOf(a).keypair()))
  sim.onPacket = function(p)
    if p.message.t == "probe" then
      sim.deliver({ from = 66, channel = p.reply, reply = 0, message = {
        zn = 1, src = 66, t = "beacon", nonce = p.message.nonce, data = forged } })
    end
  end
  found = sim.call(a, function() return a.net.findRoots(2) end)
  check("forged advert is left out", #found, 2)
  sim.onPacket = nil

  -- turned off, a root stays quiet
  other.db.setConfig({ online = false })
  found = sim.call(a, function() return a.net.findRoots(2) end)
  check("offline root isn't found", #found, 1)
  other.db.setConfig({ online = true })

  local entry = certify(a, root, "alpha")
  certify(b, root, "bravo")
  check("two computers", #root.db.list(), 2)

  -- c trusts the root, so a and b are verified to it
  trustOf(c).addRoot(entry.key, entry.name, entry.host)
  c.net.listen(5000, { verified = true })
  local box = sim.inbox(c)
  check("verified sender accepted", send(a, 3, 5000, "hi"), true)
  sim.advance(1)
  check("verified event", #box, 1)
  check("peer is verified", box[1].peer.verified)
  check("peer name", box[1].peer.name, "alpha")
  check("peer root", box[1].peer.root, entry.key)

  -- expect checks who you're talking to
  a.net.listen(5000)
  check("expect the right name", send(c, 1, 5000, "x", { expect = "alpha" }), true)
  local ok, why = send(c, 1, 5000, "x", { expect = "bravo" })
  check("expect the wrong name", ok, nil)
  check("expect says why", has(tostring(why), "not 'bravo'"))

  -- no cert: not accepted on a verified port, and refused by a sender that insists
  local d = sim.computer(4)
  d.net.listen(5000)
  local dbox = sim.inbox(d)
  ok, why = send(d, 3, 5000, "x")
  check("unverified refused", ok, nil)
  check("unverified says why", has(tostring(why), "only accepts verified"))
  sim.advance(1)
  check("no event from unverified", #box, 1)
  ok = send(c, 4, 5000, "x", { verified = true })
  check("sender insists on verified", ok, nil)
  sim.advance(1)
  check("nothing sent to unverified", #dbox, 0)

  -- a certificate from a root c doesn't trust proves nothing
  local e = sim.computer(5)
  certify(e, other, "alpha")
  ok, why = send(e, 3, 5000, "x")
  check("untrusted root refused", ok, nil)

  -- nor does a copy of someone else's certificate
  local f = sim.computer(6)
  trustOf(f).installCert(trustOf(a).certs()[1])
  check("stolen certificate refused", send(f, 3, 5000, "x"), nil)
  check("stolen cert isn't a verified peer", send(c, 6, 5000, "x", { expect = "alpha" }), nil)

  -- nor does stealing a certificate along with claiming its public key
  local imp = sim.computer(9)
  imp.net.listen(5000)
  local impSeed = trustOf(imp).identity()
  local alpha = trustOf(a).certs()[1]
  local alphaKey = cryptoOf(a).fromHex(alpha.key)
  trustOf(imp).identity = function() return impSeed, alphaKey end
  trustOf(imp).installCert(alpha)
  check("impersonating a verified computer fails", send(c, 9, 5000, "x", { expect = "alpha" }), nil)

  -- nor does writing one and naming a trusted root
  local forger = sim.computer(12)
  local forgerKey = cryptoOf(forger).toHex(select(2, trustOf(forger).identity()))
  trustOf(forger).installCert({ name = "alpha", id = 12, key = forgerKey, root = entry.key, issued = sim.now(),
    expires = sim.now() + 86400000, sig = string.rep("ab", 64) })
  check("forged certificate refused", send(forger, 3, 5000, "x"), nil)

  -- a certified computer can't take over another computer's id
  local honest = sim.computer(13)
  honest.net.listen(5000)
  check("first contact with the honest computer", send(c, 13, 5000, "x"), true)
  local honestFiles = honest.files
  sim.powerOff(honest)
  local mallory = sim.computer(14)
  certify(mallory, root, "mallory")
  check("mallory has a certificate", #trustOf(mallory).certs(), 1)
  local malloryFiles = mallory.files
  sim.powerOff(mallory)
  mallory = sim.computer(13, { files = malloryFiles })
  mallory.net.listen(5000)
  local mbox = sim.inbox(mallory)
  sim.setClock(sim.now() + 3700 * 1000)
  sim.advance(2)
  ok, why = send(c, 13, 5000, "for the honest computer")
  check("certificate for another id is refused", ok, nil)
  check("says the key changed", has(tostring(why), "different key"))
  sim.advance(1)
  check("mallory got nothing", #mbox, 0)
  sim.powerOff(mallory)
  honest = sim.computer(13, { files = honestFiles })
  honest.net.listen(5000)
  check("the pin wasn't replaced", send(c, 13, 5000, "x"), true)
  sim.powerOff(honest)
  entry = sim.call(c, function() return c.net.findRoots(2) end)[2]
  entry = entry.name == "Overworld Root" and entry or sim.call(c, function() return c.net.findRoots(2) end)[1]

  -- a name can only belong to one key
  local g = sim.computer(7)
  local status, err = sim.call(g, function() return g.net.requestCertificate(entry, "alpha") end)
  check("taken name", status, nil)
  check("taken name says why", has(tostring(err), "already has"))

  -- a computer can't get a name signed without an admin approving it
  local h = sim.computer(8)
  status = sim.call(h, function() return h.net.requestCertificate(entry, "hotel") end)
  check("unapproved stays pending", status, "pending")
  check("no certificate yet", #trustOf(h).certs(), 0)
  local hKey = cryptoOf(h).toHex(select(2, trustOf(h).identity()))
  root.db.setStatus(hKey, "denied")
  status = sim.call(h, function() return h.net.requestCertificate(entry, "hotel") end)
  check("denied", status, "denied")

  -- a certificate survives a change of key only with a new signature
  local files = a.files
  sim.powerOff(a)
  files["etc/zos/net/identity"] = nil
  files["etc/zos/net/certs"] = nil
  a = sim.computer(1, { files = files })
  a.net.listen(5000)
  ok, why = send(c, 1, 5000, "x")
  check("new key without a certificate is refused", ok, nil)
  check("says the key changed", has(tostring(why), "different key"))

  -- and the old certificate doesn't help, though it's for this computer id
  trustOf(a).installCert(alpha)
  ok, why = send(c, 1, 5000, "x", { expect = "alpha" })
  check("a certificate for another key is refused", ok, nil)

  -- removing a root drops its certificates and its verification
  trustOf(c).removeRoot(entry.key)
  sim.powerOff(c)
  c = sim.computer(3, { files = c.files })
  c.net.listen(5000, { verified = true })
  check("removed root no longer verifies", send(b, 3, 5000, "x"), nil)
end

-- A clean reinstall gets rid of the identity, certificates and trusted roots.
reset()
do
  local root = rootServer(10, "Root")
  local a = sim.computer(1)
  certify(a, root, "alpha")
  local oldKey = select(2, trustOf(a).identity())
  a.env.require("keys").reset()
  check("reset removes roots", #trustOf(a).roots(), 0)
  check("reset removes certificates", #trustOf(a).certs(), 0)
  sim.powerOff(a)
  a = sim.computer(1, { files = a.files })
  check("reset gives a new identity", select(2, trustOf(a).identity()) ~= oldKey)
end

-- A computer with certificates from two roots answers to both names, and `root` tells them apart.
do
  local one, two = rootServer(10, "One"), rootServer(11, "Two")
  local a, b = sim.computer(1), sim.computer(2)
  b.net.listen(5000)
  local entryOne = certify(a, one, "alpha")
  local entryTwo = certify(a, two, "second")
  trustOf(b).addRoot(entryOne.key, entryOne.name, entryOne.host)
  trustOf(b).addRoot(entryTwo.key, entryTwo.name, entryTwo.host)
  a.net.listen(5000)
  check("expect the first name", send(b, 1, 5000, "x", { expect = "alpha" }))
  check("expect the second name", send(b, 1, 5000, "x", { expect = "second" }))
  check("root and its name", send(b, 1, 5000, "x", { expect = "alpha", root = entryOne.key }))
  check("root and another's name", send(b, 1, 5000, "x", { expect = "alpha", root = entryTwo.key }), nil)

  send(a, 2, 5000, "back")
  local msg = sim.call(b, function() return b.net.receive(5000, 5) end)
  check("peer.names has the first", msg.peer.names[entryOne.key], "alpha")
  check("peer.names has the second", msg.peer.names[entryTwo.key], "second")
end
reset()

-- One trusted root for each top-level domain.
do
  local one, two = rootServer(10, "One"), rootServer(11, "Two")
  local other = rootServer(12, "Three")
  sim.call(two, function() assert(two.db.setTld("one")) end)
  sim.call(other, function() assert(other.db.setTld("three")) end)
  local c = sim.computer(1)
  local found = sim.call(c, function() return c.net.findRoots(2) end)
  local byHost = {}
  for _, entry in ipairs(found) do byHost[entry.host] = entry end
  local function add(entry) return sim.call(c, function() return c.net.addRoot(entry) end) end

  check("adds a root", add(byHost[10]))
  check("and remembers its tld", trustOf(c).root(byHost[10].key).tld, "one")
  local ok, why = add(byHost[11])
  check("refuses a second root for a tld", ok, false)
  check("says which root owns it", type(why) == "string" and why:find("One", 1, true) ~= nil)
  check("the second isn't trusted", trustOf(c).root(byHost[11].key), nil)
  check("adding the same root again is fine", add(byHost[10]))
  check("another tld is fine", add(byHost[12]))
  sim.powerOff(two)
  local rootKey = byHost[11].key
  trustOf(c).removeRoot(byHost[10].key)
  trustOf(c).addRoot(rootKey, "Two", 11)
  ok, why = add(byHost[10])
  check("a root it can't check blocks adding", ok, false)
  check("and says so", type(why) == "string" and why:find("Couldn't check", 1, true) ~= nil)
end
reset()

-- A reply only goes to the key that asked.
do
  local a, b = sim.computer(1), sim.computer(2)
  b.net.listen(5000)
  sim.spawn(b, function()
    while true do
      local msg = b.net.receive(5000)
      if msg.payload == "swap" then msg.peer = { key = string.rep("ab", 32) } end
      b.net.reply(msg, "answer")
    end
  end)
  sim.advance(1)
  check("reply to the same key", sim.call(a, function() return a.net.request(2, 5000, "ask", { timeout = 20 }) end).payload, "answer")
  local nope = sim.call(a, function() return a.net.request(2, 5000, "swap", { timeout = 20 }) end, 60)
  check("reply to another key is refused", nope, nil)
end
reset()

-- The root only signs what the admin reviewed.
reset()
do
  local root = rootServer(10, "Root")
  local m = sim.computer(1)
  local found = sim.call(m, function() return m.net.findRoots(2) end)
  sim.call(m, function() return m.net.requestCertificate(found[1], "mallory-laptop") end)
  local key = cryptoOf(m).toHex(select(2, trustOf(m).identity()))
  sim.call(m, function() return m.net.requestCertificate(found[1], "bank") end)
  local ok, why = sim.call(root, function() return root.db.approve(key, "mallory-laptop", 1) end)
  check("a changed request isn't signed", ok, false)
  check("says why", has(tostring(why), "changed"))
  check("still pending", root.db.requests()[key].status, "pending")
  check("the reviewed name wasn't signed", root.db.requests()[key].cert, nil)

  -- nor can the name change under a signature in progress
  local thread = sim.spawn(root, function() return root.db.approve(key, "bank", 1) end)
  local entry = root.db.requests()[key]
  sim.call(m, function() return m.net.requestCertificate(found[1], "treasury") end)
  sim.run(function() return thread.done end)
  check("a change during signing isn't signed", root.db.requests()[key].cert, nil)

  -- one computer id, one key
  local requests = root.db.requests()
  check("approve the current name", sim.call(root, function() return root.db.approve(key, "treasury", 1) end), true)
  check("certified key can't rename itself", (sim.call(m, function() return m.net.requestCertificate(found[1], "other") end)), nil)
  sim.powerOff(m)
  local again = sim.computer(1) -- same id, new key
  local status, err = sim.call(again, function() return again.net.requestCertificate(found[1], "new") end)
  check("the root refuses a changed key", status, nil)
  root.env.require("keys").forgetKnown("net:1")
  status, err = sim.call(again, function() return again.net.requestCertificate(found[1], "new") end)
  check("id already certified", status, nil)
  check("says so", has(tostring(err), "Revoke"))
  root.db.setStatus(key, "revoked")
  status = sim.call(again, function() return again.net.requestCertificate(found[1], "new") end)
  check("once revoked, it can ask", status, "pending")
end

-- Trust changes during a session take effect.
reset()
do
  local root = rootServer(10, "Root")
  root.db.setConfig({ days = 0.01 }) -- about 15 minutes, well inside a session
  local a, c = sim.computer(1), sim.computer(3)
  local entry = certify(a, root, "alpha")
  sim.powerOff(root) -- so it can't be renewed
  trustOf(c).addRoot(entry.key, entry.name, entry.host)
  c.net.listen(5000, { verified = true })
  a.net.listen(5000)
  check("verified before", send(a, 3, 5000, "x"), true)
  check("expect before", send(c, 1, 5000, "x", { expect = "alpha" }), true)
  trustOf(c).removeRoot(entry.key)
  check("removed root: verified port refuses at once", send(a, 3, 5000, "x"), nil)
  check("removed root: expect refuses at once", send(c, 1, 5000, "x", { expect = "alpha" }), nil)
  trustOf(c).addRoot(entry.key, entry.name, entry.host)
  check("added back", send(c, 1, 5000, "x", { expect = "alpha" }), true)
  sim.setClock(trustOf(a).certs()[1].expires + 1000)
  sim.advance(2)
  check("expired during a session", send(c, 1, 5000, "x", { expect = "alpha" }), nil)
end

reset()
do
  -- a certificate gained during a session is seen without waiting for the session to end
  local root = rootServer(10, "Root")
  local a, c = sim.computer(1), sim.computer(3)
  a.net.listen(5000)
  c.net.listen(5000, { verified = true })
  check("session before the certificate", send(c, 1, 5000, "x"), true)
  local entry = certify(a, root, "alpha")
  trustOf(c).addRoot(entry.key, entry.name, entry.host)
  check("verified port accepts it", send(a, 3, 5000, "x"), true)
  check("expect finds the new certificate", send(c, 1, 5000, "x", { expect = "alpha" }), true)
end

reset()
do
  -- the same, when the computer without the session news is the one that asks first
  local root = rootServer(10, "Root")
  local a, c = sim.computer(1), sim.computer(3)
  a.net.listen(5000)
  c.net.listen(5000)
  check("session before the certificate", send(c, 1, 5000, "x"), true)
  local entry = certify(a, root, "alpha")
  trustOf(c).addRoot(entry.key, entry.name, entry.host)
  check("a refused send renegotiates", send(c, 1, 5000, "x", { expect = "alpha" }), true)
end

-- A computer that's only up for minutes still renews.
reset()
do
  local root = rootServer(10, "Root")
  local a = sim.computer(1)
  certify(a, root, "alpha")
  local first = trustOf(a).certs()[1]
  local files = a.files
  sim.powerOff(a)
  sim.setClock(sim.now() + 25 * 24 * 3600 * 1000)
  sim.advance(1)
  a = sim.computer(1, { files = files })
  sim.advance(60)
  check("renewed soon after boot", trustOf(a).certs()[1].expires > first.expires)
end

-- Expiry and renewal.
reset()
do
  local root = rootServer(10, "Root")
  local a, c = sim.computer(1), sim.computer(3)
  local entry = certify(a, root, "alpha")
  trustOf(c).addRoot(entry.key, entry.name, entry.host)
  c.net.listen(5000, { verified = true })

  -- 25 days on, the renewal service swaps it for a new one by itself
  local first = trustOf(a).certs()[1]
  sim.setClock(sim.now() + 25 * 24 * 3600 * 1000)
  sim.advance(3700)
  local second = trustOf(a).certs()[1]
  check("certificate renewed by itself", second.expires > first.expires)
  check("renewed certificate works", send(a, 3, 5000, "x"), true)

  -- an expired one doesn't verify
  sim.powerOff(root)
  local kept = trustOf(a).certs()[1]
  sim.setClock(kept.expires + 1000)
  sim.advance(2)
  local ok = send(a, 3, 5000, "y")
  check("expired certificate refused", ok, nil)
end

-- Revocation stops renewal and frees the name.
reset()
do
  local root = rootServer(10, "Root")
  local a, b = sim.computer(1), sim.computer(2)
  local entry = certify(a, root, "alpha")
  local key = cryptoOf(a).toHex(select(2, trustOf(a).identity()))
  root.db.setStatus(key, "revoked")
  check("revoked can't renew", sim.call(a, function() return a.net.requestCertificate(entry, "alpha") end), "denied")
  trustOf(b).addRoot(entry.key, entry.name, entry.host)
  check("revoked name is free", sim.call(b, function() return b.net.requestCertificate(entry, "alpha") end), "pending")
end

-- A computer talking to itself ------------------------------------------------

reset()
do
  local a = sim.computer(1, { modems = {} }) -- none of this needs a modem
  local serving = {}
  a.net.listen(5000)
  a.net.listen(6000, { modem = "back" }) -- no modem is involved, so this can't keep it out
  sim.spawn(a, function()
    while true do
      local msg = a.net.receive(5000)
      serving[#serving + 1] = msg
      if type(msg.payload) == "table" and msg.payload.ask then
        msg.payload.ask = "changed by the receiver"
        a.net.reply(msg, { echo = msg.payload.n })
      end
    end
  end)

  check("send to self", send(a, 1, 5000, "hello me"), true)
  sim.advance(1)
  local msg = serving[1]
  check("self message arrives", msg and msg.payload, "hello me")
  check("from self", msg.from, 1)
  check("port", msg.port, 5000)
  check("no modem side", msg.side, nil)
  check("peer is this computer", msg.peer.key, cryptoOf(a).toHex(select(2, trustOf(a).identity())))
  check("not verified without a certificate", msg.peer.verified, false)

  local ask = { ask = "question", n = 7 }
  local reply, err = sim.call(a, function() return a.net.request(1, 5000, ask) end)
  check("request to self", reply and reply.payload.echo, 7)
  check("no error", err, nil)
  check("reply is from self", reply.from, 1)
  check("payload was copied", ask.ask, "question")
  check("reply keeps the port", reply.port, 5000)

  local ok, why = send(a, 1, 5001, "x")
  check("closed port on self", ok, nil)
  check("closed port says why", has(tostring(why), "closed"))
  ok, why = send(a, 1, 30001, "x")
  check("own home channel stays closed", ok, nil)
  ok, why = send(a, 1, 5000, function() end)
  check("self payloads are checked", ok, nil)
  ok, why = send(a, 1, 5000, string.rep("x", 40000))
  check("self payloads have the same limit", has(tostring(why), "too big"))
  check("modem option doesn't apply", send(a, 1, 6000, "x"), true)

  -- nobody answers: the time limit still applies, and a late reply finds nothing waiting
  local late = sim.call(a, function() return a.net.receive(6000, 1) end)
  check("message to the modem-limited port", late and late.payload, "x")
  sim.spawn(a, function() a.net.request(1, 6000, "ignored", { timeout = 1 }) end)
  local ignored = sim.call(a, function() return a.net.receive(6000, 1) end)
  local none
  none, why = sim.call(a, function() return a.net.request(1, 6000, "again", { timeout = 1 }) end)
  check("no reply from self", none, nil)
  check("no reply says why", has(tostring(why), "didn't reply"))
  sim.advance(2)
  local nope = sim.call(a, function() return a.net.reply(ignored, "too late") end)
  check("a late reply fails", nope, nil)

  ok, why = send(a, 1, 5000, "x", { key = string.rep("ab", 32) })
  check("key is checked on self", has(tostring(why), "different key"))
  ok, why = send(a, 1, 5000, "x", { verified = true })
  check("verified is checked on self", has(tostring(why), "no certificate"))
  ok, why = send(a, 1, 5000, "x", { expect = "someone" })
  check("expect is checked on self", has(tostring(why), "not 'someone'"))
  a.net.listen(5002, { verified = true })
  ok, why = send(a, 1, 5002, "x")
  check("verified port refuses an uncertified self", has(tostring(why), "only accepts verified"))
end

-- Packets claiming to be from this computer can't pass as its own messages.
reset()
do
  local a = sim.computer(1)
  a.net.listen(5000)
  local box = sim.inbox(a)
  local probes = {}
  sim.spawn(a, function()
    while true do probes[#probes + 1] = select(2, a.env.os.pullEventRaw("net_probe")) end
  end)
  sim.deliver({ from = 66, channel = 5000, reply = 0, message = { zn = 1, src = 1, dst = 1, t = "probe", nonce = "x" } })
  sim.deliver({ from = 66, channel = 5000, reply = 0, message = { zn = 1, src = 1, dst = 1, t = "data", sid = "x", seq = 1 } })
  sim.advance(1)
  check("forged self packets are dropped", #box + #probes, 0)
end

-- Broadcasts reach this computer as well as the others.
reset()
do
  local a, b = sim.computer(1), sim.computer(2)
  local function answers(c)
    c.net.listen(5000)
    sim.spawn(c, function()
      while true do
        local _, probe = c.env.os.pullEventRaw("net_probe")
        c.net.answerProbe(probe, { name = "computer " .. c.id, port = probe.port })
      end
    end)
  end
  answers(a)
  answers(b)
  local got = sim.call(a, function() return a.net.probe(5000, 1) end)
  local from = {}
  for _, answer in ipairs(got) do from[answer.from] = answer.data.name end
  check("two answers", #got, 2)
  check("its own answer", from[1], "computer 1")
  check("the other's answer", from[2], "computer 2")
  check("a port nobody listens on", #sim.call(a, function() return a.net.probe(5001, 1) end), 0)
end

-- A root server on the computer it serves.
reset()
do
  local root = rootServer(10, "Home Root")
  local found = sim.call(root, function() return root.net.findRoots(2) end)
  check("finds its own root", #found, 1)
  check("its host is this computer", found[1].host, 10)
  check("trusts its own root", sim.call(root, function() return root.net.addRoot(found[1]) end))
  local entry = certify(root, root, "home.home-root")
  local result = sim.call(root, function() return root.net.resolve("home.home-root") end)
  check("resolves its own hostname", result and result.id, 10)

  root.net.listen(5000, { verified = true })
  sim.spawn(root, function()
    while true do
      local msg = root.net.receive(5000)
      root.net.reply(msg, { isHost = root.net.isHost(msg.peer, "home.home-root") })
    end
  end)
  local reply = sim.call(root, function() return root.net.requestHost("home.home-root", 5000, {}, { timeout = 10 }) end)
  check("reaches its own hostname on a verified port", reply and reply.payload.isHost, true)
  check("and the peer is verified", reply and reply.peer.name, "home.home-root")
  check("another computer still gets a refusal", (send(sim.computer(1), 10, 5000, "x")), nil)
  check("entry", entry.host, 10)
end

-- A busy worker doesn't lose packets ------------------------------------------

reset()
do
  local a, b, c = sim.computer(1), sim.computer(2), sim.computer(3)
  b.net.listen(5000)
  local box = sim.inbox(b)
  local t1 = sim.spawn(a, function() return a.net.send(2, 5000, "from a") end)
  local t2 = sim.spawn(c, function() return c.net.send(2, 5000, "from c") end)
  sim.run(function() return t1.done and t2.done end)
  sim.advance(1)
  check("two handshakes at once", #box, 2)

  -- the home channel only takes replies, even with a made-up reply id
  b.net.listen(5000, { verified = true })
  local home = 30000 + 2 % 30000
  local before = #box
  local nope = send(a, 2, home, "sneaking in")
  check("home channel refuses messages", nope, nil)
  nope = send(a, 2, home, "still sneaking", { re = "0123456789abcdef" })
  check("home channel refuses unknown replies", nope, nil)
  sim.advance(1)
  check("nothing got through the home channel", #box, before)
  b.net.listen(5000)

  -- a flood of hellos doesn't stop established sessions
  for i = 1, 200 do
    sim.deliver({ from = 66, channel = 5000, reply = 0, message = {
      zn = 1, src = 500 + i, dst = 2, t = "hello", eph = cryptoOf(a).toHex(string.rep(string.char(i % 200 + 5), 32)) } })
  end
  check("session works during a flood", send(a, 2, 5000, "still here"), true)
end

if failed > 0 then
  print(("%d passed, %d FAILED"):format(passed, failed))
  os.exit(1)
end
print(("net: all %d passed"):format(passed))
