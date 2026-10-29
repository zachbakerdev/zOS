-- zOS App Manager: install apps from disk/folders/URLs and remove them.

local ui, apps = zos.ui, zos.apps
local TITLE = "App Manager"

local function result(id, err)
  if id then
    ui.message(TITLE, "Installed '" .. id .. "'. It is now on the desktop.", ui.theme.good)
  else
    ui.message(TITLE, err, ui.theme.bad)
  end
end

local function askForce(id, err)
  -- Offer to replace an app that is already installed.
  if err and err:find("already installed", 1, true) then
    ui.screen(TITLE)
    ui.text(err .. ".")
    return ui.confirm("Replace it?")
  end
end

local function installFromPath()
  ui.screen(TITLE)
  ui.text("Enter the path of an app folder (containing " .. apps.MANIFEST ..
    ") or a single .lua file, e.g. disk/myapp", ui.theme.dim)
  ui.text("")
  local path = ui.input("Path")
  if path == "" then return end
  path = shell.resolve(path)

  local opts = {}
  if fs.exists(path) and not fs.isDir(path) then
    opts.name = ui.input("Display name", nil, (fs.getName(path):gsub("%.lua$", "")))
    opts.description = ui.input("Description (optional)")
  end
  local id, err = apps.install(path, opts)
  if not id and askForce(nil, err) then
    opts.force = true
    id, err = apps.install(path, opts)
  end
  result(id, err)
end

local function installFromWeb()
  ui.screen(TITLE)
  ui.text("Download a single-file Lua app. Enter a full URL or a Pastebin code.", ui.theme.dim)
  ui.text("")
  local source = ui.input("URL or Pastebin code")
  if source == "" then return end
  local id = ui.input("App id (letters, digits, - and _)")
  local name = ui.input("Display name", nil, id)
  ui.text("Downloading...", ui.theme.dim)
  local opts = { name = name }
  local ok, err = apps.download(source, id, opts)
  if not ok and askForce(nil, err) then
    opts.force = true
    ui.text("Downloading...", ui.theme.dim)
    ok, err = apps.download(source, id, opts)
  end
  result(ok, err)
end

local function manage(app)
  ui.screen(TITLE)
  ui.text(app.name, ui.theme.accent)
  ui.text("id: " .. app.id .. "   version: " .. tostring(app.version or "?"), ui.theme.dim)
  if app.author then ui.text("by " .. app.author, ui.theme.dim) end
  ui.text("")
  if app.description ~= "" then ui.text(app.description) ui.text("") end
  if ui.confirm("Remove this app?") then
    local ok, err = apps.remove(app.id)
    ui.message(TITLE, ok and ("Removed '" .. app.id .. "'.") or err, ok and ui.theme.good or ui.theme.bad)
  end
end

local selected = 1
while true do
  local installed = apps.userApps()
  local items = {
    { label = "Install from disk or path...", hint = "Copy an app folder or .lua file" },
    { label = "Install from URL / Pastebin...", hint = "Requires the HTTP API" },
  }
  for _, app in ipairs(installed) do
    items[#items + 1] = { label = app.name .. " (" .. app.id .. ")", hint = "Select to view or remove" }
  end
  items[#items + 1] = { label = "Back", fg = ui.theme.dim }

  selected = ui.menu({ title = TITLE, items = items, selected = selected, back = true })
  if selected == nil or selected == #items then return
  elseif selected == 1 then installFromPath()
  elseif selected == 2 then installFromWeb()
  else manage(installed[selected - 2])
  end
end
