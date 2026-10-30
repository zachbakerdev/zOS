-- End-to-end tests of hostnames and the Mail and Mail Server apps: root servers, mail servers and
-- clients on simulated computers, with attackers on the wire. Run from the repository root:
-- luajit tests/test_mail.lua
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

local function has(s, text)
  return type(s) == "string" and s:find(text, 1, true) ~= nil
end

local function trustOf(c) return c.env.require("trust") end
local function cryptoOf(c) return c.env.require("crypto") end

local function keyOf(c)
  return cryptoOf(c).toHex(select(2, trustOf(c).identity()))
end

local function run(c, path, ...)
  local fn = assert(loadfile(path))
  setfenv(fn, c.env)
  return sim.spawn(c, fn, ...)
end

local function rootServer(id, name, tld)
  local c = sim.computer(id)
  c.appDir = "apps/root-server/"
  c.db = c.env.require("rootdb")
  sim.call(c, function() c.db.setup(name, tld) end)
  run(c, "apps/root-server/service.lua")
  sim.advance(1)
  return c
end

-- Trust a root, as an admin who compared its fingerprint would.
local function trustRoot(c, root)
  local found = sim.call(c, function() return c.net.findRoots(2) end)
  for _, entry in ipairs(found) do
    if entry.host == root.id then
      trustOf(c).addRoot(entry.key, entry.name, entry.host)
      return entry
    end
  end
  error("root " .. root.id .. " wasn't found")
end

local function approve(root, c, name)
  return sim.call(root, function() return root.db.approve(keyOf(c), name, c.id) end)
end

local function hostname(c, root, name)
  local entry = trustRoot(c, root)
  check("pending first: " .. name, sim.call(c, function() return c.net.requestCertificate(entry, name) end), "pending")
  check("approved: " .. name, approve(root, c, name), true)
  check("issued: " .. name, sim.call(c, function() return c.net.requestCertificate(entry, name) end), "issued")
  return entry
end

-- A computer running the mail server's service, with a hostname from `root`.
local function mailServer(id, root, name, opts)
  local c = sim.computer(id, opts)
  c.appDir = "apps/mail-server/"
  c.db = c.env.require("maildb")
  local entry = hostname(c, root, name)
  c.db.setHostname(name, entry.key)
  c.service = run(c, "apps/mail-server/service.lua")
  sim.advance(1)
  return c
end

local function restartMail(c)
  local files = c.files
  sim.powerOff(c)
  local again = sim.computer(c.id, { files = files })
  again.appDir = "apps/mail-server/"
  again.db = again.env.require("maildb")
  again.service = run(again, "apps/mail-server/service.lua")
  sim.advance(1)
  return again
end

local function account(server, user, password)
  check("account " .. user, sim.call(server, function()
    return server.db.createAccount(user, password or "correct horse")
  end), true)
end

local function clientComputer(id, roots)
  local c = sim.computer(id)
  c.appDir = "apps/mail/"
  c.client = c.env.require("mailclient")
  c.session = { user = "me", secretKey = string.rep("k", 32) }
  for _, root in ipairs(roots) do trustRoot(c, root) end
  return c
end

local function signIn(c, address, password)
  return sim.call(c, function() return c.client.signIn(c.session, address, password or "correct horse") end, 120)
end

local function op(c, signedIn, name, fields)
  return sim.call(c, function() return c.client.call(signedIn, name, fields) end, 120)
end

local function send(c, signedIn, to, subject, body)
  return op(c, signedIn, "send", { to = to, subject = subject, body = body })
end

local function inbox(server, user)
  return server.db.index(user)
end

local function reset()
  for _, c in pairs(sim.computers) do sim.powerOff(c) end
  sim.wire, sim.onPacket = {}, nil
end

-- Parsing ---------------------------------------------------------------------

