-- Settings: passwords, keys, users, secure boot, the network, updates and the computer's label.

local auth = require("auth")
local crypto = require("crypto")
local keys = require("keys")
local net = require("net")
local printer = require("printer")
local system = require("system")
local trust = require("trust")
local ui = require("ui")
local update = require("update")

local session = ...

local TITLE = "Settings"
local DAY = 24 * 3600 * 1000

local function fail(text) ui.message(TITLE, text, ui.theme.bad) end
local function done(text) ui.message(TITLE, text, ui.theme.good) end

-- Run a list of { label, hint, action } until Back. `build` is called each time, so counts stay
-- right. An item without an action ends the menu.
local function page(title, build)
    local selected = 1
    while true do
        local items = build()
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }
        selected = ui.menu({ title = title, items = items, selected = selected, back = true })
        if not selected or not items[selected].action then return end
        items[selected].action()
    end
end

local function needAdmin()
    if session.admin then return true end
    fail("Only administrators can do this.")
    return false
end

-- Accounts --------------------------------------------------------------------------------------

local function askNewPassword(title)
    ui.screen(title)
    local first = ui.input("New password", "*")
    if first == "" then return nil end
    local second = ui.input("Again", "*")
    if first ~= second then
        fail("Those didn't match.")
        return nil
    end
    return first
end

local function changePassword()
    ui.screen("Change my password")
    local old = ui.input("Current password", "*")
    if old == "" then return end
    local new = askNewPassword("Change my password")
    if not new then return end
    ui.screen("Change my password")
    ui.text("Working...", ui.theme.dim)
    local ok, err = auth.changePassword(session.user, old, new)
    if ok then
        system.log(session.user .. " changed their password")
        done("Password changed.")
    else
        fail(err)
    end
end

local function addUser()
    ui.screen("Add a user")
    local name = ui.input("Name")
    if name == "" then return end
    local password = askNewPassword("Add a user")
    if not password then return end
    ui.screen("Add a user")
    local admin = ui.confirm("Make " .. name .. " an administrator?")
    local ok, err = auth.create(name, password, admin)
    if ok then
        system.log(session.user .. " added user " .. name)
        done("Added " .. name .. ".")
    else
        fail(err)
    end
end

local function manageUser(entry)
    page("User " .. entry.name, function()
        return {
            { label = "Reset password", hint = "Their encrypted data is lost", action = function()
                ui.screen("Reset password")
                ui.text("Resetting a password loses this user's key, and anything encrypted with it.", ui.theme.bad)
                ui.text("")
                if not ui.confirm("Reset the password?") then return end
                local password = askNewPassword("Reset password")
                if not password then return end
                local ok, err = auth.resetPassword(entry.name, password)
                if ok then
                    system.log(session.user .. " reset the password of " .. entry.name)
                    done("Password reset.")
                else
                    fail(err)
                end
            end },
            { label = "Remove user", hint = "Their files are kept", action = function()
                ui.screen("Remove user")
                if not ui.confirm("Remove " .. entry.name .. "?") then return end
                local ok, err = auth.remove(entry.name)
                if ok then
                    system.log(session.user .. " removed user " .. entry.name)
                    done("Removed " .. entry.name .. ".")
                else
                    fail(err)
                end
            end },
        }
    end)
end

local function users()
    if not needAdmin() then return end
    page("Users", function()
        local items = { { label = "Add a user...", action = addUser } }
        for _, entry in ipairs(auth.list()) do
            items[#items + 1] = {
                label = entry.name .. (entry.admin and "  (admin)" or ""),
                action = function() manageUser(entry) end,
            }
        end
        return items
    end)
end

-- Keys ------------------------------------------------------------------------------------------

local function trustedKeys()
    page("Trusted keys", function()
        local items = {}
        for _, entry in ipairs(keys.knownList()) do
            items[#items + 1] = { label = entry.address, hint = entry.fingerprint, action = function()
                if not needAdmin() then return end
                ui.screen("Trusted keys")
                ui.text(entry.address)
                ui.text(entry.fingerprint, ui.theme.accent)
                ui.text("")
                if ui.confirm("Forget it?") then
                    keys.forgetKnown(entry.address)
                    system.log(session.user .. " forgot the key of " .. entry.address)
                end
            end }
        end
        if #items == 0 then items[1] = { label = "(none yet)", fg = ui.theme.dim, action = function() end } end
        return items
    end)
end

