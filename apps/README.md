# zOS apps

Each folder here is one app. `tools/make_apps.py` packs it into a single `.app` file, which the
App Manager installs.

```
apps/<id>/
  app.manifest    required: the app's name, version and so on
  main.lua        required: runs when you open the app from the desktop
  service.lua     optional: starts at boot and runs in the background
  ...             any other files: modules, data
```

The folder name is the app's id: 1-32 lowercase letters, digits, `-` or `_`.

## app.manifest

```lua
{
    name = "Notes",                      -- required
    version = "1.0",                     -- required, a string
    description = "Write and keep notes", -- shown on the desktop and in App Manager
    priority = 10,                       -- lower comes first on the desktop and starts first (default 100)
    author = "you",
}
```

## Writing an app

- `main.lua` gets `...` = `session, app`. `session` has `user`, `admin`, `secretKey` and
  `publicKey`. `app` has `id`, `name`, `version`, `dir` and so on.
- `service.lua` gets `...` = `app`. It runs alongside the session, even while nobody is logged
  in. Use `os.pullEventRaw`. Anything it draws goes to a hidden window. If it crashes, it stops
  and the error goes to `/etc/zos/system.log`.
- `require` finds the app's own modules first (`require("helper")` loads `helper.lua` from the
  app folder), then the zOS libraries (`ui`, `auth`, `keys`, `crypto`, `net`, `trust`, `system`, `apps`, ...).
- Installing a new version replaces the app's folder, so keep data somewhere else, such as
  `/home/<user>/` or `/etc/zos/<id>/`.

## Packaging

```
python3 tools/make_apps.py                # dist/apps/<id>.app for every app
python3 tools/make_apps.py notes          # only some
python3 tools/make_apps.py --disk         # also dist/zos-apps-disk.lua: `pastebin run` it to write the apps onto a floppy
python3 tools/make_apps.py --upload       # also upload each .app to Pastebin (needs PASTEBIN_DEV_KEY)
```

In App Manager, use **Install from disk** with that floppy, **Install from file...** with a path,
or **Install from URL or Pastebin...** with a link or paste code. Only admins can install or
remove apps.

A `.app` file is one `textutils.serialize`-style table:

```lua
{ format = "zos-app", formatVersion = 1, id = "notes", files = { ["main.lua"] = "...", ... } }
```

The apps in `BUILT_IN_APPS` in `tools/make_disk.py` (currently App Manager) go on the setup
disk. Setup installs them, and they can be upgraded but not removed.
