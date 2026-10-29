-- zOS Notes: personal notes stored in /home/<user>/notes and edited with `edit`.

local ui = zos.ui
local TITLE = "Notes"
local dir = fs.combine("home", zos.session.user .. "/notes")
fs.makeDir(dir)

local function modified(path)
  local ok, attr = pcall(fs.attributes, path)
  return ok and attr and attr.modified or 0
end

local function open(path)
  shell.run("edit", '"/' .. path .. '"') -- quoted: names may contain spaces
end

local function askName(title, default)
  ui.screen(TITLE .. " - " .. title)
  local name = ui.input("Note name", nil, default)
  if name == "" then return nil end
  if not name:match("^[%w _%-]+$") then
    ui.message(TITLE, "Use letters, digits, spaces, - and _ only.", ui.theme.bad)
    return nil
  end
  return fs.combine(dir, name .. ".txt")
end

local function manage(note)
  local items = {
    { label = "Open", hint = "Edit this note" },
    { label = "Rename...", hint = "Give the note a new name" },
    { label = "Delete", hint = "Remove this note" },
    { label = "Back", fg = ui.theme.dim },
  }
  local choice = ui.menu({ title = TITLE .. " - " .. note.name, items = items, back = true })
  if choice == 1 then
    open(note.path)
  elseif choice == 2 then
    local path = askName("Rename", note.name)
    if path and fs.exists(path) then
      ui.message(TITLE, "A note with that name already exists.", ui.theme.bad)
    elseif path then
      fs.move(note.path, path)
    end
  elseif choice == 3 then
    ui.screen(TITLE)
    if ui.confirm("Delete the note '" .. note.name .. "'?") then fs.delete(note.path) end
  end
end

local selected = 1
while true do
  local notes = {}
  for _, file in ipairs(fs.list(dir)) do
    local path = fs.combine(dir, file)
    if not fs.isDir(path) then
      notes[#notes + 1] = { name = (file:gsub("%.txt$", "")), path = path, modified = modified(path) }
    end
  end
  table.sort(notes, function(a, b) return a.modified > b.modified end)

  local items = { { label = "[New note]", hint = "Create a note", fg = ui.theme.accent } }
  for _, note in ipairs(notes) do
    local when = note.modified > 0 and ("Edited " .. os.date("%Y-%m-%d %H:%M", math.floor(note.modified / 1000))) or ""
    items[#items + 1] = { label = note.name, hint = when }
  end
  items[#items + 1] = { label = "Back", fg = ui.theme.dim }

  selected = ui.menu({ title = TITLE, status = function() return #notes .. " notes" end,
    items = items, selected = selected, back = true })
  if not selected or selected == #items then return
  elseif selected == 1 then
    local path = askName("New note")
    if path then open(path) end
  else
    manage(notes[selected - 1])
  end
end
