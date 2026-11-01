# zOS apps

Each folder here is one app. `tools/make_apps.py` packs it into a single `.za` file, which the
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
    minZos = "1.0",                      -- optional: the oldest zOS it runs on
}
```

Set `minZos` when an app uses something a newer zOS added. Nothing older will install that
version, whichever way it's installed, and the build stops if `minZos` is newer than the zOS in
this repository. Computers keep the version they have until they update zOS. The check only runs
when installing, so raise `minZos` before people need it, not after.

## Writing an app

- `main.lua` gets `...` = `session, app`. `session` has `user`, `admin`, `secretKey` and
  `publicKey`. `app` has `id`, `name`, `version`, `dir` and so on.
- `service.lua` gets `...` = `app`. It runs alongside the session, even while nobody is logged
  in. It never sees Ctrl+T. Anything it draws goes to a hidden window. If it crashes, it stops
  and the error goes to `/etc/zos/system.log`.
- `require` finds the app's own modules first (`require("helper")` loads `helper.lua` from the
  app folder), then the zOS libraries (`ui`, `auth`, `keys`, `crypto`, `net`, `trust`, `system`, `apps`, ...).
- Installing a new version replaces the app's folder, so keep data somewhere else, such as
  `/etc/<id>/` or `/home/<user>/.config/<id>/`. See `specs/APP_STANDARDS.md`.

## Packaging

```
python3 tools/make_apps.py                # dist/apps/<id>.za for every app
python3 tools/make_apps.py notes          # only some
python3 tools/make_apps.py --upload       # also upload each .za to Pastebin (needs PASTEBIN_DEV_KEY)
```

In App Manager, use **Install from disk** with a `.za` file copied onto a floppy, **Install from file...** with a path,
or **Install from URL or Pastebin...** with a link or paste code. Only admins can install or
remove apps.

A `.za` file is one table of the app's files, as described in `specs/formats/ZA_FORMAT.md`:

```lua
{ ["za:metadata"] = { version = 1, id = "notes" }, ["main.lua"] = "...", ... }
```

Each release includes every app here. To ship a change, raise `version` in its `app.manifest`:
computers only update to a higher version. **Get apps from GitHub** in App Manager installs and
updates them.

The apps listed in `src/.zos/lib/builtin.lua` (currently App Manager, Terminal and Files) are built in.
`./package` copies them from this folder into the system image, so keep no copy in `src/`. They can be
upgraded but not removed.
