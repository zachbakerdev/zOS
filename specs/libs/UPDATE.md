# zOS Update Library Specification

`require("update")` finds new versions of zOS in GitHub releases, checks them and stores them for the next boot. It also lists the apps in the latest release. The process as a whole is described in [Updates](../ZOS.md#updates), and `/startup.lua` does the swap at boot.

Like [ZOS.md](../ZOS.md), this document describes how zOS is meant to work.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

Methods that can fail return nil and a message that can be shown to the user, unless noted otherwise.

## Permissions

The library doesn't check who is calling. A caller acting for a user MUST check `session.admin` before calling `download` or `discard`.

## Releases

`update.RELEASES` is the address of the GitHub releases, and a release is found by its tag, `v<version>`.

| File                   | Contents                                       |
| ---------------------- | ---------------------------------------------- |
| `zos-update.manifest`  | The version, size and SHA-256 of `zos.zi`      |
| `zos.zi`               | The system, in the [.zi format](../formats/ZI_FORMAT.md) |
| `zos-apps.manifest`    | The version, size and SHA-256 of each app      |
| `<id>.za`              | Each app, in the [.za format](../formats/ZA_FORMAT.md) |

Manifests are plain text, read as data. Each starts with a header line and MUST end with an `end` line, so that a download that was cut off can't look complete.

```
zos-update 1
version=1.0.0
size=86412
sha256=<64 hex characters>
end
```

```
zos-apps 1
release=1.0
app=<id>\t<version>\t<size>\t<sha256>\t<minZos>\t<name>\t<description>
end
```

There's one `app=` line for each app, with its fields separated by tabs. `minZos` and `description` MAY be empty.

## System updates

| Method                    | Returns                                                         |
| ------------------------- | --------------------------------------------------------------- |
| `update.check()`          | `{ version, size, sha256 }` if there's a newer version, or false if not |
| `update.download(info)`   | True. Downloads, checks and stages the version from `check`     |
| `update.stagedVersion()`  | The version waiting for the next boot, or nil. No error message |
| `update.failedVersion()`  | The version that failed to boot and was rolled back, or nil. No error message |
| `update.discard()`        | Nothing. Deletes what's staged                                  |

`check` compares versions with `apps.compareVersions`, so only a version newer than the installed one is offered.

`download` works in this order, and a failure before step 5 leaves anything already staged in place:

1. Downloads `zos.zi`.
2. Checks its size and SHA-256 against `info`.
3. Parses it with `image.parse`, and checks that it has `/.zos/boot.lua` and `/startup.lua`.
4. Checks that it fits in the free space.
5. Deletes anything already staged, then writes the system to `/etc/zos/update/new/` and `/startup.lua` to `/etc/zos/update/startup.new`, reading back each file. Apps in the image are skipped, because they're updated at the finish stage.
6. Forgets that this version failed, if it did, since someone has chosen to try it again.
7. Writes the `ready` marker, last of all, so that a boot never sees half an update.

Nothing under `/.zos` is touched.

## Apps in the release

| Method                       | Returns                                                     |
| ---------------------------- | ----------------------------------------------------------- |
| `update.checkApps()`         | Every app in the release: updates, then new apps, then installed apps, then apps this zOS is too old for |
| `update.downloadApp(entry)`  | A package for `apps.install`, from an entry of `checkApps`  |

`checkApps` fails if the list can't be downloaded, or if any of it is damaged or cut off.

| Field         | Type    | Contents                                                     |
| ------------- | ------- | ------------------------------------------------------------ |
| `id`          | string  | The app's id                                                 |
| `name`        | string  | Its display name                                             |
| `description` | string  | Its description                                              |
| `version`     | string  | The version in the release                                   |
| `size`        | number  | The size of the image                                        |
| `sha256`      | string  | The SHA-256 of the image                                     |
| `minZos`      | string  | The oldest zOS it runs on, or `nil`                          |
| `release`     | string  | The release's version                                        |
| `current`     | string  | The installed version, or `nil` if it isn't installed        |
| `newer`       | boolean | Whether this is an update to an installed app                |
| `supported`   | boolean | Whether this zOS is new enough                               |

`downloadApp` rejects a download whose size or hash differs from the list, and one whose id or version doesn't match the entry.

## Finishing an update

These methods belong to the system, and apps MUST NOT call them.

| Method                 | Returns                                                                |
| ---------------------- | ---------------------------------------------------------------------- |
| `update.finish()`      | Nothing. The boot sequence calls it once the new version has got far enough to count as good |
| `update.finishApps()`  | Nothing. Does any app updates that are due                             |
| `update.tick()`        | Nothing. One round of the update service                               |
| `update.service()`     | Doesn't return. The update service, which runs as `zos:update`         |

If this boot is the trial of an update, `finish` replaces `/startup.lua`, marks the app updates as due, and deletes the old version. It then calls `finishApps`. Apps come last, so that trouble with them can't roll the system back.

`finishApps` upgrades each installed app that has a newer version in the latest release, and installs any protected app that's missing. It doesn't install other new apps or install older versions. If any of this fails, for example because the computer is offline, the updates stay due and are tried again by the service.

`tick` calls `finishApps`. Unless automatic updates are off, it then looks for a new version and downloads it, skipping a version that's already staged or that failed. Failures are logged.

The service runs `tick` 30 seconds after boot and every 6 hours after that.

## Storage

Everything is in `/etc/zos/update/`, and these paths MUST match `/startup.lua`.

| Path          | Holds                                                               |
| ------------- | ------------------------------------------------------------------- |
| `new/`        | The staged system                                                   |
| `startup.new` | The staged `/startup.lua`                                           |
| `ready`       | The staged version. Written last                                    |
| `old/`        | The previous system, during a trial                                 |
| `trial`       | The version on trial                                                |
| `rollback`    | The version being rolled back, so that a rollback survives a reboot |
| `failed`      | The version that failed to boot                                     |
| `apps-due`    | Marks that app updates haven't all been done                        |

## Security

The HTTPS connection to GitHub is the only proof of where an update came from, so whatever GitHub serves for this repository runs as system code. The sizes and hashes catch damaged downloads, not deliberate changes. See [Security](APPS.md#security) for how this compares with other sources of apps.
