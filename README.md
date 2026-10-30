# zOS

A small operating system for [CC: Tweaked](https://tweaked.cc) computers, turtles and pocket
computers.

- **Secure boot.** Ctrl+T can't skip startup, and the computer won't boot from floppy disks.
- **Logins.** Passwords are salted and hashed, and repeated failed attempts lock the login.
- **Desktop.** An app launcher with built-in apps and an app manager for installing more.
- **Setup disk.** Installs or upgrades zOS and walks you through creating an admin account.
- **Networking.** Encrypted, authenticated messages between computers, with root servers that
  vouch for who a computer is.

## Quick start

```
python3 tools/make_disk.py --upload    # needs PASTEBIN_DEV_KEY; or upload dist/zos-disk.lua yourself
```

In game, put a floppy in a disk drive and run `pastebin run <code>` to write the setup disk.
Then put that disk in a drive next to the computer you want zOS on and reboot it.

## Making a setup disk

The `disk/` folder is the contents of the setup floppy. You can get it onto a floppy in two ways.

### From Pastebin

`tools/make_disk.py` packs `disk/` into a single Lua program, `dist/zos-disk.lua`, that writes
the setup disk when you run it in game. You don't need access to the world
save.

```
python3 tools/make_disk.py                  # writes dist/zos-disk.lua
python3 tools/make_disk.py -o other.lua     # or somewhere else
python3 tools/make_disk.py --upload         # and uploads it to Pastebin (unlisted)
python3 tools/make_disk.py --upload --public
python3 tools/make_disk.py --no-minify      # keep comments and indentation in the Lua files
```

Minifying needs LuaSrcDiet. Install it once, from the repository root (this needs Lua 5.1 and
its headers, e.g. Debian's `lua5.1` and `liblua5.1-0-dev`):

```
luarocks --tree lua_modules --lua-version=5.1 install luasrcdiet 1.0.0-2
```

`--upload` needs a Pastebin API key in `PASTEBIN_DEV_KEY` (get one at
<https://pastebin.com/doc_api>). Without it, upload `dist/zos-disk.lua` by hand. Then, in game,
with a floppy in a disk drive:

```
pastebin run <code>                         # the first floppy found
pastebin run <code> <side>                  # the floppy in the drive on that side
pastebin run <code> some/folder             # a folder instead of a floppy
```

- If the floppy isn't empty, the program lists what's on it and asks before erasing it, so you
  can reuse an old setup disk.
- It checks there's enough free space, reads each file back after writing it, and labels the
  floppy `zOS Setup <version>`.
- Lua files are minified with [LuaSrcDiet](https://github.com/jirutka/luasrcdiet), which also
  checks that each one compiles to the same bytecode as before. Line numbers in error messages
  won't match the source, so use `--no-minify` when debugging.
- A floppy holds 125 KB, which the setup files only fit into minified. With `--no-minify`, write
  to a folder instead.
- Files are stored as escaped strings, one per line, so Pastebin's line-ending and whitespace
  changes can't alter them.
- After changing zOS, run the script again and upload the new version.

### From the world save

1. In game, put a floppy in a disk drive and run `label set <side> zos-setup`. This gives the
   floppy an ID, which `id <side>` prints.
2. Copy the *contents* of `disk/` into that floppy's folder:
   - singleplayer: `.minecraft/saves/<world>/computercraft/disk/<id>/`
   - server: `<world>/computercraft/disk/<id>/`

   You should end up with `.../disk/<id>/install.lua`, `.../disk/<id>/payload/...` and so on.

## Installing and upgrading

Put the setup disk in a drive next to the target computer, then either:

- **reboot the computer.** A computer without zOS boots from the disk and setup starts by
  itself, or
- **run `disk/install`** from the shell. On a computer that already has zOS, log in and open the
  Shell app to do this.

For a new install, setup asks for:

1. **An administrator account:** a username and a password (at least 4 characters, typed twice).
2. **A computer label** (optional).

It then backs up any existing `/startup` or `/startup.lua` to `/zos-backup/`, copies zOS onto
the computer, creates the account, **turns off disk boot**, ejects the disk and reboots.

If zOS is already installed, setup offers two options:

- **Upgrade** replaces the system files and keeps users, apps and settings.
- **Clean reinstall** deletes all accounts and their keys, then asks for a new admin account.

## Using zOS

### Logging in

- After 3 failed attempts, login locks for 5 seconds, then 10, 20 and so on, up to 5 minutes.
  The lock survives a reboot.
- Admins add, remove and reset users in **Settings → Users**. Everyone can change their own
  password there.

### Built-in apps

| app             | what it does |
|-----------------|--------------|
| **Files**       | Browse folders; edit, run, copy, move and delete files |
| **Shell**       | The CraftOS shell (`exit` returns to the desktop) |
| **App Manager** | Install and remove apps |
| **Settings**    | Change your password, set the computer label, view the network; admins also manage users, root servers and secure boot |
| **About**       | System information |

### Secure boot

CraftOS normally runs a floppy's `startup` program on boot, which would let anyone skip the
login. zOS turns this off and keeps it off: changing `shell.allow_disk_startup` from the shell
doesn't stick (see [How it works](#how-it-works)).

If you need to boot from a disk, for example a repair disk, an admin can turn secure boot off
in **Settings → Secure boot**. This asks for your password. While it's off, *anyone* with a
floppy can boot their own program and skip the login, so turn it back on afterwards.

The setting is saved in `/etc/zos/config`, and each change is logged to `/etc/zos/system.log`.
Upgrades keep it, and a clean install or reinstall turns secure boot back on.

## Apps

### Optional apps

These apps aren't on the setup disk. Each lives in its own folder under `apps/`, which has a
README with the details.

| folder                           | app            | what it does |
|----------------------------------|----------------|--------------|
| [`apps/zos-mail`](apps/zos-mail)   | **Mail**       | End-to-end encrypted messages between users on this or other zOS computers |
| [`apps/zos-notes`](apps/zos-notes) | **Notes**      | Personal notes, saved in `/home/<user>/notes/` |
| [`apps/zos-calc`](apps/zos-calc)   | **Calculator** | Evaluates expressions like `sqrt(2) * pi`, with variables (`x = 5`) and `ans` |
| [`apps/root-server`](apps/root-server) | **Root Server** | Signs other computers' keys, see [Root servers](#root-servers) |

Upgrading from zOS 1.2 or earlier removes the old built-in Mail, Notes and Calculator apps but
keeps their data (`/etc/zos/mail/`, `/home/<user>/notes/`). Install the apps again to get them
back.

### Making app disks

`tools/make_app_disks.py` does for apps what `tools/make_disk.py` does for the setup disk. It
packs each app into a program that writes the app onto a floppy:

```
python3 tools/make_app_disks.py              # every app: dist/zos-mail-disk.lua, dist/zos-notes-disk.lua, ...
python3 tools/make_app_disks.py notes calc   # only these ("notes" and "zos-notes" both work)
python3 tools/make_app_disks.py -o out/      # write them somewhere other than dist/
python3 tools/make_app_disks.py --upload     # and upload each one to Pastebin (--public works too)
```

In game, `pastebin run <code>` (or `pastebin run <code> <side>`) writes the app's folder onto
the floppy and labels it `zOS <app> <version>`. You can also copy an app's folder (e.g.
`apps/zos-notes/notes/`) onto a floppy through the world save, as with the setup disk.

### Installing apps

Use the **App Manager** app, or `appman` in the Shell:

```
appman list
appman install disk/notes            -- a folder with an app.manifest
appman install disk/tool.lua tool    -- a single file; a manifest is generated
appman get <pastebin-code|url> tool  -- download a single-file app (needs the HTTP API)
appman remove tool
```

### Writing apps

An app is a folder with a manifest and a main program:

```
/apps/myapp/app.manifest
/apps/myapp/main.lua
```

```lua
-- app.manifest (a textutils-serialised table)
{
  name = "My App",
  description = "Shown at the bottom of the desktop",
  version = "1.0",
  author = "you",
  main = "main.lua",
  service = "service.lua", -- optional, see below
}
```

The desktop lists every folder with a manifest in `/zos/apps` (built-in apps) and `/apps`
(installed apps). Apps are ordinary CraftOS programs started with `shell.run`, so `shell`,
`require` and Ctrl+T work as usual. Ctrl+T stops only the app, never the session.

Apps also get a global `zos` table:

| field               | contents |
|---------------------|----------|
| `zos.version`       | zOS version string |
| `zos.session`       | `{ user = "name", admin = true/false, since = epoch_ms, secretKey = ..., publicKey = ... }` |
| `zos.ui`            | the UI toolkit (`menu`, `pager`, `screen`, `text`, `input`, `message`, `confirm`, ...) |
| `zos.apps`          | the app registry (`list`, `install`, `remove`, ...) |
| `zos.auth`          | the account API |
| `zos.crypto`        | X25519, ChaCha20, HMAC-SHA256, `seal`/`open`, random bytes |
| `zos.keys`          | users' key pairs and pinned remote keys |
| `zos.import(name)`  | load a system library from `/zos/lib` |
| `zos.addStatus(fn)` | add text to the desktop's title bar; `fn(session)` returns a short string or nil |
| `zos.log(text)`     | append a line to `/etc/zos/system.log` |

**User keys.** Every user has an X25519 key pair, created at their first login. The secret key
is encrypted with their password and unlocked into `zos.session` at login, so apps can encrypt
data that only that user can read (Mail does this). Changing your own password keeps your key.
If an admin resets someone else's password, the old key is lost and that user gets a new one at
their next login.

**Background services.** If the manifest names a `service` file, zOS starts it at boot and runs
it alongside the session, even while nobody is logged in (Mail uses this to receive messages).
The service gets its app's folder as `...`. Services must not draw to the screen and should use
`os.pullEventRaw`. If a service crashes, it stops and the error goes to `/etc/zos/system.log`.
Nothing else is affected.

## Networking

`require("net")` gives apps encrypted messages over modems. There's nothing to set up: every
computer has its own key, and the key exchange happens by itself the first time two computers
talk.

```lua
local net = require("net")

-- Receive: only messages that decrypt and authenticate get through.
net.listen(5000)                                -- every modem
net.listen(5000, { modem = "top" })             -- or one modem
net.listen(5000, { verified = true })           -- only computers a trusted root vouches for

while true do
    local msg = net.receive(5000)               -- waits; net.receive(5000, 10) gives up after 10s
    if msg then
        print(msg.from, msg.payload)
        net.reply(msg, "got it")                -- if it came from net.request
    end
end
```

Each message also queues a `net_message` event (`net.EVENT`), which suits programs already
waiting on other events. The event goes to every program on the computer and is gone if nobody is
waiting for it at that moment, for example during a `net.reply`, so check `msg.port`, and use
`net.receive` in servers: it holds up to 32 messages per port until you ask for them.

```lua
-- Send: returns true once the other computer has decrypted the message.
local ok, err = net.send(12, 5000, { any = "table" })
local ok, err = net.send(12, 5000, "hi", { verified = true })       -- it must have a certificate
local ok, err = net.send(12, 5000, "hi", { expect = "bank" })       -- for exactly this name

-- Or wait for an answer.
local reply, err = net.request(12, 5000, "ping", { timeout = 5 })
```

| `msg` field | contents |
|-------------|----------|
| `payload`   | what was sent: anything except functions, up to 32 KB |
| `port`      | the port it arrived on |
| `from`      | the sender's computer id, for replying. Use `peer` to decide whether to believe it |
| `side`      | the modem it arrived on |
| `peer`      | `{ id, key, fingerprint, verified, name, root }`. `name` is only set if `verified` |

A port is the modem channel. Each computer also keeps one channel open for itself
(`30000 + id % 30000`) for handshakes and replies, which accepts nothing but answers to its own
requests. `net.close(port)` stops listening. A closed port doesn't answer at all, so a send to one
fails with a timeout, and `net.send` can take around 20 seconds to give up.

### Who you're talking to

- **Verified.** The peer showed a current certificate, signed by a root server you trust, for
  the key it proved it holds and the computer id it claims. `peer.name` is the name on the
  certificate. This is checked for every message, so removing a root takes effect at once.
- **Pinned.** Without such a certificate, the peer's key is remembered against its computer id the
  first time it's seen, and it's refused if the key changes, unless the new key has a certificate
  for that computer id. The traffic is encrypted, but
  on first contact nothing shows who is on the other end, and computer ids can be faked. Use
  `verified` or `expect` for anything that matters. Pinned keys are in **Settings → Encryption
  keys → Trusted keys**, and forgetting one there lets that computer change key.

### Root servers

A root server is a computer whose key others have decided to trust. It signs a certificate
saying "this key belongs to this name on this computer".

1. **Set one up.** Install the Root Server app on a computer that only admins can log in to, open
   it, and name the server. It announces itself on port 4200.
2. **Trust it.** On each other computer, an admin opens **Settings → Network → Root servers → Add
   root server...**. zOS asks every root server in range to identify itself and lists their names
   and fingerprints. Anyone can announce a root server under any name, so compare the
   fingerprint with the one in **This server** in the Root Server app before accepting.
3. **Get a certificate.** Choose the server in that list, then **Request a certificate** and pick
   a name. The screen waits while the root server's admin compares fingerprints (**Settings →
   Network → This computer** shows yours) and approves it under **Requests**. If you stop waiting,
   the request stays, and asking again picks up the answer.

Certificates last 30 days unless the root server is set otherwise, and computers renew them by
themselves in their last 7 days as long as the root server can be reached, checking shortly after
each boot and then hourly. An expired certificate just means the computer stops being verified.
Each name and each computer can hold one certificate on a root server at a time, so a reinstalled
computer needs its old one revoked first. Its new key is also refused, by the root server and
everyone else who pinned the old one, until an admin there forgets it under **Trusted keys**.
Revoking one in the app stops it renewing and frees the name, but the certificate
keeps working until it expires, because computers don't check back with the root server. Keep the
lifetime short if that matters to you.

### Protocol

Each handshake uses new X25519 keys, and each side signs both of them with its Ed25519 identity
key, so recorded traffic can't be decrypted later, even with the identity keys. Messages are
encrypted with ChaCha20 and authenticated with HMAC-SHA256, which also covers the addresses, port
and a sequence number, so a message can't be changed, redirected or replayed. New keys are made
every hour. Messages are acknowledged and sent again once if there's no answer, starting a new
session in case the other computer rebooted, and repeats are dropped.

Signatures are slow in Lua, so the first message to a computer takes noticeably longer than the
ones after it. The work happens in the background, so packets aren't lost in the meantime.

## How it works
## How it works

### Boot

```
CraftOS bios -> shell -> /startup.lua -> /zos/boot.lua -> login -> desktop
```

- **Disk boot stays off.** CraftOS decides whether to run a floppy's `startup` *before* it runs
  `/startup.lua`, based on the `shell.allow_disk_startup` setting. zOS sets it to `false` in
  `/.settings` at install time, on every boot, and before every reboot or shutdown.
- **`/startup.lua` never returns.** It replaces `os.pullEvent` with `os.pullEventRaw` so Ctrl+T
  can't stop it, then runs `/zos/boot.lua` inside `pcall`. If boot crashes, it shows a recovery
  prompt, where an admin login opens a recovery shell, and then reboots. It never falls through
  to an open shell.
- **`/zos/boot.lua`** secures the boot settings, loads the libraries, adds `/zos/bin` to the
  shell path and scans the installed apps, with a progress bar. It then loops login → desktop →
  logout forever. An error anywhere logs you out instead of crashing the computer.

### Accounts

- Accounts are stored in `/etc/zos/users.db`. Each password is stored as a 200-round SHA-256 hash
  with a random 16-byte salt, never in plain text.
- The login lock is stored in `/etc/zos/lockout`, which is why rebooting doesn't clear it.

### Files on the computer

| path               | contents |
|--------------------|----------|
| `/startup.lua`     | bootstrap |
| `/zos/`            | the system (replaced on upgrade) |
| `/etc/zos/`        | accounts, keys, network identity, config, log |
| `/home/<user>/`    | users' files |
| `/apps/`           | installed apps |
| `/zos-backup/`     | your old startup file, if you had one |

Upgrades only replace `/startup.lua` and `/zos/`.

## Project layout

```
tools/
  make_disk.py            packs disk/ into dist/zos-disk.lua, which writes the setup disk
  make_app_disks.py       packs each app in apps/ into dist/<app>-disk.lua, which writes an app disk
apps/                     optional apps: root-server, zos-mail, zos-notes, zos-calc
tests/                    off-game tests: luajit tests/test_crypto.lua, test_net.lua, test_ui.lua
disk/                     the setup floppy
  startup.lua             starts setup when a computer without zOS boots from the disk
  install.lua             the setup program
  payload/                copied onto the computer
    startup.lua           -> /startup.lua
    zos/                  -> /zos
      boot.lua            boot stages and the session loop
      lib/sha256.lua      password hashing
      lib/auth.lua        accounts and login throttling
      lib/apps.lua        app registry, install, remove, launch
      lib/ui.lua          terminal UI toolkit
      lib/crypto.lua      X25519, Ed25519, ChaCha20, SHA-256/512, HMAC, random numbers
      lib/keys.lua        per-user key pairs, pinned keys
      lib/trust.lua       the computer's identity, trusted root servers, certificates
      lib/net.lua         encrypted messages over modems
      sys/login.lua       login screen
      sys/desktop.lua     app launcher
      bin/appman.lua      command-line app manager
      apps/               built-in apps: files, shell, appman, settings, about
dist/                     generated programs
```

## Limitations

- **Users can see each other's files.** ComputerCraft has no file permissions, so logins keep
  strangers out but don't separate the people who can log in. Any user can open the Shell and
  read or change any file. Only give accounts to people you trust. Data encrypted with a user's
  key is the exception: only that user's password can unlock it.
- **Network keys aren't protected by a password.** Networking runs while nobody is logged in, so
  a computer's identity key, and a root server's signing key, are stored unencrypted in
  `/etc/zos/`. Anyone who can log in to a computer can take its identity, which is why a root
  server should have only trusted admins.
- **Randomness is limited.** CC has no secure random source, so keys are made from timing and
  other hard-to-guess values. Setup mixes in your password before it creates the identity key.
- **A flood can delay new connections.** Only a few unfinished handshakes are kept, so a computer
  sending constant fake handshakes can hold up new sessions. Existing sessions keep working.
  Anyone can also jam a channel, since modems have no way to stop them.
- **The world files are always a way in.** Anyone with access to the world or server files can
  get around zOS.
- **A broken install can't be fixed from a disk.** If `/zos` is damaged and recovery can't load,
  the computer keeps rebooting, and because disk boot is off, a setup disk can't fix it. Repair
  the files in the world save (`computercraft/computer/<id>/`), or delete `.settings` there to
  turn disk boot back on.

## Uninstalling

From the Shell:

```
delete /startup.lua /zos /etc/zos /home
set shell.allow_disk_startup true
```

Then move your old startup file back from `/zos-backup/` if you had one.
