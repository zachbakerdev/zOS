-- Small helpers for files and tables.

local util = {}

-- The whole of a file in binary mode, or nil and a reason.
function util.readFile(path)
    local f, err = fs.open(path, "rb")
    if not f then return nil, err or ("Can't open " .. path) end
    local text = f.readAll()
    f.close()
    return text or ""
end

function util.writeFile(path, data)
    local dir = fs.getDir(path)
    if dir ~= "" and dir ~= ".." then fs.makeDir(dir) end
    local f, err = fs.open(path, "wb")
    if not f then return false, err or ("Can't write " .. path) end
    f.write(data)
    f.close()
    return true
end

-- writeFile, then read it back, because a full disk can cut a write short without saying so.
function util.writeChecked(path, data)
    local ok, err = util.writeFile(path, data)
    if ok and util.readFile(path) ~= data then return false, "the disk is full" end
    return ok, err
end

-- A table saved with writeTable, or nil. Text mode can damage raw bytes, so keep those as hex.
-- A leftover ".new" file means a save stopped just before its last step.
function util.readTable(path)
    if not fs.exists(path) and fs.exists(path .. ".new") then path = path .. ".new" end
    if not fs.exists(path) then return nil end
    local text = util.readFile(path)
    local t = text and textutils.unserialize(text)
    return type(t) == "table" and t or nil
end

-- Writes to a new file first, so that a full disk can't lose the old contents.
function util.writeTable(path, t)
    local temp = path .. ".new"
    local text = textutils.serialize(t)
    local ok, err = util.writeChecked(temp, text)
    if not ok then
        fs.delete(temp)
        return false, err
    end
    if fs.exists(path) then fs.delete(path) end
    fs.move(temp, path)
    return true
end

-- Compile a file to run in env.
function util.loadFile(path, env)
    local text, err = util.readFile(path)
    if not text then return nil, err end
    return load(text, "@" .. path, "t", env)
end

-- Fetch a URL. Returns its contents, or nil and a reason.
function util.get(url, binary)
    if not http then return nil, "The HTTP API is disabled." end
    local response, err = http.get(url, nil, binary)
    if not response then return nil, tostring(err) end
    local text = response.readAll()
    response.close()
    return text
end

-- Wait for this many seconds. Unlike sleep, it ignores Ctrl+T.
function util.wait(seconds)
    local timer = os.startTimer(seconds)
    repeat
        local _, id = os.pullEventRaw("timer")
    until id == timer
end

return util
