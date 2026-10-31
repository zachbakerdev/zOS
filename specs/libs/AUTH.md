# zOS Auth Library Specification

`require("auth")` manages user accounts, checks logins and builds sessions. The rules for accounts are described in [Users](../ZOS.md#users), and users' keys in [KEYS.md](KEYS.md).

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

Methods that can fail return nil and a message that can be shown to the user, unless noted otherwise.

## Permissions

The library doesn't check who is calling. A caller acting for a user MUST check `session.admin` before calling `create`, `resetPassword` or `remove`, and SHOULD log what it did with `system.log`. Only the login screen and setup SHOULD call `attempt`, `session` and `reset`.

Files aren't private, so these checks keep honest users honest and don't stop an app. See the [Security model](../ZOS.md#security-model).

## Names and passwords

| Name                 | Value                              |
| -------------------- | ---------------------------------- |
| `auth.MIN_PASSWORD`  | 8, the fewest characters in a password |
| `auth.MAX_NAME`      | 16, the most characters in a name  |

| Method                    | Returns                                            |
| ------------------------- | -------------------------------------------------- |
| `auth.badName(name)`      | Why this can't be a user name, or nil if it can    |
| `auth.badPassword(password)` | Why this can't be a password, or nil if it can  |

A name is lowercase letters, digits, `-` or `_`, starting with a letter. It's also a folder name, in `/home/<name>/`, so it MUST stay this plain.

## Accounts

| Method                            | Returns                                                     |
| --------------------------------- | ----------------------------------------------------------- |
| `auth.count()`                    | How many accounts exist                                     |
| `auth.exists(name)`               | Whether the account exists                                  |
| `auth.isAdmin(name)`              | Whether the account exists and is an administrator          |
| `auth.list()`                     | Every account as `{ name, admin }`, sorted by name          |
| `auth.create(name, password, admin)` | True. Makes the account and `/home/<name>/`              |
| `auth.remove(name)`               | True. Deletes the account and its key, but not its files    |
| `auth.reset()`                    | Nothing. Deletes every account and the login lock           |

`remove` refuses to delete the last administrator. `reset` is for a clean reinstall, and is normally followed by `keys.reset`.

`create` doesn't make a key pair. `auth.session` does that at the user's first login.

### Passwords

| Method                                  | Returns                                                     |
| --------------------------------------- | ----------------------------------------------------------- |
| `auth.verify(name, password)`           | Whether this is the user's password                         |
| `auth.changePassword(name, old, new)`   | True. Changes the user's own password and keeps their key   |
| `auth.resetPassword(name, new)`         | True. An administrator's reset, which deletes the user's key |

`password` MUST be a string. `verify` does the same work for a name that doesn't exist, so the time it takes doesn't show which names are real. It doesn't count towards the login lock.

`changePassword` needs the current password, because it's what opens the key. The key is locked with the new password before the account changes, and the old lock is kept until the account is saved, so a crash at any point leaves a key that one of the two passwords can open. See `keys.rewrap`.

`resetPassword` can't open the old key, so it's lost, and with it anything encrypted to that key. The user gets a new key at their next login.

## Logging in

| Method                         | Returns                                                         |
| ------------------------------ | --------------------------------------------------------------- |
| `auth.lockRemaining()`         | The milliseconds until login opens again, or 0                  |
| `auth.attempt(name, password)` | True if the login is allowed and correct                        |
| `auth.session(name, password)` | A session. Only call this after `attempt` has succeeded         |

`attempt` refuses while the login is locked, without checking the password. Otherwise, a wrong password counts as a failure and is logged, and a correct one clears the lock.

After 3 failed logins, login locks for 5 seconds, then 10, 20 and so on, up to 5 minutes. The state is kept in `/etc/zos/LOCKOUT`, so a reboot doesn't clear it.

### Sessions

| Field         | Type    | Contents                                                       |
| ------------- | ------- | -------------------------------------------------------------- |
| `user`        | string  | The user's name                                                |
| `admin`       | boolean | Whether they're an administrator                               |
| `since`       | number  | When they logged in, in milliseconds since 1970                |
| `secretKey`   | string  | Their X25519 secret key, as raw bytes                          |
| `publicKey`   | string  | Their X25519 public key, as raw bytes                          |
| `keyReplaced` | string  | Where a key that couldn't be opened was moved to, or nil        |

`auth.session` also adds the password to the random number generator and makes `/home/<name>/` if it's missing.

If the user has no key, as after an administrator's reset, a new one is made. If they have a key that the correct password can't open, it's moved aside with `keys.setAside` rather than overwritten, a new one is made, and `keyReplaced` says where the old one went. The caller MUST tell the user, because what was encrypted to the old key can't be read for now.

A session MUST NOT be stored or placed where another program can reach it, because `secretKey` opens everything encrypted for that user.

## Storage

Accounts are in `/etc/zos/users.db`, as a table of (name -> `{ salt, hash, admin }`). `salt` is 16 random bytes and `hash` is `crypto.passwordKey` of the password, both in hex. Passwords MUST NOT be stored in any other form.
