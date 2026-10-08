# sottocall.com

The public website: what Sotto is, downloads, privacy. Plain static files with
no build step, no trackers, no cookies, and nothing loaded from other sites.

- `index.html`: the page (styles inline)
- `icon.svg`, `wordmark*.svg`, `favicon.png`, `apple-touch-icon.png`: copied
  from `docs/brand/` and `app/web/` (regenerate with `tools/icons/generate.py`)

Download buttons point to `https://github.com/rbr48/sotto/releases/latest/download/<file>`,
so the site never needs updating for a new release. The app itself runs at
`call.sottocall.com`.

## Publish on the server (Nginx)

The repository is already on the server (`~/sotto`); `git pull` updates the site.

1. DNS: `A` records for `sottocall.com` and `www` → the server's IP (DNS only, no proxy).
2. Nginx site, for example `/etc/nginx/sites-available/sottocall.com`:

   ```nginx
   server {
       server_name sottocall.com www.sottocall.com;
       listen 80;
       root /home/<user>/sotto/website;   # the clone's website/ folder
       index index.html;

       access_log off;                    # the site promises no tracking
       add_header Referrer-Policy "no-referrer" always;
       add_header X-Content-Type-Options "nosniff" always;
       add_header Content-Security-Policy "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" always;

       location ~ /\. { deny all; }
       location = /README.md { deny all; }
   }
   ```

   Nginx must be able to read the folder: `sudo chmod o+x /home/<user> /home/<user>/sotto`
   (or copy the files to `/var/www/sottocall.com` and use that as `root`).
3. `sudo ln -s /etc/nginx/sites-available/sottocall.com /etc/nginx/sites-enabled/`
4. `sudo certbot --nginx -d sottocall.com -d www.sottocall.com` (adds HTTPS and the redirect)
5. `sudo nginx -t && sudo systemctl reload nginx`
