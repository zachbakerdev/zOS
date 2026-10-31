# zOS Keys Library Specification

`require("keys")` stores each user's X25519 key pair, and the public keys this computer has pinned for remote addresses. The algorithms are described in [CRYPTO.md](CRYPTO.md).

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## User keys

Each user's secret key is encrypted with their password, and logging in unlocks it into `session.secretKey`, with the public key in `session.publicKey`. Both are raw bytes. Services don't have a session, so they can't reach a user's secret key.

| Method                 | Returns                                          |
| ---------------------- | ------------------------------------------------ |
| `keys.publicKey(user)` | The user's public key on this computer, or nil   |
| `keys.hasKey(user)`    | Whether the user has a key                       |

The methods below belong to the system, and apps MUST NOT call them. `auth` uses them to keep keys and passwords in step. See [AUTH.md](AUTH.md).

| Method                                       | Returns                                                     |
| -------------------------------------------- | ----------------------------------------------------------- |
| `keys.create(user, password)`                | A new secret key and public key, replacing any key they had |
| `keys.unlock(user, password)`                | The secret key and public key, or nil if the password is wrong |
| `keys.rewrap(user, oldPassword, newPassword)` | True, or false and a reason. Locks the same key with a new password |
| `keys.settle(user)`                          | Nothing. Deletes the old lock left by `rewrap`              |
| `keys.setAside(user)`                        | The path a key that can't be opened was moved to            |
| `keys.forget(user)`                          | Nothing. Deletes the user's key                             |
| `keys.reset()`                               | Nothing. Deletes every user's key, every pin and the computer's identity |

### Changing a password

A password change writes two files, the key and the account, so a crash between them must not lose the key.

1. `rewrap` locks the key with the new password, and keeps the old lock beside it.
2. The caller saves the new password.
3. `settle` deletes the old lock.

If the computer stops between these steps, the key can be opened with either password. `unlock` then keeps whichever lock worked and deletes the other, so the first successful login finishes the job. If the password can't be saved, the caller MUST call `unlock` with the old password to put things back.

### Damaged keys

A key that can't be opened MUST NOT be overwritten, because it may be rescued by hand. `setAside` renames it to `/etc/zos/keys/<user>.<time>.damaged`.

### Storage

A key is in `/etc/zos/keys/<user>`, saved with `util.writeTable`:

| Field      | Contents                                                       |
| ---------- | -------------------------------------------------------------- |
| `public`   | The public key, in hex                                         |
| `locked`   | The secret key, from `crypto.lock` with the user's password    |
| `previous` | The lock from the old password, only during a password change  |

## Pinned keys

A pin remembers the public key seen at an address, so that a change can be noticed. Pins are in `/etc/zos/known_keys`, and every app on the computer shares them.

| Method                              | Returns                                            |
| ----------------------------------- | -------------------------------------------------- |
| `keys.known(address)`               | The public key pinned for an address, or nil       |
| `keys.remember(address, publicKey)` | Nothing. Pins a key                                |
| `keys.forgetKnown(address)`         | Nothing. Removes a pin                             |
| `keys.knownList()`                  | Every pin as `{ address, fingerprint }`, sorted by address |

Keys are raw bytes. An app's addresses SHOULD start with its id, as in `notes:alice`. The `net:` prefix belongs to the system, which pins computers as `net:<computer id>`. See [Trust](TRUST.md#trust).

A pin is only as good as the first time the key was seen. Apps that need more SHOULD show `crypto.fingerprint` for people to compare, or use a certificate.

## Encrypting a user's data

Derive a key for the app, so that each app's data is encrypted under a different key. The file goes in the user's config folder, as described in [APP_STANDARDS.md](../APP_STANDARDS.md). This goes in an app's `main.lua`.

```lua
local session, app = ...

local crypto = require("crypto")
local util = require("util")

local FILE = "/home/" .. session.user .. "/.config/" .. app.id .. "/secrets"

local function appKey()
    return crypto.hmac(session.secretKey, "zos-app-key|" .. app.id)
end

local function save(text)
    util.writeTable(FILE, crypto.seal(appKey(), text))
end

local function load()
    local box = util.readTable(FILE)
    return box and crypto.open(appKey(), box)
end
```

If an administrator resets the user's password, the old key is lost and this data can't be read again. Apps MUST handle `load` returning nil.

## Encrypting for another user

The sender needs only the recipient's public key, from `keys.publicKey` or from wherever the app gets it. Only the recipient's secret key can open the box.

```lua
local box = crypto.sealTo(recipientPublicKey, "Meet at the mine")

-- On the recipient's computer:
local text = crypto.openSealed(session.secretKey, session.publicKey, box)
if not text then error("This message wasn't for you, or it was changed.", 0) end
```

To encrypt something large for several people, encrypt it once with `crypto.seal` under a random key from `crypto.randomBytes(32)`, then `sealTo` that key for each of them.

## Security limitations

- **Password strength.** Keys are only as strong as the password locking them. See [Security limitations](CRYPTO.md#security-limitations).
- **Password resets.** An administrator can't recover a user's key, so a reset loses what was encrypted to it.
- **Running code.** Encryption doesn't protect data from apps running in the same session, because they can reach `session.secretKey`. See the [Security model](../ZOS.md#security-model).
