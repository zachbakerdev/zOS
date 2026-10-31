-- zOS Terminal: the CraftOS shell. `exit` returns to the desktop.

local session = ...

-- Run from os.run rather than shell.run, so the shell doesn't get the multishell API. A tab
-- opened with `bg` or `fg` would outlive this app, leaving a logged-in shell on the login screen.
-- Its only print is the CraftOS version banner, and programs it runs get their own environment.
--
-- appman needs the shared libraries, which a shell program can't reach. _G.zos carries them for
-- as long as this is open. It must never hold the session, or every service could read secretKey.
_G.zos = { require = require, user = session.user, admin = session.admin }
pcall(os.run, { shell = shell, print = function() end }, "rom/programs/shell.lua")
_G.zos = nil
