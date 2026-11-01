# zOS Net Library Specification

`require("net")` gives apps encrypted, authenticated messages between computers over modems. There's nothing to set up: every computer has its own key, and the key exchange happens by itself the first time two computers talk. The algorithms it uses are described in [CRYPTO.md](CRYPTO.md), and who a computer believes in [TRUST.md](TRUST.md).

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Overview

| Layer        | Provides                                                           |
| ------------ | ------------------------------------------------------------------ |
| Messages     | `send`, `request`, `reply` and `receive` on numbered ports         |
| Sessions     | An encrypted channel between two computers, made by a handshake    |
| Trust        | Whether a peer is verified or pinned, and what its name is         |
| Root servers | Certificates and hostnames                                         |
| Modems       | Delivery. CC: Tweaked modems reach anyone in range, so nothing here is trusted |

zOS starts three background services at boot with `net.start`, which apps MUST NOT call. A receiver queues incoming packets and never does crypto, a worker handles those packets and outgoing messages one at a time, and a renewer keeps certificates current. The worker never waits for the other computer, so two computers that write to each other at the same moment can't hold each other up.

### Ports

A port is a modem channel, from 0 to 65533. 65534 and 65535 are used by rednet.

Each computer also keeps a home channel open, `30000 + id % 30000`, for handshake replies, acks and replies to requests. It can't be listened on, and only accepts answers to a request the computer is waiting on.

Root servers use port 4200, which is `net.ROOT_PORT`.

Apps SHOULD pick a fixed port of their own that doesn't clash with that, and SHOULD avoid the home channel range.

## Peers

