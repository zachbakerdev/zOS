-- First boot of a computer with no accounts: creates the first administrator.

local auth = require("auth")
local crypto = require("crypto")
local system = require("system")
local ui = require("ui")

local TITLE = "Welcome to zOS"

local function askName()
    local why
    while true do
        ui.screen(TITLE)
        ui.text("Create an administrator account. It can manage users, apps and settings.")
        ui.text("")
        if why then ui.text(why, ui.theme.bad) ui.text("") end
        local name = ui.field("Name")
        why = auth.badName(name)
        if not why then return name end
    end
end

local function askPassword(name)
    local why
    while true do
        ui.screen(TITLE)
        ui.text("Choose a password for " .. name .. ", at least " .. auth.MIN_PASSWORD .. " characters.")
        ui.text("")
        if why then ui.text(why, ui.theme.bad) ui.text("") end
        local first = ui.field("Password", "*")
        why = auth.badPassword(first)
        if not why then
            local second = ui.field("Again", "*")
            if first == second then return first end
            why = "Those didn't match."
        end
    end
end

local name = askName()
local password = askPassword(name)

ui.screen(TITLE)
ui.text("Name this computer, or press Enter to skip.")
ui.text("")
local label = ui.field("Label", nil, os.getComputerLabel())
if label ~= "" then os.setComputerLabel(label) end

ui.screen(TITLE)
ui.text("Setting up. This takes a moment...", ui.theme.dim)
crypto.addEntropy(password)
local ok, err = auth.create(name, password, true)
if not ok then error(err, 0) end
system.setConfig({ secureBoot = true })
system.applyBootPolicy()
system.log("Set up with administrator " .. name)
