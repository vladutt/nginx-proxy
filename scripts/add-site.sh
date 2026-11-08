#!/usr/bin/env bash
# Add a proxied site: nginx/conf.d/<subdomain>.<DOMAIN>.conf
#
# Usage: scripts/add-site.sh <subdomain|@> [upstream] [--ws] [--force] [--dry-run]
#        scripts/add-site.sh <subdomain|@> --redirect <subdomain|@> [--force] [--dry-run]
#   subdomain  the site is <subdomain>.<DOMAIN>; "@" means the apex <DOMAIN>
#   upstream   host:port, normally a published port of a project:
#              host.docker.internal:8000 ("localhost:8000" is rewritten).
#              A container name on the proxy network (myapp:3000) also works.
#              Omit it to pick from the running containers; the picker uses
#              the container's published host port.
#   --network  picker: use container-name:internal-port on the shared proxy
#              network instead of the published host port
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

usage() { sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

SUB="" UPSTREAM="" WS=0 FORCE=0 DRY=0 REDIRECT="" NETWORK_MODE=0
while (( $# )); do
  arg="$1"; shift
  case "$arg" in
    -h|--help) usage 0 ;;
    --ws) WS=1 ;;
    --force) FORCE=1 ;;
    --dry-run) DRY=1 ;;
    --network) NETWORK_MODE=1 ;;
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

warn() { printf '%s\n' "$*" >&2; }

# IP of the docker0 bridge (what host.docker.internal resolves to on Linux).
bridge_ip() {
  local ip
  ip="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
  printf '%s' "${ip:-172.17.0.1}"
}

# read_choice <prompt> -> REPLY (dies on EOF)
read_choice() { read -r -p "$1" REPLY || die "no selection (no input)"; }

# Container picker -> sets PICK_NAME (container) and PICK_NET (its networks);
# sets UPSTREAM directly and returns 1 if the "service on the host" entry was chosen.
pick_container() {
  local names=() nets=() name ports net i=1 choice port
  info "Running containers:"
  info "   0) service on the host (host.docker.internal)"
  while IFS='|' read -r name ports net; do
    [[ "$name" == "nginx-proxy" || "$name" == "nginx-proxy-certbot" ]] && continue
    names+=("$name"); nets+=("$net")
    printf '  %2d) %s  [ports: %s]  [networks: %s]\n' "$i" "$name" "${ports:--}" "$net"
    i=$((i + 1))
  done < <(docker ps --format '{{.Names}}|{{.Ports}}|{{.Networks}}')

  read_choice "Choose a number: "; choice="$REPLY"
  [[ "$choice" =~ ^[0-9]+$ ]] || die "not a number: $choice"
  if (( choice == 0 )); then
    read_choice "Host port: "; port="$REPLY"
    UPSTREAM="host.docker.internal:$port"
    return 1
  fi
  (( choice >= 1 && choice <= ${#names[@]} )) || die "choice out of range"
  PICK_NAME="${names[choice-1]}"; PICK_NET="${nets[choice-1]}"
}

# Default mode: the container's PUBLISHED host port, reached through
# host.docker.internal. Survives container recreate; no shared network needed.
pick_upstream_host() {
  pick_container || return 0
  local pp=() l cport hip hport br sel=0
  while IFS= read -r l; do
    [[ -n "$l" ]] && pp+=("$l")
  done < <(docker inspect -f '{{range $p,$b := .NetworkSettings.Ports}}{{range $b}}{{$p}} {{.HostIp}} {{.HostPort}}{{"\n"}}{{end}}{{end}}' "$PICK_NAME" \
            | awk '$1 ~ /\/tcp$/ { sub("/tcp", "", $1); if (!seen[$1 " " $3]++) print $1, $2, $3 }')
  br="$(bridge_ip)"
  if (( ${#pp[@]} == 0 )); then
    warn "error: $PICK_NAME publishes no TCP port, so nginx cannot reach it through the host."
    warn "Either publish one on the bridge IP in its compose file:"
    warn "    ports:"
    warn "      - \"$br:<host-port>:<container-port>\""
    warn "or use the shared-network mode: add-site.sh $SUB --network"
    exit 1
  fi
  if (( ${#pp[@]} > 1 )); then
    local n=1
    for l in "${pp[@]}"; do
      read -r cport hip hport <<< "$l"
      printf '  %d) host port %s -> container port %s  [bound to %s]\n' "$n" "$hport" "$cport" "${hip:-all}"
      n=$((n + 1))
    done
    read_choice "Which published port? "; sel="$REPLY"
    [[ "$sel" =~ ^[0-9]+$ ]] || die "not a number: $sel"
    (( sel >= 1 && sel <= ${#pp[@]} )) || die "choice out of range"
    sel=$((sel - 1))
  fi
  read -r cport hip hport <<< "${pp[sel]}"
  UPSTREAM="host.docker.internal:$hport"
  case "$hip" in
    0.0.0.0|::|"")
      warn "warning: $PICK_NAME publishes $hport on all interfaces: publicly reachable,"
      warn "bypassing Cloudflare and the rate limits. Prefer this line in its compose file:"
      warn "    ports:"
      warn "      - \"$br:$hport:$cport\""
      warn "then recreate it (docker compose up -d)." ;;
    127.*|::1)
      warn "warning: $PICK_NAME publishes $hport on loopback only; nginx cannot reach that."
      warn "Publish it on the bridge IP instead: \"$br:$hport:$cport\"." ;;
  esac
}

# --network mode: container name + container-internal port on the proxy network.
pick_upstream_network() {
  pick_container || return 0
  local line cports=() port
  # Container-internal TCP ports from the image's EXPOSE / published ports
  for line in $(docker inspect -f '{{range $p,$_ := .Config.ExposedPorts}}{{$p}} {{end}}' "$PICK_NAME"); do
    [[ "$line" =~ ^([0-9]+)/tcp$ ]] && cports+=("${BASH_REMATCH[1]}")
  done
  if (( ${#cports[@]} == 1 )); then
    port="${cports[0]}"
    info "Using container port $port"
  else
    read_choice "Container port (candidates: ${cports[*]:-none}): "; port="$REPLY"
  fi
  UPSTREAM="$PICK_NAME:$port"
  case ",$PICK_NET," in
    *",$PROXY_NETWORK,"*) ;;
    *) info "note: $PICK_NAME is not on network '$PROXY_NETWORK'. Run: docker network connect $PROXY_NETWORK $PICK_NAME" ;;
  esac
}

pick_upstream() {
  if (( NETWORK_MODE )); then pick_upstream_network; else pick_upstream_host; fi
}

TEMPLATE="$TEMPLATE_DIR/site.conf.template"
UPSTREAM_DIRECTIVES="" WS_INCLUDE="" TARGET=""

if [[ -n "$REDIRECT" ]]; then
  TEMPLATE="$TEMPLATE_DIR/redirect.conf.template"
  TARGET="$(host_for "$REDIRECT" "$DOMAIN")"
  DEST="$TARGET (301)"
  # Loop guard: refuse if the target's file already redirects back to this host.
  if (( ! FORCE )) && [[ -f "$CONF_DIR/$TARGET.conf" ]] \
     && grep -qF "return 301 https://$HOST\$request_uri" "$CONF_DIR/$TARGET.conf"; then
    die "redirect loop: $TARGET already redirects to $HOST (use --force to write it anyway)"
  fi
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
