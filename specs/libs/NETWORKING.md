# zOS Networking Specification

`require("net")` gives apps encrypted, authenticated messages between computers over modems. There's nothing to set up: every computer has its own key, and the key exchange happens by itself the first time two computers talk. The algorithms it uses are described in [CRYPTO.md](CRYPTO.md).

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Overview

| Layer        | Provides                                                           |
| ------------ | ------------------------------------------------------------------ |
| Messages     | `send`, `request`, `reply` and `receive` on numbered ports         |
| Sessions     | An encrypted channel between two computers, made by a handshake    |
| Trust        | Whether a peer is verified or pinned, and what its name is         |
| Root servers | Certificates and hostnames                                         |
| Modems       | Delivery. CC: Tweaked modems reach anyone in range, so nothing here is trusted |

zOS starts three background services at boot. A receiver queues incoming packets and never does crypto, a worker handles those packets and outgoing messages one at a time, and a renewer keeps certificates current.

### Ports

A port is a modem channel, from 0 to 65533. 65534 and 65535 are used by rednet.

Each computer also keeps a home channel open, `30000 + id % 30000`, for handshake replies, acks and replies to requests. It can't be listened on, and only accepts answers to a request the computer is waiting on.

| Port  | Used by                  |
| ----- | ------------------------ |
| 4200  | Root servers             |
| 4201  | File Share               |
| 4202  | Mail servers             |

Apps SHOULD pick a fixed port of their own that doesn't clash with these, and SHOULD avoid the home channel range.

## Trust

The identity of a peer comes from its Ed25519 key, not its computer id, because anyone can claim any computer id.

- **Verified.** The peer showed a current certificate, signed by a root server this computer trusts, for the key it proved it holds and the computer id it claims. `peer.name` is the name on the certificate. This is checked for every message, so removing a root takes effect at once.
- **Pinned.** The peer has no such certificate. Its key is remembered against its computer id the first time it's seen, and it's refused if the key changes, unless the new key has a certificate for that id. The traffic is encrypted, but on first contact nothing shows who is on the other end.

Apps MUST use `verified`, `expect` or a hostname for anything that matters. An app MUST NOT make a security decision from `msg.from` alone.

### Certificates

A certificate says that a key belongs to a name on a computer id, and has these fields: `name`, `id`, `key`, `root`, `issued`, `expires` and `sig`. They last 30 days unless the root server is set otherwise, and computers renew them during the last 7 days, starting shortly after boot and then hourly. A computer can hold one per root, and a peer's first 4 certificates are looked at.

A revoked certificate keeps working until it expires, because computers don't check back with the root server.

### Root servers

A root server is a computer whose key others have chosen to trust. To use one, an admin adds it in **Settings → Network → Root servers**, comparing its fingerprint with the one the server shows. The computer then requests a certificate, and the root server's admin approves it.

### Hostnames

A hostname is a certificate name of the form `<label>.<tld>`, such as `zmail.root-a`, up to 24 characters of lowercase letters, digits and `-`, with one dot. Each root owns one top-level domain, set in a signed zone record, and only signs hostnames in that domain.

A lookup finds the trusted root that owns the domain and asks it for the certificate. Both answers are signed by the root, so the computer it runs on can make a lookup fail but can't change the answer. If two trusted roots claim one domain, lookups in it are refused.

## Messages

A message that decrypts and authenticates goes into its port's inbox and queues a `net_message` event. Anything else is dropped silently.

| Field     | Contents                                                                  |
| --------- | ------------------------------------------------------------------------- |
| `payload` | What was sent                                                             |
| `port`    | The port it arrived on                                                    |
| `from`    | The sender's computer id, for replying                                    |
| `id`      | The message id                                                            |
| `side`    | The modem it arrived on                                                   |
| `peer`    | What's known about the sender                                             |

