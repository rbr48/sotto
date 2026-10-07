# End-to-end tests

`call.mjs` runs real calls between headless Chromium tabs (fake camera and
microphone) through the real relay. It checks:

- the crypto self-test passes in the browser
- opening someone's call link rings their device; accept → connected with live video
- a third caller gets *busy*; hang up, decline and cancel/missed all reach both sides
- every frame sent to the relay is a login or an opaque encrypted envelope

```bash
# 1. Relay
cd server && npm ci && npm run build && HOST=127.0.0.1 npm start &

# 2. Web build pointed at the local relay, served on port 8099
cd app && flutter build web --dart-define=SOTTO_RELAY_URL=ws://localhost:8080/relay
python3 -m http.server 8099 --directory build/web &

# 3. Run the test
cd e2e && npm ci && npx playwright install chromium && npm test
```

Buttons are clicked through Flutter's accessibility tree, and the call status
is read from the page title.
