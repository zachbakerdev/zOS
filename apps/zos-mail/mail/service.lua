-- Receives mail from other computers in the background, and shows the number
-- of unread messages in the desktop's title bar. zOS passes the app's folder.
local dir = ...
local mail = assert(loadfile(fs.combine(dir, "mail.lua"), nil, _G))(zos.import)

zos.addStatus(function(session)
  local unread = session.user and mail.unread(session.user) or 0
  return unread > 0 and (unread .. " new mail") or nil
end)

mail.service()
