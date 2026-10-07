# End-to-end tests

`call.mjs` runs real calls between headless Chromium tabs (fake camera and
microphone) through the real relay. It checks:

- the crypto self-test passes in the browser
- opening someone's call link rings their device; accept → connected with live video
- a third caller gets *busy*; hang up, decline and cancel/missed all reach both sides
- the first call connects **direct**; with *Hide my IP address* the next call connects **relayed** through TURN
- every frame sent to the relay is a login, an ICE request or an opaque encrypted envelope

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
cd app && flutter build web --dart-define=SOTTO_RELAY_URL=ws://localhost:8080/relay
python3 -m http.server 8099 --directory build/web &

# 3. Run the test
cd e2e && npm ci && npx playwright install chromium && npm test
```

Buttons are clicked through Flutter's accessibility tree, and the call status
is read from the page title.
