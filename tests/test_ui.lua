-- Drives the real Settings and Root Server screens with scripted keys, on a simulated screen.
-- Run from the repository root: luajit tests/test_ui.lua
package.path = "tests/?.lua;" .. package.path

local sim = require("sim")

local SETTINGS = "src/.zos/sys/settings.lua"

local failed, passed = 0, 0
local function check(name, ok)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name)
  end
end

local function has(s, text)
  return s:find(text, 1, true) ~= nil
end

local function screenHas(c, text)
  local ok, err = pcall(sim.run, function() return has(c.screenText(), text) end, 30)
  if not ok then
    print("Waiting for '" .. text .. "' on computer " .. c.id .. ", the screen says:\n" .. c.screenText())
    error(err, 0)
  end
  return true
end

local function key(c, name) c.env.os.queueEvent("key", c.env.keys[name]) end
local function char(c, ch) c.env.os.queueEvent("char", ch) end
local function line(c, text) c.env.os.queueEvent("sim_line", text) end

local function runScreen(c, path, ...)
  local fn = assert(loadfile(path))
  setfenv(fn, c.env)
  local thread = sim.spawn(c, fn, ...)
  return thread
end

-- Move down `n` rows and press Enter on the current menu.
local function pick(c, n)
  for _ = 1, n do key(c, "down") end
  key(c, "enter")
end

