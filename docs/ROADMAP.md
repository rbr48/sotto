# Sotto — Product Strategy, Technical Plan & Roadmap

**Sotto: private calls for professionals and their clients. No accounts, no data stored, on our servers or yours.**

A privacy-first audio/video calling product built with **Flutter + `flutter_webrtc`**, a **stateless signaling relay** and a **self-hosted TURN server (coturn)**.

- **Who it's for:** professionals and small organisations that must protect conversations with clients and colleagues
- **Professional apps:** Windows, Linux and Android (iOS and macOS later)
- **Guests (clients):** join from **any browser** with a link; no app, no account
- **Deployment:** our hosted service, or one-command self-hosting on the customer's own server

---

## 1. Product Strategy

### 1.1 The problem
Lawyers, therapists, doctors, accountants, journalists and NGOs talk about sensitive matters over Zoom, Teams, Google Meet or WhatsApp. Those services hold account data, metadata and sometimes recordings on servers the professional doesn't control. Many of these professionals have legal or ethical duties to protect client confidentiality.

### 1.2 The solution
- **Guest links:** the professional sends a link; the client joins from a browser with no install or sign-up.
- **End-to-end encrypted 1:1 calls** by default.
- **Zero server storage:** "we can't leak what we don't have."
- **Consent-based recording on the professional's own device** (both voices, voice-only or video).
- **Self-host in one command** for organisations that want full control.

### 1.3 First target group (beachhead)
Pick **one** group and serve it very well before expanding. Candidates:

| Group | Why they might pay | Watch out for |
|---|---|---|
| Therapists / counsellors | Confidential 1:1 sessions are the whole job; many are solo practitioners who decide quickly | Health-data rules (HIPAA in the US, GDPR in the EU) |
| Small law firms | Attorney–client privilege; already pay for software | Slower buying decisions |
| Small clinics / doctors | Telehealth demand | Strongest compliance requirements |
| Journalists / NGOs | Source protection; value self-hosting | Low budgets; grants and donations more likely |
| Accountants / financial advisers | Confidential client calls | Less urgent privacy concern |

The choice is made in Stage A (validation), based on interviews.

### 1.4 Competition and how we differ

| Competitor | Their strength | Where we differ |
|---|---|---|
| Zoom / Teams / Google Meet | Familiar, feature-rich | They store accounts, metadata and cloud recordings; E2E is optional or limited |
| Jitsi Meet | Free, open source, self-hostable, browser-based | Server-side media routing (SFU); E2EE optional; general-purpose meetings, not a professional–client workflow; no native recording with consent |
| Doxy.me / therapy-specific tools | Built for telehealth | Cloud accounts and stored data; can't self-host |
| Signal / SimpleX / Jami | Strong privacy | Both sides must install the app; no guest links, waiting room, scheduling or professional features |

**Positioning:** the simplest way for a professional to have a truly private call with a client, with nothing stored anywhere except on the professional's own device.

### 1.5 Business model

| Plan | Price (initial guess, to be validated) | Includes |
|---|---|---|
| **Free / open source** | $0 | Apps and relay source code; self-host with community support |
| **Pro (hosted)** | ~$8–12 per professional per month | Our hosted relay + TURN, guest links, waiting room, scheduling, recording, priority support |
| **Business self-hosted** | ~$500–2,000 per year per organisation | Licence for branding (logo/name), team features, setup help and support contract |

- Payments go through a merchant-of-record provider (Paddle or Lemon Squeezy, or Stripe), so **billing data stays with the payment provider, not our servers**.
- Access is checked with **signed licence tokens** verified offline, so the relay still stores nothing (section 5.15).

### 1.6 Go-to-market
1. Interviews and a landing page with a waitlist for the chosen group.
2. Free pilots with 3–5 organisations in exchange for weekly feedback and a testimonial.
3. Content aimed at the group ("How to run confidential online sessions"), plus professional associations, forums and conferences.
4. Every guest call shows a small "Secured by Sotto" footer: each client a professional calls sees the product.
5. Referral discount: a professional who brings a colleague gets a free month.

### 1.7 Success metrics

| Stage | Target |
|---|---|
| Validation (week 4) | 15–20 interviews done; **50+ waitlist sign-ups** from the target group |
| MVP (week 16) | Guest link call works on Chrome, Edge, Firefox and Safari (iPhone); call setup success > 95% |
| Pilot (week 22) | **3+ organisations using it every week**; at least 2 say they'd pay |
| Paid launch (~month 7) | **First paying customers**; monthly churn < 5% |
| Month 12 | 100+ paying professionals or 5+ business licences; a second target group started |

If validation fails (few sign-ups, nobody would pay), change the target group or idea **before** building the full product.

---

## 2. Privacy Principles

These rules override every other design decision in this document.

1. **Zero server storage.** The server has no user database and writes no user data to disk. Everything it knows lives in RAM and disappears when a connection closes or the server restarts.
2. **The server is a switchboard, not a participant.** It routes encrypted envelopes. It cannot read call setup data, contact lists, names or messages.
3. **No accounts and no personal identifiers.** Professionals are identified by a key pair created on their own device. Guests get a temporary key in their browser that is thrown away after the call.
4. **No directory.** Nobody can be searched for. People connect only through QR codes, invite links or guest links.
5. **All user data lives on the professional's device**, encrypted at rest: identity key, contacts, call history, scheduled links, settings, recordings.
6. **End-to-end encryption everywhere.** Signaling is E2E encrypted and signed. Media is DTLS-SRTP, and the media fingerprints are authenticated end to end so the server can't intercept the call.
7. **No logs, no analytics, no tracking**, including on the guest web page (no cookies, no third-party scripts). Diagnostics are opt-in and exported by the user.
8. **Open source.** Apps and relay code are public so anyone can verify what they do and do not keep.

---

## 3. Architecture Overview

```
 ┌───────────────────────────┐                              ┌──────────────────────────┐
 │ Professional app          │                              │ Guest (any browser)      │
 │ Windows / Linux / Android │                              │ Flutter Web page         │
 │ - identity key pair       │                              │ - temporary key pair     │
 │ - encrypted local DB      │                              │ - no install, no account │
 └──────┬─────────────▲──────┘                              └──────▲────────────┬──────┘
        │ WSS {to, ciphertext}                                     │            │
        │             │        ┌──────────────────────────┐        │            │
        └─────────────┼───────▶│ Signaling relay          │────────┘            │
                      │        │ - RAM only, no DB/disk   │                     │
                      │        │ - routes by public key   │──▶ FCM / UnifiedPush│
                      │        │ - checks licence tokens  │    ("wake up" only) │
                      │        └──────────────────────────┘                     │
                      │                                                         │
                      │     SRTP media (direct P2P when possible)               │
                      └─────────────────────────────────────────────────────────┘
                                     │ fallback │
                               ┌─────▼──────────▼──┐      ┌─────────────────────┐
                               │      coturn       │      │ Static web host     │
                               │  logging disabled │      │ guest page (no logs,│
                               └───────────────────┘      │ no cookies)         │
                                                          └─────────────────────┘
```

