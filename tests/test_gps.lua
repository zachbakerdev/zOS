-- End-to-end tests of the gps library, the GPS Server app and the root server's GPS certificates,
-- using simulated computers at real positions and an attacker on the wire.
-- Run from the repository root: luajit tests/test_gps.lua
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

local function reset()
  for _, c in pairs(sim.computers) do sim.powerOff(c) end
  sim.wire, sim.onPacket = {}, nil
end

local function cryptoOf(c) return c.env.require("crypto") end
local function trustOf(c) return c.env.require("trust") end
local function gpsOf(c) return c.env.require("gps") end

local function rootServer(id, name)
  local c = sim.computer(id)
  c.appDir = "apps/root-server/"
  c.db = c.env.require("rootdb")
  sim.call(c, function() c.db.setup(name) end)
  local fn = assert(loadfile("apps/root-server/service.lua"))
  setfenv(fn, c.env)
  sim.spawn(c, fn)
  return c
end

local function rootKey(root)
  return cryptoOf(root).toHex(select(2, root.db.keypair()))
end

local function trustRoot(c, root)
  trustOf(c).addRoot(rootKey(root), root.db.config().name, root.id)
end

-- A computer at `pos` running GPS Server, asking `root` to vouch for it at `claim` (default `pos`).
local function gpsHost(id, pos, root, claim)
  local c = sim.computer(id, { pos = pos })
  trustRoot(c, root)
  c.appDir = "apps/gps-server/"
  c.db = c.env.require("gpsdb")
  local at = claim or pos
  sim.call(c, function()
    c.db.keypair()
    c.db.setPosition(at[1], at[2], at[3], rootKey(root))
  end)
  local fn = assert(loadfile("apps/gps-server/service.lua"))
  setfenv(fn, c.env)
  sim.spawn(c, fn, { id = "gps-server" })
  return c
end

local function approveAll(root)
  sim.advance(12) -- the hosts ask
  for _, entry in ipairs(root.db.gpsList()) do
    if entry.status == "pending" then
      sim.call(root, function()
        return root.db.approveGps(entry.key, entry.gpsKey, entry.x, entry.y, entry.z, entry.from)
      end)
    end
  end
  sim.advance(12) -- and pick up their certificates
end

local function client(id, pos, root, opts)
  opts = opts or {}
  opts.pos = pos
  local c = sim.computer(id, opts)
  if root then trustRoot(c, root) end
  return c
end

local function locate(c)
  return sim.call(c, function() return gpsOf(c).locate() end)
end

local function at(name, c, want)
  local x, y, z = locate(c)
  if want then
    check(name, x and (x .. "," .. y .. "," .. z) or "nil", table.concat(want, ","))
  else
    check(name, x, nil)
  end
end

-- The last "here" answer each host sent, by host id.
local function answers()
  local out = {}
  for _, packet in ipairs(sim.wire) do
    local m = packet.message
    if type(m) == "table" and m.zg == 1 and m.t == "here" then out[packet.from] = sim.copy(m) end
  end
  return out
end

-- Send `make(nonce)` from `pos` in answer to every GPS request, before the real hosts answer.
local function inject(pos, make)
  sim.onPacket = function(packet)
    local m = packet.message
    if type(m) == "table" and m.zg == 1 and m.t == "where" then
      for _, message in ipairs(make(m.nonce)) do
        message.nonce = m.nonce
        sim.deliver({ from = 999, pos = pos, channel = packet.reply, reply = 4203, message = message })
      end
    end
  end
end

local HOSTS = { { 0, 70, 0 }, { 40, 90, 0 }, { 0, 60, 40 }, { 40, 80, 40 }, { 20, 100, -30 } }
local HERE = { 13, 64, -7 }

-- Getting a position ---------------------------------------------------------

