-- zOS About: basic system information.

local ui = zos.ui

local function kb(bytes) return string.format("%.1f KB", bytes / 1024) end

local kind = pocket and "Pocket computer" or turtle and "Turtle" or "Computer"
if term.isColour() then kind = "Advanced " .. kind:lower() end

ui.screen("About zOS")
ui.text("zOS " .. zos.version, ui.theme.accent)
ui.text("A small operating system for ComputerCraft.", ui.theme.dim)
ui.text("")
ui.text("Computer:   #" .. os.getComputerID() .. " (" .. (os.getComputerLabel() or "no label") .. ")")
ui.text("Type:       " .. kind)
ui.text("Runtime:    " .. (os.version and os.version() or "unknown") .. ", " .. _VERSION)
ui.text("User:       " .. zos.session.user .. (zos.session.admin and " (admin)" or ""))
ui.text("Uptime:     " .. math.floor(os.clock()) .. "s")
ui.text("Free space: " .. kb(fs.getFreeSpace("/")))
ui.text("Apps:       " .. #zos.apps.list() .. " installed")
ui.text("Secure boot: " .. (settings.get("shell.allow_disk_startup") and "OFF (disks can boot)" or "on"))
ui.text("")
ui.waitEnter()