### Components

| Component | Technology | Stores user data? |
|---|---|---|
| Professional app | Flutter 3.x, `flutter_webrtc`, Riverpod, libsodium | **Yes, locally only**, encrypted |
| Guest web client | Flutter Web, `flutter_webrtc` (web), libsodium.js | **No.** Temporary key in memory, gone when the tab closes |
| Signaling relay | Node.js 20+ / TypeScript, `ws` | **No.** RAM only: live sockets, short-lived queues |
| TURN/STUN | coturn | **No.** Logging disabled; stateless HMAC credentials |
| Static web host | Caddy serving the guest page | **No.** Access logs disabled |
| Push | FCM or UnifiedPush | Content-free "wake up" pings only |
| Billing | Paddle / Lemon Squeezy / Stripe | Billing details held by the payment provider, never by our servers |

There is **no Postgres and no Redis** in v1. If the relay later needs several instances, use Redis pub/sub with persistence turned off (`save ""`, `appendonly no`) purely for routing between instances.

---

## 4. Repository Layout

```
calling/
├── app/                          # Flutter: professional app (Android/Windows/Linux) + guest web build
│   ├── android/  windows/  linux/  web/
│   └── lib/
│       ├── main.dart             # professional app entry
│       ├── main_guest.dart       # guest web entry (small, no local storage)
│       ├── core/                 # config, DI, local-only logging, theme, branding
│       ├── crypto/               # identity keys, envelopes, safety numbers, backup encryption
│       ├── storage/              # encrypted local database
│       ├── relay/                # WebSocket client, envelopes, offline queue
│       ├── features/
│       │   ├── onboarding/       # create identity / restore from backup / enter licence
│       │   ├── guest_links/      # create, schedule, revoke links; waiting room
│       │   ├── guest/            # guest join flow: device check, knock, call
│       │   ├── contacts/         # QR + invite links for colleagues
│       │   ├── history/
│       │   ├── settings/
│       │   ├── recording/
│       │   └── call/
│       │       ├── call_controller.dart   # state machine
│       │       ├── webrtc_session.dart    # RTCPeerConnection wrapper
│       │       ├── media_devices.dart
│       │       └── ui/
│       └── platform/
│           ├── android/          # push wake-up, native incoming-call UI, foreground service
│           └── desktop/          # tray, window, notifications
├── server/                       # Stateless relay (TypeScript)
│   └── src/
│       ├── auth.ts               # challenge-response with public keys
│       ├── router.ts             # in-memory publicKey → socket map
│       ├── queue.ts              # RAM-only envelope queue (TTL 60 s)
│       ├── push.ts               # forwards wake-ups, stores nothing
│       ├── turn.ts               # stateless HMAC TURN credentials
│       ├── licence.ts            # offline verification of signed licence tokens
│       └── limits.ts             # in-memory rate limiting
├── infra/
│   ├── docker-compose.yml        # relay + coturn + guest web page (read-only filesystems)
│   ├── install.sh                # one-command self-host setup (domain, TLS, secrets)
│   ├── coturn/turnserver.conf
│   └── caddy/Caddyfile
└── docs/
    ├── ROADMAP.md                # this file
    ├── FEATURES.md
    ├── PROTOCOL.md
    ├── THREAT_MODEL.md
    └── SELF_HOSTING.md
```

### 4.1 App identifiers

The package name / application ID is **`com.izhaanintellect.sotto`** on every platform. It can't be changed after the Play Store release, so set it before the first build.

| Platform | Where it is set | Value |
|---|---|---|
| Android | `app/android/app/build.gradle(.kts)` → `namespace` and `applicationId`; Kotlin package `com.izhaanintellect.sotto` | `com.izhaanintellect.sotto` |
| Linux | `app/linux/CMakeLists.txt` → `APPLICATION_ID`; Flatpak / `.desktop` file ID | `com.izhaanintellect.sotto` |
| Windows | Inno Setup `AppId` in `packaging/windows/sotto.iss` (never changes); publisher: Izhaan Intellect | `{D44D3E58-C89A-4CAC-918B-BD5CC12187DB}` |
| Web (guest page) | `app/web/manifest.json` → `id` | `com.izhaanintellect.sotto` |
| iOS / macOS (later) | Bundle identifier | `com.izhaanintellect.sotto` |
| Firebase (FCM) | Android app registered in the Firebase project | `com.izhaanintellect.sotto` |
| Dart package | `pubspec.yaml` → `name` | `sotto` |

Native code (the Android audio mixer, desktop recording plugin) lives under the `com.izhaanintellect.sotto` package / namespace.

---

## 5. Key Technical Design

### 5.1 Identity (no accounts)

- On first launch the app generates a 32-byte **master secret** with libsodium and derives two key pairs from it: an **Ed25519 signing key** and an **X25519 encryption key** (`crypto_kdf`, see `docs/PROTOCOL.md`). Separate keys avoid key conversion, which would need libsodium's much larger "sumo" build on the web.
- Only the master secret is stored, with `flutter_secure_storage` (Android Keystore, Windows DPAPI or Linux libsecret). Backups only need the master secret.
- **User ID = the Ed25519 public key**, as base64url. Users never type it; it travels inside QR codes and links, together with the encryption key in a signed **identity card**.
- **Display name and avatar** are stored locally and sent to contacts only inside encrypted messages. The server never sees them.

### 5.2 Adding contacts (no directory)

1. User B opens *Add contact → Show my code*. The app shows a **QR code** or produces an **invite link**:
   `https://call.example.com/i#<base64url payload>`
   The payload goes after `#`, which browsers never send to the server. It contains B's public key, display name and a one-time invite secret, signed by B.
2. User A scans the QR code or opens the link. A's app sends an encrypted `contact.request` to B through the relay.
3. B's app checks the invite secret (or asks B to approve) and replies with `contact.accept`.
4. Both apps then exchange, end to end encrypted: display name, avatar, and **push wake-up tokens** (section 5.7).
5. Contacts are saved only in each device's encrypted local database.

Because public keys can't be guessed and there is no directory, **strangers cannot call you** unless you shared your code.

**As built in Phase 6:** a simpler first version. B's **contact link** (`https://<host>/#c=<payload>`, also shown as a QR code) carries B's identity card, name and organisation, signed by B (`docs/PROTOCOL.md` §5.8). A pastes it into *Contacts → Add contact*; the contact is saved on A's device only, and A can mark it **verified** after comparing safety numbers. There is no `contact.request` exchange yet, so B learns about A on A's first call (and can add A from the call or the history). The invite-secret handshake and push tokens arrive with push wake-up (Phase 12).

