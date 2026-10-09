# Plan: file sharing

Status: **proposal, awaiting approval.** Nothing here is built yet. It builds on
the peer-to-peer messaging plan (`MESSAGING_PLAN.md`), which must be built first.

## Summary

One person sends a file or photo to a contact from the chat. The file goes
directly from one device to the other, over the same data channel as messages,
in encrypted chunks checked with a hash. The relay never carries file content,
and no server stores it. The receiver keeps the file encrypted on the device,
and nothing opens automatically.

Both people must be online, as for messages. A file that can't be sent shows
"Not sent" with Retry.

## Why not through the relay, and why not the vault

- **Relay:** envelopes are capped at about 72 KB and held only in memory. Files
  would have to be stored on the server, which breaks the no-storage promise.
- **Vault:** the vault is one encrypted file, rewritten in full on every change
  (`PROTOCOL.md` §9). Storing megabytes of content there would slow every save
  and keep the whole file in memory.
- **Backups:** a backup is one JSON document held in memory (`PROTOCOL.md` §8).
  File content would make it impractically large, so files are left out of
  backups.

So files get their own store: one encrypted blob per file on the device, with
its metadata and per-file key kept in the vault.

## Scope

**In v1**
- Sending a file or photo to a contact, from the chat, one at a time per chat.
- Receiving, accepting or declining each file (see decisions).
- Opening a received file with the operating system's own app, on the user's
  tap. Deleting a received file.
- Desktop and Android in full. The browser app can send and receive small files
  only (see below).

**Not in v1:** groups (each member would need a separate copy), resuming after
the connection drops, folders, sending several files at once, previews of
documents, and cloud or server storage.

## Transfer

The data channel and the session come from the messaging plan. File transfer
adds these frames:

| Frame | Kind | Meaning |
|---|---|---|
| `{"t":"file.offer", "id", "name", "size", "mime", "sha256", "chunks"}` | JSON | Offer to send. `id` is 16 random bytes. `sha256` is the hash of the whole file. |
| `{"t":"file.accept", "id"}` / `{"t":"file.decline", "id"}` | JSON | The receiver's answer |
| `{"t":"file.done", "id"}` / `{"t":"file.ack", "id"}` | JSON | Sender has sent every chunk; receiver has stored and verified the file |
| `{"t":"file.cancel", "id", "reason"}` | JSON | Either side stops the transfer |
| chunk | **binary** | 16 bytes `id`, 4 bytes chunk index, then up to 16 KiB of file data |

**Chunks are binary, not JSON.** The messaging plan caps JSON frames at 16 KiB.
Base64 would turn a 16 KiB chunk into about 21 KiB, so chunks travel as binary
frames instead. This changes the messaging frame rules, which need updating
when the file-sharing plan is approved.

Rules:
- Chunk sizes are fixed at 16 KiB, so the receiver can place each chunk by its
  index. A repeated index is ignored.
- The sender waits for the channel's send buffer to fall below 1 MiB before
  sending more, so memory use stays flat for large files.
- The receiver writes chunks to a temporary file as they arrive. After the last
  chunk, it computes the SHA-256 of the file and compares it with the offer. A
  mismatch deletes the temporary file and reports "Damaged transfer". It never
  keeps a file that failed the check.
- A transfer is cancelled if no chunk arrives for 30 seconds, or if the session
  ends. The receiver deletes the temporary file and shows "Interrupted". There
  is no resume in v1: the file is sent again from the start.
- The sender checks the size limit before offering. The receiver refuses any
  offer above the limit, or one that doesn't fit the free space on the device.

## Storage on the receiving device

- **Native (desktop, Android):** each file is one encrypted blob in the app's
  private support directory. Its contents are encrypted with XChaCha20-Poly1305
  under a random 32-byte per-file key.
- **Metadata** (name, size, type, hash, who sent it, when, and the per-file key)
  is stored in the vault under `sotto.files.v1`. It's small, so the vault stays
  fast. It is **device-only**, like the device settings, so it is left out of
  backups (`PROTOCOL.md` §8). Without this, a backup would hold keys for files
  that the backup doesn't contain.
- **Deleting** a file removes its metadata, and with it the per-file key. The
  blob can't be read after that, even if the device's storage still holds it.
  This is deletion by destroying the key. Overwriting flash storage isn't
  reliable, so this is the protection that matters.
- Writes use a temporary file and a rename, the same as the vault.
- **Browser:** the browser vault lives in memory and disappears with the tab
  (`PROTOCOL.md` §9). A received file is offered as a download straight away
  and is not stored. Storing files in the browser would need the Remember-me
  storage, which has its own size limits. That is left for a later version.

## Safety

**Names.** The sender's name is cleaned before it's shown or used: path
separators, control characters and leading dots are removed; it's cut to 120
characters; and Windows reserved names (`CON`, `NUL`, `COM1` and so on) get a
prefix. The receiver chooses the place the file is saved, through the system's
save dialog. Nothing is written to a path the sender chose.

**Blocked types.** These are refused, by name and by type, on both sides:
executables and installers (`.exe`, `.msi`, `.apk`, `.app`, `.dmg`, `.deb`,
`.rpm`, `.appimage`), scripts (`.bat`, `.cmd`, `.ps1`, `.sh`, `.vbs`, `.js`,
`.jar`, `.scr`, `.com`, `.lnk`).

