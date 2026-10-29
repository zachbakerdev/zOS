--[[ zOS application registry.

An app is a folder containing an `app.manifest` file and a main program:

  /apps/<id>/app.manifest   { name = "My App", description = "...", version = "1.0",
                              author = "you", main = "main.lua" }
  /apps/<id>/main.lua

A manifest may also name a background service (e.g. `service = "service.lua"`).
Services start at boot and run alongside the session, even while nobody is
logged in. They must never draw to the screen.

System apps live in /zos/apps (replaced when zOS is upgraded), user apps in /apps.
Apps are started with shell.run, so they get `shell`, `require` and arguments as
usual, plus the global `zos` API. ]]

local apps = {}

apps.SYSTEM_DIR = "/zos/apps"
apps.USER_DIR = "/apps"
apps.MANIFEST = "app.manifest"

local function readManifest(dir)
  local path = fs.combine(dir, apps.MANIFEST)
  if fs.isDir(path) or not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local m = textutils.unserialise(f.readAll())
  f.close()
  return type(m) == "table" and m or nil
end

local function writeManifest(dir, m)
  local f = fs.open(fs.combine(dir, apps.MANIFEST), "w")
  f.write(textutils.serialise(m))
  f.close()
end

local function scan(root, system)
  local found = {}
  if not fs.isDir(root) then return found end
  for _, id in ipairs(fs.list(root)) do
    local dir = fs.combine(root, id)
    local m = fs.isDir(dir) and readManifest(dir)
    if m then
      local main = fs.combine(dir, m.main or "main.lua")
      local service = m.service and fs.combine(dir, m.service)
      if service and not (fs.exists(service) and not fs.isDir(service)) then service = nil end
      if fs.exists(main) and not fs.isDir(main) then
        found[#found + 1] = {
          service = service and "/" .. service,
          id = id,
          name = m.name or id,
          description = m.description or "",
          version = m.version,
          author = m.author,
          order = m.order or 100,
          dir = "/" .. dir,
          main = "/" .. main,
          system = system,
        }
      end
    end
  end
  table.sort(found, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.name:lower() < b.name:lower()
  end)
  return found
end

function apps.validId(id)
  return type(id) == "string" and #id <= 32 and id:match("^[%w_%-]+$") ~= nil
end

-- All launchable apps: system apps first, then user apps.
function apps.list()
  local out = scan(apps.SYSTEM_DIR, true)
  for _, app in ipairs(scan(apps.USER_DIR, false)) do out[#out + 1] = app end
  return out
end

function apps.userApps() return scan(apps.USER_DIR, false) end

-- Apps that declare a background service.
function apps.services()
  local out = {}
  for _, app in ipairs(apps.list()) do
    if app.service then out[#out + 1] = app end
  end
  return out
end

function apps.get(id)
  for _, app in ipairs(apps.list()) do
    if app.id == id then return app end
  end
end

--[[ Install an app from `src`, which may be:
  * a folder containing an app.manifest (copied as-is), or
  * a single Lua file (wrapped into an app folder with a generated manifest).
  opts: id, name, description (for single files), force (replace an existing app).
  Returns the installed id, or nil and an error message. ]]
function apps.install(src, opts)
  opts = opts or {}
  if not fs.exists(src) then return nil, "Not found: " .. src end

  local id, manifest
  if fs.isDir(src) then
    manifest = readManifest(src)
    if not manifest then return nil, "Folder has no " .. apps.MANIFEST end
    local main = fs.combine(src, manifest.main or "main.lua")
    if not fs.exists(main) then return nil, "Main file missing: " .. (manifest.main or "main.lua") end
    id = opts.id or manifest.id or fs.getName(src)
  else
    id = opts.id or (fs.getName(src):gsub("%.lua$", ""))
    manifest = {
      name = opts.name or id,
      description = opts.description or "",
      version = "1.0",
      main = "main.lua",
    }
  end

  id = id:lower()
  if not apps.validId(id) then return nil, "Invalid app id '" .. id .. "' (use letters, digits, - and _)" end
  if fs.exists(fs.combine(apps.SYSTEM_DIR, id)) then return nil, "'" .. id .. "' is a system app" end

  local dest = fs.combine(apps.USER_DIR, id)
  if fs.exists(dest) then
    if not opts.force then return nil, "'" .. id .. "' is already installed" end
    fs.delete(dest)
  end

  fs.makeDir(apps.USER_DIR)
  if fs.isDir(src) then
    fs.copy(src, dest)
  else
    fs.makeDir(dest)
    fs.copy(src, fs.combine(dest, "main.lua"))
    writeManifest(dest, manifest)
  end
  return id
end

-- Download a single-file app over HTTP. `source` is a URL or a Pastebin code.
function apps.download(source, id, opts)
  if not http then return nil, "The HTTP API is disabled on this server." end
  if not apps.validId(id) then return nil, "Invalid app id '" .. tostring(id) .. "'" end
  local url = source
  if not source:match("^https?://") then
    url = "https://pastebin.com/raw/" .. textutils.urlEncode(source)
  end

  local res, err = http.get(url)
  if not res then return nil, "Download failed: " .. tostring(err) end
  local body = res.readAll()
  res.close()
  local ok, syntaxErr = load(body, "=" .. id)
  if not ok then return nil, "Downloaded file is not valid Lua: " .. tostring(syntaxErr) end

  local tmp = "/.zos-download.lua"
  local f = fs.open(tmp, "w")
  f.write(body)
  f.close()
  opts = opts or {}
  opts.id = id
  local installed, installErr = apps.install(tmp, opts)
  fs.delete(tmp)
  return installed, installErr
end

function apps.remove(id)
  local dir = fs.combine(apps.USER_DIR, id or "")
  if not apps.validId(id) or not fs.isDir(dir) then
    return nil, "Not an installed user app: " .. tostring(id)
  end
  fs.delete(dir)
  return true
end

-- Run an app in the given shell. Returns false if it crashed.
function apps.launch(app, shell, ...)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  return shell.run(app.main, ...)
end

return apps
