-- Tests for the tar, gzip and gunzip shell programs in /.zos/bin.
-- Run from the repository root: luajit tests/test_archives.lua
-- The interoperability checks need the system tar and gzip commands and are skipped without them.
package.path = "tests/?.lua;src/.zos/lib/?.lua;" .. package.path
local sim = require("sim")

local failed = 0
local function check(name, ok, detail)
  if not ok then
    failed = failed + 1
    print("FAIL " .. name .. (detail and ("\n  " .. tostring(detail)) or ""))
  end
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

local function binary(n)
  local t = {}
  for i = 1, n do t[i] = string.char((i * 37 + math.floor(i / 7)) % 256) end
  return table.concat(t)
end

local TEXT = "hello archive\n" .. string.rep("line of text\n", 200)
local BIN = binary(3000)

-- A computer with just what the programs need: files, the two libraries and the event queue.
local function fresh()
  local c = { files = {
    ["home/me/docs/a.txt"] = TEXT,
    ["home/me/docs/sub/b.bin"] = BIN,
    ["home/me/notes.txt"] = "notes\n",
  } }
  local env = setmetatable({}, { __index = _G })
  env._G = env
  env.fs = sim.newFs(c.files)
  local events = {}
  env.os = setmetatable({
    epoch = function() return 1700000000000 end,
    queueEvent = function(name) events[#events + 1] = name end,
    pullEvent = function(filter)
      local name = table.remove(events, 1)
      assert(name == filter, "unexpected event " .. tostring(name))
      return name
    end,
  }, { __index = os })
  local loaded = {}
  env.require = function(name)
    if not loaded[name] then
      loaded[name] = assert(load(readFile("src/.zos/lib/" .. name .. ".lua"), "@" .. name, "t", env))(name)
    end
    return loaded[name]
  end
  env.zos = { require = env.require, user = "me", admin = true }
  c.env = env
  return c
end

-- Runs a program from /.zos/bin. Returns true or false, the error, and everything it printed.
local function run(c, cwd, program, ...)
  local out = {}
  local env = setmetatable({}, { __index = c.env })
  env._ENV = env
  env.print = function(...)
    local t = table.pack(...)
    for i = 1, t.n do t[i] = tostring(t[i]) end
    out[#out + 1] = table.concat(t, " ")
  end
  env.printError = function(s) out[#out + 1] = "! " .. tostring(s) end
  env.shell = {
    dir = function() return cwd end,
    resolve = function(p)
      if p:sub(1, 1) == "/" then return c.env.fs.combine(p, "") end
      return c.env.fs.combine(cwd, p)
    end,
    getRunningProgram = function() return ".zos/bin/" .. program .. ".lua" end,
  }
  env.loadfile = function(path, _, e)
    return load(readFile("src/" .. c.env.fs.combine(path, "")), "@" .. path, "t", e)
  end
  local fn = assert(env.loadfile(".zos/bin/" .. program .. ".lua", nil, env))
  local ok, err = pcall(fn, ...)
  return ok, err, table.concat(out, "\n")
end

local haveTar = os.execute("tar --version >/dev/null 2>&1")
haveTar = haveTar == true or haveTar == 0
local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p " .. tmp)

-- tar czf, then extract it again with -C.
do
  local c = fresh()
  local ok, err, out = run(c, "home/me", "tar", "czf", "out.tar.gz", "docs")
  check("czf succeeds", ok, err)
  local gz = c.files["home/me/out.tar.gz"]
  check("czf writes gzip", gz and gz:sub(1, 2) == "\31\139")
  check("czf reports", out:find("Archived 2 files", 1, true), out)

  local entries = c.env.require("tar").parse(gz)
  local names = {}
  for _, e in ipairs(entries) do names[#names + 1] = e.name end
  check("czf entries", table.concat(names, ",") == "docs/,docs/a.txt,docs/sub/,docs/sub/b.bin", table.concat(names, ","))

  ok, err = run(c, "home/me", "tar", "-xf", "out.tar.gz", "-C", "restore")
  check("xf -C succeeds", ok, err)
  check("xf restores text", c.files["home/me/restore/docs/a.txt"] == TEXT)
  check("xf restores binary", c.files["home/me/restore/docs/sub/b.bin"] == BIN)

  if haveTar then
    writeFile(tmp .. "/out.tar.gz", gz)
    local p = io.popen("tar tzf " .. tmp .. "/out.tar.gz")
    local listed = p:read("*a")
    p:close()
    check("system tar lists it", listed == "docs/\ndocs/a.txt\ndocs/sub/\ndocs/sub/b.bin\n", listed)
    os.execute("mkdir -p " .. tmp .. "/x && tar xzf " .. tmp .. "/out.tar.gz -C " .. tmp .. "/x")
    check("system tar extracts it", readFile(tmp .. "/x/docs/sub/b.bin") == BIN)
  end
end

-- Doing it in two steps: tar cf, gzip, gunzip, tar xf.
do
  local c = fresh()
  local ok, err = run(c, "home/me", "tar", "-c", "-f", "plain.tar", "docs", "notes.txt")
  check("cf succeeds", ok, err)
  local plain = c.files["home/me/plain.tar"]
  check("cf isn't compressed", plain and plain:sub(1, 2) ~= "\31\139" and #plain % 512 == 0)

  local out
  ok, err, out = run(c, "home/me", "gzip", "plain.tar")
  check("gzip succeeds", ok, err)
  check("gzip replaces the file", c.files["home/me/plain.tar.gz"] and not c.files["home/me/plain.tar"])
  check("gzip reports", out:find("/home/me/plain.tar -> /home/me/plain.tar.gz", 1, true), out)
  local _, members = c.env.require("compression").gunzip(c.files["home/me/plain.tar.gz"])
  check("gzip stores the name", members[1].name == "plain.tar")

  ok, err = run(c, "home/me", "tar", "tf", "plain.tar.gz")
  check("tf reads .tar.gz", ok, err)

  ok, err = run(c, "home/me", "gunzip", "plain.tar.gz")
  check("gunzip succeeds", ok, err)
  check("gunzip gives back the same bytes", c.files["home/me/plain.tar"] == plain)
  check("gunzip removes the .gz", not c.files["home/me/plain.tar.gz"])

  local _, _, listing = run(c, "home/me", "tar", "-tvf", "plain.tar")
  check("tvf lists", listing:find("docs/sub/b.bin", 1, true) and listing:find("notes.txt", 1, true), listing)

  ok, err = run(c, "", "tar", "xf", "/home/me/plain.tar")
  check("xf into the current folder", ok, err)
  check("xf wrote notes", c.files["notes.txt"] == "notes\n")
end

-- gzip options.
do
  local c = fresh()
  local ok, err = run(c, "home/me", "gzip", "-k9", "notes.txt")
  check("gzip -k succeeds", ok, err)
  check("gzip -k keeps the original", c.files["home/me/notes.txt"] and c.files["home/me/notes.txt.gz"])

  local out
  ok, err, out = run(c, "home/me", "gzip", "notes.txt")
  check("gzip won't replace without -f", not ok and out:find("already exists", 1, true), out)
  ok, err = run(c, "home/me", "gzip", "-f", "notes.txt")
  check("gzip -f replaces", ok and not c.files["home/me/notes.txt"], err)

  ok, err, out = run(c, "home/me", "gzip", "notes.txt.gz")
  check("gzip refuses .gz", not ok and out:find("already compressed", 1, true), out)
  ok, err, out = run(c, "home/me", "gzip", "-d", "docs/a.txt")
  check("gzip -d needs a suffix", not ok and out:find("unknown suffix", 1, true), out)
  ok, err, out = run(c, "home/me", "gzip", "docs")
  check("gzip refuses folders", not ok and out:find("folder", 1, true), out)
  c.files["home/me/bad.gz"] = "not gzip"
  ok, err, out = run(c, "home/me", "gunzip", "bad.gz")
  check("gunzip rejects junk", not ok and out:find("not a valid gzip", 1, true) and c.files["home/me/bad.gz"], out)

  ok, err = run(c, "home/me", "gzip", "--decompress", "--keep", "notes.txt.gz")
  check("long options", ok and c.files["home/me/notes.txt"] == "notes\n" and c.files["home/me/notes.txt.gz"], err)

  c.files["home/me/x.tar"] = "tar bytes"
  run(c, "home/me", "gzip", "x.tar")
  c.files["home/me/x.tgz"], c.files["home/me/x.tar.gz"] = c.files["home/me/x.tar.gz"], nil
  ok, err = run(c, "home/me", "gunzip", "x.tgz")
  check(".tgz becomes .tar", ok and c.files["home/me/x.tar"] == "tar bytes", err)
end

-- tar options and safety.
do
  local c = fresh()
  local ok, err = run(c, "home/me", "tar", "--create", "--file=auto.tgz", "docs")
  check("long options create", ok, err)
  check(".tgz name implies -z", c.files["home/me/auto.tgz"]:sub(1, 2) == "\31\139")

  ok, err = run(c, "home/me", "tar", "cf", "self.tar", ".")
  check("archive . succeeds", ok, err)
  local names = {}
  for _, e in ipairs(c.env.require("tar").parse(c.files["home/me/self.tar"])) do names[e.name] = true end
  check("archive . uses plain names", names["notes.txt"] and names["docs/a.txt"] and names["auto.tgz"])
  check("never archives itself", not names["self.tar"])

  ok, err = run(c, "home/me", "tar", "cxf", "a.tar")
  check("one mode only", not ok and tostring(err):find("Choose one", 1, true), err)
  ok = run(c, "home/me", "tar", "cf", "a.tar", "missing")
  check("missing path fails", not ok and not c.files["home/me/a.tar"])

  local tarlib = c.env.require("tar")
  c.files["home/me/evil.tar"] = tarlib.create({ { name = "ok.txt", data = "x" }, { name = "../../etc/evil", data = "x" } })
  ok, err = run(c, "home/me", "tar", "xf", "evil.tar", "-C", "out")
  check("rejects ..", not ok and tostring(err):find("Unsafe", 1, true), err)
  check("a bad archive writes nothing", not c.files["home/me/out/ok.txt"] and not c.files["etc/evil"])

  c.files["home/me/clash.tar"] = tarlib.create({ { name = "first.txt", data = "x" }, { name = "notes.txt/inner", data = "x" } })
  ok, err = run(c, "home/me", "tar", "xf", "clash.tar")
  check("file in the way", not ok and tostring(err):find("is a file", 1, true), err)
  check("a clash writes nothing", not c.files["home/me/first.txt"])

  c.files["home/me/link.tar"] = tarlib.create({ { name = "l", type = "symlink", linkname = "x" }, { name = "f", data = "y" } })
  local out2
  ok, err, out2 = run(c, "home/me", "tar", "xf", "link.tar")
  check("skips symlinks", not ok and out2:find("Skipping l", 1, true) and c.files["home/me/f"] == "y", out2)

  c.files["home/me/abs.tar"] = tarlib.create({ { name = "/abs/file", data = "z" }, { name = "./dot/file", data = "w" } })
  ok, err = run(c, "home/me", "tar", "xf", "abs.tar", "-C", "in")
  check("strips / and ./", ok and c.files["home/me/in/abs/file"] == "z" and c.files["home/me/in/dot/file"] == "w", err)
end

-- An archive made by the system tar.
if haveTar then
  local c = fresh()
  os.execute("mkdir -p " .. tmp .. "/src/d && printf 'one' > " .. tmp .. "/src/d/1.txt && printf 'two' > " .. tmp .. "/src/2.txt")
  os.execute("tar czf " .. tmp .. "/sys.tar.gz -C " .. tmp .. "/src .")
  c.files["home/me/sys.tar.gz"] = readFile(tmp .. "/sys.tar.gz")
  local ok, err = run(c, "home/me", "tar", "xzf", "sys.tar.gz", "-C", "sys")
  check("extracts a system tar.gz", ok and c.files["home/me/sys/d/1.txt"] == "one" and c.files["home/me/sys/2.txt"] == "two", err)
  writeFile(tmp .. "/f.gz", "")
  os.execute("printf 'gzip me' | gzip > " .. tmp .. "/f.gz")
  c.files["home/me/f.gz"] = readFile(tmp .. "/f.gz")
  ok, err = run(c, "home/me", "gunzip", "f.gz")
  check("gunzips a system .gz", ok and c.files["home/me/f"] == "gzip me", err)
else
  print("skipping interoperability checks: no system tar")
end

os.execute("rm -rf " .. tmp)

if failed > 0 then
  print(failed .. " failed")
  os.exit(1)
end
print("archives: all passed")
