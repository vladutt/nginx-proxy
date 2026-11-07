#!/usr/bin/env bash
# Issue the wildcard certificate (DOMAIN + *.DOMAIN) via Cloudflare DNS-01.
#
# Usage: scripts/init-cert.sh [extra certbot args, e.g. --dry-run --force-renewal]
#
# Needs DOMAIN and LETSENCRYPT_EMAIL in .env and a token in
# secrets/cloudflare.ini (chmod 600). Run it before the first
# `docker compose up -d`. LETSENCRYPT_STAGING=1 uses the staging CA.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DOMAIN="$(env_value DOMAIN)"
EMAIL="$(env_value LETSENCRYPT_EMAIL)"
STAGING="$(env_value LETSENCRYPT_STAGING)"
CRED="$ROOT/secrets/cloudflare.ini"

[[ -n "$DOMAIN" ]] || die "DOMAIN is not set (copy .env.example to .env)"
[[ -n "$EMAIL" ]] || die "LETSENCRYPT_EMAIL is not set (.env)"
validate_domain "$DOMAIN"
[[ -f "$CRED" ]] || die "$CRED not found (copy secrets/cloudflare.ini.example and add your token)"
if grep -q 'REPLACE_WITH' "$CRED"; then die "$CRED still contains the placeholder token"; fi
if [[ -z "$(find "$CRED" -perm 600)" ]]; then die "run: chmod 600 $CRED"; fi

args=(certonly --dns-cloudflare
  --dns-cloudflare-credentials /run/secrets/cloudflare.ini
  --dns-cloudflare-propagation-seconds 30
  --cert-name wildcard -d "$DOMAIN" -d "*.$DOMAIN"
  --email "$EMAIL" --agree-tos --no-eff-email --non-interactive)
if [[ "$STAGING" == "1" ]]; then args+=(--staging); fi

docker compose run --rm --entrypoint certbot certbot "${args[@]}" "$@"
info "Certificate stored in certbot/conf/live/wildcard/. Next: docker compose up -d"
