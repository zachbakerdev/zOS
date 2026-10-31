# zOS Util Library Specification

`require("util")` has small helpers for files, tables, downloads and waiting. It depends on no other library, so every other library can use it.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Files

| Method                         | Returns                                                             |
| ------------------------------ | ------------------------------------------------------------------- |
| `util.readFile(path)`          | The whole file, in binary mode, or nil and a reason                 |
| `util.writeFile(path, data)`   | True, or false and a reason. Makes the parent folders               |
| `util.writeChecked(path, data)` | `writeFile`, then reads the file back. False if it doesn't match   |
| `util.loadFile(path, env)`     | The compiled file as a function that runs in `env`, or nil and a reason |

CC: Tweaked can cut a write short on a full disk without reporting an error. Anything that has to survive SHOULD use `writeChecked`, which reports this as `"the disk is full"`.

`loadFile` reads in binary mode, unlike `loadfile`, and names the chunk after the path, so error messages show where they came from.

## Tables

| Method                        | Returns                                     |
| ----------------------------- | ------------------------------------------- |
| `util.readTable(path)`        | The table in a file, or nil                 |
| `util.writeTable(path, t)`    | True, or false and a reason                 |

`writeTable` writes `<path>.new`, checks it, deletes the old file and renames the new one into place, so a full disk can't lose the old contents. If the computer stops between the delete and the rename, `readTable` reads the `.new` file instead.

`readTable` returns nil for a missing file, a damaged file, and a file that doesn't hold a table.

Tables are stored with `textutils.serialize` in text mode, which can damage raw bytes, so raw values MUST be converted to hex first. `textutils.unserialize` can run code, so `readTable` MUST NOT be used on anything from outside the computer.

## Downloads

| Method                  | Returns                                 |
| ----------------------- | --------------------------------------- |
| `util.get(url, binary)` | The body of the URL, or nil and a reason |

It fails if the HTTP API is disabled. Set `binary` for anything that isn't plain text.

## Waiting

| Method               | Returns                       |
| -------------------- | ----------------------------- |
| `util.wait(seconds)` | Nothing, once the time is up  |

Unlike `sleep`, it can't be stopped with Ctrl+T. Other events that arrive meanwhile are discarded, which is also true of `sleep`.
