# Plan: group calls and meetings

Status: **proposal, awaiting approval.** Nothing here is built yet.

## Summary

Phase 1 adds **group calls for up to 4 people on video** (or 8 on audio), using a
*mesh*: each participant holds one direct WebRTC connection to every other
participant. Media never passes through a server, so the privacy model stays
as it is for calls. The relay carries only the encrypted set-up messages, as
it does today, and the TURN servers relay media only where a direct path is
blocked.

Phase 2 adds meeting features (waiting room, host controls, screen sharing,
chat). Phase 3, a media server for larger meetings, is out of scope until
end-to-end frame encryption is confirmed to work on every platform.

## Why a mesh first

| | Mesh (proposed) | Media server (SFU) |
|---|---|---|
| Who can see media | Only the participants | The server operator, unless frames are also encrypted end to end |
| Server work | Set-up messages only | Forwards every stream |
| Upload per person | One copy per other participant | One copy, whatever the group size |
| Practical size | 4 video, about 8 audio | Dozens |
| New servers to run | None | A media server, with its own capacity planning |

The mesh is the only option that keeps the current promise (no server sees
call media) without new infrastructure. Its limits are the price of that.

## What exists and what changes

- **One call, one engine.** `CallManager` drives a single call, and
  `MediaEngine` says "one engine is used for one call". A group needs one
  engine per other participant, sharing one set of local camera and microphone
  tracks. This is the largest change: local capture must be separated from the
  peer connections.
- **Signalling is already routed by Sotto ID.** A group sends the same
  `sdp.*` and `ice.candidate` messages (`PROTOCOL.md` §5.5) once per pair.
  The relay needs no change.
- **Relay limits to respect** (`PROTOCOL.md` §5.2 and §5.4): each connection
  may send 20 messages a second, with bursts of 60. Each leg needs an offer,
  an answer and several candidates, so a device setting up three legs at once
  could approach the burst. This is an estimate, not a measurement: if it
  holds, set-up must be staggered, or the limit raised for call traffic.
- **Devices.** The relay allows 5 devices per Sotto ID (`server/src/relay/relay.ts`),
  so one person's second device can't be a separate participant without the
  multi-device work.

## Group protocol

A group call is a **room**. Its identity is a 16-byte random `room` id and a
16-byte random `secret`, both inside envelopes, so only invited people know
them. The room has a **roster**: the participants' Sotto IDs and names.

### Messages (inside envelopes, `PROTOCOL.md` §5.11)

| `type` | Direction | `body` |
|---|---|---|
| `room.invite` | host → invitee | `{"room", "secret", "video", "members": [{"id", "name"?}]}` |
| `room.join` | joiner → each member | `{"room", "secret", "name"?}` |
| `room.roster` | any member → joiner | `{"room", "members": [...]}` (the current list, so the joiner can connect to everyone) |
| `room.leave` | leaver → each member | `{"room"}` |
| `room.full` | member → joiner | `{"room"}` (the limit is reached) |
| `room.decline` | member → joiner | `{"room", "reason": "not-invited" \| "wrong-secret"}` |

### Connecting the legs

- Each pair of participants has one leg. Its `callId` is derived, not sent:
  `legId = SHA-256("sotto-leg-v1\0" || room || min(id_a, id_b) || max(id_a, id_b))[0..16]`.
  Both sides compute the same value.
- On a clash, when two people join at once, the lower Sotto ID always makes
  the offer. This is the same rule as for chat (`MESSAGING_PLAN.md`), and it
  avoids two offers crossing.
