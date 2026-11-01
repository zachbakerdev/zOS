# zOS appman Specification

`appman` is a shell program for installing and managing apps from the Terminal. It does what App Manager does, without menus, so it can be used from scripts and on pocket computers. It uses [APPS.md](libs/APPS.md) to change apps and [UPDATE.md](libs/UPDATE.md) to find apps in the latest release.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

```
appman list                   Show installed apps
appman available              Show apps in the release
appman install <source> [-y]  Install an app
appman update [<id>...] [-y]  Update apps
appman remove <id> [-y]       Remove an app
appman help                   Show this list
```

`-y` or `--yes` answers yes to the prompts, for scripts. An unknown command or option prints the list above and fails.

```
> appman install notes
Notes 1.0  (new)
id: notes   by zOS
3 files, 4.1 KB

Apps can read and change every file on this
computer. Only install apps you trust.
Install it? (y/n) y
Installed Notes 1.2. It is on the desktop.
```

## Who can run it

`list`, `available` and `help` work for everyone. `install`, `update` and `remove` need an administrator, and MUST say so before downloading anything:

```
> appman remove notes
Only administrators can remove apps.
```

## appman list

Prints one line for each installed app in `apps.list` order, with its id, version and name. Long lines MUST wrap rather than be cut off, because a pocket computer's screen is only 26 characters wide.

```
> appman list
files 1.0 Files
terminal 1.0 Terminal
appman 1.0 App Manager
notes 1.0 Notes
```

## appman available

Prints one line for each entry in `update.checkApps`, in its order, with its id, version and status. The status is the same as in App Manager: `new`, `installed`, `update from <version>`, `older than installed` or `needs zOS <version>`.

```
> appman available
notes 1.1 update from 1.0
mail 1.0 new
files 1.0 installed
```

## appman install

`<source>` is read by its form alone, in this order. What's on the disk doesn't change how it is read, so a command always means the same thing.

| Form                               | Source                | Example                       |
| ---------------------------------- | --------------------- | ----------------------------- |
| Starts with `http://` or `https://` | Download from the URL | `appman install https://x/a.za` |
| Starts with `pastebin:`            | Download from Pastebin | `appman install pastebin:aBc123` |
| Passes `apps.validId`              | The latest release    | `appman install notes`        |
| Anything else                      | A file                | `appman install disk/notes.za` |

Pastebin needs a prefix because a code can look like an app id. A file path is resolved with `shell.resolve`, and a file whose name looks like an id is written `./notes`.

`install` then:

1. Checks the user is an administrator.
2. Gets the package. A release app that's up to date prints `<name> is up to date.` and succeeds.
3. Fails if this zOS is older than the app's `minZos`.
4. Shows the app's name, version, status, id, author, file count, size and description. If the image has a `service.lua`, it says the app runs in the background even when nobody is logged in. It always warns that apps can read and change every file.
5. Asks for confirmation.
6. Calls `apps.install` and logs the result.

A release is never downgraded. A file, URL or Pastebin image that's older than the installed version shows a warning and asks first, and with `-y` it fails, so a script can't downgrade an app by accident. Answering no prints nothing further and counts as success.

## appman update

With ids, updates those apps from the latest release. It fails if an id isn't in the release, or if this zOS is too old for it. An id that's up to date is reported and isn't an error.

With no ids, updates every entry from `update.checkApps` that is `newer` and `supported`, after listing them and asking once. If there are none, it prints `Everything is up to date.`

One failed app MUST NOT stop the others. `update` reports each failure at the end, then fails. Each app is downloaded with `update.downloadApp`, and each success is logged.

## appman remove

Asks for confirmation, then calls `apps.remove` and logs the result. It says that the app's data is kept.

## Exit status

Failures MUST use `error(message, 0)`. `os.run` prints the message in red and `shell.run` returns `false`, so scripts can check it:

```lua
if not shell.run("appman", "update", "-y") then
    print("Update failed")
end
```

Ctrl+T works as in any other program: it stops a download or prompt with nothing changed, and it can't interrupt `apps.install`.

## How it reaches the system

A shell program can't use `apps` directly, because of how zOS and CraftOS load code:

- CraftOS gives each shell program its own `require`, which can't see `/.zos/lib`.
- `appman` MUST NOT load a second copy of the libraries. `services` keeps its running services in a local table, so a second copy couldn't stop an app's old service, and any it started would never run.
- A shell program has no `session`, so it doesn't know who is logged in.

An environment falls back to `_G`, so Terminal passes these across in a global table for as long as it's open:

```lua
-- apps/terminal/main.lua
local session = ...

_G.zos = { require = require, user = session.user, admin = session.admin }
pcall(os.run, { shell = shell, print = function() end }, "rom/programs/shell.lua")
_G.zos = nil
```

`_G.zos` MUST NOT contain the session itself, because `secretKey` would then be readable by every service while the Terminal is open.

`appman` is `/.zos/bin/appman.lua`, so it updates with the system and can't be removed. `/.zos/bin` is added to the shell's path once, in `/.zos/boot.lua`, and the Terminal's shell inherits it:

```lua
ctx.shell.setPath(ctx.shell.path() .. ":/.zos/bin")
```

`appman` starts by getting the shared libraries from `_G.zos`:

```lua
local ctx = _G.zos
if not ctx then error("appman only runs in the zOS Terminal.", 0) end
local apps, update, system = ctx.require("apps"), ctx.require("update"), ctx.require("system")
```

A Terminal from before `appman` doesn't set `_G.zos`, so it gets that message rather than a crash. The recovery shell doesn't either, and there the libraries may be what's broken.

## Security

The admin check in `appman` is the same rule App Manager applies, but it isn't a security boundary. Anyone with Terminal can change `_G.zos.admin`, or write to `/.zos/apps` directly, as described in the [Security model](ZOS.md#security-model). It stops mistakes and keeps the rule the same in both places.

What each source of an app proves is described in [Security](libs/APPS.md#security).