do
  local c = sim.computer(1)
  local t = trustOf(c)
  check("a hostname", select(2, t.parseHost("zmail.root-a")), "root-a")
  for _, bad in ipairs({ "zmail", "a.b.c", ".root-a", "zmail.", "Zmail.root-a", "-a.root", "a b.root", "a/b.root",
    string.rep("a", 10) .. "." .. string.rep("b", 16), "" }) do
    check("not a hostname: " .. bad, t.parseHost(bad), nil)
  end
  check("not even text", t.parseHost(5), nil)
  check("tld from a name", t.tldFromName("Root A"), "root-a")
  check("tld is cut to fit", t.validTld(t.tldFromName("The Very Long Name Of A Root")))
  check("tld with nothing usable", t.tldFromName("___"), "root")
  check("tld with no bad ends", t.tldFromName("  Root!  "), "root")
end
reset()

-- Getting a hostname ----------------------------------------------------------

do
  local root = rootServer(10, "Root A")
  check("default tld", root.db.config().zone.tld, "root-a")
  local c = sim.computer(1)
  local entry = trustRoot(c, root)
  check("asks the root for its tld", sim.call(c, function() return c.net.tldOf(entry) end), "root-a")
  check("remembers it", trustOf(c).root(entry.key).tld, "root-a")

  local function ask(name) return sim.call(c, function() return c.net.requestCertificate(entry, name) end) end
  local status, why = ask("zmail.root-b")
  check("another tld is refused", status, nil)
  check("says which", has(why, "end in .root-a"))
  status, why = ask("a.b.root-a")
  check("nested name is refused", status, nil)
  check("says what they look like", has(why, "look like"))
  check("a plain name still works", ask("plain"), "pending")
  check("the hostname is pending", ask("zmail.root-a"), "pending")

  -- renaming the root leaves hostnames alone
  sim.call(root, function() root.db.rename("Something Else") end)
  check("rename keeps the tld", root.db.config().zone.tld, "root-a")

  local ok, reason = sim.call(root, function() return root.db.setTld("other") end)
  check("tld can't change under a request", ok, false)
  check("says what's using it", has(reason, "zmail.root-a"))

  check("approved", approve(root, c, "zmail.root-a"), true)
  check("issued", ask("zmail.root-a"), "issued")
  check("certificate name is the hostname", trustOf(c).cert(entry.key).name, "zmail.root-a")
  ok = sim.call(root, function() return root.db.setTld("other") end)
  check("tld can't change under a hostname", ok, false)

  -- it renews like any other certificate
  local before = trustOf(c).cert(entry.key).expires
  sim.setClock(sim.now() + 25 * 24 * 3600 * 1000)
  check("renewed", ask("zmail.root-a"), "issued")
  check("for longer", trustOf(c).cert(entry.key).expires > before)

  local d = sim.computer(2)
  trustRoot(d, root)
  local found = sim.call(d, function() return d.net.resolve("zmail.root-a") end)
  check("resolves to the computer", found.id, 1)
  check("with its key", found.key, keyOf(c))
  local nope, err = sim.call(d, function() return d.net.resolve("ghost.root-a") end)
  check("unknown host", nope, nil)
  check("says so", has(err, "no host called"))
  nope, err = sim.call(d, function() return d.net.resolve("x.root-z") end)
  check("unknown tld", nope, nil)
  check("says which tld", has(err, ".root-z"))
  check("rubbish isn't looked up", (sim.call(d, function() return d.net.resolve("not a host") end)), nil)

  -- freed once revoked
  root.db.setStatus(keyOf(c), "revoked")
  check("revoked host is gone", (sim.call(d, function() return d.net.resolve("zmail.root-a") end)), nil)
end
reset()

-- A root from before top-level domains gets one and can keep renewing old dotted names
do
  local root = rootServer(10, "Old Root")
  local c = sim.computer(1)
  local entry = trustRoot(c, root)
  sim.call(c, function() return c.net.requestCertificate(entry, "plain") end)
  local requests = root.db.requests()
  requests[keyOf(c)].name = "old.name"
  root.files["etc/zos/root-server/requests"] = root.env.textutils.serialize(requests)
  approve(root, c, "old.name")
  local config = root.db.config()
  root.db.setConfig({ zone = false })
  check("zone is missing", not root.db.config().zone)
  sim.call(root, function() root.db.ensureZone() end)
  check("zone from the name", root.db.config().zone.tld, "old-root")
  check("old name renews", sim.call(c, function() return c.net.requestCertificate(entry, "old.name") end), "issued")
