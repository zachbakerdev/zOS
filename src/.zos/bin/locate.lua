-- locate: print where this computer is, from GPS hosts a trusted root server vouches for.
-- See specs/libs/GPS.md.

local ctx = _G.zos
if not ctx then error("locate only runs in the zOS Terminal.", 0) end
local gps = ctx.require("gps")

local args = { ... }
local timeout = args[1] and tonumber(args[1])
if #args > 1 or (args[1] and not (timeout and timeout > 0)) then
    print("locate [seconds]  Print this computer's position")
    error("Usage: locate [seconds]", 0)
end

if #gps.wirelessModems() == 0 then error("No wireless modem attached.", 0) end
local x, y, z = gps.locate(timeout)
if not x then
    error("Couldn't work out where this is. It needs answers from at least 3 trusted GPS hosts.", 0)
end
print(x .. ", " .. y .. ", " .. z)
