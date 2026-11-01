# zOS Apps Library Specification

`require("apps")` finds, checks, installs, removes and runs apps. App Manager and zOS updates use it, and [`appman`](../APPMAN.md) gives administrators the same features from the Terminal. [UPDATE.md](UPDATE.md) provides the list of apps in the latest release.

What an app image contains is described in [ZA_FORMAT.md](../formats/ZA_FORMAT.md), and where an app keeps its files in [APP_STANDARDS.md](../APP_STANDARDS.md).

Like [ZOS.md](../ZOS.md), this document describes how zOS is meant to work. [Current state](#current-state) lists where the code differs.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Overview

| Layer           | Provides                                                       |
| --------------- | -------------------------------------------------------------- |
| `appman`        | The command line: arguments, prompts, the admin check, logging |
| App Manager     | The same, as menus                                             |
| `update`        | The list of apps in the latest release, and verified downloads |
| `apps`          | Packages, the installed apps, installing, removing, running    |
| `services`      | Starting and stopping each app's background service            |

Getting an app takes two steps. A source produces a **package**, and `apps.install` writes the package to the computer:

```lua
local apps = require("apps")

local pkg, err = apps.readPackage("/disk/notes.za") -- or apps.download, or update.downloadApp
if not pkg then return printError(err) end

local app
app, err = apps.install(pkg)
if not app then return printError(err) end
print("Installed " .. app.name .. " " .. app.version)
```

### Errors

Functions that can fail return `nil` and a message that can be shown to the user, unless noted otherwise. They don't raise errors for bad images or failed downloads.

### Permissions

The library doesn't check who is calling. `apps.install` and `apps.remove` work for anyone, so every caller that acts for a user MUST check `session.admin` first, and SHOULD log what it did with `system.log`:

```lua
system.log(session.user .. " installed app " .. app.id .. " " .. app.version)
```

## Packages

A package is a checked image in memory. Nothing on the computer has changed until it is passed to `apps.install`.

| Field      | Type   | Contents                                     |
| ---------- | ------ | -------------------------------------------- |
| `id`       | string | The app's id                                 |
| `manifest` | table  | The unpacked `app.manifest`                  |
| `files`    | table  | Every file, as (relative path -> data)       |
| `count`    | number | The number of files                          |
| `size`     | number | The total size of the files, in bytes        |

### apps.parse(text)

Checks the text of an image and returns a package. It rejects an image with the wrong format version, an invalid id, a bad path, a path used as both a file and a folder, no `main.lua`, a `main.lua` or `service.lua` that doesn't compile, or an invalid manifest. The code is compiled but not run.

### apps.readPackage(path)

Reads an image from a file, in binary mode, and passes it to `apps.parse`.

### apps.download(source)

Downloads an image and passes it to `apps.parse`. `source` is a URL starting with `http://` or `https://`, and anything else is treated as a Pastebin code. It fails if the HTTP API is disabled.

Nothing is known about the size or hash of what comes back, so the source has to be trusted. See [Security](#security).

### apps.validId(id)

Returns whether `id` can be an app id: 1-32 lowercase letters, digits, `-` or `_`. The id `zos` is reserved.

### apps.validPath(path)

Returns whether `path` can be a file in an app: relative, at most 128 bytes, and made of plain names that don't start with `.`.


### Manifests

`apps.parse` and `apps.list` check manifests with the same rules as `check_manifest` in `tools/make_apps.py`, and the two MUST be kept the same. `name` and `version` are required text. `description` and `author` MUST be text, `priority` MUST be a number, and `minZos` MUST be a version like `"1.0"`.

### Constants

| Name                    | Value                                                   |
| ----------------------- | ------------------------------------------------------- |
| `apps.DIR`              | `/.zos/apps`, where apps are installed                  |
| `apps.DEFAULT_PRIORITY` | 100, the priority of an app that doesn't set one        |
| `apps.FORMAT_VERSION`   | 1, the version of the .za format it reads               |
| `apps.METADATA`         | `"za:metadata"`, the metadata key                       |
| `apps.PROTECTED`        | The ids of the built-in apps, as (id -> true)           |

## Installed apps

Installed apps are described by an app record, which is also what `main.lua` receives as `app`.

| Field         | Type    | Contents                                                       |
| ------------- | ------- | -------------------------------------------------------------- |
| `id`          | string  | The app's id                                                   |
| `name`        | string  | Its display name                                               |
| `description` | string  | Its description, or `""`                                       |
| `version`     | string  | Its version                                                    |
| `author`      | string  | Its author, or `nil`                                           |
| `priority`    | number  | Its priority. Defaults to `apps.DEFAULT_PRIORITY`, which is 100 |
| `minZos`      | string  | The oldest zOS it runs on, or `nil`                            |
| `dir`         | string  | Its folder, as an absolute path                                |
| `main`        | string  | The absolute path of `main.lua`                                |
| `service`     | string  | The absolute path of `service.lua`, or `nil` if it has none    |
| `protected`   | boolean | Whether it can be upgraded but not removed                     |

### apps.list()

Returns every valid installed app, lowest priority first, then by name. A folder with a bad id or manifest, or with no `main.lua`, is skipped without an error.

### apps.get(id)

Returns the app record for `id`, or `nil` if it isn't installed or isn't valid. There is no error message.

### apps.supports(minZos)

Returns whether this version of zOS is new enough. `nil` is always supported.

### apps.compareVersions(a, b)

Compares two versions by their numbers. It returns -1 if `a` is older than `b`, 0 if they are equal and 1 if `a` is newer. Missing numbers count as 0, so `1.0` equals `1`, and `1.10` is newer than `1.9`.


## Changing apps

### apps.install(pkg)

Installs a package from `apps.parse`, replacing any installed version, and returns the new app record.

1. Refuses the package if this zOS is older than its `minZos`, or if the files don't fit in the free space.
2. Writes every file to `/.zos/apps/.installing-<id>` and reads it back, so a full disk leaves the old version in place.
3. Stops the app's service.
4. Deletes the old folder and moves the new one into place.
5. Starts the new `service.lua`, if there is one.

The whole folder is replaced, so files the app added to it are lost. A computer that shuts down during step 4 can lose the old version, and the app then has to be installed again. `apps.install` doesn't yield, so Ctrl+T can't stop it partway.

It MAY install an older version than the installed one. Callers decide whether that's allowed, using `apps.compareVersions`.

### apps.remove(id)

Stops the app's service and deletes its folder. It fails if the app isn't installed or is protected. The app's data in `/etc/<id>/` and `/home/<user>/.config/<id>/` is kept, so installing the app again brings it back.

### apps.PROTECTED

The built-in apps, which can be upgraded but not removed. They come from `require("builtin")`, the list in `src/.zos/lib/builtin.lua`: `appman`, `terminal` and `files`.

## Running apps

An app's code runs in its own environment on top of the one the system libraries share, so an app gets the same `apps` and `services` that booted the computer.

`require(name)` looks for `<name>.lua` in the app's folder first, with each `.` in the name as a `/`, then finds the system libraries. Each of the app's modules runs once, and `main.lua` and `service.lua` get separate copies.

### apps.launch(app, session)

Clears the screen, runs `main.lua` with `...` = `session, app`, and puts the terminal back afterwards. While it runs, `os.pullEvent` raises `Terminated` on Ctrl+T, even though zOS itself ignores Ctrl+T.

It returns `true` if the app finished or was stopped with Ctrl+T, or `false` and the error if it failed to load or crashed. A crash MUST NOT end the session.

### apps.startService(app)

Starts `service.lua` with `...` = `app`, under the app's id, as described in [SERVICES.md](SERVICES.md). It returns `true`, or `false` if the app has no service or it won't load. A service that won't load is also logged.

### apps.startServices()

Starts the service of every installed app, in priority order. The boot sequence calls it once.

## Security

Installing an app means trusting it completely. Path checks control where its files are written, not what its code does, and `service.lua` runs at every boot. See [Security](../formats/ZA_FORMAT.md#security) in the .za format.

| Source          | What is checked                                                     |
| --------------- | ------------------------------------------------------------------- |
| Release         | HTTPS to GitHub, then the size and SHA-256 from `zos-apps.manifest` |
| URL             | Nothing about where it came from. HTTPS only if the URL says so      |
| Pastebin        | Nothing about who wrote it                                          |
| File or floppy  | Nothing                                                             |

The size and hash catch damaged downloads, not deliberate changes. Only the release source is checked against a list. Images have no signature, and all of them are parsed in the same way.

## Current state

| Target                                       | Code today                                                      |
| -------------------------------------------- | --------------------------------------------------------------- |
| Reading an image checks that it fits in the free space | `apps.install` checks, not `apps.parse`               |
| Reading rejects a `minZos` that's too new    | `apps.install` rejects it, not `apps.parse`                     |
