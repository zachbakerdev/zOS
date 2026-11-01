-- zOS Mail: read and send mail through a mail server. Your address is user@host, where host is a
-- mail server's hostname from a root server this computer trusts.

local session = ...
local ui = require("ui")
local client = require("mailclient")

local TITLE = "Mail"
local MAX_QUOTE = 4096 -- leaves room in a message for the reply

local account = client.load(session)

local function fail(text)
    ui.message(TITLE, tostring(text), ui.theme.bad)
end

local function address()
    return account.user .. "@" .. account.host
end

local function dateText(ms)
    return os.date("!%Y-%m-%d %H:%M", math.floor(ms / 1000))
end

-- Run something with a message on screen. Drops the account if the server no longer accepts it.
local function attempt(text, action)
    ui.screen(TITLE)
    ui.text(text, ui.theme.dim)
    local answer, err, expired = action()
    if not answer then
        if expired then
            client.forget(session)
            account = nil
        end
        fail(err)
    end
    return answer
end

local function call(op, fields)
    return attempt("Talking to the server...", function() return client.call(account, op, fields) end)
end

------------------------------------------------------------------------------
-- Writing
------------------------------------------------------------------------------

local function splitAddresses(text)
    local out = {}
    for part in text:gmatch("[^,%s]+") do out[#out + 1] = part end
    return out
end

local function compose(to, subject, quoted)
    ui.screen(TITLE .. " - New message")
    to = ui.input("To (separate several with commas)", nil, to)
    if to == "" then return end
    subject = ui.input("Subject", nil, subject)
    ui.text("Write your message. A line with only a dot finishes it.", ui.theme.dim)
    local lines = {}
    while true do
        local line = ui.input()
        if line == "." then break end
        lines[#lines + 1] = line
    end
    if quoted then lines[#lines + 1] = "\n" .. quoted end
    ui.text("")
    if not ui.confirm("Send it?") then return end
    local body = table.concat(lines, "\n")
    if attempt("Encrypting and sending...", function() return client.send(account, splitAddresses(to), subject, body) end) then
        ui.message(TITLE, "Sent. Mail that can't be delivered comes back to your inbox.", ui.theme.good)
    end
end

local function replyTo(message)
    local subject = message.subject
    if not subject:match("^Re: ") then subject = "Re: " .. subject end
    local quoted = {}
    for line in (message.body .. "\n"):gmatch("(.-)\n") do quoted[#quoted + 1] = "> " .. line end
    compose(message.from, subject, table.concat(quoted, "\n"):sub(1, MAX_QUOTE))
end

------------------------------------------------------------------------------
-- Reading
------------------------------------------------------------------------------

local function readMessage(entry)
    local answer = call("read", { id = entry.id })
    if not answer then return end
    local message = answer.message
    ui.screen(TITLE)
    ui.text("Decrypting...", ui.theme.dim)
    message.body = client.decrypt(account, message) or
        "(This message can't be decrypted. It was encrypted with a key from before this account's password was reset.)"
    local text = "From: " .. message.from .. "\nTo: " .. table.concat(message.to, ", ") .. "\nDate: " ..
        dateText(message.date) .. "\nSubject: " .. message.subject .. "\n\n" .. message.body
    local action = ui.pager(TITLE .. " - " .. message.subject, text, "R: reply  D: delete  Q: back",
        { r = "reply", d = "delete" })
    if action == "reply" then
        replyTo(message)
    elseif action == "delete" then
        ui.screen(TITLE)
        if ui.confirm("Delete this message?") then call("delete", { id = entry.id }) end
    end
end

local function inbox()
    local selected = 1
    while account do
        local answer = call("list")
        if not answer then return end
        local list = answer.messages
        local items = {}
        for _, entry in ipairs(list) do
            items[#items + 1] = {
                label = (entry.read and "  " or "* ") .. (entry.subject ~= "" and entry.subject or "(no subject)"),
                hint = entry.from .. "  " .. dateText(entry.date),
            }
        end
        if #list == 0 then items[1] = { label = "(nothing here)", fg = ui.theme.dim } end
        items[#items + 1] = { label = "Back", fg = ui.theme.dim }
        selected = ui.menu({ title = TITLE .. " - Inbox", items = items, selected = selected, back = true })
        if selected == nil or not list[selected] then return end
        readMessage(list[selected])
    end
end

------------------------------------------------------------------------------
-- Accounts
------------------------------------------------------------------------------

local function askCredentials(heading)
    ui.screen(TITLE .. " - " .. heading)
    ui.text("This computer has to trust the root server that gave your mail server its hostname. " ..
        "Add it in Settings > Security > Root servers.", ui.theme.dim)
    ui.text("")
    local entered = ui.input("Address, like you@zmail.root-a")
    if entered == "" then return end
    return entered, ui.input("Password", "*")
end

local function signInWith(heading, action)
    local entered, password = askCredentials(heading)
    if not entered then return end
    ui.text("Connecting...", ui.theme.dim)
    local signedIn, err = action(session, entered, password)
    if signedIn then account = signedIn else fail(err) end
end

local function changePassword()
    ui.screen(TITLE)
    local old = ui.input("Current password", "*")
    local password = ui.input("New password", "*")
    ui.text("Changing the password...", ui.theme.dim)
    local ok, err = client.changePassword(session, account, old, password)
    if ok then
        ui.message(TITLE, "Password changed. Other computers will have to sign in again.", ui.theme.good)
    else
        fail(err)
    end
end

local function downloadKey()
    local file = attempt("Downloading your key...", function() return client.downloadCertificate(session, account) end)
    if file then
        ui.message(TITLE, "Saved to " .. file .. ". It's locked with your current password.", ui.theme.good)
    end
end

local function signOut()
    ui.screen(TITLE)
    client.call(account, "logout")
    client.forget(session)
    account = nil
end

local selected = 1
while true do
    local items
    if account then
        items = {
            { label = "Inbox", action = inbox, hint = "Read your mail" },
            { label = "New message", action = function() compose() end, hint = "Write to anyone with an address" },
            { label = "Change password", action = changePassword },
            { label = "Download key", action = downloadKey, hint = "Your encrypted mail key, as a file" },
            { label = "Sign out", action = signOut, hint = "Forget this account on this computer" },
            { label = "Back", fg = ui.theme.dim },
        }
    else
        items = {
            { label = "Sign in", action = function() signInWith("Sign in", client.signIn) end,
              hint = "Use an account on a mail server" },
            { label = "Create an account", action = function() signInWith("New account", client.signUp) end,
              hint = "On a mail server that takes new accounts" },
            { label = "Back", fg = ui.theme.dim },
        }
    end
    selected = ui.menu({ title = TITLE .. (account and (" - " .. address()) or ""), items = items,
        selected = selected, back = true })
    if selected == nil or not items[selected].action then return end
    items[selected].action()
end
