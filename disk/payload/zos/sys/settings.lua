-- zOS settings: your password, encryption keys, the computer label and, for admins,
-- users and secure boot.

local session = ...
local ui = require("ui")
local auth = require("auth")
local keys = require("keys")
local crypto = require("crypto")
local system = require("system")

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

local selected = 1
while true do
    local items = {
        { label = "Change my password", action = changePassword },
        { label = "Encryption keys", action = encryptionKeys, hint = "View or replace your key, trusted keys" },
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
    end
    items[#items + 1] = { label = "Back", fg = ui.theme.dim }

    selected = ui.menu({ title = TITLE, items = items, selected = selected, back = true })
    if selected == nil or not items[selected].action then return end
    items[selected].action()
end
