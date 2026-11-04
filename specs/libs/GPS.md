# zOS GPS Library Specification

`require("gps")` tells a computer where it is, from GPS hosts that a trusted root server has vouched for. It works like CraftOS's `gps.locate`, but it ignores any answer that a root server this computer trusts hasn't vouched for, so a computer can't be told it's somewhere it isn't by anyone with a modem. Hosts run the GPS Server app. Root servers vouch for them as described in [TRUST.md](TRUST.md#gps-certificates).

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Methods

| Method                 | Returns                                                                 |
| ---------------------- | ----------------------------------------------------------------------- |
| `gps.locate(timeout)`  | `x, y, z`, or nil if the position can't be worked out                   |
| `gps.wirelessModems()` | The names of the attached wireless modems                               |

`locate` listens for answers for `timeout` seconds, 2 by default, then checks them. Checking a host's signatures for the first time takes a moment longer, and later calls reuse what was checked. It needs a wireless or ender modem, because a wired modem doesn't say how far away a message came from, and it ignores Ctrl+T while it waits.

It returns nil when there's no wireless modem, when fewer than 3 trusted hosts answer, or when the answers don't settle on one place.

```lua
local gps = require("gps")

local x, y, z = gps.locate()
if not x then return printError("Couldn't work out where this is.") end
print(("At %d, %d, %d"):format(x, y, z))
```

From the Terminal, `locate [seconds]` prints the same.

## Which answers count

An answer counts only if all of these hold:

- Its GPS certificate is signed by a root server this computer trusts, and hasn't expired.
- Its timestamp is signed by the key on that certificate, and is less than 10 minutes old.
- It came over a wireless modem, so its distance is known.
- The same host wasn't also heard at a different distance or claiming a different place. Anyone can pass a host's answer on from somewhere else, and a host heard twice is left out rather than either answer believed.

Hosts at the same place count once, and at most 8 hosts are used.

## Working out the position

Each answer gives a host's position and its distance from this computer. Any three hosts that aren't in a line meet at one or two points. `locate` tries every three, and keeps the point that the most hosts agree with, to within 0.05 blocks. The point is used only if:

- at least 3 hosts agree with it,
- more than half of the hosts that answered agree with it, and
- no other point has as many hosts agreeing.

So a host that's wrong, for example because it was moved after it was approved, is outvoted when there are enough others, and otherwise gives nil instead of a wrong position.

The coordinates are rounded to 2 decimal places. A computer gets its block's coordinates, as long as hosts were given theirs.

### Placing hosts

- 3 hosts only give a position on their own plane, since off it there are two answers.
- 4 hosts give a position anywhere, as long as they aren't all in one plane. Hosts all at one height are in one plane.
- 5 or more let one wrong host be outvoted. With 4, a wrong host gives nil.

## Protocol

Apps don't need this section. The protocol is called `zos-gps-1`. It uses modems directly rather than `net`, because a position comes from the distance the modem reports, and `net` sessions would hide it.

A client broadcasts a request on port 4203 (`gps.PORT`) on each wireless modem, with its home channel (`30000 + id % 30000`, as in [NET.md](NET.md#ports)) as the reply channel:

| Field   | Contents                                    |
| ------- | ------------------------------------------- |
| `zg`    | 1, the version                              |
| `t`     | `where`                                     |
| `nonce` | 16 random hex characters, to match answers  |

A host answers on the reply channel, from the modem the request came in on:

| Field   | Contents                                                   |
| ------- | ---------------------------------------------------------- |
| `zg`    | 1                                                          |
| `t`     | `here`                                                     |
| `nonce` | The request's nonce                                        |
| `cert`  | Its GPS certificate, as in [TRUST.md](TRUST.md#data-formats) |
| `stamp` | `{ time, sig }`: a time in milliseconds since 1970, and the host's signature of `zos-gps-stamp-1\|<cert.key>\|<time>` with the key on its certificate |

Answering does no signing, so a host can answer as fast as requests come. It signs a new timestamp every 5 minutes, and answers at most 16 requests per tick. Every computer in a world shares one clock, which is what lets a client judge a timestamp's age.

## Security limitations

- **Relays.** Anyone in range can pass a host's real answers on from somewhere else, and a client measures the distance to whoever sent the message. A client that hears the real host too leaves that host out, but one that hears only the relay is fooled. An attacker that relays every host from carefully placed modems, out of range of the real hosts, can choose where a computer thinks it is. Timestamps only stop answers being replayed after 10 minutes.
- **Hosts.** A host's position is what its root server's admin approved. If a host is moved, it keeps saying the old position until it's revoked. Enough other hosts outvote it.
- **Denial of service.** Anyone can jam the channel, or send enough answers to fill the 32 that a request keeps, which makes `locate` return nil. At most 12 new answers are checked per request, to bound the time spent on signatures.
- **Trust.** A root server can vouch for any position, so the hosts are only as honest as the roots this computer trusts. See [TRUST.md](TRUST.md#security-limitations).
