# zOS Cryptography Specification

`require("crypto")` gives apps hashing, encryption, key agreement and signatures, written in pure Lua. `require("keys")` manages users' keys. [NETWORKING.md](NETWORKING.md) builds on both, so apps that only need to talk to other computers don't have to use them directly.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Algorithms

| Purpose                | Algorithm                                      | Functions                                  |
| ---------------------- | ---------------------------------------------- | ------------------------------------------ |
| Hashing                | SHA-256, SHA-512                               | `sha256`, `sha512`                         |
| Message authentication | HMAC-SHA256                                    | `hmac`                                     |
| Stream cipher          | ChaCha20 with a 96-bit nonce                   | `chacha20`                                 |
| Authenticated encryption | ChaCha20, then HMAC-SHA256 over nonce and ciphertext | `seal`, `open`                     |
| Key agreement          | X25519                                         | `keypair`, `publicKey`, `shared`, `x25519` |
| Public key encryption  | Ephemeral X25519, then `seal`                  | `sealTo`, `openSealed`                     |
| Password encryption    | Salted, iterated SHA-256, then `seal`          | `lock`, `unlock`                           |
| Signatures             | Ed25519 (RFC 8032)                             | `signingKeypair`, `sign`, `verify`         |

## Choosing a method

Apps SHOULD use the highest-level method that fits, and MUST NOT build their own scheme from `chacha20` and `hmac` when one of these does the job.

| To do this                                         | Use                                          |
| -------------------------------------------------- | -------------------------------------------- |
| Send data to another computer                      | `net`, not this library                      |
| Encrypt data only the logged-in user can read      | `seal` with a key derived from `session.secretKey` |
| Encrypt data for someone else's public key         | `sealTo`                                     |
| Encrypt data with a password                       | `lock`                                       |
| Prove who wrote something                          | `sign`                                       |
| Check that a download isn't damaged                | `sha256`                                     |
| Show a key for people to compare                   | `fingerprint`                                |

## Data formats

Functions take and return raw bytes unless this table says otherwise:

| Value                                     | Form                                    |
| ----------------------------------------- | --------------------------------------- |
| `sha256`, `sha512` results                | Hex strings                             |
| `hmac` results                            | Raw bytes (32)                          |
| Keys and seeds                            | Raw bytes (32)                          |
| Signatures                                | Raw bytes (64)                          |
| Boxes from `seal`, `sealTo` and `lock`    | Tables whose fields are all hex strings |

`util.writeTable` and `util.readTable` use text mode, which can damage raw bytes. Raw values MUST be converted with `toHex` before they're stored in a table. Boxes are already safe to store or send.

## Methods

### Utilities

| Method                  | Returns                                                                    |
| ----------------------- | -------------------------------------------------------------------------- |
| `crypto.toHex(s)`       | `s` as lowercase hex                                                       |
| `crypto.fromHex(h)`     | The bytes of hex string `h`                                                |
| `crypto.isHex(s, len)`  | Whether `s` is lowercase hex, and exactly `len` characters if `len` is given |
| `crypto.randomBytes(n)` | `n` random bytes                                                           |
| `crypto.addEntropy(data)` | Nothing. Mixes `data` into the random number generator                   |

Anything received from outside MUST be checked with `isHex` before `fromHex`, which doesn't validate its input.

### Hashes and MACs

| Method                                | Returns                                         |
| ------------------------------------- | ----------------------------------------------- |
| `crypto.sha256(msg)`                  | The SHA-256 of `msg`, as 64 hex characters      |
| `crypto.sha512(msg)`                  | The SHA-512 of `msg`, as 128 hex characters     |
| `crypto.hmac(key, msg)`               | The HMAC-SHA256 of `msg`, as 32 raw bytes       |
| `crypto.fingerprint(publicKey)`       | A short form of a key for people to compare, as four groups of four hex characters |