### 5.3 Relay protocol: what the server sees

Outer envelope (the only thing the server can read):

```json
{ "type": "relay", "to": "<recipient public key>", "id": "<random msg id>", "body": "<base64 ciphertext>", "wake": { "provider": "fcm", "token": "…" } }
```

- `from` is **not** sent by the client. The server attaches the authenticated public key of the sending socket.
- `body` is an envelope: the inner message is **signed** with the sender's Ed25519 key, then **sealed** to the recipient's X25519 key (`crypto_box_seal`). The signature authenticates the sender and covers the recipient, so nobody can forge or re-address messages. Details in `docs/PROTOCOL.md`.
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

### 5.4 Relay server behaviour (RAM only)

- **Connect:** the server sends a random 32-byte challenge, the client signs it with its identity key, and the server verifies it. The socket is now bound to that public key, in memory only.
- **Routing:** an in-memory `Map<publicKey, Set<socket>>`. If the recipient is online, the envelope is forwarded immediately.
- **Offline recipient:** if `wake` is present, the server sends a content-free push and keeps the envelope **in RAM for up to 60 s**. If the recipient connects within that time, it is delivered; otherwise it is dropped.
- **Nothing is written to disk:** containers run with a read-only root filesystem and `tmpfs` only; there are no access logs and process logs contain no keys, IPs or tokens.
- **Rate limits** are in-memory counters per socket and per IP, using a salted hash that rotates daily and is never persisted.
- **Monitoring** uses aggregate counters only (connected sockets, envelopes per second, error counts).

### 5.5 WebRTC session and MITM protection

- Use the **"perfect negotiation"** pattern; trickle ICE; ICE restart when the network changes.
- **Media can't be intercepted by the server:** the DTLS fingerprint in the SDP is inside the E2E-encrypted, sender-authenticated envelope. The relay can't swap it, so it can't put itself in the middle of the media.
- **Safety number:** a short code derived from both public keys, shown as 12 groups of digits plus a QR code. Users can compare it once in person or on a call to mark a contact as **verified**.
- Codecs: Opus for audio; VP8 by default for video, optional H.264.
- Optional **"Hide my IP address"** setting: forces `iceTransportPolicy: relay`, so the other person only sees the TURN server's IP. It costs some latency and TURN bandwidth.

### 5.6 TURN (coturn), stateless and log-free

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

### 5.7 Waking Android for incoming calls without storing push tokens

To ring a closed app, *someone* has to know its push token. In this design, **the user's contacts hold it, not the server**.

1. Each device obtains a push token: FCM, or a **UnifiedPush** endpoint for users who avoid Google.
2. The token is sent **only to contacts**, inside E2E-encrypted `contact.accept` / `contact.update` messages. It is refreshed whenever it changes.
3. To call someone, the caller's app puts the callee's token in the envelope's `wake` field.
4. The relay sends a **content-free** high-priority push (no name, no caller ID, just "wake"), then forgets the token.
5. The callee's app wakes, connects to the relay, receives the queued encrypted `call.invite`, and shows the incoming-call screen.

The server holds the FCM *project* credential, which is server configuration, not user data. Google sees only that a device received a ping.

### 5.8 Local data on the device

- **Encrypted vault** (as built in Phase 6, instead of drift + SQLCipher): all local data (profile, contacts, call history and notes, guest links, settings) is one key-value map, encrypted with XChaCha20-Poly1305 under a random 256-bit key kept in the OS keystore (`flutter_secure_storage`), and rewritten atomically on every change. The data is small (kilobytes), so a database isn't needed; this works identically on every platform, adds no second crypto library (SQLCipher brings OpenSSL) and uses the same audited libsodium. See `docs/PROTOCOL.md` §9. If the data grows (e.g. thousands of notes), it can move to SQLCipher later without changing the rest of the app.
- **App lock**: a PIN (6–16 digits, verified with Argon2id), lock after leaving the app (immediately, 1, 5 or 15 minutes) or on demand; growing waits after 5 wrong PINs. Calls still ring on top of the lock, like a phone. Biometrics (`local_auth`) come with the mobile work in Phase 12.
- **Auto-delete call history** after 7, 30 (default) or 90 days, keep forever, or don't keep history at all.

### 5.9 Encrypted backup and restore

Without accounts, a lost device means a lost identity, so the user gets a **backup file**:
- Contents: identity key, contacts and settings. Recordings are optional because they are large.
- Encryption: a key derived from the user's password with **Argon2id**, then XChaCha20-Poly1305.
- The user saves it wherever they choose: a file, USB drive or their own cloud. The app never uploads it.
- Restore: on first launch, *Restore from backup*, enter the password.
- As built in Phase 6: Argon2id (3 passes, 64 MiB), passphrase of at least 12 characters (or a generated 25-character one), optional call history and notes; the app lock and device choices stay on each device. Native apps only: the browser build has no Argon2id and never handles real identities. Format: `docs/PROTOCOL.md` §8.

### 5.10 What the server can and cannot see

| The server **never** sees | The server **briefly** sees, in RAM only, while it happens |
|---|---|
| Names, avatars, contact lists | Public keys of connected devices |
| Call setup content (SDP, ICE candidates inside the envelope) | Which key is sending an envelope to which key, and when |
| Audio/video (encrypted end to end) | IP addresses of connected devices (and of relayed TURN calls) |
| Call history, recordings | A push token, for the moment it forwards a wake-up |

Hiding even this short-lived metadata would need onion routing (like Tor), which adds too much latency for real-time calls. This limit is documented honestly in `THREAT_MODEL.md` and the privacy policy.

### 5.11 Abuse prevention without accounts

- No directory, so strangers can't find you.
- Calls and requests from unknown keys are dropped by the app.
- Invite links can be **single-use** or **expiring**, and can be revoked.
- Block a contact: their key is ignored locally. Optionally, the app stops sharing its push token with them.
- The relay applies in-memory rate limits per socket and IP and caps envelope size and queue length.

### 5.12 Key Flutter packages

