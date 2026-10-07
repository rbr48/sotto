#!/bin/sh
# Starts coturn for Sotto. Settings come from the environment (see infra/.env).
#
# - Credentials are time-limited HMACs issued by the relay (use-auth-secret);
#   coturn stores no users.
# - Relaying to private and special-purpose networks is refused, so the
#   server can't be used to reach anything inside its own network.
# - TURN over TLS (port 5349) is enabled automatically once Caddy has obtained
#   the certificate for SOTTO_DOMAIN; restart coturn after the first start.
# - Logs go to stdout, which docker-compose discards (logging driver "none").
set -eu

: "${SOTTO_DOMAIN:?set SOTTO_DOMAIN}"
: "${SOTTO_TURN_SECRET:?set SOTTO_TURN_SECRET}"
CERT_DIR="${SOTTO_CERT_DIR:-/certs/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$SOTTO_DOMAIN}"

set -- \
  -n \
  --listening-port=3478 \
  --realm="$SOTTO_DOMAIN" \
  --use-auth-secret \
  --static-auth-secret="$SOTTO_TURN_SECRET" \
  --fingerprint \
  --no-cli \
  --no-multicast-peers \
  --no-tcp-relay \
  --stale-nonce=600 \
  --min-port="${SOTTO_TURN_MIN_PORT:-49152}" \
  --max-port="${SOTTO_TURN_MAX_PORT:-65535}" \
  --total-quota="${SOTTO_TURN_TOTAL_QUOTA:-300}" \
  --user-quota=12 \
  --max-bps="${SOTTO_TURN_MAX_BPS:-3000000}" \
  --userdb="${SOTTO_TURN_DB:-/var/lib/coturn/turndb}" \
  --pidfile="${SOTTO_TURN_PIDFILE:-/tmp/turnserver.pid}" \
  --log-file=stdout \
  --simple-log \
  --denied-peer-ip=0.0.0.0-0.255.255.255 \
  --denied-peer-ip=10.0.0.0-10.255.255.255 \
  --denied-peer-ip=100.64.0.0-100.127.255.255 \
  --denied-peer-ip=127.0.0.0-127.255.255.255 \
  --denied-peer-ip=169.254.0.0-169.254.255.255 \
  --denied-peer-ip=172.16.0.0-172.31.255.255 \
  --denied-peer-ip=192.0.0.0-192.0.0.255 \
  --denied-peer-ip=192.168.0.0-192.168.255.255 \
  --denied-peer-ip=198.18.0.0-198.19.255.255 \
  --denied-peer-ip=240.0.0.0-255.255.255.255 \
  --denied-peer-ip=::1 \
  --denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff \
  --denied-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff \
  "$@"

if [ -n "${SOTTO_TURN_EXTERNAL_IP:-}" ]; then
  set -- "$@" --external-ip="$SOTTO_TURN_EXTERNAL_IP"
fi

if [ -r "$CERT_DIR/$SOTTO_DOMAIN.crt" ] && [ -r "$CERT_DIR/$SOTTO_DOMAIN.key" ]; then
  set -- "$@" \
    --tls-listening-port=5349 \
    --cert="$CERT_DIR/$SOTTO_DOMAIN.crt" \
    --pkey="$CERT_DIR/$SOTTO_DOMAIN.key" \
    --no-dtls
  echo "sotto-coturn: TURN over TLS enabled on port 5349"
else
  set -- "$@" --no-tls --no-dtls
  echo "sotto-coturn: no certificate yet; TURN over TLS disabled (restart coturn once Caddy has a certificate)"
fi

exec turnserver "$@"
