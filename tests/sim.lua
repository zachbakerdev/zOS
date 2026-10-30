-- Runs several zOS computers in one process, on a shared virtual clock and modem network, using
-- the real libraries. Each computer gets its own globals, files and copies of the modules.

require("cc_shim")

local LIB = "disk/payload/zos/lib/"

local sim = { computers = {}, wire = {}, onPacket = nil }
local clock = 1700000000000
local STEP = 2 -- virtual ms per event, so timeouts are reached even when nothing else is happening

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[copy(k)] = copy(x) end
  return out
end
sim.copy = copy

local function serialize(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  local out = {}
  for k, x in pairs(v) do out[#out + 1] = "[" .. serialize(k) .. "]=" .. serialize(x) end
  return "{" .. table.concat(out, ",") .. "}"
end

local function unserialize(s)
  local fn = loadstring("return " .. s)
  return fn and fn()
end

local function newFs(files)
  local fs = {}
  local dirs = {} -- empty folders; others exist because of the files in them
  local function norm(p) return (p:gsub("^/+", "")) end
  function fs.combine(a, b)
    a, b = norm(a), norm(b or "")
    if a == "" then return b end
    if b == "" then return a end
    return a .. "/" .. b
  end
  function fs.getDir(p) return norm(p):match("^(.*)/[^/]*$") or "" end
  function fs.exists(p)
    p = norm(p)
    if files[p] or dirs[p] then return true end
    for k in pairs(files) do if k:sub(1, #p + 1) == p .. "/" then return true end end
    return false
  end
  function fs.getName(p) return norm(p):match("[^/]*$") end
  function fs.isReadOnly(p) p = norm(p) return p == "rom" or p:sub(1, 4) == "rom/" end
  function fs.list(p)
    p = norm(p)
    local prefix, seen, names = p == "" and "" or p .. "/", {}, {}
    for _, set in ipairs({ files, dirs }) do
      for k in pairs(set) do
        local name = type(k) == "string" and k:sub(1, #prefix) == prefix and k:sub(#prefix + 1):match("^[^/]+")
        if name and not seen[name] then
          seen[name] = true
          names[#names + 1] = name
        end
      end
    end
    table.sort(names)
    return names
  end
  function fs.isDir(p) return fs.exists(p) and not files[norm(p)] end
  function fs.getSize(p) return #files[norm(p)] end
  function fs.getFreeSpace() return files.freeSpace or 1000000 end
  function fs.makeDir(p) dirs[norm(p)] = true end
  function fs.delete(p)
    p = norm(p)
    for _, set in ipairs({ files, dirs }) do
      for k in pairs(set) do
        if k == p or (type(k) == "string" and k:sub(1, #p + 1) == p .. "/") then set[k] = nil end
      end
    end
  end
  function fs.copy(a, b)
    a, b = norm(a), norm(b)
    for _, set in ipairs({ files, dirs }) do
      local found = {}
      for k, v in pairs(set) do
        if k == a or (type(k) == "string" and k:sub(1, #a + 1) == a .. "/") then found[b .. k:sub(#a + 1)] = v end
      end
      for k, v in pairs(found) do set[k] = v end
    end
  end
  function fs.move(a, b)
    fs.copy(a, b)
    fs.delete(a)
  end
  function fs.open(p, mode)
    p = norm(p)
    if mode:sub(1, 1) == "r" then
      if not files[p] then return nil end
      return { readAll = function() return files[p] end, close = function() end }
    end
    local buf = mode:sub(1, 1) == "a" and { files[p] or "" } or {}
    return {
      write = function(s) buf[#buf + 1] = s end,
      writeLine = function(s) buf[#buf + 1] = s .. "\n" end,
      close = function() files[p] = table.concat(buf) end,
    }
  end
  return fs
end

local function newTerm(computer)
  local w, h = computer.width or 51, 19
  local x, y, screen = 1, 1, {}
  local t = {}
  local function blank() return string.rep(" ", w) end
  function t.getSize() return w, h end
  function t.getCursorPos() return x, y end
  function t.setCursorPos(a, b) x, y = a, b end
  function t.clear() screen = {} end
  function t.clearLine() screen[y] = nil end
  function t.write(s)
    local line = screen[y] or blank()
    screen[y] = (line:sub(1, x - 1) .. s .. line:sub(x + #s + 1)):sub(1, w)
    x = x + #s
  end
  function t.setTextColor() end
  function t.setBackgroundColor() end
  function t.setCursorBlink() end
  function t.isColour() return true end
  t.isColor = t.isColour
  function t.current() return t end
  function t.native() return t end
  function t.redirect() return t end
  computer.screenText = function()
    local out = {}
    for i = 1, h do out[i] = screen[i] or "" end
    return table.concat(out, "\n")
  end
  return t
end

local function startTimer(c, seconds)
  c.timerId = c.timerId + 1
  c.timers[c.timerId] = clock + seconds * 1000
  return c.timerId
end

local function queue(c, ...)
  c.events[#c.events + 1] = table.pack(...)
end

-- Boot a computer. Passing the same `files` table again is a reboot: memory is lost, disk isn't.
function sim.computer(id, opts)
  opts = opts or {}
  local c = {
    id = id, files = opts.files or {}, events = {}, timers = {}, timerId = 0, threads = {},
    modems = opts.modems or { top = { open = {} } }, label = opts.label, width = opts.width,
  }
  sim.computers[id] = c

  local env = setmetatable({}, { __index = _G })
  c.env = env
  env._G = env
  env.os = setmetatable({
    getComputerID = function() return id end,
    getComputerLabel = function() return c.label end,
    epoch = function() return clock end,
    clock = function() return clock / 1000 end,
    queueEvent = function(...) queue(c, ...) ; local t = c.events[#c.events]; for i = 1, t.n do t[i] = copy(t[i]) end end,
    pullEventRaw = function(filter)
      if coroutine.running() then return coroutine.yield(filter) end
      return table.remove(c.events, 1) -- booting: crypto's yield just gets its own event back
    end,
    startTimer = function(s) return startTimer(c, s) end,
  }, { __index = os })
  env.os.pullEvent = env.os.pullEventRaw
  env.fs = newFs(c.files)
  env.textutils = { serialize = serialize, unserialize = unserialize }
  env.term = newTerm(c)
  env.window = { create = function() return env.term end }
  env.colors = setmetatable({}, { __index = function() return 1 end })
  env.keys = { up = 200, down = 208, home = 199, ["end"] = 207, enter = 28, numPadEnter = 156, backspace = 14,
    pageUp = 201, pageDown = 209 }
  env.peripheral = {
    getNames = function()
      local names = {}
      for name in pairs(c.modems) do names[#names + 1] = name end
      table.sort(names)
      return names
    end,
    getType = function(name) return c.modems[name] and "modem" or nil end,
    call = function(name, method, a, b, message)
      local modem = c.modems[name]
      if method == "open" then modem.open[a] = true
      elseif method == "close" then modem.open[a] = nil
      elseif method == "transmit" then sim.transmit(c, name, a, b, copy(message))
      end
    end,
  }
  env.read = function()
    local _, line = coroutine.yield("sim_line")
    return line
  end
  env.parallel = {
    waitForAll = function(...)
      local threads, filters = {}, {}
      for i, fn in ipairs({ ... }) do threads[i] = coroutine.create(fn) end
      local event = {}
      while true do
        for i, co in ipairs(threads) do
          if filters[i] == nil or filters[i] == event[1] or event[1] == "terminate" then
            local ok, filter = coroutine.resume(co, table.unpack(event))
            if not ok then error(filter, 0) end
            filters[i] = filter
          end
        end
        event = { coroutine.yield() }
      end
    end,
    waitForAny = function(...)
      local threads, filters = {}, {}
      for i, fn in ipairs({ ... }) do threads[i] = coroutine.create(fn) end
      local event = {}
      while true do
        for i, co in ipairs(threads) do
          if filters[i] == nil or filters[i] == event[1] or event[1] == "terminate" then
            local ok, filter = coroutine.resume(co, table.unpack(event))
            if not ok then error(filter, 0) end
            if coroutine.status(co) == "dead" then return i end
            filters[i] = filter
          end
        end
        event = { coroutine.yield() }
      end
    end,
  }

  local loaded = {}
  local function loadFrom(path, name)
    local fn = assert(loadfile(path))
    setfenv(fn, env)
    return fn(name)
  end
  env.require = function(name)
    if loaded[name] == nil then
      local own = c.appDir and (c.appDir .. name .. ".lua")
      local f = own and io.open(own)
      if f then f:close() end
      loaded[name] = loadFrom(f and own or (LIB .. name .. ".lua"), name)
    end
    return loaded[name]
  end

  c.net = env.require("net")
  env.require("trust").identity()
  sim.spawn(c, env.require("services").run)
  c.net.start()
  return c
end

-- Run fn as a thread on the computer, alongside its services. Its results land in thread.result.
function sim.spawn(c, fn, ...)
  local thread = { co = coroutine.create(fn), args = table.pack(...), started = false, computer = c }
  c.threads[#c.threads + 1] = thread
  return thread
end

function sim.transmit(from, side, channel, reply, message)
  local packet = { from = from.id, channel = channel, reply = reply, message = message }
  sim.wire[#sim.wire + 1] = copy(packet)
  if sim.onPacket and sim.onPacket(packet, from) == false then return end
  sim.deliver(packet)
end

function sim.deliver(packet, excludeId)
  for _, c in pairs(sim.computers) do
    if c.id ~= packet.from and c.id ~= excludeId and not c.off then
      for name, modem in pairs(c.modems) do
        if modem.open[packet.channel] then
          queue(c, "modem_message", name, packet.channel, packet.reply, copy(packet.message), 5)
        end
      end
    end
  end
end

local function resume(thread, ...)
  local ok, filter = coroutine.resume(thread.co, ...)
  if not ok then error(debug.traceback(thread.co, filter), 0) end
  thread.filter = filter
  if coroutine.status(thread.co) == "dead" then thread.done = true end
end

local function stepComputer(c)
  local busy = false
  for _, thread in ipairs(c.threads) do
    if not thread.started then
      thread.started, busy = true, true
      resume(thread, table.unpack(thread.args, 1, thread.args.n))
    end
  end
  local event = table.remove(c.events, 1)
  if not event then return busy end
  clock = clock + STEP
  for _, thread in ipairs(c.threads) do
    if not thread.done and (thread.filter == nil or thread.filter == event[1] or event[1] == "terminate") then
      resume(thread, table.unpack(event, 1, event.n))
    end
  end
  return true
end

-- Run until `done()` is true, or fail after `limit` virtual seconds.
function sim.run(done, limit)
  local stop = clock + (limit or 120) * 1000
  while not done() do
    if clock > stop then error("sim.run timed out", 2) end
    local busy = false
    for _, c in pairs(sim.computers) do
      if not c.off and stepComputer(c) then busy = true end
    end
    if not busy then
      local nextTimer
      for _, c in pairs(sim.computers) do
        if not c.off then
          for _, at in pairs(c.timers) do
            if not nextTimer or at < nextTimer then nextTimer = at end
          end
        end
      end
      clock = math.max(clock, nextTimer or (clock + 1000))
    end
    for _, c in pairs(sim.computers) do
      for id, at in pairs(c.timers) do
        if at <= clock then
          c.timers[id] = nil
          queue(c, "timer", id)
        end
      end
    end
  end
end

-- Run fn on the computer and return what it returned.
function sim.call(c, fn, limit)
  local result
  sim.spawn(c, function() result = table.pack(fn()) end)
  sim.run(function() return result ~= nil end, limit)
  return table.unpack(result, 1, result.n)
end

-- Turn a computer off: its memory goes, and `sim.computer(id, { files = old.files })` reboots it.
function sim.powerOff(c)
  c.off = true
  sim.computers[c.id] = nil
end

function sim.advance(seconds)
  local stop = clock + seconds * 1000
  sim.run(function() return clock >= stop end, seconds + 5)
end

function sim.setClock(t) clock = t end
function sim.now() return clock end

-- Collect the net_message events a computer sees.
function sim.inbox(c)
  local box = {}
  local env = c.env
  sim.spawn(c, function()
    while true do
      local _, msg = env.os.pullEventRaw("net_message")
      box[#box + 1] = msg
    end
  end)
  return box
end

return sim