| Need | Package |
|---|---|
| WebRTC | `flutter_webrtc` (native and web) |
| Guest web client | Flutter Web build; `sodium` uses libsodium.js in the browser |
| Cryptography (Ed25519, X25519, secretbox, Argon2id) | `sodium` (libsodium, built automatically for each platform; `sodium_libs` is deprecated) |
| Secure key storage | `flutter_secure_storage` |
| Encrypted local storage | Vault file encrypted with libsodium XChaCha20-Poly1305 (`path_provider` for its location); key in `flutter_secure_storage` |
| Backup files | `file_selector` (open/save dialogs) |
| WebSocket | `web_socket_channel` |
| State management | `flutter_riverpod` |
| QR display / scan | `qr_flutter` (Phase 6) / `mobile_scanner` (Phase 12; desktop: paste the contact link) |
| Invite links | `app_links` |
| Push | `firebase_messaging`, `unifiedpush` |
| Native incoming-call UI (Android) | `flutter_callkit_incoming` |
| App lock | PIN with Argon2id (Phase 6); `local_auth` biometrics (Phase 12) |
| Permissions | `permission_handler` |
| Keep screen on during calls | `wakelock_plus` |
| Network change detection | `connectivity_plus` |
| Desktop window / tray / notifications | `window_manager`, `tray_manager`, `local_notifier` |

### 5.13 Guest links (no app, no account for clients)

**Link format**

```
https://call.example.com/j#<base64url payload>
```

The payload sits after `#`, so it is **never sent to the web server**. It contains:
- the professional's public key
- a random link ID and a one-time or reusable secret
- an optional validity window (for scheduled calls) and display name
- a signature by the professional's identity key

**Join flow**
1. The client opens the link. The static guest page loads, with no cookies and no third-party scripts.
2. The page creates a **temporary key pair in memory** and runs a **device check**: camera and microphone preview, speaker test, browser compatibility.
3. The guest types a name (optional) and taps *Join*. The page sends an encrypted `guest.knock` (name, link ID, secret) to the professional's key through the relay.
4. The professional's app shows the guest in the **waiting room**. The professional taps *Admit* or *Decline*.
5. On admit, the normal call flow runs (`call.invite`, SDP, ICE), all end-to-end encrypted.
6. When the tab closes, the temporary key is gone. Nothing about the guest is stored anywhere except the professional's own local call history.

**Link types**
- **Personal room link:** reusable, like a permanent meeting room. Can be rotated at any time.
- **Scheduled link:** valid only in a time window, for example Tuesday 14:00–15:00. The app can export an `.ics` calendar file to send with it.
- **One-time link:** works for a single call and then expires.
- All links can be **revoked** from the app; revoked link IDs are kept in the local database.

**Browser support:** Chrome, Edge, Firefox, and Safari on iPhone/iPad and Mac, tested in every release.

**Abuse protection:** guests can only *knock*. Nothing reaches the professional without a valid signed link secret, and the professional must admit every guest. The relay rate-limits knocks per IP in memory.

### 5.14 Professional workflow features
- **Waiting room** with guest name, a "knocking since" timer and *Admit* / *Decline* / *Message* ("I'll be with you in 5 minutes").
- **Busy handling:** a guest who knocks while the professional is on another call sees "Please wait, you'll be admitted shortly".
- **Optional session notes** stored only in the local encrypted database and attached to the call history entry.
- **Branding** (Business plan): practice name, logo and colour shown on the guest page.

### 5.15 Licensing without storing customer data
- After payment, the payment provider triggers creation of a **licence token**: a small document (`plan`, `seats`, `expiry`, `licence ID`) signed with our private licence key.
- The professional pastes or opens the token in the app; it is stored locally.
- When connecting, the app presents the token to the relay. The relay checks the **signature and expiry** with our public licence key, **offline**, and stores nothing.
- Pro features (hosted TURN quota, scheduling, recording, branding) are unlocked on the client and the relay according to the token.
- Self-hosted installations use the same mechanism; the free tier works without a token.
- Seat limits are enforced loosely (concurrent connections per licence ID, counted in RAM). This trusts honest customers rather than tracking them.

### 5.16 Self-hosting package
- `curl -fsSL https://get.example.com | sh`, or download and run `infra/install.sh`. The script asks for the domain, gets TLS certificates, generates secrets and starts `docker compose`.
- It runs the relay, coturn and the guest web page, all on read-only filesystems.
- **Minimum server:** 1 vCPU, 1 GB RAM, public IP, ports 443 and 3478/5349 plus the UDP relay range open.
- The professional app points to the custom server domain (one setting, or a link from the admin that sets it).
- Updates: `./install.sh update` pulls signed images.
- `docs/SELF_HOSTING.md` covers firewalls, DNS and troubleshooting.

---

## 6. Roadmap

Estimates assume **one full-time developer** familiar with Flutter. A second developer for crypto, server and web can shorten the calendar by roughly 30–40%.

The roadmap has five stages. **Do not skip Stage A**: it decides whether the rest is worth building.

| Stage | Weeks | Goal |
|---|---|---|
| A. Validate | 1–4 | Prove that a specific group wants this and would pay |
| B. MVP | 5–17 | Private 1:1 calls with browser guest links |
| C. Pilot | 18–23 | 3–5 real organisations using it weekly; self-hosting works |
| D. Paid launch | 24–36 | Revenue, recording, scheduling, Android background calls, public launch |
| E. Grow | Months 9–12+ | iOS, teams, group calls, second target group |

---

### Stage A — Validate (Weeks 1–4)

#### Phase A — Customer Research & Waitlist
- [ ] Try the competitors for a week (Jitsi Meet, Doxy.me or a similar tool for your group, Signal, SimpleX); list what frustrates you and your target users
- [ ] Shortlist 2–3 candidate groups from section 1.3
- [ ] Interview **15–20** people from those groups: current tools, privacy worries, how they invite clients, what they pay today, what they'd pay
- [ ] Choose **one** beachhead group
- [ ] Landing page (no trackers): promise, 3 key features, pricing preview, waitlist form (email kept by the newsletter tool only, with consent)
- [ ] Share in the group's forums, associations and social channels
- [ ] Optional: a clickable prototype (Figma) of the guest join flow and the waiting room to show in interviews

**Exit criteria (go / no-go):** 50+ waitlist sign-ups from the chosen group and at least 5 people who say they would pay. If not, try the next group or rethink before writing product code.

---

### Stage B — MVP (Weeks 5–17)

#### Phase 0 — Foundations (Week 5)
- [x] Create the monorepo structure (`app/`, `server/`, `infra/`, `docs/`)
- [x] `flutter create --org com.izhaanintellect --project-name sotto --platforms android,windows,linux,web app`; Android `minSdk` 24+
- [x] Confirm the app ID is **`com.izhaanintellect.sotto`** on every platform (see section 4.1)
- [x] Add `flutter_webrtc` (web and Linux builds verified locally; Android and Windows built in CI)
- [x] Add `sodium` (libsodium) — done in Phase 2, where the crypto code first needs it
- [x] Android permissions: `CAMERA`, `RECORD_AUDIO`, `INTERNET`, `MODIFY_AUDIO_SETTINGS`, `BLUETOOTH_CONNECT`, `POST_NOTIFICATIONS`
- [x] Server skeleton: TypeScript, `ws`, ESLint/Prettier, Vitest
- [x] CI (GitHub Actions): analyze, tests, Android APK, Windows/Linux builds, web build, end-to-end browser call test
- [x] Test-server deployment (Docker Compose + Caddy) for `sotto.izhaanintellect.fun` — see `docs/DEPLOY_TEST_SERVER.md`

