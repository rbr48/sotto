# Plan: peer-to-peer encrypted messaging

Status: **approved, and in progress.** The protocol, session logic and store are built with tests (`app/lib/chat/`). The WebRTC data-channel engine, the screens, notifications and end-to-end tests are not built yet.

**Change from the plan:** offers, answers and candidates use `chat.offer`, `chat.answer` and `chat.ice`, not `sdp.*`, and carry the winning device's tag, so only that device applies them. The rest is as written below. `PROTOCOL.md` §5.10 has the wire format.

## Summary

Text messages go directly between the two people's devices over a WebRTC data
channel, set up the same way as a call. The relay only carries the encrypted
set-up messages, as it does for calls; it never sees the text and nothing is
stored on the server. Both people must have Sotto running at the same time.

No relay changes are needed: the relay already routes envelopes of any type
without reading them (§5.2 of `PROTOCOL.md`), so self-hosted servers keep
working without an update.

## What v1 includes

- One-to-one text messages between contacts.
- Delivery confirmation ("Delivered" when the other device has stored it).
- Chat history on each device, in the encrypted vault, deletable per chat.
- Desktop, Android and the browser app (signed-in profiles; not guests).

Not in v1: attachments, group chats, read receipts, chat during a call,
messages to someone who is offline (see "Offline" below), and history sync
between one person's devices (that is the separate multi-device task).

## How a chat session is set up

A chat session is a WebRTC connection with one data channel and no media.

1. Opening a chat (or sending the first message) sends `chat.open` to the
   contact in a sealed envelope, with a random 16-byte session id in the
   envelope's `callId` field (§3.1).
2. Every logged-in device of the contact receives it. Each that accepts
   replies `chat.accept` with a random `tag`. The first accept wins; the
   opener sends `chat.taken {tag}` and the other devices drop the session.
3. The opener sends `sdp.offer`; the other side answers with `sdp.answer`;
   both exchange `ice.candidate` messages. These are the existing call
   messages (§5.5), with the session id as `callId`.
4. The data channel `sotto-chat` opens. Both sides send a `hello` frame with
   the frame version before any messages.
5. The session closes with `chat.close`, or after 5 minutes without messages
   while the chat screen is closed. The next message opens a new session.

If both people open a chat with each other at once, the side whose Sotto ID
sorts lower keeps the offer; the other accepts it.

**Hide my IP address** applies exactly as in calls: with it on, the session
uses only TURN relay candidates (`iceTransportPolicy: "relay"`).

### New envelope types (`PROTOCOL.md` §5.10)

| `type` | Direction | `body` |
|---|---|---|
| `chat.open` | opener → contact | `{"name"?: string}` |
| `chat.accept` | contact → opener | `{"tag": string}` (16 random bytes) |
| `chat.decline` | contact → opener | `{"reason": "not-contact" \| "disabled"}` |
| `chat.taken` | opener → contact | `{"tag": string}` (the device that won) |
| `chat.close` | either | `{}` |

### Frames on the data channel

The channel is reliable and ordered. Each frame is UTF-8 JSON, at most 16 KiB.

| Frame | Meaning |
|---|---|
| `{"t":"hello","v":1}` | First frame from each side; other versions close the session. |
| `{"t":"msg","id":…,"ts":…,"text":…}` | A message. `id` is 16 random bytes (base64url), `ts` the sender's clock in ms, `text` at most 4,000 characters. |
| `{"t":"ack","id":…}` | The message is stored on the receiving device. |
| `{"t":"bye"}` | Closing the session normally. |

The receiver ignores a `msg` whose `id` it already has, so a resend after a
dropped connection is never shown twice. Text is cleaned of control
characters before it is shown.

## Security

- **Content.** The data channel is encrypted by DTLS with keys made fresh for
  each session. Each side's DTLS certificate fingerprint is inside the SDP,
  which travels in envelopes signed by that person's identity key, so the
  channel is bound to the right person and a relay or TURN server can't step
  in the middle. The safety number check (§4) covers it, as for calls.
- **Forward secrecy for content.** Because the DTLS keys are per session and
  then thrown away, a key stolen later can't decrypt recorded messages. This
  is stronger than the call set-up messages, which use long-term keys
  (`THREAT_MODEL.md`, item 1); those set-up messages carry no message text.
- **What the relay learns:** that two Sotto IDs set up a session, and when.
  This is the same as for a call. It does not learn how many messages were
  sent or what they say.
- **What a TURN server learns** (when used): the volume and timing of
  encrypted traffic.
- **Direct connections** show each side the other's IP address, unless Hide my
  IP address is on.
- **On the device:** history is in the encrypted vault, behind the app lock.
  A device that is compromised while unlocked exposes its history; no app can
  prevent that.

## Offline

With this design a message can only be sent while the other person's Sotto
is running. If no session opens within 20 seconds, the message is marked
**Not sent: <name> is offline**, with a Retry button. It is never kept or
resent in the background.

A later option, without server storage: keep unsent messages on the sender's
own device and send them automatically when the contact next comes online.

## Where the code goes

- `app/lib/chat/`: the data channel engine (behind an interface, like
  `MediaEngine`, so the flow is testable without WebRTC), the session state
  machine, the frame codec, and the chat store (vault).
- `app/lib/chat/ui/`: chat list, chat screen, and a Message button on each
  contact and in the call history.
- Notifications reuse the existing local notifications.
- All new text goes into the translation files (English, Bangla, Arabic).
- Docs: `PROTOCOL.md` §5.10, `THREAT_MODEL.md`, `FEATURES.md`, privacy page.

## Tests

- Unit: frame codec (sizes, versions, bad input), session state machine with a
  fake engine (accept, decline, the other device wins, both open at once,
  timeout, resend without duplicates), and the chat store.
- Widget: chat screen states (sending, delivered, not sent, retry).
- End-to-end (two browsers, like `e2e/call.mjs`): messages both ways; the
  other side offline gives "Not sent"; Hide my IP address uses TURN only; a
  network drop mid-chat.

## Steps

1. Protocol, session, frames and store, with unit tests.
2. Screens, notifications, translations.
3. End-to-end tests and docs; then a release.

## Decisions (recorded)

Approved with the recommended option for each:

1. **Who can message you:** contacts only. Others get `chat.decline`.
2. **Notifications:** the sender's name only. No text preview on the lock screen.
3. **History:** kept until you delete it. No automatic deletion in v1.
4. **Offline:** "Not sent" with Retry for v1. A sender-side outbox comes later.
