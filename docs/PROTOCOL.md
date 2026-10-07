# Sotto Protocol — Identity, Envelopes and Local Storage (v1)

This document specifies how Sotto identities are formed, how messages are encrypted end to end, and how the app stores and backs up data on the device. It is implemented in `app/lib/crypto/` (Dart, native and web) and independently in `tools/crypto-vectors/gen.js` (Node.js), which produces the known-answer test vectors in `app/lib/crypto/test_vectors.dart`.

All primitives come from **libsodium 1.0.22** (native build on Android/Windows/Linux; libsodium.js 0.8.4 on the web). No custom cryptographic primitives are used.

## 1. Conventions

- **base64url** means RFC 4648 §5 *without* padding. Decoders must reject padding, the standard alphabet, and non-canonical encodings (for example `AB` for a single byte), so every value has exactly one text form.
- **Domain labels** are ASCII strings followed by a single zero byte, written as `"label\0"`. They make each signature and hash usable for exactly one purpose.
- `||` is byte concatenation.

## 2. Identity

### 2.1 Keys

Every identity is derived from a 32-byte **master secret**:

| Key | Derivation |
|---|---|
| Ed25519 signing key pair | `crypto_sign_seed_keypair(crypto_kdf_derive_from_key(32, 1, "sottoid1", master))` |
| X25519 encryption key pair | `crypto_box_seed_keypair(crypto_kdf_derive_from_key(32, 2, "sottoid1", master))` |

- **Professionals** generate the master secret once (`crypto_kdf_keygen`) and keep it in the operating system keystore (Android Keystore, Windows DPAPI, Linux libsecret). Backups only need the master secret.
- **Guests** generate a fresh identity for each call and keep it only in memory.

Separate keys for signing and encryption avoid converting Ed25519 keys to X25519, which would require libsodium's larger "sumo" build on the web, and keep each key to a single purpose.

### 2.2 Identity ID

A user's **ID** (their address on the relay) is the base64url Ed25519 public key: 43 characters.

### 2.3 Identity card

An identity card binds the encryption key to the signing key so it can be sent over an untrusted channel:

```json
{"v":1,"sign":"<Ed25519 pk>","box":"<X25519 pk>","sig":"<signature>"}
```

`sig = crypto_sign_detached("sotto-card-v1\0" || sign_pk || box_pk, sign_sk)`

A valid card proves that the holder of the signing key chose this encryption key. It does **not** prove who the person is; safety numbers (§4) and, later, signed guest links do that.

## 3. Envelopes

Every end-to-end message is an envelope: a signed inner message, sealed to the recipient.

### 3.1 Inner message

UTF-8 JSON object:

| Field | Type | Meaning |
|---|---|---|
| `v` | int | Protocol version, `1` |
| `from` | string | Sender ID (base64url Ed25519 pk) |
| `fromBox` | string | Sender's X25519 pk, so the recipient can reply |
| `to` | string | Recipient ID |
| `ts` | int | Sender's clock, Unix milliseconds |
| `n` | string | 16 random bytes, base64url |
| `type` | string | Message type, e.g. `sdp.offer` |
| `callId` | string? | Optional call identifier |
| `body` | object | Type-specific content |

Maximum inner size: 48 KiB.

### 3.2 Sealing

```
signature = crypto_sign_detached("sotto-msg-v1\0" || inner, sender.sign_sk)    // 64 bytes
envelope  = base64url(crypto_box_seal(signature || inner, recipient.box_pk))
```

The signature is computed over the exact inner bytes that are sent, so no JSON canonicalisation is needed.

### 3.3 Opening

A recipient MUST perform these checks in order, and reject the envelope at the first failure:

