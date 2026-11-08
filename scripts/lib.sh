#!/usr/bin/env bash
# Shared helpers for the scripts in this directory. Source it, do not run it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC2034  # used by the scripts that source this file
CONF_DIR="$ROOT/nginx/conf.d"
# shellcheck disable=SC2034
TEMPLATE_DIR="$ROOT/templates"
cd "$ROOT" || exit 1

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

# env_value VAR -> value from the environment, else from .env (never sourced).
env_value() {
  local var="$1" val="${!1:-}"
  if [[ -z "$val" && -f "$ROOT/.env" ]]; then
    val="$(grep -E "^${var}=" "$ROOT/.env" | tail -n1 | cut -d= -f2- || true)"
    val="${val%\"}"; val="${val#\"}"
  fi
  printf '%s' "$val"
}

validate_label() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
    || die "invalid subdomain '$1' (lowercase letters, digits, '-'; max 63 chars)"
}

# Site name: a subdomain label, or "@" for the apex domain.
validate_site_name() {
  [[ "$1" == "@" ]] || validate_label "$1"
}

# host_for <sub|@> <domain> -> full hostname (apex for "@")
host_for() {
  if [[ "$1" == "@" ]]; then printf '%s' "$2"; else printf '%s.%s' "$1" "$2"; fi
}

validate_domain() {
  [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] \
    || die "invalid DOMAIN '$1' (set it in .env)"
}

validate_upstream() {
  local up="$1" host port
  [[ "$up" =~ ^[A-Za-z0-9._-]+:[0-9]{1,5}$ ]] \
    || die "invalid upstream '$up' (expected a port or host:port, e.g. 8000 or myapp:3000)"
  host="${up%:*}"; port="${up##*:}"
  [[ -n "$host" ]] || die "empty upstream host"
  (( 10#$port >= 1 && 10#$port <= 65535 )) || die "port out of range: $port"
}

nginx_running() {
  docker compose ps --status running --services 2>/dev/null | grep -qx nginx
}

# Run nginx -t with the current files. Uses the running container if any.
nginx_test() {
  if nginx_running; then
    docker compose exec -T nginx nginx -t
  else
    docker compose run --rm --no-deps -T nginx nginx -t
  fi
}

nginx_reload() {
  if nginx_running; then
    docker compose exec -T nginx nginx -s reload
    info "nginx reloaded."
  else
    info "nginx is not running; start it with: docker compose up -d"
  fi
}
