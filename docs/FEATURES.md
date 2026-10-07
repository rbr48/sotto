# Calling App — Feature List

The features planned for the privacy-first calling app. Phase numbers refer to [ROADMAP.md](ROADMAP.md). Items marked **(later)** come after v1.0.

## 1. Privacy (the foundation)

| Feature | Description | Phase |
|---|---|---|
| No accounts | No email, phone number, username or password. Your identity is a cryptographic key created on your device | 2 |
| Zero server storage | The server has no database and saves nothing. It only connects calls, in memory | 3 |
| End-to-end encrypted calls | Audio and video are encrypted between the two devices; the server and TURN relay can't decrypt them | Built in |
| End-to-end encrypted signaling | Call setup messages are encrypted and signed, so the server can't read or fake them | 2–3 |
| Interception protection | Call encryption keys are authenticated end to end, so even a hacked server can't secretly join a call | 2–3 |
| Safety numbers | Compare a short code with a contact once to confirm nobody is in the middle; the contact is then marked "verified" | 5 |
| No directory | Nobody can search for you. People can add you only if you give them your QR code or invite link | 5 |
| All data on your device | Contacts, call history, settings and recordings are stored only on your device, encrypted | 5 |
| Content-free notifications | Wake-up pushes contain no names or caller details, only "wake up" | 7 |
| Google-free option | UnifiedPush support for receiving calls without Google services | 7 |
| Hide my IP address | Optional: route calls through the relay so the other person never sees your IP address | 4 |
| No tracking or analytics | No usage tracking; diagnostics and crash reports are opt-in and exported by you | 9 |
| App lock | Protect the app with a PIN or fingerprint | 5 |
| Open source server | The server code is published so anyone can check that it stores nothing | 10 |

## 2. Calling

| Feature | Description | Phase |
|---|---|---|
| 1:1 voice calls | Audio call between two contacts over the internet | 1–4 |
| 1:1 video calls | Live camera video in both directions, with your own camera in a small draggable window | 1–4 |
| Cross-platform calls | Any combination: Android ↔ Windows, Android ↔ Linux, Windows ↔ Linux, phone ↔ phone | 1 |
| Voice → video upgrade | Turn on the camera during a voice call without hanging up | 6 |
| Ringing and call states | Clear "Calling…", "Ringing…", "Connecting…", "Connected" and "Reconnecting…" screens | 3 |
| Accept / Decline / Cancel | The person being called can answer or decline; the caller can cancel before it's answered | 3 |
| Busy detection | If the person is already on a call, their app replies "busy" automatically | 3 |
| Missed calls | Unanswered calls stop after 45 seconds and are saved as missed, on the device only | 3 |
| Contacts-only calls | Calls from anyone who isn't your contact are ignored automatically | 3 |

## 3. In-call controls

| Feature | Description | Phase |
|---|---|---|
| Mute / unmute microphone | Stop sending your voice | 1 |
| Camera on / off | Stop sending video while staying on the call | 1 |
| Switch camera | Front ↔ back camera on Android | 6 |
| Audio output | Choose speaker, earpiece, Bluetooth headset or wired headphones (Android) | 6 |
| Device selection (PC) | Choose webcam, microphone and speakers; newly plugged-in devices are detected automatically | 6 |
| Screen sharing (PC) | Share the whole screen or a single window | 8 |
| Call timer | Shows how long the call has lasted | 6 |
| Call quality indicator | Signal-bars style icon, calculated on your device only | 6 |
| Picture-in-Picture (Android) | Video keeps playing in a floating window while using other apps | 6 |
| Proximity screen-off (Android) | Screen turns off when the phone is held to the ear on voice calls | 6 |
| Keyboard shortcuts (PC) | For example, a key to mute and a key to hang up | 8 |

## 4. Receiving calls

| Feature | Description | Phase |
|---|---|---|
| Incoming calls when the app is closed (Android) | A content-free push wakes the phone and shows a full-screen incoming-call screen, even when locked. The server never stores your push token; only your contacts have it | 7 |
| Native-style call screen (Android) | Looks and behaves like a normal phone call: lock-screen answer, ringtone, vibration | 7 |
| Ongoing-call notification (Android) | Keeps the call alive in the background; return to it or hang up from the notification bar | 7 |
| Phone call interruption (Android) | Handles a normal phone call arriving during a VoIP call | 7 |
| Tray mode (PC) | Closing the window minimises the app to the system tray so it can still receive calls | 8 |
| Desktop notifications (PC) | Popup and a focused incoming-call window when someone calls | 8 |
| Start with the computer (PC) | Optional setting to launch at login | 8 |

