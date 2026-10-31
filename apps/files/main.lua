-- zOS Files: browse folders; create, edit, copy, move and delete files and folders.

local session = ...
local ui = require("ui")

local TITLE = "Files"

local home = fs.combine("home", session.user)
local cwd = fs.isDir(home) and home or ""

-- The editor's Run menu opens a multishell tab, which would outlive this app and leave a
-- logged-in program on the login screen. It only offers Run when shell.openTab exists.
local editorShell = {}
for name, fn in pairs(shell) do editorShell[name] = fn end
editorShell.openTab, editorShell.switchTab = nil, nil

local function show(path) return "/" .. path end
local function status() return show(cwd) end

-- Deleting or moving these can stop zOS from booting, or lose its users and keys.
local function isSystem(path)
    return path == "startup.lua" or path == ".settings" or path == "etc"
        or path == ".zos" or path:match("^%.zos/") ~= nil
        or path == "etc/zos" or path:match("^etc/zos/") ~= nil
end

-- Turn user input into a path, relative to the current folder unless it starts with "/".
local function resolve(input)
    if input:sub(1, 1) == "/" then return fs.combine(input, "") end
    return fs.combine(cwd, input)
end

local function ask(title, label, default)
    ui.screen(TITLE .. " - " .. title, status())
    ui.text("Paths are relative to " .. show(cwd) .. " unless they start with /.", ui.theme.dim)
    ui.text("")
    return ui.input(label, nil, default)
end

local function report(ok, err, success)
    if ok then
        ui.message(TITLE, success, ui.theme.good)
    else
        ui.message(TITLE, (tostring(err):gsub("^.-: ", "")), ui.theme.bad)
    end
end

local function edit(path)
    os.run({ shell = editorShell, require = require }, "rom/programs/edit.lua", show(path))
end

local function transfer(path, verb, fn)
    local input = ask(verb, verb .. " " .. fs.getName(path) .. " to", show(path))
    if input == "" then return end
    local dest = resolve(input)
    if fs.isDir(dest) then dest = fs.combine(dest, fs.getName(path)) end
    if dest == path then return end
    if fs.exists(dest) then return report(false, show(dest) .. " already exists.") end
    if verb == "Move" and isSystem(path) then
        ui.screen(TITLE)
        if not ui.confirm(show(path) .. " is part of zOS. Moving it may stop the computer booting. Continue?") then
            return
        end
    end
    local ok, err = pcall(fn, path, dest)
    report(ok, err, (verb == "Copy" and "Copied to " or "Moved to ") .. show(dest) .. ".")
end

local function delete(path)
    ui.screen(TITLE)
    if isSystem(path) then
        ui.text(show(path) .. " is part of zOS. Deleting it may stop the computer booting!", ui.theme.bad)
        ui.text("")
    end
    local what = fs.isDir(path) and "the folder " .. show(path) .. " and everything in it" or show(path)
    if ui.confirm("Delete " .. what .. "?") then
        local ok, err = pcall(fs.delete, path)
        report(ok, err, "Deleted " .. show(path) .. ".")
    end
end

-- The actions for a file or folder.
local function actions(path)
    local items, fns = {}, {}
    local function add(label, hint, fn)
        items[#items + 1] = { label = label, hint = hint }
        fns[#items] = fn
    end
    local readOnly = fs.isReadOnly(path)

    if not fs.isDir(path) then
        add(readOnly and "View" or "Edit", "Open in the text editor", function() edit(path) end)
    end
    add("Copy to...", "Copy to another location", function() transfer(path, "Copy", fs.copy) end)
    if not readOnly then
        add("Rename / move...", "Change the name or location", function() transfer(path, "Move", fs.move) end)
        add("Delete", "Remove permanently", function() delete(path) end)
    end
    items[#items + 1] = { label = "Back", fg = ui.theme.dim }

    local title = fs.isDir(path) and show(path) or fs.getName(path)
    local choice = ui.menu({ title = TITLE .. " - " .. title, items = items, back = true })
    if choice and fns[choice] then fns[choice]() end
end

local function newFolder()
    local name = ask("New folder", "Folder name")
    if name == "" then return end
    local path = resolve(name)
    if fs.exists(path) then return report(false, show(path) .. " already exists.") end
    local ok, err = pcall(fs.makeDir, path)
    report(ok, err, "Created " .. show(path) .. ".")
end

local function newFile()
    local name = ask("New file", "File name")
    if name == "" then return end
    local path = resolve(name)
    if fs.exists(path) then return report(false, show(path) .. " already exists.") end
    local file, err = fs.open(path, "w")
    if not file then return report(false, err) end
    file.close()
    edit(path)
end

local selected = 1
while true do
    -- The folder can disappear: it was moved or deleted here, or its floppy was taken out.
    while cwd ~= "" and not fs.isDir(cwd) do cwd = fs.getDir(cwd) end

    local dirs, files = {}, {}
    for _, name in ipairs(fs.list(cwd)) do
        local path = fs.combine(cwd, name)
        if fs.isDir(path) then dirs[#dirs + 1] = path else files[#files + 1] = path end
    end

    local items, targets = {}, {}
    local function add(item, target)
        items[#items + 1] = item
        targets[#items] = target
    end
    if cwd ~= "" then add({ label = "..", hint = "Up one folder" }, "up") end
    for _, path in ipairs(dirs) do
        add({ label = fs.getName(path) .. "/", hint = fs.isReadOnly(path) and "Folder (read-only)" or "Folder" }, { path = path })
    end
    for _, path in ipairs(files) do
        add({ label = fs.getName(path), hint = fs.getSize(path) .. " bytes" .. (fs.isReadOnly(path) and ", read-only" or "") }, { path = path })
    end
    if not fs.isReadOnly(cwd) then
        add({ label = "[New file]", hint = "Create a file here", fg = ui.theme.accent }, "newfile")
        add({ label = "[New folder]", hint = "Create a folder here", fg = ui.theme.accent }, "newdir")
    end
    if cwd ~= "" then add({ label = "[This folder...]", hint = "Copy, move or delete this folder", fg = ui.theme.accent }, "self") end
    add({ label = "Back", fg = ui.theme.dim }, "quit")

    local choice = ui.menu({ title = TITLE, status = status, items = items, selected = selected, back = true })
    local target = choice and targets[choice] or (cwd ~= "" and "up" or "quit")
    if target == "quit" then
        return
    elseif target == "up" then
        cwd, selected = fs.getDir(cwd), 1
    elseif target == "newfile" then
        newFile()
    elseif target == "newdir" then
        newFolder()
    elseif target == "self" then
        actions(cwd)
    elseif fs.isDir(target.path) then
        cwd, selected = target.path, 1
    else
        selected = choice
        actions(target.path)
    end
end
