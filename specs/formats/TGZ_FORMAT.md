# Specification for zos.tar.gz System Images

A zos.tar.gz file holds every file of one computer's system in a single file, so that the whole set can be moved by floppy or HTTP and then written back out in one step. It replaces the [.zi format](ZI_FORMAT.md), which releases still include for computers running older zOS.

It is an ordinary gzipped tar archive, so `tar tzf zos.tar.gz` lists it and `tar xzf` unpacks it on any other computer.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Format

The file is a single gzip member (RFC 1952) holding a POSIX ustar archive (POSIX.1-1988). Each regular file in the archive is a file of the system, and its name is the file's path on the target computer without the leading `/`.

```
$ tar tzvf zos.tar.gz
-rw-r--r-- 0/0      42 1970-01-01 00:00 .zos/boot.lua
-rw-r--r-- 0/0      26 1970-01-01 00:00 etc/motd
-rw-r--r-- 0/0      33 1970-01-01 00:00 startup.lua
```

Unpacked, that image produces `/.zos/boot.lua`, `/etc/motd` and `/startup.lua`, and the folders `/.zos` and `/etc`.

### Entries

- Each entry MUST be a regular file (type `0`, or NUL in older archives) or a folder (type `5`).
- An archive MUST NOT contain links, devices, FIFOs, or the extended headers of pax (`x`, `g`) or GNU tar (`L`, `K`). Every path fits in a plain ustar header, so none of them are needed. Readers MAY reject an archive that has them, and `install.lua` does.
- A name MAY start with `./`, which readers remove, so that `tar czf zos.tar.gz -C src .` makes a valid image. Readers ignore the `./` entry that command adds.
- Folder entries are ignored. A folder exists on the target only because a file inside it does, so an image can't contain an empty folder.
- No path MAY appear twice.
- A header's checksum MUST be correct, and the archive MUST end with a block of zeros.

File modes, owners and timestamps are ignored, and so are labels.

### Paths

The path of an entry is `/` followed by its name, with any leading `./` removed. Paths follow the rules of the [.zi format](ZI_FORMAT.md#paths):

- After the leading `/`, a path MUST be at most 128 bytes, and each segment MUST match `^[%w_%.%-]+$`. Hidden files and folders such as `/.zos` are allowed.
- No segment may be made up only of dots, which rules out `.`, `..` and `...`.
- A name MUST NOT start with `/`, because the path would then have an empty segment.
- A path MUST NOT be inside `/rom` or inside a mounted disk such as `/disk`.
- A path MUST NOT also be used as a folder by another path.
- Bad paths MUST be rejected, not cleaned up with `fs.combine`.

Paths are case-sensitive in the archive, but the target file system might not be. Two paths in an image SHOULD NOT differ only by case.

### File contents

Each file is stored as its exact bytes, with no conversion of line endings. Binary data is allowed.

## Writing an image

Writers SHOULD write the same bytes for the same files, as `./package` does:

- entries sorted by path, with no folder entries;
- mode `0644`, owner and group `0` with empty names, and a modification time of `0`;
- the gzip header with no file name, and a modification time of `0`.

The file is binary, so it MUST be written in binary mode (`"wb"`) and can't go through Pastebin.

## Reading an image

A reader MUST open the file in binary mode (`"rb"`). It MUST check the whole image before it changes anything on the computer, and it MUST reject the image if:

- it isn't a gzip file, or its CRC-32 or length doesn't match the data;
- the archive is cut off, a header checksum is wrong, or an entry isn't a file or folder;
- any path breaks the rules in [Paths](#paths), or appears twice;
- the files don't fit in the free space. CC: Tweaked counts each file and folder as at least 500 bytes.

It SHOULD also check that each `.lua` file compiles with `load`, because a broken system file can leave the computer unable to boot.

zOS reads images with [`image.parse`](../libs/IMAGE.md), which uses `lib/tar.lua` and `lib/compression.lua`. The installer runs before those exist, so `install.lua` has its own small reader. It reads only what this section allows, and doesn't handle more than one gzip member.

## Applying an image

An image describes the files it contains, not the whole file system, in the same way as a [.zi image](ZI_FORMAT.md#applying-an-image):

- A file in the image replaces any file already at that path. Missing parent folders are created.
- A file that isn't in the image is left alone.
- If a folder exists where the image has a file, or a file exists where the image needs a folder, the reader MUST stop before writing anything.

Each file SHOULD be read back after writing to catch a full disk, and the caller SHOULD write to a staging folder first where it can, as `lib/update.lua` does.

## Security

An image has no signature, and its paths can replace `/startup.lua` and anything in `/.zos`. Applying an image from a source is the same as running code from that source as the system, so the source has to be trusted. Verify any size and SHA-256 published with the image before reading it, as `update.download` does.

Unlike a .zi file, reading an image runs no code from it. A hostile file can still use up memory, since a small gzip file can unpack to a large one.

## Limitations

- **No signature.** The gzip CRC-32 catches damage, not deliberate changes. Sizes and hashes have to be carried outside the file, as `zos-update.manifest` does.
- **Size.** The image and the files it holds are both in memory while it's read. Compressed, a whole system fits on a default 125 KB floppy.
