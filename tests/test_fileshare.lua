-- End-to-end tests of the File Share app: its service, protocol and screens, on simulated
-- computers with an attacker on the wire. Run from the repository root: luajit tests/test_fileshare.lua
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

local function shareOf(c) return c.env.require("share") end
local function cryptoOf(c) return c.env.require("crypto") end

-- A computer running the app's service.
local function peerComputer(id, opts)
  local c = sim.computer(id, opts)
  c.appDir = "apps/fileshare/"
  local fn = assert(loadfile("apps/fileshare/service.lua"))
  setfenv(fn, c.env)
  c.service = sim.spawn(c, fn)
  sim.advance(1)
  return c
end

local function reset()
  for _, c in pairs(sim.computers) do sim.powerOff(c) end
  sim.wire, sim.onPacket = {}, nil
end

-- Compare fingerprints and add b on a, as someone at the screen would.
local function verify(a, b)
  local found = assert(sim.call(a, function() return shareOf(a).hello(b.id) end))
  shareOf(a).trustPeer(found)
  return found
end

local function pair(a, b)
  verify(a, b)
  verify(b, a)
end

local function connect(a, b)
  local peer = shareOf(a).peerById(b.id)
  return sim.call(a, function() return shareOf(a).connect(peer) end)
end

local function download(c, channel, name, progress)
  return sim.call(c, function() return shareOf(c).download(channel, name, "home/me/downloads", progress) end, 300)
end

-- Finding and verifying ------------------------------------------------------

