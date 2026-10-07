# Calling App — Feature List

The features planned for the app. Phase numbers refer to [ROADMAP.md](ROADMAP.md). Items marked **(later)** come after v1.0.

## 1. Calling

| Feature | Description | Phase |
|---|---|---|
| 1:1 voice calls | Audio call between two users over the internet | 1–3 |
| 1:1 video calls | Live camera video in both directions, with your own camera in a small draggable window | 1–3 |
| Cross-platform calls | Any combination: Android ↔ Windows, Android ↔ Linux, Windows ↔ Linux, phone ↔ phone | 1 |
| Voice → video upgrade | Turn on the camera during a voice call without hanging up | 5 |
| Ringing and call states | Clear "Calling…", "Ringing…", "Connecting…", "Connected" and "Reconnecting…" screens | 2 |
| Accept / Decline / Cancel | The person being called can answer or decline; the caller can cancel before it's answered | 2 |
| Busy detection | If the person is already on a call, the caller hears "busy" instead of ringing forever | 2 |
| Missed calls | Unanswered calls stop after 45 seconds and are saved as missed | 2 |
| Ring on all devices | A user signed in on both phone and PC hears it ring on both; answering on one stops it on the other | 2 |

## 2. In-call controls

| Feature | Description | Phase |
|---|---|---|
| Mute / unmute microphone | Stop sending your voice | 1 |
| Camera on / off | Stop sending video while staying on the call | 1 |
| Switch camera | Front ↔ back camera on Android | 5 |
| Audio output | Choose speaker, earpiece, Bluetooth headset or wired headphones (Android) | 5 |
| Device selection (PC) | Choose webcam, microphone and speakers; newly plugged-in devices are detected automatically | 5 |
| Screen sharing (PC) | Share the whole screen or a single window | 7 |
| Call timer | Shows how long the call has lasted | 5 |
| Call quality indicator | Signal-bars style icon based on lag, lost data and connection speed | 5 |
| Picture-in-Picture (Android) | Video keeps playing in a floating window while using other apps | 5 |
| Proximity screen-off (Android) | Screen turns off when the phone is held to the ear on voice calls | 5 |
| Keyboard shortcuts (PC) | For example, a key to mute and a key to hang up | 7 |

## 3. Receiving calls

| Feature | Description | Phase |
|---|---|---|
| Incoming calls when the app is closed (Android) | A push notification wakes the phone and shows a full-screen incoming-call screen, even when the phone is locked | 6 |
| Native-style call screen (Android) | Looks and behaves like a normal phone call: lock-screen answer, ringtone, vibration | 6 |
| Ongoing-call notification (Android) | Keeps the call alive in the background; return to it or hang up from the notification bar | 6 |
| Phone call interruption (Android) | Handles a normal phone call arriving during a VoIP call | 6 |
| Tray mode (PC) | Closing the window minimises the app to the system tray so it can still receive calls | 7 |
| Desktop notifications (PC) | Popup and a focused incoming-call window when someone calls | 7 |
| Start with the computer (PC) | Optional setting to launch at login | 7 |

## 4. Accounts and contacts

| Feature | Description | Phase |
|---|---|---|
| Sign up / log in | Email and password, or phone number with a one-time code | 4 |
| Stay signed in | Login stored securely and renewed automatically | 4 |
| Contacts | Search for users, then add or remove them | 4 |
| Online status | See which contacts are online right now | 4 |
| Call history | Incoming, outgoing and missed calls with date and duration; tap an entry to call back | 4 |
| Profile | Name and avatar | 4 |
| Block and report | Stop unwanted users from calling | 9 |
| Contacts-only calling | Optional setting so only contacts can call you | 9 |

## 5. Connection and reliability

These run automatically; users never have to configure them.

| Feature | Description | Phase |
|---|---|---|
| Works on any network | Direct device-to-device when possible; otherwise relayed through the app's own TURN server (strict home routers, mobile networks, office firewalls) | 3 |
| Network switching | Moving from Wi-Fi to mobile data reconnects the call instead of dropping it | 8 |
| Automatic reconnect | Short internet drops show "Reconnecting…" and recover; gives up only after 30 seconds | 8 |
| Adaptive quality | Video quality drops automatically on a weak connection, falling back to voice only if needed | 8 |
| Crash reporting and call statistics | Helps find and fix problems after release; no audio or video is recorded | 8 |

## 6. Security and privacy

| Feature | Description | Phase |
|---|---|---|
| Encrypted calls | All audio and video is encrypted by WebRTC itself (DTLS-SRTP); for 1:1 calls even the relay server can't listen in | Built in |
| Encrypted connections | All traffic to the servers uses TLS (`https`, `wss`, `turns`) | 9 |
| Short-lived TURN passwords | No permanent password is stored in the app, so the relay server can't be freely abused | 3 |
| Rate limiting | Protection against spam calls and password guessing | 9 |

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
| Small group calls (up to 4) | Grid of videos, with the person currently speaking highlighted (Phase 10) |
| In-call chat / file sharing | Send messages or files during a call over the same connection |
| Larger group calls (5+) | Needs a media server (an SFU such as mediasoup or LiveKit); a separate project |
| macOS / iOS apps | Mostly the same code; iOS adds Apple's own call-screen integration (CallKit and VoIP push) |

## v1.0 scope

v1.0 includes groups 1–6: reliable 1:1 voice and video calls between Android and PC, with contacts, history, incoming calls that work even when the app is closed, and calls that survive network problems. Call recording, group calls and chat come after v1.0.
