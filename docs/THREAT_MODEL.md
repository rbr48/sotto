# Sotto Threat Model (v0.2 — Phase 2)

This is a living document. It records what Sotto protects, against whom, and what it honestly does not protect yet. Update it whenever the design changes.

## 1. What we protect

| Asset | Where it lives |
|---|---|
| Call audio and video | In transit only (WebRTC DTLS-SRTP), device to device |
| Call setup data (SDP, ICE candidates: IP addresses, codec details) | In transit, inside end-to-end envelopes |
| Identities (master secret) | Professional's device, in the OS keystore; guests: memory only |
| Contacts, call history, notes, recordings | Professional's device only (encrypted local storage arrives in Phase 6) |
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
| Disk seizure of servers | No database, read-only containers, no request logs | ✅ (Phase 3 adds automated "no persistence" test) |
| Stolen device: identity theft | Master secret in the OS keystore (hardware-backed where available); app lock in Phase 6 | Partial |
| Malformed input crashes or confuses clients | Strict parsing; every failure is a typed rejection; fuzz tests | ✅ |

## 4. Known limitations (accepted for now)

1. **No forward secrecy for signaling (v1).** Envelopes use long-term X25519 keys. If a professional's master secret is stolen, an attacker who also recorded past relay traffic could decrypt past call-setup messages (IP addresses, codec details, timing). Call media is **not** affected (DTLS-SRTP uses ephemeral keys). Possible future fix: per-call ephemeral keys or a ratchet.
2. **Relay sees live metadata.** While connected, the relay knows which IDs are online, which ID sends to which, message sizes and timing, and IP addresses. It does not log or store them. Self-hosting removes the third party entirely.
3. **First contact is trust-on-first-use** until signed guest links (Phase 5): users must compare safety numbers to detect a malicious relay.
4. **Proof-of-concept relay (`/dev/rooms`)** has no authentication; anyone who knows a room code can join an empty slot. It is for testing only and will be removed in Phase 3.
5. **Clock dependence.** Devices with clocks more than 2 minutes off can't exchange messages. They will get a clear error once the real relay protocol exists.
6. **Web guests run code served by the web server.** A compromised web host could serve modified JavaScript. Mitigations to consider: subresource integrity, reproducible builds, published hashes, and encouraging professionals to use the native app.
7. **Endpoint compromise** (malware on a participant's device) is out of scope; no messaging system can protect against it.
8. **No external audit yet.** Planned before public launch (Phase 13).

## 5. Cryptographic choices

| Purpose | Primitive |
|---|---|
| Identity key derivation | `crypto_kdf` (BLAKE2b) from a 32-byte master secret |
| Signatures | Ed25519 (`crypto_sign`) |
| Encryption | `crypto_box_seal` (X25519 + XSalsa20-Poly1305, ephemeral sender key) |
| Safety numbers | BLAKE2b-512 (`crypto_generichash`) |
| Randomness | libsodium `randombytes` (OS CSPRNG) |
| Media | WebRTC DTLS-SRTP |

Every primitive is used through libsodium's high-level API. Details: [`PROTOCOL.md`](PROTOCOL.md).