local function encryptionKeys()
    page("Encryption keys", function()
        return {
            { label = "My key", hint = "Your fingerprint", action = function()
                ui.pager("My key", "Fingerprint:\n" .. crypto.fingerprint(session.publicKey))
            end },
            { label = "Trusted keys (" .. #keys.knownList() .. ")", hint = "Keys pinned by address", action = trustedKeys },
        }
    end)
end

-- Secure boot -----------------------------------------------------------------------------------

local function secureBoot()
    if not needAdmin() then return end
    local on = system.secureBoot()
    ui.screen("Secure boot")
    ui.text("Secure boot is " .. (on and "on" or "off") .. ".", on and ui.theme.good or ui.theme.bad)
    ui.text("")
    if on then ui.text("While it's off, anyone with a floppy can boot their own program and skip the login.", ui.theme.bad) ui.text("") end
    if not ui.confirm("Turn it " .. (on and "off" or "on") .. "?") then return end
    ui.text("")
    local password = ui.input("Password", "*")
    if not auth.verify(session.user, password) then return fail("Wrong password.") end
    system.setSecureBoot(not on, session.user)
    done("Secure boot is " .. (on and "off" or "on") .. ".")
end

-- Network ---------------------------------------------------------------------------------------

local function daysLeft(cert)
    return math.floor((cert.expires - os.epoch("utc")) / DAY)
end

local function certSummary(cert)
    return "Name: " .. cert.name .. "\nComputer: " .. cert.id .. "\n\n" .. daysLeft(cert) .. " days left"
end

local function dateText(ms)
    return os.date("!%Y-%m-%d", math.floor(ms / 1000))
end

-- Everything someone needs to check a certificate by hand.
local function certRecord(cert)
    local _, public = trust.identity()
    local root = trust.root(cert.root)
    return table.concat({
        "Certificate: " .. cert.name .. "\nComputer: " .. cert.id .. "\nIssued: " .. dateText(cert.issued) ..
            "\nExpires: " .. dateText(cert.expires),
        "Fingerprint:\n" .. crypto.fingerprint(public),
        "Public key:\n" .. cert.key,
        "Signed by:\n" .. (root and root.name or "An untrusted root") .. "\n" ..
            crypto.fingerprint(crypto.fromHex(cert.root)),
        "Root key:\n" .. cert.root,
        "Signature:\n" .. cert.sig,
    }, "\n\n")
end

local function thisComputer()
    local _, public = trust.identity()
    ui.pager("This computer", "Name: " .. trust.defaultName() .. "\nComputer: " .. os.getComputerID() ..
        "\n\nFingerprint:\n" .. crypto.fingerprint(public) .. "\n\nCertificates: " .. #trust.certs())
end

-- Keeps asking until there's an answer. A request stays on the server, so stopping loses nothing.
local function requestCertificate(root, name)
    while true do
        ui.screen("Certificate")
        ui.text("Asking " .. root.name .. "...", ui.theme.dim)
        ui.text("The server's admin has to approve this. Your fingerprint is under This computer.", ui.theme.dim)
        ui.text("Backspace stops waiting.", ui.theme.dim)
        local status, err = net.requestCertificate(root, name)
        if status == "issued" then
            system.log(session.user .. " got a certificate from " .. root.name)
            return done("Certificate installed.")
        elseif status == "denied" then
            return fail("The root server refused this request.")
        elseif status ~= "pending" then
            return fail(tostring(err))
        end

        local timer = os.startTimer(5)
        while true do
            local event, value = os.pullEvent()
            if event == "timer" and value == timer then break end
            if event == "key" and value == _G.keys.backspace then return end -- `keys` is the library
        end
    end
end

local function manageRoot(root)
    page(root.name, function()
        local cert = trust.cert(root.key)
        local items = {}
        if cert then
            items[#items + 1] = { label = "Renew certificate", action = function()
                if not needAdmin() then return end
                requestCertificate(root, cert.name)
            end }
            items[#items + 1] = { label = "Details", hint = "Your certificate", action = function()
                ui.pager("Certificate", certSummary(cert))
            end }
        else
            items[#items + 1] = { label = "About this server", hint = root.key:sub(1, 16), action = function()
                ui.pager(root.name, "Computer: " .. tostring(root.host) .. "\n\nFingerprint:\n" ..
                    crypto.fingerprint(crypto.fromHex(root.key)))
            end }
            items[#items + 1] = { label = "Request a certificate", action = function()
                if not needAdmin() then return end
                ui.screen("Certificate")
                ui.text("Choose a name for this computer. A hostname looks like name.tld.", ui.theme.dim)
                ui.text("")
                local name = ui.input("Name", nil, trust.defaultName())
                if name == "" then return end
                local ok, why = trust.validName(name)
                if not ok then return fail(why) end
                requestCertificate(root, name)
            end }
        end
        items[#items + 1] = { label = "Remove this root server", action = function()
            if not needAdmin() then return end
            ui.screen(root.name)
            if ui.confirm("Stop trusting " .. root.name .. "?") then
                trust.removeRoot(root.key)
                system.log(session.user .. " removed root server " .. root.name)
                error({ left = true }, 0)
            end
        end }
        return items
    end)
end

local function addRoot()
    if not needAdmin() then return end
    if #net.modems() == 0 then return fail("There's no modem.\nAttach one and try again.") end
    ui.screen("Add root server")
    ui.text("Looking for root servers...", ui.theme.dim)
    local found = net.findRoots(3)
    if #found == 0 then return fail("No root servers answered. Check that this computer has a modem in range.") end

    local items = {}
    for i, entry in ipairs(found) do
        items[i] = { label = entry.name .. "  " .. entry.fingerprint, hint = entry.fingerprint .. "  computer " .. entry.host }
    end
    items[#items + 1] = { label = "Back", fg = ui.theme.dim }
    local choice = ui.menu({ title = "Add root server", items = items, back = true })
    local entry = choice and found[choice]
    if not entry then return end

    ui.screen("Add root server")
    ui.text(entry.name)
    ui.text(entry.fingerprint, ui.theme.accent)
    ui.text("")
    ui.text("Anyone can announce a server under any name. Compare this fingerprint with the one the server shows.", ui.theme.dim)
    ui.text("")
    if not ui.confirm("Trust this root server?") then return end
    trust.addRoot(entry.key, entry.name, entry.host)
    system.log(session.user .. " added root server " .. entry.name)
    done("Added " .. entry.name .. ".")
end

local function rootServers()
    page("Root servers", function()
        local items = {}
        for _, root in ipairs(trust.roots()) do
            items[#items + 1] = { label = root.name, hint = crypto.fingerprint(crypto.fromHex(root.key)), action = function()
                local ok, err = pcall(manageRoot, root)
                if not ok and not (type(err) == "table" and err.left) then error(err, 0) end
            end }
        end
        items[#items + 1] = { label = "Add root server...", hint = "Find servers in range", action = addRoot }
        return items
    end)
end

local function chooseCertificate(certs)
    if #certs == 1 then return certs[1] end
    local items = {}
    for i, cert in ipairs(certs) do
        local root = trust.root(cert.root)
        items[i] = { label = cert.name, hint = root and ("From " .. root.name) or "From an untrusted root" }
    end
    items[#items + 1] = { label = "Back", fg = ui.theme.dim }
    local choice = ui.menu({ title = "Print certificate", items = items, back = true })
    return choice and certs[choice]
end

local function printCertificate()
    local certs = trust.certs()
    if #certs == 0 then return fail("This computer has no certificate.") end
    if not printer.available() then return fail("There's no printer.\nAttach one and try again.") end
    local cert = chooseCertificate(certs)
    if not cert then return end
    local ok, err = printer.print("Certificate: " .. cert.name, certRecord(cert))
    if ok then done("Printed. It's in the printer's output tray.") else fail(err) end
end

local function network()
    page("Network", function()
        return {
            { label = "Root servers (" .. #trust.roots() .. ")", hint = "Servers this computer trusts", action = rootServers },
            { label = "This computer", hint = "Name and fingerprint", action = thisComputer },
            { label = "Print certificate", hint = "Needs a printer", action = printCertificate },
        }
    end)
end

-- Updates ---------------------------------------------------------------------------------------

local function updates()
    if not needAdmin() then return end
    page("Updates", function()
        local auto = system.config().autoUpdate ~= false
        local staged = update.stagedVersion()
        local items = {
            { label = "Automatic updates: " .. (auto and "on" or "off"), action = function()
                system.setConfig({ autoUpdate = not auto })
                system.log(session.user .. " turned automatic updates " .. (auto and "off" or "on"))
            end },
            { label = "Check now", hint = "zOS " .. system.VERSION, action = function()
                ui.screen("Updates")
                ui.text("Checking...", ui.theme.dim)
                local info, err = update.check()
                if info == nil then return fail(err) end
                if info == false then return done("zOS " .. system.VERSION .. " is up to date.") end
                ui.text("zOS " .. info.version .. " is available.", ui.theme.accent)
                if info.version == update.failedVersion() then
                    ui.text("This version failed to boot here before.", ui.theme.bad)
                end
                if not ui.confirm("Download it?") then return end
                ui.text("Downloading...", ui.theme.dim)
                local ok
                ok, err = update.download(info)
                if not ok then return fail(err) end
                done("It will install the next time this computer restarts.")
            end },
        }
        if staged then
            items[#items + 1] = { label = "Restart to install " .. staged, action = system.reboot }
        end
        return items
    end)
end

-- Other -----------------------------------------------------------------------------------------

local function computerLabel()
    if not needAdmin() then return end
    ui.screen("Computer label")
    local label = ui.input("Label", nil, os.getComputerLabel())
    os.setComputerLabel(label ~= "" and label or nil)
end

page(TITLE, function()
    local items = {
        { label = "Change my password", action = changePassword },
        { label = "Encryption keys", action = encryptionKeys },
    }
    if session.admin then
        items[#items + 1] = { label = "Users", action = users }
        items[#items + 1] = { label = "Secure boot", action = secureBoot }
    end
    items[#items + 1] = { label = "Network", action = network }
    if session.admin then
        items[#items + 1] = { label = "Updates", action = updates }
        items[#items + 1] = { label = "Computer label", action = computerLabel }
    end
    return items
end)
