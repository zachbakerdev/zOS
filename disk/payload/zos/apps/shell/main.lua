-- Opens a nested CraftOS shell. `exit` (or Ctrl+T) returns to the desktop.
print("zOS " .. zos.version .. " shell - logged in as " .. zos.session.user)
print("Type 'exit' to return to the desktop. 'appman' manages apps.")
shell.run("shell")
