# Self-hosting Sotto

Run your own Sotto server, so that no third party (not even us) relays your calls. One server runs three things:

| Part | What it does | What it keeps |
|---|---|---|
| **Relay** | Passes end-to-end encrypted call-setup messages between devices | Nothing on disk; who is online, in memory only |
| **Web app** (Caddy) | Serves the page guests open from your links, with automatic HTTPS | Only its TLS certificate |
| **coturn** | STUN/TURN: connects calls across strict networks, and powers *Hide my IP address* | Nothing; its logs are discarded |

Calls stay end-to-end encrypted: the server can't read messages or media, whoever runs it.

## What you need

- A Linux server (VPS) with a public IP: Ubuntu 22.04/24.04 or Debian 12 recommended, 1 vCPU, **2 GB RAM** (the installer adds swap if there is less; the web app is compiled on the server), about 6 GB of free disk.
- A domain or subdomain, for example `calls.yourpractice.org`, whose DNS **A record** points to the server's IP.
  - Using Cloudflare? Set the record to **DNS only** (grey cloud). The proxy blocks calls (TURN needs direct UDP) and would see all traffic. The installer refuses to continue while the proxy is on.
- About 15 minutes.

## Install

```bash
ssh root@your-server
git clone https://github.com/rbr48/sotto.git
cd sotto
sudo ./infra/install.sh
```

The installer asks for the domain, then:

