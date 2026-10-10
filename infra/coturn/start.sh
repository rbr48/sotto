#!/bin/sh
# Starts coturn for Sotto. Settings come from the environment (see infra/.env).
#
# - Credentials are time-limited HMACs issued by the relay (use-auth-secret);
#   coturn stores no users.
# - Relaying to private and special-purpose networks is refused, so the
#   server can't be used to reach anything inside its own network.
# - Only UDP is relayed (--no-tcp-relay): calls need nothing else, and TCP
#   relaying would let the server be used as a TCP proxy.
# - TURN over TLS (port 5349) is enabled automatically once Caddy has obtained
#   the certificate for SOTTO_DOMAIN (or, behind another reverse proxy, with
#   that proxy's certificate: SOTTO_TLS_CERT and SOTTO_TLS_KEY); install.sh
#   restarts coturn after the first start and weekly (to load renewals).
# - Logs go to stdout, which docker-compose discards (logging driver "none").
set -eu

: "${SOTTO_DOMAIN:?set SOTTO_DOMAIN}"
: "${SOTTO_TURN_SECRET:?set SOTTO_TURN_SECRET}"
CERT_DIR="${SOTTO_CERT_DIR:-/certs/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$SOTTO_DOMAIN}"
CERT="${SOTTO_TLS_CERT:-$CERT_DIR/$SOTTO_DOMAIN.crt}"
KEY="${SOTTO_TLS_KEY:-$CERT_DIR/$SOTTO_DOMAIN.key}"

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
  # coturn uses the host's network, so also refuse relaying to the server's
  # own public address (it is not on an interface behind NAT).
  set -- "$@" \
    --external-ip="$SOTTO_TURN_EXTERNAL_IP" \
    --denied-peer-ip="${SOTTO_TURN_EXTERNAL_IP%%/*}"
fi

if [ -r "$CERT" ] && [ -r "$KEY" ]; then
  set -- "$@" \
    --tls-listening-port=5349 \
    --cert="$CERT" \
    --pkey="$KEY"
  echo "sotto-coturn: TURN over TLS enabled on port 5349"
else
  set -- "$@" --no-tls
  echo "sotto-coturn: no certificate yet ($CERT); TURN over TLS disabled (restart coturn once there is one)"
fi

exec turnserver "$@"
