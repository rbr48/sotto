# Sotto — Feature List

**Sotto: private calls for professionals and their clients. No accounts, no data stored, on our servers or yours.**

The features planned for the product. Phase numbers refer to [ROADMAP.md](ROADMAP.md). The **Plan** column shows which pricing plan includes the feature: **Free**, **Pro** (hosted) or **Business** (self-hosted licence). Items marked **(later)** come after the public launch.

## 1. Guest links: clients join from a browser

| Feature | Description | Phase | Plan |
|---|---|---|---|
| Join from any browser | Clients click a link and join in Chrome, Edge, Firefox or Safari (including iPhone). No app, no account, no sign-up | 5 | Free |
| Personal room link | A reusable link, like your own permanent meeting room; rotate it any time | 5 | Free |
| One-time links | A link that works for a single call and then expires | 5 | Free |
| Revoke links | Cancel any link instantly from the app | 5 | Free |
| Device check | Before joining, the client tests camera, microphone and speakers, with clear help if the browser blocks them | 5 | Free |
| Waiting room | Clients "knock"; you see their name and choose *Admit* or *Decline* | 5 | Free |
| Quick messages | Reply to a waiting client: "I'll be with you in 5 minutes", "Running late" | 11 | Pro |
| Scheduled links | Links valid only for a booked time slot, with a calendar file (`.ics`) to send to the client | 11 | Pro |
| Upcoming sessions | A list of scheduled calls, stored only on your device | 11 | Pro |
| Branding | Your practice name, logo and colours on the client's join page | 11 | Business |
| Private join page | No cookies, no trackers and no third-party scripts on the client's page | 5 | Free |

## 2. Privacy

| Feature | Description | Phase | Plan |
|---|---|---|---|
| No accounts | No email, phone number or password. Your identity is a cryptographic key created on your device; clients get a temporary key that disappears when they close the tab | 2 | Free |
| Zero server storage | The server has no user database and saves nothing. It only connects calls, in memory | 3 | Free |
| End-to-end encrypted calls | Audio and video are encrypted between the two devices; the server and TURN relay can't decrypt them | Built in | Free |
| End-to-end encrypted signaling | Call setup messages are encrypted and signed, so the server can't read or fake them | 2–3 | Free |
| Interception protection | Call encryption keys are authenticated end to end, so even a hacked server can't secretly join a call | 2–3 | Free |
| Safety numbers | Compare a short code with a colleague once to confirm nobody is in the middle | 2, 6 | Free |
| No directory | Nobody can search for you; people reach you only through links or QR codes you share | 5–6 | Free |
| All data on your device | Contacts, call history, session notes, settings and recordings are stored only on your device, encrypted | 6 | Free |
| App lock | Protect the app with a PIN or fingerprint | 6 | Free |
| Hide my IP address | Route calls through the relay so the other person never sees your IP address | 4 | Free |
| No tracking or analytics | Diagnostics and crash reports are opt-in and exported by you | 8 | Free |
| Billing kept separate | Payments are handled by the payment provider; our servers never hold billing details. Your licence is checked by signature, offline | 9 | Pro / Business |
| Open source | App and server code are published so anyone can check that nothing is stored | 13 | Free |

## 3. Calling

| Feature | Description | Phase | Plan |
|---|---|---|---|
| 1:1 voice and video calls | High-quality encrypted calls with a client or colleague | 1–4 | Free |
| Calls with colleagues | Add colleagues by QR code or invite link and call them directly app-to-app | 6 | Free |
| Cross-platform | Professional app on Windows, Linux and Android; clients on any modern browser | 1, 5 | Free |
| Ringing and call states | Clear "Calling…", "Ringing…", "Connecting…", "Connected" and "Reconnecting…" screens | 3 | Free |
| Busy handling | Colleagues get "busy"; clients who knock during another call see "please wait" | 3, 11 | Free |
| Works on any network | Direct device-to-device when possible; otherwise relayed through TURN (strict routers, mobile networks, office and hotel firewalls) | 4 | Free (self-hosted) / Pro (hosted TURN) |

## 4. In-call controls

| Feature | Description | Phase | Plan |
|---|---|---|---|
| Mute / camera on-off | For both the professional and the client | 1, 5 | Free |
| Device selection (PC) | Choose webcam, microphone and speakers; newly plugged-in devices are detected automatically | 6 | Free |
| Switch camera / audio output (Android) | Front ↔ back camera; speaker, earpiece, Bluetooth or wired headphones | 6 | Free |
| Call timer | Shows how long the session has lasted | 6 | Free |
| Call quality indicator | Signal-bars style icon, calculated on your device only | 6 | Free |
| Screen sharing (PC) | Share the whole screen or a window, for example to go through a document with a client | 11 | Pro |

