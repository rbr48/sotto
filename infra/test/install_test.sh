#!/usr/bin/env bash
# The stubs are written in single quotes on purpose: they expand when run.
# shellcheck disable=SC2016
# Tests infra/install.sh with stub commands (docker, DNS, firewall, cron), so
# nothing on this machine changes.   bash infra/test/install_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="$HERE/../install.sh"
FAILED=0
WORK=''

setup() {
  WORK=$(mktemp -d)
  mkdir -p "$WORK/infra" "$WORK/bin"
  cp "$HERE/../docker-compose.yml" "$WORK/infra/"
  : >"$WORK/log"
  : >"$WORK/crontab"
  printf 'MemTotal:       4000000 kB\nSwapTotal:      0 kB\n' >"$WORK/meminfo"
  RESOLVES_TO=203.0.113.10
  LOCAL_IP=203.0.113.10
  COMPOSE_VERSION=2.29.1
  stub docker 'echo "docker $*" >>"$WORK/log"
[[ "$*" == "--version" ]] && echo "Docker version 27"
[[ "$*" == "compose version --short" ]] && echo "${COMPOSE_VERSION:-2.29.1}"
exit 0'
  stub getent '[[ -n "${RESOLVES_TO:-}" ]] && echo "$RESOLVES_TO STREAM $3"; exit 0'
  stub ip 'echo "2: eth0    inet ${LOCAL_IP}/24 brd x scope global eth0"'
  stub ufw 'echo "ufw $*" >>"$WORK/log"; [[ "$1" == status ]] && echo "Status: active"; exit 0'
  stub curl 'echo "curl $*" >>"$WORK/log"; exit 0'
  stub crontab 'if [[ "${1:-}" == -l ]]; then cat "$WORK/crontab"; else cat >"$WORK/crontab"; fi'
  stub git 'echo "git $*" >>"$WORK/log"; exit 1'
  for cmd in fallocate mkswap swapon firewall-cmd; do stub "$cmd" "echo \"$cmd \$*\" >>\"\$WORK/log\""; done
}

stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$WORK/bin/$1"
  chmod +x "$WORK/bin/$1"
}

installer() {
  env PATH="$WORK/bin:$PATH" WORK="$WORK" RESOLVES_TO="$RESOLVES_TO" LOCAL_IP="$LOCAL_IP" \
    COMPOSE_VERSION="$COMPOSE_VERSION" \
    SOTTO_INFRA_DIR="$WORK/infra" SOTTO_MEMINFO="$WORK/meminfo" SOTTO_ALLOW_NONROOT=1 \
    SOTTO_SWAPFILE="$WORK/swapfile" SOTTO_LETSENCRYPT_DIR="$WORK/letsencrypt" \
    SOTTO_HEALTH_TIMEOUT=5 bash "$INSTALL" "$@" </dev/null
}

check() {
  local name=$1
  shift
  if "$@"; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name"
    FAILED=1
  fi
}

has() { grep -qF -- "$2" "$1"; }

# 1. A fresh install.
setup
out=$(installer install --domain Calls.Example.org --yes 2>&1) || true
env_file="$WORK/infra/.env"
check 'writes .env with the domain (lowercased)' has "$env_file" 'SOTTO_DOMAIN=calls.example.org'
check 'generates a 64-hex-digit TURN secret' grep -qE '^SOTTO_TURN_SECRET=[0-9a-f]{64}$' "$env_file"
if [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]]; then
  check '.env is private (mode 600)' true
else
  check '.env is private (mode 600)' test "$(stat -c %a "$env_file")" = 600
