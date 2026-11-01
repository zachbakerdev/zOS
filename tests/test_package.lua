-- Tests of how ./package puts the built-in apps into an image.
-- Run from the repository root: lua5.2 tests/test_package.lua (or luajit)

local failed, passed = 0, 0
local function check(name, ok)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name)
  end
end

local function readHost(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local function writeHost(path, text)
  os.execute("mkdir -p '" .. path:match("^(.*)/") .. "'")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local TMP = os.tmpname()
os.remove(TMP)
local OUT = TMP .. "/out.zi"

-- Runs ./package and returns whether it worked, what it said, and the image's files.
local function package(options)
  os.remove(OUT)
  local p = io.popen("./package --no-minify -o '" .. OUT .. "' " .. options .. " 2>&1")
  local said = p:read("*a")
  p:close()
  local text = readHost(OUT)
  local image = text and (loadstring or load)("return " .. text)()
  return image ~= nil, said, image
end

-- A folder to package, and a folder of apps to take built-in apps from.
local function fixture(list, srcFiles, appFiles)
  os.execute("rm -rf '" .. TMP .. "'")
  writeHost(TMP .. "/src/startup.lua", "-- startup")
  if list then writeHost(TMP .. "/src/.zos/lib/builtin.lua", list) end
  for path, data in pairs(srcFiles or {}) do writeHost(TMP .. "/src/" .. path, data) end
  for path, data in pairs(appFiles or {}) do writeHost(TMP .. "/apps/" .. path, data) end
  return ("--src '%s/src' --apps '%s/apps'"):format(TMP, TMP)
end

-- The real system ---------------------------------------------------------------------------------

local ok, said, image = package("")
check("real: builds", ok)
local ids = {}
if ok then
  local list = assert((loadstring or load)(image["/.zos/lib/builtin.lua"]))()
  check("real: lists apps", #list > 0)
  for _, id in ipairs(list) do
    ids[id] = true
    check("real: " .. id .. " is copied from apps/",
      image["/.zos/apps/" .. id .. "/main.lua"] == readHost("apps/" .. id .. "/main.lua") and
      image["/.zos/apps/" .. id .. "/app.manifest"] == readHost("apps/" .. id .. "/app.manifest"))
  end
  check("real: other apps stay out", image["/.zos/apps/mail/main.lua"] == nil)
end
check("real: no second copy in src", not readHost("src/.zos/apps/files/main.lua"))

-- The rules ---------------------------------------------------------------------------------------

local APP = { ["a/main.lua"] = "-- a", ["a/app.manifest"] = "{}", ["a/lib/x.lua"] = "-- x", ["b/main.lua"] = "-- b", ["b/app.manifest"] = "{}" }

ok, said, image = package(fixture('-- A comment.\nreturn {\n  "a",\n}\n', nil, APP))
check("copies nested files", ok and image["/.zos/apps/a/lib/x.lua"] == "-- x")
check("copies only listed apps", ok and image["/.zos/apps/b/main.lua"] == nil)

ok, said, image = package(fixture(nil, nil, APP))
check("no list means no apps", ok and image["/.zos/apps/a/main.lua"] == nil)

ok, said = package(fixture('return { "ghost" }', nil, APP))
check("unknown app refused", not ok and said:find("ghost", 1, true))

ok, said = package(fixture('return { "a" }', nil, { ["a/main.lua"] = "-- a" }))
check("app without a manifest refused", not ok and said:find("app.manifest", 1, true))

ok, said = package(fixture('return { "a" }', { [".zos/apps/a/main.lua"] = "-- copy" }, APP))
check("second copy in src refused", not ok and said:find("Apps belong in", 1, true))

ok, said = package(fixture('return { "../a" }', nil, APP))
check("bad id refused", not ok and said:find("list of ids", 1, true))

ok, said = package(fixture('local x = 1\nreturn { "a" }', nil, APP))
check("code in the list refused", not ok and said:find("list of ids", 1, true))

os.execute("rm -rf '" .. TMP .. "'")

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
