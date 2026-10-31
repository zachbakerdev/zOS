-- zOS Root Server: signs other computers' keys, so that computers which trust this server can
-- tell who they're talking to. The service in service.lua talks to the network; this is where
-- an administrator sets it up and decides who gets a certificate.

local session = ...
local ui = require("ui")
local crypto = require("crypto")
local net = require("net")
local printer = require("printer")
local system = require("system")
local trust = require("trust")
local db = require("rootdb")

local TITLE = "Root Server"

local function done(success, ok, err)
    ui.message(TITLE, ok and success or err, ok and ui.theme.good or ui.theme.bad)
end

local function askName(intro, default)
    local err
    while true do
        ui.screen(TITLE)
        ui.text(intro, ui.theme.dim)
        ui.text("")
        if err then ui.text(err, ui.theme.bad) ui.text("") end
        local name = ui.input("Server name", nil, default)
        local ok, why = trust.validName(name)
        if ok then return name end
        err = why
    end
end

local function askTld(default)
    local err
    while true do
        ui.screen(TITLE)
        ui.text("Hostnames this server gives out end in this, like zmail." .. default ..
            ". It can't change while hostnames are in use.", ui.theme.dim)
        ui.text("")
        if err then ui.text(err, ui.theme.bad) ui.text("") end
        local tld = ui.input("Top-level domain", nil, default)
        local ok, why = trust.validTld(tld)
        if ok then return tld end
        err = why
    end
end

local function setup()
    local name = askName("This computer will vouch for other computers. Every computer that trusts " ..
        "it will believe what it signs, so choose a server only admins can log in to.", trust.defaultName())
    local tld = askTld(trust.tldFromName(name))
    crypto.addEntropy(name .. os.clock())
    ui.text("Creating the root key...", ui.theme.dim)
    db.setup(name, tld)
    system.log(session.user .. " set up root server " .. name .. " ." .. tld .. " " .. db.fingerprint())
end

local function showRequest(entry)
    return "Name: " .. entry.name .. "\nComputer: " .. tostring(entry.from) .. "\n\nFingerprint:\n" ..
        crypto.fingerprint(crypto.fromHex(entry.key)) .. "\n\nStatus: " .. entry.status
end

local function reviewPending(entry)
    ui.screen(TITLE .. " - " .. entry.name)
    ui.text("Computer " .. tostring(entry.from) .. " wants to be '" .. entry.name .. "'.")
    ui.text("")
    ui.text("Fingerprint:", ui.theme.dim)
    ui.text(crypto.fingerprint(crypto.fromHex(entry.key)), ui.theme.accent)
    ui.text("")
    ui.text("Approve this only if computer " .. tostring(entry.from) .. " itself shows the same " ..
        "fingerprint in Settings > Network, and you're sure it deserves this name.", ui.theme.dim)
    ui.text("")
    if ui.confirm("Sign this key?") then
        ui.text("Signing...", ui.theme.dim)
        local ok, err = db.approve(entry.key, entry.name, entry.from)
        if ok then system.log(session.user .. " signed " .. entry.name .. " for computer " .. tostring(entry.from)) end
        return done("Signed. It will pick up its certificate by itself.", ok, err)
    end
    ui.text("")
    if ui.confirm("Refuse it?") then
        db.setStatus(entry.key, "denied")
        system.log(session.user .. " refused " .. entry.name .. " for computer " .. tostring(entry.from))
    end
end

local function manage(entry)
    if entry.status == "pending" then return reviewPending(entry) end
    local actions = {}
    if entry.status == "issued" then
        actions.r = "revoke"
    else
        actions.f = "forget"
    end
    local help = entry.status == "issued" and "R: revoke  Q: back" or "F: forget  Q: back"
    local action = ui.pager(TITLE .. " - " .. entry.name, showRequest(entry), help, actions)
    ui.screen(TITLE)
    if action == "revoke" then
        ui.text("Revoke '" .. entry.name .. "'? It can't renew, and the name is free for others. " ..
            "Its current certificate works until it expires, in up to " .. db.config().days ..
            " days, because computers don't check back with this server.", ui.theme.accent)
        ui.text("")
        if ui.confirm("Revoke it?") then
            db.setStatus(entry.key, "revoked")
            system.log(session.user .. " revoked " .. entry.name)
        end
    elseif action == "forget" then
        ui.text("Forget this entry? The computer will be able to ask again.", ui.theme.accent)
        ui.text("")
        if ui.confirm("Forget it?") then db.forget(entry.key) end
    end
end

