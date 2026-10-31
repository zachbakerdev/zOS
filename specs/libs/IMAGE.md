# zOS Image Library Specification

`require("image")` reads and checks .zi system images. [UPDATE.md](UPDATE.md) uses it for updates. What an image contains is described in [ZI_FORMAT.md](../formats/ZI_FORMAT.md), and that format is what decides what's valid.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Constants

| Name                   | Value                                 |
| ---------------------- | ------------------------------------- |
| `image.FORMAT_VERSION` | 1, the version of the format it reads |
| `image.METADATA`       | `"zi:metadata"`, the metadata key     |

## Methods

| Method                     | Returns                                                      |
| -------------------------- | ------------------------------------------------------------ |
| `image.parse(text)`        | The files as (absolute path -> data), or nil and a reason    |
| `image.validPath(path)`    | Whether `path` can be a file in an image                     |
| `image.clash(files)`       | A path used as both a file and a folder, or nil              |
| `image.spaceNeeded(files)` | The bytes `files` take up on disk                            |

### image.parse(text)

Checks the text of an image. It rejects an image with the wrong format version, an entry that isn't two strings, a bad path, a path used as both a file and a folder, or a `.lua` file that doesn't compile. The code is compiled but not run.

Nothing on the computer changes. The caller decides what to do with the files, and has to check that they make a complete system, as `update.download` does. `image.parse` accepts an image with no files.

### image.validPath(path)

Applies the [path rules](../formats/ZI_FORMAT.md#paths): absolute, at most 128 bytes after the leading `/`, no segment made only of dots, and nothing inside `/rom` or a mounted disk.

### image.clash(files)

Takes a table with paths as keys. It works with absolute paths and with the relative paths of a .za image, and [APPS.md](APPS.md) uses it for those.

### image.spaceNeeded(files)

CC: Tweaked counts each file and folder as at least 500 bytes, so this is more than the total of the file sizes. It takes absolute or relative paths, and doesn't count the folder a set of relative paths will go in.

## Security

An image can write anywhere outside `/rom`, so applying one means trusting it completely. `parse` catches damage and mistakes, not deliberate changes, and reading an image uses `textutils.unserialize`, which can run code. See [Security](../formats/ZI_FORMAT.md#security) in the .zi format.
