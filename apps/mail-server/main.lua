-- zOS Mail Server: get a hostname from a root server and manage accounts. The service in
-- service.lua talks to the network.

local session = ...
local ui = require("ui")
local db = require("maildb")
local net = require("net")
local system = require("system")
local trust = require("trust")

local TITLE = "Mail Server"

local function fail(text)
    ui.message(TITLE, tostring(text), ui.theme.bad)
end

local function daysLeft(cert)
    return math.max(0, math.ceil((cert.expires - os.epoch("utc")) / 86400000))
end

------------------------------------------------------------------------------
-- Hostname
------------------------------------------------------------------------------

-- Polls until the root server's admin has answered. Returns true once it's installed. Backspace
-- leaves the request with them, and asking again later picks up the answer.
local function waitForHostname(root, host)
    while true do
        ui.screen(TITLE .. " - Hostname")
        ui.text("Asking " .. root.name .. " for " .. host .. ".")
        ui.text("")
        ui.text("Your fingerprint:", ui.theme.dim)
        ui.text(trust.fingerprint(select(2, trust.identity())), ui.theme.accent)
        ui.text("")
        local status, err = net.requestCertificate(root, host)
        if status == "issued" then
            db.setHostname(host, root.key)
            system.log(session.user .. " got the hostname " .. host .. " from " .. root.name)
            ui.message(TITLE, "This server is now " .. host .. ".", ui.theme.good)
            return true
        elseif status == "denied" then
            return fail(root.name .. " refused the request.")
        elseif not status then
            return fail("Couldn't get the hostname:\n\n" .. tostring(err))
        end

        ui.text("Waiting for the root server's administrator to approve it under Requests. They " ..
            "should compare this fingerprint with the one on their screen. Backspace stops waiting.", ui.theme.dim)
        local timer = os.startTimer(5)
        while true do
            local e, a = os.pullEventRaw()
            if e == "timer" and a == timer then break end
            if e == "key" and a == keys.backspace then return end
        end
    end
end