**Macros.** Office files that can contain macros (`.docm`, `.xlsm`, `.pptm`) are
allowed, with a warning on both sides.

**Opening.** Nothing opens automatically. Opening hands the file to the
operating system's app after the user taps Open. The app doesn't render
documents itself.

**Images.** Photos are shown as previews only after they are stored, decoded by
the operating system's image libraries. Corrupt images show an error and nothing
more.

**Malware.** The app doesn't scan files. The warnings and the blocked types
reduce the risk, but a received document can still contain malicious content,
and the user must judge what to open. The privacy page and the help text should
say so.

## Privacy and metadata

**Photos.** Location and camera details are removed from photos before sending,
by default. For JPEG this means removing the EXIF, XMP and IPTC segments without
re-encoding, so quality is not lost. For PNG it means removing the text and
time chunks. **HEIC** photos from iPhones need re-encoding to remove their
metadata, which is a later addition: until then, the sender sees a warning that
HEIC photos keep their location details.

**What each party learns**

| Who | Learns |
|---|---|
| The other person | Name, size, type, hash, and the content |
| The relay | Nothing about files. It carries only the session set-up, as for messages |
| A TURN server (only when used) | The encrypted traffic's size and timing. It can't read the content |
| Someone with the locked device | Nothing. The vault and the file keys are behind the app lock |
| Someone with the unlocked device | Everything the owner can see, as for chat history |

File sizes are visible to a TURN server and to anyone watching the network. v1
doesn't pad files to hide their size.

**Hide my IP address.** With this on, transfers go through TURN. Large files
then use the TURN server's bandwidth. The app should warn before sending a
file in this mode, and the warning should say what it costs.

**Notifications.** As for messages, a new file notification shows the sender's
name only, never the file name.

## Limits

| | Native | Browser |
|---|---|---|
| Largest file (proposed) | 100 MB | 25 MB, received as a download only |
| Files at once | One per chat | One per chat |
| Storage check | Before accepting, free space must cover the file | Not applicable |

The 100 MB figure is a starting point, not a measured limit. Speed depends on
the connection: a direct connection is limited by the networks at each end,
and a relayed one by the TURN server. The steps below include a measurement.

## Where the code goes

- `app/lib/chat/files/`: the transfer state machine, the chunking and hashing,
  and the frame codec for JSON and binary frames.
- `app/lib/files/`: the blob store (encrypted files on disk), the sanitising of
  names, the blocked types, and the photo metadata removal.
- `app/lib/chat/ui/`: the attach button, the offer and progress views, and
  open and delete actions.
- `docs/PROTOCOL.md` §5.12 (file frames and the binary chunk format),
  `THREAT_MODEL.md`, the privacy page, and `FEATURES.md`.
- All new text goes into the translations (English, Bangla, Arabic).

## Tests

- **Chunking and hashing:** a file split into chunks and reassembled matches its
  hash, including with chunks arriving out of order and repeated; a damaged chunk
  makes the transfer fail with "Damaged transfer" and no file kept.
- **Cancellation:** a transfer cancelled at 50%, or cut off by a dropped
  session, leaves no temporary file behind and reports "Interrupted".
- **Limits:** a file over the cap is refused by the sender before the offer, and
  by the receiver when the offer arrives; an offer that doesn't fit the free
  space is refused.
- **Names:** `../` sequences, control characters, long names and reserved Windows
  names are all sanitised; a path chosen by the sender is never used.
- **Blocked types:** executables and scripts are refused by name and by type.
- **Photos:** a JPEG with GPS data and a PNG with text chunks come out with
  those removed, and the image still decodes.
- **Deletion:** after deleting a file, its blob can't be decrypted, because the
  key has been removed from the vault.
- **Browser:** a received file is offered as a download and nothing is stored.
- **Malformed input:** a fuzz test on the binary frame parser, with random and
  truncated frames, never crashes and never writes outside the blob store.
- **End-to-end (two browsers and the native app):** a 10 MB file arrives with a
  matching hash; a transfer cut at 50% reports "Interrupted"; a file sent with
  Hide my IP address shows the warning.

## Steps

1. Build messaging first (`MESSAGING_PLAN.md`), including its data channel.
2. Frame codec (JSON and binary), chunking, and hashing, with unit tests on a
   fake channel.
3. The blob store, per-file keys, vault metadata, and deletion, with tests.
4. Name cleaning, blocked types, and photo metadata removal, with tests.
5. The chat UI: attach, offer, progress, open and delete.
6. The browser download-only path.
7. End-to-end tests, measurements (speed over a direct connection and over TURN),
   documentation, and a release.

## Decisions needed

1. **Size limit:** 100 MB on desktop and Android, and 25 MB in the browser
   (recommended). The alternative is 25 MB everywhere, which is simpler.
2. **Accepting files:** ask for every file (recommended). The alternative is
   automatic for photos from contacts.
3. **Photo location:** removed by default (recommended). HEIC photos get a
   warning until they can be re-encoded.
4. **Executables and scripts:** blocked (recommended).
5. **Browser:** download only, never stored (recommended). The alternative is
   storing received files with Remember me on.
6. **Backups:** files are left out (recommended). A new device won't have
   earlier files.
7. **Resuming after a dropped connection:** not in v1 (recommended).
8. **Hide my IP address:** file transfers allowed, with a warning about the
   cost (recommended). The alternative is blocking them.