local function requests()
    local selected = 1
    while true do
        local list = db.list()
        local items = {}
        for _, entry in ipairs(list) do
            items[#items + 1] = {
                label = entry.name .. "  [" .. entry.status .. "]",
                hint = crypto.fingerprint(crypto.fromHex(entry.key)),
                fg = entry.status == "pending" and ui.theme.accent or
                    (entry.status == "issued" and ui.theme.fg or ui.theme.dim),
            }
        end
        if #list == 0 then items[1] = { label = "(no requests yet)", fg = ui.theme.dim } end
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }
        selected = ui.menu({ title = TITLE .. " - Requests", items = items, selected = selected, back = true })
        if selected == nil or not list[selected] then return end
        manage(list[selected])
    end
end

-- Everything someone needs to check they've found this server. Only the public half of the key.
local function identityText()
    local _, public = db.keypair()
    return "Name: " .. db.config().name .. "\nTop-level domain: ." ..
        db.config().zone.tld .. "\nComputer: " .. os.getComputerID() ..
        "\nPort: " .. net.ROOT_PORT .. "\n\nFingerprint:\n" .. db.fingerprint() ..
        "\n\nPublic key:\n" .. crypto.toHex(public) ..
        "\n\nPeople adding this server in Settings > Network should see this fingerprint."
end

local function serverInfo()
    ui.pager(TITLE .. " - This server", identityText())
end

local function printIdentity()
    ui.screen(TITLE)
    ui.text("Printing...", ui.theme.dim)
    done("Printed. It's in the printer's output tray.", printer.print("Root server: " .. db.config().name, identityText()))
end

local function rename()
    local name = askName("Computers that already trust this server keep showing the old name.", db.config().name)
    ui.text("Signing the new name...", ui.theme.dim)
    db.rename(name)
    system.log(session.user .. " renamed the root server to " .. name)
end

local function changeTld()
    local tld = askTld(db.config().zone.tld)
    ui.text("Signing the top-level domain...", ui.theme.dim)
    local ok, err = db.setTld(tld)
    if ok then system.log(session.user .. " set the top-level domain to ." .. tld) end
    done("Hostnames now end in ." .. tld .. ".", ok, err)
end

local function lifetime()
    ui.screen(TITLE)
    ui.text("How many days a certificate lasts. Longer means fewer renewals, but a revoked " ..
        "certificate keeps working for longer. New certificates only.", ui.theme.dim)
    ui.text("")
    local days = tonumber(ui.input("Days", nil, tostring(db.config().days)))
    if not days or days < 8 or days > 365 or days ~= math.floor(days) then
        return ui.message(TITLE, "Enter a whole number from 8 to 365.", ui.theme.bad)
    end
    db.setConfig({ days = days })
end

local function newKey()
    ui.screen(TITLE)
    ui.text("A new key ends this server as computers know it. All its certificates stop being " ..
        "accepted, every computer has to add it again, and all requests are deleted.", ui.theme.bad)
    ui.text("")
    if not ui.confirm("Create a new root key?") then return end
    ui.text("Creating the root key...", ui.theme.dim)
    db.setup(db.config().name, db.config().zone.tld)
    system.log(session.user .. " replaced the root key: " .. db.fingerprint())
    ui.message(TITLE, "New fingerprint: " .. db.fingerprint(), ui.theme.good)
end

if not session.admin then
    return ui.message(TITLE, "Only administrators can use the root server.", ui.theme.bad)
end

if not db.ready() then setup() end
db.ensureZone()

local selected = 1
while true do
    local config = db.config()
    local pending = 0
    for _, entry in ipairs(db.list()) do
        if entry.status == "pending" then pending = pending + 1 end
    end
    local items = {
        { label = "Requests" .. (pending > 0 and (" (" .. pending .. " waiting)") or ""), action = requests,
          hint = "Approve computers and manage certificates", fg = pending > 0 and ui.theme.accent or nil },
        { label = "This server", action = serverInfo, hint = "Name and fingerprint" },
        { label = "Print server identity", action = printIdentity, hint = "For others to verify this server against" },
        { label = "Name: " .. config.name, action = rename, hint = "What computers see when they look for roots" },
        { label = "Top-level domain: ." .. config.zone.tld, action = changeTld, hint = "What hostnames here end in" },
        { label = "Certificates last " .. config.days .. " days", action = lifetime, hint = "How long a signature is good for" },
        { label = "Serving: " .. (config.online and "on" or "OFF"),
          action = function() db.setConfig({ online = not config.online }) end,
          hint = "Announce this server and answer requests", fg = not config.online and ui.theme.bad or nil },
        { label = "Create a new root key", action = newKey, hint = "Start over with a new identity" },
        { label = "Back", fg = ui.theme.dim },
    }
    selected = ui.menu({ title = TITLE, items = items, selected = selected, back = true })
    if selected == nil or not items[selected].action then return end
    items[selected].action()
end
