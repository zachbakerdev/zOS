# zOS Mail

End-to-end encrypted messages between users on the same or other [zOS](../../README.md) computers.

## Installing

Mail needs **zOS 1.3.0 or later**. Copy the `mail/` folder onto a floppy disk, put it in a drive
next to the zOS computer, and install it with the **App Manager** app or from the Shell:

```
appman install disk/mail
```

Then reboot, so zOS starts Mail's background service (it receives messages and answers key
requests). Mail keeps its data in `/etc/zos/mail/`, so messages from an older zOS with built-in
Mail are still there.

## Files

```
mail/app.manifest   app manifest (declares the background service)
mail/main.lua       the Mail app
mail/service.lua    background service: receives mail, shows "N new mail" on the desktop
mail/mail.lua       mail storage, delivery, encryption and the rednet protocol
```

## Using Mail

- **Addresses** look like `user@computer`. `computer` is the computer's ID (e.g. `bob@12`) or its
  label if the label has no spaces (e.g. `bob@Base`). Just `bob` means a user on the same computer.
  Your own address is shown in Mail's title bar.
- **Between computers**, mail travels over rednet, so both computers need a **modem** (wireless,
  ender or wired). Mail between users on the same computer needs no modem.
- **Delivery is confirmed.** The receiving computer replies once it has stored the message. If
  it's off, out of range or not running zOS, you get an error and the message isn't saved as sent.
- **Mail arrives while you're away.** A background service accepts messages even at the login
  screen. The desktop's title bar shows "N new mail" when you have unread messages.
- Messages are stored in `/etc/zos/mail/<user>/`.

## Encryption

Message bodies are encrypted end to end with public-key cryptography. Only the sender and the
recipient can read them. That includes other people on the network and other users of the same
computer. Everything is pure Lua in zOS's `lib/crypto.lua`, checked against the RFC 7748 test vectors
and a reference implementation.

**Keys.** Mail uses the **X25519** key pair zOS gives each user. It is created at their first login
after installing or upgrading zOS.
- `/etc/zos/keys/<user>.pub` holds the public key, which anyone may ask for.
- `/etc/zos/keys/<user>.key` holds the secret key, encrypted with a key derived from the user's
  login password (200 rounds of salted SHA-256).
- The secret key is unlocked at login and kept in memory only for that session. Other users of
  the computer can't read it from disk.

**Encrypting a message**, the same construction as NaCl's `box`:

```
shared = X25519(sender secret, recipient public)    -- the recipient computes the same value
                                                    -- from (recipient secret, sender public)
key    = HMAC-SHA256(shared, "zos-mail-v1" || sender public || recipient public)
enc    = HMAC(key, "zos-enc"),  mac = HMAC(key, "zos-mac")
ct     = ChaCha20(enc, random 96-bit nonce, body)
tag    = HMAC-SHA256(mac, nonce || ct)              -- checked before decrypting
```

- Because the shared secret comes from both parties' keys, a message that decrypts must have been
  written by the holder of the sender key it names. Any change to the ciphertext makes the tag
  check fail.
- The sender can decrypt the message too, so the copy in "Sent" is the same encrypted envelope.

**Finding keys (trust on first use).**
- When you write to `bob@12`, Mail asks computer #12 for bob's public key. It saves (pins) the key
  in `/etc/zos/mail/known_keys` under `bob@12`.
- If a different key is offered later, Mail warns you, shows both fingerprints and asks before
  trusting the new one. This is like SSH's "host key changed" warning.
- Each message shows whether the sender's key matches the one on record. Possible results are
  *verified*, *NOT verified* (their computer couldn't be reached to check), or a warning that it
  doesn't match.
- To be sure nobody swapped keys the first time, compare fingerprints in person. Your fingerprint
  is in **Mail → Encryption keys**.

**What isn't encrypted:** subjects, sender and recipient addresses, and times. Treat the subject
like a postcard. If a recipient has no key yet (they haven't logged in since installing, or they
run an older zOS), Mail offers to send the message unencrypted. Those messages are marked
`[plain]` in the inbox.

**Password changes:**
- Changing your own password (Settings) re-encrypts your secret key, so nothing is lost.
- If an **admin resets** someone else's password, that user's key can't be recovered. They get a
  new key pair at their next login, and mail sent to the old key can no longer be read. People who
  write to them will see a key-change warning.

## Limits of the encryption

- **Someone who can log in can tamper with the system.** They could change zOS's own files, for
  example to record passwords as they're typed, or replace a user's public key file.
  Encryption protects stored and in-transit mail, not a computer that has already been tampered
  with.
- **Randomness is improvised.** ComputerCraft has no secure random number generator. Keys and
  nonces come from a SHA-256 pool fed by clocks, timing jitter, memory addresses and
  login keystroke timing. That's fine for a game, but it isn't a vetted generator.
- **The first key exchange can be intercepted.** Rednet sender IDs can be forged with raw modem
  messages, so a determined player could swap keys on first contact. Comparing fingerprints
  prevents that.
- **No forward secrecy.** If someone later gets a user's password and their key file, they can
  read that user's old mail.
- **It's slow-ish.** Key operations take roughly a second in ComputerCraft. Results are cached per
  login, so writing to the same person again is quick.
