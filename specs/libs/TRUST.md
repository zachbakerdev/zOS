# zOS Trust Library Specification

`require("trust")` holds this computer's identity, the root servers it trusts, its certificates, and the rules for names. [NET.md](NET.md) uses it to decide who it's talking to, so most apps only meet it through `msg.peer`.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Trust

The identity of a peer comes from its Ed25519 key, not its computer id, because anyone can claim any computer id. The key belongs to the computer and not a user, because networking runs while nobody is logged in.

- **Verified.** The peer showed a current certificate, signed by a root server this computer trusts, for the key it proved it holds and the computer id it claims. `peer.name` is the name on the certificate. This is checked for every message, so removing a root takes effect at once.
- **Pinned.** The peer has no such certificate. Its key is remembered against its computer id the first time it's seen, as `net:<id>` in [KEYS.md](KEYS.md#pinned-keys), and it's refused if the key changes, unless the new key has a certificate for that id. The traffic is encrypted, but on first contact nothing shows who is on the other end.

Apps MUST use `verified`, `expect` or a hostname for anything that matters. An app MUST NOT make a security decision from `msg.from` alone. See [Requiring a verified peer](NET.md#requiring-a-verified-peer).

### Certificates

A certificate says that a key belongs to a name on a computer id. It lasts for as long as the root server chooses, and computers renew theirs during the last 7 days, starting shortly after boot and then hourly. A computer can hold one per root.

A revoked certificate keeps working until it expires, because computers don't check back with the root server.

### Root servers

A root server is a computer whose key others have chosen to trust. To use one, an admin adds it in **Settings → Security → Root servers**, comparing its fingerprint with the one the server shows. The computer then requests a certificate, and the root server's admin approves it.

### Hostnames

A hostname is a certificate name of the form `<label>.<tld>`, such as `zmail.root-a`, up to 24 characters of lowercase letters, digits and `-`, with one dot. Each root owns one top-level domain, set in a signed zone record, and only signs hostnames in that domain.

A lookup finds the trusted root that owns the domain and asks it for the certificate. Both answers are signed by the root, so the computer it runs on can make a lookup fail but can't change the answer.

A computer trusts one root for each domain. `net.addRoot` and the installer refuse a second, and a setup disk can only hold one. If two trusted roots still claim one domain, as they can on a computer that trusted them before this rule or when a root moves to another domain, lookups in it are refused.

## Permissions

Apps MAY read `trust.defaultName()`, `trust.roots()`, `trust.root(key)`, `trust.certs()` and `trust.cert(rootKey)`, and use the name checks. Apps MUST NOT change the trusted roots or use `trust.identity()`, which returns the computer's secret seed. The exception is an app that is a root server, which uses the signing methods with its own key.

## Data formats

Keys in tables are hex strings of 64 characters, and signatures are hex strings of 128 characters. Methods that take raw keys say so.

| Certificate field | Contents                                         |
| ----------------- | ------------------------------------------------ |
| `name`            | The name it gives the computer                   |
| `id`              | The computer id it's for                         |
| `key`             | The computer's public key                        |
| `root`            | The public key of the root that signed it        |
| `issued`          | When it was issued, in milliseconds since 1970   |
| `expires`         | When it expires, in the same form                |
| `sig`             | The root's signature                             |

| Root field | Contents                                                     |
| ---------- | ------------------------------------------------------------ |
| `key`      | The root's public key                                        |
| `name`     | Its display name, as it was when it was added                |
| `host`     | The computer id it runs on                                   |
| `tld`      | Its top-level domain, once that has been checked, or nil     |

Each signed text starts with a label, so that a signature for one purpose can't be passed off as another. Fields are joined with `|`.

| Record      | Fields         | Signed text                                              |
| ----------- | -------------- | -------------------------------------------------------- |
| Certificate | As above       | `zos-cert-1`, `name`, `id`, `key`, `root`, `issued`, `expires` |
| Advert      | `name`, `key`, `sig` | `zos-advert-1`, `name`, `key`                      |
| Zone        | `tld`, `root`, `sig` | `zos-zone-1`, `tld`, `root`                        |

## Identity

| Method             | Returns                                                       |
| ------------------ | ------------------------------------------------------------- |
| `trust.identity()` | The computer's secret seed and public key, as raw bytes. Made the first time it's needed |

## Names

| Method                 | Returns                                                         |
| ---------------------- | --------------------------------------------------------------- |
| `trust.defaultName()`  | The computer's label if it would make a good name, otherwise `computer-<id>` |
| `trust.validName(name)` | True, or false and a reason. For certificate and server names  |
| `trust.parseHost(host)` | The label and top-level domain of a hostname, or nil and a reason |
| `trust.validTld(tld)`  | True, or false and a reason                                     |
| `trust.tldFromName(name)` | A top-level domain to suggest for a root server called `name` |

A name is up to 32 letters, digits, spaces, `-` or `_`. A name with a dot MUST be a valid hostname. A top-level domain is up to 16 lowercase letters, digits or `-`, starting with a letter or digit.

## Roots

| Method                           | Returns                                                       |
| -------------------------------- | ------------------------------------------------------------- |
| `trust.roots()`                  | Every trusted root, sorted by name                            |
| `trust.root(key)`                | The trusted root with this key, or nil                        |
| `trust.addRoot(key, name, host, tld)` | True, or false and a reason. Trusts a root, and keeps its top-level domain if it's already known. `tld`, if given, MUST be verified, and is refused if another root owns it |
| `trust.tldOwner(tld, except)`    | The trusted root known to own this domain, other than the one with key `except`, or nil |
| `trust.removeRoot(key)`          | Nothing. Stops trusting it, and deletes its certificate for this computer |
| `trust.setRootTld(key, tld)`     | Nothing. Remembers a top-level domain from a zone that has been verified |

A person MUST compare a root's fingerprint before it's added, and a caller acting for a user MUST check `session.admin`. Callers SHOULD use `net.addRoot`, which finds the domain and enforces one root for each. See [NET.md](NET.md).

## This computer's certificates

| Method                     | Returns                                      |
| -------------------------- | -------------------------------------------- |
| `trust.certs()`            | Every certificate, in a fixed order          |
| `trust.cert(rootKey)`      | The certificate from this root, or nil       |
| `trust.installCert(cert)`  | Nothing. Stores it, replacing any from that root |

`installCert` doesn't check the certificate. `net.requestCertificate` does that first.

## Checking signatures

| Method                             | Returns                                                     |
| ---------------------------------- | ----------------------------------------------------------- |
| `trust.certIntact(cert)`           | Whether it's well formed, current and signed by the root it names |
| `trust.verifyAdvert(advert)`       | Whether it's signed by the key it shows                     |
| `trust.verifyZone(zone, rootKey)`  | Whether it's signed by this root                            |
| `trust.namesFor(certs, id, keyHex)` | What a peer's certificates prove: a table of (root key -> name), and the first certificate that counts, or nil |

None of the first three ask whether the root is trusted, and only `namesFor` does. A certificate counts only for its own computer id and key, and only if a trusted root signed it. Otherwise any certified computer could claim another's id and replace its pinned key.

Signature checks are slow and a peer chooses what it sends, so `namesFor` looks at no more than 32 certificates and checks the signatures of no more than 4. The results of the last 64 checks are remembered.

## Signing

These are for root servers, which pass in their own seed and public key as raw bytes.

| Method                                                     | Returns                  |
| ---------------------------------------------------------- | ------------------------ |
| `trust.issue(rootSeed, rootPublic, name, id, key, lifetime)` | A certificate. `lifetime` is in milliseconds |
| `trust.signAdvert(rootSeed, rootPublic, name)`             | An advert                |
| `trust.signZone(rootSeed, rootPublic, tld)`                | A zone                   |

A root server MUST only sign hostnames in its own top-level domain.

## Storage

Everything is in `/etc/zos/net/`.

| File       | Holds                                                 |
| ---------- | ----------------------------------------------------- |
| `identity` | The computer's seed and public key, in hex, unencrypted |
| `roots`    | The trusted roots, by key                             |
| `certs`    | This computer's certificates, by root key             |

## Security limitations

- **First contact.** A pinned peer can be impersonated the first time it's seen.
- **Revocation.** A certificate can't be cancelled before it expires, so keep lifetimes short if that matters.
- **Stored identity.** The identity seed isn't encrypted, so any app on a computer can impersonate that computer. Files aren't private, and networking has to run while nobody is logged in.
- **Root servers.** A trusted root can certify any name in its domain and any computer id, so an admin SHOULD only trust roots they'd trust with that power. Root servers MUST NOT be open for anyone to log in to.