end
reset()

-- Lying about zones and hosts -------------------------------------------------

-- A zone can only be signed by the root it names
do
  local root = rootServer(10, "Root A")
  local c = sim.computer(1)
  local entry = trustRoot(c, root)
  local zone = sim.copy(root.db.config().zone)
  check("real zone", sim.call(c, function() return trustOf(c).checkZone(zone, entry.key) end))
  zone.tld = "bank"
  check("changed zone", sim.call(c, function() return trustOf(c).checkZone(zone, entry.key) end), false)
  check("rubbish zone", sim.call(c, function() return trustOf(c).checkZone("x", entry.key) end), false)

  local realReply = root.net.reply
  root.net.reply = function(msg, payload, opts)
    if type(payload) == "table" and payload.sig then payload = zone end
    return realReply(msg, payload, opts)
  end
  local tld, why = sim.call(c, function() return c.net.tldOf(entry) end)
  check("forged zone refused", tld, nil)
  check("says so", has(why, "bad zone"))
  check("nothing remembered", trustOf(c).root(entry.key).tld, nil)
end
reset()

-- A trusted root can't answer for another's top-level domain
do
  local a = rootServer(10, "Root A")
  local b = rootServer(11, "Root B")
  local server = mailServer(1, a, "zmail.root-a")
  account(server, "alice")

  -- b's root signs its computer as a hostname that belongs to a. It wouldn't by accident.
  local mallory = sim.computer(2)
  local entryB = trustRoot(mallory, b)
  local seed, public = b.db.keypair()
  local forged = sim.call(b, function()
    return trustOf(b).issue(seed, public, "zmail.root-a", 2, keyOf(mallory), 86400000)
  end)
  trustOf(mallory).installCert(forged)
  mallory.net.listen(4202)

  local c = clientComputer(3, { a, b })
  assert(signIn(c, "alice@zmail.root-a"))

  -- point the lookup at mallory: `root` still has to match
  local realResolve = c.net.resolve
  c.net.resolve = function(host)
    local found = realResolve(host)
    found.id = 2
    return found
  end
  local nope, why = sim.call(c, function() return c.net.requestHost("zmail.root-a", 4202, { op = "login" }) end)
  check("wrong root's certificate refused", nope, nil)
  check("says who it is", has(why, "computer 2"))
  c.net.resolve = realResolve

  -- nor does a root's answer count for another root
  local realRequest = c.net.request
  c.net.request = function(id, port, payload, opts)
    local reply, err = realRequest(id, port, payload, opts)
    if reply and payload.op == "resolve" then reply.payload = { cert = forged } end
    return reply, err
  end
  nope, why = sim.call(c, function() return c.net.resolve("zmail.root-a") end)
  check("certificate from the wrong root refused", nope, nil)
  check("says it's bad", has(why, "bad certificate"))
  c.net.request = realRequest

  -- an honest cert for another host doesn't pass as this one
  local _, certA = server.db.hostname()
  c.net.request = function(id, port, payload, opts)
    local reply, err = realRequest(id, port, payload, opts)
    if reply and payload.op == "resolve" then reply.payload = { cert = certA } end
    return reply, err
  end
  nope = sim.call(c, function() return c.net.resolve("other.root-a") end)
  check("certificate for another host refused", nope, nil)
  c.net.request = realRequest

  -- two trusted roots with one tld: neither is believed
  check("still works", sim.call(c, function() return c.net.rootForTld("root-a") end) ~= nil)
  local roots = trustOf(c)
  roots.setRootTld(entryB.key, "root-a")
  nope, why = sim.call(c, function() return c.net.resolve("zmail.root-a") end)
  check("clashing tlds refused", nope, nil)
  check("says two claim it", has(why, "two trusted root servers"))
end
reset()

-- Accounts --------------------------------------------------------------------

