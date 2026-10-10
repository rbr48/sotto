#!/usr/bin/env bash
# Sotto self-host installer: relay + web app (Caddy, automatic HTTPS) + coturn.
#
#   sudo ./infra/install.sh                      # interactive install
#   sudo ./infra/install.sh install --domain calls.example.org --yes
#   sudo ./infra/install.sh install --domain calls.example.org --behind-proxy [PORT] --yes
#   sudo ./infra/install.sh update               # pull the latest code and rebuild
#   sudo ./infra/install.sh status               # containers and health
#   sudo ./infra/install.sh uninstall [--purge]  # stop (and delete certificates)
#
# Options:
#   --domain NAME          the server's domain (its DNS A record must point here)
#   --external-ip IP       public IP if this server is behind NAT (detected otherwise)
#   --behind-proxy [PORT]  run behind an existing reverse proxy (e.g. Nginx); binds
#                          web to 127.0.0.1:PORT (default: 8185), leaves 80/443 alone,
#                          and prints the proxy config. Needs Docker Compose 2.24+
#   --tls-cert FILE        with --behind-proxy: the domain's certificate (full chain)
#   --tls-key FILE         and key, for TURN over TLS (port 5349). Found automatically
#                          when Certbot made them (/etc/letsencrypt/live/DOMAIN/)
#   --operator NAME        who runs this server (shown in its privacy policy and terms,
#                          /privacy.html and /terms.html; default: the domain)
#   --contact ADDRESS      how users reach the operator (an email address or URL)
#   --support-email ADDR   optional support address, shown on the same pages
#   --support-link URL     optional https:// link for live support (e.g. a Sotto
#                          call link), shown on the same pages
#   --yes                  don't ask; accept the defaults (install Docker, add swap,
#                          open firewall ports)
#   --no-firewall          don't touch ufw/firewalld
#   --skip-dns-check       install even if the domain doesn't point here yet
#   --dry-run              print what would be done, change nothing
#
# Nothing here sends data anywhere except to Docker's servers (images) and
# Let's Encrypt (certificate), and `update` fetches code with git.
set -euo pipefail

INFRA_DIR="${SOTTO_INFRA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
ENV_FILE="$INFRA_DIR/.env"
MEMINFO="${SOTTO_MEMINFO:-/proc/meminfo}"
SWAPFILE="${SOTTO_SWAPFILE:-/swapfile}"
HEALTH_TIMEOUT="${SOTTO_HEALTH_TIMEOUT:-300}"
LETSENCRYPT_DIR="${SOTTO_LETSENCRYPT_DIR:-/etc/letsencrypt}"
CRON_MARK='# sotto: restart coturn weekly to load renewed certificates'

