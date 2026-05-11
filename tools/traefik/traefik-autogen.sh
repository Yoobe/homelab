#!/usr/bin/env bash
set -euo pipefail
################################################################################
# TRAEFIK AUTOGENERATION SCRIPT + GATUS MONITORING
# Status: OPERATIONAL | Last Updated: 2026-03-08
################################################################################
#
# READS: Proxmox container descriptions for [web] INI sections
# GENERATES: Traefik route YAML files in /etc/traefik/dynamic/
# GENERATES: Gatus monitoring config for domain and machine health checks
# SYNCS: DNS records to AdGuard Home instances configured via ADGUARD_PRIMARY/SECONDARY
# SYNCS: Gatus config to monitoring servers via scp+ssh
# RUNS: Every minute via cron
#
# CONTAINER [web] SECTION KEYS (all optional except domain + port):
#   domain = app.example.com           (Required - traefik route host)
#   port = 8080                       (Required - container service port)
#   security = oauth|public|private|password|auth  (Optional - applies middleware)
#   proto = http|https                (Optional - affects TLS config)
#   ip = 192.168.0.X                  (Optional - static IP override)
#   dns = dns.name.local              (Optional - DNS-only, no route)
#   websocket = true|false            (Optional - enables WebSocket support, skips headers middleware)
#
# EXAMPLES:
#
#   Minimal (no security):
#   [web]
#   domain = app.yoo.plus
#   port = 3000
#
#   OAuth-protected:
#   [web]
#   domain = oauth-app.example.com
#   port = 5678
#   security = oauth
#   proto = http
#
#   Public dashboard:
#   [web]
#   domain = pub-app.example.com
#   port = 3000
#   security = public
#
#   Internal-only:
#   [web]
#   domain = priv-app.example.com
#   port = 8086
#   security = private
#
#   Password-protected:
#   [web]
#   domain = pw-app.example.com
#   port = 9000
#   security = password
#
#   WebSocket-enabled:
#   [web]
#   domain = ws-app.example.com
#   port = 3000
#   websocket = true
#
#   DNS-only record:
#   [web]
#   dns = hostname.local
#   ip = 192.168.0.5
#
#
# KEY BEHAVIORS:
#    domain         - Required. Must be valid FQDN. Creates traefik route.
#    port           - Required. Must be valid port number (1-65535).
#    security       - Optional. Maps to middleware:
#                     oauth        -> security-oauth middleware
#                     private      -> allow-internal middleware
#                     password     -> auth-basic middleware
#                     auth         -> authentik middleware
#                     (empty/other) -> no security middleware
#    proto          - Optional. Defaults to http if omitted. Sets tls config.
#    ip             - Optional. Static IP override. Uses tag-defined IP if missing.
#    dns            - Optional. Creates an *additional* DNS-only entry (no Traefik route). When specified, the script
#                     creates a rewrite record in AdGuard (e.g. `custom.local -> <ip>`). Note: this is *separate* from
#                     the automatic `.lan` record that is created for every container based on its hostname. The IP used
#                     is from the `ip =` field in the same section when available, otherwise falls back to an IP from the
#                     container tags (first matching `192.168.x.x`). This avoids non-LAN addresses like Tailscale or Docker
#                     bridge IPs.
#    websocket      - Optional. Set to .true. to enable WebSocket support. When enabled:
#                     - Skips the forward-headers-* middleware (which breaks WebSocket upgrades)
#                     - Adds .passHostHeader: true. to the service
#
# AUTOMATIC .LAN RECORDS:
#    For every container in Proxmox, the script automatically creates an internal `.lan` DNS record
#    (e.g. `hostname.lan -> container_ip`) for service-to-service discovery on the LAN. The hostname
#    is lowercased, and a tiered deduplication strategy applies when collisions occur:
#      Tier 1: hostname.lan
#      Tier 2: hostname-pve_alias.lan    (if tier 1 collides)
#      Tier 3: hostname-pve_alias-vmid.lan (guaranteed unique)
#    The IP used is the first matching `192.168.x.x` address from container tags, falling back to
#    the `ip =` field in a `[web]` section if tags don't provide a private IP. Non-LAN addresses
#    (Tailscale, Docker bridges) are skipped. These `.lan` records are synced to AdGuard Home.
#
LOG_FILE="/var/log/traefik-autogen.log"
LOG_DIR="/var/log"
# Can be set to true in environment to perform a dry run (no AdGuard changes).
# shellcheck disable=SC2034
DRY_RUN=false
mkdir -p "$LOG_DIR"

# Logging function
log() {
  local level="$1"
  shift
  local msg="$*"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local formatted="[$timestamp] [$level] $msg"
  [[ "$level" != "DEBUG" ]] && echo "$formatted"
  echo "$formatted" >> "$LOG_FILE" 2>/dev/null || true
}

