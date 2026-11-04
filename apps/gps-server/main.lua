-- zOS GPS Server: set where this host is and get a root server to vouch for it. The service in
-- service.lua answers the computers asking where they are.

local session = ...
local ui = require("ui")
local crypto = require("crypto")
local db = require("gpsdb")
local gps = require("gps")
local system = require("system")
local trust = require("trust")

local TITLE = "GPS Server"

local function where(config)
    return config.x .. ", " .. config.y .. ", " .. config.z
end

local function rootName(config)
    local root = config.root and trust.root(config.root)
    return root and root.name or "the root server"
end

local function myFingerprint()
    return crypto.fingerprint(select(2, trust.identity()))
end

-- One line saying what this host is doing.
local function summary(config)
    if not config.x then return "Not set up yet", ui.theme.accent end
    if config.status == "issued" and db.usableCert() then
        if not config.online then return "Answering is off", ui.theme.bad end
        if #gps.wirelessModems() == 0 then return "No wireless modem", ui.theme.bad end
        return "Serving " .. where(config), ui.theme.good
    end
    if config.status == "pending" then return "Waiting for " .. rootName(config), ui.theme.accent end
    if config.status == "issued" then return "Certificate expired, renewing", ui.theme.bad end
    if config.status == "denied" then return rootName(config) .. " refused", ui.theme.bad end
    return tostring(config.message or "Something went wrong"), ui.theme.bad
end

