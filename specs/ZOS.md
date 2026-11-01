# zOS Specification

zOS is a small operating system for CC: Tweaked computers, turtles and pocket computers. It adds secure boot, user accounts, a desktop, apps, automatic updates and encrypted networking on top of CraftOS.

This document describes how zOS is meant to work, not how the current code works. Where they differ, this document is the target. For example, it uses `/.zos` where the code still uses `/zos`.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

Related specifications:

- [ZI_FORMAT.md](formats/ZI_FORMAT.md): the .zi system image format.
- [ZR_FORMAT.md](formats/ZR_FORMAT.md): the .zr file of root servers on a setup disk.
- [ZA_FORMAT.md](formats/ZA_FORMAT.md): the .za app image format.
- [APP_STANDARDS.md](APP_STANDARDS.md): where apps keep their files.
- [APPMAN.md](APPMAN.md): the `appman` command.

Each system library has its own specification:

| Library    | Specification                    | Provides                                                   |
| ---------- | -------------------------------- | ---------------------------------------------------------- |
| `apps`     | [APPS.md](libs/APPS.md)          | Installing, removing and running apps                      |
| `auth`     | [AUTH.md](libs/AUTH.md)          | Accounts, logins and sessions                              |
| `crypto`   | [CRYPTO.md](libs/CRYPTO.md)      | Hashing, encryption, key agreement and signatures          |
| `image`    | [IMAGE.md](libs/IMAGE.md)        | Reading .zi system images                                  |
| `keys`     | [KEYS.md](libs/KEYS.md)          | Users' key pairs and pinned keys                           |
| `net`      | [NET.md](libs/NET.md)            | Encrypted messages between computers                       |
| `printer`  | [PRINTER.md](libs/PRINTER.md)    | Printing text                                              |
| `services` | [SERVICES.md](libs/SERVICES.md)  | Background services                                        |
| `system`   | [SYSTEM.md](libs/SYSTEM.md)      | The version, log, settings and boot policy                 |
| `trust`    | [TRUST.md](libs/TRUST.md)        | The computer's identity, root servers, certificates, names |
| `ui`       | [UI.md](libs/UI.md)              | The terminal toolkit                                       |
| `update`   | [UPDATE.md](libs/UPDATE.md)      | Finding and staging updates, and listing release apps      |
| `util`     | [UTIL.md](libs/UTIL.md)          | Helpers for files, tables, downloads and waiting           |

## File system layout

| Path                           | Holds                                                   |
| ------------------------------ | ------------------------------------------------------- |
| `/startup.lua`                 | The bootstrap, which CraftOS runs at boot               |
| `/.zos/boot.lua`               | The boot sequence                                       |
| `/.zos/lib/`                   | System libraries                                        |
| `/.zos/sys/`                   | System screens: setup, login, desktop, settings and recovery |
| `/.zos/bin/`                   | Shell programs, such as `appman`                        |
| `/.zos/apps/<id>/`             | Installed apps                                          |
| `/etc/zos/`                    | System data                                             |
| `/etc/<id>/`                   | Each app's global data                                  |
| `/home/<user>/`                | Each user's files                                       |
| `/home/<user>/.config/<id>/`   | Each app's config for that user                         |

`/.zos` holds only code, apart from `/.zos/apps`, and can be replaced by an update at any time. Data MUST NOT be kept there.

### System data

| Path                     | Holds                                                |
| ------------------------ | ---------------------------------------------------- |
| `/etc/zos/config`        | System settings, such as secure boot                 |
| `/etc/zos/system.log`    | The system log                                       |
| `/etc/zos/users.db`      | User accounts                                        |
| `/etc/zos/LOCKOUT`       | The login lock, which survives a reboot              |
| `/etc/zos/keys/`         | Users' key pairs                                     |
| `/etc/zos/known_keys`    | Pinned remote keys                                   |
| `/etc/zos/net/`          | The computer's identity, trusted roots, certificates |
| `/etc/zos/update/`       | Updates in progress                                  |