| # | Check | Error |
|---|---|---|
| 1 | Valid base64url, at least `sealBytes + 64 + 2` bytes | `malformed` |
| 2 | `crypto_box_seal_open` succeeds with own encryption key | `undecryptable` |
| 3 | Inner is valid JSON with all fields, `v == 1`, 32-byte keys, 16-byte nonce, non-empty `type` | `invalidMessage` |
| 4 | `to` equals own ID | `wrongRecipient` |
| 5 | Signature verifies against `from` | `badSignature` |
| 6 | If an expected sender is known (relay-authenticated address, or the call's peer), `from` equals it | `unexpectedSender` |
| 7 | `now − 2 min ≤ ts ≤ now + 2 min` | `expired` |
| 8 | `(from, n)` not seen in the last 4 min 1 s | `replayed` |

Only after all checks pass is `(from, n)` recorded.

### 3.4 Properties

- **Confidentiality:** only the recipient's X25519 key opens the envelope. The relay sees only the outer routing data.
- **Sender authentication:** the Ed25519 signature; the sealed box itself is anonymous.
- **No re-addressing:** `to` is signed, so a recipient can't forward a signed message to a third party as if it were addressed to them.
- **Replay protection:** timestamp window plus nonce cache.
- **Not provided in v1:** forward secrecy for signaling. Compromise of a long-term encryption key would expose past signaling captured by an attacker (SDP, ICE candidates, call metadata). Call **media** keeps forward secrecy, because DTLS-SRTP keys are ephemeral. See `THREAT_MODEL.md`.

## 4. Safety numbers

```
(lo, hi) = the two Ed25519 public keys, sorted by bytes
h        = BLAKE2b-512("sotto-safety-v1\0" || lo || hi)       // crypto_generichash, 64 bytes, no key
groups   = for i in 0..11: (big-endian uint40 of h[5i .. 5i+5]) mod 100000, zero-padded to 5 digits
number   = groups joined with spaces                             // 12 groups, 60 digits
```

Both people compute the same number. If a relay substituted either identity card, the numbers would differ.

## 5. Relay protocol (Phase 3)

The relay (`server/src/relay/`) routes envelopes between Sotto IDs over a WebSocket at `/relay`. All frames are UTF-8 JSON.

### 5.1 Login

```
server → {"type":"challenge","nonce":"<32 random bytes>"}
client → {"type":"auth","id":"<Sotto ID>","sig":"<signature>"}
server → {"type":"ready","id":"<Sotto ID>"}            or  {"type":"error","code":"auth-failed"} + close 4001
```

`sig = crypto_sign_detached("sotto-relay-auth-v1\0" || nonce || lowercase(host), sign_sk)`, where `host` is the HTTP `Host` the client connected to (`name` or `name:port` for non-default ports). Binding the host stops a malicious relay from forwarding this server's challenge to a victim and reusing the signature. Clients that don't log in within 10 s are disconnected (close 4002).

### 5.2 Messages

```
client → {"type":"send","to":"<Sotto ID>","body":"<envelope>","ref":"<optional, ≤64 chars>"}
server → {"type":"message","from":"<authenticated sender ID>","body":"<envelope>"}     (to every device of the recipient)
server → {"type":"ack","ref":"…","status":"delivered" | "queued" | "dropped"}           (only if ref was given)
server → {"type":"error","code":"bad-message" | "bad-recipient" | "too-large" | "rate-limited" | "not-authenticated" | …}
```

- The relay never reads `body`. It attaches `from` itself; anything the client puts there is ignored.
- Recipients receive `from` and must open the envelope with `expectedSender = from` (§3.3 check 6).
- If the recipient has no connected device, the envelope is held **in memory** for up to 60 s (at most 50 per recipient, 64 MiB in total) and delivered when they log in; otherwise it is dropped.

### 5.3 STUN/TURN servers

`ready` carries `"ice": [ {"urls": ["stun:…"]}, {"urls": ["turn:…", "turns:…"], "username": "…", "credential": "…"} ]`, usable directly as WebRTC `iceServers`. Clients refresh credentials older than one hour before a call with `{"type":"ice"}` → `{"type":"ice","ice":[…]}`. Only logged-in clients receive credentials.

TURN credentials follow coturn's `use-auth-secret` scheme: `username = "<unix expiry>:<random>"`, `credential = base64(HMAC-SHA1(secret, username))`, valid for 6 hours. Usernames contain no Sotto ID, and nothing is stored.

With **Hide my IP address**, the app sets `iceTransportPolicy: "relay"`, so it only offers TURN relay candidates and the other person never learns its IP address.

### 5.4 Limits (in memory, defaults)

| Limit | Value |
|---|---|
| WebSocket frame | 96 KiB |
| Envelope (`body`) | 72 Ki characters |
| Messages per connection | 20/s, bursts of 60 |
| Connections per network address | 20 (addresses kept only as an HMAC under a random per-process key) |
| Devices per Sotto ID | 5 |

### 5.5 Call messages (inside envelopes)

| `type` | Direction | `body` |
|---|---|---|
| `call.invite` | caller → callee | `{"video": bool}` |
| `call.ringing` | callee → caller | `{}` |
| `call.accept` / `call.reject` | callee → caller | `{}` |
| `call.busy` | callee → caller | `{}` (callee is in another call) |
| `call.cancel` | caller → callee | `{}` (hung up before answer, or 45 s without answer) |
| `call.end` | either | `{}` |
| `sdp.offer` / `sdp.answer` | caller → callee / callee → caller | `{"sdp": "…"}` |
| `ice.candidate` | either | `{"candidate", "sdpMid", "sdpMLineIndex"}` |

`call.accept` may carry `{"auto": true}` when the callee's device answered automatically (an admitted guest, or a trusted caller with auto-answer on); both sides then show *Auto-answered* (not shown for guest admissions). Every call message carries the same random `callId` (16 bytes). Messages for another call, or from anyone but the call's peer, are ignored. An incoming call stops ringing after 60 s if no `call.cancel` arrives; media setup must finish within 30 s of acceptance.

### 5.6 Call links (Phase 3)

A call link is `https://<host>/?call=<base64url(identity card JSON)>`. It contains only public keys and lets anyone ring its owner. Opened in a browser, it dials right away with a temporary identity. Clients should get guest links (§5.7) instead; colleagues, contact links (§5.8).

### 5.7 Guest links (Phase 5)

A guest link is `https://<host>/#g=<payload>`. Everything after `#` stays in the browser and is never sent to the web server or the relay.

`payload = base64url(JSON {v:1, card, lid, s, n, exp?, sig})`:

| Field | Meaning |
|---|---|
| `card` | The professional's identity card (§2.3) |
| `lid` | Link ID (16 random bytes) |
| `s` | Link secret (16 random bytes); proves the guest holds the link |
| `n` | Name shown to the guest |
| `exp` | Optional expiry (Unix seconds); one-time links expire after 7 days |
| `sig` | `Ed25519("sotto-link-v1\0" || JSON[sign_pk, box_pk, lid, s, n, exp])` by the professional |

The guest's page verifies the card and `sig` (rejecting tampered or expired links) before sending anything. The professional's app keeps its links only on the device (OS keystore) and checks every knock against them: unknown link or wrong secret, revoked, expired, or already-used one-time link → declined with that reason.

Guest messages (inside envelopes, no `callId`):

| `type` | Direction | `body` |
|---|---|---|
| `guest.knock` | guest → professional, repeated every 25 s while waiting | `{"knock", "link", "secret", "name", "video"}` |
| `guest.leave` | guest → professional | `{"knock"}` |
| `guest.declined` | professional → guest | `{"knock", "reason": "declined" \| "unknown" \| "revoked" \| "expired" \| "used" \| "full"}` |
| `guest.message` | professional → guest | `{"knock", "text"}` (quick replies) |

Admitting a guest is an ordinary call (§5.5) from the professional whose `call.invite` body carries `"knock": "<knock id>"`; the guest's page answers it immediately because it matches its own knock from that professional (`call.accept` carries `"auto": true`). A waiting guest who stops knocking for 75 s (closed tab) disappears from the waiting room; at most 20 guests wait at once.

### 5.8 Contact links (Phase 6)

A contact link lets colleagues add each other: `https://<host>/#c=<payload>` (after `#`, so it never reaches a web server). The app also shows it as a QR code.

`payload = base64url(JSON {v:1, card, n, o?, sig})`, where `card` is the identity card (§2.3), `n` the name (1–80 characters), `o` the optional organisation, and

`sig = Ed25519("sotto-contact-v1\0" || JSON[sign_pk, box_pk, n, o])` by the card's key.

The name and organisation are self-asserted, but nobody can change them without breaking the signature. *Add contact* also accepts a call link or bare call code (no name). A contact is stored only on the device that adds it; marking it **verified** means the user confirmed that the safety number (§4) matches. Opened in a browser, a contact link shows the person's name with *Video call* / *Voice call* buttons (temporary identity).

## 6. Test vectors

`tools/crypto-vectors/gen.js` implements §2–§4 independently and prints the vectors stored in `app/lib/crypto/test_vectors.dart`:

- identities from master secrets `00 01 … 1f` and `20 21 … 3f`
- identity card of A (Ed25519 signatures are deterministic)
- safety number of A and B
- a reference envelope from A to B, which the Dart code must open

`runCryptoSelfTest` checks these on the Dart VM (unit tests) and in the browser (`?selftest=1`, run by the end-to-end test), proving all platforms agree.

## 7. Supply chain

`app/web/sodium.js` is libsodium.js 0.8.4, downloaded by `dart run sodium:update_web`.
SHA-256: `35958171e76a794218cd3675feec663da5236d3322d525abd692bd3c6d6941cf`.

## 8. Backups (Phase 6, native apps)

A backup is one line of JSON:

```
{"sotto":"backup","v":1,
 "kdf":{"alg":"argon2id13","ops":<int>,"mem":<bytes>,"salt":"<16 bytes>"},
 "nonce":"<24 bytes>","data":"<ciphertext>"}
```

```
key       = crypto_pwhash(32, passphrase, salt, ops, mem, ALG_ARGON2ID13)   // defaults: ops 3, mem 64 MiB
ad        = "sotto-backup-v1\0" || JSON[1, "argon2id13", ops, mem, salt, nonce]
data      = crypto_aead_xchacha20poly1305_ietf_encrypt(plaintext, ad, nonce, key)
plaintext = JSON {"master": "<32-byte master secret>", "values": {<vault entries>}, "created": "<ISO 8601>"}
```

- The passphrase must be at least 12 characters (after trimming); the app offers a generated one (25 Crockford base32 characters, 125 bits).
- Changing any header field (for example lowering the cost) changes `ad`, so decryption fails.
- To open a backup, the app accepts only `1 ≤ ops ≤ 10` and `8 MiB ≤ mem ≤ 1 GiB`, so a crafted file can't make it hang or run out of memory.
- `values` holds the vault (§9) except device-only entries (`sotto.lock.v1`, `sotto.devices.v1`); call history and notes are optional.
- Restoring writes the master secret to the OS keystore and replaces the vault's contents, keeping the device's own app lock and device choices.

## 9. Local storage: the vault (Phase 6)

All local data except the identity (profile, contacts, call history and notes, guest links, settings) is one key-value map of strings, stored as a single file in the app's private support directory (`sotto.vault`):

```
file      = "SOTTOVAULT1\0" || nonce (24) || crypto_aead_xchacha20poly1305_ietf_encrypt(plaintext, "SOTTOVAULT1\0", nonce, vault_key)
plaintext = JSON {"v":1, "values": {"<key>": "<string>", …}}
```

- `vault_key` is 32 random bytes, stored in the OS keystore under `sotto.vault.key.v1` (never next to the file). The identity's master secret stays in its own keystore entry (`sotto.identity.master.v1`).
- Every change rewrites the file with a fresh nonce, atomically (temporary file, then rename).
- A file whose key is missing, or that fails to decrypt, is never silently replaced: the app explains the problem and offers to start with empty storage (keeping the identity) or to restore a backup.
- In the browser, the same vault lives in memory and disappears with the tab.

| Key | Contents |
|---|---|
| `sotto.profile.v1` | Name and practice |
| `sotto.contacts.v1` | Contacts (keys, name, organisation, verified, auto-answer choices) and the auto-answer switch and delay |
| `sotto.history.v1` | Call history with notes, and the retention period |
| `sotto.guest_links.v1` | Guest links (§5.7) |
| `sotto.lock.v1` | App lock: Argon2id PIN verifier (`crypto_pwhash_str`), failed attempts, auto-lock time. Device-only |
| `sotto.devices.v1` | Chosen camera, microphone and speaker. Device-only |
| `sotto.settings.hide_ip` | "Hide my IP address" |

Earlier versions kept settings directly in the keystore; on first start they are moved into the vault and deleted from the keystore.

