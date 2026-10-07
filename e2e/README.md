# End-to-end tests

`poc-call.mjs` runs a real WebRTC call between two headless Chromium tabs
(with fake camera and microphone) through the relay.

```bash
# 1. Relay with dev rooms
cd server && npm ci && npm run build && SOTTO_DEV_ROOMS=1 npm start &

# 2. Web build pointed at the local relay, served on port 8099
cd app && flutter build web --dart-define=SOTTO_RELAY_URL=ws://localhost:8080/dev/rooms
python3 -m http.server 8099 --directory build/web &

# 3. Run the test
cd e2e && npm ci && npx playwright install chromium && npm test
```
