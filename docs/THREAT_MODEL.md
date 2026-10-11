# Sotto Threat Model (v0.8 — group chats and chat export)

This is a living document. It records what Sotto protects, against whom, and what it honestly does not protect yet. Update it whenever the design changes.

## 1. What we protect

| Asset | Where it lives |
|---|---|
| Call audio and video | In transit only (WebRTC DTLS-SRTP), device to device |
| Call setup data (SDP, ICE candidates: IP addresses, codec details) | In transit, inside end-to-end envelopes |
| Chat messages (text), one-to-one and in groups | In transit, directly between two devices over an encrypted data channel. When no direct chat is ready, a plain text also goes through the relay as a sealed `chat.text` envelope (`group.text` in a group), which the relay holds in RAM for at most 60 s and can't read |
| Group chats (name, member list, messages) | Each member's device, in the encrypted vault; in transit as above, one copy per member |
| Identities (master secret) | Professional's device, in the OS keystore (in the browser: memory only, or the browser's storage with *Remember me*, §9.1 of `PROTOCOL.md`); guests: memory only |
| Contacts, call history, chat history, notes | Professional's device only, in the encrypted vault (`PROTOCOL.md` §9) |
| Backups | Wherever the user saves them, encrypted with their passphrase (`PROTOCOL.md` §8) |
| Chat exports | Wherever the user saves the file. Encrypted with a passphrase by default; plain text only if the user chooses it (`PROTOCOL.md` §8A) |
| Metadata: who talks to whom, when, from which IP, and who is in a group with whom | Seen briefly by the relay in RAM; never stored |

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
| Relay replays old messages | 2-minute timestamp window + nonce cache. The cache is in memory only, so a message replayed within 2 minutes of an app restart is accepted | ✅ |
| Participant re-addresses a signed message to someone else | Signed `to` field | ✅ |
| Relay swaps identity cards (man in the middle) | Safety numbers shown to both people; mismatch reveals interception. Signed guest links (Phase 5) and verified contacts (Phase 6) remove the need to trust the first exchange | Detectable ✅; prevented from Phase 5 |
| Relay or TURN reads media | WebRTC DTLS-SRTP; the DTLS fingerprints travel inside signed envelopes, so a relay can't substitute its own | ✅ |
| Relay or TURN reads chat messages | Chat text travels over the direct WebRTC data channel (DTLS). When no direct chat is ready, a plain text also goes as a sealed `chat.text` envelope (`group.text` in a group, one per member), which the relay holds in memory for at most 60 seconds and can't read. Files, voice notes, replies, forwarded texts, reactions, edits and deletes go only over the data channel | ✅ |
| Relay reads group chats | Every group envelope and frame is sealed or sent to one member only. The group name and member list travel only inside sealed envelopes and direct frames. Group bodies are padded to a multiple of 1 KiB, so the relay sees a size bucket, not the exact size (limitation 16) | ✅ for content; membership and timing are visible (limitation 16) |
| A stranger adds you to a group, or a member forges another member's message | An invite from someone who is not a contact is dropped. A device can join only if every member is its contact. No member forwards another's messages: each message comes over its author's own session or sealed envelope, and edits and deletes apply only to the author's own messages. A reply in a group quotes only the replier's own message. Read receipts go only to a message's author | ✅ |
| An exported chat falls into the wrong hands | Encrypted by default with Argon2id + XChaCha20-Poly1305, as backups are; passphrase of at least 12 characters. The file holds one chat only: no keys, identity, other chats, pending controls or file contents (`PROTOCOL.md` §8A). A plain-text export is not protected (limitation 20) | ✅ (encrypted: as strong as the passphrase) |
| Someone who later steals a key decrypts recorded chat messages | Each chat session has its own DTLS keys, discarded when it ends, so a stolen identity key does not reveal past message text. The set-up envelopes do use long-term keys (limitation 1) | ✅ for message text |
| A contact sends unwanted or harmful files | A file is only offered: nothing is downloaded until the receiver taps Accept, unless they turn on *Download files automatically* (off by default). Voice notes from contacts are downloaded at once, within their size caps and format checks. Blocked types are refused, and nothing opens automatically | ✅ |
| A stranger sends a chat message | Only contacts can open a chat; anyone else gets `chat.decline` (`not-contact`) and nothing is shown | ✅ |
| Message text shown on a lock screen or in the notification history | Notifications say "New message"; the sender's name appears only with *Show names in notifications* on and the app unlocked. The text is never in a notification, and a group's name never is | ✅ |
| Disk seizure of servers | No database, read-only containers, no request logs; an automated test runs the real relay process and fails if it writes any file | ✅ |
| Someone logs in to the relay as another person | Challenge-response login: the device signs a fresh random challenge, bound to the relay's own name (`SOTTO_DOMAIN`, sent in the challenge and checked by the app); a login can't be forwarded to another server, which doesn't accept a signature over its name from a connection to a different one | ✅ |
| Someone injects messages "from" another person | The relay attaches the authenticated sender; apps additionally require the envelope signature to match it | ✅ |
| Strangers reach a professional through a guest link | Links carry a random secret checked on the professional's device; links can be replaced or revoked, one-time links are used up on admission and expire after 7 days; guests only *knock* and nothing happens until the professional admits them | ✅ |
| A forged or altered guest link (e.g. a phishing page showing a different name) | Links are signed by the professional's identity key and verified in the guest's browser before anything is sent; any change makes the page show "This link is not valid" | ✅ |
| Guest link secrets leak to servers | The payload is in the URL fragment (`#…`), which browsers never send to web servers; knocks travel inside end-to-end envelopes | ✅ |
| Guest page loads third-party resources (CDNs, Google Fonts) that learn visitors' IPs | Built with `--no-web-resources-cdn`, fonts bundled, fallback fonts only from our server; the e2e tests fail if a page contacts any other host | ✅ |
| Auto-answer abused to listen in on someone (a caller, or a person who secretly enables it on someone else's device) | Off by default; only the device's owner can enable it, on that device; never controllable by a caller; only for verified contacts (safety number compared; exact key match) chosen one by one; turning it on, choosing people and changing the ring time all require the app lock's PIN; rings first (default 5 s) so it can be declined; voice only unless video is allowed per person; "Auto-answered" banner on both sides; permanent home-screen reminder naming who is trusted while it is on; never interrupts an ongoing call | ✅ |
| The other person learns your IP address | Optional **Hide my IP address** (calls and chats): relay-only ICE, so only the TURN server's address is exchanged | ✅ |
| TURN server used as an open proxy into private networks | coturn refuses relaying to private, loopback, link-local and other special ranges, and to the server's own public address when it is behind NAT; TCP relaying disabled | ✅ |
| TURN credentials abused | Issued only to logged-in relay clients; expire after 6 hours; per-user and total allocation quotas; bandwidth cap per session | ✅ |
| TURN server links calls to people | Usernames are `<expiry>:<random>`, never a Sotto ID; coturn's logs are discarded | ✅ |
| Third parties (Google STUN) see users' IPs | The relay hands out Sotto's own STUN server; Google STUN is only a fallback for relays that offer none | ✅ |
| Flooding / resource exhaustion | In-memory limits: messages per connection, connections per address (addresses kept only as keyed hashes), devices per ID, message size, 60 s offline queue with per-recipient and total caps | ✅ |
| Stolen or copied device storage (disk image, phone backup, another user on a shared PC) | Contacts, history, notes and settings are in an encrypted vault whose key is in the OS keystore, never next to the file; the identity's master secret is in the keystore too. Received files are encrypted one by one, each with its own key kept in the vault, so deleting a message makes its file unreadable (`docs/PROTOCOL.md` §9). Limit: a decrypted copy made by "Open" stays in the temporary folder until the app next starts | ✅ |
| A browser that remembers the identity ("Remember me on this browser") is used or copied by someone else | Off by default, and the screens say to use it only on one's own computer. Secrets are encrypted with a non-extractable Web Crypto key, so scripts can't copy the key out; the app lock's PIN guards the screens; *Forget this browser* deletes everything. Anyone who can use that browser profile, or copy its files, can still open the identity (see limitation 11) | Partial |
| Someone picks up the unlocked device and the app is open | App lock with a PIN (auto-lock after leaving the app, *Lock now*); wrong PINs make the next try wait (30 s, doubling to an hour, counted across restarts). Auto-answer, backups, changing or removing the PIN and erasing all ask for the PIN | ✅ (biometrics: Phase 12) |
| Stolen device: identity theft | Master secret in the OS keystore (hardware-backed where available); the app lock hides the app. Someone who can unlock the operating system and extract keystore items (e.g. root on Android) can still copy the identity: the user should then create a new identity and tell contacts | Partial |
| Notifications reveal who is calling or waiting (screen visible to others, the system's notification history) | Desktop notifications say only "A guest is waiting" / "Incoming call" unless the user turns on names; never names while the app is locked | ✅ |
| Someone switches a professional's app to a server they control | Changing the server asks for the PIN when the app lock is on; the app checks a Sotto relay answers. Even then the server can't read calls (end-to-end encryption, safety numbers); it would see metadata, like any relay | ✅ |
| Self-hosted server misconfigured (proxy in front, logs on) | `install.sh` refuses Cloudflare-proxied domains, generates a private TURN secret, keeps containers read-only and coturn's logs discarded; `SELF_HOSTING.md` lists what the server sees | ✅ |
| Backup file falls into the wrong hands | Encrypted with Argon2id (64 MiB, 3 passes) + XChaCha20-Poly1305; passphrase of at least 12 characters, or a generated 125-bit one; header parameters are authenticated, and absurd parameters are refused when opening | ✅ (as strong as the passphrase) |
| A forged contact link (someone else's keys under a colleague's name) | The name is signed by the key in the link, but anyone can sign their own name. Contacts start as *not verified*; only comparing the safety number marks them verified, and only verified contacts can be auto-answered | ✅ |
| Voice notes left in plaintext on disk. iOS, macOS and Linux play from a decrypted copy, and recording writes a temporary file | The playback copy is removed when playback stops, completes or the player is disposed. A recording is read and deleted at once, and one that fails to stop is deleted too. Both sit in the temporary folder that the app clears at start and on erase, so a crash can leave one until the next start. Android, Windows and the browser play from memory (`docs/PROTOCOL.md` §9) | ✅ (a crash leaves a copy until the next start) |
| Malformed input crashes or confuses clients | Strict parsing; every failure is a typed rejection; fuzz tests | ✅ |

## 4. Known limitations (accepted for now)

1. **No forward secrecy for signaling (v1).** Envelopes use long-term X25519 keys. If a professional's master secret is stolen, an attacker who also recorded past relay traffic could decrypt past call-setup messages (IP addresses, codec details, timing). Call media is **not** affected (DTLS-SRTP uses ephemeral keys). Possible future fix: per-call ephemeral keys or a ratchet.
2. **The TURN server sees the IP addresses of relayed calls** (both ends) and their timing and volume, while the call lasts. It cannot decrypt media. It does not log, and it does not know which Sotto IDs are involved, but whoever controls the server could watch live traffic. Self-hosting keeps this in-house.
3. **Relay sees live metadata.** While connected, the relay knows which IDs are online, which ID sends to which, message sizes and timing, and IP addresses. It does not log or store them. Self-hosting removes the third party entirely.
4. **First contact: guests are protected by signed links; colleagues by verified contacts.** A guest link is signed by the professional's key, so a malicious relay can't impersonate the professional to a guest who received the link through another channel. A contact link carries the colleague's keys, so calls go to the right key from the start; whether the link really came from that colleague is confirmed by comparing the safety number once (the contact is then marked verified). A guest's *name* and a contact link's name are self-chosen.
5. **Call links and contact links are permanent.** Anyone who has a person's call link or contact link can ring them (these are meant for colleagues); guest links (waiting room, replaceable, one-time) are the recommended way to give access to clients. The receiving app only rings; nothing happens without the person accepting.
6. **Local data is only as safe as the operating system.** The vault key and the identity live in the OS keystore. Malware on the device, or someone who can unlock the device and read the keystore, can read them. The app lock is a screen lock: while the app runs, the vault is open in memory so that calls can ring.
7. **Clock dependence.** Devices with clocks more than 2 minutes off can't exchange messages. The receiving app drops such messages without telling anyone, so calls and chats simply fail.
8. **Web app users run code served by the web server**, guests and professionals alike. A compromised web host could serve modified JavaScript. Mitigations to consider: subresource integrity, reproducible builds, published hashes, and encouraging professionals to use the native app.
9. **Endpoint compromise** (malware on a participant's device) is out of scope; no messaging system can protect against it.
10. **No external audit yet.** Planned before public launch (Phase 13).
11. **A remembered browser is as safe as that browser profile.** With *Remember me on this browser*, the identity stays in the browser's storage. The wrapping key is non-extractable, but browsers keep it in the profile's files, and the browser's PIN is stored as an Argon2id hash, like the apps'. A PIN set before this change is stored again on its next successful unlock. Someone who can use or copy the profile can therefore use the identity. Use it on your own computer only; on shared computers, keep the default (nothing kept), and prefer the apps.
12. **Chat needs the sender's app to be running.** A message for an offline contact waits on the sender's device and is sent again on each check (every 30 seconds) while the sender's app runs; the relay keeps a text for at most 60 seconds. If the sender's app closes before the contact or group member is back, nothing more is sent until the app runs again. Files and voice notes queued for an offline contact are offered when the contact is back, and go through the same checks as any other file. A direct chat shows each person the other's IP address, as a call does, unless Hide my IP address is on.
13. **Chat history stays until it is deleted.** Each chat stays on the device until its owner deletes it or removes the app, unless the owner turns on disappearing messages for that one-to-one chat (24 hours, 7 days or 30 days). That setting works only on the device where it is set: the other person's copy is not affected. The call-history retention setting does not apply to chats, and chats are not synced between one person's devices.
14. **"Save to Downloads" leaves a plaintext copy.** On Android, *Save to Downloads* writes a decrypted copy of a received file to the shared Downloads folder. Other apps with storage access can read it, and it stays there until the user deletes it; deleting the message does not remove it.
15. **Your profile photo goes to anyone with your short link.** Whoever opens your short call or contact link while your app is online gets your name, practice and profile photo (sealed to them, so the relay can't see them). Don't use a photo you wouldn't put on a business card.
16. **The relay learns group membership and the timing and size of each copy.** A group message goes to each member separately, so the relay sees each member's key (in `to`), and from the invites, answers and each pair's sessions it can work out who is in a group with whom. It also sees when each copy is sent and roughly how large it is. Group envelope and frame bodies are padded to the smallest multiple of 1 KiB (at most 16 KiB), which hides only the exact size; it does not hide membership or timing. One-to-one `chat.text` envelopes are not padded. The relay does not see the group's name, its id or any text. Self-hosting keeps this in-house.
17. **Edits and deletes for everyone can't be enforced.** An edit or a delete for everyone is a request to the other devices. A modified app can ignore it, a device that is offline for more than seven days never applies it, and a copy already made (a screenshot, an export, a copy of the text) keeps the earlier text. The app says that the other person may keep a copy.
18. **Group members see each other.** Every member sees the group's name, every member's Sotto ID and the name each one has as a contact, and all messages, reactions and edits in the group. An invite lists every member's Sotto ID, so even someone who declines learns who was invited.
19. **Repeat relay sends are visible to the relay.** A text that the contact has not acknowledged is sent again through the relay every 30 seconds for 15 minutes while the sender's app is open, each time as a new sealed envelope. A text the user queues is sent again on every check, with no time limit, while the app is open. Group texts, invites and invite answers are repeated the same way, for about 15 minutes. The relay can't read these copies, but it can see that the same sender keeps sending to the same recipient.
20. **An exported chat is only as safe as its file.** An encrypted export is sealed with the user's passphrase (Argon2id), so it is as strong as that passphrase. A plain-text export is readable by anyone who has the file; the app makes it only after the user confirms a warning. Once saved, the file is outside Sotto's control: deleting the chat does not delete it.

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
| Chat text | WebRTC data channel (DTLS), keys per session |

Every primitive is used through libsodium's high-level API. Details: [`PROTOCOL.md`](PROTOCOL.md).