do
  local root = rootServer(1, "Root")
  local hosts = {}
  for i, pos in ipairs(HOSTS) do hosts[i] = gpsHost(10 + i, pos, root) end
  local me = client(30, HERE, root)

  sim.advance(12)
  check("hosts wait for approval", hosts[1].db.config().status, "pending")
  check("root lists every request", #root.db.gpsList(), 5)
  at("nothing before the root approves", me, nil)

  approveAll(root)
  for i, host in ipairs(hosts) do check("host " .. i .. " has its certificate", host.db.usableCert() ~= nil) end
  at("finds its position", me, HERE)
  at("again, from remembered signatures", me, HERE)

  local elsewhere = client(31, { -25, 75, 18 }, root)
  at("another computer finds its own", elsewhere, { -25, 75, 18 })

  local stranger = client(32, HERE, nil)
  at("a computer that doesn't trust the root gets nil", stranger, nil)

  local wired = client(33, HERE, root, { modems = { back = { open = {}, wired = true } } })
  at("a wired modem can't measure distance", wired, nil)
  check("so it isn't asked", #gpsOf(wired).wirelessModems(), 0)

  local noModem = client(34, HERE, root, { modems = {} })
  at("no modem gets nil", noModem, nil)

  -- Timestamps are signed again before they run out.
  sim.advance(660)
  at("works after the first timestamps expire", me, HERE)

  -- Attacks ----------------------------------------------------------------

  local real = answers()
  local h1 = real[hosts[1].id]
  check("answers carry a certificate and stamp", type(h1.cert) == "table" and type(h1.stamp) == "table")

  -- A host's real answer passed on from somewhere else: that host is heard at two distances, so
  -- it's left out, and the other four still agree.
  inject({ 100, 64, 100 }, function() return { sim.copy(h1) } end)
  at("a relayed answer drops that host, not the fix", me, HERE)

  -- Relays placed so that each host seems as far away as it would be from somewhere else would
  -- move the computer there, if the first answer from each host were believed. Each host is also
  -- heard from where it really is, so none of them count.
  local FAKE = { -60, 64, 25 }
  sim.onPacket = function(packet)
    local m = packet.message
    if type(m) == "table" and m.zg == 1 and m.t == "where" then
      for i, host in ipairs(hosts) do
        local dx, dy, dz = FAKE[1] - HOSTS[i][1], FAKE[2] - HOSTS[i][2], FAKE[3] - HOSTS[i][3]
        local relayAt = { HERE[1] + math.sqrt(dx * dx + dy * dy + dz * dz), HERE[2], HERE[3] }
        local message = sim.copy(real[host.id])
        message.nonce = m.nonce
        sim.deliver({ from = 999, pos = relayAt, channel = packet.reply, reply = 4203, message = message })
      end
    end
  end
  at("relaying every host doesn't move the computer", me, nil)

  -- From here on there are four hosts, which all have to count for a fix, so an answer that was
  -- wrongly believed would show.
  sim.powerOff(hosts[4])
  sim.onPacket = nil
  at("four hosts still work", me, HERE)

  -- A certificate with a changed position fails its signature, and the real answer still counts.
  inject(HOSTS[1], function() -- from where host 1 is, so the distance alone doesn't give it away
    local forged = sim.copy(h1)
    forged.cert.x = forged.cert.x + 10
    return { forged }
  end)
  at("a changed certificate is ignored", me, HERE)

  -- A root this computer doesn't trust can certify anything.
  local fakeRoot = rootServer(2, "Fake")
  local fakes = sim.call(fakeRoot, function()
    local out = {}
    local seed, public = fakeRoot.db.keypair()
    for i, pos in ipairs({ { 500, 64, 0 }, { 0, 64, 500 }, { 500, 100, 500 }, { 250, 0, 250 }, { 1, 2, 3 } }) do
      local _, hostPublic = cryptoOf(fakeRoot).signingKeypair()
      out[i] = {
        zg = 1, t = "here",
        cert = trustOf(fakeRoot).issueGps(seed, public, 50 + i, cryptoOf(fakeRoot).toHex(hostPublic),
          pos[1], pos[2], pos[3], 86400000),
        stamp = sim.copy(h1.stamp),
      }
    end
    return out
  end)
  inject({ 13, 64, -7 }, function() return sim.copy(fakes) end)
  at("answers from an untrusted root are ignored", me, HERE)
  sim.onPacket = nil

  -- Old answers replayed from the right places: the stamps have run out.
  local stale = answers()
  for _, host in ipairs(hosts) do if not host.off then sim.powerOff(host) end end
  sim.advance(601)
  sim.onPacket = function(packet)
    local m = packet.message
    if type(m) == "table" and m.t == "where" then
      for i, host in ipairs(hosts) do
        local old = sim.copy(stale[host.id])
        old.nonce = m.nonce
        sim.deliver({ from = 999, pos = HOSTS[i], channel = packet.reply, reply = 4203, message = old })
      end
    end
  end
  at("replayed answers with expired stamps are ignored", me, nil)

  -- The same, with a new time on each stamp: the host's signature doesn't match it.
  sim.onPacket = function(packet)
    local m = packet.message
    if type(m) == "table" and m.t == "where" then
      for i, host in ipairs(hosts) do
        local old = sim.copy(stale[host.id])
        old.nonce, old.stamp.time = m.nonce, sim.now()
        sim.deliver({ from = 999, pos = HOSTS[i], channel = packet.reply, reply = 4203, message = old })
      end
    end
  end
  at("a stamp with a new time and an old signature is ignored", me, nil)
  reset()
end

-- Hosts that are wrong -------------------------------------------------------

do
  local root = rootServer(1, "Root")
  for i, pos in ipairs(HOSTS) do gpsHost(10 + i, pos, root) end
  -- Approved at a position it isn't at, for example after being moved.
  gpsHost(20, { 10, 70, 10 }, root, { 30, 70, -20 })
  local me = client(30, HERE, root)
  approveAll(root)
  at("five good hosts outvote a wrong one", me, HERE)
  reset()
end

do
  local root = rootServer(1, "Root")
  for i = 1, 3 do gpsHost(10 + i, HOSTS[i], root) end
  gpsHost(20, { 10, 70, 10 }, root, { 30, 70, -20 })
  local me = client(30, HERE, root)
  approveAll(root)
  at("three good and one wrong gives nil, not a wrong position", me, nil)
  reset()
end

do
  local root = rootServer(1, "Root")
  gpsHost(11, HOSTS[1], root)
  gpsHost(12, HOSTS[2], root)
  local me = client(30, HERE, root)
  approveAll(root)
  at("two hosts aren't enough", me, nil)
  reset()
end

do
  local root = rootServer(1, "Root")
  local hosts = {}
  -- Not 1-4, which are all in one plane.
  for i, n in ipairs({ 1, 2, 3, 5 }) do hosts[i] = gpsHost(10 + i, HOSTS[n], root) end
  local me = client(30, HERE, root)
  approveAll(root)
  at("four hosts are enough", me, HERE)
  sim.call(hosts[1], function() hosts[1].db.setConfig({ online = false }) end)
  at("a host with answering off is missing, and three can't settle it", me, nil)
  sim.call(hosts[1], function() hosts[1].db.setConfig({ online = true }) end)
  at("and back on", me, HERE)

  -- Moving a host takes a new approval, and until then it doesn't answer.
  sim.call(hosts[1], function() hosts[1].db.setPosition(1, 70, 0, rootKey(root)) end)
  check("moving drops the certificate", hosts[1].db.usableCert(), nil)
  sim.advance(12)
  check("the root has the new position waiting", root.db.gpsRequests()[cryptoOf(hosts[1]).toHex(
    select(2, trustOf(hosts[1]).identity()))].status, "pending")
  reset()
end

-- The screens ----------------------------------------------------------------

do
  local function run(c, path, ...)
    local fn = assert(loadfile(path))
    setfenv(fn, c.env)
    return sim.spawn(c, fn, ...)
  end
  local function key(c, name) c.env.os.queueEvent("key", c.env.keys[name]) end
  local function char(c, ch) c.env.os.queueEvent("char", ch) end
  local function line(c, text) c.env.os.queueEvent("sim_line", text) end
  local function pick(c, n)
    for _ = 1, n do key(c, "down") end
    key(c, "enter")
  end
  local function screenHas(c, text)
    local ok, err = pcall(sim.run, function() return c.screenText():find(text, 1, true) ~= nil end, 120)
    if not ok then
      print("Waiting for '" .. text .. "' on computer " .. c.id .. ", the screen says:\n" .. c.screenText())
      error(err, 0)
    end
    return true
  end
  local admin = { user = "admin", admin = true }

  local root = rootServer(1, "Root")
  local host = sim.computer(11, { pos = HOSTS[1] })
  host.appDir = "apps/gps-server/"
  host.db = host.env.require("gpsdb")
  run(host, "apps/gps-server/service.lua", { id = "gps-server" })

  local refused = run(host, "apps/gps-server/main.lua", { user = "guest", admin = false })
  check("needs an admin", screenHas(host, "Only administrators"))
  key(host, "enter")
  sim.run(function() return refused.done end)

  local app = run(host, "apps/gps-server/main.lua", admin)
  check("explains", screenHas(host, "A root server vouches"))
  key(host, "enter")
  check("needs a root first", screenHas(host, "doesn't trust a root server"))
  key(host, "enter")
  check("not set up yet", screenHas(host, "Not set up yet"))

  trustRoot(host, root)
  pick(host, 1)
  check("asks for X", screenHas(host, "Enter the coordinates of this computer"))
  line(host, "1.5")
  check("refuses a fraction", screenHas(host, "Enter a whole number"))
  line(host, "0")
  line(host, "70")
  line(host, "0")
  check("says where", screenHas(host, "If that's wrong"))
  check("asks to send it", screenHas(host, "Ask Root to vouch for it?"))
  char(host, "y")
  check("waits for approval", screenHas(host, "Waiting for the root server's administrator"))
  check("shows the fingerprint", screenHas(host, cryptoOf(host).fingerprint(select(2, trustOf(host).identity()))))

  sim.run(function() return #root.db.gpsList() > 0 end)
  local rootApp = run(root, "apps/root-server/main.lua", admin)
  check("root shows it waiting", screenHas(root, "GPS hosts (1 waiting)"))
  pick(root, 1)
  check("listed by computer and place", screenHas(root, "#11 0, 70, 0  [pending]"))
  key(root, "enter")
  check("review says where", screenHas(root, "wants to be a GPS host at 0, 70, 0"))
  char(root, "y")
  check("signed", screenHas(root, "Signed."))
  key(root, "enter")
  check("listed as issued", screenHas(root, "#11 0, 70, 0  [issued]"))

  check("host hears back", screenHas(host, "Approved. This host now answers at 0, 70, 0."))
  key(host, "enter")
  check("serving", screenHas(host, "Serving 0, 70, 0"))
  key(host, "home")
  key(host, "enter")
  check("details", screenHas(host, "GPS key fingerprint"))
  char(host, "q")
  check("answering can be turned off", screenHas(host, "Answering: on"))
  key(host, "home")
  pick(host, 2)
  check("is off", screenHas(host, "Answering is off"))
  check("saved", host.db.config().online, false)

  -- Revoking on the root
  key(root, "enter")
  check("root details", screenHas(root, "R: revoke"))
  char(root, "r")
  check("asks to revoke", screenHas(root, "Revoke this GPS host?"))
  char(root, "y")
  check("revoked", screenHas(root, "[revoked]"))
  check("revoked in the db", root.db.gpsList()[1].status, "revoked")
  check("app still running", not app.done and not rootApp.done)
  reset()
end

-- Geometry -------------------------------------------------------------------

do
  local c = sim.computer(1)
  local gps = gpsOf(c)
  local function hostsAround(point, positions)
    local out = {}
    for i, p in ipairs(positions) do
      local dx, dy, dz = p[1] - point[1], p[2] - point[2], p[3] - point[3]
      out[i] = { pos = p, distance = math.sqrt(dx * dx + dy * dy + dz * dz) }
    end
    return out
  end
  local flat = { { 0, 64, 0 }, { 30, 64, 0 }, { 0, 64, 30 } }
  check("three hosts, on their plane: one answer", gps.solve(hostsAround({ 7, 64, 9 }, flat)), 7)
  check("three hosts, off their plane: two answers, so nil", gps.solve(hostsAround({ 7, 80, 9 }, flat)), nil)
  local level = { { 0, 64, 0 }, { 30, 64, 0 }, { 0, 64, 30 }, { 30, 64, 30 } }
  check("all at one height: mirror images, so nil", gps.solve(hostsAround({ 7, 80, 9 }, level)), nil)
  local inLine = { { 0, 64, 0 }, { 10, 64, 0 }, { 20, 64, 0 }, { 30, 64, 0 } }
  check("in a line: nil", gps.solve(hostsAround({ 7, 80, 9 }, inLine)), nil)
  check("four in one plane: mirror images, so nil", gps.solve(hostsAround(HERE, { HOSTS[1], HOSTS[2], HOSTS[3], HOSTS[4] })), nil)
  local split = hostsAround(HERE, HOSTS)
  for i = 1, 4 do
    local wrong = hostsAround({ 100 + 37 * i, 20 * i, -90 + 11 * i }, { { 300 + i, 10 * i, 7 * i } })[1]
    split[#split + 1] = wrong
  end
  check("five agree out of nine", gps.solve(split), HERE[1])
  split[#split + 1] = hostsAround({ 5, 5, 5 }, { { 222, 64, 222 } })[1]
  check("five agree out of ten: not a majority, so nil", gps.solve(split), nil)
  local x, y, z = gps.solve(hostsAround({ -3, 12, 250 }, HOSTS))
  check("solves far away too", x .. "," .. y .. "," .. z, "-3,12,250")
  reset()
end

-- The root server's side -----------------------------------------------------

do
  local root = rootServer(1, "Root")
  local db = root.db
  local key, gpsKey = string.rep("a", 64), string.rep("b", 64)
  local function ask(x, y, z, k) return sim.call(root, function() return db.handleGps({ key = k or gpsKey, x = x, y = y, z = z }, key, 7) end) end

  check("a bad key is refused", ask(1, 2, 3, "nope").status, "error")
  check("a fractional position is refused", ask(1.5, 2, 3).status, "error")
  check("a position outside the world is refused", ask(1, 2, 40000000).status, "error")
  check("a string position is refused", ask("1", 2, 3).status, "error")
  check("a good request waits", ask(1, 2, 3).status, "pending")
  check("asking again still waits", ask(1, 2, 3).status, "pending")
  check("an approval of what wasn't shown fails", sim.call(root, function() return db.approveGps(key, gpsKey, 9, 9, 9, 7) end), false)
  check("approving works", sim.call(root, function() return db.approveGps(key, gpsKey, 1, 2, 3, 7) end), true)
  local reply = ask(1, 2, 3)
  check("then it's issued", reply.status, "issued")
  check("for that place", reply.cert.x .. "," .. reply.cert.y .. "," .. reply.cert.z, "1,2,3")
  check("signed by the root", sim.call(root, function() return trustOf(root).gpsCertIntact(reply.cert) end), true)
  check("and the same one again, without signing", ask(1, 2, 3).cert.sig, reply.cert.sig)

  sim.setClock(sim.now() + 16 * 86400000)
  local renewed = ask(1, 2, 3)
  check("renewed once half used", renewed.cert.sig ~= reply.cert.sig)
  check("renewal needs no approval", renewed.status, "issued")

  check("moving asks for approval again", ask(5, 2, 3).status, "pending")
  sim.call(root, function() db.setGpsStatus(key, "denied") end)
  check("refused stays refused", ask(1, 2, 3).status, "denied")
  sim.call(root, function() db.forgetGps(key) end)
  check("forgotten can ask again", ask(1, 2, 3).status, "pending")
  sim.call(root, function() db.approveGps(key, gpsKey, 1, 2, 3, 7) end)
  sim.call(root, function() db.setGpsStatus(key, "revoked") end)
  check("revoked is refused", ask(1, 2, 3).status, "denied")

  check("a name certificate is separate", db.requests()[key], nil)
  sim.call(root, function() db.setup("Root") end)
  check("a new root key forgets GPS hosts", #db.gpsList(), 0)
  reset()
end

print(failed == 0 and ("gps: all " .. passed .. " passed") or ("gps: " .. failed .. " failed, " .. passed .. " passed"))
if failed > 0 then os.exit(1) end
