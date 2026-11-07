#!/usr/bin/env bash
# Remove a proxied site.
#
# Usage: scripts/remove-site.sh <subdomain> [--purge-cert]
#   --purge-cert  also delete the Let's Encrypt certificate for the host
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUB="" PURGE=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --purge-cert) PURGE=1 ;;
    -*) die "unknown option: $arg" ;;
    *) [[ -z "$SUB" ]] || die "too many arguments"; SUB="$arg" ;;
  esac
done
[[ -n "$SUB" ]] || die "usage: remove-site.sh <subdomain> [--purge-cert]"

DOMAIN="$(env_value DOMAIN)"
[[ -n "$DOMAIN" ]] || die "DOMAIN is not set (copy .env.example to .env)"
validate_label "$SUB"
validate_domain "$DOMAIN"
HOST="$SUB.$DOMAIN"
CONF="$CONF_DIR/$HOST.conf"

[[ -f "$CONF" ]] || die "$CONF does not exist"

SNAP="$(mktemp)"
cp "$CONF" "$SNAP"
rm -f "$CONF"
if nginx_test; then
  rm -f "$SNAP"
  nginx_reload
  info "Removed $HOST."
else
  cp "$SNAP" "$CONF"; rm -f "$SNAP"
  die "nginx -t failed; site file restored"
fi

if (( PURGE )); then
  docker compose run --rm --entrypoint certbot certbot delete --cert-name "$HOST" --non-interactive
else
  info "Certificate kept. To delete it:"
  info "  docker compose run --rm --entrypoint certbot certbot delete --cert-name $HOST"
fi