fi
check 'no external IP when the domain points to an interface' bash -c "! grep -q EXTERNAL_IP '$env_file'"
check 'builds and starts the containers' has "$WORK/log" 'up -d --build'
check 'restarts coturn after HTTPS works (TURN over TLS)' has "$WORK/log" 'restart coturn'
check 'checks health over HTTPS' has "$WORK/log" 'https://calls.example.org/health'
check 'opens TURN relay ports in ufw' has "$WORK/log" 'ufw allow 49152:65535/udp'
check 'opens HTTPS in ufw' has "$WORK/log" 'ufw allow 443/tcp'
check 'opens TURN over TLS in ufw' has "$WORK/log" 'ufw allow 5349/tcp'
check 'no override file without --behind-proxy' test ! -e "$WORK/infra/docker-compose.override.yml"
check 'adds the weekly coturn restart' has "$WORK/crontab" 'sotto: restart coturn weekly'
check 'tells the user how to point the app at the server' grep -q 'Use another' <<<"$out"
secret=$(grep SOTTO_TURN_SECRET "$env_file")

# 2. Running it again keeps the secret and doesn't duplicate the cron job.
installer install --yes >/dev/null 2>&1
check 'reinstall keeps the TURN secret' has "$env_file" "$secret"
check 'reinstall keeps the domain from .env' has "$env_file" 'SOTTO_DOMAIN=calls.example.org'
check 'cron job added only once' test "$(grep -c 'sotto: restart coturn' "$WORK/crontab")" = 1
rm -rf "$WORK"

# 3. Cloudflare's proxy is refused with an explanation.
setup
RESOLVES_TO=104.21.33.7
out=$(installer install --domain calls.example.org --yes 2>&1) && status=0 || status=$?
check 'refuses a Cloudflare-proxied domain' test "$status" != 0
check 'explains "DNS only"' grep -q 'DNS only' <<<"$out"
check 'nothing started' bash -c "! grep -q 'up -d --build' '$WORK/log'"
rm -rf "$WORK"

# 4. Behind NAT: the resolved IP becomes coturn's external IP.
setup
RESOLVES_TO=198.51.100.20
LOCAL_IP=10.0.0.5
installer install --domain calls.example.org --yes >/dev/null 2>&1
check 'NAT: sets SOTTO_TURN_EXTERNAL_IP' has "$WORK/infra/.env" 'SOTTO_TURN_EXTERNAL_IP=198.51.100.20'
rm -rf "$WORK"

# 5. A domain that doesn't resolve, an invalid domain, an unknown option.
setup
RESOLVES_TO=''
out=$(installer install --domain calls.example.org --yes 2>&1) && status=0 || status=$?
check 'refuses a domain that does not resolve' test "$status" != 0
check '... explains the A record' grep -q 'A record' <<<"$out"
installer install --domain calls.example.org --yes --skip-dns-check >/dev/null 2>&1 && status=0 || status=$?
check '--skip-dns-check installs anyway' test "$status" = 0
out=$(installer install --domain 'not a domain' --yes 2>&1) && status=0 || status=$?
check 'refuses an invalid domain' test "$status" != 0
out=$(installer install --bogus 2>&1) && status=0 || status=$?
check 'refuses unknown options' test "$status" != 0
rm -rf "$WORK"

# 6. Little memory: swap is added (shown with --dry-run, which changes nothing).
#    The swap path is redirected into the test directory, so the host's own
#    /swapfile (GitHub's runners have one) doesn't matter.
setup
printf 'MemTotal:       1000000 kB\nSwapTotal:      0 kB\n' >"$WORK/meminfo"
out=$(installer install --domain calls.example.org --yes --dry-run 2>&1) || true
check 'low memory: offers a 2 GB swap file' grep -q "fallocate -l 2G $WORK/swapfile" <<<"$out"
: >"$WORK/swapfile" # an existing, inactive swap file that isn't ours
out=$(installer install --domain calls.example.org --yes --dry-run 2>&1) || true
check 'an existing swap file is left alone; a separate one is used' grep -q "fallocate -l 2G $WORK/swapfile-sotto" <<<"$out"
check 'dry run writes no .env' test ! -e "$WORK/infra/.env"
check 'dry run starts nothing' bash -c "! grep -q 'up -d --build' '$WORK/log'"
check 'dry run leaves cron alone' test ! -s "$WORK/crontab"
check 'dry run mentions no proxy port without --behind-proxy' bash -c "! grep -q BEHIND_PROXY <<<\"\$1\"" _ "$out"
rm -rf "$WORK"