| `peer` field  | Contents                                                     |
| ------------- | ------------------------------------------------------------ |
| `id`          | The computer id                                              |
| `key`         | The public key, in hex                                       |
| `fingerprint` | A short form of the key for people to compare                |
| `verified`    | True if it has a certificate from a trusted root             |
| `name`        | The name on the certificate. Only set if `verified`          |
| `root`        | The root that issued it, by key. Only set if `verified`      |
| `names`       | Every name it holds, as root key to name                     |

A payload can be any value except a function, nested up to 16 levels, and up to 32 KB once encoded.

### Delivery

- `send` returns true once the other computer has decrypted the message.
- If an ack is lost, the message is sent again once with a new session, and the other computer ignores the repeat.
- A port's inbox holds 32 messages. When it's full, the oldest is dropped.
- A closed port doesn't answer a handshake, so a send to one fails by timing out. This can take around 20 seconds. On an existing session, it fails straight away.

## Methods

Every method that can fail returns nil and a reason. Failures MUST be expected, since the other computer may be off, out of range or busy.

### Receiving

| Method                       | Returns                                                                   |
| ---------------------------- | ------------------------------------------------------------------------- |
| `net.listen(port, opts)`     | True. Calling it again keeps the inbox                                    |
| `net.close(port)`            | Nothing. Stops listening, and drops the inbox                             |
| `net.receive(port, timeout)` | The next message. Waits forever if `timeout` (seconds) is nil             |
| `net.modems()`               | The names of the attached modems                                          |
| `net.isRunning()`            | Whether networking is running                                             |

| `listen` option | Meaning                                                              |
| --------------- | -------------------------------------------------------------------- |
| `modem`         | Only listen on this modem                                            |
| `verified`      | Refuse any computer without a certificate from a trusted root        |

Modems attached later are picked up automatically. `receive` returns nil on terminate, on a timeout, or if the port is closed. Other programs MAY wait for the event `net.EVENT` instead, but it reaches every program on the computer and is lost if nobody is waiting at that moment, so servers MUST use `receive`.

### Sending

| Method                                  | Returns                                                       |
| --------------------------------------- | ------------------------------------------------------------- |
| `net.send(id, port, payload, opts)`     | True once it has been received                                |
| `net.request(id, port, payload, opts)`  | The reply's message table                                     |
| `net.reply(msg, payload, opts)`         | True. `msg` MUST have come from `net.request`                 |

| Option     | Meaning                                                                 |
| ---------- | ----------------------------------------------------------------------- |
| `verified` | Only send to a computer with a certificate from a trusted root          |
| `expect`   | Only send to a computer holding this name                               |
| `root`     | With `expect`: the name MUST come from this root, by key                |
| `key`      | Only send to a computer with this public key, in hex                    |
| `timeout`  | `request` only: seconds to wait for the reply, after delivery. Default 5 |

These calls block and ignore Ctrl+T, but each has a time limit. `reply` only goes to the key that asked, so a computer claiming the same id can't collect the answer.

### Hostnames

| Method                                         | Returns                                                   |
| ---------------------------------------------- | --------------------------------------------------------- |
| `net.resolve(host)`                            | `{ host, id, key, root }`                                 |
| `net.requestHost(host, port, payload, opts)`   | `net.request` to whoever holds the hostname. Only `timeout` is used from `opts` |
| `net.isHost(peer, host)`                       | Whether this peer holds the hostname                      |
| `net.rootForTld(tld)`                          | The trusted root that owns a top-level domain             |
| `net.tldOf(root)`                              | The top-level domain of a trusted root                    |

`requestHost` refuses to send to anyone but the holder of that hostname from the root that owns it. A computer can't reach its own hostname, because modems can't send to their own computer.

### Discovery

| Method                         | Returns                                                                  |
| ------------------------------ | ------------------------------------------------------------------------ |
| `net.probe(port, timeout)`     | A list of `{ data, from }`, after `timeout` seconds. Default 3           |
| `net.answerProbe(probe, data)` | Nothing. Answers a `net.PROBE_EVENT`                                     |

Probes are how computers find each other before they know anything about each other, so they aren't encrypted or authenticated. Apps MUST treat what comes back as a claim, and MUST NOT put secrets in an answer. A computer only hears probes on ports it's listening on.