COMMAND=install
DOMAIN=''
EXTERNAL_IP=''
BEHIND_PROXY=0
PROXY_PORT=8185
TLS_CERT=''
TLS_KEY=''
OPERATOR=''
CONTACT=''
SUPPORT_EMAIL=''
SUPPORT_LINK=''
ASSUME_YES=0
FIREWALL=1
DNS_CHECK=1
DRY_RUN=0
PURGE=0

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# Runs a command, or prints it with --dry-run.
run() {
  if [[ $DRY_RUN == 1 ]]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# Asks a yes/no question; --yes answers yes.
confirm() {
  local question=$1
  if [[ $ASSUME_YES == 1 ]]; then return 0; fi
  if [[ ! -t 0 ]]; then return 1; fi
  local answer
  read -r -p "$question [Y/n] " answer
  [[ -z $answer || $answer =~ ^[Yy] ]]
}

usage() {
  sed -n '2,/^set -euo pipefail/ { /^set /d; p }' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

parse_args() {
  if [[ $# -gt 0 && $1 != -* ]]; then
    COMMAND=$1
    shift
  fi
  while [[ $# -gt 0 ]]; do
    case $1 in
      --domain) DOMAIN=${2:-}; shift 2 ;;
      --external-ip) EXTERNAL_IP=${2:-}; shift 2 ;;
      --behind-proxy)
        BEHIND_PROXY=1
        if [[ $# -ge 2 && ${2:-} =~ ^[0-9]+$ ]]; then
          PROXY_PORT=$2
          shift 2
        else
          shift
        fi
        ;;
      --behind-proxy=*)
        BEHIND_PROXY=1
        PROXY_PORT="${1#*=}"
        [[ $PROXY_PORT =~ ^[0-9]+$ ]] || die "invalid port for --behind-proxy: $PROXY_PORT"
        shift
        ;;
      --tls-cert) TLS_CERT=${2:-}; shift 2 ;;
      --tls-key) TLS_KEY=${2:-}; shift 2 ;;
      --operator) OPERATOR=${2:-}; shift 2 ;;
      --contact) CONTACT=${2:-}; shift 2 ;;
      --support-email) SUPPORT_EMAIL=${2:-}; shift 2 ;;
      --support-link) SUPPORT_LINK=${2:-}; shift 2 ;;
      --yes | -y) ASSUME_YES=1; shift ;;
      --no-firewall) FIREWALL=0; shift ;;
      --skip-dns-check) DNS_CHECK=0; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --purge) PURGE=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
  done
  if (( PROXY_PORT < 1 || PROXY_PORT > 65535 )); then
    die "port must be between 1 and 65535: $PROXY_PORT"
  fi
  if [[ ($TLS_CERT || $TLS_KEY) && $BEHIND_PROXY == 0 ]]; then
    die '--tls-cert and --tls-key go with --behind-proxy (otherwise Caddy gets the certificate)'
  fi
  # Shown in web pages through Caddy templates: one plain line, no markup.
  local value
  for value in "$OPERATOR" "$CONTACT" "$SUPPORT_EMAIL" "$SUPPORT_LINK"; do
    if [[ $value == *$'\n'* || $value == *'{{'* || $value == *'<'* || ${#value} -gt 120 ]]; then
      die "--operator, --contact, --support-email and --support-link take one plain line of at most 120 characters"
    fi
  done
  if [[ -n $SUPPORT_EMAIL && $SUPPORT_EMAIL != *@* ]]; then
    die "--support-email needs an email address: $SUPPORT_EMAIL"
  fi
  if [[ -n $SUPPORT_LINK && $SUPPORT_LINK != https://* ]]; then
    die "--support-link needs an https:// link: $SUPPORT_LINK"
  fi
  case $COMMAND in
    install | update | status | uninstall) ;;
    *) die "unknown command: $COMMAND (install, update, status or uninstall)" ;;
  esac
}

compose() {
  local files=(-f "$INFRA_DIR/docker-compose.yml")
  if [[ -f "$INFRA_DIR/docker-compose.override.yml" || ($BEHIND_PROXY == 1 && $DRY_RUN == 1) ]]; then
    files+=(-f "$INFRA_DIR/docker-compose.override.yml")
  fi
  run docker compose --project-directory "$INFRA_DIR" "${files[@]}" "$@"
}

# --- checks -----------------------------------------------------------------

require_root() {
  if [[ $DRY_RUN == 1 || ${SOTTO_ALLOW_NONROOT:-0} == 1 ]]; then return; fi
  [[ $(id -u) == 0 ]] || die "run as root, for example: sudo $0 $COMMAND"
}

valid_domain() {
  [[ $1 =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

ask_domain() {
  if [[ -z $DOMAIN && -f $ENV_FILE ]]; then
    DOMAIN=$(sed -n 's/^SOTTO_DOMAIN=//p' "$ENV_FILE" | tail -n 1)
  fi
  if [[ $BEHIND_PROXY == 0 && -f $ENV_FILE ]]; then
    local saved_proxy
    saved_proxy=$(saved SOTTO_BEHIND_PROXY_PORT)
    if [[ -n $saved_proxy ]]; then
      BEHIND_PROXY=1
      PROXY_PORT=$saved_proxy
    fi
  fi
  if [[ -z $DOMAIN && -t 0 && $ASSUME_YES == 0 ]]; then
    read -r -p 'Domain for this Sotto server (e.g. calls.example.org): ' DOMAIN
  fi
  [[ -n $DOMAIN ]] || die 'no domain given (use --domain)'
  DOMAIN=${DOMAIN,,}
  valid_domain "$DOMAIN" || die "not a valid domain name: $DOMAIN"
  # The certificate saved in .env is for the domain it was saved with: after a
  # change of domain, look for the new domain's.
  if [[ $BEHIND_PROXY == 1 && -z $TLS_CERT && -z $TLS_KEY && -f $ENV_FILE &&
    $(saved SOTTO_DOMAIN) == "$DOMAIN" ]]; then
    TLS_CERT=$(saved SOTTO_TLS_CERT)
    TLS_KEY=$(saved SOTTO_TLS_KEY)
    if [[ -n $TLS_CERT && ! -r $TLS_CERT ]] || [[ -n $TLS_KEY && ! -r $TLS_KEY ]]; then
      warn "the TLS certificate saved in .env ($TLS_CERT) is gone; looking for another one"
      TLS_CERT='' TLS_KEY=''
    fi
  fi
}

# A value saved in .env.
saved() {
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1
}

# Behind a proxy, Caddy has no certificate for coturn's TURN over TLS: use the
# proxy's (Certbot's, if not given).
find_tls_cert() {
  [[ $BEHIND_PROXY == 1 ]] || return 0
  step 'Looking for the TLS certificate for TURN over TLS'
  if [[ -z $TLS_CERT && -z $TLS_KEY ]]; then
    local live="$LETSENCRYPT_DIR/live/$DOMAIN"
    if [[ -r $live/fullchain.pem && -r $live/privkey.pem ]]; then
      TLS_CERT=$live/fullchain.pem
      TLS_KEY=$live/privkey.pem
    fi
  fi
  if [[ -z $TLS_CERT && -z $TLS_KEY ]]; then
    warn "no certificate for $DOMAIN found (looked in $LETSENCRYPT_DIR/live/$DOMAIN/): TURN over TLS (port 5349) stays off. Calls still work; networks that only allow HTTPS can't connect. Once your proxy has a certificate, run this again (or pass --tls-cert and --tls-key)."
    return 0
  fi
  [[ -n $TLS_CERT && -n $TLS_KEY ]] || die 'give both --tls-cert and --tls-key'
  local file
  for file in "$TLS_CERT" "$TLS_KEY"; do
    [[ $file == /* ]] || die "use an absolute path: $file"
    # Paths go into docker-compose.override.yml as volumes.
    [[ $file != *[\'\":$'\n']* ]] || die "unsupported characters in path: $file"
    [[ -r $file ]] || die "can't read $file"
  done
  say "OK: $TLS_CERT"
}

# Directories coturn needs to read the certificate and key, including where
# symbolic links point (Certbot's live/ links into archive/).
tls_dirs() {
  local file
  for file in "$TLS_CERT" "$TLS_KEY"; do
    dirname -- "$file"
    dirname -- "$(readlink -f -- "$file")"
  done | sort -u
}

# Whether coturn can offer TURN over TLS: Caddy's certificate, or the proxy's.
turn_tls() {
  [[ $BEHIND_PROXY == 0 || -n $TLS_CERT ]]
}

# IPv4 addresses the domain resolves to.
resolved_ips() {
  getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u
}

# IPv4 addresses on this machine's interfaces.
local_ips() {
  ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u
}

# Cloudflare's proxy ranges (IPv4): with the orange cloud on, TURN can't work
# and Cloudflare would see all signaling traffic.
is_cloudflare_ip() {
  case $1 in
    104.1[6-9].* | 104.2[0-9].* | 104.3[01].* | 172.6[4-9].* | 172.7[01].* | 188.114.9[6-9].* | \
      162.158.* | 141.101.* | 108.162.* | 190.93.* | 197.234.* | 198.41.* | 173.245.* | 103.21.* | 103.22.* | 103.31.* | 131.0.7[2-5].*)
      return 0 ;;
  esac
  return 1
}

check_dns() {
  step "Checking that $DOMAIN points to this server"
  local resolved locals ip
  resolved=$(resolved_ips "$DOMAIN")
  locals=$(local_ips)
  if [[ -z $resolved ]]; then
    [[ $DNS_CHECK == 1 ]] || { warn "$DOMAIN does not resolve yet (continuing: --skip-dns-check)"; return; }
    die "$DOMAIN does not resolve. Create an A record pointing to this server's public IP, wait a few minutes, then run this again."
  fi
  for ip in $resolved; do
    if is_cloudflare_ip "$ip"; then
      die "$DOMAIN resolves to $ip, a Cloudflare proxy address. In Cloudflare's DNS settings, set this record to \"DNS only\" (grey cloud): calls can't connect through the proxy, and it would see all traffic."
    fi
  done
  for ip in $resolved; do
    if grep -qxF "$ip" <<<"$locals"; then
      say "OK: $DOMAIN -> $ip (on this server)"
      return
    fi
  done
  # Not on an interface: a cloud server behind 1:1 NAT (AWS, GCP, Oracle...)
  # or the wrong server.
  ip=$(head -n 1 <<<"$resolved")
  if [[ -z $EXTERNAL_IP ]]; then
    say "$DOMAIN resolves to $ip, which is not on any network interface here."
    say 'That is normal for cloud servers behind NAT; otherwise the record points to another server.'
    if confirm "Is $ip this server's public IP?"; then
      EXTERNAL_IP=$ip
    elif [[ $DNS_CHECK == 1 ]]; then
      die "point $DOMAIN to this server, or pass --external-ip"
    fi
  fi
}

check_docker() {
  step 'Checking Docker'
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    say "OK: $(docker --version)"
    if [[ $BEHIND_PROXY == 1 ]]; then check_compose_version; fi
    return
  fi
  confirm 'Docker (with the Compose plugin) is not installed. Install it now from get.docker.com?' ||
    die 'install Docker first: https://docs.docker.com/engine/install/'
  run sh -c 'curl -fsSL https://get.docker.com | sh'
}

# The override written for --behind-proxy replaces the web ports with
# `!override`, which Docker Compose understands from version 2.24.0.
check_compose_version() {
  local version major minor
  version=$(docker compose version --short 2>/dev/null || true)
  version=${version#v}
  if [[ ! $version =~ ^([0-9]+)\.([0-9]+) ]]; then
    warn "couldn't tell the Docker Compose version (${version:-none}); --behind-proxy needs 2.24 or newer"
    return
  fi
  major=${BASH_REMATCH[1]}
  minor=${BASH_REMATCH[2]}
  if ((major < 2 || (major == 2 && minor < 24))); then
    die "--behind-proxy needs Docker Compose 2.24 or newer; this server has $version. Update Docker (https://docs.docker.com/engine/install/), then run this again."
  fi
}

# The web app is compiled on the server; Flutter needs about 2.5 GB of memory.
check_memory() {
  step 'Checking memory'
  local mem_kb swap_kb
  mem_kb=$(awk '/^MemTotal:/ {print $2}' "$MEMINFO")
  swap_kb=$(awk '/^SwapTotal:/ {print $2}' "$MEMINFO")
  if (((mem_kb + swap_kb) >= 2500000)); then
    say "OK: $((mem_kb / 1024)) MB memory, $((swap_kb / 1024)) MB swap"
    return
  fi
  warn "only $((mem_kb / 1024)) MB memory and $((swap_kb / 1024)) MB swap: building the web app needs about 2.5 GB"
  # An existing but inactive /swapfile isn't ours to change: use our own.
  local swapfile=$SWAPFILE
  if [[ -e $swapfile ]]; then swapfile="$SWAPFILE-sotto"; fi
  if [[ -e $swapfile ]]; then
    warn "$swapfile exists but no swap is active; run 'swapon $swapfile' if the build runs out of memory"
    return
  fi
  if confirm "Add a 2 GB swap file ($swapfile)?"; then
    run fallocate -l 2G "$swapfile"
    run chmod 600 "$swapfile"
    run mkswap "$swapfile"
    run swapon "$swapfile"
    if ! grep -q "^$swapfile " /etc/fstab 2>/dev/null; then
      run sh -c "echo '$swapfile none swap sw 0 0' >> /etc/fstab"
    fi
  else
    warn 'continuing without swap; the build may run out of memory'
  fi
}

open_firewall() {
  [[ $FIREWALL == 1 ]] || return 0
  step 'Opening firewall ports'
  local tcp=(3478) udp=(3478)
  if turn_tls; then tcp+=(5349); fi
  if [[ $BEHIND_PROXY == 0 ]]; then
    tcp=(80 443 "${tcp[@]}")
    udp=(443 "${udp[@]}")
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    local port
    for port in "${tcp[@]}"; do run ufw allow "$port/tcp"; done
    for port in "${udp[@]}"; do run ufw allow "$port/udp"; done
    run ufw allow 49152:65535/udp
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    local port
    for port in "${tcp[@]}"; do run firewall-cmd --permanent --add-port="$port/tcp"; done
    for port in "${udp[@]}"; do run firewall-cmd --permanent --add-port="$port/udp"; done
    run firewall-cmd --permanent --add-port=49152-65535/udp
    run firewall-cmd --reload
  else
    say 'No active ufw or firewalld found; nothing to change here.'
  fi
  say "If your hosting provider has its own firewall, open there too: TCP ${tcp[*]}, UDP ${udp[*]} and UDP 49152-65535."
}

# --- configuration ------------------------------------------------------------

new_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

write_env() {
  step "Writing $ENV_FILE"
  local secret=''
  if [[ -f $ENV_FILE ]]; then
    secret=$(sed -n 's/^SOTTO_TURN_SECRET=//p' "$ENV_FILE" | tail -n 1)
  fi
  if [[ -z $secret ]]; then secret=$(new_secret); fi
  # Keep the operator details from an earlier install unless new ones are given.
  if [[ -f $ENV_FILE ]]; then
    [[ -n $OPERATOR ]] || OPERATOR=$(saved SOTTO_OPERATOR)
    [[ -n $CONTACT ]] || CONTACT=$(saved SOTTO_CONTACT)
    [[ -n $SUPPORT_EMAIL ]] || SUPPORT_EMAIL=$(saved SOTTO_SUPPORT_EMAIL)
    [[ -n $SUPPORT_LINK ]] || SUPPORT_LINK=$(saved SOTTO_SUPPORT_LINK)
  fi
  local content
  content="# Written by install.sh. The TURN secret is shared by the relay and coturn.
SOTTO_DOMAIN=$DOMAIN
SOTTO_TURN_SECRET=$secret"
  if [[ -n $EXTERNAL_IP ]]; then
    content+="
SOTTO_TURN_EXTERNAL_IP=$EXTERNAL_IP"
  fi
  if [[ -n $OPERATOR ]]; then
    content+="
SOTTO_OPERATOR=$OPERATOR"
  fi
  if [[ -n $CONTACT ]]; then
    content+="
SOTTO_CONTACT=$CONTACT"
  fi
  if [[ -n $SUPPORT_EMAIL ]]; then
    content+="
SOTTO_SUPPORT_EMAIL=$SUPPORT_EMAIL"
  fi
  if [[ -n $SUPPORT_LINK ]]; then
    content+="
SOTTO_SUPPORT_LINK=$SUPPORT_LINK"
  fi
  local proxy=''
  if [[ $BEHIND_PROXY == 1 ]]; then
    proxy="SOTTO_BEHIND_PROXY_PORT=$PROXY_PORT"
    content+="
$proxy"
    if [[ -n $TLS_CERT ]]; then
      content+="
SOTTO_TLS_CERT=$TLS_CERT
SOTTO_TLS_KEY=$TLS_KEY"
    fi
  fi
  if [[ $DRY_RUN == 1 ]]; then
    say "[dry-run] would write $ENV_FILE (SOTTO_DOMAIN=$DOMAIN${EXTERNAL_IP:+, SOTTO_TURN_EXTERNAL_IP=$EXTERNAL_IP}${proxy:+, $proxy})"
    return
  fi
  (
    umask 077
    printf '%s\n' "$content" >"$ENV_FILE"
  )
  say "OK (kept private: mode 600)"
}

write_override() {
  local override_file="$INFRA_DIR/docker-compose.override.yml"
  if [[ $BEHIND_PROXY == 1 ]]; then
    step "Writing $override_file (binding web to 127.0.0.1:$PROXY_PORT)"
    local content="# Generated by install.sh --behind-proxy; rewritten by each install.
services:
  web:
    environment:
      SOTTO_DOMAIN: :80
      # The proxy reaches Caddy from Docker's network: trust its
      # X-Forwarded-For, so the relay sees each client's address.
      SOTTO_TRUSTED_PROXIES: private_ranges
    ports: !override
      - '127.0.0.1:$PROXY_PORT:80'"
    if [[ -n $TLS_CERT ]]; then
      content+="
  coturn:
    environment:
      # The proxy's certificate, for TURN over TLS (port 5349).
      SOTTO_TLS_CERT: '$TLS_CERT'
      SOTTO_TLS_KEY: '$TLS_KEY'
    volumes:"
      local dir
      while IFS= read -r dir; do
        content+="
      - '$dir:$dir:ro'"
      done < <(tls_dirs)
    else
      content+="
  relay:
    environment:
      # No certificate for coturn, so no TURN over TLS (turns:, port 5349).
      SOTTO_TURN_URLS: 'turn:$DOMAIN:3478?transport=udp,turn:$DOMAIN:3478?transport=tcp'"
    fi
    if [[ $DRY_RUN == 1 ]]; then
      say "[dry-run] would write $override_file"
      return
    fi
    printf '%s\n' "$content" >"$override_file"
    say "OK"
  fi
}

# coturn reads the TLS certificate only at start; restart it weekly so it
# picks up Caddy's renewals.
install_cron() {
  local line="17 4 * * 1 docker compose --project-directory $INFRA_DIR restart coturn >/dev/null 2>&1 $CRON_MARK"
  if crontab -l 2>/dev/null | grep -qF "$CRON_MARK"; then return; fi
  if [[ $DRY_RUN == 1 ]]; then
    say "[dry-run] would add to root's crontab: $line"
    return
  fi
  { crontab -l 2>/dev/null || true; printf '%s\n' "$line"; } | crontab -
}

remove_cron() {
  if ! crontab -l 2>/dev/null | grep -qF "$CRON_MARK"; then return; fi
  if [[ $DRY_RUN == 1 ]]; then
    say '[dry-run] would remove the coturn restart from crontab'
    return
  fi
  { crontab -l 2>/dev/null | grep -vF "$CRON_MARK" || true; } | crontab -
}

wait_for_health() {
  local url="https://$DOMAIN/health"
  local label="HTTPS"
  if [[ $BEHIND_PROXY == 1 ]]; then
    url="http://127.0.0.1:$PROXY_PORT/health"
    label="local proxy port (127.0.0.1:$PROXY_PORT)"
  fi
  step "Waiting for $url"
  if [[ $DRY_RUN == 1 ]]; then
    say '[dry-run] would wait for the health check'
    return 0
  fi
  local waited=0
  until curl -fsS --max-time 5 "$url" >/dev/null 2>&1; do
    if ((waited >= HEALTH_TIMEOUT)); then
      warn "$url did not answer within ${HEALTH_TIMEOUT}s. Check: docker compose -f $INFRA_DIR/docker-compose.yml logs web"
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  say "OK: the server answers over $label"
}

# --- commands ---------------------------------------------------------------

cmd_install() {
  require_root
  ask_domain
  find_tls_cert
  check_dns
  check_docker
  check_memory
  open_firewall
  write_env
  write_override
  step 'Building and starting (the first build takes 5-15 minutes)'
  compose up -d --build
  if wait_for_health; then
    # coturn can also offer TURN over TLS (port 5349).
    compose restart coturn
  fi
  install_cron
  if [[ $BEHIND_PROXY == 1 ]]; then
    local tls_note=''
    if ! turn_tls; then
      tls_note="  - TURN over TLS (port 5349) is off until this server has a certificate
    for $DOMAIN: get one for the proxy, then run this installer again.
"
    fi
    cat <<EOF

Sotto is running locally on 127.0.0.1:$PROXY_PORT.

To complete setup, configure your reverse proxy (e.g. Nginx):

server {
    server_name $DOMAIN;
    listen 443 ssl http2;
    # Your certificate, for example from: certbot --nginx -d $DOMAIN
    ssl_certificate     ${TLS_CERT:-/etc/letsencrypt/live/$DOMAIN/fullchain.pem};
    ssl_certificate_key ${TLS_KEY:-/etc/letsencrypt/live/$DOMAIN/privkey.pem};

    # Sotto keeps no request logs; don't let the proxy keep them either
    # (they would hold every visitor's IP address).
    access_log off;

    location / {
        proxy_pass http://127.0.0.1:$PROXY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        # Only the client's own address (Sotto limits connections per address).
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}

Once your proxy is reloaded:
${tls_note}  - Professionals: in the Sotto app, open Settings -> Server -> "Use another
    server" and enter: $DOMAIN
  - Guests open the guest links the app creates; they point to this server.
  - Update later with:  sudo $0 update
  - The server keeps no user data; see docs/SELF_HOSTING.md.
EOF
  else
    cat <<EOF

Sotto is running at https://$DOMAIN/

  - Professionals: in the Sotto app, open Settings -> Server -> "Use another
    server" and enter: $DOMAIN
  - Guests open the guest links the app creates; they point to this server.
  - Update later with:  sudo $0 update
  - The server keeps no user data; see docs/SELF_HOSTING.md.
EOF
  fi
}

cmd_update() {
  require_root
  [[ -f $ENV_FILE ]] || die "not installed yet (no $ENV_FILE); run: sudo $0 install"
  DOMAIN=$(sed -n 's/^SOTTO_DOMAIN=//p' "$ENV_FILE" | tail -n 1)
  local saved_proxy
  saved_proxy=$(saved SOTTO_BEHIND_PROXY_PORT)
  if [[ -n $saved_proxy ]]; then
    BEHIND_PROXY=1
    PROXY_PORT=$saved_proxy
  fi
  step 'Fetching the latest version'
  if git -C "$INFRA_DIR/.." rev-parse --git-dir >/dev/null 2>&1; then
    run git -C "$INFRA_DIR/.." pull --ff-only
  else
    warn 'not a git checkout; rebuilding the current files'
  fi
  step 'Rebuilding and restarting'
  compose up -d --build
  run docker image prune -f
  if wait_for_health; then compose restart coturn; fi
  say 'Updated.'
}

cmd_status() {
  compose ps
  if [[ -f $ENV_FILE ]]; then
    DOMAIN=$(sed -n 's/^SOTTO_DOMAIN=//p' "$ENV_FILE" | tail -n 1)
    local saved_proxy
    saved_proxy=$(saved SOTTO_BEHIND_PROXY_PORT)
    if [[ -n $saved_proxy ]]; then
      if curl -fsS --max-time 5 "http://127.0.0.1:$saved_proxy/health" >/dev/null 2>&1; then
        say "http://127.0.0.1:$saved_proxy/health: OK"
      else
        say "http://127.0.0.1:$saved_proxy/health: not answering"
      fi
    fi
    if curl -fsS --max-time 5 "https://$DOMAIN/health" >/dev/null 2>&1; then
      say "https://$DOMAIN/health: OK"
    else
      say "https://$DOMAIN/health: not answering"
    fi
  fi
}

cmd_uninstall() {
  require_root
  if [[ $PURGE == 1 ]]; then
    compose down --volumes
    if [[ $DRY_RUN == 1 ]]; then
      say "[dry-run] would delete $ENV_FILE and docker-compose.override.yml"
    else
      rm -f "$ENV_FILE" "$INFRA_DIR/docker-compose.override.yml"
    fi
  else
    compose down
  fi
  remove_cron
  say 'Stopped. (The server never stored user data; --purge also deletes the TLS certificates and .env.)'
}

main() {
  parse_args "$@"
  case $COMMAND in
    install) cmd_install ;;
    update) cmd_update ;;
    status) cmd_status ;;
    uninstall) cmd_uninstall ;;
  esac
}

main "$@"