1. checks that the domain points to this server (and isn't behind Cloudflare's proxy; behind NAT, it asks for the public IP);
2. installs Docker if it is missing (with your permission);
3. adds a 2 GB swap file if the server has little memory;
4. opens the firewall ports in ufw or firewalld;
5. writes `infra/.env` with a random TURN secret (readable only by root);
6. builds and starts everything (the first build takes 5–15 minutes);
7. waits until `https://<domain>/health` answers, then restarts coturn so TURN over TLS uses the new certificate;
8. adds a weekly coturn restart (root's crontab) so it picks up certificate renewals.

Non-interactive: `sudo ./infra/install.sh install --domain calls.yourpractice.org --yes`. See `--help` for all options, and `--dry-run` to see what it would do.

### Shared server (alongside Nginx, Apache, or existing sites)

If your server already hosts other websites or uses ports 80/443 (e.g. managed by Nginx), run the installer with `--behind-proxy`. It needs Docker Compose 2.24 or newer (`docker compose version`).

Get the certificate for the domain in your web server first (for example `sudo certbot --nginx -d calls.yourpractice.org`), then:

```bash
sudo ./infra/install.sh install --domain calls.yourpractice.org --behind-proxy 8185 --yes
```

In this mode, Sotto:
- binds its web container to `127.0.0.1:8185` (or any local port you pass) instead of public ports 80 and 443;
- leaves ports 80 and 443 alone in your firewall;
- runs coturn on ports 3478 and 49152–65535 (TURN media requires direct UDP), and on 5349 for TURN over TLS when it can use your web server's certificate (see below);
- trusts the address your web server forwards (`X-Forwarded-For`), so its per-address connection limit applies to each client rather than to the web server;
- writes these settings to `infra/docker-compose.override.yml` (rewritten by each install) and prints the Nginx configuration snippet ready to paste into your virtual host.

**TURN over TLS** (port 5349) lets calls connect from networks that only allow HTTPS-like traffic. Without its own HTTPS, Sotto uses your web server's certificate: Certbot's (`/etc/letsencrypt/live/<domain>/`) is found automatically; for other locations pass `--tls-cert /path/fullchain.pem --tls-key /path/privkey.pem`. Without a certificate, Sotto works but leaves TURN over TLS off; run the installer again once there is one. coturn is restarted weekly to load renewed certificates.

In your Nginx site configuration (`/etc/nginx/sites-available/...`):

```nginx
server {
    server_name calls.yourpractice.org;
    listen 443 ssl http2;
    ssl_certificate     /etc/letsencrypt/live/calls.yourpractice.org/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/calls.yourpractice.org/privkey.pem;

    # Sotto keeps no request logs; don't let the proxy keep them either
    # (they would hold every visitor's IP address).
    access_log off;

    location / {
        proxy_pass http://127.0.0.1:8185;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        # Only the client's own address (Sotto limits connections per address).
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

**Hosting provider firewall:** if your provider has a firewall in its control panel, open these ports there too (in `--behind-proxy` mode, ports 80/443 are handled by your existing web server):

| Port(s) | Protocol | Used by |
|---|---|---|
| 80, 443 | TCP | HTTPS and certificates (handled by existing web server in `--behind-proxy` mode) |
| 443 | UDP | HTTP/3 (standalone mode only) |
| 3478 | UDP and TCP | STUN/TURN |
| 5349 | TCP | TURN over TLS (for networks that only allow HTTPS-like traffic) |
| 49152–65535 | UDP | Relayed call media |

## Use it

**In the Sotto app** (Windows, Linux, Android): *Settings → Server → Use another server*, enter your domain, then *Check and use*. The app checks that a Sotto relay answers there before switching. From then on:

- guest links and your contact link point to your server;
- colleagues who want to call you must use the same server;
- links you shared before the switch stop reaching you, so share new ones.

The choice is kept on the device and included in backups.

**In a browser:** open `https://<domain>/`. A browser session always uses the server it was loaded from and keeps nothing after the tab is closed.

**Check it:** `https://<domain>/health` shows `{"status":"ok"}`; `https://<domain>/?selftest=1` runs the browser crypto self-test. Make a call between two networks (for example Wi-Fi and mobile data) with *Hide my IP address* on: the call screen must show *Relayed*. More tests: [`NETWORK_TESTING.md`](NETWORK_TESTING.md).

## Update

```bash
cd sotto
sudo ./infra/install.sh update
```

This pulls the latest code (`git pull --ff-only`), rebuilds, restarts and removes old images. Calls in progress drop during the restart (a few seconds).

## Other commands

```bash
sudo ./infra/install.sh status              # containers and health check
sudo ./infra/install.sh uninstall           # stop everything
sudo ./infra/install.sh uninstall --purge   # also delete the TLS certificates and .env
```

## Privacy policy and terms

Your server serves a privacy policy and terms of use at `https://<domain>/privacy.html` and `/terms.html`; the app (*Settings → Help*) and the guest page link to them. They describe exactly what Sotto processes, and name who runs the server: set it once with

```bash
sudo ./infra/install.sh install --domain calls.example.org --operator "Your Practice Ltd" --contact privacy@yourpractice.org
```

(kept in `infra/.env` as `SOTTO_OPERATOR` and `SOTTO_CONTACT`; later installs keep them). Without them the pages say "the operator of <domain>". The contact can be an email address or an `https://` link.

Two more settings are optional: `--support-email help@yourpractice.org` adds a support address, and `--support-link 'https://calls.example.org/#c=…'` adds a live support link (for example your own Sotto call link). They are kept as `SOTTO_SUPPORT_EMAIL` and `SOTTO_SUPPORT_LINK`, and the pages show them only when they are set. All these values are shown as plain text: markup is refused or escaped. If you put Sotto behind your own reverse proxy, keep its access logs off (`access_log off;` in Nginx, as in the configuration above), or the pages' "no request logs" is no longer true. Have them checked for your country's rules before you rely on them.

## Backups

There is nothing to back up on the server: it stores no user data. `infra/.env` holds the TURN secret; if it is lost, run the installer again and it creates a new one (the relay and coturn always share it).

Each professional backs up their own identity in the app (*Settings → Backup*).

## What the server sees

While running, the relay knows which Sotto IDs (public keys) are online and who sends encrypted messages to whom, and when (for a text chat, when two contacts set one up; the message text never reaches the relay); coturn sees the IP addresses of relayed calls. None of this is written to disk or logged, and it is gone after a restart. Self-hosting means only you run that server. Details: [`THREAT_MODEL.md`](THREAT_MODEL.md).

## Security notes

- Containers run read-only, without Linux capabilities (except Caddy binding ports 80/443), with `no-new-privileges`.
- coturn refuses to relay to private, loopback and other special networks, so the server can't be used to reach your internal network. It also refuses the server's own public address when it is behind NAT (`SOTTO_TURN_EXTERNAL_IP`). TCP relaying is off; there are per-user and total quotas and a bandwidth cap per session.
- TURN credentials are short-lived (6 hours) and handed out only to devices logged in to the relay.
- Keep the server updated (`unattended-upgrades` on Ubuntu/Debian) and run `install.sh update` when new Sotto versions are out.

## Troubleshooting

| Problem | Fix |
|---|---|
| The installer says the domain doesn't resolve | Create the A record, wait a few minutes (`getent hosts <domain>`), run it again |
| "Cloudflare proxy address" | Set the record to **DNS only** in Cloudflare, wait a few minutes |
| `health did not answer` | Ports 80/443 must be reachable from the internet (also in the provider's firewall). See `docker compose -f infra/docker-compose.yml logs web` |
| The build runs out of memory | Let the installer add swap, or use a server with more memory |
| Calls stay on *Connecting…* between different networks | UDP 3478 and 49152–65535 must be open (server and provider firewall). Test with *Hide my IP address* on |
| The app says "not a Sotto relay" | The domain serves something else on `/relay`; check that you entered the Sotto server's domain |
| Ports 80 or 443 are already in use by Nginx/Apache | Run the installer with `--behind-proxy [PORT]` to bind locally and proxy from your existing server |
| "--behind-proxy needs Docker Compose 2.24 or newer" | Update Docker from Docker's own repository (https://docs.docker.com/engine/install/); distribution packages are often older |
| Behind a proxy: "TURN over TLS … is off" | Get a certificate for the domain in your web server (e.g. `certbot --nginx -d <domain>`), then run the installer again; or pass `--tls-cert` and `--tls-key` |
| Need coturn's logs to debug | Temporarily remove `logging: driver: none` from the coturn service in `infra/docker-compose.yml`, run `docker compose up -d coturn`, then put it back: coturn logs IP addresses |