# 7. Update, status, uninstall.
setup
installer install --domain calls.example.org --yes --no-firewall >/dev/null 2>&1
check '--no-firewall leaves ufw alone' bash -c "! grep -q 'ufw allow' '$WORK/log'"
: >"$WORK/log"
installer update >/dev/null 2>&1
check 'update rebuilds' has "$WORK/log" 'up -d --build'
check 'update prunes old images' has "$WORK/log" 'image prune -f'
out=$(installer status 2>&1) || true
check 'status reports health' grep -q 'health: OK' <<<"$out"
installer uninstall --purge >/dev/null 2>&1
check 'uninstall --purge removes containers and volumes' has "$WORK/log" 'down --volumes'
check 'uninstall --purge deletes .env' test ! -e "$WORK/infra/.env"
check 'uninstall removes the cron job' bash -c "! grep -q sotto '$WORK/crontab'"
rm -rf "$WORK"

# 8. Shared-server mode (--behind-proxy).
setup
out=$(installer install --domain calls.example.org --yes --behind-proxy 8185 2>&1) || true
check 'behind-proxy writes SOTTO_BEHIND_PROXY_PORT' has "$WORK/infra/.env" 'SOTTO_BEHIND_PROXY_PORT=8185'
check 'writes docker-compose.override.yml' test -f "$WORK/infra/docker-compose.override.yml"
check 'override binds web to 127.0.0.1:8185' has "$WORK/infra/docker-compose.override.yml" '127.0.0.1:8185:80'
check 'override sets site to :80' has "$WORK/infra/docker-compose.override.yml" 'SOTTO_DOMAIN: :80'
check 'compose command includes override file' has "$WORK/log" 'docker-compose.override.yml'
check 'does not open port 80 in ufw' bash -c "! grep -q 'ufw allow 80/tcp' '$WORK/log'"
check 'does not open port 443 in ufw' bash -c "! grep -q 'ufw allow 443/tcp' '$WORK/log'"
check 'opens TURN ports in ufw' has "$WORK/log" 'ufw allow 3478/tcp'
check 'checks health on local port' has "$WORK/log" 'http://127.0.0.1:8185/health'
check 'prints proxy configuration advice' grep -q 'proxy_pass http://127.0.0.1:8185;' <<<"$out"
override="$WORK/infra/docker-compose.override.yml"
check 'Caddy trusts the proxy for client addresses' has "$override" 'SOTTO_TRUSTED_PROXIES: private_ranges'
check 'the proxy passes only the client address' grep -qF 'X-Forwarded-For $remote_addr;' <<<"$out"
check 'checks the Compose version (needs 2.24 for !override)' has "$WORK/log" 'compose version --short'
check 'no certificate: TURN over TLS is not offered' has "$override" "SOTTO_TURN_URLS: 'turn:calls.example.org:3478?transport=udp,turn:calls.example.org:3478?transport=tcp'"
check 'no certificate: port 5349 stays closed' bash -c "! grep -q 'ufw allow 5349/tcp' '$WORK/log'"
check 'no certificate: says how to turn on TURN over TLS' grep -q 'TURN over TLS (port 5349) is off' <<<"$out"

# Re-running install keeps behind-proxy settings from .env
installer install --yes >/dev/null 2>&1
check 'reinstall preserves behind-proxy port' has "$WORK/infra/.env" 'SOTTO_BEHIND_PROXY_PORT=8185'

