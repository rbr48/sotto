# Calling App — Technical Plan & Roadmap (Privacy-First, Zero Server Storage)

A VoIP audio/video calling app built with **Flutter + `flutter_webrtc`**, using a **self-built, stateless signaling relay** and a **self-hosted TURN server (coturn)**.

- **Primary targets:** Android, Windows, Linux (macOS is cheap to add later)
- **Initial scope:** 1:1 audio and video calls between contacts
- **Later scope:** on-device call recording, linking several devices to one identity, small group calls (mesh, up to ~4 people)

---

## 1. Privacy Principles

These rules override every other design decision in this document.

1. **Zero server storage.** The server has no database and writes no user data to disk. Everything it knows lives in RAM and disappears when a connection closes or the server restarts.
2. **The server is a switchboard, not a participant.** It routes encrypted envelopes between public keys. It cannot read call setup data, contact lists, names or messages.
3. **No accounts and no personal identifiers.** No email, phone number, username or password. A user *is* a key pair generated on their own device.
4. **No directory.** Nobody can be searched for. People connect only by exchanging a QR code or invite link directly.
5. **All user data lives on the user's device**, encrypted at rest: identity key, contacts, call history, settings, recordings.
6. **End-to-end encryption everywhere.** Signaling is E2E encrypted and signed. Media is DTLS-SRTP, and the media fingerprints are authenticated end to end so the server can't intercept the call.
7. **No logs, no analytics, no tracking.** Diagnostics are opt-in and are exported by the user, never uploaded automatically.
8. **Open source server.** The relay code is public so anyone can verify what it does and does not keep.

---

## 2. Architecture Overview

```
 ┌──────────────────────┐                                 ┌──────────────────────┐
 │  Flutter client A    │                                 │  Flutter client B    │
 │  - identity key pair │                                 │  - identity key pair │
 │  - encrypted local DB│                                 │  - encrypted local DB│
 │  - flutter_webrtc    │                                 │  - flutter_webrtc    │
 └───┬──────────────▲───┘                                 └───▲──────────────┬───┘
     │ WSS: {to, ciphertext}                                   │              │
     │              │       ┌──────────────────────────┐      │              │
     └──────────────┼──────▶│  Signaling relay         │──────┘              │
                    │       │  - RAM only, no DB/disk  │                     │
                    │       │  - routes by public key  │──▶ FCM / UnifiedPush│
                    │       │  - can't read payloads   │    ("wake up" only) │
                    │       └──────────────────────────┘                     │
                    │                                                        │
                    │      SRTP media (direct P2P when possible)             │
                    └───────────────────────────────────────────────────────┘
                                   │ fallback │
                             ┌─────▼──────────▼──┐
                             │      coturn       │  relays encrypted packets,
                             │  logging disabled │  can't decrypt them
                             └───────────────────┘
```

### Components

| Component | Technology | Stores user data? |
|---|---|---|
| Client app | Flutter 3.x, `flutter_webrtc`, Riverpod, libsodium | **Yes, locally only**, encrypted |
| Signaling relay | Node.js 20+ / TypeScript, `ws` | **No.** RAM only: live sockets, short-lived queues |
| TURN/STUN | coturn | **No.** Logging disabled; stateless HMAC credentials |
| Push | FCM (Google) or UnifiedPush (self-hostable) | Content-free "wake up" pings only |
| Reverse proxy | Caddy | Access logging disabled |

There is **no Postgres and no Redis** in v1. If the relay later needs several instances, use Redis pub/sub with persistence turned off (`save ""`, `appendonly no`) purely for routing between instances.

---

## 3. Repository Layout

