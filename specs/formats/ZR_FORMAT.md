# Specification for the .zr File Format

A .zr file holds the root servers that a setup disk offers to trust. It's kept apart from the .zi image, so that the same image can go on any disk and a list of roots can be changed without touching it.

A setup disk has at most one, called `zos.zr`, in the same folder as `zos.zi`.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Format

A .zr file is a serialized Lua table. Roots are keyed by top-level domain, so a file can't hold two for one domain.

```lua
{
  ["zr:metadata"] = { version = 1 },
  roots = {
    ["root-a"] = {
      key = "<64 hex characters>",
      name = "Root A",
      host = 12,
      sig = "<128 hex characters>",
    },
  },
}
```

| Metadata field | Type   | Value                                      |
| -------------- | ------ | ------------------------------------------ |
| `version`      | number | The version of this format. Currently `1`. |

| Root field | Contents                                                              |
| ---------- | --------------------------------------------------------------------- |
| `key`      | The root's public key                                                 |
| `name`     | Its display name. Not signed, so it MUST NOT be relied on             |
| `host`     | The computer id it runs on. Not signed, like the name                 |
| `sig`      | The signature from its zone record, over `zos-zone-1`, the top-level domain and `key`. See [TRUST.md](../libs/TRUST.md#data-formats) |

No key MAY appear under two domains, because a root owns one.

## Writing a file

The Setup Disk app writes `zos.zr`. It offers every root the computer trusts, and the computer's own root server if it has one. It asks each trusted root for its zone, so a root that doesn't answer can't be chosen. Choosing a second root for a domain replaces the first. If nothing is chosen, it doesn't write the file.

The Root Server app's name and zone are in the `name` and `zone` fields of `/etc/root-server/config`, which other apps MAY read. The rest of that folder is private to it.

## Reading a file

The installer MUST read `zos.zr` from the folder of the image it's installing, and so ignores it for a downloaded image. Before anything on the computer changes, it MUST refuse the whole file if:

- it isn't a table in this format, or has another `version`.
- any domain, key, name, host or signature isn't valid, using the rules in [TRUST.md](../libs/TRUST.md#names).
- two domains have the same key.
- any signature doesn't verify, using the `crypto` library in the image.

It then shows each root's name, domain and fingerprint, and a person MUST choose to trust it. It doesn't ask about a root that's already trusted. If a different root is known to own the domain, that root stays and the new one is skipped, so a disk can't take over a domain. A clean reinstall deletes the old roots first, so they don't count.

## Security limitations

The signature shows that the key claims the domain, and not that the key is the one you meant, because anyone can make a key and sign any domain. A setup disk is trusted in the same way as the system image on it, which is why a person compares the fingerprints.
