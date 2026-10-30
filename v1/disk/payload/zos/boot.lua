-- zOS boot sequence. Started by /startup.lua with a context table:
--   { shell = <CraftOS shell>, multishell = ..., pullEvent = <original os.pullEvent> }

local ctx = ...
local VERSION = "1.3.0"

-- Module loader: libraries live in /zos/lib and receive the loader as `...`
-- so they can import each other.
local cache = {}
local function import(name)
  if cache[name] == nil then
    local fn, err = loadfile("/zos/lib/" .. name .. ".lua", nil, _G)
    if not fn then error(err, 0) end
    cache[name] = fn(import)
  end
  return cache[name]
end

local function halt(action)
  action()
  while true do os.pullEventRaw() end
end

-- Append a line to the system log.
local function log(text)
  fs.makeDir("/etc/zos")
  local f = fs.open("/etc/zos/system.log", "a")
  f.writeLine(os.date("%Y-%m-%d %H:%M:%S ") .. text)
  f.close()
end

-- System options, stored in /etc/zos/config.
local CONFIG = "/etc/zos/config"

local function readConfig()
  if not fs.exists(CONFIG) then return {} end
  local f = fs.open(CONFIG, "r")
  local config = textutils.unserialise(f.readAll())
  f.close()
  return type(config) == "table" and config or {}
end

local function writeConfig(config)
  fs.makeDir(fs.getDir(CONFIG))
  local f = fs.open(CONFIG, "w")
  f.write(textutils.serialise(config))
  f.close()
end

-- Secure boot stops CraftOS from booting off floppy disks, which would skip the
-- login screen. It is on unless an admin turned it off in Settings.
local function secureBootEnabled() return readConfig().secureBoot ~= false end

-- CraftOS checks shell.allow_disk_startup *before* running /startup.lua, so the
-- setting is persisted to /.settings.
local function applyBootPolicy()
  settings.set("shell.allow_disk_startup", not secureBootEnabled())
  settings.set("shell.allow_startup", true)
  settings.set("motd.enable", false)
  settings.save(".settings")
end

local function setSecureBoot(enabled)
  local config = readConfig()
  config.secureBoot = enabled == true
  writeConfig(config)
  applyBootPolicy()
  log("secure boot " .. (enabled and "enabled" or "disabled") .. " by " .. tostring(zos.session.user))
end

local services = {}

-- Extra text for the desktop's title bar. Apps (usually their services) add a
-- function returning a short string, or nil/"" for nothing.
local statusProviders = {}

local function addStatus(fn) statusProviders[#statusProviders + 1] = fn end

local function statusText()
  local out = {}
  for _, fn in ipairs(statusProviders) do
    local ok, text = pcall(fn, zos.session)
    if ok and type(text) == "string" and text ~= "" then out[#out + 1] = text end
  end
  return table.concat(out, "  ")
end

local zos = {
  version = VERSION,
  import = import,
  session = {},
  applyBootPolicy = applyBootPolicy,
  secureBootEnabled = secureBootEnabled,
  setSecureBoot = setSecureBoot,
  addStatus = addStatus,
  statusText = statusText,
  log = log,
}
_G.zos = zos

local ui = import("ui")
zos.ui = ui

local function splash(step, total, label)
  local w, h = term.getSize()
  local mid = math.floor(h / 2)
  term.setBackgroundColor(ui.theme.bg)
  term.clear()
  ui.center(mid - 2, "z O S", ui.theme.accent)
  ui.center(mid - 1, "version " .. VERSION, ui.theme.dim)

  local barW = math.min(30, w - 4)
  local x = math.floor((w - barW) / 2) + 1
  local filled = math.floor(barW * step / total)
  ui.at(x, mid + 1, string.rep(" ", filled), nil, ui.theme.selBg)
  ui.at(x + filled, mid + 1, string.rep(" ", barW - filled), nil, colors.gray)
  term.setBackgroundColor(ui.theme.bg)
  ui.center(mid + 3, label, ui.theme.dim)
end

local stages = {
  { "Applying boot policy", applyBootPolicy },
  { "Loading system libraries", function()
      zos.auth = import("auth")
      zos.apps = import("apps")
      zos.crypto = import("crypto")
      zos.keys = import("keys")
    end },
  { "Configuring shell", function()
      local path = ctx.shell.path()
      if not path:find("/zos/bin", 1, true) then ctx.shell.setPath(path .. ":/zos/bin") end
    end },
  { "Scanning applications", function() services = zos.apps.services() end },
}

for i, stage in ipairs(stages) do
  splash(i - 1, #stages, stage[1] .. "...")
  stage[2]()
  sleep(0.15)
end
splash(#stages, #stages, "Ready")
sleep(0.3)

local function sysProgram(name)
  return assert(loadfile("/zos/sys/" .. name .. ".lua", nil, _G))
end
local login = sysProgram("login")
local desktop = sysProgram("desktop")

-- One login -> desktop -> logout cycle.
local function session()
  local user, secretKey, publicKey = login()
  zos.session = {
    user = user,
    admin = zos.auth.isAdmin(user),
    since = os.epoch("utc"),
    secretKey = secretKey,
    publicKey = publicKey,
  }
  local action = desktop(ctx.shell, ctx.pullEvent)
  zos.session = {}
  zos.crypto.clearCache()
  if action == "reboot" or action == "shutdown" then
    applyBootPolicy()
    halt(action == "reboot" and os.reboot or os.shutdown)
  end
end

local function sessionLoop()
  while true do
    local ok, err = pcall(session)
    zos.session = {}
    zos.crypto.clearCache()
    os.pullEvent = os.pullEventRaw
    if not ok then
      ui.message("zOS - System error", "Something went wrong:\n\n" .. tostring(err) ..
        "\n\nYou have been logged out.", ui.theme.bad)
    end
  end
end

-- Background services run alongside the session and get their app's folder as
-- `...`. A crashing service is logged and stops, without affecting the session
-- or other services.
local function runServices()
  local tasks = {}
  for _, app in ipairs(services) do
    tasks[#tasks + 1] = function()
      local fn, err = loadfile(app.service, nil, _G)
      local ok = fn ~= nil
      if fn then ok, err = pcall(fn, app.dir) end
      if not ok then zos.log("service '" .. app.id .. "' stopped: " .. tostring(err)) end
    end
  end
  if #tasks > 0 then parallel.waitForAll(table.unpack(tasks)) end
  while true do os.pullEventRaw() end
end

parallel.waitForAny(sessionLoop, runServices)
