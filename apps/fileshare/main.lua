-- zOS File Share: share files directly with other computers. The service in service.lua answers
-- them; this is where you check who they are, choose what to share and download.

local session = ...
local ui = require("ui")
local net = require("net")
local share = require("share")
local system = require("system")
local trust = require("trust")

local TITLE = "File Share"
local DOWNLOADS = "/home/" .. session.user .. "/downloads"

local function fail(text)
    ui.message(TITLE, tostring(text), ui.theme.bad)
end

local function myFingerprint()
    return trust.fingerprint(select(2, trust.identity()))
end

local function sizeText(bytes)
    if bytes < 1024 then return bytes .. " B" end
    return string.format("%.1f KB", bytes / 1024)
end

------------------------------------------------------------------------------
-- Adding computers
------------------------------------------------------------------------------

local function verify(id)
    ui.screen(TITLE)
    ui.text("Asking computer " .. id .. " for its key...", ui.theme.dim)
    local found, err = share.hello(id)
    if not found then return fail("Couldn't reach computer " .. id .. ":\n\n" .. tostring(err)) end
    if share.isTrusted(found.key) then
        return ui.message(TITLE, found.name .. " is already verified.", ui.theme.good)
    end

    local previous = share.peerById(id)
    ui.screen(TITLE .. " - Verify")
    if previous then
        ui.text("WARNING: computer " .. id .. " has a different fingerprint from when you added it.", ui.theme.bad)
    end
    ui.text(found.name .. " (computer " .. id .. ")" .. (found.certified and ", certified by a root server" or ""))
    ui.text("")
    ui.text("Its fingerprint:", ui.theme.dim)
    ui.text(found.fingerprint, ui.theme.accent)
    ui.text("This computer:", ui.theme.dim)
    ui.text(myFingerprint())
    ui.text("")
    ui.text("Check that computer shows this under File Share > This computer.", ui.theme.dim)
    ui.text("")
    if not ui.confirm("Does it match exactly?") then return end

    if previous then share.forgetPeer(previous.key) end
    share.trustPeer(found)
    system.log(session.user .. " verified " .. found.name .. " for File Share: " .. found.fingerprint)
    ui.message(TITLE, found.name .. " is verified. It can download what you share once it has " ..
        "verified this computer too, and the same goes for you.", ui.theme.good)
end

local function enterId()
    ui.screen(TITLE)
    local id = tonumber(ui.input("Computer id"))
    if not id or id < 0 or id ~= math.floor(id) then return fail("Enter a computer's id number.") end
    if id == os.getComputerID() then return fail("That's this computer.") end
    verify(id)
end

