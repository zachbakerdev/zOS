# zOS System Library Specification

`require("system")` holds the version of zOS, the system log, system settings and the boot policy. Where these fit into the system is described in [ZOS.md](../ZOS.md).

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Constants

| Name             | Value                                  |
| ---------------- | -------------------------------------- |
| `system.VERSION` | The version of zOS, such as `"3.0.0"`  |
| `system.ROOT`    | `/.zos`, the system's code             |
| `system.DATA`    | `/etc/zos`, the system's data          |

## The log

`system.log(text)` adds a line to `/etc/zos/system.log`, as `[<seconds since 1970>] <text>`. It raises no error if the file can't be written, so it's safe to call while handling a failure.

Once the log is over 32 KB, the next call keeps only the newest 16 KB.

Anything that changes the system on someone's behalf SHOULD log who did it. Passwords and keys MUST NOT be logged.

## Settings

Settings are a table in `/etc/zos/config`.

| Method                       | Returns                                                  |
| ---------------------------- | -------------------------------------------------------- |
| `system.config()`            | Every setting. An empty table if none have been saved    |
| `system.setConfig(changes)`  | Nothing. Saves these fields, and leaves the others alone |

| Setting      | Default | Meaning                                           |
| ------------ | ------- | ------------------------------------------------- |
| `secureBoot` | `true`  | Whether the computer refuses to boot from floppies |
| `autoUpdate` | `true`  | Whether new versions of zOS download by themselves |

A setting that has never been saved is nil, so code MUST compare with `false` to read one of these, as in `config.autoUpdate ~= false`.

## Boot policy

CraftOS reads `shell.allow_disk_startup` before it runs `/startup.lua`, so the setting has to be correct on disk before the computer next starts. A shell can change it at any time, so zOS writes it again at every boot and before every reboot or shutdown.

| Method                            | Returns                                                         |
| --------------------------------- | --------------------------------------------------------------- |
| `system.secureBoot()`             | Whether secure boot is on                                       |
| `system.setSecureBoot(on, user)`  | Nothing. Saves the setting, applies it, and logs that `user` did it |
| `system.applyBootPolicy()`        | Nothing. Saves `shell.allow_disk_startup` in `/.settings`       |
| `system.reboot()`                 | Doesn't return. Applies the boot policy and reboots             |
| `system.shutdown()`               | Doesn't return. Applies the boot policy and shuts down          |

System code MUST use `system.reboot` and `system.shutdown` rather than `os.reboot` and `os.shutdown`. `setSecureBoot` doesn't check who is calling, so a caller acting for a user MUST check `session.admin` and the user's password first.
