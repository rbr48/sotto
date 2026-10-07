# Sotto Threat Model (v0.7 — Phase 7)

This is a living document. It records what Sotto protects, against whom, and what it honestly does not protect yet. Update it whenever the design changes.

## 1. What we protect

| Asset | Where it lives |
|---|---|
| Call audio and video | In transit only (WebRTC DTLS-SRTP), device to device |
| Call setup data (SDP, ICE candidates: IP addresses, codec details) | In transit, inside end-to-end envelopes |
| Identities (master secret) | Professional's device, in the OS keystore; guests: memory only |
| Contacts, call history, notes, recordings | Professional's device only, in the encrypted vault (`PROTOCOL.md` §9) |
| Backups | Wherever the user saves them, encrypted with their passphrase (`PROTOCOL.md` §8) |
| Metadata: who talks to whom, when, from which IP | Seen briefly by the relay in RAM; never stored |

## 2. Adversaries

| Adversary | Capabilities assumed |
|---|---|
| **Network attacker** | Reads and modifies traffic between users and servers (public Wi-Fi, ISP) |
| **Malicious or compromised relay** | Reads, drops, delays, replays and injects relay messages; swaps identity cards |
| **Compromised TURN server** | Sees and relays encrypted media packets and IP addresses |
| **Curious hosting provider / legal request** | Gets disk images, server logs, memory at a point in time |
| **Malicious call participant** | Holds valid keys for their own identity; may record or forward what they receive |
| **Stolen or lost device** | Physical access to a professional's device |

## 3. Guarantees and how they are achieved