local function addComputer()
    ui.screen(TITLE)
    ui.text("Looking for computers in range...", ui.theme.dim)
    local found, err = share.find(3)
    if not found then return fail(err) end

    local items = {}
    for _, computer in ipairs(found) do
        items[#items + 1] = { label = computer.name .. " (computer " .. computer.id .. ")", id = computer.id }
    end
    items[#items + 1] = { label = "Enter a computer id", action = enterId, hint = "For a computer that wasn't found" }
    items[#items + 1] = { label = "Back", fg = ui.theme.dim }

    local selected = ui.menu({ title = TITLE .. " - Add a computer", items = items, back = true })
    local item = selected and items[selected]
    if item and item.id then
        verify(item.id)
    elseif item and item.action then
        item.action()
    end
end

------------------------------------------------------------------------------
-- Downloading
------------------------------------------------------------------------------

local function drawProgress(file, got)
    local w = term.getSize()
    local width = w - 4
    local filled = math.floor(width * (file.size > 0 and got / file.size or 1))
    ui.at(2, 7, sizeText(got) .. " of " .. sizeText(file.size) .. "      ", ui.theme.dim, ui.theme.bg)
    ui.at(2, 8, string.rep("=", filled) .. string.rep("-", width - filled), ui.theme.accent)
end

local function download(channel, file)
    ui.screen(TITLE .. " - " .. file.name)
    ui.text("Encrypted download from " .. channel.peer.name)
    ui.text("")
    ui.text("Backspace cancels.", ui.theme.dim)
    drawProgress(file, 0)

    local path, err
    parallel.waitForAny(function()
        path, err = share.download(channel, file.name, DOWNLOADS, function(got) drawProgress(file, got) end)
        if not path then err = err or "The download failed." end
    end, function()
        local key
        repeat
            local _, code = os.pullEventRaw("key")
            key = code
        until key == keys.backspace
    end)

    if path then
        ui.message(TITLE, "Saved to /" .. fs.combine("/", path), ui.theme.good)
    elseif err then
        fail(err)
    end
end

local function browse(peer)
    ui.screen(TITLE)
    ui.text("Setting up encryption with " .. peer.name .. "...", ui.theme.dim)
    local channel, err = share.connect(peer)
    if not channel then return fail(err) end

    local selected = 1
    while true do
        local files, why = share.list(channel)
        if not files then return fail(why) end
        local items = {}
        for _, file in ipairs(files) do
            items[#items + 1] = { label = file.name, hint = sizeText(file.size), file = file }
        end
        if #files == 0 then items[1] = { label = "(nothing shared)", fg = ui.theme.dim } end
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }
        selected = ui.menu({ title = peer.name, items = items, selected = selected, back = true })
        if selected == nil or not files[selected] then return end
        download(channel, files[selected])
    end
end

local function manage(peer)
    local items = {
        { label = "Browse files", action = function() browse(peer) end, hint = "See what it shares and download" },
        { label = "Show fingerprint", action = function()
            ui.pager(TITLE .. " - " .. peer.name, "Computer: " .. peer.id .. "\n\nFingerprint:\n" .. peer.fingerprint)
        end, hint = "The fingerprint you verified" },
        { label = "Forget", action = function()
            ui.screen(TITLE)
            ui.text("Forget " .. peer.name .. "? It won't be able to download from this computer, and " ..
                "you'd have to verify it again.", ui.theme.accent)
            ui.text("")
            if ui.confirm("Forget it?") then
                share.forgetPeer(peer.key)
                system.log(session.user .. " forgot " .. peer.name .. " in File Share")
                return true
            end
        end, hint = "Stop trusting this computer" },
        { label = "Back", fg = ui.theme.dim },
    }
    while true do
        local selected = ui.menu({ title = peer.name, items = items, back = true })
        if selected == nil or not items[selected].action then return end
        if items[selected].action() then return end
    end
end

local function computers()
    local selected = 1
    while true do
        local list = share.peers()
        local items = {}
        for _, peer in ipairs(list) do
            items[#items + 1] = { label = peer.name .. " (computer " .. peer.id .. ")", hint = peer.fingerprint }
        end
        if #list == 0 then items[1] = { label = "(none yet)", fg = ui.theme.dim } end
        items[#items + 1] = { label = "Add a computer", action = addComputer, hint = "Find one and compare fingerprints" }
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }
        selected = ui.menu({ title = TITLE .. " - Computers", items = items, selected = selected, back = true })
        if selected == nil then return end
        local item = items[selected]
        if list[selected] then
            manage(list[selected])
        elseif item.action then
            item.action()
        elseif item.label == "Back" then
            return
        end
    end
end

------------------------------------------------------------------------------
-- Sharing
------------------------------------------------------------------------------

local function addFile()
    ui.screen(TITLE)
    ui.text("Every computer you've verified, and that has verified you, can download this. " ..
        "It keeps being shared with whatever it contains later.", ui.theme.dim)
    ui.text("")
    local name, err = share.addFile(ui.input("Path to the file"))
    if not name then return fail(err) end
    system.log(session.user .. " shared " .. name)
end

local function sharedFiles()
    local selected = 1
    while true do
        local list = share.files()
        local items = {}
        for _, file in ipairs(list) do
            items[#items + 1] = { label = file.name, hint = "/" .. file.path .. "  " .. sizeText(file.size) }
        end
        items[#items + 1] = { label = "Share a file", action = addFile, hint = "Enter a path" }
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }
        selected = ui.menu({ title = TITLE .. " - Shared files", items = items, selected = selected, back = true })
        if selected == nil then return end
        local item = items[selected]
        if list[selected] then
            ui.screen(TITLE)
            ui.text(list[selected].name .. " stays on this computer.", ui.theme.dim)
            ui.text("")
            if ui.confirm("Stop sharing it?") then share.removeFile(list[selected].name) end
        elseif item.action then
            item.action()
        else
            return
        end
    end
end

local function thisComputer()
    ui.pager(TITLE .. " - This computer", "Name: " .. trust.defaultName() .. "\nComputer: " .. os.getComputerID() ..
        "\n\nFingerprint:\n" .. myFingerprint() ..
        "\n\nPeople adding this computer should see this fingerprint." ..
        "\n\nModems: " .. (#net.modems() > 0 and table.concat(net.modems(), ", ") or "none"))
end

local selected = 1
while true do
    local items = {
        { label = "Computers (" .. #share.peers() .. ")", action = computers, hint = "Browse, download and verify" },
        { label = "Shared files (" .. #share.files() .. ")", action = sharedFiles, hint = "What other computers can download" },
        { label = "This computer", action = thisComputer, hint = "Your fingerprint" },
        { label = "Back", fg = ui.theme.dim },
    }
    selected = ui.menu({ title = TITLE, items = items, selected = selected, back = true })
    if selected == nil or not items[selected].action then return end
    items[selected].action()
end