local function chooseRoot()
    local roots = trust.roots()
    if #roots == 0 then
        return fail("This computer doesn't trust a root server yet. Add one in Settings > Network > " ..
            "Root servers, then come back.")
    end
    if #roots == 1 then return roots[1] end
    local items = {}
    for _, root in ipairs(roots) do items[#items + 1] = { label = root.name, hint = root.fingerprint } end
    items[#items + 1] = { label = "Back", fg = ui.theme.dim }
    local selected = ui.menu({ title = TITLE .. " - Choose a root server", items = items, back = true })
    return selected and roots[selected]
end

local function acquireHostname()
    local root = chooseRoot()
    if not root then return end
    ui.screen(TITLE)
    ui.text("Asking " .. root.name .. " for its top-level domain...", ui.theme.dim)
    local tld, err = net.tldOf(root)
    if not tld then return fail("Couldn't reach " .. root.name .. ":\n\n" .. tostring(err)) end

    local why
    while true do
        ui.screen(TITLE .. " - Hostname")
        ui.text("Pick the name of this server. Addresses here will look like you@name." .. tld ..
            ". The root server's administrator has to approve it.", ui.theme.dim)
        ui.text("")
        if why then ui.text(why, ui.theme.bad) ui.text("") end
        local label = ui.input("Name, without ." .. tld)
        if label == "" then return end
        local host = label .. "." .. tld
        local ok, reason = trust.parseHost(host)
        if ok then return waitForHostname(root, host) end
        why = reason
    end
end

local function hostnameDetails()
    local host, cert = db.hostname()
    local root = trust.root(cert.root)
    local action = ui.pager(TITLE .. " - " .. host, "Hostname: " .. host .. "\nComputer: " .. os.getComputerID() ..
        "\nRoot server: " .. (root and root.name or "no longer trusted") ..
        "\nCertificate: " .. daysLeft(cert) .. " days left, renewed by itself\n\nFingerprint:\n" ..
        trust.fingerprint(select(2, trust.identity())), "C: change hostname  Q: back", { c = "change" })
    if action == "change" then
        ui.screen(TITLE)
        ui.text("Everyone's address here changes with it, and mail to the old one will bounce.", ui.theme.bad)
        ui.text("")
        if ui.confirm("Get a different hostname?") then acquireHostname() end
    end
end

------------------------------------------------------------------------------
-- Accounts
------------------------------------------------------------------------------

local function addAccount()
    ui.screen(TITLE .. " - New account")
    local user = ui.input("Account name")
    if user == "" then return end
    local password = ui.input("Password", "*")
    ui.text("Creating the account...", ui.theme.dim)
    local ok, err = db.createAccount(user, password)
    if not ok then return fail(err) end
    system.log(session.user .. " created mail account " .. user)
end

local function manageAccount(user)
    local box = db.index(user)
    local host = db.hostname()
    local items = {
        { label = "Reset password", hint = "Signs it out everywhere" },
        { label = "Delete account", hint = "Deletes its mail too", fg = ui.theme.bad },
        { label = "Back", fg = ui.theme.dim },
    }
    local title = user .. (host and ("@" .. host) or "") .. " (" .. #box .. " messages)"
    local choice = ui.menu({ title = title, items = items, back = true })
    if choice == 1 then
        ui.screen(TITLE)
        local password = ui.input("New password", "*")
        ui.text("Changing the password...", ui.theme.dim)
        local ok, err = db.setPassword(user, password)
        if not ok then return fail(err) end
        system.log(session.user .. " reset the password of mail account " .. user)
    elseif choice == 2 then
        ui.screen(TITLE)
        ui.text("Delete " .. user .. " and " .. #box .. " messages? This can't be undone.", ui.theme.bad)
        ui.text("")
        if ui.confirm("Delete it?") then
            db.removeAccount(user)
            system.log(session.user .. " deleted mail account " .. user)
        end
    end
end

local function accounts()
    local selected = 1
    while true do
        local list = db.accounts()
        local items = {}
        for _, user in ipairs(list) do items[#items + 1] = { label = user } end
        if #list == 0 then items[1] = { label = "(none yet)", fg = ui.theme.dim } end
        items[#items + 1] = { label = "Add an account", action = addAccount }
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }
        selected = ui.menu({ title = TITLE .. " - Accounts", items = items, selected = selected, back = true })
        if selected == nil then return end
        local item = items[selected]
        if list[selected] then
            manageAccount(list[selected])
        elseif item.action then
            item.action()
        elseif item.label == "Back" then
            return
        end
    end
end

local function queue()
    local lines = {}
    for _, entry in ipairs(db.outbox()) do
        lines[#lines + 1] = entry.message.from .. " to " .. entry.host .. "\n  tried " .. entry.attempts ..
            " times" .. (entry.lastError and (": " .. entry.lastError) or "")
    end
    ui.pager(TITLE .. " - Waiting to send", #lines > 0 and table.concat(lines, "\n\n") or "Nothing is waiting.")
end

if not session.admin then
    return ui.message(TITLE, "Only administrators can use the mail server.", ui.theme.bad)
end

if not db.hostname() then
    ui.message(TITLE, "This server needs a hostname from a root server before it can take mail.")
    acquireHostname()
    if not db.hostname() then return end
end

local selected = 1
while true do
    local host, cert = db.hostname()
    local config = db.config()
    local waiting = #db.outbox()
    local items = {
        { label = "Hostname: " .. (host or "none"), action = host and hostnameDetails or acquireHostname,
          hint = cert and (daysLeft(cert) .. " days left on its certificate") or "Get one from a root server",
          fg = not host and ui.theme.bad or nil },
        { label = "Accounts (" .. #db.accounts() .. ")", action = accounts, hint = "Add, reset and delete" },
        { label = "New accounts: " .. (config.signups and "open" or "admins only"),
          action = function() db.setConfig({ signups = not config.signups }) end,
          hint = "Whether Mail can create accounts here" },
        { label = "Waiting to send (" .. waiting .. ")", action = queue, hint = "Mail for other servers" },
        { label = "Back", fg = ui.theme.dim },
    }
    selected = ui.menu({ title = TITLE, items = items, selected = selected, back = true })
    if selected == nil or not items[selected].action then return end
    items[selected].action()
end
