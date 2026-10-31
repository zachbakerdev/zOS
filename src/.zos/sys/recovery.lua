-- Shown when zOS can't start. An administrator can log in to get a shell; anyone else is rebooted.
-- This loads as little as it can, because the libraries may be what's broken.

local why = ...

local libEnv = setmetatable({}, { __index = _ENV })
local loaded = {}

function libEnv.require(name)
    if loaded[name] ~= nil then return loaded[name] end
    local path = "/.zos/lib/" .. name .. ".lua"
    local f = fs.open(path, "rb")
    if not f then error("No library called " .. name, 2) end
    local text = f.readAll()
    f.close()
    local fn, err = load(text, "@" .. path, "t", libEnv)
    if not fn then error(err, 0) end
    loaded[name] = fn(name)
    return loaded[name]
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("zOS can't start:")
print(tostring(why))
print("")

local ok, auth = pcall(libEnv.require, "auth")
if not ok or auth.count() == 0 or auth.lockRemaining() > 0 then
    print("Recovery isn't available. Restarting.")
    local timer = os.startTimer(10)
    repeat
        local _, id = os.pullEventRaw("timer")
    until id == timer
    return
end

print("Administrators can log in for a recovery shell.")
write("Name: ")
local name = read()
write("Password: ")
local password = read("*")

local allowed, err = auth.attempt(name, password)
if not allowed or not auth.isAdmin(name) then
    print(err or "Only administrators can use recovery.")
    local timer = os.startTimer(3)
    repeat
        local _, id = os.pullEventRaw("timer")
    until id == timer
    return
end

libEnv.require("system").log(name .. " opened the recovery shell")
print("Type exit to restart.")

-- Programs in this shell need Ctrl+T to work.
function os.pullEvent(filter)
    local event = table.pack(os.pullEventRaw(filter))
    if event[1] == "terminate" then error("Terminated", 0) end
    return table.unpack(event, 1, event.n)
end

pcall(os.run, { shell = shell }, "rom/programs/shell.lua")