# Load configuration from an external file to avoid hardcoding secrets or
# personal data in this script. The file should export the variables used by
# this script (see import.env.example). First, try the system path, then the
# local directory. If neither is present we exit to avoid running with
# embedded credentials.
CONFIG_FILE="/etc/traefik/traefik-autogen.env"
LOCAL_CONFIG="./traefik-autogen.env"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  log "INFO" "Loaded config from $CONFIG_FILE"
elif [[ -f "$LOCAL_CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$LOCAL_CONFIG"
  log "INFO" "Loaded config from $LOCAL_CONFIG"
else
  echo "ERROR: No config file found. Deploy traefik-autogen.env to /etc/traefik/import.env or place ./traefik-autogen.env in current directory." >&2
  exit 1
fi
# NOTES:
# - Stopped containers have no IP: routes not generated (expected behavior)
# - New containers auto-detected next cron cycle
# - Description changes apply on next cron cycle
#
################################################################################
ROUTERS_TMP=""
SERVICES_TMP=""
TCP_ROUTERS_TMP=""
TCP_SERVICES_TMP=""
MIDDLEWARES_TMP=""
TRANSPORTS_TMP=""
FINAL=""
GATUS_TMP=""

cleanup() {
  rm -f "$ROUTERS_TMP" "$SERVICES_TMP" "$TCP_ROUTERS_TMP" "$TCP_SERVICES_TMP" "$MIDDLEWARES_TMP" "$TRANSPORTS_TMP" "$FINAL" "$GATUS_TMP" 2>/dev/null ; true
}
trap cleanup EXIT ERR

# Format: "alias|api_url|token"
# alias is used for .lan DNS naming (short, e.g. p1, p2)
# PVE_SERVERS must be provided by the external config. See import.env.example
# Expected format (newline-separated entries):
# p1|https://pve.example.com:8006/api2/json|PVEAPIToken=user@pam!token=xxxxxxxx-xxxx-xxxx
PVE_SERVERS=()
if [[ -n "${PVE_SERVERS_RAW:-}" ]]; then
  # readarray will split on newlines into the PVE_SERVERS array
  IFS=$'\n' read -r -d '' -a PVE_SERVERS < <(printf '%s\0' "$PVE_SERVERS_RAW") || true
fi

# AdGuard Home API Configuration must also be provided by the external config.
# Provide `ADGUARD_PRIMARY`, `ADGUARD_SECONDARY`, `ADGUARD_USER`, and
# `ADGUARD_PASS` via the config file or environment variables.
ADGUARD_PRIMARY="${ADGUARD_PRIMARY:-}"
ADGUARD_SECONDARY="${ADGUARD_SECONDARY:-}"
ADGUARD_USER="${ADGUARD_USER:-}"
ADGUARD_PASS="${ADGUARD_PASS:-}"

# Gatus monitoring configuration (optional)
# Format: pipe-separated list of servers (e.g., "192.168.0.97|192.168.2.36")
GATUS_SERVERS_RAW="${GATUS_SERVERS_RAW:-}"
GATUS_CONFIG_DIR="${GATUS_CONFIG_DIR:-/etc/gatus/config.d}"
GATUS_AUTOGEN_FILE="${GATUS_AUTOGEN_FILE:-autogen-pve.yml}"
GATUS_CONTAINER_NAME="${GATUS_CONTAINER_NAME:-gatus}"
GATUS_SSH_USER="${GATUS_SSH_USER:-root}"
GATUS_SSH_PASS="${GATUS_SSH_PASS:-}"
GATUS_GOOGLECHAT_WEBHOOK="${GATUS_GOOGLECHAT_WEBHOOK:-}"
GATUS_TELEGRAM_TOKEN="${GATUS_TELEGRAM_TOKEN:-}"
GATUS_TELEGRAM_ID="${GATUS_TELEGRAM_ID:-}"

if [[ -n "${GATUS_SERVERS_RAW:-}" ]]; then
  IFS='|' read -r -a GATUS_SERVERS <<< "${GATUS_SERVERS_RAW}"
else
  GATUS_SERVERS=()
fi

# Detect Traefik IP (prefers Keepalived VIP if present)
TRAEFIK_IP=""
KEEPALIVED_CONF="/etc/keepalived/keepalived.conf"
if [[ -f "$KEEPALIVED_CONF" ]]; then
    # Strictly extract VIP from config to enforce 200
    TRAEFIK_IP=$(/usr/bin/grep -A 5 "virtual_ipaddress" "$KEEPALIVED_CONF" | /usr/bin/grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | /usr/bin/head -n1)
    if [[ -n "$TRAEFIK_IP" ]]; then
        log "DEBUG" "Detected VIP from ${KEEPALIVED_CONF}: $TRAEFIK_IP"
    fi
fi

# Fallback 1: Check active keepalived interfaces
if [[ -z "$TRAEFIK_IP" ]]; then
    TRAEFIK_IP=$(/usr/sbin/ip addr show | /usr/bin/grep "proto keepalived" | /usr/bin/grep -Eo 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' | /usr/bin/awk '{print $2}' | /usr/bin/head -n1 || true)
    if [[ -n "$TRAEFIK_IP" ]]; then
        log "DEBUG" "Detected active VIP from interface: $TRAEFIK_IP"
    fi
fi

# Fallback 2: Check specifically for VIP in hostname -I before accepting local IP
# If a DEFAULT_TRAEFIK_VIP is provided in the environment (import.env), prefer it.
DEFAULT_TRAEFIK_VIP="${DEFAULT_TRAEFIK_VIP:-}"
if [[ -z "$TRAEFIK_IP" ]]; then
  if [[ -n "$DEFAULT_TRAEFIK_VIP" ]] && /usr/bin/hostname -I | /usr/bin/grep -q "$DEFAULT_TRAEFIK_VIP"; then
    TRAEFIK_IP="$DEFAULT_TRAEFIK_VIP"
    log "DEBUG" "Forcing VIP ${DEFAULT_TRAEFIK_VIP} found in hostname list"
  else
    TRAEFIK_IP=$(/usr/bin/hostname -I | /usr/bin/awk '{print $1}')
    log "DEBUG" "Falling back to local IP: $TRAEFIK_IP"
  fi
fi

# If running on a Traefik node and a DEFAULT_TRAEFIK_VIP is set, prefer that VIP
if [[ -n "$DEFAULT_TRAEFIK_VIP" && "$(hostname)" == *"traefik" ]]; then
  log "DEBUG" "Detected Traefik node, using DEFAULT_TRAEFIK_VIP: $DEFAULT_TRAEFIK_VIP"
  TRAEFIK_IP="$DEFAULT_TRAEFIK_VIP"
fi

# FINAL SAFETY: use DEFAULT_TRAEFIK_VIP or a reserved example IP if nothing detected
if [[ -z "$TRAEFIK_IP" ]]; then
  if [[ -n "$DEFAULT_TRAEFIK_VIP" ]]; then
    log "WARNING" "Could not detect any IP, using DEFAULT_TRAEFIK_VIP: $DEFAULT_TRAEFIK_VIP"
    TRAEFIK_IP="$DEFAULT_TRAEFIK_VIP"
  else
    log "ERROR" "Could not detect any IP, using example default 192.0.2.200 as fallback"
    TRAEFIK_IP="192.0.2.200"
  fi
fi

log "INFO" ">>> Sync Target IP: $TRAEFIK_IP <<<"

# URL encode function for special characters in credentials
urlencode() {
  local string="${1}"
  local strlen=${#string}
  local encoded=""
  local pos c o

  for (( pos=0 ; pos<strlen ; pos++ )); do
    c=${string:$pos:1}
    case "$c" in
      [-_.~a-zA-Z0-9] ) o="${c}" ;;
      * ) printf -v o '%%%02x' "'$c"
    esac
    encoded+="${o}"
  done
  echo "${encoded}"
}

# AdGuard Home DNS sync function
adguard_sync_all() {
  local adguard_host="$1"
  local target_ip="$2"
  shift 2
  local desired_domains=("$@")

  log "INFO" "Syncing domains to ${adguard_host}..."

  local list_json http_code
  http_code=$(/usr/bin/curl -s -k -o /dev/null -w "%{http_code}" --max-time 10 -u "${ADGUARD_USER}:${ADGUARD_PASS}" "http://${adguard_host}/control/rewrite/list")
  list_json=$(/usr/bin/curl -s -k --max-time 10 -u "${ADGUARD_USER}:${ADGUARD_PASS}" "http://${adguard_host}/control/rewrite/list")
  if [[ -z "$list_json" || "$list_json" == "null" ]]; then
    log "ERROR" "Failed to fetch rewrite list from ${adguard_host} (HTTP ${http_code})"
    return 1
  fi

  declare -A desired_map
  for d in "${desired_domains[@]}"; do desired_map["$d"]=1; done

  for domain in "${desired_domains[@]}"; do
    # Check if this domain has a manual override target IP
    local current_target="$target_ip"
    if [[ -n "${MANUAL_DNS_MAP[$domain]:-}" ]]; then
        current_target="${MANUAL_DNS_MAP[$domain]}"
    fi

    local existing_answers
    existing_answers=$(echo "$list_json" | /usr/bin/jq -r --arg d "$domain" '.[] | select(.domain==$d) | .answer')

    # If correct record exists
    if echo "$existing_answers" | /usr/bin/grep -qFx "$current_target"; then
      # Prune other answers for same domain
      while read -r ans; do
        [[ -z "$ans" || "$ans" == "$current_target" ]] && continue
        /usr/bin/curl -s -X POST --max-time 10 "http://${adguard_host}/control/rewrite/delete" \
          -u "${ADGUARD_USER}:${ADGUARD_PASS}" -H "Content-Type: application/json" \
          -d "$(/usr/bin/jq -nc --arg d "$domain" --arg a "$ans" '{domain:$d,answer:$a}')" >/dev/null
      done <<< "$existing_answers"
      continue
    fi

    # Record wrong or missing
    if [[ -n "$existing_answers" ]]; then
       while read -r ans; do
         [[ -z "$ans" ]] && continue
         /usr/bin/curl -s -X POST --max-time 10 "http://${adguard_host}/control/rewrite/delete" \
           -u "${ADGUARD_USER}:${ADGUARD_PASS}" -H "Content-Type: application/json" \
           -d "$(/usr/bin/jq -nc --arg d "$domain" --arg a "$ans" '{domain:$d,answer:$a}')" >/dev/null
       done <<< "$existing_answers"
    fi

    # Add correct one
    /usr/bin/curl -s -X POST --max-time 10 "http://${adguard_host}/control/rewrite/add" \
      -u "${ADGUARD_USER}:${ADGUARD_PASS}" -H "Content-Type: application/json" \
      -d "$(/usr/bin/jq -nc --arg d "$domain" --arg a "$current_target" '{domain:$d,answer:$a}')" >/dev/null
    log "INFO" "✅ Synced: ${domain} -> ${current_target}"
  done

  # Prune orphans (only those matching our target IPs)
  local orphans
  orphans=$(echo "$list_json" | /usr/bin/jq -c --arg ip "$target_ip" '.[] | select(.answer==$ip)')
  if [[ -n "$orphans" && "$orphans" != "null" ]]; then
    while read -r row; do
      [[ -z "$row" || "$row" == "null" ]] && continue
      local dom
      dom=$(echo "$row" | /usr/bin/jq -r '.domain')
      if [[ -z "${desired_map[$dom]:-}" ]]; then
        /usr/bin/curl -s -X POST --max-time 10 "http://${adguard_host}/control/rewrite/delete" \
          -u "${ADGUARD_USER}:${ADGUARD_PASS}" -H "Content-Type: application/json" \
          -d "$row" >/dev/null
        log "INFO" "🗑 Pruned: ${dom}"
      fi
    done <<< "$orphans"
  fi
}

# Gatus monitoring config generation helpers
gatus_init() {
  GATUS_TMP=$(/usr/bin/mktemp)
  log "DEBUG" "Initialized Gatus temp file: $GATUS_TMP"
}

gatus_add() {
  cat >> "$GATUS_TMP" <<EOGATUS
$1
EOGATUS
}

# Gatus deployment function with retry logic
gatus_deploy() {
  local gatus_server="$1"
  local config_file="$2"
  local config_dir="$3"
  local container_name="$4"
  local max_retries=2
  local retry=0
  
  # Check sshpass if password auth is configured
  if [[ -n "${GATUS_SSH_PASS:-}" ]] && ! command -v sshpass &>/dev/null; then
    log "ERROR" "sshpass not found but GATUS_SSH_PASS is set. Install sshpass or use SSH keys."
    return 1
  fi

  while [[ $retry -lt $max_retries ]]; do
    # Build ssh/scp commands
    local ssh_cmd=("/usr/bin/ssh" "-o" "ConnectTimeout=10" "-o" "StrictHostKeyChecking=no" "${GATUS_SSH_USER}@${gatus_server}")
    local scp_cmd=("/usr/bin/scp" "-o" "ConnectTimeout=10" "-o" "StrictHostKeyChecking=no" "${config_file}" "${GATUS_SSH_USER}@${gatus_server}:${config_dir}/${GATUS_AUTOGEN_FILE}")
    if [[ -n "${GATUS_SSH_PASS:-}" ]]; then
      ssh_cmd=("sshpass" "-p" "${GATUS_SSH_PASS}" "${ssh_cmd[@]}")
      scp_cmd=("sshpass" "-p" "${GATUS_SSH_PASS}" "${scp_cmd[@]}")
    fi

    # Compare md5 BEFORE deploying — skip SCP entirely if unchanged (avoids inotify hot-reload)
    local local_md5 remote_md5
    local_md5=$(md5sum "${config_file}" | awk '{print $1}')
    remote_md5=$("${ssh_cmd[@]}" "md5sum '${config_dir}/${GATUS_AUTOGEN_FILE}' 2>/dev/null | awk '{print \$1}'" 2>/dev/null)

    if [[ "$local_md5" == "$remote_md5" ]]; then
      log "INFO" "✅ Gatus config unchanged on ${gatus_server}, skipping deploy"
      return 0
    fi

    log "INFO" "Deploying Gatus config to ${gatus_server}:${config_dir}/${GATUS_AUTOGEN_FILE} (attempt $((retry+1))/$max_retries)..."
    if "${scp_cmd[@]}" 2>/dev/null; then
      "${ssh_cmd[@]}" "grep -q 'GATUS_CONFIG_PATH' /etc/systemd/system/gatus.service || (sed -i '/\[Service\]/a Environment=GATUS_CONFIG_PATH=${config_dir}' /etc/systemd/system/gatus.service && systemctl daemon-reload); systemctl restart gatus" 2>/dev/null
      log "INFO" "✅ Deployed and restarted gatus on ${gatus_server} (config changed)"
      return 0
    fi
    
    retry=$((retry+1))
    if [[ $retry -lt $max_retries ]]; then
      log "WARN" "Deploy attempt $retry failed for ${gatus_server}, retrying..."
      sleep 2
    fi
  done
  
  log "WARN" "Failed to deploy to ${gatus_server} after $max_retries attempts"
  return 1
}

# AdGuard sync for .lan records (real container IPs, one per container)
adguard_sync_lan() {
  local adguard_host="$1"
  shift
  local entries=("$@")  # format: "domain|ip"

  log "INFO" "Syncing .lan records to ${adguard_host}..."

  local list_json
  list_json=$(/usr/bin/curl -s -k --max-time 10 -u "${ADGUARD_USER}:${ADGUARD_PASS}" "http://${adguard_host}/control/rewrite/list")
  if [[ -z "$list_json" || "$list_json" == "null" ]]; then
    log "ERROR" "Failed to fetch rewrite list from ${adguard_host}"
    return 1
  fi

  declare -A desired_lan
  for _entry in "${entries[@]}"; do
    IFS='|' read -r _d _ip <<< "$_entry"
    desired_lan[$_d]="$_ip"
  done

  for _domain in "${!desired_lan[@]}"; do
    local _target="${desired_lan[$_domain]}"
    local _existing
    _existing=$(echo "$list_json" | /usr/bin/jq -r --arg d "$_domain" '.[] | select(.domain==$d) | .answer')
    if echo "$_existing" | /usr/bin/grep -qFx "$_target"; then
      while read -r _ans; do
        [[ -z "$_ans" || "$_ans" == "$_target" ]] && continue
        /usr/bin/curl -s -X POST --max-time 10 "http://${adguard_host}/control/rewrite/delete" \
          -u "${ADGUARD_USER}:${ADGUARD_PASS}" -H "Content-Type: application/json" \
          -d "$(/usr/bin/jq -nc --arg d "$_domain" --arg a "$_ans" '{domain:$d,answer:$a}')" >/dev/null
      done <<< "$_existing"
      continue
    fi
    if [[ -n "$_existing" ]]; then
      while read -r _ans; do
        [[ -z "$_ans" ]] && continue
        /usr/bin/curl -s -X POST --max-time 10 "http://${adguard_host}/control/rewrite/delete" \
          -u "${ADGUARD_USER}:${ADGUARD_PASS}" -H "Content-Type: application/json" \
          -d "$(/usr/bin/jq -nc --arg d "$_domain" --arg a "$_ans" '{domain:$d,answer:$a}')" >/dev/null
      done <<< "$_existing"
    fi
    /usr/bin/curl -s -X POST --max-time 10 "http://${adguard_host}/control/rewrite/add" \
      -u "${ADGUARD_USER}:${ADGUARD_PASS}" -H "Content-Type: application/json" \
      -d "$(/usr/bin/jq -nc --arg d "$_domain" --arg a "$_target" '{domain:$d,answer:$a}')" >/dev/null
    log "INFO" "✅ LAN: ${_domain} -> ${_target}"
  done

  # Prune orphan .lan records no longer in desired set
  while read -r _row; do
    [[ -z "$_row" || "$_row" == "null" ]] && continue
    local _dom
    _dom=$(echo "$_row" | /usr/bin/jq -r '.domain')
    if [[ -z "${desired_lan[$_dom]:-}" ]]; then
      /usr/bin/curl -s -X POST --max-time 10 "http://${adguard_host}/control/rewrite/delete" \
        -u "${ADGUARD_USER}:${ADGUARD_PASS}" -H "Content-Type: application/json" \
        -d "$_row" >/dev/null
      log "INFO" "🗑 Pruned LAN: ${_dom}"
    fi
  done < <(echo "$list_json" | /usr/bin/jq -c '.[] | select(.domain | endswith(".lan"))')
}

DST="/etc/traefik/dynamic"
PREFIX="autogen-"

mkdir -p "$DST"
CHANGED=false
GENERATED_FILES=()
QUERIED_NODES=()  # Actual Proxmox node names successfully contacted
DNS_DOMAINS=()
declare -A MANUAL_DNS_MAP
LAN_CANDIDATES=()  # format: "hostname|node|vmid|base_ip|pve_alias"

validate_ip() { [[ $1 =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; }
is_private_ip() { [[ $1 =~ ^${LAN_PREFIX} ]]; }
validate_port() { [[ $1 =~ ^[0-9]+$ ]] && [[ $1 -ge 1 && $1 -le 65535 ]]; }
validate_domain() { [[ $1 =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }
sanitize_name() { echo "$1" | /usr/bin/tr -cs '[:alnum:]_-' '_' | /usr/bin/sed 's/_*$//;s/^_*//'; }
get_ip_from_tags() {
  # Return the first 192.168.x.x IP found in tags
  while IFS= read -r _tip; do
    [[ -z "$_tip" ]] && continue
    if is_private_ip "$_tip"; then echo "$_tip"; return; fi
  done < <(echo "$1" | /usr/bin/grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
}

parse_ini_routes() {
  /usr/bin/awk '
    /^\[/ { gsub(/[\[\]]/, "", $0); section=$0; next }
    section != "" && /=/ {
      key=$1; sub(/=.*/, "", key); val=$0; sub(/[^=]*=/, "", val);
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key);
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val);
      if (length(key) && length(val)) printf "%s|%s|%s\n", section, key, val
    }
  '
}

# Initialize Gatus config if servers are configured
if [[ ${#GATUS_SERVERS[@]} -gt 0 ]]; then
  gatus_init
fi

for entry in "${PVE_SERVERS[@]}"; do
  IFS='|' read -r PVE_ALIAS API TOKEN <<< "$entry"
  NODES=$(/usr/bin/curl -ks --max-time 30 -H "Authorization: ${TOKEN}" "${API}/nodes" | /usr/bin/jq -r '.data[].node' 2>/dev/null) || continue

  for NODE in $NODES; do
    QUERIED_NODES+=("$NODE")
    for KIND in lxc qemu; do
      GUESTS=$(/usr/bin/curl -ks --max-time 30 -H "Authorization: ${TOKEN}" "${API}/nodes/${NODE}/${KIND}" | /usr/bin/jq -r '.data[] | "\(.vmid)|\(.status)"' 2>/dev/null) || continue
      for ID_STATUS in $GUESTS; do
        IFS='|' read -r ID GUEST_STATUS <<< "$ID_STATUS"
        CONFIG=$(/usr/bin/curl -ks --max-time 30 -H "Authorization: ${TOKEN}" "${API}/nodes/${NODE}/${KIND}/${ID}/config" | /usr/bin/jq -r '.data' 2>/dev/null) || continue
        NOTES=$(echo "$CONFIG" | /usr/bin/jq -r '.description // empty')
        NAME=$(echo "$CONFIG" | /usr/bin/jq -r '.hostname // .name')
        TAGS=$(echo "$CONFIG" | /usr/bin/jq -r '.tags // empty')
        BASE_IP=$(get_ip_from_tags "$TAGS")
        ROUTE_LINES=$(echo "$NOTES" | parse_ini_routes)
        [[ -z "$ROUTE_LINES" ]] && continue

        # Collect .lan candidate and Gatus checks only for running containers
        CONTAINER_LAN_IP=""
        if [[ "$GUEST_STATUS" == "running" ]]; then
          if is_private_ip "${BASE_IP:-}"; then
            CONTAINER_LAN_IP="$BASE_IP"
          else
            _name_lower=$(echo "$NAME" | /usr/bin/tr '[:upper:]' '[:lower:]')
            while IFS='|' read -r _r _k _v; do
              _r_lower=$(echo "$_r" | /usr/bin/tr '[:upper:]' '[:lower:]')
              if [[ "$_r_lower" == "$_name_lower" && "$_k" == "ip" ]] && is_private_ip "$_v"; then
                CONTAINER_LAN_IP="$_v"; break
              fi
            done < <(echo "$ROUTE_LINES")
          fi
          # Check if any [web] section has nossh = true (disables SSH monitoring for this container)
          NOSSH_FLAG=false
          while IFS='|' read -r _r _k _v; do
            [[ "$_k" == "nossh" && "$_v" == "true" ]] && NOSSH_FLAG=true
          done < <(echo "$ROUTE_LINES")

          if [[ -n "$CONTAINER_LAN_IP" ]]; then
            LAN_CANDIDATES+=("${NAME}|${NODE}|${ID}|${CONTAINER_LAN_IP}|${PVE_ALIAS}|${NOSSH_FLAG}")
          fi
        fi

        FILE="${DST}/${PREFIX}${NODE}-${NAME}-${ID}.yml"
        ROUTERS_TMP=$(/usr/bin/mktemp); SERVICES_TMP=$(/usr/bin/mktemp); MIDDLEWARES_TMP=$(/usr/bin/mktemp); TRANSPORTS_TMP=$(/usr/bin/mktemp)

        mapfile -t RIDS < <(echo "$ROUTE_LINES" | /usr/bin/cut -d'|' -f1 | /usr/bin/sort -u)
        for RID in "${RIDS[@]}"; do
                    DOMAIN=""; PORT=""; SEC=""; IP_O=""; PROTO=""; DNS_ONLY=""; WS=""; HEALTHPATH="";
          while IFS='|' read -r r k v; do
            [[ "$r" == "$RID" ]] && case "$k" in domain) DOMAIN="$v";; port) PORT="$v";; security) SEC="$v";; ip) IP_O="$v";; proto) PROTO="$v";; dns) DNS_ONLY="$v";; websocket) WS="$v";; healthpath) HEALTHPATH="$v";; esac
          done < <(echo "$ROUTE_LINES")
          if [[ -n "$DNS_ONLY" ]]; then
             if validate_domain "$DNS_ONLY"; then
               # Skip manual DNS mapping if this domain is tagged public
               if [[ "$(echo "$SEC" | /usr/bin/tr '[:upper:]' '[:lower:]')" == "public" ]]; then
                 log "INFO" "Skipping manual DNS record for public domain: $DNS_ONLY"
               else
                MY_IP="${IP_O:-$BASE_IP}"
                if validate_ip "$MY_IP"; then
                  log "INFO" "Manual DNS record: $DNS_ONLY -> $MY_IP"
                  DNS_DOMAINS+=("$DNS_ONLY")
                  MANUAL_DNS_MAP["$DNS_ONLY"]="$MY_IP"
                fi
               fi
             fi
             continue
          fi

          [[ -z "$DOMAIN" ]] || ! validate_port "$PORT" || ! validate_domain "$DOMAIN" && continue
          IP="${IP_O:-$BASE_IP}"; validate_ip "$IP" || continue

          # Gatus domain-level checks — only for running containers
          if [[ ${#GATUS_SERVERS[@]} -gt 0 && "$GUEST_STATUS" == "running" ]]; then
            SEC_LC=$(echo "$SEC" | /usr/bin/tr '[:upper:]' '[:lower:]')

            # Internal check: always — name is the real domain, group = Internal
            _email_alert=""
            { [[ -n "${GATUS_GOOGLECHAT_WEBHOOK:-}" ]] || [[ -n "${GATUS_TELEGRAM_TOKEN:-}" && -n "${GATUS_TELEGRAM_ID:-}" ]]; } && {
              _email_alert=$'\n  alerts:'
              [[ -n "${GATUS_GOOGLECHAT_WEBHOOK:-}" ]] && _email_alert+=$'\n    - type: googlechat'
              [[ -n "${GATUS_TELEGRAM_TOKEN:-}" && -n "${GATUS_TELEGRAM_ID:-}" ]] && _email_alert+=$'\n    - type: telegram'
            }
            gatus_add "
- name: ${DOMAIN}
  group: Internal
  url: \"http://${IP}:${PORT}\"
  interval: 30s
  conditions:
    - \"[STATUS] < 500\"
    - \"[RESPONSE_TIME] < 5000\"${_email_alert}"

            # External check: only for public services — group = Sites
            if [[ "$SEC_LC" == "public" ]]; then
              _ext_url="https://${DOMAIN}${HEALTHPATH}"
              gatus_add "
- name: ${DOMAIN}
  group: Sites
  url: \"${_ext_url}\"
  interval: 30s
  conditions:
    - \"[STATUS] == 200\"
    - \"[RESPONSE_TIME] < 1500\"
    - \"[CERTIFICATE_EXPIRATION] > 72h\"${_email_alert}"
            fi
          fi

          # Do not add local DNS records for domains tagged public
          if [[ "$(echo "$SEC" | /usr/bin/tr '[:upper:]' '[:lower:]')" == "public" ]]; then
            log "DEBUG" "Skipping DNS sync for public domain: $DOMAIN"
          else
            DNS_DOMAINS+=("$DOMAIN")
          fi

          MW=""
          case "$SEC" in private) MW="allow-internal";; password) MW="auth-basic";; oauth) MW="security-oauth";; auth) MW="authentik";; esac
          RNAME=$(sanitize_name "${NAME}-${ID}-${RID}")
          PROTOCOL="http"
          [[ "$(echo "$PROTO" | /usr/bin/tr '[:upper:]' '[:lower:]')" == "https" ]] && PROTOCOL="https"



          {
            echo "    ${RNAME}:"
            echo "      entryPoints: [websecure]"
            echo "      rule: Host(\`${DOMAIN}\`)"
            echo "      service: ${RNAME}"
            # WebSocket routes: skip header injection middleware to prevent WebSocket upgrade breakage
            if [[ "$(echo "$WS" | /usr/bin/tr '[:upper:]' '[:lower:]')" == "true" ]]; then
                      if [[ -n "$MW" ]]; then
                        echo "      middlewares: [$MW]"
                      fi
            else
              echo "      middlewares: [forward-headers-${RNAME}$( [[ -n "$MW" ]] && echo ", $MW" )]"
            fi
            echo "      tls: { certResolver: letsencrypt }"
          } >> "$ROUTERS_TMP"


          {
            echo "    ${RNAME}:"
            echo "      loadBalancer:"
            # WebSocket routes need passHostHeader: true to preserve Host header through the upgrade
            if [[ "$(echo "$WS" | /usr/bin/tr '[:upper:]' '[:lower:]')" == "true" ]]; then
              echo "        passHostHeader: true"
            fi
            echo "        servers: [{ url: \"${PROTOCOL}://${IP}:${PORT}\" }]"
            [[ "$PROTOCOL" == "https" ]] && echo "        serversTransport: ${RNAME}-transport"
          } >> "$SERVICES_TMP"

          if [[ "$PROTOCOL" == "https" ]]; then
            {
              echo "    ${RNAME}-transport:"
              echo "      serverName: \"${DOMAIN}\""
              echo "      insecureSkipVerify: true"
            } >> "$TRANSPORTS_TMP"
          fi

          {
            echo "    forward-headers-${RNAME}:"
            echo "      headers:"
            echo "        customRequestHeaders:"
            echo "          X-Forwarded-Proto: \"https\""
            echo "        customResponseHeaders:"
            echo "          Access-Control-Allow-Private-Network: \"true\""
            # Temporary fix: X-Forwarded-Host override breaks Authentik forwardAuth (overwrites protected service host with auth.example.com)
            # echo "          X-Forwarded-Host: \"${DOMAIN}\""
          } >> "$MIDDLEWARES_TMP"
        done

        FINAL_YAML=$(/usr/bin/mktemp)
        if [[ -s "$ROUTERS_TMP" ]]; then
          {
            echo "http:"
            echo "  middlewares:"
            /usr/bin/cat "$MIDDLEWARES_TMP"
            echo "  routers:"
            /usr/bin/cat "$ROUTERS_TMP"
            echo "  services:"
            /usr/bin/cat "$SERVICES_TMP"
            if [[ -s "$TRANSPORTS_TMP" ]]; then
              echo "  serversTransports:"
              /usr/bin/cat "$TRANSPORTS_TMP"
            fi
          } > "$FINAL_YAML"

          if [[ ! -f "$FILE" ]] || ! /usr/bin/cmp -s "$FINAL_YAML" "$FILE"; then
            /usr/bin/mv "$FINAL_YAML" "$FILE"
            log "INFO" "✅ UPDATED: $FILE"
            CHANGED=true
          else
            /usr/bin/rm -f "$FINAL_YAML"
          fi
          GENERATED_FILES+=("$FILE")
        fi
        /usr/bin/rm -f "$ROUTERS_TMP" "$SERVICES_TMP" "$MIDDLEWARES_TMP" "$TRANSPORTS_TMP"
      done
    done
  done
