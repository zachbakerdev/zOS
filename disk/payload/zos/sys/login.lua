-- zOS login screen. Returns the user's name and their unlocked encryption keys
-- (secret key, public key), or just the name if the keys couldn't be unlocked.

local ui = require("ui")
local auth = require("auth")
local keys = require("keys")
local crypto = require("crypto")
local system = require("system")

local function header()
    ui.screen("zOS " .. system.VERSION, "Computer #" .. os.getComputerID())
    ui.text("")
    ui.text("Welcome to " .. (os.getComputerLabel() or "zOS") .. ".", ui.theme.accent)
    ui.text("")
end

-- Setup always creates an admin, but if the account database is lost, let the
-- person at the keyboard create a new one rather than locking everyone out.
local function createFirstAdmin()
    local function redraw()
        header()
        ui.text("No user accounts exist. Create an administrator account.")
        ui.text("")
    end
    local name = ui.newUsername(auth.validName, redraw, "admin")
    local password = ui.newPassword(auth.checkPassword, function()
        redraw()
        ui.text("Username: " .. name, ui.theme.dim)
        ui.text("")
    end)
    assert(auth.create(name, password, true))
    system.log("created first administrator " .. name)
    return name, password
end

local function unlockKeys(name, password)
    crypto.addEntropy(password)
    ui.text(keys.hasKey(name) and "Unlocking your keys..." or "Creating your encryption keys...", ui.theme.dim)
    local ok, sk, pk = pcall(keys.unlock, name, password)
    if ok and sk then return name, sk, pk end
    system.log("could not unlock keys for " .. name .. ": " .. tostring(ok and pk or sk))
    return name
end

local function waitLockout()
    local left = auth.lockRemaining()
    while left > 0 do
        header()
        ui.text("Too many failed login attempts.", ui.theme.bad)
        ui.text("Try again in " .. left .. "s.")
        sleep(1)
        left = auth.lockRemaining()
    end
end

if not auth.hasUsers() then return unlockKeys(createFirstAdmin()) end

local message
while true do
    waitLockout()
    header()
    if message then
        ui.text(message, ui.theme.bad)
        ui.text("")
    end
    local name = ui.input("Username")
    crypto.addEntropy(name) -- typing times are extra randomness
    if name ~= "" then
        local password = ui.input("Password", "*")
        ui.text("Checking...", ui.theme.dim)
        if auth.verify(name, password) then
            auth.recordSuccess()
            return unlockKeys(name, password)
        end
        auth.recordFailure()
        message = "Incorrect username or password."
    end
end
