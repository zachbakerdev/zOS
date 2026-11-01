# Specification for the .zi File Format

The .zi file format is used as a disk image for copying all files over for an operating system.

A .zi file holds every file of one computer's system in a single text file, so that the whole set can be moved by floppy, Pastebin or HTTP and then written back out in one step.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Format

A .zi file is simply a serialized lua object where the key is the absolute path of a file and the value is the entire contents of that file. One extra key, `zi:metadata`, describes the image itself.

```lua
{
  ["zi:metadata"] = { version = 1 },
  ["/startup.lua"] = "shell.run(\"/.zos/boot.lua\")\010",
  ["/.zos/boot.lua"] = "print(\"Hello\")\010",
  ["/etc/motd"] = "Welcome\010",
}
```

Unpacked, that image produces three files, and the folders `/.zos` and `/etc`.

### Syntax

- The file MUST be a single Lua 5.2 table constructor that `textutils.unserialize` can read.
- The table MUST contain the `zi:metadata` key described in [Metadata](#metadata).
- Every other key MUST be a string path, and its value MUST be a string.
- Apart from the metadata, the table MUST NOT contain nested tables, numbers, booleans or function calls.
- Comments MUST NOT be used. Whitespace between entries has no meaning.
- A table holding only `zi:metadata` is a valid image with no files.

### Metadata

The `zi:metadata` key MUST be present, and its value MUST be a table with this field:

| Field     | Type   | Value                                      |
| --------- | ------ | ------------------------------------------ |
| `version` | number | The version of this format. Currently `1`. |

The key isn't a path, because it doesn't start with `/`, so it can't clash with a file. It is never written to the target computer.

### Paths

Each key is the path the file is written to on the target computer.

- A path MUST start with `/`.
- A path MUST NOT end with `/`, and MUST NOT contain an empty segment (`//`).
- After the leading `/`, a path MUST be at most 128 bytes, and each segment MUST match `^[%w_%.%-]+$`. Hidden files and folders such as `/.zos` and `/home/zach/.config` are allowed.
- A path MUST NOT contain reverse path traversal. No segment may be made up only of dots, which rules out `.`, `..` and `...`, even where the path would stay inside the root. CC: Tweaked treats longer runs of dots specially, so they aren't plain names either.
- Bad paths MUST be rejected, not cleaned up with `fs.combine`.
- A path MUST NOT be inside `/rom`, which is read-only, or inside a mounted disk such as `/disk`.
- A path MUST NOT also be used as a folder by another path. `/a` and `/a/b` can't appear in the same image.

Paths are case-sensitive in the file, but the target file system might not be. Two paths in an image SHOULD NOT differ only by case.

### File contents

Each value is the exact bytes of the file, with no conversion of line endings and no compression. Binary data is allowed, and Lua strings can hold any byte.

### Folders

Folders are not stored. A folder exists on the target only because a file inside it does, so an image can't contain an empty folder.

File modes, labels and timestamps are not stored either.

## Writing an image

Writers SHOULD write:

- `zi:metadata` first, then the entries sorted by path, one per line, so that the same input always gives the same bytes;
- strings in printable ASCII only, escaping `"` and `\`, and writing every other byte as a three-digit decimal escape (`\010`). `lua_string` in `tools/make_apps.py` does this. Three digits are required so a following digit isn't read as part of the escape.

Printable ASCII lets a .zi file survive Pastebin's line-ending conversion unchanged. `textutils.serialize` also produces a valid image, but it doesn't sort its keys and it leaves bytes above 127 unescaped.

A .zi file MUST be written in binary mode (`"wb"`).

## Reading an image

A reader MUST open the file in binary mode (`"rb"`), which rules out `util.readTable`. It MUST check the whole image before it changes anything on the computer, and it MUST reject the image if:

- the text doesn't unserialize to a table;
- `zi:metadata` is missing or isn't a table, or its `version` isn't one the reader supports;
- any other key or value isn't a string;
- any path breaks the rules in [Paths](#paths);
- the files don't fit in the free space. CC: Tweaked counts each file and folder as at least 500 bytes.

It SHOULD also check that each `.lua` file compiles with `load`, as `checkBundle` in `lib/update.lua` does, because a broken system file can leave the computer unable to boot.

```lua
local FORMAT_VERSION = 1
local METADATA = "zi:metadata"

-- An absolute path made of plain names, which may be hidden: no ".", no "..".
local function validPath(path)
    if #path > 129 or not path:match("^/.") then return false end
    for part in (path:sub(2) .. "/"):gmatch("(.-)/") do
        if not part:match("^[%w_%.%-]+$") or part:match("^%.+$") then return false end
    end
    return true
end

-- Returns the files as (path -> data), without the metadata.
local function parseImage(text)
    local image = textutils.unserialize(text)
    if type(image) ~= "table" or type(image[METADATA]) ~= "table" then
        return nil, "This isn't a .zi file."
    end
    if image[METADATA].version ~= FORMAT_VERSION then
        return nil, "This image needs a newer version of zOS."
    end
    local files = {}
    for path, data in pairs(image) do
        if path ~= METADATA then
            if type(path) ~= "string" or type(data) ~= "string" then
                return nil, "The image contains a bad entry."
            end
            if not validPath(path) then
                return nil, "The image contains a bad file name: " .. path
            end
            files[path] = data
        end
    end
    return files
end
```

This example covers only the metadata, type and name checks. A complete reader also makes the other checks above.

## Applying an image

An image describes the files it contains, not the whole file system:

- A file in the image replaces any file already at that path. Missing parent folders are created.
- A file that isn't in the image is left alone. A caller that wants a clean system has to erase the old files first.
- If a folder exists where the image has a file, or a file exists where the image needs a folder, the reader MUST stop before writing anything.

Each file SHOULD be read back after writing to catch a full disk, as `install.lua` does.

Applying an image can't be undone and isn't atomic. A computer that shuts down partway through may be left with a mix of old and new files, so the caller SHOULD write to a staging folder first where it can, as `lib/update.lua` does. Writing `/startup.lua` last reduces the time in which the computer can't boot.

## Security

An image has no signature, and because its paths are absolute it can replace `/startup.lua` and anything in `/.zos`. Applying an image from a source is the same as running code from that source as the system, so only admins should be able to do it, and the source has to be trusted.

`textutils.unserialize` runs the file as Lua in an empty environment. It can't reach any APIs, but a hostile file can still loop forever or use up memory, so the file has to be trusted before it's parsed, not after. Verify any size and SHA-256 published with the image first, as `update.download` does.

## Limitations

- **No integrity check.** A damaged image that still parses isn't detected. Sizes and hashes have to be carried outside the file, as `zos-update.manifest` does for bundles.
- **Size.** The image is loaded into memory as a whole, and it's bigger than the files it holds because of the escapes. It won't fit on a default 125 KB floppy unless the files are small, and free Pastebin accounts are limited to 512 KB.