local function scenario(width)
  for _, c in pairs(sim.computers) do sim.powerOff(c) end

  local root = sim.computer(10, { label = "root-box" })
  root.appDir = "apps/root-server/"
  local admin = { user = "admin", admin = true, since = 0 }
  root.env.require("auth").create("admin", "password1", true)

  -- first run of the app: name the server
  local rootApp = runScreen(root, "apps/root-server/main.lua", admin, {})
  check("root setup asks for a name", screenHas(root, "Server name"))
  line(root, "Overworld Root")
  check("asks for a top-level domain", screenHas(root, "Top-level domain"))
  line(root, "overworld")
  check("root menu appears", screenHas(root, "Requests"))
  local rootFinger = root.env.require("rootdb").fingerprint()

  local service = assert(loadfile("apps/root-server/service.lua"))
  setfenv(service, root.env)
  sim.spawn(root, service)

  local c = sim.computer(1, { width = width, label = "alpha" })
  c.env.require("auth").create("admin", "password1", true)
  c.env.require("auth").create("guest", "password1", false)
  local settings = runScreen(c, SETTINGS, admin)
  check("settings has a network page", screenHas(c, "Network"))

  -- Settings: Change my password, Encryption keys, Users, Secure boot, Network, ...
  pick(c, 4)
  check("network page", screenHas(c, "Root servers (0)"))
  pick(c, 0)
  check("root server list", screenHas(c, "Add root server..."))
  pick(c, 0)
  check("scan names the server", screenHas(c, "Overworld Root"))
  check("scan shows the fingerprint", has(c.screenText(), rootFinger))
  if width >= 50 then
    local together = false
    for row in (c.screenText() .. "\n"):gmatch("(.-)\n") do
      together = together or (has(row, "Overworld Root") and has(row, rootFinger))
    end
    check("name and fingerprint share a row", together)
  end
  key(c, "enter")
  check("confirmation repeats the fingerprint", screenHas(c, "Trust this root server?"))
  check("confirmation warns", has(c.screenText(), "fingerprint"))
  char(c, "y")
  check("root added", screenHas(c, "Added Overworld Root"))
  key(c, "enter")
  check("listed afterwards", screenHas(c, "Overworld Root"))
  key(c, "enter") -- into the root
  check("root menu", screenHas(c, "Request a certificate"))
  pick(c, 1)
  check("asks for a certificate name", screenHas(c, "Name"))
  line(c, "alpha")
  check("waits for approval", screenHas(c, "Backspace stops"))

  -- the root server's admin approves it
  check("request shows on the root", screenHas(root, "Requests"))
  sim.advance(0.5)
  key(root, "enter") -- the root's menu was drawn before the request; opening Requests reads it
  check("pending request listed", screenHas(root, "alpha  [pending]"))
  check("its fingerprint is shown", has(root.screenText(),
    sim.fingerprint(select(2, c.env.require("trust").identity()))))
  key(root, "enter")
  check("review screen", screenHas(root, "Sign this key?"))
  char(root, "y")
  check("signed", screenHas(root, "Signed."))
  key(root, "enter")

  check("computer gets its certificate", screenHas(c, "Certificate installed"))
  key(c, "enter")
  check("menu offers renewal", screenHas(c, "Renew certificate"))
  key(c, "enter") -- Details
  check("details show the certificate", screenHas(c, "days left"))
  char(c, "q")
  check("back from details", screenHas(c, "Renew certificate"))

  -- printing this computer's certificate
  local trust = c.env.require("trust")
  local cert = trust.certs()[1]
  key(c, "backspace")
  check("back to the root list", screenHas(c, "Add root server..."))
  key(c, "backspace")
  check("back to the network page", screenHas(c, "Print certificate"))
  pick(c, 2)
  check("no printer says so", screenHas(c, "Attach one"))
  key(c, "enter")
  check("back after no printer", screenHas(c, "Print certificate"))
  c.printers.left = sim.printer(1, 5)
  key(c, "enter")
  check("too little paper says so", screenHas(c, "needs paper"))
  check("nothing printed without enough paper", #c.printers.left.pages == 0)
  key(c, "enter")
  check("back after too little paper", screenHas(c, "Print certificate"))
  c.printers.left = sim.printer(5, 1)
  key(c, "enter")
  check("too little ink says so", screenHas(c, "needs ink"))
  key(c, "enter")
  screenHas(c, "Print certificate")
  c.printers.left = sim.printer(5, 5, 1)
  key(c, "enter")
  check("a full tray says how far it got", screenHas(c, "after 1 of 2 pages"))
  key(c, "enter")
  screenHas(c, "Print certificate")
  c.printers.left = sim.printer(5, 5)
  key(c, "enter")
  check("certificate printed", screenHas(c, "Printed."))
  local paper = c.printers.left
  local printed = paper.text()
  check("two pages, numbered", #paper.pages == 2 and has(printed, "[Certificate: alpha 1/2]") and
    has(printed, "[Certificate: alpha 2/2]"))
  local whole = printed:gsub("\n", "")
  check("printed name", has(printed, "alpha"))
  check("printed computer", has(printed, "Computer: 1\n"))
  check("printed dates", has(printed, c.env.os.date("!%Y-%m-%d", math.floor(cert.expires / 1000))))
  check("printed fingerprint", has(printed, root.env.require("crypto").fingerprint(select(2, trust.identity()))))
  check("printed its key", has(whole, cert.key))
  check("printed the signer", has(printed, "Overworld Root"))
  check("printed the root's fingerprint", has(printed, rootFinger))
  check("printed the root's key", has(whole, cert.root))
  check("printed the signature", has(whole, cert.sig))
  check("no section is split between pages", not paper.pages[1].lines[#paper.pages[1].lines]:match(":$"))
  key(c, "enter")
  screenHas(c, "Print certificate")

  -- with certificates from two roots, you choose which
  local otherSeed, otherKey = c.env.require("crypto").signingKeypair()
  trust.installCert(trust.issue(otherSeed, otherKey, "alpha-too", 1, cert.key, 1000000))
  c.printers.left = sim.printer(5, 5)
  key(c, "enter")
  check("offers each certificate", screenHas(c, "alpha-too"))
  check("names an unknown signer", has(c.screenText(), "From an untrusted root") or
    has(c.screenText(), "From Overworld Root"))
  local firstChoice = trust.certs()[1].name
  key(c, "enter")
  check("prints the one chosen", screenHas(c, "Printed."))
  check("chosen certificate", has(c.printers.left.text(), "[Certificate: " .. firstChoice .. " 1/2]"))
  key(c, "enter")
  screenHas(c, "Print certificate")
  key(c, "enter")
  check("backs out of the choice", screenHas(c, "alpha-too"))
  key(c, "backspace")
  check("nothing more printed", screenHas(c, "Print certificate") and #c.printers.left.pages == 2)

  -- printing the root server's identity
  key(root, "backspace")
  check("back to the root's menu", screenHas(root, "Print server identity"))
  pick(root, 2)
  check("root without a printer says so", screenHas(root, "Attach one"))
  key(root, "enter")
  screenHas(root, "Print server identity")
  root.printers.right = sim.printer(5, 5)
  key(root, "enter")
  check("identity printed", screenHas(root, "Printed."))
  local sheet = root.printers.right
  local identity, flat = sheet.text(), sheet.text():gsub("\n", "")
  local rootSeed, rootPublic = root.env.require("rootdb").keypair()
  local crypto = root.env.require("crypto")
  check("fits on one page", #sheet.pages == 1 and has(identity, "[Root server: Overworld Root]"))
  check("identity has the name", has(identity, "Overworld Root"))
  check("identity has the domain", has(identity, ".overworld"))
  check("identity has the computer", has(identity, "Computer: 10"))
  check("identity has the port", has(identity, "Port: " .. root.env.require("net").ROOT_PORT))
  check("identity has the fingerprint", has(identity, rootFinger))
  check("identity has the public key", has(flat, crypto.toHex(rootPublic)))
  check("identity leaves out the secret", not has(flat, crypto.toHex(rootSeed)))
  key(root, "enter")
  screenHas(root, "Print server identity")

  -- a non-admin can look but not add
  local guest = sim.computer(2, { width = width })
  local guestSession = { user = "guest", admin = false }
  guest.env.require("auth").create("root", "password1", true)
  guest.env.require("auth").create("guest", "password1", false)
  runScreen(guest, SETTINGS, guestSession)
  check("guest settings", screenHas(guest, "Network"))
  pick(guest, 2) -- no Users or Secure boot rows
  check("guest network page", screenHas(guest, "Root servers (0)"))
  pick(guest, 0)
  check("guest list", screenHas(guest, "Add root server..."))
  pick(guest, 0)
  check("guest can't add", screenHas(guest, "Only administrators"))

  -- no modem
  local lonely = sim.computer(3, { width = width, modems = {} })
  lonely.env.require("auth").create("admin", "password1", true)
  runScreen(lonely, SETTINGS, admin)
  screenHas(lonely, "Network")
  pick(lonely, 4)
  screenHas(lonely, "Root servers (0)")
  pick(lonely, 0)
  screenHas(lonely, "Add root server...")
  pick(lonely, 0)
  check("no modem says so", screenHas(lonely, "Attach one"))
end

scenario(51)
scenario(26) -- pocket computer

if failed > 0 then
  print(("%d passed, %d FAILED"):format(passed, failed))
  os.exit(1)
end
print(("ui: all %d passed"):format(passed))