do
  local a, b = peerComputer(1), peerComputer(2, { label = "Storage" })
  local found = sim.call(a, function() return shareOf(a).find(2) end)
  check("finds the computer", #found, 1)
  check("with its name", found[1].name, "Storage")

  local hello = sim.call(a, function() return shareOf(a).hello(2) end)
  local trustB = b.env.require("trust")
  check("hello shows the real fingerprint", hello.fingerprint, b.env.require("crypto").fingerprint(select(2, trustB.identity())))
  check("hello doesn't trust anyone by itself", shareOf(a).isTrusted(hello.key), false)
end
reset()

-- A bad name in an announcement isn't shown
do
  local a, b = peerComputer(1), peerComputer(2, { label = "\27[evil\nname" })
  local found = sim.call(a, function() return shareOf(a).find(2) end)
  check("bad name is replaced", found[1].name, "computer-2")
end
reset()

-- Downloading ----------------------------------------------------------------

do
  local a, b = peerComputer(1), peerComputer(2)
  local marker = "top-secret-recipe"
  local bytes = {}
  for i = 0, 255 do bytes[#bytes + 1] = string.char(i) end
  local content = marker .. table.concat(bytes) .. string.rep("xyz\n", 6000) -- several chunks
  b.files["home/you/plans.bin"] = content
  b.files["home/you/empty"] = ""
  check("share a file", shareOf(b).addFile("/home/you/plans.bin"), "plans.bin")
  check("share an empty file", shareOf(b).addFile("home/you/empty"), "empty")
  pair(a, b)

  -- what the service hands to net: sealed before the network layer ever sees it
  local replies = {}
  local realReply = b.net.reply
  b.net.reply = function(msg, payload, opts)
    replies[#replies + 1] = sim.copy(payload)
    return realReply(msg, payload, opts)
  end

  local channel = assert(connect(a, b))
  local list = sim.call(a, function() return shareOf(a).list(channel) end)
  check("lists both files", #list, 2)
  check("list is sorted", list[1].name, "empty")
  check("list has sizes", list[2].size, #content)

  local steps = {}
  local path = download(a, channel, "plans.bin", function(got, size) steps[#steps + 1] = got .. "/" .. size end)
  check("download path", path, "home/me/downloads/plans.bin")
  check("bytes are identical", a.files["home/me/downloads/plans.bin"], content)
  check("progress reported", #steps, 3)
  check("progress reaches the end", steps[#steps], #content .. "/" .. #content)

  local text = {}
  for _, payload in ipairs(replies) do text[#text + 1] = tostring(payload.box and payload.box.ct) end
  text = table.concat(text)
  local hexMarker = cryptoOf(a).toHex(marker)
  check("file is sealed before it reaches net", has(text, hexMarker) or has(text, marker), false)
  local wire = sim.copy(sim.wire)
  local seen = false
  for _, p in ipairs(wire) do
    if has(tostring(p.message.ct), hexMarker) then seen = true end
  end
  check("file isn't on the wire", seen, false)

  check("empty file downloads", download(a, channel, "empty"), "home/me/downloads/empty")
  check("empty file is empty", a.files["home/me/downloads/empty"], "")

  check("a second copy never overwrites", download(a, channel, "plans.bin"), "home/me/downloads/plans (1).bin")

  local nope, why = download(a, channel, "secrets")
  check("unshared file refused", nope, nil)
  check("says why", has(why, "isn't shared"))

  a.files.freeSpace = 10
  nope, why = download(a, channel, "plans.bin")
  check("no room refused", nope, nil)
  check("says no room", has(why, "free space"))
  check("nothing left behind", a.files["home/me/downloads/plans (2).bin"], nil)
  a.files.freeSpace = nil

  -- a channel left idle is replaced by itself
  sim.advance(400)
  check("expired channel renews", #sim.call(a, function() return shareOf(a).list(channel) end), 2)
end
reset()

-- A file changing during a download doesn't mix versions
do
  local a, b = peerComputer(1), peerComputer(2)
  b.files["share.txt"] = string.rep("A", 20000)
  shareOf(b).addFile("share.txt")
  pair(a, b)
  local channel = assert(connect(a, b))
  local path = download(a, channel, "share.txt", function() b.files["share.txt"] = string.rep("B", 20000) end)
  check("snapshot is consistent", a.files[path], string.rep("A", 20000))
end
reset()

-- Refusing -------------------------------------------------------------------

-- Both sides have to verify each other
do
  local a, b = peerComputer(1), peerComputer(2)
  b.files["f"] = "data"
  shareOf(b).addFile("f")
  verify(a, b)
  local channel, why = connect(a, b)
  check("not added back: refused", channel, nil)
  check("says to add it", has(why, "hasn't added this computer"))

  -- and forgetting takes effect on a channel that's already open
  verify(b, a)
  channel = assert(connect(a, b))
  shareOf(b).forgetPeer(shareOf(b).peerById(1).key)
  local list, err = sim.call(a, function() return shareOf(a).list(channel) end)
  check("forgotten computer refused", list, nil)
  check("forgotten says why", has(err, "hasn't added"))
end
reset()

-- A stranger can't use someone else's channel
do
  local a, b, c = peerComputer(1), peerComputer(2), peerComputer(3)
  b.files["f"] = "data"
  shareOf(b).addFile("f")
  pair(a, b)
  local channel = assert(connect(a, b))
  local reply = sim.call(c, function()
    return c.net.request(2, 4201, { op = "call", cid = channel.id, box = { nonce = "", ct = "", tag = "" } })
  end)
  check("stranger is untrusted", reply.payload.error, "untrusted")

  -- nor can a trusted computer use another's
  verify(b, c)
  reply = sim.call(c, function()
    return c.net.request(2, 4201, { op = "call", cid = channel.id, box = { nonce = "", ct = "", tag = "" } })
  end)
  check("another computer's channel looks expired", reply.payload.error, "expired")
end
reset()

-- Key changes: another computer now answers to the verified one's id
do
  local a, b = peerComputer(1), peerComputer(2)
  b.files["f"] = "data"
  shareOf(b).addFile("f")
  pair(a, b)
  local channel = assert(connect(a, b))

  local files = b.files
  files["etc/zos/net/identity"] = nil
  sim.powerOff(b)
  local impostor = peerComputer(2, { files = files })
  shareOf(impostor).trustPeer({ key = cryptoOf(a).toHex(select(2, a.env.require("trust").identity())), id = 1, name = "a" })

  -- net.lua's pin stops this first, so take it away: what's left is the check against the verified key
  a.files["etc/zos/known_keys"] = nil
  local peer = shareOf(a).peerById(2)
  local nope, why = sim.call(a, function() return shareOf(a).connect(peer) end)
  check("new key refused at connect", nope, nil)
  check("says the fingerprint changed", has(why, "fingerprint has changed"))
  nope, why = sim.call(a, function() return shareOf(a).list(channel) end)
  check("new key refused on open channel", nope, nil)
  check("says so", has(why, "fingerprint has changed"))
end
reset()

-- A reply that claims the right key but can't sign with it gets nothing back
do
  local a, b = peerComputer(1), peerComputer(2)
  pair(a, b)
  local peer = shareOf(a).peerById(2)
  local cryptoA = cryptoOf(a)
  local sent = 0
  a.net.request = function()
    sent = sent + 1
    return {
      peer = { key = peer.key },
      payload = { eph = cryptoA.toHex(cryptoA.randomBytes(32)), sig = string.rep("ab", 64) },
    }
  end
  local nope, why = sim.call(a, function() return shareOf(a).connect(peer) end)
  check("forged signature refused", nope, nil)
  check("says it couldn't prove it", has(why, "couldn't prove"))
  check("nothing sealed was sent", sent, 1)
end
reset()

-- A trusted computer can still lie about names, which must not reach the file system
do
  local a, b = peerComputer(1), peerComputer(2)
  pair(a, b)
  b.files["f"] = "payload"
  shareOf(b).addFile("f")
  local channel = assert(connect(a, b))
  for _, name in ipairs({ "../../startup.lua", "/startup.lua", "..", ".hidden", "a/b", "a\nb", "" }) do
    local nope, why = download(a, channel, name)
    check("unsafe name refused: " .. name, nope, nil)
    check("before asking: " .. name, has(why, "isn't safe"))
  end

  -- and names in a list are filtered, even if the other side shares them
  local realFiles = shareOf(b).files
  shareOf(b).files = function()
    local list = realFiles()
    list[#list + 1] = { name = "../../startup.lua", size = 1 }
    return list
  end
  local list = sim.call(a, function() return shareOf(a).list(channel) end)
  check("unsafe name left out of the list", #list, 1)
  check("safe one remains", list[1].name, "f")
end
reset()

-- A chunk of the wrong size is caught: the file that's kept is the size that was promised
do
  local a, b = peerComputer(1), peerComputer(2)
  pair(a, b)
  b.files["f"] = string.rep("z", 100)
  shareOf(b).addFile("f")
  local channel = assert(connect(a, b))
  local crypto = cryptoOf(b)
  local realSeal = crypto.seal
  crypto.seal = function(key, plain)
    if plain:sub(-50) == string.rep("z", 50) then plain = plain:sub(1, -2) end
    return realSeal(key, plain)
  end
  local nope, why = download(a, channel, "f")
  check("short chunk refused", nope, nil)
  check("says it's wrong", has(why, "wrongly"))
  check("nothing kept", a.files["home/me/downloads/f"], nil)
end
reset()

-- Garbage doesn't stop the service
do
  local a, b, c = peerComputer(1), peerComputer(2), peerComputer(3)
  pair(a, b)
  verify(b, c)
  for _, payload in ipairs({
    "text", 5, {}, { op = "open" }, { op = "open", eph = "zz" }, { op = "call" }, { op = "call", cid = 5 },
    { op = "nonsense" }, { op = "call", cid = "x", box = "y" },
  }) do
    sim.call(c, function() return c.net.send(2, 4201, payload) end)
  end
  sim.advance(2)
  check("service still running", b.service.done, nil)
  check("still answers", assert(connect(a, b)) ~= nil)
end
reset()

-- What can be shared ---------------------------------------------------------

do
  local a = peerComputer(1)
  a.files["home/me/a.txt"] = "x"
  a.files["other/a.txt"] = "y"
  a.files["etc/zos/net/identity"] = "seed"
  a.files[".zos/boot.lua"] = "x"
  a.files["home/me/.secret"] = "x"
  a.files["startup.lua"] = "x"
  local s = shareOf(a)
  local function refused(path, text, label)
    local name, why = s.addFile(path)
    check(label .. " refused", name, nil)
    check(label .. " says why", has(why, text))
  end
  refused("/etc/zos/net/identity", "can't be shared", "identity key")
  refused(".zos/boot.lua", "can't be shared", "system file")
  refused("/ETC/zos/net/identity", "can't be shared", "other case")
  refused("startup.lua", "can't be shared", "startup")
  refused("/home/me", "single files", "folder")
  refused("/home/me/missing", "no file", "missing file")
  refused("/home/me/.secret", "letters", "dot file")
  check("own file shared", s.addFile("/home/me/a.txt"), "a.txt")
  check("sharing it twice is fine", s.addFile("/home/me/a.txt"), "a.txt")
  refused("/other/a.txt", "already shared", "same name")
  a.files["home/me/a.txt"] = nil
  check("a deleted file isn't listed", #s.files(), 0)
end
reset()

-- The screens ----------------------------------------------------------------

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
  local function open(c)
    local fn = assert(loadfile("apps/fileshare/main.lua"))
    setfenv(fn, c.env)
    return sim.spawn(c, fn, { user = "me" }, {})
  end

  local a, b = peerComputer(1, { label = "Alpha" }), peerComputer(2, { label = "Beta" })
  b.files["home/me/map.txt"] = "the treasure is under the tree"

  -- on b: share a file and verify a by id
  local appB = open(b)
  check("menu", screenHas(b, "Computers (0)"))
  pick(b, 1)
  check("shared files", screenHas(b, "Share a file"))
  key(b, "enter")
  check("asks for a path", screenHas(b, "Path to the file"))
  line(b, "/home/me/map.txt")
  check("file is listed", screenHas(b, "map.txt"))
  pick(b, 2)
  check("back at the menu", screenHas(b, "Shared files (1)"))
  key(b, "up")
  key(b, "enter")
  check("computers", screenHas(b, "Add a computer"))
  pick(b, 1)
  check("add screen", screenHas(b, "Enter a computer id"))
  pick(b, 1) -- computer 1 was found; move past it
  check("asks for an id", screenHas(b, "Computer id"))
  line(b, "1")
  local trustA = a.env.require("trust")
  local fingerA = sim.fingerprint(select(2, trustA.identity()))
  check("shows a's fingerprint", screenHas(b, fingerA))
  char(b, "y")
  check("verified", screenHas(b, "is verified"))

  -- on a: declining adds nothing, then find b and accept
  local appA = open(a)
  check("menu on a", screenHas(a, "Computers (0)"))
  key(a, "enter")
  check("a's computers", screenHas(a, "Add a computer"))
  pick(a, 1)
  check("b is found", screenHas(a, "Beta (computer 2)"))
  key(a, "enter")
  check("compare prompt", screenHas(a, "Does it match exactly?"))
  char(a, "n")
  check("back after declining", screenHas(a, "Computers"))
  check("declining adds nothing", #shareOf(a).peers(), 0)
  sim.advance(1)
  key(a, "enter") -- the menu stays on Add a computer
  check("b is found again", screenHas(a, "Beta (computer 2)"))
  key(a, "enter")
  check("compare prompt again", screenHas(a, "Does it match exactly?"))
  char(a, "y")
  check("a verified b", screenHas(a, "is verified"))
  key(a, "enter")
  check("b in the list", screenHas(a, "Beta (computer 2)"))
  key(a, "up")
  key(a, "enter")
  check("computer menu", screenHas(a, "Browse files"))
  key(a, "enter")
  check("sees the file", screenHas(a, "map.txt"))
  key(a, "enter")
  check("saved", screenHas(a, "Saved to /home/me/downloads/map.txt"))
  check("file arrived", a.files["home/me/downloads/map.txt"], b.files["home/me/map.txt"])
end

reset()

-- Data from older versions --------------------------------------------------------

do
  local c = sim.computer(70)
  c.files["etc/zos/fileshare/peers"] = "peers"
  c.files["etc/zos/fileshare/files"] = "files"
  c.appDir = "apps/fileshare/"
  c.env.require("share")
  check("trusted computers moved", c.files["etc/fileshare/peers"], "peers")
  check("shared files moved", c.files["etc/fileshare/files"], "files")
  check("nothing left in /etc/zos", c.files["etc/zos/fileshare/peers"], nil)
end
reset()

if failed > 0 then
  print("fileshare: " .. failed .. " failed, " .. passed .. " passed")
  os.exit(1)
end
print("fileshare: all " .. passed .. " passed")