# Custom port and uninstall --purge cleans override file
installer install --domain calls.example.org --yes --behind-proxy 9000 >/dev/null 2>&1
check 'custom port used in override' has "$WORK/infra/docker-compose.override.yml" '127.0.0.1:9000:80'
installer uninstall --purge >/dev/null 2>&1
check 'uninstall --purge deletes override file' test ! -e "$WORK/infra/docker-compose.override.yml"
rm -rf "$WORK"

# 9. Behind a proxy with Certbot's certificate: coturn uses it for TURN over TLS.
setup
le="$WORK/letsencrypt"
mkdir -p "$le/archive/calls.example.org" "$le/live/calls.example.org"
: >"$le/archive/calls.example.org/fullchain1.pem"
: >"$le/archive/calls.example.org/privkey1.pem"
ln -s ../../archive/calls.example.org/fullchain1.pem "$le/live/calls.example.org/fullchain.pem"
ln -s ../../archive/calls.example.org/privkey1.pem "$le/live/calls.example.org/privkey.pem"
out=$(installer install --domain calls.example.org --yes --behind-proxy 2>&1) || true
override="$WORK/infra/docker-compose.override.yml"
check 'finds Certbot'"'"'s certificate' has "$override" "SOTTO_TLS_CERT: '$le/live/calls.example.org/fullchain.pem'"
check '... and key' has "$override" "SOTTO_TLS_KEY: '$le/live/calls.example.org/privkey.pem'"
check 'mounts the live directory for coturn' has "$override" "- '$le/live/calls.example.org:$le/live/calls.example.org:ro'"
check 'mounts the archive directory the links point to' has "$override" "- '$le/archive/calls.example.org:$le/archive/calls.example.org:ro'"
check 'keeps offering TURN over TLS' bash -c "! grep -q SOTTO_TURN_URLS '$override'"
check 'opens port 5349' has "$WORK/log" 'ufw allow 5349/tcp'
check 'saves the certificate path in .env' has "$WORK/infra/.env" "SOTTO_TLS_CERT=$le/live/calls.example.org/fullchain.pem"
check 'nginx example uses the same certificate' grep -qF "ssl_certificate     $le/live/calls.example.org/fullchain.pem;" <<<"$out"
# Moving to another domain: its own certificate, not the one saved for the old one.
mkdir -p "$le/live/call.example.net"
: >"$le/live/call.example.net/fullchain.pem"
: >"$le/live/call.example.net/privkey.pem"
installer install --domain call.example.net --yes >/dev/null 2>&1 || true
check 'new domain: uses its own certificate' has "$WORK/infra/.env" "SOTTO_TLS_CERT=$le/live/call.example.net/fullchain.pem"
check 'new domain: keeps the proxy port' has "$WORK/infra/.env" 'SOTTO_BEHIND_PROXY_PORT='
check 'new domain: TURN uses the new name' has "$WORK/infra/.env" 'SOTTO_DOMAIN=call.example.net'
installer install --yes >/dev/null 2>&1 || true
check 'reinstall keeps the new certificate' has "$WORK/infra/.env" "SOTTO_TLS_CERT=$le/live/call.example.net/fullchain.pem"
rm -rf "$WORK"

# 10. Behind a proxy: certificate options, and an old Docker Compose.
setup
mkdir -p "$WORK/tls"
: >"$WORK/tls/cert.pem"
: >"$WORK/tls/key.pem"
installer install --domain calls.example.org --yes --behind-proxy \
  --tls-cert "$WORK/tls/cert.pem" --tls-key "$WORK/tls/key.pem" >/dev/null 2>&1 || true
