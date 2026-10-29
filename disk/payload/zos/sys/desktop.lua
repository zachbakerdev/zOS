-- zOS desktop: the app launcher shown after login.
-- Returns "logout", "reboot" or "shutdown".

local shell, nativePullEvent = ...
local ui, apps = zos.ui, zos.apps

local function status()
  local extra = zos.statusText()
  if extra ~= "" then extra = extra .. "  " end
  return extra .. zos.session.user .. "  " .. textutils.formatTime(os.time(), false)
end

local function run(app)
  local screen = term.current()
  -- Apps get normal Ctrl+T behaviour; it only ends the app, not the session.
  os.pullEvent = nativePullEvent
  local ok, result = pcall(apps.launch, app, shell)
  os.pullEvent = os.pullEventRaw
  term.redirect(screen)
  term.setCursorBlink(false)

  if not ok or result == false then
    if not ok then printError(tostring(result)) end
    print()
    ui.waitEnter(app.name .. " stopped with an error. Press Enter.")
  end
end

local power = {
  { label = "Log out", hint = "Return to the login screen", action = "logout" },
  { label = "Reboot", hint = "Restart the computer", action = "reboot" },
  { label = "Shut down", hint = "Turn the computer off", action = "shutdown" },
}

local selected = 1
while true do
  local list = apps.list()
  local items = {}
  for _, app in ipairs(list) do
    items[#items + 1] = { label = app.name, hint = app.description }
  end
  for _, p in ipairs(power) do
    items[#items + 1] = { label = p.label, hint = p.hint, fg = ui.theme.dim }
  end

  selected = ui.menu({ title = "zOS", status = status, items = items, selected = selected })
  if selected <= #list then
    run(list[selected])
  else
    return power[selected - #list].action
  end
end