done

# Cleanup stale config - only delete files from servers that were queried
if [[ ${#QUERIED_NODES[@]} -gt 0 ]]; then
  for f in "${DST}/${PREFIX}"*.yml; do
    [[ -e "$f" ]] || continue
    file_node=$(basename "$f" | sed 's/autogen-\([^-]*\)-.*/\1/')
    node_queried=false
    for qn in "${QUERIED_NODES[@]}"; do
      [[ "$file_node" == "$qn" ]] && node_queried=true && break
    done
    if $node_queried; then
      keep=false; for g in "${GENERATED_FILES[@]}"; do [[ "$f" == "$g" ]] && keep=true && break; done
      $keep || { log "INFO" "Removing stale: $f"; /usr/bin/rm -f "$f"; }
    fi
  done
else
  log "WARN" "Skipping cleanup - all API queries failed"
fi

# Resolve .lan names with tiered deduplication:
#   Tier 1: hostname.lan
#   Tier 2: hostname-alias.lan   (if tier 1 collides)
#   Tier 3: hostname-alias-vmid.lan (guaranteed unique)
declare -A LAN_DNS_FINAL
if [[ ${#LAN_CANDIDATES[@]} -gt 0 ]]; then
  declare -A _hcount
  declare -A _hacount
  for _c in "${LAN_CANDIDATES[@]}"; do
    IFS='|' read -r _cn _ _ _ _ <<< "$_c"
    _hcount[$_cn]=$(( ${_hcount[$_cn]:-0} + 1 ))
  done
  for _c in "${LAN_CANDIDATES[@]}"; do
    IFS='|' read -r _cn _ _ _ _ca <<< "$_c"
    if [[ ${_hcount[$_cn]:-0} -gt 1 ]]; then
      _hacount["${_cn}-${_ca}"]=$(( ${_hacount["${_cn}-${_ca}"]:-0} + 1 ))
    fi
  done
  for _c in "${LAN_CANDIDATES[@]}"; do
    IFS='|' read -r _cn _cnode _cid _cip _ca <<< "$_c"
    _cn_lower=$(echo "$_cn" | /usr/bin/tr '[:upper:]' '[:lower:]')
    _lan_name=""
    if [[ ${_hcount[$_cn]:-0} -eq 1 ]]; then
      _lan_name="${_cn_lower}.lan"
    elif [[ ${_hacount["${_cn}-${_ca}"]:-0} -eq 1 ]]; then
      _lan_name="${_cn_lower}-${_ca}.lan"
    else
      _lan_name="${_cn_lower}-${_ca}-${_cid}.lan"
    fi
    LAN_DNS_FINAL[$_lan_name]="$_cip"
    log "DEBUG" "LAN: ${_cn} (${_cnode}/${_cid}) -> ${_lan_name} -> ${_cip}"
  done
fi

# Sync DNS (Traefik domains -> TRAEFIK_IP)
if [[ ${#DNS_DOMAINS[@]} -gt 0 ]]; then
  mapfile -t UNIQUE < <(printf '%s\n' "${DNS_DOMAINS[@]}" | /usr/bin/sort -u)
  adguard_sync_all "$ADGUARD_PRIMARY" "$TRAEFIK_IP" "${UNIQUE[@]}"
  adguard_sync_all "$ADGUARD_SECONDARY" "$TRAEFIK_IP" "${UNIQUE[@]}"
fi

# Sync .lan records (real container IPs, for internal service-to-service)
if [[ ${#LAN_DNS_FINAL[@]} -gt 0 ]]; then
  _LAN_ENTRIES=()
  for _ld in "${!LAN_DNS_FINAL[@]}"; do
    _LAN_ENTRIES+=("${_ld}|${LAN_DNS_FINAL[$_ld]}")
  done
  adguard_sync_lan "$ADGUARD_PRIMARY" "${_LAN_ENTRIES[@]}"
  adguard_sync_lan "$ADGUARD_SECONDARY" "${_LAN_ENTRIES[@]}"
fi

# Generate Gatus machine-level checks from LAN_CANDIDATES
if [[ ${#GATUS_SERVERS[@]} -gt 0 && ${#LAN_CANDIDATES[@]} -gt 0 ]]; then
  for _c in "${LAN_CANDIDATES[@]}"; do
    IFS='|' read -r _cn _cnode _cid _cip _ca _nossh <<< "$_c"
    [[ -z "$_cip" ]] && continue
    _mname=$(sanitize_name "${_ca}-${_cn}")

    _email_alert=""
    { [[ -n "${GATUS_GOOGLECHAT_WEBHOOK:-}" ]] || [[ -n "${GATUS_TELEGRAM_TOKEN:-}" && -n "${GATUS_TELEGRAM_ID:-}" ]]; } && {
      _email_alert=$'\n  alerts:'
      [[ -n "${GATUS_GOOGLECHAT_WEBHOOK:-}" ]] && _email_alert+=$'\n    - type: googlechat'
      [[ -n "${GATUS_TELEGRAM_TOKEN:-}" && -n "${GATUS_TELEGRAM_ID:-}" ]] && _email_alert+=$'\n    - type: telegram'
    }
    gatus_add "
- name: ${_mname}
  group: Hosts
  url: \"icmp://${_cip}\"
  interval: 30s
  conditions:
    - \"[CONNECTED] == true\"${_email_alert}"

    # Skip SSH check if container has nossh = true in its [web] section
    [[ "${_nossh}" == "true" ]] && continue
    gatus_add "
- name: ${_mname}
  group: SSH
  url: \"tcp://${_cip}:22\"
  interval: 30s
  conditions:
    - \"[CONNECTED] == true\"${_email_alert}"
  done
fi

# Deploy Gatus config to monitoring servers
if [[ ${#GATUS_SERVERS[@]} -gt 0 && -n "$GATUS_TMP" && -s "$GATUS_TMP" ]]; then
  log "INFO" "Deploying Gatus config to ${#GATUS_SERVERS[@]} server(s)..."

  # Sort endpoint blocks alphabetically so md5 is stable regardless of PVE API ordering
  /usr/bin/python3 -c "
import re
txt = open('${GATUS_TMP}').read()
blocks = re.split(r'\n(?=- name:)', txt.strip())
def skey(b):
    m = re.search(r'- name:\s+(\S+)', b)
    return m.group(1) if m else ''
blocks.sort(key=skey)
open('${GATUS_TMP}', 'w').write('\n'.join(blocks) + '\n')
" 2>/dev/null || true

  # Generate final Gatus config file
  {
    if [[ -n "${GATUS_GOOGLECHAT_WEBHOOK:-}" || ( -n "${GATUS_TELEGRAM_TOKEN:-}" && -n "${GATUS_TELEGRAM_ID:-}" ) ]]; then
      echo "alerting:"
      if [[ -n "${GATUS_GOOGLECHAT_WEBHOOK:-}" ]]; then
        echo "  googlechat:"
        echo "    webhook-url: \"${GATUS_GOOGLECHAT_WEBHOOK}\""
        echo "    default-alert:"
        echo "      failure-threshold: 5"
        echo "      success-threshold: 2"
        echo "      send-on-resolved: true"
        echo "      minimum-reminder-interval: 24h"
      fi
      if [[ -n "${GATUS_TELEGRAM_TOKEN:-}" && -n "${GATUS_TELEGRAM_ID:-}" ]]; then
        echo "  telegram:"
        echo "    token: \"${GATUS_TELEGRAM_TOKEN}\""
        echo "    id: \"${GATUS_TELEGRAM_ID}\""
        echo "    default-alert:"
        echo "      failure-threshold: 5"
        echo "      success-threshold: 2"
        echo "      send-on-resolved: true"
        echo "      minimum-reminder-interval: 24h"
      fi
      echo ""
    fi
    echo "endpoints:"
    /usr/bin/cat "$GATUS_TMP"
  } > "${GATUS_TMP}.final"
  
  deploy_failed=0
  for gatus_server in "${GATUS_SERVERS[@]}"; do
    if ! gatus_deploy "$gatus_server" "${GATUS_TMP}.final" "$GATUS_CONFIG_DIR" "$GATUS_CONTAINER_NAME"; then
      deploy_failed=$((deploy_failed + 1))
    fi
  done
  
  /usr/bin/rm -f "${GATUS_TMP}.final"
  
  if [[ $deploy_failed -gt 0 ]]; then
    log "WARN" "Gatus deployment failed on $deploy_failed server(s) out of ${#GATUS_SERVERS[@]}"
  else
    log "INFO" "✅ Gatus config deployed to all servers"
  fi
fi

if $CHANGED; then
  /usr/bin/systemctl restart traefik
  log "INFO" "Traefik restarted"
fi
log "INFO" "Loop finished successfully"