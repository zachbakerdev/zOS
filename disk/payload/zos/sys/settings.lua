-- zOS settings: your password, encryption keys, the network, the computer label and, for
-- admins, users, secure boot and updates.

local session = ...
local ui = require("ui")
local auth = require("auth")
local keys = require("keys")
local crypto = require("crypto")
local system = require("system")
local net = require("net")
local trust = require("trust")
local update = require("update")
local printer = require("printer")

local TITLE = "Settings"
local me = session.user

-- Usage: done("Success message", someCall()) where someCall returns ok, err.
local function done(success, ok, err)
    ui.message(TITLE, ok and success or err, ok and ui.theme.good or ui.theme.bad)
end

local function changePassword()
    ui.screen(TITLE)
    local current = ui.input("Current password", "*")
    if not auth.verify(me, current) then
        return ui.message(TITLE, "Incorrect password.", ui.theme.bad)
    end
    local password = ui.newPassword(auth.checkPassword, function() ui.screen(TITLE) end, "New password")
    local ok, err = auth.setPassword(me, password)
    if not ok then return done(nil, ok, err) end
    -- Your secret key is encrypted with your password, so re-encrypt it too.
    if keys.rewrap(me, current, password) then return done("Password changed.", true) end
    session.secretKey, session.publicKey = keys.create(me, password)
    system.log(me .. "'s key couldn't be re-encrypted, so a new one was created")
    ui.message(TITLE, "Password changed. Your old encryption key couldn't be unlocked, so you have " ..
        "a new one.", ui.theme.accent)
end

local function addUser()
    local redraw = function() ui.screen(TITLE .. " - Add user") end
    local name = ui.newUsername(function(n)
        if auth.exists(n) then return false, "That user already exists." end
        return auth.validName(n)
    end, redraw)
    local password = ui.newPassword(auth.checkPassword, function()
        redraw()
        ui.text("Username: " .. name, ui.theme.dim)
        ui.text("")
    end)
    ui.text("")
    local admin = ui.confirm("Make " .. name .. " an administrator?")
    ui.text("Creating account and encryption keys...", ui.theme.dim)
    local ok, err = auth.create(name, password, admin)
    if ok then system.log(me .. " created user " .. name .. (admin and " (admin)" or "")) end
    done("Created user '" .. name .. "'.", ok, err)
end

local function manageUser(user)
    local items = {
        { label = "Reset password" },
        { label = "Delete user" },
        { label = "Back", fg = ui.theme.dim },
    }
    local choice = ui.menu({ title = TITLE .. " - " .. user.name, items = items, back = true })
    if choice == 1 then
        if user.name == me then return changePassword() end -- keeps your key
        ui.screen(TITLE)
        ui.text("Without their old password, " .. user.name .. "'s encryption key can't be kept. " ..
            "They will get a new one, and anything encrypted to the old key will be unreadable.",
            ui.theme.accent)
        ui.text("")
        if not ui.confirm("Reset the password anyway?") then return end
        local password = ui.newPassword(auth.checkPassword, function() ui.screen(TITLE) end,
            "New password for " .. user.name)
        local ok, err = auth.setPassword(user.name, password)
        if ok then
            ui.text("Creating a new encryption key...", ui.theme.dim)
            keys.create(user.name, password)
            system.log(me .. " reset the password and key of " .. user.name)
        end
        done("Password reset.", ok, err)
    elseif choice == 2 then
        ui.screen(TITLE)
        if user.name == me then
            return ui.message(TITLE, "You can't delete the account you are logged in with.", ui.theme.bad)
        end
        if ui.confirm("Delete user '" .. user.name .. "'?") then
            local ok, err = auth.remove(user.name)
            if ok then system.log(me .. " deleted user " .. user.name) end
            done("Deleted '" .. user.name .. "'.", ok, err)
        end
    end
end

local function users()
    while true do
        local list = auth.list()
        local items = { { label = "Add user...", hint = "Create a new account" } }
        for _, u in ipairs(list) do
            items[#items + 1] = { label = u.name .. (u.admin and "  [admin]" or ""), hint = "Reset password or delete" }
        end
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }
        local choice = ui.menu({ title = TITLE .. " - Users", items = items, back = true })
        if choice == nil or choice == #items then return
        elseif choice == 1 then addUser()
        else manageUser(list[choice - 1])
        end
    end
end

