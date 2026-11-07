#!/usr/bin/env bash
# Refresh nginx/snippets/cloudflare-realip.conf from cloudflare.com/ips-v4 and
# /ips-v6, validate with nginx -t and reload. Restores the old file on failure.
#
# Usage: scripts/update-cloudflare-ips.sh
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OUT="$ROOT/nginx/snippets/cloudflare-realip.conf"
CIDR='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$|^[0-9a-fA-F:]+/[0-9]{1,3}$'

fetch() {
  local url="$1" body line
  body="$(curl -fsS --max-time 20 "$url")" || die "could not fetch $url"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ $CIDR ]] || die "unexpected line from $url: $line"
    printf 'set_real_ip_from %s;\n' "$line"
  done <<< "$body"
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
{
  echo "# Managed by scripts/update-cloudflare-ips.sh -- do not edit by hand."
  echo "# Source: https://www.cloudflare.com/ips-v4 and https://www.cloudflare.com/ips-v6"
  echo "# Included globally from nginx.conf (http block). Only connections coming from"
  echo "# these ranges may set the client address through CF-Connecting-IP."
  fetch https://www.cloudflare.com/ips-v4
  fetch https://www.cloudflare.com/ips-v6
  echo "real_ip_header CF-Connecting-IP;"
  echo "real_ip_recursive on;"
} > "$tmp"

[[ "$(grep -c '^set_real_ip_from' "$tmp")" -ge 10 ]] || die "too few ranges fetched; keeping the current file"

if cmp -s "$tmp" "$OUT"; then
  info "Cloudflare IP ranges unchanged."
  exit 0
fi

old="$(mktemp)"
cp "$OUT" "$old"
cp "$tmp" "$OUT"
if nginx_test; then
  rm -f "$old"
  nginx_reload
  info "Cloudflare IP ranges updated; review and commit the change."
else
  cp "$old" "$OUT"; rm -f "$old"
  die "nginx -t failed; previous ranges restored"
fi
