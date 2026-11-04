# zOS Image Library Specification

`require("image")` reads and checks zos.tar.gz system images, using `lib/tar.lua` and `lib/compression.lua`. [UPDATE.md](UPDATE.md) uses it for updates. What an image contains is described in [TGZ_FORMAT.md](../formats/TGZ_FORMAT.md), and that format is what decides what's valid.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Methods

| Method                     | Returns                                                      |
| -------------------------- | ------------------------------------------------------------ |
| `image.parse(data)`        | The files as (absolute path -> data), or nil and a reason    |
| `image.validPath(path)`    | Whether `path` can be a file in an image                     |
| `image.clash(files)`       | A path used as both a file and a folder, or nil              |
| `image.spaceNeeded(files)` | The bytes `files` take up on disk                            |

### image.parse(data)

Checks the bytes of an image. It rejects anything that isn't gzipped, a damaged archive, an entry that isn't a file or folder, a bad path, a path that appears twice or is used as both a file and a folder, or a `.lua` file that doesn't compile. The code is compiled but not run. Folder entries are skipped.

Nothing on the computer changes. The caller decides what to do with the files, and has to check that they make a complete system, as `update.download` does. `image.parse` accepts an image with no files.

### image.validPath(path)

Applies the [path rules](../formats/TGZ_FORMAT.md#paths): absolute, at most 128 bytes after the leading `/`, no segment made only of dots, and nothing inside `/rom` or a mounted disk.

### image.clash(files)

Takes a table with paths as keys. It works with absolute paths and with the relative paths of a .za image, and [APPS.md](APPS.md) uses it for those.

### image.spaceNeeded(files)

CC: Tweaked counts each file and folder as at least 500 bytes, so this is more than the total of the file sizes. It takes absolute or relative paths, and doesn't count the folder a set of relative paths will go in.

## Security

An image can write anywhere outside `/rom`, so applying one means trusting it completely. `parse` catches damage and mistakes, not deliberate changes. See [Security](../formats/TGZ_FORMAT.md#security) in the zos.tar.gz format.
