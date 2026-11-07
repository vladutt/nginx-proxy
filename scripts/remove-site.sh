#!/usr/bin/env bash
# Remove a proxied site. The shared wildcard certificate is not touched.
#
# Usage: scripts/remove-site.sh <subdomain|@>   ("@" = the apex domain)
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUB=""
for arg in "$@"; do
  case "$arg" in
    -h|--help) sed -n '2,5p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $arg" ;;
    *) [[ -z "$SUB" ]] || die "too many arguments"; SUB="$arg" ;;
  esac
done
[[ -n "$SUB" ]] || die "usage: remove-site.sh <subdomain>"

DOMAIN="$(env_value DOMAIN)"
[[ -n "$DOMAIN" ]] || die "DOMAIN is not set (copy .env.example to .env)"
validate_site_name "$SUB"
validate_domain "$DOMAIN"
HOST="$(host_for "$SUB" "$DOMAIN")"
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
