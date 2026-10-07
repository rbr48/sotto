# Calling App — Technical Plan & Roadmap

A VoIP audio/video calling app built with **Flutter + `flutter_webrtc`**, using a **self-built signaling server** and a **self-hosted TURN server (coturn)**.

- **Primary targets:** Android, Windows, Linux (macOS is cheap to add later)
- **Initial scope:** 1:1 audio and video calls between registered users
- **Later scope:** on-device call recording, small group calls (mesh, up to ~4 people), chat over data channels

---

## 1. Architecture Overview

```
 ┌──────────────────┐        WSS (signaling)         ┌──────────────────────┐
 │  Flutter client  │◀──────────────────────────────▶│  Signaling server    │
 │  (Android / PC)  │        HTTPS (REST API)        │  Node.js + TS        │
 │                  │◀──────────────────────────────▶│  - auth (JWT)        │
 │  flutter_webrtc  │                                │  - presence          │
 └───────┬──────────┘                                │  - call routing      │
         │                                           │  - TURN creds        │
         │   SRTP media (P2P when possible)          └──────┬───────┬───────┘
         │◀───────────────────────────────▶ other peer      │       │
         │                                           ┌──────▼──┐ ┌──▼──────┐
         │   STUN / TURN (when P2P fails)            │Postgres │ │  Redis  │
         └──────────────────────────────────┐        └─────────┘ └─────────┘
                                     ┌──────▼──────┐
                                     │   coturn    │   FCM (Android push for
                                     │ STUN + TURN │   incoming calls when the
                                     └─────────────┘   app is in the background)
```

### Components

| Component | Technology | Responsibility |
|---|---|---|
| Client app | Flutter 3.x, `flutter_webrtc`, Riverpod | UI, media capture, peer connection, call state machine |
| Signaling server | Node.js 20+ / TypeScript, `ws`, Fastify | WebSocket signaling, REST API, auth, presence, TURN credential issuing |
| Database | PostgreSQL | Users, contacts, call history, device/push tokens |
| Cache / pub-sub | Redis | Online presence, socket→user mapping, multi-instance fan-out (later) |
| TURN/STUN | coturn | NAT traversal; relays media when direct P2P fails |
| Push | Firebase Cloud Messaging | Wakes the Android app for incoming calls |
| Reverse proxy | Caddy or Nginx | TLS termination for `https://` and `wss://` |

> **Why Node.js for signaling?** It has mature WebSocket libraries, deploys easily and has a big ecosystem. A Dart server (`shelf` + `web_socket_channel`) also works and lets you share model classes with the app. Either is fine, but pick one and stick with it.

---

## 2. Repository Layout

```
calling/
├── app/                      # Flutter application
│   ├── android/
│   ├── windows/
│   ├── linux/
│   └── lib/
│       ├── main.dart
│       ├── core/             # config, DI, logging, theme, env
│       ├── data/
│       │   ├── api/          # REST client (auth, contacts, history)
│       │   └── signaling/    # WebSocket client + message models
│       ├── features/
│       │   ├── auth/
│       │   ├── contacts/
│       │   ├── history/
│       │   └── call/
│       │       ├── call_controller.dart   # state machine
│       │       ├── webrtc_session.dart    # RTCPeerConnection wrapper
│       │       ├── media_devices.dart     # camera/mic/speaker selection
│       │       └── ui/                    # incoming, outgoing, in-call screens
│       └── platform/
│           ├── android/      # push, CallKit-style UI, foreground service
│           └── desktop/      # tray, window, notifications
├── server/                   # Signaling + REST server (TypeScript)
│   ├── src/
│   │   ├── http/             # REST routes
│   │   ├── ws/               # signaling handlers
│   │   ├── services/         # auth, presence, calls, turn, push
│   │   └── db/               # migrations, queries
│   └── test/
├── infra/
│   ├── docker-compose.yml    # server + postgres + redis (+ coturn for dev)
│   ├── coturn/turnserver.conf
│   └── caddy/Caddyfile
└── docs/
    ├── ROADMAP.md            # this file
    └── SIGNALING_PROTOCOL.md
```

---

## 3. Key Technical Design

### 3.1 Signaling protocol (JSON over WSS)

Every message has a `type`, and every call-scoped message carries a `callId` (UUID v4) so that stale or duplicate messages can be dropped.

