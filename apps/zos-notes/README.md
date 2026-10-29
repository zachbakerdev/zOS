# zOS Notes

Personal notes for [zOS](../../README.md). Each user's notes are plain text files in
`/home/<user>/notes/`, edited with the CraftOS `edit` program.

## Installing

Copy the `notes/` folder onto a floppy disk, put it in a drive next to the zOS computer, and
install it with the **App Manager** app or from the Shell:

```
appman install disk/notes
```

Since Notes is a single file, you can also upload `notes/main.lua` to Pastebin and run
`appman get <code> notes`.

## Using Notes

- **[New note]** asks for a name (letters, digits, spaces, `-` and `_`) and opens the editor.
- Selecting a note lets you open, rename or delete it. Notes are listed newest first.
