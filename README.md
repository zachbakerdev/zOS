# zOS

A small operating system for [CC: Tweaked](https://tweaked.cc) computers, turtles and pocket
computers.

- **Secure boot.** Ctrl+T can't skip startup, and the computer won't boot from floppy disks.
- **Logins.** Passwords are salted and hashed, and repeated failed attempts lock the login.
- **Desktop.** An app launcher with built-in apps and an app manager for installing more.
- **Setup disk.** Installs or upgrades zOS and walks you through creating an admin account.
- **Updates.** Finds new releases by itself and goes back to the old version if the new one won't start.
- **Networking.** Encrypted, authenticated messages between computers, with root servers that
  vouch for who a computer is.

## Quick start

On a computer with internet access, run:

```
wget run https://github.com/zachbakerdev/zOS/releases/latest/download/install.lua
```

## Building and releasing

`./build.sh` builds everything a release publishes into `dist/`: the system image `zos.zi`, every
app as `apps/<id>.za`, a minified `install.lua` and the manifests computers update from. Pass
`--no-minify` to keep comments and indentation. `./package` builds only `zos.zi`.

Minifying needs LuaSrcDiet. Install it once, from the repository root (this needs Lua 5.1 and
its headers, e.g. Debian's `lua5.1` and `liblua5.1-0-dev`):

```
luarocks --tree lua_modules --lua-version=5.1 install luasrcdiet 1.0.0-2
```

To publish a release, set `VERSION` in `src/.zos/lib/system.lua` to a major.minor.patch version
such as `1.0.0`, then push a tag that matches it.
`.github/workflows/release.yml` runs the tests, builds everything with `./build.sh` and publishes
the release.

```
git tag v1.0.0
git push origin v1.0.0
```

## Installing and upgrading

`install.lua` installs zOS from a `.zi` system image. Build one with `./package`, which writes
`dist/zos.zi`. On a computer with internet access, run:

```
wget run https://raw.githubusercontent.com/zachbakerdev/zOS/main/install.lua
```

That downloads `zos.zi` from the latest release. To use a particular image, pass its path or URL:
`install some/file.zi` or `install https://...`.

To make a setup disk, copy `zos.zi` and `install.lua` to a floppy. Name the script `startup.lua`
and a computer without zOS will run it when it boots with the disk inserted. Keep only one copy
of the script, because two won't fit on a default floppy with the image.

On a computer already running zOS, the optional **Setup Disk** app does all of this from the latest
release. It can also put root servers on the disk, as a separate file, `zos.zr`, next to the image.
It lists the roots the computer trusts, and its own root server if it has one, and you tick the
ones to include. There's one for each top-level domain, so ticking another replaces the first. Roots
are asked for their signed zones, so a root that doesn't answer is left out.

The installer checks `zos.zr` before changing anything, then shows each root's name, domain and
fingerprint to accept or skip. A root whose domain already belongs to another trusted root is
skipped, which keeps that root until you remove it. See
[ZR_FORMAT.md](specs/formats/ZR_FORMAT.md).

The image is fully checked before anything changes. Then, on a computer without zOS, the installer
copies any `/startup` or `/startup.lua` to `/zos-backup/`, installs the system, **turns off disk
boot**, ejects the disk and reboots. The first boot asks for an administrator account and a
computer label.

If zOS is already installed, it offers two options:

- **Upgrade** keeps users, apps and settings. The system is staged like an update, so it's rolled
  back if it doesn't boot. Apps aren't changed, and the first boot updates them from the release.
- **Clean reinstall** deletes all accounts, keys and system settings, and the first boot asks for
  a new admin account. Apps and user files stay.

If an install is damaged, only a clean reinstall is offered, and the startup files are copied to
`/zos-backup/` first.

### Updates

zOS checks GitHub for a new release 30 seconds after booting and every 6 hours after that. A new
version downloads in the background and installs the next time the computer restarts, and the
**Reboot** item on the desktop says when one is waiting. Installed apps with a newer version
in the release are updated at the same time, and App Manager can update them sooner.

Admins can look for one straight away and restart to install it in **Settings → Updates**. Turn
**Automatic updates** off there to only download what you choose. Computers need the HTTP API, and
a server that blocks `github.com` can still upgrade with a setup disk, which also replaces any
update that's waiting.

- **Updates come from GitHub over HTTPS.** That connection is the only proof of where an update
  came from: the size and SHA-256 in the manifest catch a damaged download, not a deliberate
  change. Only versions newer than the installed one are accepted.
- **Installing can't be left half done.** `/startup.lua` swaps the folders by renaming them at the
  start of a boot, and finishes the job at the next boot if it's interrupted.
- **A bad version is undone.** If the new version crashes before it finishes booting, zOS goes back
  to the old one and doesn't download that version again by itself. An admin can still install it
  from Settings. Apps aren't touched until the boot has got that far. An update that boots but has
  bugs later isn't undone: use a setup disk or publish a newer release.

The folders are in `/etc/zos/update/`. Downloaded and finished updates are logged to
`/etc/zos/system.log`.

## Using zOS

### Logging in

- After 3 failed attempts, login locks for 5 seconds, then 10, 20 and so on, up to 5 minutes.
  The lock survives a reboot.
- Admins add, remove and reset users in **Settings → Account → Users**. Everyone can change their
  own password in **Settings → Account**.

### Built-in apps

| app             | what it does |
|-----------------|--------------|
| **Files**       | Browse folders; create, edit, copy, move and delete files and folders. Users who aren't admins stay in their home folder. To run a program, use the Terminal |
| **Terminal**    | Admin only. The CraftOS shell (`exit` returns to the desktop, and Ctrl+T stops the running program). No `bg` or `fg`, since a tab would outlive the session |
| **App Manager** | Admin only. Install and remove apps |

These can be upgraded but not removed, and they're listed on the desktop under **Apps**, which
opens a menu of every other app. The desktop also has **Settings**, for your password and
keys, and **About** shows the version and free space. Admins also manage users, root servers,
updates, secure boot and the computer label there.

### Secure boot

CraftOS normally runs a floppy's `startup` program on boot, which would let anyone skip the
login. zOS turns this off and keeps it off: changing `shell.allow_disk_startup` from the shell
doesn't stick (see [How it works](#how-it-works)).

If you need to boot from a disk, for example a repair disk, an admin can turn secure boot off
in **Settings → Security → Secure boot**. This asks for your password. While it's off, *anyone* with a
floppy can boot their own program and skip the login, so turn it back on afterwards.

The setting is saved in `/etc/zos/config`, and each change is logged to `/etc/zos/system.log`.
Upgrades keep it, and a clean install or reinstall turns secure boot back on.

## Apps

### Optional apps

These apps aren't in the system image, so install them with App Manager. Each lives in its own
folder under `apps/`.

| folder                           | app            | what it does |
|----------------------------------|----------------|--------------|
| [`apps/mail`](apps/mail)         | **Mail**       | Read and send mail through a mail server, see [Mail](#mail) |
| [`apps/mail-server`](apps/mail-server) | **Mail Server** | Hosts mailboxes under a hostname from a root server, see [Mail](#mail) |
| [`apps/root-server`](apps/root-server) | **Root Server** | Signs other computers' keys, see [Root servers](#root-servers) |
| [`apps/fileshare`](apps/fileshare) | **File Share** | Sends files directly between computers you've verified, see [File Share](#file-share) |
| [`apps/storage`](apps/storage) | **Storage** | Searches chests on a wired network and moves items in and out through one chest, see [Storage](#storage) |
| [`apps/setup-disk`](apps/setup-disk) | **Setup Disk** | Erases a floppy, writes the latest release's installer and image to it with any root servers you choose, and labels it `zOS vX.X.X` |

### Making app disks

Copy an app's `.za` file onto a floppy, from a release or from `dist/apps/` after `./build.sh`.
**Install from disk** in the App Manager finds any `.za` file in the top folder of a floppy.

### Installing apps

**Get apps from GitHub** in the App Manager lists every app in the latest release. It marks which
are new and which are updates, and **Update all** installs every update at once. An app that needs
a newer zOS is marked and left as it is until zOS is updated. These apps come from the same place as zOS updates, over HTTPS, and each download is checked
against the list. **Install from URL or Pastebin** installs whatever it's given. An app that's already up to date is never replaced by an older one here.

Only admins can install or remove apps. [APPMAN.md](specs/APPMAN.md) describes the `appman` command
for doing this from the Terminal, and [APPS.md](specs/libs/APPS.md) the library that App Manager uses.

### Writing apps

An app is a folder with a manifest and a main program, installed to `/.zos/apps/<id>/`:

```
/.zos/apps/myapp/app.manifest
/.zos/apps/myapp/main.lua
```

```lua
-- app.manifest
{
  name = "My App",
  description = "Shown at the bottom of the desktop",
  version = "1.0.0",       -- required: major.minor.patch
  author = "you",
  minZos = "1.0.0",        -- optional: the oldest zOS it runs on
  admin = true,            -- optional: only administrators can open it (default false)
}
```

The desktop's **Apps** menu lists every installed app the user can open, by name, and the built-in
apps are listed by name on the desktop itself. `main.lua` gets `...` = `session, app`, and Ctrl+T stops only
the app, never the session. `session` holds `user`, `admin`, `since`, `secretKey` and `publicKey`.
`require` finds the app's own modules first, then the system libraries, such as `ui`, `apps`, `auth`,
`crypto`, `keys`, `net` and `system`. See [apps/README.md](apps/README.md) and
[APP_STANDARDS.md](specs/APP_STANDARDS.md), which says where an app keeps its data.

**User keys.** Every user has an X25519 key pair, created at their first login. The secret key
is encrypted with their password and unlocked into the session at login, so apps can encrypt
data that only that user can read (Mail does this). Changing your own password keeps your key.
If an admin resets someone else's password, the old key is lost and that user gets a new one at
their next login.

**Background services.** If an app has a `service.lua`, zOS starts it at boot and runs it alongside
the session, even while nobody is logged in (Mail Server uses this to receive messages). The service
gets `...` = `app`. Anything it draws goes to a hidden window, and it never sees Ctrl+T. If a service crashes, it stops and the error goes to `/etc/zos/system.log`.
Nothing else is affected.

### Storage

The **Storage** app treats chests on a wired network as one store, with one chest as the way in
and out. Connect each chest to the network with a wired modem, and right-click each modem to turn
it on. Chests, barrels and other inventories all work.

The first time it runs, it asks for two things, and **Settings** changes them later:

- **I/O chest**: where items go in and come out. It defaults to a chest next to the computer. For
  any other chest, choose **Find it by adding an item** and put something in it.
- **Storage chests**: which chests the app may use. Chests and barrels start ticked on the first
  run. Anything added later starts unticked, and the app never touches a chest that isn't ticked.
  **Find a chest** finds one in the list when you change its contents.

A chest next to the computer needs its own wired modem too, because CC: Tweaked can't move items
between a chest attached by its side and one on a network. If that chest is empty, it looks like
every other empty chest, so the app asks you to put an item in it. With no network at all, the
chests touching the computer are used instead.

**Store all** empties the I/O chest into storage. **Recall item** searches by name or item id, then
fills the I/O chest with that item until it's full or there are none left. Take what you need, then
press **Return items to storage**, which puts back what's left of the recalled items. It's the only
way on from that screen. If the app is stopped first, the items stay in the I/O chest until the next
**Store all**.

Settings live in `/etc/storage/` and belong to the computer, so anyone who can log in can use the app
and change them. Items with different NBT, such as damaged or enchanted tools, are listed separately.

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
| `side`      | the modem it arrived on, or nil if it came from this computer |
| `peer`      | `{ id, key, fingerprint, verified, name, root, names }`. `name` is only set if `verified`, and `names` has every name it holds, by root key |

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
  `verified` or `expect` for anything that matters. Pinned keys are in **Settings → Security →
  Encryption keys → Trusted keys**, and forgetting one there lets that computer change key.

### Root servers

A root server is a computer whose key others have decided to trust. It signs a certificate
saying "this key belongs to this name on this computer".

1. **Set one up.** Install the Root Server app on a computer that only admins can log in to, open
   it, and name the server. It announces itself on port 4200.
2. **Trust it.** On each other computer, an admin opens **Settings → Security → Root servers → Add
   root server...**. zOS asks every root server in range to identify itself and lists their names
   and fingerprints. Anyone can announce a root server under any name, so compare the
   fingerprint with the one in **This server** in the Root Server app before accepting. A computer
   trusts one root for each top-level domain, so a root whose domain is taken is refused, and
   every root it trusts has to be reachable or have its domain known already.
3. **Get a certificate.** Choose the server in that list, then **Request a certificate** and pick
   a name. The screen waits while the root server's admin compares fingerprints (**Settings →
   Security → Computer identity** shows yours) and approves it under **Requests**. If you stop waiting,
   the request stays, and asking again picks up the answer.

Certificates last 30 days unless the root server is set otherwise, and computers renew them by
themselves in their last 7 days as long as the root server can be reached, checking shortly after
each boot and then hourly. An expired certificate just means the computer stops being verified.
Each name and each computer can hold one certificate on a root server at a time, so a reinstalled
computer needs its old one revoked first. Its new key is also refused, by the root server and
everyone else who pinned the old one, until an admin there forgets it under **Trusted keys**.
Revoking one in the app stops it renewing and frees the name. That computer can't have the name
back unless the entry is forgotten, but it can ask for a different one. The certificate
keeps working until it expires, because computers don't check back with the root server. Keep the
lifetime short if that matters to you.

With a printer attached, both sides can put this on paper. **Print server identity** in the Root
Server app prints the server's name, top-level domain, computer, port, fingerprint and public key,
for people to check against when they add it. **Settings → Security → Print computer cert** prints
this computer's certificate, in full. Each needs paper and ink for up to two pages.

### Hostnames

A hostname is a name a root server gives out under its own top-level domain, like `zmail.root-a`.
It's an ordinary certificate name, so it's requested, approved and renewed in the same way.

Each root server has one top-level domain, which it asks for at setup and signs with its root key.
It's separate from the server's name, so renaming the server doesn't move anyone's hostname. It can
only change under **Top-level domain** in the Root Server app while no hostname is using it. A root
server only signs hostnames in its own top-level domain, and names without a dot aren't affected.

```lua
local found, err = net.resolve("zmail.root-a")                 -- { host, id, key, root }
local reply, err = net.requestHost("zmail.root-a", 5000, "hi") -- net.request, by hostname
net.isHost(msg.peer, "zmail.root-a")                           -- did this message come from it?
```

Looking up a hostname means finding which trusted root owns the top-level domain, then asking that
root for the certificate. Both answers are signed by the root, so the computer it runs on can only
make a lookup fail, not change the answer. `requestHost` then only sends to a computer holding that
name from that root, so a second root you trust can't answer for another's hostnames even if it
signs the same name. If two trusted roots claim one top-level domain, lookups in it are refused.

A hostname is taken like any certificate: a computer holds one per root, so a computer already
certified under another name has to have that entry revoked in the Root Server app first. It can
then ask for a different name, which the admin approves as usual. To reach a hostname, a computer has to trust its root server, and the root server has to be
in range. A root server on the same computer counts: apps on one computer reach each other with the
same calls, including `net.probe`, without using a modem, so a mail server and a root server can share
a computer. Trust the root in **Settings** as usual.

### Mail

The Mail Server app (port 4202) holds mailboxes for accounts, and the Mail app reads and sends
through it from any other computer. An address is `account@hostname`, like
`alice@zmail.root-a`.

1. **Trust a root server** on the mail server, in **Settings → Security → Root servers**. See
   [Root servers](#root-servers).
2. **Get a hostname.** Open Mail Server, which asks for a name and adds the root's top-level domain.
   The root server's admin compares fingerprints and approves it under **Requests**. Press **Q** to
   come back later, which you'll need if the root server is on this computer. The request is
   remembered, and opening Mail Server again carries on waiting. **C** asks for another name instead.
3. **Make accounts.** Add them under **Accounts**, or leave **New accounts** open so that people
   can use **Create an account** in Mail.
4. **Sign in.** On another computer that trusts the same root server, install Mail and sign in with
   the full address.

Mail for another server is queued and sent by the service. If that server can't be reached, it tries
again after 1 minute, doubling up to every hour, for 3 days, and the queue survives a reboot. Mail
that can't be delivered comes back to the sender from `postmaster@<hostname>`. **Waiting to send**
in Mail Server shows what's queued and why. To exchange mail, both servers have to trust both
roots, because each one looks the other up and checks that a message comes from the server named
in its address. Nothing is relayed through a third server.

Writing to someone on another server takes their public key, which your server asks for and
remembers. The first message to an address needs that server to be up. After that, mail can be
queued while it's away.

- **Message bodies are encrypted on the server.** Every account has an X25519 key pair, made by the
  mail server with the account. The public key stays readable. The secret key is kept locked with
  the password, and is downloaded and unlocked by Mail at sign-in, or saved as a file with
  **Download key**. Mail encrypts each body under a new key, which it seals to each recipient's
  public key, and decrypts it after reading it from the server. That covers mailboxes, the outgoing
  queue and bounces, which is why a bounce doesn't quote the message.
- **Addresses, subjects and dates aren't encrypted,** because servers need them or show them in the
  inbox. Anyone who can log in to the mail server can read those.
- **The server still sees your password when you sign in,** so this protects stored mail, not mail
  from a server that's been altered to record passwords or hand out the wrong public key. A stolen
  server's key files can be attacked by guessing passwords, so use a long one.
- **Only the account's owner can keep its mail.** Changing your password in Mail re-locks the same
  key, and needs the current password. An admin's **Reset password** can't open the key, so it makes
  a new one, and mail already in the mailbox stays unreadable.
- **A server vouches for its own addresses.** The hostname in a sender's address is proven. The
  account name in front of it is only as honest as that server.
- **Passwords only travel when signing in or changing them,** and are stored salted and hashed.
  Mail keeps a token and your unlocked mail key instead, sealed with your zOS user's key, and the
  token lasts 30 days. Changing a password signs out every other
  computer. Five wrong passwords lock an account for a minute.
- **Limits.** 8 KB per message, 8 recipients, 64 messages per mailbox, 64 accounts and 32 queued
  deliveries. A full mailbox makes other servers keep trying.

Revoking a hostname stops lookups of it straight away. A computer that holds the certificate can
still prove the name to anyone it reaches until the certificate expires, as with any revoked
certificate (see [Root servers](#root-servers)).

### File Share

File Share is an optional app (port 4201) that lets computers download files straight from each
other over their modems. Nothing sits in between, and its service answers even while nobody is
logged in.

1. **Verify each other.** Under **Computers → Add a computer**, pick a computer that was found or
   enter its id. Compare the fingerprint shown with **This computer** on the other screen, and
   accept only if they match exactly. Then do the same on the other computer: neither serves a
   computer it hasn't added.
2. **Share files.** Under **Shared files → Share a file**, enter a path. Single files only, and
   nothing from `/etc`, `/.zos`, `/rom` or `/startup.lua`, which hold passwords and keys.
3. **Download.** Under **Computers**, pick the computer, then **Browse files**. Files are saved
   to `/home/<user>/downloads/`, and never over an existing file.

The full public key is stored when you accept, and every request and answer is checked against
it, so a computer that changes key has to be verified again. Forgetting a computer stops it at
once, even partway through a download.

File lists and contents have their own encryption on top of `net`. Each connection makes a new
key from two ephemeral X25519 keys, signed by the sending computer's verified identity key, and
each chunk is sealed with ChaCha20 and HMAC-SHA256. See `apps/fileshare/share.lua` for the
protocol. Files are only encrypted on their way between computers: they're ordinary files on both
disks.

The lists in `/etc/fileshare/` belong to the computer, not to a user, so anyone who can log in
can change what it shares and who it trusts. Whoever verifies a computer can download everything
that's shared, since there are no per-file permissions. The file is held in memory at both ends
during a download.

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

### Boot

```
CraftOS bios -> shell -> /startup.lua -> /.zos/boot.lua -> login -> desktop
```

- **Disk boot stays off.** CraftOS decides whether to run a floppy's `startup` *before* it runs
  `/startup.lua`, based on the `shell.allow_disk_startup` setting. zOS sets it to `false` in
  `/.settings` at install time, on every boot, and before every reboot or shutdown.
- **`/startup.lua` never returns.** It replaces `os.pullEvent` with `os.pullEventRaw` so Ctrl+T
  can't stop it, then runs `/.zos/boot.lua` inside `pcall`. If boot crashes, it shows a recovery
  prompt, where an admin login opens a recovery shell, and then reboots. It never falls through
  to an open shell.
- **`/.zos/boot.lua`** secures the boot settings, loads the libraries, adds `/.zos/bin` to the
  shell path and scans the installed apps, with a progress bar. It then loops login → desktop →
  logout forever. An error anywhere logs you out instead of crashing the computer.

### Accounts

- Accounts are stored in `/etc/zos/users.db`. Each password is stored as a 200-round SHA-256 hash
  with a random 16-byte salt, never in plain text.
- The login lock is stored in `/etc/zos/LOCKOUT`, which is why rebooting doesn't clear it.

### Files on the computer

| path               | contents |
|--------------------|----------|
| `/startup.lua`     | bootstrap |
| `/.zos/`           | the system (replaced on upgrade) |
| `/.zos/apps/`      | apps, which are kept on upgrade |
| `/etc/zos/`        | accounts, keys, network identity, config, log, updates in progress |
| `/etc/<id>/`       | each app's own data |
| `/home/<user>/`    | users' files |
| `/zos-backup/`     | your old startup file, if you had one |

Upgrades only replace `/startup.lua` and the system in `/.zos/`.

## Project layout

```
install.lua               the installer
package                   builds the system image, dist/zos.zi
build.sh                  builds everything a release publishes into dist/
tools/
  make_apps.py            packs each app in apps/ into a .za file
  make_update.py          builds the image, apps, manifests and minified installer
  minify_lua.py           minifies Lua with LuaSrcDiet
apps/                     every app, including the built-in ones
specs/                    how zOS is meant to work, see Specifications
tests/                    off-game tests, run from the repository root with luajit or lua5.2
src/                      mirrors the target computer
  startup.lua             -> /startup.lua
  .zos/                   -> /.zos
    boot.lua              boot stages and the session loop
    bin/                  shell programs, such as appman
    lib/                  system libraries
    sys/                  login, desktop, settings, setup and recovery screens
```

## Specifications

The specifications describe how zOS is meant to work, not how the current code works. Where they
differ, they are the target.

| specification | what it covers |
|---------------|----------------|
| [ZOS.md](specs/ZOS.md) | The system as a whole: layout, boot, users, updates and the security model |
| [APP_STANDARDS.md](specs/APP_STANDARDS.md) | Where apps keep their files |
| [ZA_FORMAT.md](specs/formats/ZA_FORMAT.md) | The .za app image format |
| [ZI_FORMAT.md](specs/formats/ZI_FORMAT.md) | The .zi system image format |
| [ZR_FORMAT.md](specs/formats/ZR_FORMAT.md) | The .zr file of root servers on a setup disk |
| [APPMAN.md](specs/APPMAN.md) | The `appman` command |
| [specs/libs/](specs/libs) | One specification per system library, listed in [ZOS.md](specs/ZOS.md) |

## Limitations

- **Users aren't fully separated.** ComputerCraft has no file permissions. Users who aren't admins
  can't open the Terminal, and Files keeps them in their home folder, but that's enforced by the
  apps, not by the computer. Any app they can open can reach every file, and File Share lets them
  share another user's files. Only give accounts to people you trust. Data encrypted with a user's
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
- **Updates trust GitHub.** Releases aren't signed, so anyone who can publish a release on this
  repository can run code on every computer with automatic updates on, including reading its
  accounts and keys.
- **The world files are always a way in.** Anyone with access to the world or server files can
  get around zOS.
- **A broken install can't be fixed from a disk.** If `/.zos` is damaged and recovery can't load,
  the computer keeps rebooting, and because disk boot is off, a setup disk can't fix it. Repair
  the files in the world save (`computercraft/computer/<id>/`), or delete `.settings` there to
  turn disk boot back on.

## Uninstalling

From the Terminal:

```
delete /startup.lua /.zos /etc/zos /home
set shell.allow_disk_startup true
```

Then move your old startup file back from `/zos-backup/` if you had one.
