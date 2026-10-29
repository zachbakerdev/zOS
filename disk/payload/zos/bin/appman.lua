-- appman: command-line app manager for zOS.

local USAGE = [[
Usage:
  appman list
  appman install <folder|file.lua> [id]
  appman get <url|pastebin-code> <id>
  appman remove <id>]]

if not zos or not zos.apps then
  printError("appman must be run inside zOS.")
  return
end

local apps = zos.apps
local command, a, b = ...

local function report(id, err)
  if id then print("Installed '" .. id .. "'.") else printError(err) end
end

if command == "list" then
  for _, app in ipairs(apps.list()) do
    print(string.format("%-12s %-18s %s", app.id, app.name, app.system and "[system]" or (app.version or "")))
  end
elseif command == "install" and a then
  report(apps.install(shell.resolve(a), { id = b }))
elseif command == "get" and a and b then
  print("Downloading...")
  report(apps.download(a, b))
elseif command == "remove" and a then
  local ok, err = apps.remove(a)
  if ok then print("Removed '" .. a .. "'.") else printError(err) end
else
  print(USAGE)
end
