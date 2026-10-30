local util = {}

function util.readTable(path)
    if not fs.exists(path) then
        return nil
    end

    local f = fs.open(path, "r")
    local data = f.readAll()
    f.close()

    return textutils.unserialize(data)
end

function util.writeTable(path, value)
    fs.makeDir(fs.getDir(path))
    local f = fs.open(path, "w")
    f.write(textutils.serialize(value))
    f.close()
end

return util