do
  local root = rootServer(10, "Root A")
  local server = mailServer(1, root, "zmail.root-a")
  account(server, "alice")
  local c = clientComputer(2, { root })

  local nope, why = signIn(c, "alice@zmail.root-a", "wrong password")
  check("wrong password", nope, nil)
  check("doesn't say which part", has(why, "Wrong account or password"))
  check("unknown account is the same", select(2, signIn(c, "nobody@zmail.root-a")), why)
  check("bad address", select(2, signIn(c, "alice")) ~= nil)

  local signedIn = assert(signIn(c, "alice@zmail.root-a"))
  check("token isn't the hash stored", server.files["etc/zos/mail-server/accounts"]:find(signedIn.token, 1, true), nil)
  check("password isn't stored", has(server.files["etc/zos/mail-server/accounts"], "correct horse"), false)
  check("saved token is sealed", has(c.files["etc/zos/mail-client/me"], signedIn.token), false)
  check("signed in after a restart", c.client.load(c.session).token, signedIn.token)
  check("another user can't read it", c.client.load({ user = "me", secretKey = string.rep("z", 32) }), nil)

  -- signing up
  local up = sim.call(c, function() return c.client.signUp({ user = "two" }, "bob@zmail.root-a", "hunter2hunter2") end)
  check("sign up", up and up.user, "bob")
  nope, why = sim.call(c, function() return c.client.signUp({ user = "x" }, "bob@zmail.root-a", "hunter2hunter2") end)
  check("name taken", has(why, "taken"))
  nope, why = sim.call(c, function() return c.client.signUp({ user = "x" }, "short@zmail.root-a", "abc") end)
  check("short password", has(why, "at least"))
  nope, why = sim.call(c, function() return c.client.signUp({ user = "x" }, "postmaster@zmail.root-a", "hunter2hunter2") end)
  check("postmaster is reserved", has(why, "reserved"))
  server.db.setConfig({ signups = false })
  nope, why = sim.call(c, function() return c.client.signUp({ user = "x" }, "carol@zmail.root-a", "hunter2hunter2") end)
  check("closed sign-ups", has(why, "new accounts"))

  -- tokens
  local _, err, expired = op(c, { user = "alice", host = "zmail.root-a", token = "forged" }, "list")
  check("forged token", has(err, "sign in"))
  check("asks to sign in", expired, true)
  check("one account's token isn't another's", (op(c, { user = "bob", host = up.host, token = signedIn.token }, "list")), nil)
  check("logout", op(c, up, "logout") ~= nil)
  check("logged out", (op(c, up, "list")), nil)

  -- password change signs everything else out
  local second = assert(signIn(c, "alice@zmail.root-a"))
  check("change password", sim.call(c, function() return c.client.changePassword(c.session, signedIn, "a new password") end))
  check("new token works", op(c, signedIn, "list") ~= nil)
  check("old devices are out", (op(c, second, "list")), nil)
  check("old password is out", (signIn(c, "alice@zmail.root-a")), nil)
  check("new password works", signIn(c, "alice@zmail.root-a", "a new password") ~= nil)

  -- tokens run out
  sim.setClock(sim.now() + 31 * 24 * 3600 * 1000)
  check("expired token", (op(c, signedIn, "list")), nil)
end
reset()

-- Guessing locks the account for a while
do
  local root = rootServer(10, "Root A")
  local server = mailServer(1, root, "zmail.root-a")
  account(server, "alice")
  local c = clientComputer(2, { root })
  for _ = 1, 5 do signIn(c, "alice@zmail.root-a", "bad guess") end
  local nope, why = signIn(c, "alice@zmail.root-a")
  check("locked, even with the right password", nope, nil)
  check("says so", has(why, "Too many"))
  sim.advance(61)
  check("unlocks", signIn(c, "alice@zmail.root-a") ~= nil)
end
reset()

-- Mail ------------------------------------------------------------------------