| Type | Direction | Purpose |
|---|---|---|
| `auth` | C→S | First message: `{ token }` (JWT) |
| `call.invite` | C→S→C | Start a call: `{ callId, to, media: "audio"\|"video" }` |
| `call.ringing` | C→S→C | Callee's device is ringing |
| `call.accept` / `call.reject` | C→S→C | Callee answers or declines |
| `call.cancel` | C→S→C | Caller hangs up before answer |
| `call.busy` | S→C | Callee is already in a call |
| `call.end` | C→S→C | Either side hangs up |
| `sdp.offer` / `sdp.answer` | C→S→C | Session descriptions |
| `ice.candidate` | C→S→C | Trickle ICE candidates |
| `presence` | S→C | Contact online/offline updates |
| `ping` / `pong` | both | Heartbeat every 20–30 s |
| `error` | S→C | `{ code, message, callId? }` |

Example:

```json
{ "type": "sdp.offer", "callId": "6f1c…", "to": "user_42", "sdp": "v=0\r\no=- …" }
```

**Rules:**
- The server **never parses SDP**. It authenticates, checks that both users are part of the call, and relays.
- The server keeps authoritative **call state** (`ringing`, `active`, `ended`) for busy detection, timeouts and history.
- **Ring timeout:** 45 s, then the server sends `call.end { reason: "no_answer" }` to both sides and logs a missed call.
- **Multi-device:** an invite rings all of the callee's online devices. The first `call.accept` wins, and the server sends `call.end { reason: "answered_elsewhere" }` to the others.

### 3.2 WebRTC session

- Use the **"perfect negotiation"** pattern (polite/impolite peer) so that renegotiation is safe, for example when switching audio→video or starting a screen share.
- **Trickle ICE**: send candidates as they are gathered and queue remote candidates until `setRemoteDescription` is done.
- **ICE restart** on `iceConnectionState == disconnected/failed` or on an OS network-change event (Wi-Fi ↔ mobile).
- Codecs: Opus for audio; VP8 for video by default (widest compatibility). H.264 can be preferred later for hardware encoding on Android.
- Default video constraints: 640×480 @ 24–30 fps for mobile, 1280×720 for desktop. Use `RTCRtpSender.setParameters` to cap bitrate.
- Encryption: WebRTC media is always DTLS-SRTP encrypted. TURN only relays encrypted packets, so 1:1 calls are effectively end-to-end encrypted.

### 3.3 Client call state machine

```
idle ──invite──▶ outgoing ──ringing──▶ outgoingRinging ──accept──▶ connecting ──ICE ok──▶ connected
  │                                                                     ▲                   │
  └──incoming invite──▶ incomingRinging ──accept──────────────────────┘    reconnecting ◀─┘
                              │                                              │
                     reject / cancel / timeout / end ────────────────▶ ended ──▶ idle
```

All UI is driven by this single state object (a Riverpod `Notifier`), which makes it testable without real media.

### 3.4 TURN (coturn)

- Use **time-limited credentials** (the TURN REST API scheme) so that no static password ships in the app:
  - `username = "<unix_expiry>:<userId>"`
  - `credential = base64(HMAC-SHA1(static_auth_secret, username))`
  - The server issues them via `GET /turn-credentials` with a TTL of about 12 h.
