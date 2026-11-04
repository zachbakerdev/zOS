-- gunzip: decompress files from the Terminal. The same as gzip -d; see specs/ARCHIVES.md.

local gzip = fs.combine(fs.getDir(shell.getRunningProgram()), "gzip.lua")
local fn, err = loadfile(gzip, nil, _ENV)
if not fn then error(err, 0) end
return fn("-d", ...)