**Exit criteria:** the app builds for Android, Windows, Linux and web in CI; the relay accepts a WebSocket.

#### Phase 1 — WebRTC Proof of Concept (Weeks 6–7)
- [x] Local camera preview in the browser (verified with automated test)
- [ ] Local camera preview on Windows and Android (needs a real device)
- [x] Throwaway plaintext relay for experiments only (`/dev/rooms`; removed in Phase 3)
- [x] Browser ↔ browser call through the relay (automated end-to-end test)
- [ ] First calls on the same LAN: **Windows app ↔ browser** and Android ↔ Windows (needs real devices)
- [x] Mute mic, toggle camera, switch camera (Android), hang up

**Exit criteria:** video calls work between the desktop app and a browser on the same network.

#### Phase 2 — Identity & Crypto Core (Weeks 8–9)
- [x] Generate and securely store the professional's identity (`IdentityStore` + OS keystore; the onboarding screen that uses it comes in Phase 6)
- [x] Temporary in-memory key pairs for guests (web)
- [x] Envelope library `seal` / `open` (sign, then `crypto_box_seal`), working identically on native and web
- [x] Inner message format with `callId`, timestamp, nonce; replay protection
- [x] Safety-number generation, shown on the test call screen
- [x] Unit tests, known-answer test vectors from an independent implementation (`tools/crypto-vectors`), fuzz tests for malformed ciphertexts
- [x] Write `docs/PROTOCOL.md` and the first version of `docs/THREAT_MODEL.md`
- [x] Test call: identity cards exchanged, then offer/answer/ICE sent only as encrypted envelopes
- [x] Browser self-test (`?selftest=1`) in the end-to-end test; the test also checks the relay never sees readable call data

**Exit criteria:** native and web clients exchange encrypted, authenticated messages through a local relay; tampered or replayed messages are rejected.

#### Phase 3 — Stateless Relay Server (Weeks 10–11)
- [x] Challenge-response login with the public key, bound to the relay's hostname (professionals and guests)
- [x] In-memory routing map; envelope forwarding; multi-device fan-out; relay attaches the authenticated sender
- [x] RAM-only queue (TTL 60 s, size caps)
- [x] Heartbeat; dead-socket cleanup; in-memory rate limiting, connection/device limits and size limits
- [x] **No-storage enforcement:** read-only container filesystem, no DB, logs without keys, IPs or tokens; automated test that runs the real relay process and fails if it writes any file
- [x] Client relay connection with reconnect/backoff and outgoing queue; call state machine (busy, timeout, cancel handled on the clients), tested with a fake clock
- [x] Plaintext proof-of-concept rooms (`/dev/rooms`) removed
- [x] Call links: open someone's link to ring them (replaced by signed guest links in Phase 5)
- [x] End-to-end test: ringing, accept + live video, busy, hang up, decline, cancel/missed across three browsers; relay frames checked to be logins and opaque envelopes only

**Exit criteria:** encrypted calls between two clients by public key with ringing, accept, reject, cancel and busy behaviour. The relay can't read any message body.