check '--tls-cert/--tls-key are used' has "$WORK/infra/docker-compose.override.yml" "- '$WORK/tls:$WORK/tls:ro'"
installer install --yes >/dev/null 2>&1 || true
check 'reinstall keeps the given certificate' has "$WORK/infra/docker-compose.override.yml" "SOTTO_TLS_CERT: '$WORK/tls/cert.pem'"
out=$(installer install --domain calls.example.org --yes --behind-proxy --tls-cert "$WORK/tls/cert.pem" 2>&1) && status=0 || status=$?
check 'refuses --tls-cert without --tls-key' test "$status" != 0
out=$(installer install --domain calls.example.org --yes --behind-proxy --tls-cert tls/cert.pem --tls-key tls/key.pem 2>&1) && status=0 || status=$?
check 'refuses relative certificate paths' test "$status" != 0
rm -rf "$WORK"
setup
out=$(installer install --domain calls.example.org --yes --tls-cert /a.pem --tls-key /b.pem 2>&1) && status=0 || status=$?
check 'refuses --tls-cert without --behind-proxy' test "$status" != 0
COMPOSE_VERSION=v2.20.2
out=$(installer install --domain calls.example.org --yes --behind-proxy 2>&1) && status=0 || status=$?
check 'refuses Docker Compose older than 2.24 behind a proxy' test "$status" != 0
check '... and says why' grep -q 'Compose 2.24 or newer' <<<"$out"
check '... before starting anything' bash -c "! grep -q 'up -d --build' '$WORK/log'"
installer install --domain calls.example.org --yes >/dev/null 2>&1 && status=0 || status=$?
check 'an old Compose is fine without --behind-proxy' test "$status" = 0
rm -rf "$WORK"

# Operator details for the privacy policy and terms.
setup
installer install --domain calls.example.org --yes \
  --operator 'Izhaan Intellect' --contact 'privacy@izhaanintellect.fun' >/dev/null 2>&1
check 'saves the operator' has "$WORK/infra/.env" 'SOTTO_OPERATOR=Izhaan Intellect'
check 'saves the contact' has "$WORK/infra/.env" 'SOTTO_CONTACT=privacy@izhaanintellect.fun'
installer install --domain calls.example.org --yes >/dev/null 2>&1
check 'reinstall keeps the operator' has "$WORK/infra/.env" 'SOTTO_OPERATOR=Izhaan Intellect'
out=$(installer install --domain calls.example.org --yes --operator '<script>' 2>&1) && status=0 || status=$?
check 'refuses markup in the operator name' test "$status" != 0
out=$(installer install --domain calls.example.org --yes --behind-proxy 8185 2>&1) || true
check 'the printed proxy config turns access logs off' grep -q 'access_log off;' <<<"$out"
rm -rf "$WORK"

# coturn's settings (infra/coturn/start.sh), with a stub turnserver.
setup
stub turnserver 'printf "%s\n" "$@" >"$WORK/turnserver-args"'
START="$HERE/../coturn/start.sh"
check 'coturn start.sh turns TCP relaying off' grep -q -- '--no-tcp-relay' "$START"
env PATH="$WORK/bin:$PATH" WORK="$WORK" SOTTO_DOMAIN=calls.example.org SOTTO_TURN_SECRET=x \
  SOTTO_CERT_DIR="$WORK/none" sh "$START" >/dev/null
check 'coturn runs with --no-tcp-relay' grep -qx -- '--no-tcp-relay' "$WORK/turnserver-args"
check '... and without its own IP denied when none is set' bash -c "! grep -q 198.51.100.20 '$WORK/turnserver-args'"
env PATH="$WORK/bin:$PATH" WORK="$WORK" SOTTO_DOMAIN=calls.example.org SOTTO_TURN_SECRET=x \
  SOTTO_CERT_DIR="$WORK/none" SOTTO_TURN_EXTERNAL_IP=198.51.100.20 sh "$START" >/dev/null
check 'coturn refuses relaying to its external IP' grep -qx -- '--denied-peer-ip=198.51.100.20' "$WORK/turnserver-args"
rm -rf "$WORK"

if [[ $FAILED == 1 ]]; then
  echo 'install.sh tests FAILED'
  exit 1
fi
echo 'install.sh tests passed'