## 5. Identity and contacts

| Feature | Description | Phase |
|---|---|---|
| Instant setup | Open the app, pick a display name, done. No sign-up form | 5 |
| Profile | Display name and avatar, shared only with your contacts, encrypted | 5 |
| Add contacts by QR code | Scan each other's QR code in person | 5 |
| Add contacts by invite link | Send a link through any channel; it can be single-use or expiring, and revoked | 5 |
| Contact requests | You approve who becomes a contact | 5 |
| Contact list | Rename, delete and block contacts, stored only on your device | 5 |
| Call history | Incoming, outgoing and missed calls, on your device only, with optional auto-delete | 5 |
| Encrypted backup and restore | Save a password-protected backup file of your identity and contacts wherever you choose; restore it on a new device | 5 |

**Removed by design:** there is no online/offline status, because it would let the server track who is online and who their contacts are. You find out whether someone is reachable when you call them.

## 6. Connection and reliability

These run automatically; users never have to configure them.

| Feature | Description | Phase |
|---|---|---|
| Works on any network | Direct device-to-device when possible; otherwise relayed through the app's own TURN server (strict home routers, mobile networks, office firewalls) | 4 |
| Network switching | Moving from Wi-Fi to mobile data reconnects the call instead of dropping it | 9 |
| Automatic reconnect | Short internet drops show "Reconnecting…" and recover; gives up only after 30 seconds | 9 |
| Adaptive quality | Video quality drops automatically on a weak connection, falling back to voice only if needed | 9 |
| Local diagnostics | Call statistics stay on your device; you can export an anonymised report to share with support | 9 |

## 7. Call recording (later — Phase 12)

Recording happens **on the device**. Calls stay end-to-end encrypted and nothing is uploaded to the server.

| Feature | Description |
|---|---|
| Record calls | Record both sides' voices of a call into one file |
| Recording mode choice | In a video call, choose **Voice only** (`.m4a`, smaller file) or **Video + voice** (`.mp4`). Voice calls always record voice only |
| Default mode setting | Settings → Recording: *Ask every time* / *Voice only* / *Video + voice* |
| Recording indicator | A "● Recording (voice)" or "● Recording (video)" badge is shown to **both** people for as long as the recording runs |
| Consent prompt | Optionally, the other person must accept before recording starts (on by default) |
| Recordings library | List, play, share, rename and delete recordings in the app |
| Private storage | Recordings are kept in the app's private storage, encrypted |
| Storage management | Low-space warning, optional maximum length and auto-delete after N days |
| Platforms | Android and Windows/Linux |

## 8. After v1.0 (later)

| Feature | Description |
|---|---|
| Linked devices | Use the same identity on your phone and PC by scanning a QR code; both ring, and contacts sync device-to-device, end to end encrypted (Phase 13) |
| Small group calls (up to 4) | Each pair of people is connected and encrypted directly, with the person speaking highlighted (Phase 14) |
| In-call chat / file sharing | End-to-end encrypted messages and files during a call, sent device-to-device |
| Larger group calls (5+) | Needs a media server plus extra end-to-end encryption (SFrame) so the server still can't see the video; a separate project |
| macOS / iOS apps | Mostly the same code; iOS adds Apple's own call-screen integration (CallKit and VoIP push) |

## What the server can still see

The server keeps nothing, but while a call is being set up it briefly sees, in memory only, which device keys are connecting to each other and their IP addresses. Hiding even that would need Tor-style routing, which is too slow for live calls. The "Hide my IP address" option keeps your IP address hidden from the other person.

## v1.0 scope

v1.0 includes groups 1–6: private, end-to-end encrypted 1:1 voice and video calls between Android and PC, with no accounts and no server storage, contacts by QR code or invite link, encrypted backup, incoming calls that work even when the app is closed, and calls that survive network problems. Call recording, linked devices, group calls and chat come after v1.0.