#### Phase 4 — NAT Traversal with coturn (Week 12)
- [x] coturn in Docker Compose (`infra/coturn/start.sh`): TURN over UDP/TCP 3478 and TLS 5349 (Caddy's certificate), logs discarded, private/special IP ranges denied, TCP relaying off, quotas and bandwidth cap
- [x] Stateless TURN credentials, issued over the relay connection only to logged-in clients (in `ready`, refreshable with `{"type":"ice"}`); usernames contain no Sotto ID
- [x] Relay hands out Sotto's own STUN server; Google STUN only as a fallback
- [x] "Hide my IP address" setting (relay-only ICE), saved on the device
- [x] Call screen shows **Direct connection** / **Relayed through Sotto**
- [x] Automated: e2e test checks a normal call is direct and a "Hide my IP" call is relayed through a real coturn (verified to fail with a wrong TURN secret)
- [ ] Manual test matrix on real devices and networks (`docs/NETWORK_TESTING.md`): same Wi-Fi, Wi-Fi ↔ 4G, 4G ↔ 4G, forced relay, UDP-blocked firewall

**Exit criteria / Milestone M1:** an E2E-encrypted call connects across the internet in every network in the test matrix.

#### Phase 5 — Guest Links & Web Guest Client (Weeks 13–14)
- [x] Signed guest links (`/#g=<payload>`, never sent to a server): personal (reusable, replaceable) and one-time (7 days, used up on admission); copy / replace / revoke; stored on the professional's device only
- [x] Guest web page: no cookies, no third-party requests (rendering engine and fonts served locally; checked by the e2e tests)
- [x] Device check: camera/mic preview, clear permission help, voice-only option
- [x] `guest.knock` (repeated while waiting) → **waiting room** → *Admit* / *Decline* / quick messages; admitted guest's page answers automatically
- [x] Guest in-call screen: mute, camera, hang up, safety number, "Secured by Sotto" footer
- [x] Clear error pages: link not valid / tampered, expired, replaced, already used, declined, waiting room full
- [x] End-to-end test (`e2e/guest.mjs`): knock, admit, call, hang up, decline, replaced link, one-time link reuse, tampered link, no names reaching the relay
- [ ] Browser testing on real devices: Chrome, Edge, Firefox, Safari on iPhone/iPad and Mac (automated tests use Chromium only)
- [ ] Speaker test in the device check; "browser not supported" detection beyond the camera/mic check
- [ ] Bundle fallback fonts (e.g. Noto) for names in non-Latin scripts; fallback fonts are now looked up on our own server only

**Exit criteria:** a client on an iPhone or a PC browser joins a call from a link in under 30 seconds with no install.

#### Phase 5B — Auto-Answer for Trusted Callers, open app (≈3 days, right after Phase 5)
An **optional** setting on the *receiving* device: calls from people the user has chosen are answered automatically, so family members (or a colleague on duty) can always get through. Only the device owner can turn it on; a caller can never force it.

- [x] Setting **Auto-answer calls from trusted callers** (off by default, can't be switched on until someone is trusted), stored on the device only; never sent to anyone
- [x] **Trusted callers** list: added only after a call, through a dialog that requires confirming "I compared this safety number with them"; exact key match; strangers, guests and unverified callers always ring normally
- [x] **Rings first** for a chosen delay (0–10 s, default 5 s) so the user can still decline
- [x] Answers as a **voice call with the camera never opened** by default; video allowed per trusted caller
- [x] **"Auto-answered" banner** on both sides (`call.accept` carries `{"auto": true}`); system alert sound where the platform provides one
- [ ] A proper ringtone/chime sound on every platform (web and Linux have no system alert sound) — moved to Phase 7, with desktop notifications
- [x] Persistent reminder on the home screen while auto-answer is on, listing who is trusted
- [x] Never auto-answers while already in a call (busy still applies) or when the trusted list is empty
- [x] Tests: state-machine tests (delay, decline during delay, voice-only, busy), trusted-caller rules and storage; e2e `e2e/autoanswer.mjs`: trusted caller auto-connects voice-only after the delay, decline wins, stranger keeps ringing
- [x] Threat model entry: abuse as a listening device, and the mitigations above
- [x] Works while the app is open (desktop; Android in the foreground). Locked phone / closed app: Phase 12

**Exit criteria:** a verified trusted caller's call connects by itself after the ring delay with a visible and audible indication on both sides; anyone else's call rings normally.

#### Phase 6 — Professional App Essentials (Weeks 15–17)
- [x] Onboarding: create an identity or restore from a backup; name and practice (shown on guest links and the contact link). Upgrading from Phase 5 keeps the identity and moves old settings into the vault
- [x] Encrypted local storage: an encrypted vault (XChaCha20-Poly1305, key in the OS keystore) instead of drift + SQLCipher (reasons in §5.8); clear screens when the keystore or the vault can't be used
- [x] App lock: PIN (Argon2id verifier, growing waits after wrong PINs), auto-lock after leaving the app, *Lock now*; calls still ring while locked
- [ ] Biometric unlock (`local_auth`) — Phase 12, with the other mobile work
- [x] Call history (local only): direction, time, talk time, outcome; call back; add to contacts; private session notes; auto-delete (7/30/90 days, forever, or off)
- [x] Call screens: names, call timer, quality indicator from local statistics (good / fair / poor), draggable self-preview
- [x] Camera, microphone and speaker pickers (Settings and during calls), choices kept on the device; unplugged devices fall back to the default mid-call, plugged-in devices appear automatically
- [x] Android: switch camera; audio output picker (speaker / earpiece / Bluetooth / wired, as reported by the system)
- [ ] Verify device pickers and Android audio routing on real hardware (automated tests use fake devices)
- [x] Encrypted backup export and restore (Argon2id + XChaCha20-Poly1305), native apps; save or copy the file, open or paste it to restore
- [x] Colleagues: signed contact links (`#c=`) with a QR code; add from a link, after a call or from the history; call contacts directly; browser quick-call page for contact links
- [ ] Scan QR codes in the app (`mobile_scanner`) — Phase 12; for now the phone's camera opens the link, or paste it
- [x] Auto-answer: chosen per verified contact; turning it on, changing the ring time and choosing people all require the app lock
- [x] Tests: vault, backup, app lock, contacts and contact links, history and recorder, devices and quality, app lifecycle (onboarding, restart, upgrade, backup/restore, erase, no keystore); e2e `phase6.mjs` (onboarding, contact link, call from contacts, timer and quality, history and notes, lock with a call on top, device picker, nothing readable at the relay); existing e2e tests updated

**Exit criteria / Milestone M2 — MVP:** a professional installs the desktop app, sends a guest link and holds a private, encrypted call with a client who is using only a browser.

---

### Stage C — Pilot (Weeks 18–23)

#### Phase 7 — Self-Host Package & Hosted Beta (Weeks 18–19)
- [x] `docker-compose.yml` for relay + coturn + web app with read-only filesystems, no capabilities, logs capped or discarded
- [x] `infra/install.sh`: checks the domain points here (refuses Cloudflare's proxy, detects NAT), installs Docker, adds swap on small servers, opens ufw/firewalld ports, writes a private `.env` with a random TURN secret, builds and starts, waits for HTTPS, enables TURN over TLS, schedules coturn's certificate reload; `update`, `status`, `uninstall [--purge]`, `--dry-run`. Tested in CI with stubbed Docker, DNS, firewall and cron (`infra/test/install_test.sh`) and shellcheck
- [x] App setting to point at a custom server (Settings → Server): checks that a Sotto relay answers before switching, warns that earlier links stop working, PIN if the app lock is on; kept in the vault and in backups. The browser always uses the server it was loaded from
- [x] `docs/SELF_HOSTING.md`
- [x] Our hosted beta environment (relay + coturn + guest page) in one region — deployed on `call.sottocall.com` (earlier `sotto.izhaanintellect.fun`, still served) with DNS only, Nginx reverse proxy, and coturn STUN/TURNS (ports 3478/5349)
- [x] Desktop tray mode: closing the window keeps Sotto running (tray icon with *Open* / *Quit*); only where a tray host exists (checked on Linux), otherwise the window closes normally
- [x] Native notifications (Windows, Linux) for knocking guests and incoming calls while Sotto is in the background; names hidden unless the user chooses, never while locked
- [x] Ringtone, ringback tone and chimes (knock, auto-answered), synthesized by `tools/sounds/generate.py` (original, CC0) and bundled; on/off in Settings; playback errors never affect calls
- [x] A dialog left open no longer covers an incoming call or the lock screen
- [ ] Single-instance desktop app (opening Sotto again shows the running window) — Phase 8
- [ ] Verify tray and notifications on real Windows and Linux desktops (tested here on a virtual display without a tray host)

**Exit criteria:** a non-expert can self-host on a fresh VPS in under 15 minutes by following the docs.

#### Phase 8 — Pilot Programme & Reliability (Weeks 20–23)
- [ ] Onboard **3–5 pilot organisations** from the waitlist (free in exchange for weekly feedback and a testimonial)
- [ ] Weekly 20-minute feedback calls; a prioritised list of requests
- [x] ICE restart on network change; reconnect mid-call; "Reconnecting…" UI (PROTOCOL §5.5): both sides show it, the caller restarts ICE (numbered offers, `call.restart` from the callee), repeats every 8 s, gives up after 45 s; the relay connection is checked with `ping` so a socket left dead by a network change is replaced within seconds (§5.2). Tested with a fake clock and end to end (the TURN server frozen mid-call, then resumed)
- [ ] Verify Wi-Fi ↔ mobile data switching on real Android phones (the end-to-end test simulates the network loss on one machine)
- [x] Desktop: *Start Sotto when I log in* (Settings → Desktop): an XDG autostart entry on Linux, the user's `Run` registry value on Windows; starts with `--hidden`, straight to the tray (the window may flash briefly first)
- [x] Android: *Ring even when Sotto is closed* (moved up from Phase 12, see there)
- [ ] Bandwidth adaptation; audio-only fallback
- [x] Local diagnostics: *Settings → Help → Diagnostic report* shows the whole report (version, platform, server host, relay and TURN state, call state, background permissions, recent relay and call events from an in-memory log) and copies it; nothing is sent, and it holds no names, contacts, call partners, links, IDs or keys (tested)
- [ ] Opt-in crash reports
- [x] Update notice: the native apps ask GitHub Releases once a day (switch in *Settings → Updates*; GitHub sees the IP address only) and show *"Sotto x.y.z is available"* with *Download* (opens the release page) and *Not now*; nothing is installed by the app. Builds for another repository set `SOTTO_UPDATE_URL` (empty turns it off); a test keeps `lib/core/version.dart` equal to `pubspec.yaml`
- [x] Dependency and secret scanning in CI: a *Security* job runs gitleaks over the whole git history and osv-scanner over every lockfile (npm, pub), with pinned, checksum-verified binaries; Dependabot opens weekly update pull requests (npm, pub, GitHub Actions, Docker)
- [ ] Security hardening: log audit, read-only servers verified
- [x] Privacy policy and terms (`/privacy.html`, `/terms.html`, linked from *Settings → Help* and the guest page) that plainly list what the server processes, briefly and in memory (section 5.10); they name the operator from `install.sh --operator/--contact` (Caddy templates); the printed Nginx configuration turns access logs off
- [ ] Have the privacy policy and terms checked by a lawyer for each country we launch in
- [x] Windows installer (Inno Setup) and Linux AppImage / `.deb`

**Exit criteria / Milestone M3 — Pilot success:** 3+ organisations use it every week; call setup success > 95%; at least 2 pilots say they'd pay.

---

### Stage D — Paid Launch (Weeks 24–36)

#### Phase 9 — Licensing & Billing (Weeks 24–25)
- [ ] Merchant-of-record payment provider (Paddle / Lemon Squeezy, or Stripe)
- [ ] Licence token generation after payment (signed with our licence key)
- [ ] App: enter or open licence; show plan and expiry; renewal reminders
- [ ] Relay: offline licence verification; feature and quota checks in RAM
- [ ] Pricing page on the website
- [ ] Convert pilots to paid plans (with a pilot discount)

**Milestone M4 — First revenue (~month 6).**

#### Phase 10 — On-Device Call Recording with Consent (Weeks 26–29)
Recording happens **only on the professional's device**. Media stays peer-to-peer and end-to-end encrypted, and the server never sees or stores call content. For guests in a browser, the consent prompt and recording indicator are shown on the guest page.

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

**Exit criteria:** both sides of a call are recorded into a single playable file on desktop and Android, and the guest always sees the recording indicator and consent prompt.

#### Phase 11 — Scheduling, Waiting Room, Branding & Screen Sharing (Weeks 30–31)
- [ ] Scheduled links with a validity window; `.ics` calendar file export; copyable invitation text
- [ ] Upcoming sessions list (local only)
- [ ] Waiting room: knock sound, "knocking since" timer, quick replies ("5 minutes", "running late")
- [ ] Busy handling: a guest knocking during another call sees a waiting message
- [ ] Branding (Business plan): practice name, logo and colour on the guest page
- [ ] Screen sharing from the desktop app (screen or window picker), for going through documents with a client

#### Phase 12 — Android Background & Incoming Calls (Weeks 32–34)
Done early (Phase 8), without a push service:
- [x] **Ring even when Sotto is closed** (on by default): a foreground service (`specialUse`, quiet permanent notification) keeps the app's one Flutter engine and its relay connection alive after the window closes; it starts again after a reboot or an app update. Settings shows what Android still has to allow (notifications, battery optimization, full-screen calls) with a button for each
- [x] Native incoming-call notification while the app is in the background: full screen on a locked phone, *Answer* (opens the app into the call) and *Decline*; the system plays the ringtone, so silent mode and Do Not Disturb apply; a knock notification for waiting guests; names only if chosen and never while Sotto is locked; no auto-answer while in the background (Android lets only a visible app use the microphone)
- [ ] Verify on real phones (Pixel, Samsung, Xiaomi) with Doze and battery savers; some makers stop background services anyway
- [x] A call continues while the user switches to another app: a microphone foreground service (`CallService`) runs from the start of an outgoing call or from answering, with an *Ongoing call* notification (timer once connected, *Hang up*, tap to return); names as for ringing. The camera still pauses in the background

Push wake-up, as a battery-saving alternative:
- [ ] Obtain FCM token; **UnifiedPush** as an alternative
- [ ] Share push tokens only with contacts via E2E `contact.update`
- [ ] For guest links: the guest page includes the professional's wake token (stored in the signed link payload, only if the professional enables "Wake my phone for guests")
- [ ] Relay sends a **content-free** high-priority push and keeps nothing
- [ ] Native incoming-call / knocking UI (`flutter_callkit_incoming`), lock screen and full-screen intent
- [x] Foreground service type `camera` too during video calls, so video continues in the background
- [ ] Permissions: `USE_FULL_SCREEN_INTENT`, `FOREGROUND_SERVICE_PHONE_CALL`, `FOREGROUND_SERVICE_MICROPHONE`, `FOREGROUND_SERVICE_CAMERA`
- [ ] Test on Samsung, Xiaomi and Pixel with Doze and battery savers
- [ ] **Auto-answer on a locked phone / closed app:** after the wake-up push, start the call foreground service (types `phoneCall|microphone`) before opening the microphone, ring for the chosen delay, then answer; persistent notification "Auto-answer is on" while enabled

**Exit criteria:** a knocking guest or calling colleague rings a locked Android phone with the app killed, within about 3 seconds, and the server stores no token.

#### Phase 13 — Public Launch (Weeks 35–36)
- [ ] **External security review** of the crypto and relay
- [ ] Play Store listing (data-safety form, foreground-service and full-screen-intent declarations)
- [ ] Windows code-signing certificate
- [ ] Production hosting in at least two regions; monitoring with aggregate counters only
- [ ] Load test the relay (k6 WebSocket clients)
- [ ] Launch content for the target group: guides, case studies from pilots, association partnerships
- [ ] Support channel and documentation site

**Milestone M5 — Public launch (~month 9).**

---

### Stage E — Grow (Months 9–12+)

Prioritise using paying customers' requests. Likely candidates:

- [ ] **iOS app** for professionals (CallKit + VoIP push) and **macOS** build
- [ ] **Team features** (Business plan): an admin creates a signed team roster and server settings and shares them E2E with members; shared branding; colleagues directory stored only on members' devices
- [ ] **Linked devices:** use one identity on phone and PC; contacts and history sync device-to-device, end to end encrypted
- [ ] **Small group calls (mesh, up to 4):** for example family therapy, or a lawyer with two clients
- [ ] **E2E-encrypted chat and file sharing during calls** (send a document to a client)
- [ ] **Compliance pack:** GDPR data-processing documentation and a HIPAA-readiness assessment (with legal advice) for the chosen market
- [ ] **Second target group**, chosen with the same validation steps as Stage A

> Larger groups (5+) need an SFU media server plus SFrame end-to-end encryption so the server still can't see media. That is a separate project with its own privacy review.

### Summary timeline

| Weeks | Phase | Milestone |
|---|---|---|
| 1–4 | A. Customer research & waitlist | Go / no-go |
| 5 | 0. Foundations | |
| 6–7 | 1. WebRTC PoC | First app ↔ browser call |
| 8–9 | 2. Identity & crypto core | |
| 10–11 | 3. Stateless relay | |
| 12 | 4. coturn | **M1: E2E call over the internet** |
| 13–14 | 5. Guest links & web client | |
| +3 days | 5B. Auto-answer for trusted callers (open app) | |
| 15–17 | 6. Professional app essentials | **M2: MVP** |
| 18–19 | 7. Self-host package & hosted beta | |
| 20–23 | 8. Pilot & reliability | **M3: pilot success** |
| 24–25 | 9. Licensing & billing | **M4: first revenue (~month 6)** |
| 26–29 | 10. Consent recording | |
| 30–31 | 11. Scheduling, waiting room, branding, screen sharing | |
| 32–34 | 12. Android background calls | |
| 35–36 | 13. Public launch | **M5: public launch (~month 9)** |
| Months 9–12+ | E. Grow | iOS, teams, group calls, second group |

---

## 7. Infrastructure & Cost Estimate

There is no user database to run or back up, so infrastructure is simple and cheap.

| Stage | Setup | Approx. monthly cost |
|---|---|---|
| Development | Relay locally; one small VPS for coturn | $5–10 |
| Pilot | 1 small VPS (relay + guest page), 1 VPS (coturn) | $10–30 |
| Launch | 2+ relay instances, 2+ coturn nodes in different regions, static guest page | $60–150 (TURN bandwidth driven) |
| Business tools | Payment provider fees (~5% for merchant of record), website, newsletter tool, code-signing certificate | ~5% of revenue + $20–40 |

**TURN bandwidth is the main variable cost.** About 15–20% of calls normally need relaying; guests on corporate or hotel networks may need it more often. A relayed 720p call uses roughly 1–2 GB per hour, so choose hosts with generous included traffic, such as Hetzner or OVH. Price the Pro plan so that a heavy user's TURN traffic stays well under their subscription.

---

## 8. Testing Strategy

- **Crypto unit tests:** known-answer vectors, tampering, replay, wrong-key and truncated ciphertexts, on native **and web**
- **Relay tests:** routing, queue expiry, rate limits, licence verification; an automated **"no persistence" test** on a read-only filesystem
- **State machine tests:** busy, timeout, cancel, glare, guest knock/admit/decline
- **Widget tests:** onboarding, guest join flow, waiting room, call screens
- **Browser matrix for guests:** Chrome, Edge, Firefox (Windows/Mac/Android) and Safari (iPhone/iPad/Mac), in every release
- **Manual device matrix:**
  - Android 9, 11, 13, 14, 15+ on Samsung, Xiaomi and Pixel
  - Windows 10/11; Ubuntu 22.04/24.04
  - Networks: same LAN, Wi-Fi ↔ 4G, forced relay, TLS-only firewall, corporate proxy, hotel Wi-Fi
  - Scenarios: app killed, screen locked, network switch mid-call, Bluetooth headset, backup/restore on a new device, expired / revoked links
- **Self-host test:** a fresh VPS install following only the docs, timed
- **Privacy test:** inspect relay traffic and memory to confirm no names, SDP or plaintext appear; confirm the guest page sets no cookies and loads no third-party resources
- **Soak test:** a 1-hour call for memory and stability
- **Pilot feedback:** treated as a test input, reviewed weekly

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Nobody in the chosen group will pay | High | Stage A validation before building; switch group early if sign-ups are weak |
| Free alternatives (Jitsi, Meet) are "good enough" for many | High | Focus on the professional–client workflow (guest links, waiting room, consent recording, zero storage) and on groups with real confidentiality duties |
| Guest experience fails in some browsers (especially Safari on iPhone) | High | Browser matrix in every release; device check page; clear help messages |
| Compliance expectations (HIPAA, GDPR) for health or legal customers | High | Zero storage reduces exposure; get legal advice before marketing to regulated groups; don't claim certifications you don't have |
| Professionals lose their device and their identity | High | Prominent backup reminders; encrypted backup file; linked devices later |
| Mistakes in home-made crypto code | High | Only libsodium high-level APIs; test vectors; external security review before public launch |
| Calls fail behind strict NAT/firewalls | High | coturn with TLS on 443; forced-relay testing; corporate proxy testing |
| One developer can't keep up with support and features | Medium | Strict prioritisation from paying customers; good self-service docs; consider a co-founder after pilot success |
| Licence sharing or abuse | Low | Concurrent-connection limits per licence ID in RAM; accept some leakage rather than tracking users |
| Short-lived metadata (who connects to whom, IPs) visible to the relay in RAM | Medium | No logging; read-only servers; documented honestly; self-hosting option; "Hide my IP" |
| Recording without consent (legal exposure) | High | Consent prompt on by default, indicator for both sides, in-app notice |
| Desktop recording needs native code | Medium | Check `flutter_webrtc` support first; otherwise an FFmpeg-based plugin |
| Play Store policy rejection (foreground service / full-screen intent) | Medium | Declare service types correctly; provide a demo video for the review |

---

## 10. Definition of Done for the Public Launch (M5)

**Product**
- A professional on Windows, Linux or Android sends a guest link; a client joins from any major browser with no install or account
- Waiting room, scheduled and one-time links, revocation
- End-to-end encrypted 1:1 audio and video, with safety-number verification between colleagues
- Consent-based on-device recording (voice only or video + voice, both sides' voices)
- Incoming calls and knocking guests ring an Android phone even when the app is closed
- Call setup success above 95% across the network test matrix

**Privacy**
- No accounts and no personal identifiers; the server stores nothing (verified by tests and read-only deployment)
- Guest page with no cookies and no third-party scripts
- Published source code, threat model and an honest privacy policy
- External security review completed and findings fixed

**Business**
- Hosted Pro plan and Business self-hosted licence on sale
- One-command self-hosting with documentation
- Paying customers from the pilot, with at least 2 published testimonials or case studies