local function showMyKey()
    local pk = session.publicKey or keys.publicKey(me)
    if not pk then
        return ui.message(TITLE, "You don't have an encryption key yet.", ui.theme.bad)
    end
    ui.pager(TITLE .. " - My key", "Fingerprint:\n" .. keys.fingerprint(pk) ..
        "\n\nPublic key:\n" .. crypto.toHex(pk) ..
        "\n\nOther computers see this fingerprint for you. Compare it with them in person " ..
        "to be sure nobody is pretending to be you.")
end

local function newKey()
    ui.screen(TITLE .. " - New key")
    ui.text("A new key replaces your current one. Anything encrypted to your old key will be " ..
        "unreadable, and computers that trust your old key will see a different fingerprint.",
        ui.theme.bad)
    ui.text("")
    if not ui.confirm("Create a new key?") then return end
    local password = ui.input("Your password", "*")
    if not auth.verify(me, password) then
        return ui.message(TITLE, "Incorrect password. Your key was not changed.", ui.theme.bad)
    end
    ui.text("Creating your new key...", ui.theme.dim)
    session.secretKey, session.publicKey = keys.create(me, password)
    system.log(me .. " created a new encryption key")
    ui.message(TITLE, "New key created. Fingerprint: " .. keys.fingerprint(session.publicKey), ui.theme.good)
end

-- Keys pinned for other computers, shared by every user on this computer.
local function trustedKeys()
    local admin = auth.isAdmin(me)
    while true do
        local list = keys.knownList()
        local items = {}
        for _, k in ipairs(list) do
            items[#items + 1] = { label = k.address .. "  " .. k.fingerprint, hint = admin and "Forget this key" or nil }
        end
        if #list == 0 then items[1] = { label = "(no trusted keys)", fg = ui.theme.dim } end
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }
        local choice = ui.menu({ title = TITLE .. " - Trusted keys", items = items, back = true })
        local entry = choice and list[choice]
        if not entry then return end
        ui.screen(TITLE .. " - Trusted keys")
        if not admin then
            ui.message(TITLE, "Only administrators can forget trusted keys.", ui.theme.bad)
        else
            ui.text("Forget the key for " .. entry.address .. "? The next key it presents will be " ..
                "trusted without a warning.", ui.theme.accent)
            ui.text("")
            if ui.confirm("Forget it?") then
                keys.forgetKnown(entry.address)
                system.log(me .. " forgot the trusted key for " .. entry.address)
            end
        end
    end
end

local function encryptionKeys()
    local selected = 1
    while true do
        local items
        if session.secretKey then
            items = {
                { label = "My key: " .. keys.fingerprint(session.publicKey), action = showMyKey,
                  hint = "Show your public key" },
                { label = "Create a new key", action = newKey, hint = "Replace your keypair" },
            }
        else
            items = {
                { label = "Key locked", fg = ui.theme.bad,
                  hint = keys.hasKey(me) and "Your key couldn't be unlocked" or "You have no key" },
                { label = "Create a new key", action = newKey, hint = "Replace your keypair" },
            }
        end
        items[#items + 1] = { label = "Trusted keys", action = trustedKeys, hint = "Keys pinned for other computers" }
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }
        selected = ui.menu({ title = TITLE .. " - Encryption keys", items = items, selected = selected, back = true })
        if selected == nil or selected == #items then return end
        if items[selected].action then items[selected].action() end
    end
end

-- A root server's name and fingerprint on one line, if the screen is wide enough for both.
local function rootLabel(root)
    local w = term.getSize()
    local line = root.name .. "  " .. root.fingerprint
    return #line + 4 <= w and line or root.name
end

local function daysLeft(cert)
    return math.max(0, math.ceil((cert.expires - os.epoch("utc")) / 86400000))
end

-- Polls until the root server's admin has answered. Backspace leaves the request with them, and
-- asking again later picks up the answer.
local function waitForCertificate(root, name)
    while true do
        ui.screen(TITLE .. " - Certificate")
        ui.text("Asking " .. root.name .. " to sign this computer's key as '" .. name .. "'.")
        ui.text("")
        ui.text("Your fingerprint:", ui.theme.dim)
        ui.text(trust.fingerprint(select(2, trust.identity())), ui.theme.accent)
        ui.text("")
        local status, err = net.requestCertificate(root, name)
        if status == "issued" then
            system.log(me .. " got a certificate as " .. name .. " from " .. root.name)
            return ui.message(TITLE, "Certificate installed. Other computers that trust " .. root.name ..
                " can now verify this computer as '" .. name .. "'.", ui.theme.good)
        elseif status == "denied" then
            return ui.message(TITLE, root.name .. " refused the request.", ui.theme.bad)
        elseif not status then
            return ui.message(TITLE, "Couldn't get a certificate:\n\n" .. tostring(err), ui.theme.bad)
        end

        ui.text("Waiting for the root server's administrator to approve it. They should compare " ..
            "this fingerprint with the one on their screen. Backspace stops waiting.", ui.theme.dim)
        local timer = os.startTimer(5)
        while true do
            local e, a = os.pullEventRaw()
            if e == "timer" and a == timer then break end
            if e == "key" and a == _G.keys.backspace then return end
        end
    end
