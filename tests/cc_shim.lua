-- The parts of the CC: Tweaked API that the zOS libraries need, for running tests off-game
-- under LuaJIT (which, like CC, uses doubles for every number).

if not table.unpack then table.unpack = unpack end
if not table.pack then
  table.pack = function(...) return { n = select("#", ...), ... } end
end

local bit = require("bit")
local function u(x) return x % 4294967296 end
bit32 = {
  band = function(...) return u(bit.band(...)) end,
  bor = function(...) return u(bit.bor(...)) end,
  bxor = function(...) return u(bit.bxor(...)) end,
  bnot = function(x) return u(bit.bnot(x)) end,
  lshift = function(x, n) return n >= 32 and 0 or u(bit.lshift(x, n)) end,
  rshift = function(x, n) return n >= 32 and 0 or u(bit.rshift(x, n)) end,
  lrotate = function(x, n) return u(bit.rol(x, n)) end,
  rrotate = function(x, n) return u(bit.ror(x, n)) end,
}