-- On one server, and from one server to another under the same root
do
  local root = rootServer(10, "Root A")
  local one = mailServer(1, root, "zmail.root-a")
  local two = mailServer(2, root, "other.root-a")
  account(one, "alice")
  account(one, "bob")
  account(two, "carol")
  local c = clientComputer(3, { root })
  local alice = assert(signIn(c, "alice@zmail.root-a"))

  check("local send", send(c, alice, { "bob" }, "Lunch", "Noon?") ~= nil)
  check("arrived", #inbox(one, "bob"), 1)
  check("from", inbox(one, "bob")[1].from, "alice@zmail.root-a")

  sim.wire = {}
  local marker = "the-password-is-swordfish"
  check("remote send", send(c, alice, { "carol@other.root-a" }, "Hi", marker) ~= nil)
  sim.run(function() return #inbox(two, "carol") > 0 end, 60)
  check("arrived there", inbox(two, "carol")[1].subject, "Hi")
  sim.run(function() return #one.db.outbox() == 0 end, 60)
  check("queue is empty", #one.db.outbox(), 0)

  local bob = assert(signIn(c, "bob@zmail.root-a"))
  local list = assert(op(c, bob, "list"))
  check("unread", list.messages[1].read, false)
  local answer = assert(op(c, bob, "read", { id = list.messages[1].id }))
  check("body", answer.message.body, "Noon?")
  check("now read", assert(op(c, bob, "list")).messages[1].read, true)
  check("can't read someone else's", (op(c, alice, "read", { id = list.messages[1].id })), nil)
  check("delete", op(c, bob, "delete", { id = list.messages[1].id }) ~= nil)
  check("deleted", #assert(op(c, bob, "list")).messages, 0)

  for _, id in ipairs({ "../accounts", "..", "index", string.rep("z", 32) }) do
    check("bad id: " .. id, (op(c, alice, "read", { id = id })), nil)
    op(c, alice, "delete", { id = id })
  end
  check("accounts survive", one.db.exists("alice"))

  local hex = cryptoOf(c).toHex(marker)
  local seen = false
  local function walk(v)
    if type(v) == "table" then
      for k, x in pairs(v) do walk(k) walk(x) end
    elseif type(v) == "string" and (has(v, marker) or has(v, hex)) then
      seen = true
    end
  end
  walk(sim.wire)
  check("mail isn't on the wire", seen, false)

  -- refused up front
  local nope, why = send(c, alice, { "nobody" }, "x", "y")
  check("unknown local account", nope, nil)
  check("says who", has(why, "nobody"))
  nope, why = send(c, alice, { "bob", "not an address" }, "x", "y")
  check("bad address stops the whole message", nope, nil)
  check("nothing half sent", #inbox(one, "bob"), 0)
  check("no recipients", (send(c, alice, {}, "x", "y")), nil)
  check("too long", (send(c, alice, { "bob" }, "x", string.rep("y", 9000))), nil)
  check("subject type", (send(c, alice, { "bob" }, 5, "y")), nil)
end
reset()

-- Between two roots, with each server trusting both
do
  local a = rootServer(10, "Root A")
  local b = rootServer(11, "Root B")
  local one = mailServer(1, a, "zmail.root-a")
  local two = mailServer(2, b, "ymail.root-b")
  trustRoot(one, b)
  trustRoot(two, a)
  account(one, "alice")
  account(two, "bob")
  local c = clientComputer(3, { a })
  local alice = assert(signIn(c, "alice@zmail.root-a"))
  check("send across roots", send(c, alice, { "bob@ymail.root-b" }, "Far", "away") ~= nil)
  sim.run(function() return #inbox(two, "bob") > 0 end, 120)
  check("arrived", inbox(two, "bob")[1].from, "alice@zmail.root-a")

  -- a server holding names from both roots still answers to each
  local both = sim.computer(4)
  both.appDir = "apps/mail-server/"
  both.db = both.env.require("maildb")
  hostname(both, a, "both.root-a")
  hostname(both, b, "both.root-b")
  both.db.setHostname("both.root-a", trustOf(both).roots()[1].key)
  both.service = run(both, "apps/mail-server/service.lua")
  sim.advance(1)
  account(both, "dave")
  local d = clientComputer(5, { a, b })
  check("through the first root", signIn(d, "dave@both.root-a") ~= nil)
  check("through the second root", signIn(d, "dave@both.root-b") ~= nil)
end
reset()

-- A server that's away gets its mail later, even if the sender restarts
do
  local root = rootServer(10, "Root A")
  local one = mailServer(1, root, "zmail.root-a")
  local two = mailServer(2, root, "other.root-a")
  account(one, "alice")
  account(two, "carol")
  local c = clientComputer(3, { root })
  local alice = assert(signIn(c, "alice@zmail.root-a"))
  local twoFiles = two.files
  sim.powerOff(two)

  check("accepted while it's away", send(c, alice, { "carol@other.root-a" }, "Later", "Still there?") ~= nil)
  sim.run(function() return #one.db.outbox() == 1 and one.db.outbox()[1].attempts > 0 end, 60)
  check("waits", #one.db.outbox(), 1)
  check("records why", one.db.outbox()[1].lastError ~= nil)

  one = restartMail(one)
  check("queue survives a reboot", #one.db.outbox(), 1)
  two = restartMail({ id = 2, files = twoFiles })
  sim.run(function() return #inbox(two, "carol") > 0 end, 300)
  check("delivered in the end", inbox(two, "carol")[1].subject, "Later")
  sim.run(function() return #one.db.outbox() == 0 end, 60)
  check("left the queue", #one.db.outbox(), 0)

  -- sending it again after a lost answer doesn't make two
  local id = inbox(two, "carol")[1].id
  check("repeat is harmless", two.db.store("carol", two.db.open("carol", id)))
  check("kept once", #inbox(two, "carol"), 1)
end
reset()

-- Mail that can't go anywhere comes back
do
  local root = rootServer(10, "Root A")
  local one = mailServer(1, root, "zmail.root-a")
  local two = mailServer(2, root, "other.root-a")
  account(one, "alice")
  account(two, "carol")
  local c = clientComputer(3, { root })
  local alice = assert(signIn(c, "alice@zmail.root-a"))

  send(c, alice, { "ghost@other.root-a", "carol@other.root-a" }, "Hello", "Anyone?")
  sim.run(function() return #inbox(two, "carol") > 0 and #inbox(one, "alice") > 0 end, 60)
  check("bounce from the postmaster", inbox(one, "alice")[1].from, "postmaster@zmail.root-a")
  check("names the message", has(inbox(one, "alice")[1].subject, "Hello"))
  check("names the address", has(one.db.open("alice", inbox(one, "alice")[1].id).body, "ghost@other.root-a"))
  sim.run(function() return #one.db.outbox() == 0 end, 60)
  check("the rest was delivered", #inbox(two, "carol"), 1)

  -- a host that doesn't exist, after days of trying
  send(c, alice, { "x@nowhere.root-a" }, "Lost", "body")
  sim.run(function() return one.db.outbox()[1] and one.db.outbox()[1].attempts > 0 end, 60)
  sim.setClock(sim.now() + 4 * 24 * 3600 * 1000)
  sim.run(function() return #one.db.outbox() == 0 end, 4000)
  check("gives up", has(inbox(one, "alice")[1].subject, "Lost"))

  -- a full mailbox refuses, and the sender keeps trying
  for i = 1, 64 do
    two.db.store("carol", two.db.cleanMessage({ id = string.format("%032x", i), from = "a@b.c", to = {}, subject = "s", body = "" }))
  end
  send(c, alice, { "carol@other.root-a" }, "Room?", "body")
  sim.run(function() return one.db.outbox()[1] and one.db.outbox()[1].attempts > 0 end, 60)
  check("waits for room", one.db.outbox()[1].lastError, "mailbox full")
  two.db.delete("carol", string.format("%032x", 1))
  sim.run(function() return #one.db.outbox() == 0 end, 4000)
  check("delivered when there's room", inbox(two, "carol")[1].subject, "Room?")
end
reset()

-- Servers can only send mail from their own hostname
do
  local root = rootServer(10, "Root A")
  local one = mailServer(1, root, "zmail.root-a")
  local two = mailServer(2, root, "other.root-a")
  account(one, "alice")
  account(two, "carol")

  local message = { id = string.rep("a", 32), from = "alice@zmail.root-a", to = { "carol@other.root-a" },
    subject = "Pay me", body = "Love, alice" }

  -- a stranger with no certificate
  local stranger = sim.computer(3)
  trustRoot(stranger, root)
  local reply = sim.call(stranger, function()
    return stranger.net.request(2, 4202, { op = "deliver", users = { "carol" }, message = message }, { timeout = 10 })
  end)
  check("uncertified sender refused", has(reply.payload.error, "can't verify"))

  -- a real mail server forging another's address
  reply = sim.call(one, function()
    local forged = sim.copy(message)
    forged.from = "boss@other.root-a"
    return one.net.requestHost("other.root-a", 4202, { op = "deliver", users = { "carol" }, message = forged })
  end, 60)
  check("forged address refused", has(reply.payload.error, "can't verify"))

  check("nothing arrived", #inbox(two, "carol"), 0)
  check("a real one works", sim.call(one, function()
    return one.net.requestHost("other.root-a", 4202, { op = "deliver", users = { "carol" }, message = message })
  end, 60).payload.results.carol, "ok")

  -- what's on screen is plain text, whatever is sent
  local nasty = sim.copy(message)
  nasty.id = string.rep("b", 32)
  nasty.subject = "line\nbreak\27[31m" .. string.rep("x", 100)
  nasty.body = "keeps\nlines\tand tabs\1\2\27"
  sim.call(one, function()
    return one.net.requestHost("other.root-a", 4202, { op = "deliver", users = { "carol", "../accounts" }, message = nasty })
  end, 60)
  local stored = two.db.open("carol", nasty.id)
  check("subject has no controls", stored.subject:find("%c"), nil)
  check("subject is limited", #stored.subject, 64)
  check("body keeps lines", stored.body:sub(1, 22), "keeps\nlines\tand tabs")
  check("body has no other controls", #stored.body, 20)

  local unsafe = sim.copy(message)
  unsafe.id = "../accounts"
  local bad = sim.call(one, function()
    return one.net.requestHost("other.root-a", 4202, { op = "deliver", users = { "carol" }, message = unsafe })
  end, 60)
  check("unsafe id refused", bad.payload.error, "bad message")

  -- garbage doesn't stop the service
  for _, payload in ipairs({ "text", 5, {}, { op = "nope" }, { op = "login" }, { op = "deliver" }, { op = "list" },
    { op = "signup", user = 5, password = {} }, { op = "deliver", users = "x", message = {} } }) do
    sim.call(stranger, function() return stranger.net.request(2, 4202, payload, { timeout = 5 }) end)
  end
  sim.advance(2)
  check("service still running", two.service.done, nil)
end
reset()

-- Mail only goes to the key that asked: an answer can't be taken by claiming a computer's id
do
  local root = rootServer(10, "Root A")
  local server = mailServer(1, root, "zmail.root-a")
  account(server, "alice")
  local c = clientComputer(2, { root })
  local signedIn = assert(signIn(c, "alice@zmail.root-a"))

  local answers = 0
  local realReply = server.net.reply
  server.net.reply = function(msg, payload, opts)
    answers = answers + 1
    msg.peer = { key = string.rep("ab", 32) } -- as if another key had asked
    return realReply(msg, payload, opts)
  end
  local nope = sim.call(c, function() return c.client.call(signedIn, "list") end, 120)
  check("the answer doesn't go down the wrong session", nope, nil)
  check("it was tried", answers > 0)
end
reset()

-- The screens -----------------------------------------------------------------

do
  local function key(c, name) c.env.os.queueEvent("key", c.env.keys[name]) end
  local function char(c, ch) c.env.os.queueEvent("char", ch) end
  local function line(c, text) c.env.os.queueEvent("sim_line", text) end
  local function pick(c, n)
    for _ = 1, n do key(c, "down") end
    key(c, "enter")
  end
  local function screenHas(c, text)
    local ok, err = pcall(sim.run, function() return has(c.screenText(), text) end, 120)
    if not ok then
      print("Waiting for '" .. text .. "' on computer " .. c.id .. ", the screen says:\n" .. c.screenText())
      error(err, 0)
    end
    return true
  end

  local root = rootServer(10, "Root A")

  -- the server's admin gets a hostname, and the root's admin approves it
  local server = sim.computer(1)
  server.appDir = "apps/mail-server/"
  server.db = server.env.require("maildb")
  server.service = run(server, "apps/mail-server/service.lua")
  sim.advance(1)

  local refused = run(server, "apps/mail-server/main.lua", { user = "guest", admin = false })
  check("needs an admin", screenHas(server, "Only administrators"))
  key(server, "enter")
  sim.run(function() return refused.done end)

  run(server, "apps/mail-server/main.lua", { user = "admin", admin = true })
  check("explains", screenHas(server, "needs a hostname"))
  key(server, "enter")
  check("needs a root", screenHas(server, "doesn't trust a root server"))
  key(server, "enter")
  sim.advance(1)

  trustRoot(server, root)
  run(server, "apps/mail-server/main.lua", { user = "admin", admin = true })
  check("explains again", screenHas(server, "needs a hostname"))
  key(server, "enter")
  check("asks for a name under the tld", screenHas(server, "Name, without .root-a"))
  line(server, "Not Valid")
  check("refuses a bad name", screenHas(server, "Hostnames look like"))
  line(server, "zmail")
  check("waits for approval", screenHas(server, "Waiting for the root server"))
  check("the request reached the root", root.db.requests()[keyOf(server)].name, "zmail.root-a")
  check("approve", approve(root, server, "zmail.root-a"), true)
  check("got it", screenHas(server, "This server is now zmail.root-a"))
  key(server, "enter")
  check("server menu", screenHas(server, "Hostname: zmail.root-a"))
  check("hostname saved", (server.db.hostname()), "zmail.root-a")

  pick(server, 1)
  check("no accounts yet", screenHas(server, "(none yet)"))
  pick(server, 1)
  check("account name", screenHas(server, "Account name"))
  line(server, "alice")
  check("account password", screenHas(server, "Password"))
  line(server, "correct horse")
  check("account listed", screenHas(server, "alice"))
  check("account made", server.db.exists("alice"))

  -- someone signs in on another computer and writes to themselves
  local c = sim.computer(2)
  c.appDir = "apps/mail/"
  trustRoot(c, root)
  local session = { user = "me", secretKey = string.rep("k", 32) }
  run(c, "apps/mail/main.lua", session)
  check("client menu", screenHas(c, "Sign in"))
  key(c, "enter")
  check("asks for an address", screenHas(c, "Address, like"))
  line(c, "alice@zmail.root-a")
  check("asks for a password", screenHas(c, "Password"))
  line(c, "correct horse")
  check("signed in", screenHas(c, "Mail - alice@zmail.root-a"))
  pick(c, 1)
  check("to", screenHas(c, "To (separate"))
  line(c, "alice")
  check("subject", screenHas(c, "Subject"))
  line(c, "Note to self")
  check("body", screenHas(c, "A line with only a dot"))
  line(c, "Buy diamonds")
  line(c, ".")
  check("confirm", screenHas(c, "Send it?"))
  char(c, "y")
  check("sent", screenHas(c, "Sent."))
  key(c, "enter")
  check("menu again", screenHas(c, "Inbox"))
  key(c, "up")
  key(c, "enter")
  check("listed", screenHas(c, "* Note to self"))
  key(c, "enter")
  check("reads it", screenHas(c, "Buy diamonds"))
  char(c, "r")
  check("reply fills in the sender", screenHas(c, "To (separate"))
  line(c, "alice@zmail.root-a")
  line(c, "Re: Note to self")
  check("reply body", screenHas(c, "A line with only a dot"))
  line(c, "Done")
  line(c, ".")
  check("confirm reply", screenHas(c, "Send it?"))
  char(c, "y")
  check("reply sent", screenHas(c, "Sent."))
  sim.run(function() return #server.db.index("alice") == 2 end, 60)
  check("quotes the original", has(server.db.open("alice", server.db.index("alice")[1].id).body, "> Buy diamonds"))
end
reset()

if failed > 0 then
  print("mail: " .. failed .. " failed, " .. passed .. " passed")
  os.exit(1)
end
print("mail: all " .. passed .. " passed")