```
calling/
├── app/                          # Flutter application
│   ├── android/  windows/  linux/
│   └── lib/
│       ├── main.dart
│       ├── core/                 # config, DI, logging (local only), theme
│       ├── crypto/               # identity keys, envelopes, safety numbers, backup encryption
│       ├── storage/              # encrypted local database (contacts, history, settings)
│       ├── relay/                # WebSocket client, envelope send/receive, offline queue
│       ├── features/
│       │   ├── onboarding/       # create identity / restore from backup
│       │   ├── contacts/         # QR + invite links, contact requests, verification
│       │   ├── history/
│       │   ├── settings/
│       │   ├── recording/        # Phase 12
│       │   └── call/
│       │       ├── call_controller.dart   # state machine
│       │       ├── webrtc_session.dart    # RTCPeerConnection wrapper
│       │       ├── media_devices.dart
│       │       └── ui/
│       └── platform/
│           ├── android/          # push wake-up, native incoming-call UI, foreground service
│           └── desktop/          # tray, window, notifications
├── server/                       # Stateless relay (TypeScript)
│   ├── src/
│   │   ├── auth.ts               # challenge-response with public keys
│   │   ├── router.ts             # in-memory publicKey → socket map
│   │   ├── queue.ts              # RAM-only short-lived envelope queue (TTL 60 s)
│   │   ├── push.ts               # forwards wake-ups to FCM / UnifiedPush, stores nothing
│   │   ├── turn.ts               # stateless HMAC TURN credentials
│   │   └── limits.ts             # in-memory rate limiting
│   └── test/
├── infra/
│   ├── docker-compose.yml        # relay + coturn (read-only filesystems, tmpfs only)
│   ├── coturn/turnserver.conf
│   └── caddy/Caddyfile
└── docs/
    ├── ROADMAP.md                # this file
    ├── FEATURES.md
    ├── PROTOCOL.md               # envelope + message formats
    └── THREAT_MODEL.md
```

---

## 4. Key Technical Design

### 4.1 Identity (no accounts)

- On first launch the app generates an **Ed25519 identity key pair** with libsodium.
- The private key is stored with `flutter_secure_storage`, which uses Android Keystore, Windows DPAPI or Linux libsecret.
- **User ID = the public key**, shown as base32/base64url. Users never type it; it travels inside QR codes and links.
- For encryption, the identity key is converted to X25519 (`crypto_sign_ed25519_pk_to_curve25519`).
- **Display name and avatar** are stored locally and sent to contacts only inside encrypted messages. The server never sees them.

### 4.2 Adding contacts (no directory)

1. User B opens *Add contact → Show my code*. The app shows a **QR code** or produces an **invite link**:
   `https://call.example.com/i#<base64url payload>`
   The payload goes after `#`, which browsers never send to the server. It contains B's public key, display name and a one-time invite secret, signed by B.
2. User A scans the QR code or opens the link. A's app sends an encrypted `contact.request` to B through the relay.
3. B's app checks the invite secret (or asks B to approve) and replies with `contact.accept`.
4. Both apps then exchange, end to end encrypted: display name, avatar, and **push wake-up tokens** (section 4.7).
5. Contacts are saved only in each device's encrypted local database.

Because public keys can't be guessed and there is no directory, **strangers cannot call you** unless you shared your code.

### 4.3 Relay protocol: what the server sees

Outer envelope (the only thing the server can read):

```json
{ "type": "relay", "to": "<recipient public key>", "id": "<random msg id>", "body": "<base64 ciphertext>", "wake": { "provider": "fcm", "token": "…" } }
```

- `from` is **not** sent by the client. The server attaches the authenticated public key of the sending socket.
- `body` is `crypto_box` (X25519 + XSalsa20-Poly1305) from sender to recipient. That authenticates the sender, so nobody can forge messages.
- `wake` is optional. It is included only when the caller wants the server to wake an offline recipient, and the server discards it after one use.