`hmac` can also derive one key from another, using a label as `msg`. See [Encrypting a user's data](#encrypting-a-users-data).

### Symmetric encryption

| Method                                    | Returns                                                 |
| ----------------------------------------- | ------------------------------------------------------- |
| `crypto.seal(key, plaintext)`             | A box `{ nonce, ct, tag }`                              |
| `crypto.open(key, box)`                   | The plaintext, or nil if the box is damaged or the key is wrong |
| `crypto.chacha20(key, nonce, data, counter)` | `data` encrypted or decrypted. `counter` defaults to 1 |

`key` MUST be 32 bytes that nobody else can guess. `seal` picks a random nonce and derives separate encryption and MAC keys from `key`.

`open` returns nil rather than an error, so callers MUST check the result.

`chacha20` has no authentication, so an attacker can change the data without being noticed. A nonce MUST NOT be used twice with the same key. Apps SHOULD use `seal` instead.

### Key agreement

| Method                        | Returns                                                       |
| ----------------------------- | ------------------------------------------------------------- |
| `crypto.keypair()`            | A new X25519 secret key and public key                        |
| `crypto.publicKey(sk)`        | The public key of a secret key                                |
| `crypto.shared(sk, peerPk)`   | The shared secret. Raises an error on a low-order public key  |
| `crypto.x25519(sk, peerPk)`   | The raw X25519 result, with no checks                         |
| `crypto.clearCache()`         | Nothing. Forgets the secrets kept by `shared`                 |

`shared` keeps its results in memory for speed. zOS clears them at logout.

Code that uses `x25519` MUST reject an all-zero result. A shared secret SHOULD NOT be used as a key directly: pass it through `hmac` with a label first.

### Public key encryption

| Method                                      | Returns                                                       |
| ------------------------------------------- | ------------------------------------------------------------- |
| `crypto.sealTo(publicKey, plaintext)`       | A box `{ nonce, ct, tag, eph }`, or nil for a low-order key   |
| `crypto.openSealed(secretKey, publicKey, box)` | The plaintext, or nil. `publicKey` is the recipient's own  |

`sealTo` uses a new key each time and throws it away, so the sender can't read the box afterwards. A box doesn't say who it's from. To prove that, sign it too.

### Password encryption

| Method                            | Returns                                     |
| --------------------------------- | ------------------------------------------- |
| `crypto.lock(password, plaintext)` | A locked table `{ salt, box }`             |
| `crypto.unlock(password, locked)`  | The plaintext, or nil if the password is wrong |

### Signatures

| Method                                     | Returns                                              |
| ------------------------------------------ | ---------------------------------------------------- |
| `crypto.signingKeypair()`                  | A new Ed25519 seed and public key                    |
| `crypto.signingPublicKey(seed)`            | The public key of a seed                             |
| `crypto.sign(seed, msg, publicKey)`        | A signature. `publicKey` is optional and saves time  |
| `crypto.verify(publicKey, msg, signature)` | True if the signature is valid, otherwise false      |

Ed25519 and X25519 keys are different kinds of key. A key from `keypair` MUST NOT be used with `sign`, and a seed from `signingKeypair` MUST NOT be used with `shared`.

Signed text SHOULD start with a label naming what it is, such as `"my-app-receipt-1\n"`, so that a signature for one purpose can't be passed off as another.

## User keys

`require("keys")` stores each user's X25519 key pair. The secret key is encrypted with their password, and login unlocks it into `session.secretKey`, with the public key in `session.publicKey`. Both are raw bytes. Services don't have a session, so they can't reach a user's secret key.

| Method                                | Returns                                                         |
| ------------------------------------- | --------------------------------------------------------------- |
| `keys.publicKey(user)`                | The user's public key on this computer, or nil                  |
| `keys.hasKey(user)`                   | Whether the user has a key                                      |
| `keys.known(address)`                 | The public key pinned for an address, or nil                    |
| `keys.remember(address, publicKey)`   | Nothing. Pins a key                                             |
| `keys.forgetKnown(address)`           | Nothing. Removes a pin                                          |
| `keys.knownList()`                    | Every pin, as a list of `{ address, fingerprint }`              |

`keys.create`, `keys.unlock`, `keys.rewrap`, `keys.forget` and `keys.reset` belong to the system, and apps MUST NOT call them.

Pins are shared by all apps. An app's addresses SHOULD start with its id, as in `notes:alice`. The `net:` prefix belongs to the system.

## Using these interfaces in an app

All of these examples go in an app's `main.lua`, which starts with `local session, app = ...`.

### Encrypting a user's data

Derive a key for the app, so that each app's data is encrypted under a different key. The file goes in the user's config folder, as described in [APP_STANDARDS.md](APP_STANDARDS.md).

```lua
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

### Encrypting for another user

The sender needs only the recipient's public key. Only the recipient's secret key can open the box.

```lua
local box = crypto.sealTo(recipientPublicKey, "Meet at the mine")

-- On the recipient's computer:
local text = crypto.openSealed(session.secretKey, session.publicKey, box)
if not text then error("This message wasn't for you, or it was changed.", 0) end
```

To encrypt something large for several people, encrypt it once with a random key from `crypto.randomBytes(32)`, then `sealTo` that key for each of them, as Mail does.

### Signing data

An app that needs signatures creates its own key pair and keeps it in `/etc/<id>/`. The seed is a secret, so any computer holding it can sign as that app.

```lua
local seed, public = crypto.signingKeypair()
local text = "my-app-receipt-1\nPaid 5 diamonds"
local signature = crypto.sign(seed, text, public)

if not crypto.verify(public, text, signature) then
    error("The receipt has been changed.", 0)
end
```

`verify` only shows that the holder of that key signed the text. The app still has to decide whether to trust the key: compare its `fingerprint` in person, or use a certificate as described in [NETWORKING.md](NETWORKING.md).

### Verifying a download

```lua
if crypto.sha256(text) ~= expected then
    error("The download is damaged.", 0)
end
```

A hash only helps if `expected` came from somewhere more trustworthy than the download.

## Performance

These methods run in Lua on an emulated computer, so they're slow. X25519 and Ed25519 can take long enough to notice, and an app that needs them often SHOULD show that it's working.

Long operations yield to the scheduler by queueing a `zos:crypto` event and waiting for it. Other events that arrive during that wait are discarded, so a program that calls these methods MUST NOT rely on seeing events in the meantime. `net` works around this by doing no crypto in the service that receives packets.

## Security limitations

- **Random numbers.** `randomBytes` hashes a pool built from the time, computer id, label and timing jitter. CC: Tweaked has no true random source, so this is only as strong as those inputs. zOS adds entropy where it can, such as from passwords at login. Apps SHOULD call `addEntropy` with anything unpredictable they have, such as key timings.
- **Password strength.** Passwords go through only 200 rounds of SHA-256, because more would be too slow in Lua. A stolen locked table can be attacked offline, so weak passwords offer little protection.
- **Timing.** Comparisons of tags and hashes aren't constant-time.
- **Stored secrets.** The computer's identity seed is stored unencrypted, because networking has to run while nobody is logged in. Files aren't private, so any app can read it.
- **Running code.** Encryption doesn't protect data from apps running in the same session, because they can reach `session.secretKey` through any code the user runs. See the Security model in [ZOS.md](ZOS.md).
