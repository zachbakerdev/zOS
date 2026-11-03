-- Round-trip and interoperability tests for gzip.lua. Run from the repository root: luajit tests/test_gzip.lua
-- The interoperability checks need the system gzip command and are skipped without it.
package.path = "tests/?.lua;?.lua;" .. package.path
require("cc_shim")

local yields = 0
os.queueEvent = function() yields = yields + 1 end
os.pullEvent = function() end

local gzip = require("gzip")
local failed = 0

local function check(name, ok, detail)
  if not ok then
    failed = failed + 1
    print("FAIL " .. name .. (detail and ("\n  " .. tostring(detail)) or ""))
  end
end

-- Seeded random bytes: incompressible, but the same every run under LuaJIT.
local function noise(n)
  math.randomseed(1)
  local t = {}
  for i = 1, n do t[i] = string.char(math.random(0, 255)) end
  return table.concat(t)
end

local function readFile(p)
  local f = assert(io.open(p, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local function writeFile(p, s)
  local f = assert(io.open(p, "wb"))
  f:write(s)
  f:close()
end

local words = {}
for w in readFile("src/.zos/lib/net.lua"):gmatch("%S+") do words[#words + 1] = w end
local prose = {}
for i = 1, 20000 do prose[i] = words[(i * 7919) % #words + 1] end

local samples = {
  empty = "",
  one = "a",
  short = "hello hello hello",
  source = readFile("src/.zos/lib/net.lua"),
  prose = table.concat(prose, " "),
  noise = noise(70000),
  repeated = string.rep("abcabcabc\n", 30000),
  zeros = string.rep("\0", 100000),
  bytes = (function() local t = {} for i = 0, 255 do t[#t + 1] = string.char(i) end return table.concat(t) end)(),
}
local names = {}
for name in pairs(samples) do names[#names + 1] = name end
table.sort(names)

-- CRC-32 known answers.
check("crc32 empty", gzip.crc32("") == 0)
check("crc32 check value", gzip.crc32("123456789") == 0xCBF43926, gzip.crc32("123456789"))

-- Our own round trips at each level.
for _, name in ipairs(names) do
  local data = samples[name]
  for _, level in ipairs({ 0, 1, 6, 9 }) do
    local packed = gzip.compress(data, { name = name, level = level })
    local back, storedName = gzip.decompress(packed)
    check(("round trip %s level %d"):format(name, level), back == data, storedName)
    check(("stored name %s level %d"):format(name, level), storedName == name, storedName)
  end
end

-- Compression actually compresses, and incompressible data falls back to stored blocks.
local sizes = {}
for _, name in ipairs(names) do sizes[name] = #gzip.compress(samples[name]) end
check("source shrinks", sizes.source < #samples.source / 2, sizes.source)
-- Fixed codes spend about 20 bits per maximum-length match, so ~1% is the floor for runs.
check("repeated shrinks to about 1%", sizes.repeated < #samples.repeated / 100, sizes.repeated)
check("noise falls back to stored blocks", sizes.noise <= #samples.noise + 30, sizes.noise)

-- Corrupt and truncated input fails cleanly instead of throwing.
local packed = gzip.compress(samples.source)
local function fails(name, input)
  local ok, out, err = pcall(gzip.decompress, input)
  check(name, ok and out == nil and type(err) == "string", ok and err or out)
end
fails("not gzip", "plain text")
fails("empty input", "")
fails("truncated trailer", packed:sub(1, -5))
fails("truncated body", packed:sub(1, math.floor(#packed / 2)))
fails("bad method", packed:sub(1, 2) .. "\7" .. packed:sub(4))
fails("flipped byte", packed:sub(1, 200) .. string.char((packed:byte(201) + 1) % 256) .. packed:sub(202))

-- Concatenated members decompress as one file, like gzip -d.
local joined = gzip.compress("first ") .. gzip.compress("second")
check("concatenated members", gzip.decompress(joined) == "first second")

check("long work yields", yields > 0, yields)

-- Interoperability with the system gzip: it reads ours, and we read its dynamic-Huffman output.
local hasGzip = os.execute("gzip --version >/dev/null 2>&1")
if hasGzip == true or hasGzip == 0 then
  local tmp = os.tmpname()
  for _, name in ipairs(names) do
    local data = samples[name]

    writeFile(tmp .. ".gz", gzip.compress(data, { name = name }))
    local p = io.popen("gzip -dc " .. tmp .. ".gz")
    local out = p:read("*a")
    p:close()
    check("system gzip reads " .. name, out == data, #out)

    writeFile(tmp, data)
    for _, level in ipairs({ 1, 6, 9 }) do
      p = io.popen("gzip -" .. level .. " -c " .. tmp)
      local theirs = p:read("*a")
      p:close()
      local back, err = gzip.decompress(theirs)
      check(("we read system gzip -%d %s"):format(level, name), back == data, err)
      if level == 6 then
        print(("%-9s %7d bytes -> ours %7d, gzip -6 %7d"):format(name, #data, sizes[name], #theirs))
      end
    end
  end
  os.remove(tmp)
  os.remove(tmp .. ".gz")
else
  print("skipping interoperability checks: no gzip command")
end

if failed > 0 then
  print(failed .. " failed")
  os.exit(1)
end
print("gzip: all tests passed")