Every message says who sent it in `msg.peer`. A peer is either verified or pinned, as described in [Trust](TRUST.md#trust). In short, a verified peer has a certificate from a root server this computer trusts, and a pinned peer is only known to have the same key as last time.

Apps MUST use `verified`, `expect` or a hostname for anything that matters. An app MUST NOT make a security decision from `msg.from` alone.

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

A payload can be any value except a function, nested up to 16 levels, and up to 32 KB once encoded. `net.MAX_PAYLOAD` is the limit in bytes.

### Delivery

- `send` returns true once the other computer has decrypted the message.
- If an ack is lost, the message is sent again once with a new session, and the other computer ignores the repeat.
- A peer that fails `verified`, `expect` or `key` on an existing session gets one new handshake, in case it has a new certificate. The same goes for a port that answers `denied`.
- A port's inbox holds 32 messages. When it's full, the oldest is dropped.
- A closed port doesn't answer a handshake, so a send to one fails by timing out. This can take around 15 seconds. On an existing session, it fails straight away.

## Methods

Every method that can fail returns nil and a reason. Failures MUST be expected, since the other computer may be off, out of range or busy.

### Receiving

| Method                       | Returns                                                                   |
| ---------------------------- | ------------------------------------------------------------------------- |
| `net.listen(port, opts)`     | True. Calling it again changes the options and keeps the inbox            |
| `net.close(port)`            | Nothing. Stops listening, and drops the inbox                             |
| `net.receive(port, timeout)` | The next message. Waits forever if `timeout` (seconds) is nil             |
| `net.modems()`               | The names of the attached modems                                          |
| `net.isRunning()`            | Whether networking is running                                             |

| `listen` option | Meaning                                                              |
| --------------- | -------------------------------------------------------------------- |
| `modem`         | Only listen on this modem. It isn't checked, so a wrong name just hears nothing |
| `verified`      | Refuse any computer without a certificate from a trusted root        |

Modems attached later are picked up automatically. `receive` returns nil on terminate, on a timeout, or if the port is closed. Other programs MAY wait for the event `net.EVENT` instead, whose value is the message, but it reaches every program on the computer and is lost if nobody is waiting at that moment, so servers MUST use `receive`. `net.close` queues the same event with no message, to wake up a `receive`, so anything that waits for it MUST check for nil.

### Sending

| Method                                  | Returns                                                       |
| --------------------------------------- | ------------------------------------------------------------- |
| `net.send(id, port, payload, opts)`     | True once it has been received                                |
| `net.request(id, port, payload, opts)`  | The reply's message table                                     |
| `net.reply(msg, payload)`               | True. `msg` MUST have come from `net.request`                 |

| Option     | Meaning                                                                 |
| ---------- | ----------------------------------------------------------------------- |
| `verified` | Only send to a computer with a certificate from a trusted root          |
| `expect`   | Only send to a computer holding this name                               |
| `root`     | With `expect`: the name MUST come from this root, by key                |
| `key`      | Only send to a computer with this public key, in hex                    |
| `timeout`  | `request` only: seconds to wait for the reply, after delivery. Default 5 |

These calls block and ignore Ctrl+T, but each has a time limit. `reply` only goes to the key that asked, on the session it asked on, so a computer claiming the same id can't collect the answer. It fails if that session has gone.

### Hostnames

| Method                                         | Returns                                                   |
| ---------------------------------------------- | --------------------------------------------------------- |
| `net.resolve(host)`                            | `{ host, id, key, root }`                                 |
| `net.requestHost(host, port, payload, opts)`   | `net.request` to whoever holds the hostname. Only `timeout` is used from `opts` |
| `net.isHost(peer, host)`                       | Whether this peer holds the hostname                      |
| `net.rootForTld(tld)`                          | The trusted root that owns a top-level domain             |
| `net.tldOf(root)`                              | The top-level domain of a trusted root                    |

`requestHost` refuses to send to anyone but the holder of that hostname, with the key on its certificate, from the root that owns it. `tldOf` remembers the answer, so it only asks a root once. A root that can't be reached stops `rootForTld` finding a domain only if no other root owns it. A computer can't reach its own hostname, because modems can't send to their own computer.

### Discovery

| Method                         | Returns                                                                  |
| ------------------------------ | ------------------------------------------------------------------------ |
| `net.probe(port, timeout)`     | A list of `{ data, from }`, after `timeout` seconds. Default 3           |
| `net.answerProbe(probe, data)` | Nothing. Answers a `net.PROBE_EVENT`, whose value is `{ port, nonce, from, side }` |

Probes are how computers find each other before they know anything about each other, so they aren't encrypted or authenticated. Apps MUST treat what comes back as a claim, and MUST NOT put secrets in an answer. A computer only hears probes on ports it's listening on.

### Root servers

| Method                                | Returns                                                                 |
| ------------------------------------- | ----------------------------------------------------------------------- |
| `net.findRoots(timeout)`              | Root servers in range, as `{ name, key, host, fingerprint }`            |
| `net.addRoot(entry)`                  | True, or false and a reason. Trusts a root from `findRoots`, unless another trusted root owns its top-level domain or one that doesn't have a known domain can't be asked |
| `net.requestCertificate(root, name)`  | `"issued"`, `"pending"` or `"denied"`. Safe to repeat                   |

Being listed by `findRoots` proves only that a server holds the key it shows, so a person MUST compare the fingerprint before it's trusted. Ordinary apps don't need these methods, because Settings handles them.

`requestCertificate` takes a root from `findRoots` or `trust.roots`. It checks a certificate that comes back against the root's key and this computer's key before storing it, so the computer the root runs on can make a request fail but no more. A new certificate is shown to peers at the next handshake.

[TRUST.md](TRUST.md) has more about the computer's identity and certificates.

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
local reply, err = net.requestHost("zmail.root-a", 5000, { op = "ping" }, { timeout = 5 })

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

Split the data into chunks and send them in order with `net.request`, using the reply to confirm each one. A box from `crypto.seal` is twice the size of its plaintext, because it's hex, so a sealed chunk has to stay under 16 KB.

### Common mistakes

- Using `net_message` events in a server. They're lost while it's busy, so use `net.receive`.
- Trusting `msg.from`. Use `msg.peer` to decide whether to believe a message.
- Trusting a `verified` peer because it's verified. It only means that a trusted root knows its name, so check the name too.
- Trusting `net.probe` answers. Anyone in range can answer.
- Assuming a peer is the same after a reinstall. Its new key is refused until an admin forgets the old one in **Settings → Encryption keys → Trusted keys**, unless it has a certificate.

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
| `done`  | b to a    | A tag showing b has checked a: the HMAC of `zos-net-1\|done\|` and the transcript |

The transcript is the SHA-256 of `zos-net-1`, then a's ephemeral key, then b's. Keys are derived with HMAC-SHA256 from the X25519 secret, with the transcript as the salt, giving each direction its own handshake, encryption and MAC keys.

`hello` is sent again every 5 seconds until it's answered, and is only answered on a port that's listening. b signs `zos-net-1|resp|`, the transcript and its identity. a signs `zos-net-1|auth|`, the transcript, b's identity and its own, so a's signature can't be presented to anyone else.

An answer that fails its checks is ignored, not treated as a failure. `hello` is broadcast, so otherwise anyone could stop a connection by answering first.

### Data

A `data` packet has a session id, port, sequence number, ciphertext and tag. The body is encrypted with ChaCha20, using the sequence number as a 12-byte little-endian nonce, and the HMAC-SHA256 tag covers the type, session id, source, destination, port, sequence number and ciphertext. Receivers MUST refuse a sequence number that isn't higher than the last one accepted.

Before encryption, the body is encoded with a format that's only ever read as data, because `textutils.unserialize` runs code. It holds the message id `id`, the payload `p` and, for a reply, the id `re` of the request.

Each `ack` has a status of `ok`, `closed` or `denied`, and its own tag. Replies go to the home channel of the computer that asked, with the port of the request. Message ids are remembered for 60 seconds, so that a retry on a new session isn't delivered twice.

### Limits

| Limit                        | Value                                       |
| ---------------------------- | ------------------------------------------- |
| Payload                      | 32768 bytes, once encoded                   |
| Sessions                     | 64, then the oldest goes                    |
| Session lifetime             | 1 hour                                      |
| Half-open handshakes         | 4 from other computers                      |
| Handshake timeout            | 15 seconds per step                         |
| Hello retry                  | Every 5 seconds                             |
| Ack timeout                  | 6 seconds                                   |
| Queued data packets          | 64                                          |
| Queued handshake packets     | 8                                           |
| Probes answered              | 8 per tick                                  |
| Answers kept per probe       | 16                                          |

These limits exist because handshakes are slow and packets come from anyone.

### Root server requests

Root servers answer `net.request` messages on port 4200. Each is a table with an `op`.

| `op`          | Fields | Answer                                                      |
| ------------- | ------ | ----------------------------------------------------------- |
| `certificate` | `name` | `{ status, cert, message }`. `status` is `issued`, `pending` or `denied`. Any other answer is a refusal, explained by `message` |
| `zone`        | None   | The root's zone record, as in [TRUST.md](TRUST.md#data-formats) |
| `resolve`     | `name` | `{ cert }`, or nothing in `cert` if there's no such host    |

They also answer probes on that port with a signed advert.

## Security limitations

- **Denial of service.** Anyone in range can jam traffic, fill the handshake limit or stop a lookup.
- **Traffic analysis.** Computer ids, ports, sizes and timing aren't hidden.
- **Trust.** First contact, revocation, the stored identity and root servers are covered in [TRUST.md](TRUST.md#security-limitations).
