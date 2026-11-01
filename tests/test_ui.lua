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

-- Whether the row holding `text` ends with `tail`, ignoring the spaces after it.
local function rowEnds(c, text, tail)
  for row in (c.screenText() .. "\n"):gmatch("(.-)\n") do
    if has(row, text) then return row:gsub("%s+$", ""):sub(-#tail) == tail end
  end
  return false
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
  check("settings has a security page", screenHas(c, "Security"))
  check("main page has no network item", not has(c.screenText(), "Network"))
  check("main page keeps updates", has(c.screenText(), "Updates"))
  check("main page keeps the label", has(c.screenText(), "Computer label"))
  check("main page has no password item", not has(c.screenText(), "Change my password"))
  local function marked(label) return has(c.screenText(), label) and rowEnds(c, label, ">") end
  check("a submenu is marked", marked("Account") and marked("Security") and marked("Updates"))
  check("an action isn't marked", has(c.screenText(), "Computer label") and not rowEnds(c, "Computer label", ">"))

  -- Settings: Account, Security, Updates, Computer label
  pick(c, 0)
  check("account page", screenHas(c, "Change my password"))
  check("account page has users", has(c.screenText(), "Users"))
  check("the password is an action", not rowEnds(c, "Change my password", ">"))
  key(c, "backspace")
  screenHas(c, "Computer label")
  pick(c, 1)
  check("security page", screenHas(c, "Encryption keys"))
  check("security page has secure boot", has(c.screenText(), "Secure boot"))
  check("security page has root servers", has(c.screenText(), "Root servers (0)"))
  check("security page has the identity", has(c.screenText(), "Computer identity"))
  check("security page prints", has(c.screenText(), "Print computer cert"))
  -- Security: Encryption keys, Root servers, Computer identity, Print computer cert, Secure boot
  pick(c, 1)
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
  check("back to the security page", screenHas(c, "Print computer cert"))
  pick(c, 2)
  check("no printer says so", screenHas(c, "Attach one"))
  key(c, "enter")
  check("back after no printer", screenHas(c, "Print computer cert"))
  c.printers.left = sim.printer(1, 5)
  key(c, "enter")
  check("too little paper says so", screenHas(c, "needs paper"))
  check("nothing printed without enough paper", #c.printers.left.pages == 0)
  key(c, "enter")
  check("back after too little paper", screenHas(c, "Print computer cert"))
  c.printers.left = sim.printer(5, 1)
  key(c, "enter")
  check("too little ink says so", screenHas(c, "needs ink"))
  key(c, "enter")
  screenHas(c, "Print computer cert")
  c.printers.left = sim.printer(5, 5, 1)
  key(c, "enter")
  check("a full tray says how far it got", screenHas(c, "after 1 of 2 pages"))
  key(c, "enter")
  screenHas(c, "Print computer cert")
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
  screenHas(c, "Print computer cert")

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
  screenHas(c, "Print computer cert")
  key(c, "enter")
  check("backs out of the choice", screenHas(c, "alpha-too"))
  key(c, "backspace")
  check("nothing more printed", screenHas(c, "Print computer cert") and #c.printers.left.pages == 2)

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
  check("guest settings", screenHas(guest, "Security"))
  check("guest has no admin rows", not has(guest.screenText(), "Updates"))
  pick(guest, 0)
  check("guest account page", screenHas(guest, "Change my password"))
  check("guest can't see users", not has(guest.screenText(), "Users"))
  key(guest, "backspace")
  screenHas(guest, "Security")
  pick(guest, 1)
  check("guest security page", screenHas(guest, "Encryption keys"))
  check("guest can't see secure boot", not has(guest.screenText(), "Secure boot"))
  check("guest sees root servers", has(guest.screenText(), "Root servers (0)"))
  pick(guest, 1)
  check("guest list", screenHas(guest, "Add root server..."))
  pick(guest, 0)
  check("guest can't add", screenHas(guest, "Only administrators"))

  -- no modem
  local lonely = sim.computer(3, { width = width, modems = {} })
  lonely.env.require("auth").create("admin", "password1", true)
  runScreen(lonely, SETTINGS, admin)
  screenHas(lonely, "Security")
  pick(lonely, 1)
  screenHas(lonely, "Root servers (0)")
  pick(lonely, 1)
  screenHas(lonely, "Add root server...")
  pick(lonely, 0)
  check("no modem says so", screenHas(lonely, "Attach one"))

  -- About, for admins and everyone else
  local curious = sim.computer(4, { width = width, label = "beta" })
  curious.env.require("auth").create("admin", "password1", true)
  runScreen(curious, SETTINGS, admin)
  screenHas(curious, "Computer label")
  check("about isn't a submenu", not rowEnds(curious, "About", ">"))
  pick(curious, 4)
  check("about shows the version", screenHas(curious, "zOS " .. curious.env.require("system").VERSION))
  check("about shows the computer", has(curious.screenText(), "Computer: 4"))
  check("about shows the label", has(curious.screenText(), "Label: beta"))
  check("about shows free space", has(curious.screenText(), "Free space: 976.6 KB"))
  char(curious, "q")
  check("back from about", screenHas(curious, "Computer label"))

  local visitor = sim.computer(5, { width = width })
  visitor.env.require("auth").create("root", "password1", true)
  runScreen(visitor, SETTINGS, guestSession)
  screenHas(visitor, "About")
  pick(visitor, 2) -- Account, Security, About
  check("guest about", screenHas(visitor, "Free space:"))
  check("no label says so", has(visitor.screenText(), "Label: (none)"))
end

-- The desktop has an Apps menu, then the built-in apps. Each is in order of name, and apps that set
-- `admin` are left off for anyone else.
do
  for _, c in pairs(sim.computers) do sim.powerOff(c) end
  local function install(c, id, manifest, main)
    c.files[".zos/apps/" .. id .. "/main.lua"] = main or "-- " .. id
    c.files[".zos/apps/" .. id .. "/app.manifest"] = manifest
  end
  local function builtins(c)
    install(c, "appman", '{ name = "App Manager", version = "1.0.0", admin = true }')
    install(c, "files", '{ name = "Files", version = "1.0.0" }')
    install(c, "terminal", '{ name = "Terminal", version = "1.0.0", admin = true }')
  end
  local function desktop(id, session, others)
    local c = sim.computer(id)
    builtins(c)
    if others then others(c) end
    runScreen(c, "src/.zos/sys/desktop.lua", session)
    screenHas(c, "Settings")
    return c
  end
  local function inOrder(c, ...)
    local at = 0
    for _, text in ipairs({ ... }) do
      at = c.screenText():find(text, at + 1, true)
      if not at then return false end
    end
    return true
  end
  local function others(c)
    install(c, "zebra", '{ name = "Zebra", version = "1.0.0", priority = 1 }')
    install(c, "apple", '{ name = "apple", version = "1.0.0", priority = 99 }',
      "appleOpened()")
    install(c, "locked", '{ name = "Locked App", version = "1.0.0", admin = true }')
  end

  local admin = desktop(20, { user = "admin", admin = true }, others)
  check("Apps comes first, then the built-in apps by name",
    inOrder(admin, "Apps", "App Manager", "Files", "Terminal", "Settings"))
  check("Apps is a submenu", rowEnds(admin, "Apps", ">"))
  check("other apps aren't on the desktop", not has(admin.screenText(), "Zebra"))
  key(admin, "enter")
  check("the menu lists other apps by name, not priority", screenHas(admin, "Zebra")
    and inOrder(admin, "apple", "Locked App", "Zebra", "Back"))
  check("built-in apps aren't in the menu", not has(admin.screenText(), "Files"))
  key(admin, "enter")
  check("the menu opens an app", screenHas(admin, "appleOpened"))
  key(admin, "enter")
  check("the menu comes back after an app", screenHas(admin, "Zebra"))
  key(admin, "backspace")
  check("backspace leaves the menu", screenHas(admin, "Settings"))

  local guest = desktop(21, { user = "guest", admin = false }, others)
  check("users see built-in apps they can open", has(guest.screenText(), "Files"))
  check("users don't see admin built-in apps", not has(guest.screenText(), "Terminal"))
  key(guest, "enter")
  check("users see normal apps", screenHas(guest, "Zebra"))
  check("users don't see admin apps", not has(guest.screenText(), "Locked App"))

  local empty = desktop(22, { user = "guest", admin = false }, function(c)
    install(c, "locked", '{ name = "Locked App", version = "1.0.0", admin = true }')
  end)
  key(empty, "enter")
  check("the menu says when there are no apps", screenHas(empty, "No apps installed"))
  key(empty, "enter")
  check("leaving the empty menu", screenHas(empty, "Settings"))

  local adminOnly = { appman = true, terminal = true, ["setup-disk"] = true, ["mail-server"] = true, ["root-server"] = true }
  for _, id in ipairs({ "appman", "terminal", "setup-disk", "mail-server", "root-server", "files", "fileshare", "mail" }) do
    local file = assert(io.open("apps/" .. id .. "/app.manifest"))
    local text = file:read("*a")
    file:close()
    check(id .. " has the right admin flag", has(text, "admin = true") == (adminOnly[id] == true))
  end
end

scenario(51)
scenario(26) -- pocket computer

if failed > 0 then
  print(("%d passed, %d FAILED"):format(passed, failed))
  os.exit(1)
end
print(("ui: all %d passed"):format(passed))
