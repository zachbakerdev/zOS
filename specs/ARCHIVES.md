# zOS tar and gzip Specification

`tar`, `gzip` and `gunzip` are shell programs in `/.zos/bin` for packing files into archives and compressing them from the Terminal. They use the system libraries `lib/tar.lua` and `lib/compression.lua`, so they write files that `tar` and `gzip` on any other computer can read, and read the files those programs write.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

Like `appman`, they only run in the zOS Terminal, because a shell program can't reach the system libraries anywhere else.

## tar

```
tar -c [-z] -f <archive> <path>...  Create an archive
tar -x -f <archive> [-C <folder>]   Extract an archive
tar -t -f <archive>                 List an archive
  -z  gzip it (.tar.gz). Implied by a
      .gz or .tgz name; extracting and
      listing detect it by themselves
  -v  show each file
```

Options follow GNU tar. They can be grouped (`-czf`), and the leading `-` can be left out of the first argument (`tar czf out.tar.gz docs`). A letter that takes a value takes the next argument. The long forms `--create`, `--extract`, `--list`, `--gzip`, `--verbose`, `--file=<archive>`, `--directory=<folder>` and `--help` also work. Without `-f`, the first path is the archive.

Exactly one of `-c`, `-x` and `-t` MUST be given. An unknown option prints the list above and fails.

### Creating

`tar -c` archives each path, and everything inside each folder, into one file.

- Each name is the path relative to the current folder, as it was given. A path outside the current folder keeps its full path without the leading `/`, as GNU tar does.
- Folders get their own entries, so empty folders are kept.
- The archive itself is never added, even when it's inside a folder being archived.
- Archiving `/` leaves out `/rom`.
- Entries are sorted by name within each folder, with mode `644` for files and `755` for folders, owner `0`, and the time the file last changed.
- The archive is POSIX ustar, padded to a multiple of 512 bytes. A path too long for ustar fails.
- With `-z`, or when the archive's name ends in `.gz` or `.tgz`, the archive is gzipped.

It MUST fail before writing if a path doesn't exist or the archive doesn't fit in the free space.

### Extracting

`tar -x` writes each file in the archive into the current folder, or the folder given with `-C`, which it creates if needed. A gzipped archive is detected by its first bytes, so `-z` isn't needed.

It MUST check the whole archive before it writes anything, and MUST fail without writing if:

- the archive is damaged, as `tar.parse` decides;
- a name has a `..` segment;
- a file would replace a folder, a folder would replace a file, or a file sits where a folder is needed;
- a path is read-only.

A leading `/` or `./` is removed from names. A file replaces any file already at its path. Links, devices and FIFOs are skipped with a message, and the program fails at the end so that scripts notice.

### Listing

`tar -t` prints each name in the archive. With `-v` it also shows `d` for folders, `-` for files and `?` for anything else, and each file's size.

## gzip and gunzip

```
gzip [-k] [-f] [-1..-9] <file>...  Compress
gzip -d [-k] [-f] <file>...        Decompress
  file -> file.gz, or back again
  -k  keep the original file
  -f  replace a file that's in the way
  -1  fastest ... -9  smallest (6)
gunzip <file>... is gzip -d
```

The long forms `--decompress`, `--keep`, `--force`, `--fast`, `--best` and `--help` also work.

- `gzip file` writes `file.gz` and deletes `file`. The gzip header holds the file's name and the time it last changed.
- `gzip -d file.gz` writes `file`, and `file.tgz` becomes `file.tar`. Any other name fails.
- The new file is written in full before the original is deleted, and the original is kept with `-k`.
- It MUST NOT replace an existing file unless `-f` is given, and MUST NOT compress a name that already ends in `.gz` or `.tgz`.
- Folders are refused. To compress a folder, archive it with `tar -cz`.

Each file is handled on its own: a problem with one prints a message and moves on to the next, and the program fails at the end if any did.

`tar -cz` and `tar -c` followed by `gzip` give the same archive, apart from the name and time that `gzip` stores in the header.

## Limitations

- **Memory.** The whole archive and every file in it are in memory at once.
- **Time.** CraftOS stops a program that runs about 7 seconds without yielding. `tar` yields between files, and `gzip` before it starts, but a single gzip of a very large file can't be split up, so compressing much more than a few hundred KB at a time might be stopped.
- **No links or permissions.** CC has neither, so links aren't extracted and file modes are ignored.