## Boot

### Bootstrap

`/startup.lua` MUST NOT return, because that would leave the user at an unauthenticated shell. It MUST block Ctrl+T by replacing `os.pullEvent` with `os.pullEventRaw` before doing anything else. It then:

1. Applies any staged update, as described in [Updates](#updates).
2. Runs `/.zos/boot.lua`.
3. If the boot crashes during a trial of an update, rolls the update back and reboots.
4. Otherwise, shows the error and offers [recovery](#recovery).

### Boot sequence

`/.zos/boot.lua` runs these stages in order, showing a splash screen:

1. Apply the boot policy.
2. Load the system libraries.
3. Start networking. A failure here is logged and MUST NOT stop the boot.
4. Finish any update.
5. Start app services and the update service.

It then runs the session loop alongside the services, so services keep running while nobody is logged in. A session is one cycle of login, desktop and logout. If a session crashes, the error is logged, the user is logged out and the loop continues.

### Recovery

If zOS can't start, an administrator MAY log in at a plain prompt to get a recovery shell. Failed attempts count towards the login lock. If there are no users, or the login is locked, the computer reboots instead.

### Secure boot

CraftOS normally runs a floppy's `startup` program at boot, which would skip the login. With secure boot on, zOS sets `shell.allow_disk_startup` to false. It MUST apply this at every boot and before every reboot or shutdown, so changing the setting from a shell doesn't last.

Secure boot is on by default. An admin MAY turn it off in Settings after entering their password. Each change is logged.

## Users

Each account is a user or an administrator. The first account is created during setup and is an administrator. Only administrators can manage users, install or remove apps, change system settings, and open apps whose manifest sets `admin`. Files keeps other users in their home folder.

- Passwords MUST be at least 8 characters.
- Passwords MUST be stored only as salted, iterated hashes.
- After 3 failed logins, login locks for 5 seconds, then 10, 20 and so on, up to 5 minutes.

Each user has an X25519 key pair, created at their first login. The secret key is encrypted with their password and unlocked into the session at login. Changing your own password keeps the key. If an administrator resets someone's password, the old key is lost and the user gets a new one at their next login.

A session is a table with `user`, `admin`, `since`, `secretKey`, `publicKey` and, if an old key couldn't be opened, `keyReplaced`. See [AUTH.md](libs/AUTH.md).

## Apps

Apps are distributed as .za images and installed to `/.zos/apps/<id>/`. See [ZA_FORMAT.md](formats/ZA_FORMAT.md), [APP_STANDARDS.md](APP_STANDARDS.md) and [APPS.md](libs/APPS.md).

An app contains:

| File           | Purpose                                                              |
| -------------- | -------------------------------------------------------------------- |
| `app.manifest` | Required. The app's name, version and other details                  |
| `main.lua`     | Required. Runs from the desktop with `...` = `session, app`          |
| `service.lua`  | Optional. Starts at boot with `...` = `app` and runs in the background |

`require` finds the app's own modules first, then the system libraries. Apps with a lower `priority` are listed and started first. Apps with `admin` set are hidden from users who aren't administrators and refuse to open for them. Their services still run.

App Manager, Terminal and Files are built-in apps. App Manager, Terminal, Setup Disk, Mail Server and Root Server are admin only. They can be upgraded but not removed. `/.zos/lib/builtin.lua` is the only list of them, and `./package` copies each one from `apps/<id>/` into the system image.

### Services

A service is a coroutine that runs alongside the session. Services get their turn on every event, so a service MUST NOT block for long. Anything a service draws goes to a hidden window. A service that crashes is stopped and logged, and doesn't affect the session or other services.

## Installation

zOS is installed by `install.lua`, from a .zi image next to it, a path or URL it's given, or the latest release. On a setup disk it's named `startup.lua`, so that it runs by itself when a computer without zOS boots with the disk inserted. Setup MUST load and check the whole image before changing anything on the computer. It then offers the modes below as a menu that works like the desktop's, with a description of the selected mode at the bottom of the screen.

| Mode            | Result                                                         |
| --------------- | -------------------------------------------------------------- |
| Install         | Backs up startup files, installs zOS                           |
| Upgrade         | Stages the system as an update, keeps users, apps and settings |
| Clean reinstall | Deletes all accounts, keys and settings, installs zOS          |

The first boot creates the administrator after an install or clean reinstall. Each thing it asks for has a label and a colon, with a `>` before the input on the next line. Install and clean reinstall turn secure boot on, and upgrades keep the setting. Setup replaces any waiting update, then ejects the disk and reboots. Ctrl+T MUST NOT be able to interrupt setup once it has started changing files.

System files are distributed as a .zi image. See [ZI_FORMAT.md](formats/ZI_FORMAT.md).

A setup disk MAY have a .zr file next to the image, listing root servers to trust. Setup MUST check it before changing anything, and a person MUST accept each root after choosing a mode. See [ZR_FORMAT.md](formats/ZR_FORMAT.md).

## Updates

zOS looks for a release 30 seconds after boot and every 6 hours after that. Each release has a .zi image of the system, a .za image of each app, and manifests giving the version, size and SHA-256 of each one. Manifests MUST end with an `end` line, so that a cut-off one isn't accepted.

Only versions newer than the installed one are accepted. A version that failed to boot isn't downloaded again automatically, but an administrator MAY still install it from Settings.

1. **Download.** The image is checked against the manifest and validated.
2. **Stage.** The files are stored in `/etc/zos/update/new/`. The `ready` marker is written last, so a boot never sees half an update. `/.zos` isn't touched.
3. **Apply.** At the next boot, `/startup.lua` swaps the folders before any zOS code loads. Every step is a rename, so an interrupted swap finishes at the following boot.
4. **Trial.** The old version is kept until the new one proves it can boot. If it crashes first, `/startup.lua` restores the old version and records the failed one.
5. **Finish.** Once the boot has reached the finish stage, the old version is deleted and installed apps are updated. App updates that can't be done are tried again by the update service until they work.

Apps MUST NOT be changed before the finish stage, so a rollback doesn't leave them ahead of the system. An update that boots but has bugs later isn't rolled back.

The HTTPS connection to GitHub is the only proof of where an update came from. The size and hash catch damaged downloads, not deliberate changes.

## Networking

Networking gives apps encrypted, authenticated messages over modems through `require("net")`, with no setup. See [NET.md](libs/NET.md) and [TRUST.md](libs/TRUST.md). Packets that fail any check MUST be dropped silently. Payloads MUST be decoded as data and never run, because packets come from anyone.

Each computer has an Ed25519 identity key, owned by the computer and not a user, because networking runs while nobody is logged in. A peer is one of:

- **Verified:** it shows a current certificate from a trusted root server for the computer id it claims.
- **Pinned:** it has no certificate, so its key is pinned by computer id the first time it's seen, and it's refused if the key changes.

A certificate only counts for its own computer id, because computer ids can be faked.

### Root servers

A root server is a computer whose key another computer has chosen to trust. It signs certificates saying that a key belongs to a name on a computer. Each root owns one top-level domain, set in a zone record it signs, and only signs hostnames of the form `<label>.<tld>` in that domain.

## Security model

zOS protects against people at the keyboard who don't have an account. It doesn't protect against the code it runs:

- **Apps aren't sandboxed.** All code runs with full access to `fs` and every other API, so installing an app or image means trusting it completely. See the Security sections of the format specifications.
- **Files aren't private.** CraftOS has no file permissions, so a user with Terminal can read other users' files. Data that must stay private SHOULD be encrypted with the user's key.
- **Physical access wins.** Anyone who can break the computer or reach the world save can bypass all of this.
