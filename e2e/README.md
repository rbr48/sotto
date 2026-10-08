# End-to-end tests

`call.mjs`, `guest.mjs`, `autoanswer.mjs`, `phase6.mjs`, `phase7.mjs`, `remember.mjs`, `firefox.mjs` and `safari.mjs` run real calls between headless Chromium tabs (fake camera and
microphone) through the real relay and a real TURN server. They check:

- the crypto self-test passes in the browser
- onboarding (name and practice); opening someone's call link rings their device; accept → connected with live video
- a third caller gets *busy*; hang up, decline and cancel/missed all reach both sides
- the first call connects **direct** (or relayed on a starved machine); with *Hide my IP address* the next call connects **relayed** through TURN
- guest links: knock, waiting room, admit, decline, replaced, one-time and tampered links
- auto-answer: only for a verified contact, behind the app lock's PIN; voice only; decline wins; strangers ring
- Phase 6: contact links, calling from contacts, call timer and quality, history with talk time and a note, the app lock (a call rings on top of it), the device picker
- Phase 7: ringtone and ringback tone, a dialog left open closes for an incoming call, the knock chime, no server setting in the browser
- every frame sent to the relay is a login, an ICE request or an opaque encrypted envelope, with no names, notes or PINs; pages contact no third-party hosts
- Remember me on this browser (`remember.mjs`): the warning and the "links work only while this tab is open" card without it; with it, the same links after reloading; what IndexedDB holds is encrypted and its key isn't extractable; *Forget this browser* deletes it; an empty database left behind doesn't break it
- reconnecting (`reconnect.mjs`): a call through the TURN server survives the TURN server freezing for 15 s (`SIGSTOP`, via its pidfile `SOTTO_TURN_PIDFILE`, default `/tmp/turn.pid`): both sides show *Reconnecting*, then reconnect by themselves (ICE restart) and the video plays again
- Safari's engine (`safari.mjs`, WebKit with the professional in Chromium): the crypto self-test, a signed guest link (verified name, device check), clear advice when the camera can't be used, a signed contact link, a tampered link rejected. Not a live call: Playwright's Linux WebKit always refuses camera and microphone access, so calls from Safari are checked by hand (below)

```bash
# 0. A test TURN server on loopback (apt install coturn)
turnserver -n --listening-ip=127.0.0.1 --listening-port=3478 --use-auth-secret \
  --static-auth-secret=e2e-secret --realm=sotto.test --allow-loopback-peers \
  --no-cli --no-tls --no-dtls --fingerprint --no-tcp-relay --min-port=50000 --max-port=50200 \
  --userdb=/tmp/turndb --pidfile=/tmp/turn.pid &

# 1. Relay, handing out that TURN server
cd server && npm ci && npm run build
HOST=127.0.0.1 SOTTO_STUN_URLS='stun:127.0.0.1:3478' \
  SOTTO_TURN_URLS='turn:127.0.0.1:3478?transport=udp' SOTTO_TURN_SECRET=e2e-secret npm start &

# 2. Web build pointed at the local relay, served on port 8099
cd app && flutter build web --no-web-resources-cdn --dart-define=SOTTO_RELAY_URL=ws://localhost:8080/relay
python3 -m http.server 8099 --directory build/web &

# 3. Run the test
cd e2e && npm ci && npx playwright install --with-deps chromium webkit && npm test
```

Buttons are clicked through Flutter's accessibility tree, and the call status
is read from the page title.

## Safari and iPhone, by hand

Before each release, and after changes to calls or the guest page, on the
test server (or your own):

1. On a computer, open the app and copy your personal guest link.
2. On an **iPhone** (Safari, current iOS): open the link, allow the camera and
   microphone, enter a name, *Join with video*. Admit the guest on the computer.
3. Check: video and sound both ways; the iPhone's video stays inside the page
   (not full screen); the call survives locking and unlocking the phone for a
   few seconds; *Hang up* on either side ends it on both.
4. Turn on *Hide my IP address* on the computer (Settings), then join again
   from the iPhone with *Voice only*: the call screen shows *Relayed through
   Sotto* (this checks TURN from Safari).
5. Repeat steps 2–3 with **Safari on a Mac**.
6. Deny the camera on the iPhone once: the page must explain how to allow it.

Write down the iOS and Safari versions you tested in the release notes.