### Root servers

| Method                                | Returns                                                                 |
| ------------------------------------- | ----------------------------------------------------------------------- |
| `net.findRoots(timeout)`              | Root servers in range, as `{ name, key, host, fingerprint }`            |
| `net.requestCertificate(root, name)`  | `"issued"`, `"pending"` or `"denied"`. Safe to repeat                   |

Being listed by `findRoots` proves only that a server holds the key it shows, so a person MUST compare the fingerprint before it's trusted. Ordinary apps don't need these methods, because Settings handles them.

`require("trust")` has more about the computer's identity and certificates. Apps MAY read `trust.defaultName()`, `trust.roots()` and `trust.certs()`, but MUST NOT change the trusted roots or use `trust.identity()`, which returns the computer's secret seed.

## Using these interfaces in an app

### A server

A server belongs in `service.lua`, so it keeps running while nobody is logged in.

```lua
local app = ...
local net = require("net")
local system = require("system")

local PORT = 5000

local function handle(msg)
    if type(msg.payload) ~= "table" then return { error = "Bad request" } end
    if msg.payload.op == "time" then return { time = os.epoch("utc") } end
    return { error = "Unknown request" }
end

net.listen(PORT)

while true do
    local msg = net.receive(PORT)
    if msg then
        local ok, result = pcall(handle, msg)
        if ok then
            net.reply(msg, result)
        else
            system.log(app.id .. ": " .. tostring(result))
        end
    end
end
```

Payloads come from anyone who can reach the port, so a server MUST check the type of every field before using it. `net.reply` waits for the other computer, and messages that arrive meanwhile wait in the inbox.

### A client

```lua
local net = require("net")

local reply, err = net.request(serverId, 5000, { op = "time" }, { timeout = 5 })
if not reply then
    return printError("Couldn't reach the server: " .. err)
end
print(reply.payload.time)
```

### Requiring a verified peer

A client names who it expects, and a server refuses anything else.

```lua
-- Client: only sends if computer 12 holds the name "bank".
local reply, err = net.request(12, 5000, request, { expect = "bank" })

-- Server: only accepts computers with a certificate.
net.listen(5000, { verified = true })
```

`listen` with `verified` admits any computer with a certificate, whatever its name. To limit a port to one computer, check the sender:

```lua
if msg.peer.names[rootKey] ~= "terminal-1" then
    return { error = "Not allowed" }
end
```

Compare against a specific root, as above, when more than one root is trusted. Otherwise, a second root could give the same name to someone else.

### Using hostnames

Clients SHOULD reach servers by hostname where they can, because a computer id can be claimed and a hostname can't.

```lua
local reply, err = net.requestHost("zmail.root-a", 4202, { op = "ping" }, { timeout = 5 })

-- A server can check where a message came from in the same way.
if not net.isHost(msg.peer, "zmail.root-a") then return { error = "Not allowed" } end
```

The client has to trust the root server, and it has to be in range for a lookup.

### Finding servers

A server answers probes on its port while it handles requests, using a separate loop, because answering a request waits for the other computer.

```lua
local function announcements()
    while true do
        local _, probe = os.pullEventRaw(net.PROBE_EVENT)
        if probe and probe.port == PORT then
            net.answerProbe(probe, { name = "Weather" })
        end
    end
end

parallel.waitForAll(announcements, requests)
```

A client then lists what's in range, and treats each answer as unproven until it has connected:

```lua
for _, server in ipairs(net.probe(5000) or {}) do
    print(server.from, type(server.data) == "table" and server.data.name)
end
```

### Sending more than 32 KB

Split the data into chunks and send them in order with `net.request`, using the reply to confirm each one. File Share works this way, with 8 KB chunks. A box from `crypto.seal` is twice the size of its plaintext, because it's hex, so a sealed chunk has to stay under 16 KB.

### Common mistakes

