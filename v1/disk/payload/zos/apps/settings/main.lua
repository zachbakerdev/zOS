-- zOS Settings: change password, manage users (admins) and set the computer label.

local ui, auth = zos.ui, zos.auth
local TITLE = "Settings"
local me = zos.session.user

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
  -- Your secret key is encrypted with your password, so re-encrypt it too.
  if ok then zos.keys.rewrap(me, current, password) end
  done("Password changed.", ok, err)
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
  done("Created user '" .. name .. "'.", auth.create(name, password, admin))
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
      "They will get a new one at their next login, and anything encrypted to the old key " ..
      "(such as Mail messages) will be unreadable.", ui.theme.accent)
    ui.text("")
    if not ui.confirm("Reset the password anyway?") then return end
    local password = ui.newPassword(auth.checkPassword, function() ui.screen(TITLE) end,
      "New password for " .. user.name)
    local ok, err = auth.setPassword(user.name, password)
    if ok then zos.keys.forget(user.name) end
    done("Password reset.", ok, err)
  elseif choice == 2 then
    ui.screen(TITLE)
    if user.name == me then
      return ui.message(TITLE, "You can't delete the account you are logged in with.", ui.theme.bad)
    end
    if ui.confirm("Delete user '" .. user.name .. "'?") then
      local ok, err = auth.remove(user.name)
      if ok then zos.keys.forget(user.name) end
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
  if zos.secureBootEnabled() then
    ui.text("Secure boot is ON. Floppy disks can't start this computer, so nobody can skip the login screen.")
    ui.text("")
    ui.text("If you turn it off, anyone with a disk can boot their own program and get full access to every file.", ui.theme.bad)
    ui.text("")
    if not ui.confirm("Turn secure boot off?") then return end
    local password = ui.input("Your password", "*")
    if not auth.verify(me, password) then
      return ui.message(TITLE, "Incorrect password. Secure boot is still on.", ui.theme.bad)
    end
    zos.setSecureBoot(false)
    ui.message(TITLE, "Secure boot is OFF. A disk with a startup program will now boot instead of zOS. " ..
      "Turn it back on when you're done.", ui.theme.accent)
  else
    ui.text("Secure boot is OFF. A floppy disk with a startup program will boot instead of zOS, " ..
      "skipping the login screen.", ui.theme.bad)
    ui.text("")
    if not ui.confirm("Turn secure boot on?") then return end
    zos.setSecureBoot(true)
    ui.message(TITLE, "Secure boot is ON. Floppy disks can no longer start this computer.", ui.theme.good)
  end
end

local selected = 1
while true do
  local items = {
    { label = "Change my password", action = changePassword },
    { label = "Computer label", action = label, hint = "Name shown on the login screen" },
  }
  if zos.session.admin then
    table.insert(items, 2, { label = "Users", action = users, hint = "Add, remove or reset accounts" })
    table.insert(items, 3, {
      label = "Secure boot: " .. (zos.secureBootEnabled() and "on" or "OFF"),
      action = secureBoot,
      hint = "Block booting from floppy disks",
      fg = not zos.secureBootEnabled() and ui.theme.bad or nil,
    })
  end
  items[#items + 1] = { label = "Back", fg = ui.theme.dim }

  selected = ui.menu({ title = TITLE, items = items, selected = selected, back = true })
  if selected == nil or not items[selected].action then return end
  items[selected].action()
end
