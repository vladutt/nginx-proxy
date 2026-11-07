#!/usr/bin/env bash
# Add a proxied site: nginx/conf.d/<subdomain>.<DOMAIN>.conf
#
# Usage: scripts/add-site.sh <subdomain|@> [upstream] [--ws] [--force] [--dry-run]
#        scripts/add-site.sh <subdomain|@> --redirect <subdomain|@> [--force] [--dry-run]
#   subdomain  the site is <subdomain>.<DOMAIN>; "@" means the apex <DOMAIN>
#   upstream   host:port. A container name on the proxy network (myapp:3000)
#              or a service on the host (host.docker.internal:3001).
#              Omit it to pick from the running containers.
#   --ws       enable WebSocket upgrade for this site
#   --redirect <target>  301 this site to the target (a subdomain or "@" for
#              the apex) instead of proxying, e.g. "www --redirect @";
#              takes no upstream; the target must differ from the site
#   --force    overwrite an existing site file
#   --dry-run  print the generated config, change nothing
#
# The site uses the wildcard certificate from scripts/init-cert.sh; no
# certificate is issued per site.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

SUB="" UPSTREAM="" WS=0 FORCE=0 DRY=0 REDIRECT=""
while (( $# )); do
  arg="$1"; shift
  case "$arg" in
    -h|--help) usage 0 ;;
    --ws) WS=1 ;;
    --force) FORCE=1 ;;
    --dry-run) DRY=1 ;;
    --redirect)
      (( $# )) || die "--redirect needs a subdomain"
      REDIRECT="$1"; shift ;;
    -*) die "unknown option: $arg" ;;
    *)
      if [[ -z "$SUB" ]]; then SUB="$arg"
      elif [[ -z "$UPSTREAM" ]]; then UPSTREAM="$arg"
      else die "too many arguments"; fi ;;
  esac
done
[[ -n "$SUB" ]] || usage 1
if [[ -n "$REDIRECT" ]]; then
  [[ "$SUB" != "$REDIRECT" ]] || die "a site cannot redirect to itself ('$SUB')"
  [[ -z "$UPSTREAM" ]] || die "--redirect takes no upstream"
  (( ! WS )) || die "--redirect cannot be combined with --ws"
  validate_site_name "$REDIRECT"
fi

DOMAIN="$(env_value DOMAIN)"
[[ -n "$DOMAIN" ]] || die "DOMAIN is not set (copy .env.example to .env)"
PROXY_NETWORK="$(env_value PROXY_NETWORK)"; PROXY_NETWORK="${PROXY_NETWORK:-proxy}"

validate_site_name "$SUB"
validate_domain "$DOMAIN"
HOST="$(host_for "$SUB" "$DOMAIN")"
CONF="$CONF_DIR/$HOST.conf"

if (( ! DRY )) && [[ -e "$CONF" && $FORCE -ne 1 ]]; then
  die "$CONF already exists (use --force to overwrite)"
fi

