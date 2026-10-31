# zOS App Standards

These standards say where an app's files live on a computer.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

| Path                          | Holds                                    | Written by          |
| ----------------------------- | ---------------------------------------- | ------------------- |
| `/.zos/apps/<id>/`            | The app's installed files                | The installer       |
| `/etc/<id>/`                  | The app's global data                    | The app             |
| `/home/<user>/.config/<id>/`  | The app's config for one user            | The app             |

`<id>` is the app's id, and `<user>` is the name of the logged-in user.

## Installation

Apps are installed to `/.zos/apps/<id>/`.

Installing a new version replaces the whole folder, so anything else in it is lost. An app MUST NOT write to this folder while it runs, and MUST NOT rely on files in another app's folder.

## Data

An app MUST save its data in one of the two locations below, not in its install folder.

### Global data

Apps SHOULD save data that belongs to the computer in `/etc/<id>/`. This is data that is the same whoever is logged in, such as a server's database or settings that apply to everyone.

Global data is the only location available to `service.lua`, because a service runs even while nobody is logged in.

### User config

Apps SHOULD save config that belongs to one person in `/home/<user>/.config/<id>/`. The user name comes from `session.user`, which `main.lua` receives.

```lua
local session, app = ...

local GLOBAL_DIR = "/etc/" .. app.id
local CONFIG_DIR = "/home/" .. session.user .. "/.config/" .. app.id
```

An app SHOULD create these folders the first time it needs them, and MUST NOT assume they exist.

## Ownership

An app MUST NOT read or write another app's folders unless that app documents them for others to use.

The id `zos` is reserved and MUST NOT be used by an app, because `/etc/zos/` belongs to the system.