| Threat | Mitigation | Status |
|---|---|---|
| Network attacker reads signaling | TLS (`wss://`) to the relay **and** end-to-end envelopes | Phase 2 ✅ (envelopes); TLS via Caddy ✅ |
| Relay reads call setup data | Envelopes are sealed to the recipient's X25519 key; relay sees ciphertext only. The end-to-end test asserts no SDP or candidates reach the relay in readable form | ✅ |
| Relay forges or alters messages | Ed25519 signature over the inner message; any change fails verification | ✅ |
| Relay replays old messages | 2-minute timestamp window + nonce cache | ✅ |
| Participant re-addresses a signed message to someone else | Signed `to` field | ✅ |
| Relay swaps identity cards (man in the middle) | Safety numbers shown to both people; mismatch reveals interception. Signed guest links (Phase 5) and verified contacts (Phase 6) remove the need to trust the first exchange | Detectable ✅; prevented from Phase 5 |
| Relay or TURN reads media | WebRTC DTLS-SRTP; the DTLS fingerprints travel inside signed envelopes, so a relay can't substitute its own | ✅ |
| Disk seizure of servers | No database, read-only containers, no request logs; an automated test runs the real relay process and fails if it writes any file | ✅ |
| Someone logs in to the relay as another person | Challenge-response login: the device signs a fresh random challenge bound to the relay's hostname with its identity key; signatures can't be replayed or forwarded from another server | ✅ |
| Someone injects messages "from" another person | The relay attaches the authenticated sender; apps additionally require the envelope signature to match it | ✅ |
| Strangers reach a professional through a guest link | Links carry a random secret checked on the professional's device; links can be replaced or revoked, one-time links are used up on admission and expire after 7 days; guests only *knock* and nothing happens until the professional admits them | ✅ |
| A forged or altered guest link (e.g. a phishing page showing a different name) | Links are signed by the professional's identity key and verified in the guest's browser before anything is sent; any change makes the page show "This link is not valid" | ✅ |
| Guest link secrets leak to servers | The payload is in the URL fragment (`#…`), which browsers never send to web servers; knocks travel inside end-to-end envelopes | ✅ |
| Guest page loads third-party resources (CDNs, Google Fonts) that learn visitors' IPs | Built with `--no-web-resources-cdn`, fonts bundled, fallback fonts only from our server; the e2e tests fail if a page contacts any other host | ✅ |
| Auto-answer abused to listen in on someone (a caller, or a person who secretly enables it on someone else's device) | Off by default; only the device's owner can enable it, on that device; never controllable by a caller; only for verified contacts (safety number compared; exact key match) chosen one by one; turning it on, choosing people and changing the ring time all require the app lock's PIN; rings first (default 5 s) so it can be declined; voice only unless video is allowed per person; "Auto-answered" banner on both sides; permanent home-screen reminder naming who is trusted while it is on; never interrupts an ongoing call | ✅ |
| The other person learns your IP address | Optional **Hide my IP address**: relay-only ICE, so only the TURN server's address is exchanged | ✅ |
| TURN server used as an open proxy into private networks | coturn refuses relaying to private, loopback, link-local and other special ranges; TCP relaying disabled | ✅ |
| TURN credentials abused | Issued only to logged-in relay clients; expire after 6 hours; per-user and total allocation quotas; bandwidth cap per session | ✅ |
| TURN server links calls to people | Usernames are `<expiry>:<random>`, never a Sotto ID; coturn's logs are discarded | ✅ |
| Third parties (Google STUN) see users' IPs | The relay hands out Sotto's own STUN server; Google STUN is only a fallback for relays that offer none | ✅ |
| Flooding / resource exhaustion | In-memory limits: messages per connection, connections per address (addresses kept only as keyed hashes), devices per ID, message size, 60 s offline queue with per-recipient and total caps | ✅ |
| Stolen or copied device storage (disk image, phone backup, another user on a shared PC) | Contacts, history, notes and settings are in an encrypted vault whose key is in the OS keystore, never next to the file; the identity's master secret is in the keystore too | ✅ |
| Someone picks up the unlocked device and the app is open | App lock with a PIN (auto-lock after leaving the app, *Lock now*); wrong PINs make the next try wait (30 s, doubling to an hour, counted across restarts). Auto-answer, backups, changing or removing the PIN and erasing all ask for the PIN | ✅ (biometrics: Phase 12) |
| Stolen device: identity theft | Master secret in the OS keystore (hardware-backed where available); the app lock hides the app. Someone who can unlock the operating system and extract keystore items (e.g. root on Android) can still copy the identity: the user should then create a new identity and tell contacts | Partial |
| Notifications reveal who is calling or waiting (screen visible to others, the system's notification history) | Desktop notifications say only "A guest is waiting" / "Incoming call" unless the user turns on names; never names while the app is locked | ✅ |
| Someone switches a professional's app to a server they control | Changing the server asks for the PIN when the app lock is on; the app checks a Sotto relay answers. Even then the server can't read calls (end-to-end encryption, safety numbers); it would see metadata, like any relay | ✅ |
| Self-hosted server misconfigured (proxy in front, logs on) | `install.sh` refuses Cloudflare-proxied domains, generates a private TURN secret, keeps containers read-only and coturn's logs discarded; `SELF_HOSTING.md` lists what the server sees | ✅ |
| Backup file falls into the wrong hands | Encrypted with Argon2id (64 MiB, 3 passes) + XChaCha20-Poly1305; passphrase of at least 12 characters, or a generated 125-bit one; header parameters are authenticated, and absurd parameters are refused when opening | ✅ (as strong as the passphrase) |
| A forged contact link (someone else's keys under a colleague's name) | The name is signed by the key in the link, but anyone can sign their own name. Contacts start as *not verified*; only comparing the safety number marks them verified, and only verified contacts can be auto-answered | ✅ |
| Malformed input crashes or confuses clients | Strict parsing; every failure is a typed rejection; fuzz tests | ✅ |

## 4. Known limitations (accepted for now)

1. **No forward secrecy for signaling (v1).** Envelopes use long-term X25519 keys. If a professional's master secret is stolen, an attacker who also recorded past relay traffic could decrypt past call-setup messages (IP addresses, codec details, timing). Call media is **not** affected (DTLS-SRTP uses ephemeral keys). Possible future fix: per-call ephemeral keys or a ratchet.
2. **The TURN server sees the IP addresses of relayed calls** (both ends) and their timing and volume, while the call lasts. It cannot decrypt media. It does not log, and it does not know which Sotto IDs are involved, but whoever controls the server could watch live traffic. Self-hosting keeps this in-house.
3. **Relay sees live metadata.** While connected, the relay knows which IDs are online, which ID sends to which, message sizes and timing, and IP addresses. It does not log or store them. Self-hosting removes the third party entirely.
4. **First contact: guests are protected by signed links; colleagues by verified contacts.** A guest link is signed by the professional's key, so a malicious relay can't impersonate the professional to a guest who received the link through another channel. A contact link carries the colleague's keys, so calls go to the right key from the start; whether the link really came from that colleague is confirmed by comparing the safety number once (the contact is then marked verified). A guest's *name* and a contact link's name are self-chosen.
5. **Call links and contact links are permanent.** Anyone who has a person's call link or contact link can ring them (these are meant for colleagues); guest links (waiting room, replaceable, one-time) are the recommended way to give access to clients. The receiving app only rings; nothing happens without the person accepting.
6. **Local data is only as safe as the operating system.** The vault key and the identity live in the OS keystore. Malware on the device, or someone who can unlock the device and read the keystore, can read them. The app lock is a screen lock: while the app runs, the vault is open in memory so that calls can ring.
7. **Clock dependence.** Devices with clocks more than 2 minutes off can't exchange messages. They will get a clear error once the real relay protocol exists.
8. **Web guests run code served by the web server.** A compromised web host could serve modified JavaScript. Mitigations to consider: subresource integrity, reproducible builds, published hashes, and encouraging professionals to use the native app.
9. **Endpoint compromise** (malware on a participant's device) is out of scope; no messaging system can protect against it.
10. **No external audit yet.** Planned before public launch (Phase 13).

## 5. Cryptographic choices

| Purpose | Primitive |
|---|---|
| Identity key derivation | `crypto_kdf` (BLAKE2b) from a 32-byte master secret |
| Signatures | Ed25519 (`crypto_sign`) |
| Encryption | `crypto_box_seal` (X25519 + XSalsa20-Poly1305, ephemeral sender key) |
| Local vault, backups | XChaCha20-Poly1305 (`crypto_aead_xchacha20poly1305_ietf`) |
| Backup passphrases, app-lock PIN | Argon2id (`crypto_pwhash`, `crypto_pwhash_str`) |
| Safety numbers | BLAKE2b-512 (`crypto_generichash`) |
| Randomness | libsodium `randombytes` (OS CSPRNG) |
| Media | WebRTC DTLS-SRTP |

Every primitive is used through libsodium's high-level API. Details: [`PROTOCOL.md`](PROTOCOL.md).