## 5. Professional tools

| Feature | Description | Phase | Plan |
|---|---|---|---|
| Call history | Past sessions with date and duration, stored only on your device, with optional auto-delete | 6 | Free |
| Session notes | Private notes attached to a call, encrypted on your device | 6 | Free |
| Consent-based recording | Record both voices of a session on your own device, with a consent prompt and a "● Recording" indicator shown to the client | 10 | Pro |
| Recording mode choice | **Voice only** (`.m4a`, smaller) or **Video + voice** (`.mp4`); a default can be set in Settings (*Ask every time* / *Voice only* / *Video + voice*) | 10 | Pro |
| Recordings library | List, play, share, rename and delete; encrypted storage; low-space warnings and auto-delete | 10 | Pro |
| Encrypted backup and restore | A password-protected backup of your identity, contacts and settings, saved wherever you choose | 6 | Free |

## 6. Being reachable

| Feature | Description | Phase | Plan |
|---|---|---|---|
| Tray mode (PC) | The app stays in the system tray so it can still receive knocking clients and calls | 7 | Free |
| Desktop notifications | A popup and sound when a client knocks or a colleague calls | 7 | Free |
| Auto-answer for trusted callers | Optional: calls from people you choose (verified contacts only) connect by themselves after a short ring you can still decline. Starts as voice only, with a sound and "Auto-answered" banner on both sides. Only you can turn it on, on your own device | 5B (open app), 12 (locked phone) | Free |
| Android wake-up | A content-free push wakes your phone with a full-screen call / knock screen even when the app is closed. The server never stores your push token | 12 | Free |
| Google-free option | UnifiedPush support for receiving calls without Google services | 12 | Free |
| Ongoing-call notification (Android) | Keeps the call alive in the background | 12 | Free |

## 7. Reliability

| Feature | Description | Phase | Plan |
|---|---|---|---|
| Network switching | Moving from Wi-Fi to mobile data reconnects the call instead of dropping it | 8 | Free |
| Automatic reconnect | Short internet drops show "Reconnecting…" and recover | 8 | Free |
| Adaptive quality | Video quality drops automatically on a weak connection, falling back to voice only if needed | 8 | Free |
| Local diagnostics | Export an anonymised report to share with support when something goes wrong | 8 | Free |

## 8. Deployment options

| Feature | Description | Phase | Plan |
|---|---|---|---|
| Hosted service | Use our relay and TURN servers in several regions; nothing to install except the app | 7, 13 | Pro |
| One-command self-hosting | Run your own relay, TURN server and client join page with a single install script and Docker | 7 | Free (community) / Business (with support) |
| Custom domain | Client links use your own domain, for example `call.yourpractice.com` | 7 | Free (self-hosted) |
| Signed updates | `install.sh update` pulls signed images | 7 | Free |

## 9. Later (after the public launch)

| Feature | Description |
|---|---|
| iOS and macOS apps | Professional app for iPhone, iPad and Mac (clients can already join from a browser) |
| Team features | An admin shares a signed team roster, server settings and branding with colleagues end to end encrypted; nothing stored on the server (Business) |
| Linked devices | Use the same identity on phone and PC; history and contacts sync device-to-device, end to end encrypted |
| Small group calls (up to 4) | For example family therapy, or a lawyer with two clients |
| In-call chat and file sharing | Send a document to a client during a call, end to end encrypted |
| Compliance pack | GDPR documentation and a HIPAA-readiness assessment for the chosen market |
| Larger group calls (5+) | Needs a media server plus extra end-to-end encryption (SFrame); a separate project |

## What the server can still see

The server keeps nothing, but while a call is being set up it briefly sees, in memory only, which keys are connecting to each other and their IP addresses. Hiding even that would need Tor-style routing, which is too slow for live calls. Organisations that want to remove even this can **self-host**, so the only server involved is their own.

## Public launch scope (Milestone M5, ~month 9)

Sections 1–8: guest browser links with a waiting room and scheduling, end-to-end encrypted 1:1 calls with no accounts and no server storage, consent-based recording, a desktop and Android app for professionals, Android wake-up for incoming calls, and both hosted and self-hosted deployment. iOS, teams, group calls and chat come after launch.
