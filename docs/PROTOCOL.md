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

Only after all checks pass is `(from, n)` recorded. The record is kept in memory only, so it starts empty when the app restarts.

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
client → {"type":"ping"}   server → {"type":"pong"}                                      (also before login)
```

Clients send `ping` every 25 s, and right away when a call loses its connection or the browser comes back online. If nothing at all arrives within 10 s (5 s for the immediate check), the connection is considered dead (after a network change a WebSocket can stay "open" for minutes without delivering anything): the client drops it and reconnects. An older relay answers `ping` with `bad-message`, which proves the connection works just as well.

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
| `call.invite` | caller → callee | `{"video": bool, "name"?: string}` |
| `call.ringing` | callee → caller | `{}` |
| `call.accept` / `call.reject` | callee → caller | `{"name"?: string}` / `{}` |
| `call.busy` | callee → caller | `{}` (callee is in another call) |
| `call.cancel` | caller → callee | `{}` (hung up before answer, or 45 s without answer) |
| `call.end` | either | `{}` |
| `sdp.offer` / `sdp.answer` | caller → callee / callee → caller | `{"sdp": "…"}`; during the call `{"sdp": "…", "restart": n}` |
| `ice.candidate` | either | `{"candidate", "sdpMid", "sdpMLineIndex"}` |
| `call.restart` | callee → caller | `{}` (the callee lost the connection and asks for an ICE restart) |

`name` is the sender's own profile name (the professional's app; guests and browser quick calls send none). It is not verified: the other side shows it only if the sender isn't a contact, as *“Name (not in your contacts)”*, cleaned of control characters and cut to 80 characters. `call.accept` may carry `{"auto": true}` when the callee's device answered automatically (an admitted guest, or a trusted caller with auto-answer on); both sides then show *Auto-answered* (not shown for guest admissions). Every call message carries the same random `callId` (16 bytes). Messages for another call, or from anyone but the call's peer, are ignored. An incoming call stops ringing after 60 s if no `call.cancel` arrives; media setup must finish within 30 s of acceptance.

**Reconnecting.** When a connected call's WebRTC connection becomes `disconnected` or `failed` (e.g. Wi-Fi to mobile data), both apps show *Reconnecting…*, check their relay connection (§5.2), and look for a new path with an ICE restart; the call and its media tracks stay as they are. Only the caller sends offers, so the two sides never offer at once: a numbered `sdp.offer` with `"restart": n` (made after `restartIce()`), answered by an `sdp.answer` carrying the same `n`; answers to an older number are ignored. The callee asks for a restart with `call.restart`. A `disconnected` connection gets 2 s to recover by itself first; a `failed` one restarts at once. Attempts repeat every 8 s and right after the relay connection comes back; without a new path within 45 s, the call ends as failed (`call.end`).

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

### 5.9 Short links and profile lookup

Since 0.1.7 the app shares **short** call and contact links that carry only the signing key (the relay ID, 43 characters of base64url):

```
https://<host>/?call=<signing key>     dials right away (call link)
https://<host>/#c=<signing key>        shows the person first (contact link)
```

Whoever opens one looks the person up through the relay:

```
request = "p1." || base64url(requester's identity card JSON)     not encrypted
reply   = envelope (§3) of type "profile", body {n, o?, av?}      sealed, signed
```

- The request holds only the requester's public card. The answering app checks that the card belongs to the relay-authenticated sender, and seals the reply to it.
- The reply is an ordinary signed envelope. It is accepted only when its verified signer is the key in the link, so the encryption key, name and organisation are as trustworthy as a full contact link (§5.8).
- `n` is the name and `o` the organisation (each at most 80 characters). `av` is the profile photo, if the person set one: a `data:image/jpeg;base64,…` URI of at most 24 KB. The app re-encodes the photo as a small JPEG (about 12 KB at most), which also removes its metadata. A reply that would not fit is sent without `av`. Anyone who has the short link gets the photo, as they get the name.
- Only the professional's app answers. Guest pages and browser quick calls don't, and answers are rate limited: one per requester every 3 s, at most 30 a minute.
- The person must be online for a first lookup, as for a call. After that, the app keeps the verified result in its encrypted settings, and uses it while the person is offline. A short link of someone already in the contacts needs no lookup at all.
- Full links (§5.7, §5.8) are still accepted everywhere.

### 5.10 Chat sessions (peer-to-peer messages)

A chat is set up with envelopes and then runs over a WebRTC data channel
labelled `sotto-chat`, directly between the two devices (see
`MESSAGING_PLAN.md`). The relay carries only the envelopes below.

Envelope types. `callId` is the session id: 16 random bytes.

| `type` | Direction | `body` |
|---|---|---|
| `chat.open` | opener → contact | `{}` |
| `chat.accept` | answering device → opener | `{"tag"}`: 16 random bytes, made by that device |
| `chat.decline` | contact → opener | `{"reason": "not-contact" \| "disabled"}` |
| `chat.taken` | opener → contact | `{"tag"}`: the winning device's tag |
| `chat.offer` / `chat.answer` | offerer ↔ winning device | `{"tag", "sdp"}` |
| `chat.ice` | either, with the winning device | `{"tag", "candidate", "sdpMid", "sdpMLineIndex"}` |
| `chat.close` | either | `{}` |
| `chat.text` | sender → contact | `{"id", "ts", "text"}`: a text message, when no direct chat is ready |
| `chat.text.ack` | contact → sender | `{"id"}`: the text is stored |

- Only contacts can open a chat. Others get `chat.decline` with `not-contact`.
- Every logged-in device of the contact answers `chat.open` with its own tag.
  The first `chat.accept` wins. The opener sends `chat.taken` with that tag, and
  the other devices drop their sessions.
- `chat.offer`, `chat.answer` and `chat.ice` carry the winning tag, so no other
  device applies them. They use their own types, not `sdp.*`, so call handling
  (§5.5) is unaffected.
- When both people open a chat at the same moment, the side with the lower
  Sotto ID keeps its own invitation; the other side answers it.
- An open with no answer after 20 seconds fails. An answering device that
  hears nothing decisive after 20 seconds drops its session.
- Texts through the relay. When no direct chat is ready, a text message also
  goes as a `chat.text` envelope, sealed to the contact like every envelope, so
  it reaches a device whose app runs in the background (the relay connection
  is kept by the Android service and desktop tray mode). The relay holds it in
  memory for at most 60 seconds and cannot read it. Every device of the
  contact that is connected stores it; a device stores a message id once and
  answers each copy with `chat.text.ack`, which marks it delivered. A message
  that still waits is sent again on the next check (every 30 seconds) while the
  sender's app runs, up to 20 per check. Files and voice notes need the direct
  chat, and so do replies and forwarded texts: their fields are negotiated in
  `hello` (see "Features" below), which the relay never sees. Reactions, edits
  and deletes never go this way. Texts from anyone who is not a contact are
  dropped without an answer.

Data-channel frames: UTF-8 JSON, at most 16 KiB each. Text is at most 4,000
characters after cleaning: control characters (except line breaks and tabs)
and the Unicode direction controls U+202A–U+202E and U+2066–U+2069 are removed,
and the ends are trimmed.

| Frame | Meaning |
|---|---|
| `{"t":"hello","v":1,"features":[…]}` | First frame from each side. Another version ends the session. `features` lists the optional features this side supports (below), and is left out when there are none. |
| `{"t":"msg","id","ts","text","reply"?,"fwd"?}` | A message. `id`: 16 random bytes. `ts`: sender's clock, ms (see "Clocks" below). `reply`: `{"id","text"}`, the message replied to and a copy of its text. `fwd`: `true` for a forwarded text. |
| `{"t":"react","id","emoji","ts"}` | The sender's reaction on message `id`. An empty `emoji` removes it. |
| `{"t":"edit","id","ts","text"}` | New text for the sender's own message `id`, made at `ts`. |
| `{"t":"delete","id","ts"}` | The sender's own message `id` is deleted for everyone, at `ts`. |
| `{"t":"ack","id"}` | The message is stored on the receiving device. Sent for every copy received. |
| `{"t":"bye"}` | The session is ending. |

Messages are sent only after the other side's `hello`. A message received
again (same `id`) is acknowledged but stored once. A session that ends before
an acknowledgement marks the message not sent; it is sent again in the next
session. A session with no activity for five minutes closes, unless the chat
is open on screen or messages are waiting.

### Features

`hello` lists the optional features a side supports, in `features`. The
version stays 1, and the version check is unchanged.

| Feature | Adds |
|---|---|
| `reply` | the `reply` field of `msg` |
| `fwd` | the `fwd` field of `msg` |
| `react` | the `react` frame |
| `edit` | the `edit` frame |
| `delete` | the `delete` frame |

A side sends a field or frame only when the other side's `hello` lists its
feature. A `hello` with no `features`, or with a `features` value that is not
a list, lists none. A name this app does not know is ignored, and a list item
that is not a string is skipped. Older versions ignore the new fields and
frames, so text and files work unchanged between old and new versions.

### Replies, forwards, reactions, edits and deletes

- **Reply.** `reply` is `{"id", "text"}`: the id of the message replied to,
  and a copy of its text. The sender cuts the copy to 200 characters and
  cleans it as messages are cleaned. The receiver refuses a quote over 200
  characters (`too-long`) or with a malformed id. If the quote would take the
  frame past 16 KiB, the message is sent without it, so the message itself
  still goes. On arrival the receiver sets the quote from its own copy of the
  message replied to, as that copy is at the time: its text cut to 200
  characters, or empty if it is deleted for everyone. The quote the sender sent
  is kept only when the receiver does not hold that message.
- **Forward.** A forwarded text is an ordinary message with `"fwd": true`. It
  keeps no reference to the original, and only text is forwarded.
- **Reaction** (`react`). `emoji` is trimmed. An empty one removes the
  sender's reaction. Otherwise it must be 1 to 16 UTF-16 code units, with no
  control characters (U+0000 to U+001F and U+007F), no direction controls
  (U+202A to U+202E and U+2066 to U+2069) and no lone surrogates. Anything
  else is refused. Each person has at most one reaction per message, and a new
  `react` replaces the old one. A reaction may be on any message in the chat.
  One on an unknown message, or on a message deleted for everyone, is ignored.
- **Edit** (`edit`). Only the contact's own text messages can be edited. The
  receiver applies it only if the message is stored, not deleted, `ts` is no
  earlier than the message's `ts` and at most 15 minutes after it, and the edit
  is current (below). `text` is cleaned and limited like a message, and it may
  not be empty. The receiver replaces the text and sets `editedAt` to `ts`. No
  earlier text is kept.
- **Delete** (`delete`). Only the contact's own text messages can be deleted
  for everyone. The receiver applies it only if the message is stored, not
  already deleted, `ts` is no earlier than the message's `ts` and at most one
  hour after it, and the delete is current (below). The message stays on record
  with no text and no reactions, and `deletedForAll` is set. Deleting for
  everyone is best effort: another device may keep its copy.
- **Current.** An edit or delete is refused when its `ts` is more than five
  minutes ahead of the receiver's clock, or more than seven days plus five
  minutes behind it. The windows above are measured on the control's `ts`; this
  check keeps that `ts` near the receiver's own clock, so a control cannot
  rewrite a message long after it was sent, whatever `ts` it carries. A control
  that waited in the sender's pending list applies when it arrives, as long as
  it is less than seven days old.
- **Quotes of a deleted message.** A delete takes the text out of quotes. The
  deleted message keeps no quote of its own, and each reply to it keeps its
  `id` with an empty quote text. This happens on the device that deletes and on
  the contact's device when the delete arrives. A reply still waiting in the
  outbox is sent with its quote emptied.
- **Quotes of an edited message.** An edit gives each reply to the message the
  new text, cut to 200 characters as a quote is, so no quote keeps the earlier
  text. This happens on the device that edits and on the contact's device when
  the edit arrives. A reply still waiting in the outbox is sent with the new
  quote, and a reply that arrives after the edit takes its quote from the
  receiver's copy (see Reply), so it shows the new text too.
- Files and voice notes are never edited or deleted for everyone: an edit or
  delete of one is ignored.
- A control frame is checked against the owner of its message, and the checks
  above. One that fails is ignored: no exception, no `ack`, no change.
- **Clocks.** A message whose `ts` is more than five minutes ahead of the
  receiver's clock keeps the arrival time as its `ts`. The chat list and search
  are ordered by each message's time on the device that holds it: the arrival
  time for an incoming message, its own `ts` for an outgoing one. So a peer
  cannot pin a chat to the top. `editedAt` is the edit's `ts`, which the
  current check keeps within seven days of the receiver's clock.

On the sending side, a reaction, edit or delete is applied to this device's
copy at once. It is sent to the contact over the chat, never through the relay:

- A reaction or an edit on one of this device's messages waits until the
  contact has stored that message (its state is delivered or read). Otherwise
  the contact would receive it first and ignore it. A delete does not wait:
  the message's text is taken off the outbox at once, so it is not sent after
  the delete, and an unknown id is ignored.
- A control that cannot be sent (no ready chat, or the contact does not list
  its feature, or the message has not been stored yet) is kept in the vault
  under `sotto.chats.pending.<contact id>`, as a list of the frames above in
  the order made. The list is included in backups, like the chat history. At
  most one reaction and one edit per message are kept, and a newer one of
  either kind replaces the older. A delete replaces both. At most 100 controls
  are kept per contact; past that, the oldest is dropped.
- A ready chat sends the pending controls after its messages, when the
  contact's `hello` lists the feature. This is at the `hello`, when a
  message is acknowledged, and when a control is made. Opening a chat only for
  pending controls does not happen. A control is dropped without being sent
  when its message is gone, when a reaction or edit is on a message deleted
  for everyone, or when an edit or delete is more than seven days old by its
  own `ts` on the sender's clock, since the contact would refuse it (see
  "Current" above). The windows are not checked again when the control is
  sent: an edit or delete made within its window is sent when a chat opens,
  even after the window has closed, because the contact checks the control's
  `ts`, not the time it arrives. A contact offline for longer than seven days
  does not get an edit or delete made in that time; its copy stays as it was.

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
- `values` holds the vault (§9) except device-only entries (`sotto.lock.v1`, `sotto.devices.v1`, `sotto.settings.desktop`); call history and notes are optional.
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
- In the browser, the same vault lives in memory and disappears with the tab, unless the user turns on **Remember me on this browser** (below).

**Received files** are not in the vault file. Each one is a separate blob in `received_files/` under the app's private support directory, named by 16 random bytes in hex (never the sender's file id or name). It is sealed with XChaCha20-Poly1305 under its own random 256-bit key, with the stored name as additional data. The key and the blob's name are kept in the chat record, so they are in the vault and are deleted with the message. Files from earlier versions, which were plaintext, are moved into this form the next time the app starts. "Open" writes a decrypted copy into the temporary folder for another app to open; that copy is removed when the app next starts, and on erase. The browser keeps received files and voice notes in memory for the life of the tab only, never in its storage, so after a reload they are gone; a file can be saved with the browser's download. On Android, *Save to Downloads* writes a decrypted copy to the shared Downloads folder, where it stays until the user deletes it (`THREAT_MODEL.md`, limitation 14).

**Voice notes** are files offered with `file.offer` (`FILE_SHARING_PLAN.md`) and marked by an optional `kind` field: `"voice"` for a voice note, and `"file"` or no field for an ordinary file. Any other `kind` makes the frame malformed. A receiver decides from `kind` alone, never from the MIME type, and older clients show a voice note as an ordinary file. A `voice` offer is declined (`file.decline`) unless its MIME type, with parameters ignored and case folded, is `audio/mp4` (AAC-LC in an MPEG-4 container, `.m4a`) or `audio/wav` (16-bit PCM, mono, 8 to 48 kHz, `.wav`), its name ends in the extension of that type, and its size is at most 2 MiB for `audio/mp4` or 9,600,044 bytes for `audio/wav`. A voice note lasts at most 300 seconds. The sender enforces that limit, and the receiver checks only the byte caps, so it cannot check the duration. An offer with no `kind`, including other audio such as `audio/mpeg`, is an ordinary file under the usual file limits. A completed voice note must look like its format (an `ftyp` box with the major brand `M4A `, `mp42` or `isom`; or a RIFF/WAVE file with a PCM `fmt ` chunk of 1 channel and 16 bits, followed by a `data` chunk), or it is treated as damaged and never saved. A voice note from a contact that passes these checks is downloaded at once; playback still needs a tap. It is kept encrypted like any received file, and so is the sender's own copy. An ordinary file waits for the receiver to accept it, unless they turn on *Download files automatically* in Settings (off by default). Playback decrypts the note into memory on Android, Windows and in the browser. On iOS, macOS and Linux the player needs a file, so a decrypted copy is written into the temporary folder and removed when playback stops, completes or the player is disposed. A player disposed while its note is still being read neither plays it nor keeps a copy. Recording writes a temporary file, which is read and deleted at once, and it is deleted too when the recording fails to stop. Not yet signed off by the owner (see the voice decision's open questions): the `kind` field, and in the browser a voice note (sent or received) held in memory for the life of the tab only, never in storage, so after a reload it is unavailable.

| Key | Contents |
|---|---|
| `sotto.profile.v1` | Name and practice |
| `sotto.contacts.v1` | Contacts (keys, name, organisation, verified, auto-answer choices) and the auto-answer switch and delay |
| `sotto.history.v1` | Call history with notes, and the retention period |
| `sotto.chats.v1` | Chat history (§5.10), kept until the person deletes a chat. Included in backups |
| `sotto.guest_links.v1` | Guest links (§5.7) |
| `sotto.lock.v1` | App lock: PIN verifier (Argon2id `crypto_pwhash_str` in the apps; keyed BLAKE2b in the browser, §9.1), failed attempts, auto-lock time. Device-only |
| `sotto.devices.v1` | Chosen camera, microphone and speaker. Device-only |
| `sotto.settings.hide_ip` | "Hide my IP address" |
| `sotto.settings.sounds` | Ringtone and chimes on/off |
| `sotto.server.v1` | A server chosen instead of the built-in one (web and relay URLs). Included in backups, so restored links keep working |
| `sotto.settings.desktop` | Tray and notification choices. Device-only |

Earlier versions kept settings directly in the keystore; on first start they are moved into the vault and deleted from the keystore.


### 9.1 Remember me on this browser

Off by default. When on, the browser keeps what the OS keystore and the vault file keep in the apps, in an IndexedDB database `sotto` (table `kv`):

| Record | Contents |
|---|---|
| `wrapping-key` | An AES-256-GCM `CryptoKey` created by Web Crypto as **non-extractable**: scripts (ours included) can use it but can't read it |
| `secret:<name>` | Each keystore entry (`sotto.identity.master.v1`, `sotto.vault.key.v1`, `sotto.lock.key.v1`) as `iv (12) || AES-GCM(value, wrapping-key)` |
| `vault` | The vault file's bytes, as above (already encrypted with the vault key) |

- `sotto.lock.key.v1` is the 32-byte key of the browser's PIN verifier (keyed BLAKE2b; the web build has no Argon2id). It is kept with the secrets so that the PIN still works after reloading.
- Turning it on copies the session's identity, PIN key and vault into this storage; *Forget this browser* copies them back to memory and deletes the database (the tab keeps working until it is closed). Erasing everything deletes it too.
- Non-extractable means a script can't copy the key out; it does not protect against someone who can use this browser profile or read its files. The option is meant for one's own computer.

