# Deploying the Sotto Test Server

This runs the current Sotto test build on **`call.sottocall.com`** (server `148.135.137.245`, behind Nginx). The earlier address, `sotto.izhaanintellect.fun`, points to the same server and keeps working, for links shared before the move and for app versions up to 0.1.4 (see [Moving to call.sottocall.com](#moving-to-callsottocallcom)).

- the **relay** (signaling) — routes end-to-end encrypted envelopes; no database, read-only filesystem
- the **web app**, served by **Caddy** with automatic HTTPS
- **coturn**, the STUN/TURN server that lets calls connect across difficult networks and powers "Hide my IP address"

After deployment, open `https://call.sottocall.com/` to get your own **call link**; anyone who opens that link calls you. The desktop and Android apps (0.1.5 and later) connect to `wss://call.sottocall.com/relay` by default.

> **This is a test build.** Call setup is end-to-end encrypted, the relay stores nothing, and calls fall back to the TURN server when a direct connection isn't possible.

---

## 1. Point the name at the server, without a proxy (important)

Create an `A` record `call` → `148.135.137.245` in the DNS of `sottocall.com`. If the DNS is on Cloudflare, set it to **DNS only (grey cloud)**, not proxied:

1. Cloudflare dashboard → `sottocall.com` → **DNS** → **Records**
2. Add (or edit) the `call` `A` record (`148.135.137.245`) → **Proxy status**: **DNS only** → Save

Why:
- **Privacy.** With the proxy on, Cloudflare terminates HTTPS and can see all traffic between users and the relay. That contradicts Sotto's promise that no third party sees signaling metadata.
- **TURN** needs direct UDP access to the server, which the Cloudflare proxy does not pass through. **Calls across networks will not work with the proxy on.**
- **Certificates.** Caddy gets its own Let's Encrypt certificate automatically when the domain points straight at the server.

Check it after a few minutes (should print `148.135.137.245`):

```bash
dig +short call.sottocall.com
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
git checkout main
```

## 4. Configure and start

The installer does the rest (checks DNS, writes `infra/.env` with a random TURN secret, builds, starts, enables TURN over TLS once the certificate exists, and schedules coturn's weekly certificate reload). Details: [`SELF_HOSTING.md`](SELF_HOSTING.md).

```bash
sudo ./infra/install.sh install --domain call.sottocall.com
```

If you already started it by hand earlier, that's fine: the installer keeps the existing `infra/.env` secret.

The privacy policy and terms (`/privacy.html`, `/terms.html`) name the operator and the support contacts from `infra/.env`. Set them once (later installs keep them):

```bash
sudo ./infra/install.sh install --domain call.sottocall.com \
  --operator "Sotto (Izhaan Intellect)" --contact contact@sottocall.com \
  --support-email support@sottocall.com \
  --support-link 'https://call.sottocall.com/#c=n3qJ6HlYC0WI3DU_ixZTW6VaXCTX04zQTw5FjPj20CQ'
```

## 5. Check it works

```bash
docker compose ps
curl https://call.sottocall.com/health
# {"status":"ok"}
```

Then test a call with two devices (or two browser windows):

1. On device **B**, open `https://call.sottocall.com/` and copy **Your call link**.
2. On device **A**, open that link. It calls B automatically.
3. On B, tap **Accept**. Allow camera and microphone on both.
4. Compare the **safety number** shown on both screens: it must be identical.

The tab title shows the call status: *Ready* → *Ringing…* / *Incoming call* → *Connected*. During a call, a small **Relayed** chip at the top means the call goes through the TURN server; no chip means a direct connection (*Settings → Help → Diagnostic report* shows the route either way). `https://call.sottocall.com/?selftest=1` runs the crypto self-test in the browser.

**Guest links:** on the professional's device, copy the **personal guest link** (or create a one-time link) and open it on another device or browser. The guest checks their camera, presses **Join with video** and waits; the professional presses **Admit** in the waiting room.

To test TURN, turn on **Hide my IP address** before calling: the call must show the *Relayed* chip. See [`NETWORK_TESTING.md`](NETWORK_TESTING.md) for the full network test matrix.

## 6. Update to a new version

```bash
cd ~/sotto
sudo ./infra/install.sh update
```

## Moving to call.sottocall.com

The server first ran as `sotto.izhaanintellect.fun`. Both names now point to the same server, so nothing breaks during the move: a link with either name reaches the same relay, and apps up to 0.1.4 keep using the old name. Keep the old name working for a few months (until people have updated and shared new links).

1. **DNS:** add the `call` `A` record for `sottocall.com` (step 1 above). Check: `dig +short call.sottocall.com` prints `148.135.137.245`.
2. **Nginx:** copy the existing `server { … }` block of `sotto.izhaanintellect.fun` into a new site, change only `server_name` and the certificate paths, and get the certificate:

   ```bash
   sudo cp /etc/nginx/sites-available/sotto.izhaanintellect.fun /etc/nginx/sites-available/call.sottocall.com
   sudo nano /etc/nginx/sites-available/call.sottocall.com
   #   server_name call.sottocall.com;
   #   remove the two ssl_certificate lines (Certbot adds the new ones)
   #   keep proxy_pass (the same port), the headers and access_log off;
   sudo ln -s /etc/nginx/sites-available/call.sottocall.com /etc/nginx/sites-enabled/
   sudo certbot --nginx -d call.sottocall.com
   sudo nginx -t && sudo systemctl reload nginx
   curl https://call.sottocall.com/health      # {"status":"ok"}
   ```

   (Use the file names your server already has; the installer prints a complete block if you need one.)
3. **TURN under the new name:** run the installer with the new domain. It keeps the TURN secret, the proxy port and the operator details, and uses `call.sottocall.com`'s certificate for TURN over TLS:

   ```bash
   cd ~/sotto && git pull
   sudo ./infra/install.sh install --domain call.sottocall.com --yes
   ```

   Calls then use `turn:call.sottocall.com` and `turns:call.sottocall.com:5349`, whichever name the app or page was opened with.
4. **Optional:** send `sottocall.com` and `www.sottocall.com` to the app until there is a website (`A` records for `@` and `www` → `148.135.137.245`, then):

   ```nginx
   server {
       server_name sottocall.com www.sottocall.com;
       listen 80;
       return 302 https://call.sottocall.com/;
   }
   ```

   followed by `sudo certbot --nginx -d sottocall.com -d www.sottocall.com`.

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
