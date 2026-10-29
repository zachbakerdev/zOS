-- Runs when a computer *without* zOS boots with this disk inserted.
-- (CraftOS boots from disks by default; zOS turns that off once installed.)
shell.run("/" .. fs.combine(fs.getDir(shell.getRunningProgram()), "install.lua"))
