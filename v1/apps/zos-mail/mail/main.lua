-- zOS Mail: read and send end-to-end encrypted messages to users on this or
-- other zOS computers.

local dir = fs.getDir(shell.getRunningProgram())
local mail = assert(loadfile(fs.combine(dir, "mail.lua"), nil, _G))(zos.import)
local ui, keys = zos.ui, zos.keys
local me = zos.session.user
local secretKey, publicKey = zos.session.secretKey, zos.session.publicKey
local TITLE = "Mail"

local function address() return mail.address(me) end

local function fmtTime(ms)
  return os.date("%Y-%m-%d %H:%M", math.floor((ms or 0) / 1000))
end

-- Send, asking the user what to do if the recipient's key is missing or changed.
local function deliver(to, subject, body)
  local opts = { secretKey = secretKey, publicKey = publicKey }
  while true do
    ui.screen(TITLE .. " - Sending", address())
    ui.text(opts.plain and "Sending..." or "Encrypting and sending...", ui.theme.dim)
    local ok, err, info = mail.send(me, to, subject, body, opts)
    if ok then
      return ui.message(TITLE, "Message sent to " .. to .. (opts.plain and " (not encrypted)." or ", encrypted."),
        ui.theme.good)
    end

    ui.screen(TITLE, address())
    if info and info.code == "keychanged" then
      ui.text("WARNING: " .. err, ui.theme.bad)
      ui.text("")
      ui.text("Saved key:  " .. keys.fingerprint(info.old))
      ui.text("Offered key: " .. keys.fingerprint(info.new))
      ui.text("")
      ui.text("This happens if their password was reset, or if someone is impersonating " ..
        "them. Check the new fingerprint with them (they can see it in Mail > Encryption keys).",
        ui.theme.dim)
      ui.text("")
      if not ui.confirm("Trust the new key and send?") then return end
      opts.trustNewKey = true
    elseif info and (info.code == "nokey" or info.code == "locked") and not opts.plain then
      ui.text("Can't encrypt: " .. err, ui.theme.accent)
      ui.text("")
      if not ui.confirm("Send it WITHOUT encryption?") then return end
      opts.plain = true
    else
      return ui.message(TITLE, "Not sent: " .. tostring(err), ui.theme.bad)
    end
  end
end