- Using `net_message` events in a server. They're lost while it's busy, so use `net.receive`.
- Trusting `msg.from`. Use `msg.peer` to decide whether to believe a message.
- Trusting a `verified` peer because it's verified. It only means that a trusted root knows its name, so check the name too.
- Trusting `net.probe` answers. Anyone in range can answer.
- Assuming a peer is the same after a reinstall. Its new key is refused until an admin forgets the old one in **Settings → Encryption keys → Trusted keys**.

## Protocol

Apps don't need this section. It's for anyone changing `net`, or checking its design. The protocol is called `zos-net-1`.

Every packet is a table sent through the modem, with `zn` (the version, currently 1), `src` (the sender's computer id) and `t` (the type). Packets other than `probe` and `beacon` also have `dst`, the computer they're for. `src` is a claim until a handshake or tag proves it.

### Handshake

Each side makes a new X25519 key for each handshake, and signs both ephemeral keys with its identity. An attacker needs an identity key to impersonate either side, and recording traffic doesn't help them read it later.

| Step    | Direction | Contents                                                                    |
| ------- | --------- | --------------------------------------------------------------------------- |
| `hello` | a to b    | a's ephemeral key, broadcast on the port                                    |
| `resp`  | b to a    | b's ephemeral key, then encrypted: b's identity, certificates and signature |
| `auth`  | a to b    | Encrypted: a's identity, certificates and signature                         |
| `done`  | b to a    | A tag showing b has checked a                                               |

The transcript is the SHA-256 of `zos-net-1`, then a's ephemeral key, then b's. Keys are derived with HMAC-SHA256 from the X25519 secret, with the transcript as the salt, giving each direction its own handshake, encryption and MAC keys.

b signs `zos-net-1|resp|`, the transcript and its identity. a signs `zos-net-1|auth|`, the transcript, b's identity and its own, so a's signature can't be presented to anyone else.

An answer that fails its checks is ignored, not treated as a failure. `hello` is broadcast, so otherwise anyone could stop a connection by answering first.

### Data

A `data` packet has a session id, port, sequence number, ciphertext and tag. The body is encrypted with ChaCha20, using the sequence number as a 12-byte little-endian nonce, and the HMAC-SHA256 tag covers the type, session id, source, destination, port, sequence number and ciphertext. Receivers MUST refuse a sequence number that isn't higher than the last one accepted.

Before encryption, the body is encoded with a format that's only ever read as data, because `textutils.unserialize` runs code. It holds the message id `id`, the payload `p` and, for a reply, the id `re` of the request.

Each `ack` has a status of `ok`, `closed` or `denied`, and its own tag. Message ids are remembered for 60 seconds, so that a retry on a new session isn't delivered twice.

### Limits

| Limit                        | Value                                       |
| ---------------------------- | ------------------------------------------- |
| Payload                      | 32768 bytes, once encoded                   |
| Sessions                     | 64, then the oldest goes                    |
| Session lifetime             | 1 hour                                      |
| Half-open handshakes         | 4 from other computers                      |
| Handshake timeout            | 15 seconds per step                         |
| Ack timeout                  | 6 seconds                                   |
| Queued data packets          | 64                                          |
| Queued handshake packets     | 8                                           |
| Probes answered              | 8 per tick                                  |
| Answers kept per probe       | 16                                          |

These limits exist because handshakes are slow and packets come from anyone.

## Security limitations

- **Denial of service.** Anyone in range can jam traffic, fill the handshake limit or stop a lookup.
- **Traffic analysis.** Computer ids, ports, sizes and timing aren't hidden.
- **First contact.** A pinned peer can be impersonated the first time it's seen.
- **Revocation.** A certificate can't be cancelled before it expires, so keep lifetimes short if that matters.
- **Stored identity.** The identity seed isn't encrypted, so any app on a computer can impersonate that computer. See [CRYPTO.md](CRYPTO.md).
- **Root servers.** A trusted root can certify any name in its domain and any computer id, so an admin SHOULD only trust roots they'd trust with that power. Root servers MUST NOT be open for anyone to log in to.