end

local function requestCertificate(root)
    local redraw = function()
        ui.screen(TITLE .. " - Certificate")
        ui.text("Choose the name other computers will know this computer by. The root server's " ..
            "administrator has to approve it.", ui.theme.dim)
        ui.text("")
    end
    local err
    while true do
        redraw()
        if err then ui.text(err, ui.theme.bad) ui.text("") end
        local name = ui.input("Name", nil, trust.defaultName())
        if name == "" then return end
        local ok, why = trust.validName(name)
        if ok then return waitForCertificate(root, name) end
        err = why
    end
end

local function manageRoot(root)
    while true do
        local cert = trust.cert(root.key)
        local items = {
            { label = "Details", hint = "Name, fingerprint and computer" },
            { label = cert and "Renew certificate" or "Request a certificate",
              hint = "Have this root server vouch for this computer" },
            { label = "Remove root server", hint = "Stop trusting it", fg = ui.theme.bad },
            { label = "Back", fg = ui.theme.dim },
        }
        local choice = ui.menu({ title = TITLE .. " - " .. root.name, items = items, back = true })
        if choice == 1 then
            ui.pager(TITLE .. " - " .. root.name, "Name: " .. root.name .. "\n\nFingerprint:\n" .. root.fingerprint ..
                "\n\nPublic key:\n" .. root.key .. "\n\nComputer: " .. root.host ..
                "\n\nThis computer's certificate: " ..
                (cert and (cert.name .. ", " .. daysLeft(cert) .. " days left") or "none"))
        elseif choice == 2 then
            if not session.admin then
                ui.message(TITLE, "Only administrators can request certificates.", ui.theme.bad)
            else
                requestCertificate(root)
            end
        elseif choice == 3 then
            if not session.admin then
                ui.message(TITLE, "Only administrators can remove root servers.", ui.theme.bad)
            else
                ui.screen(TITLE)
                ui.text("Stop trusting " .. root.name .. "? Computers it vouched for will no longer be " ..
                    "verified here, and this computer's certificate from it will be deleted.", ui.theme.accent)
                ui.text("")
                if ui.confirm("Remove it?") then
                    trust.removeRoot(root.key)
                    system.log(me .. " removed root server " .. root.name .. " " .. root.fingerprint)
                    return
                end
            end
        else
            return
        end
    end
end

