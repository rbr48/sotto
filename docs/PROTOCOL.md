# Sotto Protocol — Identity and Envelopes (v1)

This document specifies how Sotto identities are formed and how messages are encrypted end to end. It is implemented in `app/lib/crypto/` (Dart, native and web) and independently in `tools/crypto-vectors/gen.js` (Node.js), which produces the known-answer test vectors in `app/lib/crypto/test_vectors.dart`.

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

## 5. Proof-of-concept transport (Phase 1–2 only)

Until the encrypted relay arrives (Phase 3), the test call uses the plaintext dev-room relay:

1. Each peer creates a temporary identity and sends `{"kind":"hello","card":<identity card>}`.
2. All call setup then travels as `{"kind":"sealed","env":"<envelope>"}`, with inner types `sdp.offer`, `sdp.answer` and `ice.candidate`, opened with the peer's ID as the expected sender.

The dev relay can still swap the identity cards (a man-in-the-middle), which comparing safety numbers detects.

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
