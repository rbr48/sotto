# Plan: peer-to-peer encrypted messaging

Status: **built and tested.** Built with tests: the protocol, session logic, store, the WebRTC connection, the chat screen (Message on each contact; `app/lib/chat/`, `app/lib/chat/ui/`), the browser tests of the data channel (`e2e/chat.mjs`, `e2e/chat-offline.mjs`), and notifications for new messages on Android and desktop (the names follow the "Show names in notifications" setting). Not built yet: notifications in the web app, which has no notification surface.

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

## Second plan: the first group of messaging features

Status: **step 1 is built and tested; steps 2 to 5 are not started.** The
decisions below are approved.

Adds to the one-to-one chat: replies, forwarding of text, reactions, editing,
delete for everyone, archive, mute and pin, starred messages, chat export, and
small groups of up to four people.

Not in this plan, each needing its own decision: delivery beyond the outbox and
the 60-second relay window (D1), history sync between one person's devices,
status posts, channels and communities, groups larger than four, payments and
business features, GIF and sticker search, link previews fetched by the
receiving app, and finding people by phone number. Each of these either needs
the server to store data or goes against a rule in `ROADMAP.md` §2.

### Decisions to approve

| # | Question | Recommended |
|---|---|---|
| D1 | Offline delivery | Keep the sender-side outbox, which is already built: a message the contact did not get waits on the sender's device and goes out when the chat reopens. The server keeps storing nothing. The gap that remains is when the sender closes the app before the contact returns. The alternative is an encrypted relay queue for a fixed time. That breaks "zero server storage" (`ROADMAP.md` §2, rule 1), so the privacy text would change, and it needs your approval. |
| D2 | Group size | Four people in total, including you, as in the group calls plan (`GROUP_CALLS_PLAN.md`). Each device keeps a direct chat with each other member. |
| D3 | Who can be in a group | Only people who are contacts of every member. Chats only open between contacts (recorded decision 1 above), so this is needed anyway. |
| D4 | Delete for everyone | Your own text messages only, allowed for one hour after sending. Files cannot be deleted for everyone. Best effort: another device may keep its copy, and the app says so. |
| D5 | Editing | Allowed for 15 minutes after sending. The new text replaces the old one and is marked "Edited". No edit history is kept. |
| D6 | Forwarding | Text only at first. A forwarded message keeps no link to the original, so nothing about the original is sent. Files can be forwarded later. |
| D7 | Reactions | One emoji per person per message. Sending an empty emoji removes your reaction. |
| D8 | Export | Encrypted with a passphrase by default, the same way as backups (`PROTOCOL.md` §8). Plain text only after a warning that anyone who has the file can read it. |
| D9 | Older app versions | Keep working. `hello` lists the features each side supports, and a new frame is sent only when both sides list it. Text and files keep working between old and new versions. |

### Protocol changes (`PROTOCOL.md` §5.10)

All new frames are UTF-8 JSON under the 16 KiB limit. Each device checks the
sender of every frame against the owner of the message it changes.

- `msg` gets an optional `reply`: `{"id", "text"}`. `text` is a copy of up to
  200 characters of the quoted message, so the quote still shows when the
  original is gone. No lookup is needed.
- `react`: `{"id", "emoji"}`, where `id` is the message reacted to. Each person
  has at most one reaction on a message.
- `edit`: `{"id", "ts", "text"}`. Accepted only for the sender's own text
  message, within 15 minutes of its `ts`.
- `delete`: `{"id"}`. Accepted only for the sender's own text message, within
  one hour of its `ts`.
- Forwarding uses an ordinary `msg`, so nothing new is needed.
- Groups use envelope types through the relay, as `chat.text` does:
  `group.invite` `{"group", "name", "members"}`, answered by `group.accept` or
  `group.decline`, and `group.leave`. Text that cannot go over a direct chat is
  sent as `group.text`, with the same 60-second rule as `chat.text`.
- A group message is a `group.msg` frame on each member's direct chat, with the
  fields of `msg` plus `group`. Each copy travels only over that member's own
  connection, as in a one-to-one chat.

### Storage

Added to the encrypted vault as optional fields, so older records still load:

- Message: `replyTo`, reactions (one emoji per person), `editedAt`,
  `deletedForAll`, `forwarded`, `starred`.
- Chat: `archived`, `muted`, `pinnedAt`. These never leave the device.
- Group: id, name, members, creation time, and whether you left.

### Screens

- Message menu: Reply, Forward, Copy, Star, Edit and Delete for everyone (only
  on your own text, inside its window), Delete for me, and Info (delivered
  and read times).
- A reaction bar under a message.
- Chat list: archived chats in their own section, pinned chats on top, and a
  mute icon.
- New group from the chats screen, with two or three contacts. The group header
  shows member names, and group info lists members and has "Leave group".
- Export from the chat menu, with the choice in D8.
- All new text in English, Bengali and Arabic. Golden images are regenerated.

Not in this plan: admins, removing other people from a group, and group names
changed by anyone except the creator. These can wait until there is a reason.

### Threat model and docs

- `THREAT_MODEL.md`: delete for everyone and editing cannot be enforced on
  another device. Members of a group see each other's names. An exported file
  can be read by whoever has it, and an encrypted export only with its
  passphrase.
- `FEATURES.md` and the privacy page: check the wording, because reactions and
  groups are new things users can do.
- `PROTOCOL.md` §5.10: the new frames and envelope types above.
- No relay change is expected, because the relay routes envelopes of any type
  without reading them (`PROTOCOL.md` §5.2).

### Tests

- Unit: the new frames (valid, too long, malformed emoji, wrong owner, outside
  the edit or delete window); reactions (one per person, an empty emoji removes
  it); storage migration of old records; the outbox for each group member; and
  archive, mute and pin kept across restarts. Export in both formats.
- Widget: the message menu for your own message and for the contact's message,
  inside and outside each window; the four-person limit when creating a group;
  and the plain-text export warning.
- End-to-end, two browsers (like `e2e/chat.mjs`): reply, reaction, edit, delete
  for everyone, and forwarding. Three browsers: a group message reaches both
  others, and a member who was offline gets it from the outbox when they return.
  The export has no end-to-end check. It is native only, because the browser
  build has no Argon2id, and the browser suite cannot reach it. Widget and unit
  tests cover it.

### Steps

1. Approve decisions D1–D9.
2. Protocol and storage for replies, forwarding, reactions, edit and delete,
   with unit tests and no new screens.
3. Screens for those, and the local-only features: archive, mute, pin, star and
   export.
4. Groups: invite, accept, decline, leave, group messages, the outbox for each
   member, and the screens. This is the largest step.
5. End-to-end tests, the docs above, then a release.