Inner messages (encrypted; the server can't see them):

| Type | Purpose |
|---|---|
| `contact.request` / `contact.accept` / `contact.update` | Contact exchange; profile and push-token updates |
| `call.invite` | `{ callId, media: "audio"\|"video", ts }` |
| `call.ringing` / `call.accept` / `call.reject` / `call.busy` / `call.cancel` / `call.end` | Call flow |
| `sdp.offer` / `sdp.answer` / `ice.candidate` | WebRTC negotiation |
| `call.recording.started` / `call.recording.stopped` | Recording notice, including the mode |

**Replay protection:** every inner message carries `callId`, a timestamp and a random nonce. Receivers drop messages older than 2 minutes and any nonce they have already seen.

**Call logic runs on the clients**, because the server can't read the messages:
- **Busy:** the callee's app answers `call.busy` automatically if it is already in a call.
- **Ring timeout:** the caller's app gives up after 45 s and sends `call.cancel`.
- **Calls from non-contacts:** the callee's app silently drops them.

### 4.4 Relay server behaviour (RAM only)

- **Connect:** the server sends a random 32-byte challenge, the client signs it with its identity key, and the server verifies it. The socket is now bound to that public key, in memory only.
- **Routing:** an in-memory `Map<publicKey, Set<socket>>`. If the recipient is online, the envelope is forwarded immediately.
- **Offline recipient:** if `wake` is present, the server sends a content-free push and keeps the envelope **in RAM for up to 60 s**. If the recipient connects within that time, it is delivered; otherwise it is dropped.
- **Nothing is written to disk:** containers run with a read-only root filesystem and `tmpfs` only; there are no access logs and process logs contain no keys, IPs or tokens.
- **Rate limits** are in-memory counters per socket and per IP, using a salted hash that rotates daily and is never persisted.
- **Monitoring** uses aggregate counters only (connected sockets, envelopes per second, error counts).

### 4.5 WebRTC session and MITM protection

- Use the **"perfect negotiation"** pattern; trickle ICE; ICE restart when the network changes.
- **Media can't be intercepted by the server:** the DTLS fingerprint in the SDP is inside the E2E-encrypted, sender-authenticated envelope. The relay can't swap it, so it can't put itself in the middle of the media.
- **Safety number:** a short code derived from both public keys, shown as 12 groups of digits plus a QR code. Users can compare it once in person or on a call to mark a contact as **verified**.
- Codecs: Opus for audio; VP8 by default for video, optional H.264.
- Optional **"Hide my IP address"** setting: forces `iceTransportPolicy: relay`, so the other person only sees the TURN server's IP. It costs some latency and TURN bandwidth.

### 4.6 TURN (coturn), stateless and log-free

- Credentials are time-limited HMAC values (`username = "<expiry>:<random>"`, `credential = base64(HMAC-SHA1(secret, username))`). The relay issues them on request, so **nothing is stored** and they contain no user identifier.
- Minimal `turnserver.conf`:

```
listening-port=3478
tls-listening-port=5349
fingerprint
use-auth-secret
static-auth-secret=<long-random-secret>
realm=turn.example.com
cert=/etc/ssl/turn/fullchain.pem
pkey=/etc/ssl/turn/privkey.pem
min-port=49152
max-port=65535
no-cli
no-multicast-peers
log-file=/dev/null
no-stdout-log
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
total-quota=300
user-quota=12
```

### 4.7 Waking Android for incoming calls without storing push tokens

To ring a closed app, *someone* has to know its push token. In this design, **the user's contacts hold it, not the server**.

1. Each device obtains a push token: FCM, or a **UnifiedPush** endpoint for users who avoid Google.
2. The token is sent **only to contacts**, inside E2E-encrypted `contact.accept` / `contact.update` messages. It is refreshed whenever it changes.
3. To call someone, the caller's app puts the callee's token in the envelope's `wake` field.
4. The relay sends a **content-free** high-priority push (no name, no caller ID, just "wake"), then forgets the token.
5. The callee's app wakes, connects to the relay, receives the queued encrypted `call.invite`, and shows the incoming-call screen.

The server holds the FCM *project* credential, which is server configuration, not user data. Google sees only that a device received a ping.

### 4.8 Local data on the device

- **Encrypted database:** `drift` with SQLCipher (`sqlcipher_flutter_libs`). The database key is random and stored in `flutter_secure_storage`.
- Tables: `contacts` (public key, name, avatar, push token, verified flag), `calls` (history), `settings`, `seen_nonces` (pruned automatically).
- Optional **app lock**: PIN or biometrics (`local_auth`).
- Optional **auto-delete call history** after N days.

### 4.9 Encrypted backup and restore

Without accounts, a lost device means a lost identity, so the user gets a **backup file**:
- Contents: identity key, contacts and settings. Recordings are optional because they are large.
- Encryption: a key derived from the user's password with **Argon2id**, then XChaCha20-Poly1305.
- The user saves it wherever they choose: a file, USB drive or their own cloud. The app never uploads it.
- Restore: on first launch, *Restore from backup*, enter the password.

### 4.10 What the server can and cannot see

| The server **never** sees | The server **briefly** sees, in RAM only, while it happens |
|---|---|
| Names, avatars, contact lists | Public keys of connected devices |
| Call setup content (SDP, ICE candidates inside the envelope) | Which key is sending an envelope to which key, and when |
| Audio/video (encrypted end to end) | IP addresses of connected devices (and of relayed TURN calls) |
| Call history, recordings | A push token, for the moment it forwards a wake-up |

Hiding even this short-lived metadata would need onion routing (like Tor), which adds too much latency for real-time calls. This limit is documented honestly in `THREAT_MODEL.md` and the privacy policy.

### 4.11 Abuse prevention without accounts

- No directory, so strangers can't find you.
- Calls and requests from unknown keys are dropped by the app.
- Invite links can be **single-use** or **expiring**, and can be revoked.
- Block a contact: their key is ignored locally. Optionally, the app stops sharing its push token with them.
- The relay applies in-memory rate limits per socket and IP and caps envelope size and queue length.

### 4.12 Key Flutter packages

| Need | Package |
|---|---|
| WebRTC | `flutter_webrtc` |
| Cryptography (Ed25519, X25519, secretbox, Argon2id) | `sodium_libs` (libsodium) |
| Secure key storage | `flutter_secure_storage` |
| Encrypted local database | `drift` + `sqlcipher_flutter_libs` |
| WebSocket | `web_socket_channel` |
| State management | `flutter_riverpod` |
| QR display / scan | `qr_flutter` / `mobile_scanner` (desktop: paste invite link, or webcam scan where supported) |
| Invite links | `app_links` |
| Push | `firebase_messaging`, `unifiedpush` |
| Native incoming-call UI (Android) | `flutter_callkit_incoming` |
| App lock | `local_auth` |
| Permissions | `permission_handler` |
| Keep screen on during calls | `wakelock_plus` |
| Network change detection | `connectivity_plus` |
| Desktop window / tray / notifications | `window_manager`, `tray_manager`, `local_notifier` |

---

## 5. Roadmap

Estimates assume **one full-time developer** familiar with Flutter. A second developer for crypto and the server can shorten the calendar by roughly 30–40%.

### Phase 0 — Foundations (Week 1)
- [ ] Create the monorepo structure (`app/`, `server/`, `infra/`, `docs/`)
- [ ] `flutter create` with `android`, `windows`, `linux`; Android `minSdk` 24+
- [ ] Add `flutter_webrtc` and `sodium_libs`; confirm they build on all three platforms
- [ ] Android permissions: `CAMERA`, `RECORD_AUDIO`, `INTERNET`, `MODIFY_AUDIO_SETTINGS`, `BLUETOOTH_CONNECT`, `POST_NOTIFICATIONS`
- [ ] Server skeleton: TypeScript, `ws`, ESLint/Prettier, Vitest
- [ ] CI (GitHub Actions): analyze, tests, Android APK and Windows/Linux builds

**Exit criteria:** an empty app builds on Android, Windows and Linux in CI; the relay starts and accepts a WebSocket.

### Phase 1 — WebRTC Proof of Concept (Weeks 2–3)
- [ ] Local camera preview on Android and Windows
- [ ] Loopback call (two peer connections in one app)
- [ ] Throwaway plaintext relay (rooms by code) for experiments only
- [ ] First real call: Android ↔ Windows on the same LAN with public STUN
- [ ] Mute mic, toggle camera, hang up

**Exit criteria:** a video call works between an Android phone and a Windows PC on the same Wi-Fi.

### Phase 2 — Identity & Crypto Core (Weeks 4–5)
- [ ] Generate and securely store the Ed25519 identity key; display the public key and QR code
- [ ] Envelope library: `seal(recipientPk, message)` / `open(senderPk, ciphertext)` with libsodium `crypto_box`
- [ ] Inner message format with `callId`, timestamp, nonce; replay protection
- [ ] Safety-number generation (deterministic from both keys)
- [ ] Unit tests and known-answer test vectors; fuzz tests for malformed ciphertexts
- [ ] Write `docs/PROTOCOL.md` and the first version of `docs/THREAT_MODEL.md`

**Exit criteria:** two app instances can exchange encrypted, authenticated test messages through a local relay; tampered or replayed messages are rejected.

### Phase 3 — Stateless Relay Server (Weeks 6–7)
- [ ] Challenge-response login with the public key
- [ ] In-memory routing map; forward envelopes; multi-device fan-out for the same key
- [ ] RAM-only queue (TTL 60 s, size caps) for recipients being woken up
- [ ] Heartbeat; dead-socket cleanup
- [ ] In-memory rate limiting and envelope size limits
- [ ] **No-storage enforcement:** read-only container filesystem, no DB, logging that excludes keys, IPs and tokens; automated test that the process writes nothing to disk
- [ ] Client: relay connection with reconnect/backoff, outgoing queue, call state machine driven by the encrypted messages (busy, timeout and cancel handled on the clients)

**Exit criteria:** users A and B call each other by public key with ringing, accept, reject, cancel and busy behaviour. The relay can't read any message body.

### Phase 4 — NAT Traversal with coturn (Week 8)
- [ ] Deploy coturn with TLS, logging disabled, private IP ranges denied
- [ ] Stateless TURN credential endpoint on the relay
- [ ] Test matrix: same Wi-Fi, Wi-Fi ↔ 4G, 4G ↔ 4G, forced relay, TLS-only firewall
- [ ] "Hide my IP address" setting (forced relay)

**Exit criteria / Milestone M1:** an E2E-encrypted call connects across the internet in every network in the test matrix.

### Phase 5 — Contacts, Local Data & Backup (Weeks 9–11)
- [ ] Onboarding: create a new identity or restore from backup; choose display name and avatar
- [ ] Encrypted local database (drift + SQLCipher)
- [ ] Show my QR code / share invite link (single-use and expiring options)
- [ ] Scan QR code / open invite link, then the `contact.request` → `contact.accept` exchange
- [ ] Contact list, rename, delete, block
- [ ] Safety-number screen and **verified** badge
- [ ] Call history (local only), with optional auto-delete
- [ ] Encrypted backup export and restore (Argon2id + XChaCha20-Poly1305)
- [ ] App lock (PIN / biometrics)

**Exit criteria:** two users add each other by QR code with no server-side account, call from the contact list, verify safety numbers, and restore everything on a new device from a backup file.

### Phase 6 — Call Experience & Media Controls (Weeks 12–13)
- [ ] Outgoing, incoming and in-call screens (draggable local preview)
- [ ] Audio-only calls; upgrade audio → video mid-call
- [ ] Switch front/back camera; speaker / earpiece / Bluetooth / wired routing (Android)
- [ ] Desktop pickers for camera, microphone and speaker, with hot-plug handling
- [ ] Ringtone and ringback; proximity screen-off (Android)
- [ ] Call-quality indicator from `getStats()`, computed and shown locally only
- [ ] Picture-in-Picture (Android)

**Exit criteria / Milestone M2 — Internal Alpha:** usable private 1:1 calling while both apps are open.

### Phase 7 — Android Background & Incoming Calls (Weeks 14–16)
- [ ] Obtain an FCM token; add **UnifiedPush** support as an alternative
- [ ] Share push tokens only with contacts via E2E `contact.update`, and re-send on change
- [ ] Caller includes the callee's token in `wake`; relay sends a **content-free** high-priority push and keeps nothing
- [ ] Background handler: connect to the relay, receive the queued `call.invite`, show the native incoming-call UI (`flutter_callkit_incoming`), lock screen and full-screen intent
- [ ] Foreground service during calls with types `phoneCall|microphone|camera` (Android 14+)
- [ ] Permissions: `USE_FULL_SCREEN_INTENT`, `FOREGROUND_SERVICE_PHONE_CALL`, `FOREGROUND_SERVICE_MICROPHONE`, `FOREGROUND_SERVICE_CAMERA`
- [ ] Handle a normal phone call interrupting a VoIP call
- [ ] Test on Samsung, Xiaomi and Pixel, with Doze and battery savers; in-app battery-optimisation guidance

**Exit criteria:** an incoming call rings on a locked Android phone with the app killed, within about 3 seconds, and the server stores no token.

### Phase 8 — Desktop Polish (Weeks 17–18)
- [ ] System tray; minimise to tray so the relay connection stays open
- [ ] Optional start at login; single-instance enforcement
- [ ] Native notification and an incoming-call window
- [ ] Screen sharing with a screen/window picker
- [ ] Keyboard shortcuts
- [ ] Add contacts on desktop: invite links, and QR scanning by webcam where supported
- [ ] Packaging: Windows MSIX / installer; Linux AppImage / `.deb`

**Exit criteria:** installable desktop builds that receive calls while minimised.

### Phase 9 — Reliability & Call Quality (Weeks 19–20)
- [ ] ICE restart on network change and on `disconnected`, with "Reconnecting…" UI and a 30 s give-up
- [ ] Relay reconnect mid-call without dropping media
- [ ] Bandwidth adaptation; audio-only fallback
- [ ] **Local-only diagnostics:** per-call stats kept on the device; *Export diagnostic report* lets the user share an anonymised file manually
- [ ] Crash reporting **opt-in only**, with a self-hosted collector or a user-exported crash file
- [ ] Relay health metrics as aggregate counters only

**Exit criteria:** call setup success above 95% in the test matrix; calls survive a Wi-Fi → 4G switch.

### Phase 10 — Security & Privacy Hardening (Weeks 21–22)
- [ ] Review the threat model; check every log line on the server and client for data leaks
- [ ] Prove there is no disk write: run the relay and coturn with read-only root filesystems and inspect tmpfs usage
- [ ] Dependency, secret and static-analysis scanning in CI
- [ ] Crypto code review, ideally an independent external audit before the public launch
- [ ] Publish the relay source code and deployment config
- [ ] Privacy policy that plainly lists the short-lived metadata in section 4.10
- [ ] Optional: reproducible Android builds so users can check that releases match the source

**Milestone M3 — Closed Beta (end of Week 22):** 20–50 testers via Play Console internal testing and a desktop download.

### Phase 11 — Release (Weeks 23–25)
- [ ] Beta feedback fixes
- [ ] Play Store listing: data-safety form ("no data collected" where accurate), foreground-service and full-screen-intent declarations
- [ ] Windows code-signing certificate
- [ ] Production relay and coturn in at least two regions; monitoring and alerting with no user data
- [ ] Load test the relay (WebSocket clients with k6)

**Milestone M4 — v1.0 public release (about 6 months).**

### Phase 12 — On-Device Call Recording (Weeks 26–29, post v1.0)
Recording happens **only on the user's device**. Media stays peer-to-peer and end-to-end encrypted, and the server never sees or stores call content.

**Shared (all platforms)**
- [ ] E2E messages `call.recording.started` / `call.recording.stopped`, sent to the other participant
- [ ] Visible **"● Recording"** indicator shown to **both** participants for the whole time recording is on
- [ ] Optional consent prompt: the other participant must accept before recording starts (configurable; on by default)
- [ ] Recording is stopped automatically on hang-up, call failure or the app being killed (finalise the file safely)
- [ ] Recordings library screen: list, play, share, rename, delete
- [ ] Recordings stored in app-private storage, encrypted at rest (XChaCha20-Poly1305 / AES-GCM, key in `flutter_secure_storage`)
- [ ] **Recording mode choice**: when starting a recording in a video call, the user picks **"Voice only"** (`.m4a`/AAC) or **"Video + voice"** (`.mp4`, H.264 + AAC). Voice calls always record voice only
- [ ] Default recording mode in Settings (Ask every time / Voice only / Video + voice)
- [ ] Switching mode mid-recording is not supported: stop and start a new recording instead (keeps files simple)
- [ ] Both modes include **both sides' voices** (local mic + remote audio mixed into one track)
- [ ] Mode is included in the `call.recording.started` message so the other participant sees "● Recording (voice)" or "● Recording (video)"
- [ ] Storage checks: warn when free space is low; optional maximum length / auto-delete after N days

**Android (about 1–1.5 weeks)**
- [ ] Start with `flutter_webrtc`'s `MediaRecorder` to capture the video track to MP4
- [ ] Native (Kotlin) audio mixer that combines the **local mic** and **remote audio** into a single track. Out of the box, the recorder captures only one side
- [ ] Video layout: record the remote video, optionally with the local preview composited picture-in-picture
- [ ] Keep recording alive in the background under the existing call foreground service

**Windows / Linux (about 2 weeks)**
- [ ] Check the current `flutter_webrtc` desktop `MediaRecorder` support first; use it if it is available
- [ ] Otherwise, a native plugin (C++) that taps the decoded remote audio/video frames and the local capture, mixes the audio and encodes with **FFmpeg** (libavcodec)
- [ ] Bundle FFmpeg libraries with the Windows installer and the Linux AppImage/`.deb` (check the licence: use an LGPL build)

**Compliance**
- [ ] Update the privacy policy and the Play Store data-safety form (audio/video recorded and stored on device only)
- [ ] In-app notice explaining that the user is responsible for consent under local recording laws

**Exit criteria / Milestone M5:** both sides of a call are recorded into a single playable file on Android and desktop, and the other participant always sees the recording indicator.

### Phase 13 — Linked Devices (Weeks 30–32, optional)
- [ ] Link a PC to a phone by scanning a QR code shown on the PC
- [ ] Each device keeps its own key; the primary key signs a **device list**
- [ ] Contacts receive the signed device list over E2E messages; calls ring every linked device
- [ ] Contacts and history sync between linked devices **directly, end to end encrypted**, never stored on the server
- [ ] Unlink / revoke a lost device

### Phase 14 — Group Calls, Mesh (Weeks 33–35, optional)
- [ ] Group invite sent as separate E2E envelopes to each participant
- [ ] One `RTCPeerConnection` per pair of participants (mesh); every pair is end-to-end encrypted
- [ ] Grid layout, active-speaker detection
- [ ] Hard cap at **4 participants**

> Larger groups need an SFU (media server). Standard SFUs can see media unless you add **WebRTC Insertable Streams / SFrame** end-to-end encryption. That is a separate project with its own privacy review.

### Summary timeline

| Weeks | Phase | Milestone |
|---|---|---|
| 1 | Foundations | |
| 2–3 | WebRTC PoC | First LAN call |
| 4–5 | Identity & crypto core | |
| 6–7 | Stateless relay | |
| 8 | coturn | **M1: E2E call over the internet** |
| 9–11 | Contacts, local data, backup | |
| 12–13 | Call UX | **M2: internal alpha** |
| 14–16 | Android background calls | |
| 17–18 | Desktop polish | |
| 19–20 | Reliability | |
| 21–22 | Security & privacy hardening | **M3: closed beta** |
| 23–25 | Release | **M4: v1.0** |
| 26–29 | On-device call recording | **M5: recording** |
| 30–32 | Linked devices (optional) | |
| 33–35 | Group calls (optional) | |

---

## 6. Infrastructure & Cost Estimate

Infrastructure is simpler and cheaper than an account-based design: no database, no backups of user data, no Redis.

| Stage | Setup | Approx. monthly cost |
|---|---|---|
| Development | Relay locally; one small VPS for coturn | $5–10 |
| Beta | 1 small VPS for the relay, 1 VPS for coturn | $10–30 |
| Production | 2+ relay instances, 2+ coturn nodes in different regions | $60+ (TURN bandwidth driven) |

**TURN bandwidth is the main cost.** About 15–20% of calls normally need relaying. Users who turn on "Hide my IP address" are always relayed. A relayed 720p call is roughly 1–2 GB per hour, so choose hosts with generous included traffic, such as Hetzner or OVH.

Server location matters less here, because there is no stored data to hand over. Still choose a jurisdiction with strong privacy law, since live metadata could in principle be observed while it is in memory.

---

## 7. Testing Strategy

- **Crypto unit tests:** known-answer vectors, tampering, replay, wrong-key and truncated ciphertexts
- **Relay tests:** routing, queue expiry, rate limits; an automated **"no persistence" test** that runs the relay on a read-only filesystem and checks no files are created
- **State machine tests:** busy, timeout, cancel, glare (both sides calling at once), driven by fake envelopes
- **Widget tests:** onboarding, contact exchange, call screens
- **Manual device matrix:**
  - Android 9, 11, 13, 14, 15+ on Samsung, Xiaomi and Pixel
  - Windows 10/11; Ubuntu 22.04/24.04
  - Networks: same LAN, Wi-Fi ↔ 4G, forced relay, TLS-only firewall
  - Scenarios: app killed, screen locked, network switch mid-call, Bluetooth headset, backup/restore on a new phone, push token rotation
- **Privacy test:** inspect relay traffic and memory dumps to confirm no names, SDP or plaintext appear
- **Soak test:** a 1-hour call for memory and stability

---

## 8. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Users lose their phone and therefore their identity and contacts | High | Prominent backup reminders; encrypted backup file; linked devices (Phase 13) |
| Incoming calls unreliable on Android (Doze, OEM battery killers) | High | High-priority FCM, UnifiedPush option, native call UI, foreground service; test Xiaomi and Samsung early |
| A contact holds a stale push token, so wake-ups fail | Medium | Re-send tokens on change and periodically; caller sees "unreachable, try again" |
| Mistakes in home-made crypto code | High | Use only libsodium high-level APIs; never invent primitives; test vectors; external audit before v1.0 |
| Calls fail behind strict NAT/firewalls | High | coturn with TLS on 443; forced-relay testing |
| Short-lived metadata (who calls whom, IPs) visible to the relay while in RAM | Medium | No logging; read-only servers; documented honestly in the threat model; "Hide my IP" option |
| Spam or abuse without accounts | Medium | No directory, contacts-only calling, revocable invites, in-memory rate limits |
| Harder to debug production issues without logs | Medium | Good local diagnostics and user-exported reports; aggregate server counters |
| Recording without the other person's consent (legal exposure) | High | Always-visible indicator for both sides, consent prompt on by default, in-app notice |
| Desktop recording needs native code | Medium | Check `flutter_webrtc` support first; otherwise an FFmpeg-based plugin |
| Play Store policy rejection (foreground service / full-screen intent) | Medium | Declare service types correctly; provide a demo video for the review |

---

## 9. Definition of Done for v1.0

- 1:1 audio and video calls between Android, Windows and Linux in any combination
- **No accounts and no personal identifiers**; identity is a key pair on the device
- **The server stores nothing**: no database, no logs of users, verified by tests and a read-only deployment
- Signaling end-to-end encrypted and authenticated; media protected against interception; safety-number verification
- Contacts by QR code or invite link only; all user data encrypted on the device; encrypted backup and restore
- Calls connect across the internet with a setup success rate above 95%
- Incoming calls ring on Android when the app is killed and the phone is locked, without the server keeping push tokens
- Desktop receives calls while minimised to the tray
- Published relay source code, threat model and an honest privacy policy