local function addRoot()
    ui.screen(TITLE .. " - Add root server")
    if #net.modems() == 0 then
        return ui.message(TITLE, "This computer has no modem. Attach one and try again.", ui.theme.bad)
    end
    ui.text("Looking for root servers on port " .. net.ROOT_PORT .. "...", ui.theme.dim)
    local found, err = net.findRoots(3)
    if not found then return ui.message(TITLE, err, ui.theme.bad) end
    if #found == 0 then
        return ui.message(TITLE, "No root servers answered. Check that one is running, online and in range.",
            ui.theme.bad)
    end

    local items = {}
    for _, root in ipairs(found) do
        local trusted = trust.root(root.key) ~= nil
        items[#items + 1] = { label = rootLabel(root) .. (trusted and "  [added]" or ""),
            hint = root.fingerprint, fg = trusted and ui.theme.dim or nil }
    end
    items[#items + 1] = { label = "Back", fg = ui.theme.dim }

    local choice = ui.menu({ title = TITLE .. " - Add root server", items = items, back = true })
    local root = choice and found[choice]
    if not root then return end
    if trust.root(root.key) then
        return ui.message(TITLE, root.name .. " is already a trusted root server.", ui.theme.dim)
    end

    ui.screen(TITLE .. " - Add root server")
    ui.text(root.name, ui.theme.accent)
    ui.text("Fingerprint: " .. root.fingerprint)
    ui.text("Computer: " .. root.host, ui.theme.dim)
    ui.text("")
    ui.text("Anyone can announce a root server and pick any name. Compare this fingerprint with " ..
        "the one on the root server's own screen. Every computer it signs will be verified here.",
        ui.theme.bad)
    ui.text("")
    if not ui.confirm("Trust this root server?") then return end
    trust.addRoot(root.key, root.name, root.host)
    system.log(me .. " added root server " .. root.name .. " " .. root.fingerprint)
    ui.message(TITLE, "Added " .. root.name .. ".", ui.theme.good)
end

local function rootServers()
    while true do
        local list = trust.roots()
        local items = {}
        for _, root in ipairs(list) do
            items[#items + 1] = { label = rootLabel(root), hint = root.fingerprint }
        end
        items[#items + 1] = { label = "Add root server...", hint = "Find root servers on the network" }
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }

        local choice = ui.menu({ title = TITLE .. " - Root servers", items = items, back = true })
        if choice == nil or choice == #items then return end
        if list[choice] then
            manageRoot(list[choice])
        elseif not session.admin then
            ui.message(TITLE, "Only administrators can add root servers.", ui.theme.bad)
        else
            addRoot()
        end
    end
end

local function networkIdentity()
    local _, public = trust.identity()
    local lines = { "Computer: " .. os.getComputerID(), "", "Fingerprint:", trust.fingerprint(public), "",
        "Public key:", crypto.toHex(public), "", "Certificates:" }
    local certs = trust.certs()
    for _, cert in ipairs(certs) do
        local root = trust.root(cert.root)
        lines[#lines + 1] = cert.name .. " from " .. (root and root.name or "an untrusted root") ..
            ", " .. daysLeft(cert) .. " days left"
    end
    if #certs == 0 then lines[#lines + 1] = "None. Request one from a root server." end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Modems: " .. (#net.modems() > 0 and table.concat(net.modems(), ", ") or "none")
    ui.pager(TITLE .. " - This computer", table.concat(lines, "\n"))
end

local function certificateText(cert)
    local function date(ms) return os.date("!%Y-%m-%d %H:%M UTC", math.floor(ms / 1000)) end
    local root = trust.root(cert.root)
    return table.concat({
        "Certificate for:\n" .. cert.name,
        "Computer: " .. cert.id,
        "Issued:\n" .. date(cert.issued) .. "\n" .. (daysLeft(cert) > 0 and "Expires:\n" or "EXPIRED:\n") ..
            date(cert.expires),
        "Fingerprint:\n" .. trust.fingerprint(crypto.fromHex(cert.key)),
        "Public key:\n" .. cert.key,
        "Signed by:\n" .. (root and root.name or "an untrusted root"),
        "Root fingerprint:\n" .. trust.fingerprint(crypto.fromHex(cert.root)),
        "Root public key:\n" .. cert.root,
        "Signature:\n" .. cert.sig,
    }, "\n\n")
end

local function printCertificate()
    local certs = trust.certs()
    if #certs == 0 then
        return ui.message(TITLE, "This computer has no certificate. Request one from a root server.", ui.theme.bad)
    end
    local cert = certs[1]
    if #certs > 1 then
        local items = {}
        for _, c in ipairs(certs) do
            local root = trust.root(c.root)
            items[#items + 1] = { label = c.name, hint = "From " .. (root and root.name or "an untrusted root") }
        end
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }
        local choice = ui.menu({ title = TITLE .. " - Print certificate", items = items, back = true })
        cert = choice and certs[choice]
        if not cert then return end
    end
    ui.screen(TITLE .. " - Print certificate")
    ui.text("Printing...", ui.theme.dim)
    done("Printed. It's in the printer's output tray.", printer.print("Certificate: " .. cert.name,
        certificateText(cert)))
end

local function network()
    local selected = 1
    while true do
        local items = {
            { label = "Root servers (" .. #trust.roots() .. ")", action = rootServers,
              hint = "Servers that vouch for other computers" },
            { label = "This computer", action = networkIdentity, hint = "Fingerprint and certificates" },
            { label = "Print certificate", action = printCertificate, hint = "Print this computer's certificate" },
            { label = "Back", fg = ui.theme.dim },
        }
        selected = ui.menu({ title = TITLE .. " - Network", items = items, selected = selected, back = true })
        if selected == nil or not items[selected].action then return end
        items[selected].action()
    end
end

local function label()
    ui.screen(TITLE)
    ui.text("Current label: " .. (os.getComputerLabel() or "(none)"), ui.theme.dim)
    ui.text("Leave empty to clear it.", ui.theme.dim)
    ui.text("")
    local value = ui.input("New label", nil, os.getComputerLabel())
    os.setComputerLabel(value ~= "" and value or nil)
    ui.message(TITLE, "Label " .. (value ~= "" and ("set to '" .. value .. "'.") or "cleared."), ui.theme.good)
end

local function secureBoot()
    ui.screen(TITLE .. " - Secure boot")
    if system.secureBootEnabled() then
        ui.text("Secure boot is ON. Floppy disks can't start this computer, so nobody can skip the login screen.")
        ui.text("")
        ui.text("If you turn it off, anyone with a disk can boot their own program and get full access to every file.", ui.theme.bad)
        ui.text("")
        if not ui.confirm("Turn secure boot off?") then return end
        local password = ui.input("Your password", "*")
        if not auth.verify(me, password) then
            return ui.message(TITLE, "Incorrect password. Secure boot is still on.", ui.theme.bad)
        end
        system.setSecureBoot(false, me)
        ui.message(TITLE, "Secure boot is OFF. A disk with a startup program will now boot instead of zOS. " ..
            "Turn it back on when you're done.", ui.theme.accent)
    else
        ui.text("Secure boot is OFF. A floppy disk with a startup program will boot instead of zOS, " ..
            "skipping the login screen.", ui.theme.bad)
        ui.text("")
        if not ui.confirm("Turn secure boot on?") then return end
        system.setSecureBoot(true, me)
        ui.message(TITLE, "Secure boot is ON. Floppy disks can no longer start this computer.", ui.theme.good)
    end
end

local function restart()
    system.applyBootPolicy()
    os.reboot()
    while true do os.pullEventRaw() end
end

local function checkForUpdates()
    ui.screen(TITLE .. " - Updates")
    ui.text("Checking for updates...", ui.theme.dim)
    local info, err = update.check()
    if info == nil then return ui.message(TITLE, err, ui.theme.bad) end
    if not info then return ui.message(TITLE, "zOS " .. system.VERSION .. " is up to date.", ui.theme.good) end

    if update.stagedVersion() ~= info.version then
        ui.text("zOS " .. info.version .. " is available (" .. math.ceil(info.size / 1024) .. " KB).")
        if update.failedVersion() == info.version then
            ui.text("It failed to start on this computer before, and zOS went back to " ..
                system.VERSION .. ".", ui.theme.bad)
        end
        ui.text("")
        if not ui.confirm("Download it?") then return end
        ui.text("Downloading and checking...", ui.theme.dim)
        local ok, downloadErr = update.download(info)
        if not ok then return ui.message(TITLE, downloadErr, ui.theme.bad) end
    end
    ui.screen(TITLE .. " - Updates")
    ui.text("zOS " .. info.version .. " will install when this computer restarts.", ui.theme.good)
    ui.text("")
    if ui.confirm("Restart now?") then restart() end
end

local function updates()
    while true do
        local staged, auto = update.stagedVersion(), system.autoUpdateEnabled()
        local items = {
            { label = "Installed: zOS " .. system.VERSION, fg = ui.theme.dim,
                hint = staged and ("zOS " .. staged .. " installs at the next restart") or nil },
            { label = "Check for updates", action = checkForUpdates },
            { label = "Automatic updates: " .. (auto and "on" or "off"), hint = "Download by itself, install at the next restart",
                action = function() system.setAutoUpdate(not auto, me) end },
            { label = "Back", fg = ui.theme.dim },
        }
        local choice = ui.menu({ title = TITLE .. " - Updates", items = items, back = true })
        if choice == nil or choice == #items then return end
        if items[choice].action then items[choice].action() end
    end
end

local selected = 1
while true do
    local items = {
        { label = "Change my password", action = changePassword },
        { label = "Encryption keys", action = encryptionKeys, hint = "View or replace your key, trusted keys" },
        { label = "Network", action = network, hint = "Root servers, fingerprint, certificates" },
        { label = "Computer label", action = label, hint = "Name shown on the login screen" },
    }
    if auth.isAdmin(me) then
        table.insert(items, 3, { label = "Users", action = users, hint = "Add, remove or reset accounts" })
        table.insert(items, 4, {
            label = "Secure boot: " .. (system.secureBootEnabled() and "on" or "OFF"),
            action = secureBoot,
            hint = "Block booting from floppy disks",
            fg = not system.secureBootEnabled() and ui.theme.bad or nil,
        })
        items[#items + 1] = { label = "Updates", action = updates, hint = "Check for a new version of zOS" }
    end
    items[#items + 1] = { label = "Back", fg = ui.theme.dim }

    selected = ui.menu({ title = TITLE, items = items, selected = selected, back = true })
    if selected == nil or not items[selected].action then return end
    items[selected].action()
end