local function chooseRoot()
    local roots = trust.roots()
    if #roots == 0 then
        ui.message(TITLE, "This computer doesn't trust a root server yet. Add one in Settings > Security > " ..
            "Root servers, then come back.", ui.theme.bad)
        return nil
    end
    if #roots == 1 then return roots[1] end
    local items = {}
    for _, root in ipairs(roots) do items[#items + 1] = { label = root.name, hint = crypto.fingerprint(crypto.fromHex(root.key)) } end
    items[#items + 1] = { label = "Back", fg = ui.theme.dim }
    local selected = ui.menu({ title = TITLE .. " - Choose a root server", items = items, back = true })
    return selected and roots[selected]
end

-- Shows the request until the root server's admin answers it, or Q or Backspace is pressed. The
-- service does the asking, so leaving is safe.
local function waitForApproval()
    local function draw()
        local config = db.config()
        ui.screen(TITLE .. " - Approval")
        ui.text("Asking " .. rootName(config) .. " to vouch for this host at " .. where(config) .. ".")
        ui.text("")
        ui.text("This computer's fingerprint:", ui.theme.dim)
        ui.text(myFingerprint(), ui.theme.accent)
        ui.text("")
        ui.text("Waiting for the root server's administrator to approve it under GPS hosts. They " ..
            "should compare this fingerprint with the one on their screen.", ui.theme.dim)
        ui.text("")
        ui.text("Q: come back later", ui.theme.dim)
        if config.message then
            ui.text("")
            ui.text(tostring(config.message), ui.theme.bad)
            ui.text("Root servers older than Root Server 1.1.0 don't answer GPS requests.", ui.theme.dim)
        end
    end
    draw()
    local timer = os.startTimer(2)
    while db.config().status == "pending" do
        local event, a = os.pullEvent()
        if (event == "key" and a == keys.backspace) or (event == "char" and a:lower() == "q") then return end
        if event == "timer" and a == timer then
            draw()
            timer = os.startTimer(2)
        end
    end
    local config = db.config()
    if config.status == "issued" then
        system.log(session.user .. " got a GPS certificate for " .. where(config) .. " from " .. rootName(config))
        ui.message(TITLE, "Approved. This host now answers at " .. where(config) .. ".", ui.theme.good)
    else
        ui.message(TITLE, (summary(config)), ui.theme.bad)
    end
end

local function askNumber(label, current)
    local err
    while true do
        ui.screen(TITLE .. " - Position")
        ui.text("Enter the coordinates of this computer, the block itself, not where you're " ..
            "standing. Look at it and press F3 to see them, under Targeted Block.", ui.theme.dim)
        ui.text("")
        if err then ui.text(err, ui.theme.bad) ui.text("") end
        local text = ui.input(label, nil, current and tostring(current) or nil)
        if text == "" then return nil end
        local n = tonumber(text)
        if n and trust.validPosition(n, 0, 0) then return n end
        err = "Enter a whole number, like -120."
    end
end

local function setPosition()
    local config = db.config()
    local root = chooseRoot()
    if not root then return end
    local x = askNumber("X", config.x)
    local y = x and askNumber("Y", config.y)
    local z = y and askNumber("Z", config.z)
    if not z then return end

    ui.screen(TITLE .. " - Position")
    ui.text("This host will tell other computers it's at " .. x .. ", " .. y .. ", " .. z ..
        ". If that's wrong, they'll get the wrong position from it.")
    ui.text("")
    if #gps.wirelessModems() == 0 then
        ui.text("There's no wireless modem attached. Attach one before computers can reach this host.", ui.theme.bad)
        ui.text("")
    end
    if config.status == "issued" then
        ui.text("This replaces the current certificate, and " .. root.name .. " has to approve the new " ..
            "position before this host answers again.", ui.theme.accent)
        ui.text("")
    end
    if not ui.confirm("Ask " .. root.name .. " to vouch for it?") then return end
    db.setPosition(x, y, z, root.key)
    system.log(session.user .. " set the GPS position to " .. x .. ", " .. y .. ", " .. z)
    waitForApproval()
end

local function askAgain()
    db.retry()
    waitForApproval()
end

local function details()
    local config = db.config()
    local cert = db.usableCert()
    local lines = {
        "Status: " .. (summary(config)),
        "Position: " .. (config.x and where(config) or "not set"),
        "Root server: " .. (config.root and rootName(config) or "none"),
    }
    if cert then
        lines[#lines + 1] = "Certificate: " .. math.ceil((cert.expires - os.epoch("utc")) / 86400000) ..
            " days left, renewed by itself"
    end
    lines[#lines + 1] = "Wireless modems: " .. #gps.wirelessModems()
    lines[#lines + 1] = "Port: " .. gps.PORT
    lines[#lines + 1] = ""
    lines[#lines + 1] = "This computer's fingerprint, for the root server's admin:"
    lines[#lines + 1] = myFingerprint()
    lines[#lines + 1] = ""
    lines[#lines + 1] = "GPS key fingerprint:"
    lines[#lines + 1] = crypto.fingerprint(crypto.fromHex(db.publicKey()))
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Computers find their position from at least 3 hosts that aren't in a line, and " ..
        "4 or more that aren't all at the same height. With 5 or more, a host that's wrong is outvoted."
    ui.pager(TITLE .. " - Status", table.concat(lines, "\n"))
end

if not session.admin then
    return ui.message(TITLE, "Only administrators can use GPS Server.", ui.theme.bad)
end

if not db.config().x then
    ui.screen(TITLE)
    ui.text("Creating this host's key...", ui.theme.dim)
    db.keypair()
    ui.message(TITLE, "This computer can tell others nearby where they are. A root server vouches " ..
        "for its position, so computers that trust that root know its answers are real.\n\n" ..
        "Next, enter where it is.")
    setPosition()
end

local selected = 1
while true do
    local config = db.config()
    local status, color = summary(config)
    local items = {
        { label = status, action = details, hint = "Details and fingerprints", fg = color },
        { label = config.x and ("Position: " .. where(config)) or "Set position", action = setPosition,
          hint = "Where this computer is" },
    }
    if config.status == "pending" then
        items[#items + 1] = { label = "Wait for approval", action = waitForApproval, hint = "Show the fingerprint to compare" }
    elseif config.x and (config.status == "denied" or config.status == "error") then
        items[#items + 1] = { label = "Ask again", action = askAgain, hint = "Send the same request to " .. rootName(config) }
    end
    items[#items + 1] = {
        label = "Answering: " .. (config.online and "on" or "OFF"),
        action = function() db.setConfig({ online = not config.online }) end,
        hint = "Answer computers asking where they are", fg = not config.online and ui.theme.bad or nil,
    }
    items[#items + 1] = { label = "Back", fg = ui.theme.dim }
    selected = ui.menu({ title = TITLE, items = items, selected = selected, back = true })
    if selected == nil or not items[selected].action then return end
    items[selected].action()
end
