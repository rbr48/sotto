# Sotto

**Speak freely. Nothing is kept.**

Sotto is a privacy-first audio and video calling app for professionals and their clients: lawyers, therapists, doctors, accountants, journalists and small organisations.

- Clients join from **any browser** with a link: no app, no account
- **End-to-end encrypted** 1:1 calls
- **Zero server storage**: the server only connects calls, in memory
- **Consent-based recording** kept only on the professional's device
- Use our **hosted service** or **self-host** with one command

The name comes from *sotto voce*: speaking quietly so that only the listener hears.

> Status: **Phase 1 — WebRTC proof of concept.** Two people can join the same room code and video-call each other. Not yet end-to-end encrypted signaling (Phase 3) or TURN (Phase 4).

**Package name / application ID:** `com.izhaanintellect.sotto` (publisher: Izhaan Intellect)

## Repository

| Folder | What it is |
|---|---|
| `app/` | Flutter app: Android, Windows, Linux and the browser (web) |
| `server/` | Relay server (Node.js + TypeScript). Stores nothing |
| `infra/` | Docker Compose + Caddy deployment for the test server |
| `e2e/` | End-to-end test: a real call between two headless browsers |
| `docs/` | Strategy, roadmap, features and deployment guides |

## Try it

**Online** (after the test server is deployed): open `https://sotto.izhaanintellect.fun/?room=pick-a-code&join=1` on two devices.

**Locally:**

```bash
# Relay with proof-of-concept rooms
cd server && npm ci && npm run build && SOTTO_DEV_ROOMS=1 npm start

# App (another terminal) — desktop, or Chrome for the web version
cd app && flutter run -d linux --dart-define=SOTTO_RELAY_URL=ws://localhost:8080/dev/rooms
cd app && flutter run -d chrome --dart-define=SOTTO_RELAY_URL=ws://localhost:8080/dev/rooms
```

Join the same room code on two devices or windows.

## Development checks

```bash
cd server && npm run lint && npm run typecheck && npm test
cd app && flutter analyze && flutter test
```

See [`e2e/README.md`](e2e/README.md) for the end-to-end call test.

## Documents

- [Product strategy, technical plan & roadmap](docs/ROADMAP.md)
- [Feature list](docs/FEATURES.md)
- [Deploying the test server](docs/DEPLOY_TEST_SERVER.md)

## Before using the name publicly

- [ ] Domain (for example `sotto.app`, `getsotto.com`, `sottocall.com`)
- [ ] Trademark search (local office, USPTO, EUIPO; classes 9 and 38)
- [ ] Play Store / Microsoft Store name check
- [ ] Social handles