local function compose(to, subject, quote)
  ui.screen(TITLE .. " - New message", address())
  ui.text("Send to user@computer (computer ID or label), or just a username for this computer.", ui.theme.dim)
  ui.text("")
  to = ui.input("To", nil, to)
  if to == "" then return end
  subject = ui.input("Subject (not encrypted)", nil, subject)
  ui.text("Message (finish with a line containing only a dot):", ui.theme.accent)

  local lines = {}
  while true do
    term.setTextColor(ui.theme.fg)
    local line = read()
    if line == "." then break end
    lines[#lines + 1] = line
  end
  local body = table.concat(lines, "\n")
  if quote then body = body .. "\n\n--- Original message ---\n" .. quote end

  ui.screen(TITLE .. " - New message", address())
  ui.text("To: " .. to)
  ui.text("Subject: " .. (subject ~= "" and subject or "(no subject)"))
  ui.text(#lines .. " line(s)", ui.theme.dim)
  ui.text("")
  if not ui.confirm("Send this message?") then return end
  deliver(to, subject, body)
end

local SENDER_STATUS = {
  verified = "Encrypted. Sender verified",
  unverified = "Encrypted. Sender NOT verified (couldn't reach their computer to check their key)",
  changed = "WARNING: encrypted with a key that does NOT match the one on record for this sender. " ..
    "It may be forged, or their key was reset.",
}

-- Returns the body to show and a one-line security summary.
local function reveal(folder, msg)
  if not msg.enc then return msg.body, "NOT encrypted" end
  if not secretKey then return "", "Encrypted, but your key isn't unlocked. Log out and back in." end
  ui.screen(TITLE, address())
  ui.text("Decrypting...", ui.theme.dim)
  local text, err = mail.decrypt(msg, secretKey, publicKey)
  if not text then return "", "Encrypted. " .. err end
  if folder == "sent" then return text, "Encrypted" end
  ui.text("Checking sender's key...", ui.theme.dim)
  local status = mail.checkSender(msg)
  local summary = SENDER_STATUS[status] .. " (key " .. keys.fingerprint(zos.crypto.fromHex(msg.enc.from)) .. ")"
  return text, summary
end

local function view(folder, msg)
  if folder == "inbox" then mail.markRead(me, msg) end
  local body, security = reveal(folder, msg)
  local text = "From: " .. msg.from .. (msg.via and (" (sent by computer #" .. msg.via .. ")") or "") ..
    "\nTo: " .. msg.to ..
    "\nDate: " .. fmtTime(msg.time) ..
    "\nSubject: " .. (msg.subject ~= "" and msg.subject or "(no subject)") ..
    "\nSecurity: " .. security ..
    "\n\n" .. body

  local action
  if folder == "inbox" then
    action = ui.pager(TITLE, text, "R: reply  D: delete  Q: back", { r = "reply", d = "delete" })
  else
    action = ui.pager(TITLE, text, "D: delete  Q: back", { d = "delete" })
  end

  if action == "reply" then
    local subject = msg.subject:match("^Re: ") and msg.subject or ("Re: " .. msg.subject)
    compose(msg.from, subject:sub(1, 64), body)
  elseif action == "delete" then
    ui.screen(TITLE)
    if ui.confirm("Delete this message?") then mail.delete(me, folder, msg) end
  end
end

local function browse(folder, title)
  local selected = 1
  while true do
    local msgs = mail.list(me, folder)
    local items = {}
    for _, m in ipairs(msgs) do
      local subject = m.subject ~= "" and m.subject or "(no subject)"
      local who = folder == "inbox" and m.from or ("to " .. m.to)
      items[#items + 1] = {
        label = (m.read and "  " or "* ") .. subject,
        hint = who .. "  " .. fmtTime(m.time) .. (m.enc and "" or "  [plain]"),
      }
    end
    if #msgs == 0 then items[1] = { label = "(no messages)", fg = ui.theme.dim } end
    items[#items + 1] = { label = "Back", fg = ui.theme.dim }

    selected = ui.menu({ title = TITLE .. " - " .. title, status = address, items = items,
      selected = selected, back = true })
    if not selected or selected == #items then return end
    if msgs[selected] then view(folder, msgs[selected]) end
  end
end

local function keyScreen()
  while true do
    local known = keys.knownList()
    local mine = publicKey and keys.fingerprint(publicKey) or "locked"
    local items = {
      { label = "Your key: " .. mine, hint = "Read this out to people who want to verify you" },
    }
    for _, k in ipairs(known) do
      items[#items + 1] = { label = k.address .. "  " .. k.fingerprint, hint = "Select to forget this saved key" }
    end
    if #known == 0 then items[#items + 1] = { label = "(no saved keys yet)", fg = ui.theme.dim } end
    items[#items + 1] = { label = "Back", fg = ui.theme.dim }

    local choice = ui.menu({ title = TITLE .. " - Encryption keys", status = address, items = items, back = true })
    if not choice or choice == #items then return end
    local k = known[choice - 1]
    if k then
      ui.screen(TITLE)
      ui.text("Forgetting a key means the next key offered for " .. k.address ..
        " will be trusted automatically.", ui.theme.dim)
      ui.text("")
      if ui.confirm("Forget the saved key for " .. k.address .. "?") then keys.forgetKnown(k.address) end
    end
  end
end

local selected = 1
while true do
  local unread = mail.unread(me)
  local network = mail.openModems() and "" or " (no modem: this computer only)"
  local items = {
    { label = "Inbox" .. (unread > 0 and (" (" .. unread .. " new)") or ""), hint = "Messages you have received" },
    { label = "Compose", hint = "Write a new message" .. network },
    { label = "Sent", hint = "Messages you have sent" },
    { label = "Encryption keys", hint = "Your key fingerprint and saved keys" },
    { label = "Back", fg = ui.theme.dim },
  }
  selected = ui.menu({ title = TITLE, status = address, items = items, selected = selected, back = true })
  if selected == 1 then browse("inbox", "Inbox")
  elseif selected == 2 then compose()
  elseif selected == 3 then browse("sent", "Sent")
  elseif selected == 4 then keyScreen()
  else return
  end
end