# Interactive container picker -> sets UPSTREAM
pick_upstream() {
  [[ -t 0 ]] || die "no upstream given and stdin is not a terminal"
  local names=() nets=() line name ports net i=1 choice cports port
  info "Running containers:"
  info "   0) service on the host (host.docker.internal)"
  while IFS='|' read -r name ports net; do
    [[ "$name" == "nginx-proxy" || "$name" == "nginx-proxy-certbot" ]] && continue
    names+=("$name"); nets+=("$net")
    printf '  %2d) %s  [ports: %s]  [networks: %s]\n' "$i" "$name" "${ports:--}" "$net"
    i=$((i + 1))
  done < <(docker ps --format '{{.Names}}|{{.Ports}}|{{.Networks}}')

  read -r -p "Choose a number: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] || die "not a number: $choice"
  if (( choice == 0 )); then
    read -r -p "Host port: " port
    UPSTREAM="host.docker.internal:$port"
    return
  fi
  (( choice >= 1 && choice <= ${#names[@]} )) || die "choice out of range"
  name="${names[choice-1]}"; net="${nets[choice-1]}"

  # Container-internal TCP ports from the image's EXPOSE / published ports
  cports=()
  for line in $(docker inspect -f '{{range $p,$_ := .Config.ExposedPorts}}{{$p}} {{end}}' "$name"); do
    [[ "$line" =~ ^([0-9]+)/tcp$ ]] && cports+=("${BASH_REMATCH[1]}")
  done
  if (( ${#cports[@]} == 1 )); then
    port="${cports[0]}"
    info "Using container port $port"
  else
    read -r -p "Container port (candidates: ${cports[*]:-none}): " port
  fi
  UPSTREAM="$name:$port"
  case ",$net," in
    *",$PROXY_NETWORK,"*) ;;
    *) info "note: $name is not on network '$PROXY_NETWORK'. Run: docker network connect $PROXY_NETWORK $name" ;;
  esac
}

TEMPLATE="$TEMPLATE_DIR/site.conf.template"
UPSTREAM_DIRECTIVES="" WS_INCLUDE="" TARGET=""

if [[ -n "$REDIRECT" ]]; then
  TEMPLATE="$TEMPLATE_DIR/redirect.conf.template"
  TARGET="$(host_for "$REDIRECT" "$DOMAIN")"
  DEST="$TARGET (301)"
else
  [[ -n "$UPSTREAM" ]] || pick_upstream
  validate_upstream "$UPSTREAM"

  UP_HOST="${UPSTREAM%:*}"; UP_PORT="${UPSTREAM##*:}"
  case "$UP_HOST" in
    localhost|127.0.0.1)
      info "note: '$UP_HOST' inside the nginx container is nginx itself; using host.docker.internal" >&2
      UP_HOST="host.docker.internal" ;;
  esac

  # Upstream directives. Names on the proxy network are resolved at request time
  # through Docker's DNS, so nginx still starts when that container is down.
  # host.docker.internal and IPs are static (resolved from /etc/hosts at start).
  INDENT="        "
  if [[ "$UP_HOST" == "host.docker.internal" || "$UP_HOST" =~ ^[0-9.]+$ ]]; then
    UPSTREAM_DIRECTIVES="${INDENT}proxy_pass http://$UP_HOST:$UP_PORT;"
  else
    UPSTREAM_DIRECTIVES="${INDENT}resolver 127.0.0.11 valid=10s ipv6=off;"$'\n'
    UPSTREAM_DIRECTIVES+="${INDENT}set \$upstream_target \"$UP_HOST:$UP_PORT\";"$'\n'
    UPSTREAM_DIRECTIVES+="${INDENT}proxy_pass http://\$upstream_target;"
  fi
  if (( WS )); then WS_INCLUDE=$'\n'"${INDENT}include /etc/nginx/snippets/websocket.conf;"; fi
  DEST="$UP_HOST:$UP_PORT"
fi

render() {
  local content
  content="$(cat "$1")"
  content="${content//@@HOSTNAME@@/$HOST}"
  content="${content//@@TARGET@@/$TARGET}"
  content="${content//@@UPSTREAM_DIRECTIVES@@/$UPSTREAM_DIRECTIVES}"
  content="${content//$'\n'@@WEBSOCKET_INCLUDE@@/$WS_INCLUDE}"
  printf '%s\n' "$content"
}

if (( DRY )); then
  render "$TEMPLATE"
  exit 0
fi

# Write, nginx -t, reload; restore the previous state on failure.
snap="" had=0
if [[ -e "$CONF" ]]; then had=1; snap="$(mktemp)"; cp "$CONF" "$snap"; fi
render "$TEMPLATE" > "$CONF"
if nginx_test; then
  [[ -z "$snap" ]] || rm -f "$snap"
  nginx_reload
  info "Done: https://$HOST -> $DEST"
else
  if (( had )); then cp "$snap" "$CONF"; rm -f "$snap"; else rm -f "$CONF"; fi
  info "hint: has the wildcard certificate been issued? Run scripts/init-cert.sh" >&2
  die "nginx -t failed; change rolled back"
fi