- Each leg runs the existing offer, answer and candidate exchange, with the
  same checks (`expectedSender` is the leg's other participant).
- A leg's media is encrypted by DTLS with keys made fresh for that leg, as it
  is for a call today.

### Joining, leaving, removing

- **Join:** the invitee sends `room.join` to each member. Each member checks
  the secret and the roster; a wrong secret or an uninvited ID gets
  `room.decline`. Accepted joiners receive `room.roster` and open legs.
- **Leave:** `room.leave` closes that person's legs. The call goes on for the
  rest.
- **Remove (host):** the host closes the legs and sends a new roster to the
  others. The removed person still has the room secret, so the others must
  refuse any later `room.join` from them. Refusal is by roster, which only the
  host can change.
- **Roster changes are signed by the host.** Each member keeps the last roster
  the host signed, and ignores unsigned or older ones. This stops a member from
  adding people the host did not invite.

## Limits and quality

- **Upload.** Each device sends one copy per other participant. The existing
  bandwidth adaptation (`setVideoLevel`) must share one budget across the
  legs, instead of each leg adapting alone.
- **Size.** 4 video participants means each device sends and receives up to 3
  streams. Above that, quality on phones drops quickly. Audio-only groups of up
  to 8 are the same mesh with the camera off.
- **TURN.** A leg that needs relaying costs TURN bandwidth. A 4-person mesh
  has 6 pairs, so up to 12 one-way streams can be relayed across the call.
  Hide my IP address forces relaying on every leg, so its cost grows with the
  group.
- **Measurements to make before committing:** CPU and battery on a mid-range
  Android phone with 3 legs, the relay's set-up burst at join, and TURN
  bandwidth for a 4-person call. The repository's TURN configuration needs
  checking for an existing bandwidth quota before we promise capacity.

## Security

- **Media.** Each leg is encrypted end to end, with ephemeral DTLS keys, so
  nothing in the middle can read it. Forward secrecy for media is kept.
- **Signalling.** As for calls, set-up messages use long-term keys, so the
  known gap in `THREAT_MODEL.md` (item 1) applies to every leg.
- **Joining needs the secret.** A Sotto ID that wasn't invited can't join,
  even if it learns the room id, because it doesn't have the secret.
- **Other participants see everything.** In a mesh every participant gets
  media from every other participant, and learns every other participant's
  Sotto ID and name. This is inherent to the design; it has to be stated in
  the app and in the privacy page.
- **The relay learns the group.** For every leg the relay sees the two Sotto
  IDs and the timing, so it learns who is in the call, as it does for a call
  today. It doesn't learn the room id, secret or media.
- **A participant can record.** As for calls (`THREAT_MODEL.md`, "malicious
  call participant"), a participant can record what it receives. The app can't
  prevent this.
- **Replay and sender checks.** Every envelope goes through the existing checks
  (`PROTOCOL.md` §3.3): recipient, signature, expected sender, time window and
  replay guard.

## Meeting features (Phase 2)

| Feature | How | Notes |
|---|---|---|
| **Waiting room** | Reuse the guest knock flow (§5.7): people who open a meeting link knock, and the host admits them | Meeting links are signed and secret, like guest links |
| **Host controls** | `room.control` messages: remove, and ask to mute | A mute can only be asked for. A participant's microphone can't be switched off by someone else |
| **Screen sharing** | `getDisplayMedia`, added to every leg (renegotiated) | Desktop and web first. Mobile platforms restrict capture |
| **Meeting chat** | Group data channels over the same legs | Depends on the peer-to-peer messaging work |
| **Scheduled meetings** | The scheduled-calls design | Already planned |
| **Raise hand, participant list** | Small control messages | Low risk |
| **Recording** | Not in Phase 1 | See decisions |

Breakout rooms and polls are left out: they add a lot of state for little
benefit to professional calls.

## Where the code goes

- `app/lib/call/`: split local capture (`LocalMedia`) from peer legs
  (`PeerLeg`, one per participant). `CallManager` stays as the 1:1 flow, and a
  new `RoomManager` runs groups, so the working 1:1 path changes as little as
  possible.
- `app/lib/call/room/`: the roster, the join rules, and the leg-id derivation.
- `app/lib/call/ui/`: a participant grid, with name, mute and camera state.
- `docs/PROTOCOL.md` §5.11 (the room messages), `THREAT_MODEL.md`, the privacy page.
- All new text goes into the translations (English, Bangla, Arabic).

## Tests

- **Unit, with fake legs:** join, leave and remove; a wrong or missing secret;
  the lower-ID rule when two people join at once; the full limit (a 5th
  participant gets `room.full`); a roster that isn't signed by the host; and
  a leg message from someone other than its peer.
- **Unit, legs and budget:** the shared video budget is split across legs.
- **End-to-end (several browsers, like `e2e/call.mjs`):** three participants
  connect and see each other; one leaves and the other two stay connected; a
  dropped network on one leg recovers without affecting the others.
- **Load:** the burst measurement and TURN bandwidth from "Limits and quality".

## Steps

1. Split local capture from peer legs; the existing 1:1 tests must still pass
   unchanged.
2. Room messages, roster and join rules, with unit tests.
3. Participant grid and controls.
4. Shared bandwidth budget across legs.
5. Measurements (burst, CPU, TURN), then the end-to-end tests.
6. Documentation and a release.
7. Phase 2 features, one at a time, each with its own plan.

## Decisions needed

1. **Size:** 4 people on video (recommended), or 8 on audio only at first?
2. **Who can invite:** only the host (recommended, as it keeps the roster
   simple), or any participant?
3. **If the host leaves:** the call goes on with the same roster, and nobody
   can invite or remove anyone until the call ends (recommended for v1), or
   the call ends for everyone?
4. **Visibility:** do you accept that every participant learns every
   other participant's name and Sotto ID? A mesh needs this, and the privacy
   page will say so.
5. **Recording:** none in Phase 1 (recommended). Any later version would be
   local only, announced to everyone, and visible on screen.
6. **Phase 3 (larger meetings):** only if needed, and only with end-to-end
   frame encryption confirmed on every platform first.
