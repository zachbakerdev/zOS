-- zOS Terminal: the CraftOS shell. `exit` or Ctrl+T at the prompt returns to the desktop.

-- zOS sets os.pullEvent to os.pullEventRaw so Ctrl+T can't stop it. Programs in the shell
-- need the normal version, or Ctrl+T wouldn't stop them either. This is the one from bios.lua.
function os.pullEvent(filter)
    local event = table.pack(os.pullEventRaw(filter))
    if event[1] == "terminate" then error("Terminated", 0) end
    return table.unpack(event, 1, event.n)
end

-- Run from os.run rather than shell.run, so the shell doesn't get the multishell API. A tab
-- opened with `bg` or `fg` would outlive this app, leaving a logged-in shell on the login screen.
-- Its only print is the CraftOS version banner, and programs it runs get their own environment.
pcall(os.run, { shell = shell, print = function() end }, "rom/programs/shell.lua")

os.pullEvent = os.pullEventRaw
