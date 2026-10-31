# Specification for the .za File Format

The .za file format is used as an app image for copying all the files of one app onto a computer.

It follows the conventions of the [.zi format](ZI_FORMAT.md). The main difference is that a .zi file can write anywhere on a computer, while a .za file can only write inside its own app folder. To guarantee that, absolute paths and reverse path traversal are banned.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Format

A .za file is simply a serialized lua object where the key is the path of a file relative to the app's folder and the value is the entire contents of that file. One extra key, `za:metadata`, describes the image itself.

```lua
{
  ["za:metadata"] = { version = 1, id = "notes" },
  ["app.manifest"] = "{ name = \"Notes\", version = \"1.0\" }\010",
  ["lib/store.lua"] = "return {}\010",
  ["main.lua"] = "print(\"Hello\")\010",
}
```

Installed, that image produces `/.zos/apps/notes/app.manifest`, `/.zos/apps/notes/lib/store.lua` and `/.zos/apps/notes/main.lua`.

### Syntax

- The file MUST be a single Lua 5.2 table constructor that `textutils.unserialize` can read.
- The table MUST contain the `za:metadata` key described in [Metadata](#metadata).
- Every other key MUST be a string path, and its value MUST be a string.
- Apart from the metadata, the table MUST NOT contain nested tables, numbers, booleans or function calls.
- Comments MUST NOT be used. Whitespace between entries has no meaning.

### Metadata

The `za:metadata` key MUST be present, and its value MUST be a table with these fields:

| Field     | Type   | Value                                                                            |
| --------- | ------ | -------------------------------------------------------------------------------- |
| `version` | number | The version of this format. Currently `1`.                                       |
| `id`      | string | The app's id, which MUST pass `apps.validId`: 1-32 lowercase letters, digits, `-` or `_`. |

The key isn't a path, because `:` isn't allowed in one, so it can't clash with a file. It is never written to the target computer.

The `id` names the folder the app is installed to, so it needs the same care as a path. `apps.validId` doesn't allow `/` or `.`, which keeps the folder directly inside `/.zos/apps`.

### Paths

Each key is the path of a file relative to the app's folder.

- A path MUST pass `apps.validPath`: at most 128 bytes, and each `/`-separated segment matches `^[%w_%-][%w_%.%-]*$`.
- A path MUST NOT be absolute. It can't start with `/`, and drive-style prefixes such as `C:/` and backslashes are not valid either.
- A path MUST NOT contain reverse path traversal. No segment may be `..`, even where the path would end up back inside the app's folder, as `lib/../main.lua` would.
- A path MUST NOT contain a `.` segment, an empty segment (`//`) or a trailing `/`.
- A path MUST NOT also be used as a folder by another path. `a` and `a/b` can't appear in the same image.

| Path              | Valid | Reason                     |
| ----------------- | ----- | -------------------------- |
| `main.lua`        | Yes   |                            |
| `lib/store.lua`   | Yes   |                            |
| `/main.lua`       | No    | Absolute path              |
| `/etc/passwd`     | No    | Absolute path              |
| `../other/x.lua`  | No    | Reverse path traversal     |
| `lib/../main.lua` | No    | Reverse path traversal     |
| `./main.lua`      | No    | `.` segment                |
| `lib\main.lua`    | No    | Backslash                  |
| `.hidden`         | No    | Hidden file                |

Bad paths MUST be rejected, not cleaned up. A reader MUST NOT pass a path through `fs.combine` or strip a leading `/` to make it valid, because the image is then no longer what its author wrote, and the check must happen on the path exactly as it appears in the file.

Two paths in an image SHOULD NOT differ only by case, because the target file system might not be case-sensitive.

### Required files

An image MUST contain:

- `main.lua`, which runs when the app is opened;
- `app.manifest`, which MUST be a valid manifest as described in `apps/README.md`.

It MAY contain `service.lua`, which starts at boot, and any other files the app needs.

### File contents

Each value is the exact bytes of the file, with no conversion of line endings and no compression. Binary data is allowed, and Lua strings can hold any byte.

### Folders

Folders are not stored. A folder exists on the target only because a file inside it does, so an image can't contain an empty folder. File modes, labels and timestamps are not stored either.

## Writing an image

Writers SHOULD write:

- `za:metadata` first, then the entries sorted by path, one per line, so that the same input always gives the same bytes;
- strings in printable ASCII only, escaping `"` and `\`, and writing every other byte as a three-digit decimal escape (`\010`). `lua_string` in `tools/make_disk.py` does this.

A writer MUST refuse to build an image containing a path that breaks the rules in [Paths](#paths).

A .za file MUST be written in binary mode (`"wb"`).

## Reading an image

A reader MUST open the file in binary mode (`"rb"`), which rules out `util.readTable`. It MUST check the whole image before it changes anything on the computer, and it MUST reject the image if:

- the text doesn't unserialize to a table;
- `za:metadata` is missing or isn't a table, its `version` isn't one the reader supports, or its `id` isn't valid;
- any other key or value isn't a string;
- any path breaks the rules in [Paths](#paths);
- `main.lua` or `app.manifest` is missing, or the manifest isn't valid;
- `main.lua` or `service.lua` doesn't compile with `load`;
- the manifest's `minZos` is newer than the running zOS;
- the files don't fit in the free space. CC: Tweaked counts each file and folder as at least 500 bytes.

```lua
local FORMAT_VERSION = 1
local METADATA = "za:metadata"

-- Returns the app's id and its files as (path -> data), without the metadata.
local function parseImage(text)
    local image = textutils.unserialize(text)
    if type(image) ~= "table" or type(image[METADATA]) ~= "table" then
        return nil, "This isn't a .za file."
    end
    local metadata = image[METADATA]
    if metadata.version ~= FORMAT_VERSION then
        return nil, "This app needs a newer version of zOS."
    end
    if not apps.validId(metadata.id) then return nil, "The app has an invalid id." end
    local files = {}
    for path, data in pairs(image) do
        if path ~= METADATA then
            -- validPath rejects absolute paths, "." and "..".
            if not apps.validPath(path) or type(data) ~= "string" then
                return nil, "The app contains a bad file name: " .. tostring(path)
            end
            files[path] = data
        end
    end
    return metadata.id, files
end
```

This example covers only the metadata, type and name checks. A complete reader also makes the other checks above.

## Installing an image

Unlike a .zi file, a .za file describes the whole of its app:

- The image is installed to `/.zos/apps/<id>/`.
- Installing replaces the app's folder, so files from an older version that aren't in the image are removed. Apps have to keep their data somewhere else, as described in [APP_STANDARDS.md](../APP_STANDARDS.md): `/etc/<id>/` or `/home/<user>/.config/<id>/`.
- The files SHOULD be written to a temporary folder first, as `apps.install` does, so that a failed install leaves the old version in place.
- Each file SHOULD be read back after writing to catch a full disk.
- Built-in apps in `apps.PROTECTED` can be upgraded but not removed.

## Security

The path rules control where an image's files are written. They don't control what those files do once they run. App code runs with the full zOS environment, including `fs`, and `service.lua` starts at every boot, so a hostile app can still read or change anything on the computer. Only admins should be able to install apps, and an image has no signature, so the source has to be trusted.

`textutils.unserialize` runs the file as Lua in an empty environment. It can't reach any APIs, but a hostile file can still loop forever or use up memory, so the file has to be trusted before it's parsed, not after. Verify any size and SHA-256 published with the image first, as `update.downloadApp` does.

## Limitations

- **No integrity check.** A damaged image that still parses isn't detected. Sizes and hashes have to be carried outside the file, as `zos-apps.manifest` does for release images.
- **Size.** The image is loaded into memory as a whole, and it's bigger than the files it holds because of the escapes.
- **No shared files.** An app can't put a file outside its folder at install time, so anything it needs elsewhere has to be created when it runs.
