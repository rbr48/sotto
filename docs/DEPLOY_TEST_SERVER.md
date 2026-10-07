# Deploying the Sotto Test Server

This runs the current Sotto test build on **`sotto.izhaanintellect.fun`** (server `148.135.137.245`):

- the **relay** (signaling) — routes end-to-end encrypted envelopes; no database, read-only filesystem
- the **web app**, served by **Caddy** with automatic HTTPS
- **coturn**, the STUN/TURN server that lets calls connect across difficult networks and powers "Hide my IP address"

After deployment, open `https://sotto.izhaanintellect.fun/` to get your own **call link**; anyone who opens that link calls you. The desktop and Android apps connect to `wss://sotto.izhaanintellect.fun/relay` by default.

> **This is a test build.** Call setup is end-to-end encrypted, the relay stores nothing, and calls fall back to the TURN server when a direct connection isn't possible.

---

## 1. Turn off the Cloudflare proxy for this record (important)

`izhaanintellect.fun` uses Cloudflare DNS, and `sotto.izhaanintellect.fun` currently resolves to **Cloudflare's IPs** (the orange cloud is on), not directly to `148.135.137.245`.

Set the record to **DNS only (grey cloud)**:

1. Cloudflare dashboard → `izhaanintellect.fun` → **DNS** → **Records**
2. Edit the `sotto` `A` record (`148.135.137.245`) → switch **Proxy status** to **DNS only** → Save

Why:
- **Privacy.** With the proxy on, Cloudflare terminates HTTPS and can see all traffic between users and the relay. That contradicts Sotto's promise that no third party sees signaling metadata.
- **TURN** needs direct UDP access to the server, which the Cloudflare proxy does not pass through. **Calls across networks will not work with the proxy on.**
- **Certificates.** Caddy gets its own Let's Encrypt certificate automatically when the domain points straight at the server.

Check it after a few minutes (should print `148.135.137.245`):

```bash
dig +short sotto.izhaanintellect.fun
```

## 2. Prepare the server

Requirements: a Linux VPS (Ubuntu 22.04/24.04 recommended), 1+ vCPU, **2 GB RAM or more for the first build** (the web app is compiled on the server), ~6 GB free disk.

```bash
ssh <user>@148.135.137.245

# Docker + Compose plugin
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER   # log out and back in afterwards

# Firewall (if ufw is enabled)
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw allow 3478/tcp            # STUN/TURN
sudo ufw allow 3478/udp
sudo ufw allow 5349/tcp            # TURN over TLS
sudo ufw allow 49152:65535/udp     # TURN relay ports
```

Open the same ports in your hosting provider's firewall panel, if it has one:

| Port(s) | Protocol | Used by |
|---|---|---|
| 80, 443 | TCP | Caddy (HTTPS, certificates) |
| 443 | UDP | Caddy (HTTP/3) |
| 3478 | UDP + TCP | coturn (STUN/TURN) |
| 5349 | TCP | coturn (TURN over TLS) |
| 49152–65535 | UDP | coturn (relayed media) |

## 3. Get the code

The repository is on GitHub (`rbr48/sotto`). If it is private, authenticate first (for example `gh auth login`, or add a read-only deploy key).

```bash
git clone https://github.com/rbr48/sotto.git
cd sotto
git checkout claude/blissful-wozniak-w64f4v   # until this work is merged into main
```

## 4. Configure and start

```bash
cd infra
cp .env.example .env
# Put a long random secret in .env (shared by the relay and coturn):
sed -i "s/^SOTTO_TURN_SECRET=.*/SOTTO_TURN_SECRET=$(openssl rand -hex 32)/" .env
docker compose up -d --build
```

On the very first start Caddy hasn't obtained the HTTPS certificate yet, so coturn starts **without** TURN over TLS (UDP/TCP 3478 work immediately). Once `https://sotto.izhaanintellect.fun/health` works, restart coturn once to enable TLS on port 5349:

```bash
docker compose restart coturn
```

Let's Encrypt certificates are renewed by Caddy every ~60 days; coturn only reads them at start. Add a weekly restart so it picks up renewals (it takes a second and does not affect calls that are already connected directly):

```bash
( crontab -l 2>/dev/null; echo "0 4 * * 1 cd $HOME/sotto/infra && docker compose restart coturn" ) | crontab -
```

The first build takes about **5–15 minutes**, because it downloads Flutter and compiles the web app. Later builds are faster.

## 5. Check it works

```bash
docker compose ps
curl https://sotto.izhaanintellect.fun/health
# {"status":"ok"}
```

Then test a call with two devices (or two browser windows):

1. On device **B**, open `https://sotto.izhaanintellect.fun/` and copy **Your call link**.
2. On device **A**, open that link. It calls B automatically.
3. On B, tap **Accept**. Allow camera and microphone on both.
4. Compare the **safety number** shown on both screens: it must be identical.

The tab title shows the call status: *Ready* → *Ringing…* / *Incoming call* → *Connected*. During a call the screen shows **Direct connection** or **Relayed through Sotto**. `https://sotto.izhaanintellect.fun/?selftest=1` runs the crypto self-test in the browser.

**Guest links:** on the professional's device, copy the **personal guest link** (or create a one-time link) and open it on another device or browser. The guest checks their camera, presses **Join with video** and waits; the professional presses **Admit** in the waiting room.

To test TURN, turn on **Hide my IP address** before calling: the call must show *Relayed through Sotto*. See [`NETWORK_TESTING.md`](NETWORK_TESTING.md) for the full network test matrix.

## 6. Update to a new version

```bash
cd ~/sotto
git pull
cd infra && docker compose up -d --build
```

## 7. Troubleshooting

| Problem | Fix |
|---|---|
| Certificate errors / Caddy logs show ACME failures | The record must be **DNS only** and point to `148.135.137.245`; ports 80 and 443 must be reachable from the internet |
| `docker compose logs web` shows build running out of memory | Add swap (`sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile`) or build the web app elsewhere |
| Stuck on *Connecting…* between two different networks | TURN isn't reachable: check the Cloudflare record is **DNS only**, the firewall ports above are open, and `docker compose ps` shows coturn running. Test with **Hide my IP address** on |
| Calls with *Hide my IP address* fail | Same as above; also check `SOTTO_TURN_SECRET` is set in `.env` and both relay and coturn were restarted after changing it |
| Need to see coturn's logs while debugging | Temporarily remove `logging: driver: none` from the coturn service, `docker compose up -d coturn`, then `docker compose logs coturn`. Put it back afterwards: coturn logs IP addresses |
| Camera blocked in the browser | The page must be opened over **https://**; check the site's camera permission in the browser |

Logs are capped at 1 MB per container, and neither the relay nor Caddy logs requests or user data:

```bash
docker compose logs --tail=50
```

## What the server keeps

Nothing on disk. The relay holds, in memory only, which Sotto IDs are connected and envelopes waiting up to 60 seconds for an offline recipient; both disappear on restart. coturn runs read-only with its logs discarded, and its TURN usernames are `<expiry>:<random>`, never a Sotto ID. Caddy keeps only its TLS certificates (the `caddy_data` volume).