- Listen on **3478 UDP/TCP** and **5349 TLS**, and ideally also **443 TLS** on a dedicated IP to get through corporate firewalls.
- Relay port range: `49152–65535/udp`, open in the firewall.
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
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
total-quota=300
user-quota=12
```

(The `denied-peer-ip` lines stop the TURN server from being abused to reach your private network.)

### 3.5 Key Flutter packages

| Need | Package |
|---|---|
| WebRTC | `flutter_webrtc` |
| WebSocket | `web_socket_channel` |
| State management | `flutter_riverpod` |
| HTTP | `dio` |
| Secure token storage | `flutter_secure_storage` |
| Permissions | `permission_handler` |
| Push (Android) | `firebase_messaging` |
| Native incoming-call UI (Android) | `flutter_callkit_incoming` |
| Keep screen on during calls | `wakelock_plus` |
| Network change detection | `connectivity_plus` |
| Desktop window / tray | `window_manager`, `tray_manager` |
| Desktop notifications | `local_notifier` |
| Single instance (desktop) | `windows_single_instance` / custom lock file |

---

## 4. Roadmap

Estimates assume **one full-time developer** familiar with Flutter. Two developers (one app, one server) can roughly halve the calendar time from Phase 2 onward.

### Phase 0 — Foundations (Week 1)
- [ ] Create the monorepo structure (`app/`, `server/`, `infra/`, `docs/`)
- [ ] `flutter create` with `android`, `windows`, `linux` platforms; set Android `minSdk` to 24+
- [ ] Add `flutter_webrtc`; configure Android permissions (`CAMERA`, `RECORD_AUDIO`, `INTERNET`, `MODIFY_AUDIO_SETTINGS`, `BLUETOOTH_CONNECT`, `POST_NOTIFICATIONS`)
- [ ] Server skeleton: TypeScript, Fastify, `ws`, ESLint/Prettier, Vitest
- [ ] `docker-compose` for Postgres + Redis + server for local development
- [ ] CI (GitHub Actions): `flutter analyze`, `flutter test`, server lint and tests, Android APK and Windows build artifacts

**Exit criteria:** an empty app builds on Android and Windows in CI; the server responds to `/health`.

### Phase 1 — WebRTC Proof of Concept (Weeks 2–3)
- [ ] Local camera preview with `RTCVideoRenderer` on Android and Windows
- [ ] **Loopback call**: two `RTCPeerConnection`s in the same app, to learn the offer/answer/ICE flow
- [ ] Minimal "dumb relay" WebSocket server (rooms by code, no auth)
- [ ] First real call: Android ↔ Windows on the **same LAN** using public Google STUN only
- [ ] Mute mic, toggle camera, hang up

**Exit criteria:** a video call works between an Android phone and a Windows PC on the same Wi-Fi.

### Phase 2 — Signaling Server v1 (Weeks 4–5)
- [ ] Write `docs/SIGNALING_PROTOCOL.md` (section 3.1 above, made formal)
- [ ] JWT authentication on WebSocket connect
- [ ] Message validation (zod) and rejection of messages for calls the user is not part of
- [ ] Server-side call state: invite → ringing → active → ended; busy detection; 45 s ring timeout
- [ ] Heartbeat and dead-connection cleanup
- [ ] Client: `SignalingClient` with automatic reconnect (exponential backoff) and a message queue
- [ ] Client: call state machine (section 3.3) with unit tests using fake signaling

**Exit criteria:** user A can call user B by user ID with proper ringing, accept, reject, cancel and busy behaviour.

### Phase 3 — NAT Traversal with coturn (Week 6)
- [ ] Provision a VPS with a public IP; deploy coturn with TLS (Let's Encrypt)
- [ ] `GET /turn-credentials` endpoint issuing HMAC time-limited credentials
- [ ] Client fetches ICE servers before each call
- [ ] Test matrix: same Wi-Fi, Wi-Fi ↔ 4G, 4G ↔ 4G, **forced relay** (`iceTransportPolicy: relay`), and a restrictive network over TLS
- [ ] Log the selected ICE candidate pair type (host/srflx/relay) for each call

**Exit criteria / Milestone M1:** a call connects across the internet between any two networks in the test matrix.

### Phase 4 — Accounts, Contacts & Presence (Weeks 7–8)
- [ ] REST: register/login (email+password or phone OTP), refresh tokens
- [ ] Postgres schema: `users`, `devices`, `contacts`, `calls`
- [ ] Contact list: search users, add/remove contacts
- [ ] Online/offline presence via Redis, pushed over the WebSocket
- [ ] Call history: missed, incoming, outgoing, duration
- [ ] Client screens: login, contacts, history, profile

**Exit criteria:** two users can sign up, add each other and call from the contact list; history is recorded.

### Phase 5 — Call Experience & Media Controls (Weeks 9–10)
- [ ] Polished screens: outgoing, incoming, in-call (draggable local preview)
- [ ] Audio-only calls; upgrade audio→video mid-call (renegotiation)
- [ ] Switch front/back camera (Android)
- [ ] Speaker / earpiece / Bluetooth / wired headset routing (Android)
- [ ] **Desktop device pickers**: choose camera, microphone and speaker; hot-plug handling
- [ ] Ringtone and ringback tones; proximity sensor screen-off for audio calls (Android)
- [ ] Call-quality indicator from `getStats()` (RTT, packet loss, bitrate)
- [ ] Picture-in-Picture on Android

**Exit criteria / Milestone M2 — Internal Alpha:** usable 1:1 calling while both apps are open in the foreground.

### Phase 6 — Android Background & Incoming Calls (Weeks 11–13)
This is usually the **hardest part** of the project, so leave buffer time.
- [ ] Register FCM tokens per device on login
- [ ] Server sends a **high-priority data message** for `call.invite` when the callee has no live socket (or always, to be safe)
- [ ] Background handler shows a native incoming-call screen via `flutter_callkit_incoming` (lock screen and full-screen intent)
- [ ] On accept: start the app, reconnect the socket, fetch the pending call, then continue the normal flow
- [ ] **Foreground service** during calls with types `phoneCall|microphone|camera` (required on Android 14+), with an ongoing-call notification
- [ ] Permissions: `USE_FULL_SCREEN_INTENT`, `FOREGROUND_SERVICE_PHONE_CALL`, `FOREGROUND_SERVICE_MICROPHONE`, `FOREGROUND_SERVICE_CAMERA`
- [ ] Handle a GSM call interrupting a VoIP call (audio focus)
- [ ] Test on Samsung, Xiaomi, Pixel, plus Doze mode and battery savers; guide users to disable battery optimisation if needed

**Exit criteria:** an incoming call rings on a locked Android phone with the app killed, within about 3 seconds.

### Phase 7 — Desktop Polish (Weeks 14–15)
- [ ] System tray icon; minimise to tray so the socket stays connected to receive calls
- [ ] Start at login (optional setting)
- [ ] Native notification plus a focused incoming-call window
- [ ] Single-instance enforcement
- [ ] **Screen sharing** with `navigator.mediaDevices.getDisplayMedia` and a source picker (screens/windows)
- [ ] Keyboard shortcuts (mute, hang up)
- [ ] Packaging: Windows **MSIX** or Inno Setup installer; Linux **AppImage** / `.deb`

**Exit criteria:** installable desktop builds that receive calls while minimised.

### Phase 8 — Reliability & Call Quality (Weeks 16–17)
- [ ] ICE restart on network change and on `disconnected` (with a "Reconnecting…" UI and a 30 s give-up)
- [ ] Signaling reconnect in the middle of a call without dropping media
- [ ] Bandwidth adaptation: lower resolution/bitrate when packet loss rises; audio-only fallback
- [ ] Upload a short per-call stats summary to the server (no media) for debugging
- [ ] Crash reporting (Sentry or Firebase Crashlytics)
- [ ] Server: structured logs and metrics (calls/min, connect success rate, relay ratio, time-to-connect)

**Exit criteria:** call setup success rate above 95% in the test matrix; calls survive a Wi-Fi → 4G switch.

### Phase 9 — Security & Hardening (Week 18)
- [ ] TLS everywhere (`https`, `wss`, `turns`)
- [ ] Short-lived access tokens plus rotating refresh tokens
- [ ] Rate limiting on login, invite and TURN-credential endpoints
- [ ] Block/report users; only contacts can call (configurable)
- [ ] coturn hardening (denied private ranges, quotas, monitoring for relay abuse)
- [ ] Dependency and secret scanning in CI
- [ ] Privacy policy (required for Play Store camera/mic use)

**Milestone M3 — Closed Beta (end of Week 18):** release to roughly 20–50 testers through Play Console internal testing and a desktop download link.

### Phase 10 — Group Calls, Mesh (Weeks 19–21, optional for v1)
- [ ] Room concept on the server (`room.join`, `room.leave`, participant list)
- [ ] Each participant keeps one `RTCPeerConnection` per other participant (mesh)
- [ ] Grid layout, active-speaker detection from audio levels
- [ ] Hard cap at **4 participants**, because mesh upload bandwidth grows with N−1

> Beyond about 4 participants you need an **SFU** (mediasoup, Janus or LiveKit). That is a separate project and is out of scope for this roadmap.

### Phase 11 — Release (Weeks 22–24)
- [ ] Beta feedback fixes
- [ ] Play Store listing: data-safety form, foreground-service declarations, and the full-screen intent declaration (calling apps qualify)
- [ ] Windows code signing certificate (avoids SmartScreen warnings)
- [ ] Production infrastructure: separate signaling and TURN hosts, backups, monitoring and alerting
- [ ] Load test the signaling server (for example k6 with WebSocket clients)

**Milestone M4 — v1.0 public release (about 6 months).**

### Phase 12 — On-Device Call Recording (Weeks 25–28, post v1.0)
Recording happens **on the user's device**. Media stays peer-to-peer and end-to-end encrypted, and the server never sees or stores call content.

**Shared (all platforms)**
- [ ] Signaling messages `call.recording.started` / `call.recording.stopped`, relayed to the other participant
- [ ] Visible **"● Recording"** indicator shown to **both** participants for the whole time recording is on
- [ ] Optional consent prompt: the other participant must accept before recording starts (configurable; on by default)
- [ ] Recording is stopped automatically on hang-up, call failure or the app being killed (finalise the file safely)
- [ ] Recordings library screen: list, play, share, rename, delete
- [ ] Recordings stored in app-private storage, encrypted at rest (AES-GCM, key in `flutter_secure_storage`)
- [ ] Audio-only recordings for voice calls (`.m4a`/AAC); video recordings for video calls (`.mp4`, H.264 + AAC)
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
- [ ] Update the privacy policy and the Play Store data-safety form (audio/video recorded and stored on device)
- [ ] In-app notice explaining that the user is responsible for consent under local recording laws

**Exit criteria / Milestone M5:** both sides of a call are recorded into a single playable file on Android and desktop, and the other participant always sees the recording indicator.

### Summary timeline

| Weeks | Phase | Milestone |
|---|---|---|
| 1 | Foundations | |
| 2–3 | WebRTC PoC | First LAN call |
| 4–5 | Signaling v1 | |
| 6 | coturn | **M1: call over the internet** |
| 7–8 | Accounts & contacts | |
| 9–10 | Call UX | **M2: internal alpha** |
| 11–13 | Android background calls | |
| 14–15 | Desktop polish | |
| 16–17 | Reliability | |
| 18 | Security | **M3: closed beta** |
| 19–21 | Group calls (optional) | |
| 22–24 | Release | **M4: v1.0** |
| 25–28 | On-device call recording | **M5: recording** |

---

## 5. Infrastructure & Cost Estimate

| Stage | Setup | Approx. monthly cost |
|---|---|---|
| Development | Docker Compose locally plus one small VPS for coturn | $5–10 |
| Beta | 1 VPS (2 vCPU / 4 GB) for signaling + DB + Redis; 1 VPS for coturn | $15–40 |
| Production | Signaling ×2 behind a load balancer, managed Postgres, Redis, 2+ coturn nodes in different regions | $100+ (bandwidth driven) |

**TURN bandwidth is the main variable cost.** About 15–20% of calls usually need relaying. A relayed 720p video call uses roughly 1.5–2.5 Mbps per direction, which is about 1–2 GB per hour of relayed call. Pick providers with generous included traffic, such as Hetzner or OVH.

---

## 6. Testing Strategy

- **Unit:** call state machine, signaling message parsing, TURN credential generation (server)
- **Integration:** signaling server with two fake WebSocket clients running the full invite→answer→end flow
- **Widget tests:** call screens driven by fake state
- **Manual device matrix:**
  - Android 9, 11, 13, 14, 15+ on Samsung, Xiaomi and Pixel
  - Windows 10 and 11; Ubuntu 22.04/24.04
  - Networks: same LAN, Wi-Fi ↔ 4G, forced TURN relay, TLS-only firewall
  - Scenarios: app killed / backgrounded / screen locked; network switch mid-call; Bluetooth headset; incoming GSM call during a VoIP call
- **Soak test:** a 1-hour call to check for memory leaks and stability

---

## 7. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Incoming calls unreliable on Android (Doze, OEM battery killers) | High | High-priority FCM, CallKit-style UI, foreground service, battery-optimisation guidance; test on Xiaomi and Samsung early |
| Calls fail behind strict NAT/firewalls | High | coturn with TLS on 443; forced-relay testing in Phase 3 |
| TURN bandwidth costs grow | Medium | Time-limited credentials, per-user quotas, monitor relay ratio, cheap-bandwidth hosting |
| `flutter_webrtc` platform gaps or bugs on desktop | Medium | Prototype every desktop feature in Phase 1/7; pin versions; contribute fixes upstream or work around in native code |
| Mesh group calls do not scale | Medium | Cap at 4; plan an SFU as a later project |
| Echo or audio-routing issues on Android | Medium | Use WebRTC's built-in AEC; test speaker vs earpiece vs Bluetooth explicitly |
| Play Store policy rejection (foreground service / full-screen intent) | Medium | Declare service types correctly; provide a demo video for the review |
| Recording without the other person's consent (legal exposure) | High | Always-visible indicator for both sides, consent prompt on by default, in-app notice and privacy policy |
| Desktop recording needs native code (no ready-made Flutter support) | Medium | Check `flutter_webrtc` support first; otherwise an FFmpeg-based native plugin, with time budgeted in Phase 12 |

---

## 8. Definition of Done for v1.0

- 1:1 audio and video calls between Android, Windows and Linux in any combination
- Calls connect across the internet with a setup success rate above 95%
- Incoming calls ring on Android when the app is killed and the phone is locked
- Desktop receives calls while minimised to the tray
- Mute, camera toggle, camera switch, speaker routing, device selection and screen share (desktop)
- Accounts, contacts, presence, call history
- Recovery from network changes during a call
- Production infrastructure with monitoring, and signed release builds
