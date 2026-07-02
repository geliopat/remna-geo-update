#!/usr/bin/env bash
#
# remna-geo-update.sh
# -------------------
# Downloads geoip.dat / geosite.dat for a Remnawave node (remnanode) from the
# roscomvpn (hydraponique) release repos, into the exact path used by the
# DigneZzZ remnanode.sh installer, checks for updates once a day at night and
# only re-applies + restarts the node when a file actually changed.
#
# Sources:
#   https://github.com/hydraponique/roscomvpn-geoip
#   https://github.com/hydraponique/roscomvpn-geosite
#   https://github.com/hydraponique/roscomvpn-routing
#
# Target layout (DigneZzZ remnanode.sh):
#   /var/lib/remnanode/geoip.dat   -> container /usr/local/share/xray/geoip.dat
#   /var/lib/remnanode/geosite.dat -> container /usr/local/share/xray/geosite.dat
#
# Usage:
#   sudo bash remna-geo-update.sh install     # install script + daily timer, run once
#   sudo remna-geo-update.sh update           # run the update now (used by the timer)
#   sudo remna-geo-update.sh status           # show config, files and timer state
#   sudo remna-geo-update.sh uninstall        # remove timer/service + script
#
# All settings below can be overridden via env vars or /etc/remna-geo-update.conf
#
set -euo pipefail
umask 022

# ---------------------------- configuration ---------------------------------
APP_NAME="${APP_NAME:-remnanode}"
COMPOSE_FILE="${COMPOSE_FILE:-/opt/${APP_NAME}/docker-compose.yml}"
DATA_DIR="${DATA_DIR:-/var/lib/${APP_NAME}}"
CONTAINER="${CONTAINER:-remnanode}"

GEOIP_URL="${GEOIP_URL:-https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geoip.dat}"
GEOSITE_URL="${GEOSITE_URL:-https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geosite.dat}"

RESTART_ON_CHANGE="${RESTART_ON_CHANGE:-true}"   # restart node when a file changed
FILE_MODE="${FILE_MODE:-0644}"                   # 0644 = world-readable (any container UID)
FILE_OWNER="${FILE_OWNER:-root:root}"
MIN_SIZE="${MIN_SIZE:-4096}"                      # reject obviously bad/empty downloads (bytes)

LOG_FILE="${LOG_FILE:-/var/log/remna-geo-update.log}"
TIMER_CALENDAR="${TIMER_CALENDAR:-*-*-* 00:00:00}" # systemd OnCalendar (nightly, strictly 00:00)
TIMER_DELAY="${TIMER_DELAY:-0}"                     # RandomizedDelaySec; 0 = run strictly on time, >0 spreads the load

# Canonical raw URL of this script (used for self-install via `curl | bash`).
RAW_URL="${RAW_URL:-https://raw.githubusercontent.com/geliopat/remna-geo-update/main/remna-geo-update.sh}"

SELF_PATH="/usr/local/bin/remna-geo-update.sh"
CONF_FILE="/etc/remna-geo-update.conf"
LOCK_FILE="/run/remna-geo-update.lock"
SVC_NAME="remna-geo-update"

# Load optional persistent config (overrides defaults, env still wins if exported)
# shellcheck disable=SC1090
[ -f "$CONF_FILE" ] && . "$CONF_FILE"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# ------------------------------- helpers ------------------------------------
log() {
    local line="[$(date '+%F %T')] $*"
    echo "$line"
    { echo "$line" >>"$LOG_FILE"; } 2>/dev/null || true
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This command must be run as root (use sudo)." >&2
        exit 1
    fi
}

# Resolve the real host paths of the .dat files from docker-compose.yml,
# falling back to the DigneZzZ default ($DATA_DIR/<file>).
detect_geo_paths() {
    GEOIP_FILE="$DATA_DIR/geoip.dat"
    GEOSITE_FILE="$DATA_DIR/geosite.dat"
    [ -f "$COMPOSE_FILE" ] || return 0

    local line host
    line="$(grep -E ':/usr/local/share/xray/geoip\.dat([:[:space:]]|$)' "$COMPOSE_FILE" | head -n1 || true)"
    if [ -n "$line" ]; then
        host="$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/:.*$//; s/^["'\'']//; s/["'\'']$//')"
        [ -n "$host" ] && GEOIP_FILE="$host"
    fi
    line="$(grep -E ':/usr/local/share/xray/geosite\.dat([:[:space:]]|$)' "$COMPOSE_FILE" | head -n1 || true)"
    if [ -n "$line" ]; then
        host="$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/:.*$//; s/^["'\'']//; s/["'\'']$//')"
        [ -n "$host" ] && GEOSITE_FILE="$host"
    fi
}

# Warn if the compose file exists but has no geo volume mount: in that case the
# container uses the geo files baked into the image, not the ones we manage.
check_mounts() {
    [ -f "$COMPOSE_FILE" ] || return 0
    if ! grep -q ':/usr/local/share/xray/geoip\.dat' "$COMPOSE_FILE"; then
        log "WARNING: no geoip.dat volume mount found in $COMPOSE_FILE."
        log "         The node will use the image's built-in geo files, not $GEOIP_FILE."
        log "         Add these under the '${CONTAINER}' service 'volumes:' and re-up:"
        log "           - $DATA_DIR/geoip.dat:/usr/local/share/xray/geoip.dat"
        log "           - $DATA_DIR/geosite.dat:/usr/local/share/xray/geosite.dat"
        log "         then: docker compose -f $COMPOSE_FILE up -d"
    fi
}

# Download one file. Returns: 0 = updated, 1 = no change, 2 = error.
fetch_one() {
    local name="$1" url="$2" dest="$3"
    local dir tmp size first

    dir="$(dirname "$dest")"
    mkdir -p "$dir"
    tmp="$(mktemp "$dir/.${name}.XXXXXX")" || { log "ERROR: mktemp failed for $name"; return 2; }

    log "$name: downloading $url"
    if ! curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 20 --max-time 600 \
              -o "$tmp" "$url"; then
        log "ERROR: download failed for $name"
        rm -f "$tmp"; return 2
    fi

    size="$(stat -c%s "$tmp" 2>/dev/null || echo 0)"
    if [ "$size" -lt "$MIN_SIZE" ]; then
        log "ERROR: $name too small ($size bytes) - refusing to install"
        rm -f "$tmp"; return 2
    fi
    first="$(head -c 1 "$tmp" 2>/dev/null | tr -d '\0' || true)"
    if [ "$first" = "<" ]; then
        log "ERROR: $name looks like an HTML/error page - refusing to install"
        rm -f "$tmp"; return 2
    fi

    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        log "$name: no change ($size bytes)"
        rm -f "$tmp"; return 1
    fi

    chmod "$FILE_MODE" "$tmp" 2>/dev/null || true
    chown "$FILE_OWNER" "$tmp" 2>/dev/null || true
    if mv -f "$tmp" "$dest"; then          # atomic replace (same filesystem)
        log "$name: UPDATED ($size bytes) -> $dest"
        return 0
    fi
    log "ERROR: failed to install $name to $dest"
    rm -f "$tmp"; return 2
}

# Restart the node so Xray reloads the geo data (re-resolves the single-file
# bind mount to the new inode).
restart_node() {
    if ! command -v docker >/dev/null 2>&1; then
        log "WARNING: docker not found - cannot restart '$CONTAINER'."
        return 1
    fi
    log "Restarting node '$CONTAINER' to apply new geo files..."
    if [ -f "$COMPOSE_FILE" ] && docker compose version >/dev/null 2>&1; then
        if docker compose -f "$COMPOSE_FILE" restart "$CONTAINER" >>"$LOG_FILE" 2>&1; then
            log "Restarted via docker compose."
            return 0
        fi
    fi
    if docker restart "$CONTAINER" >>"$LOG_FILE" 2>&1; then
        log "Restarted via docker restart."
        return 0
    fi
    log "WARNING: failed to restart container '$CONTAINER'."
    return 1
}

# ------------------------------- actions ------------------------------------
do_update() {
    need_root

    # single-instance lock
    exec 9>"$LOCK_FILE" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then
        flock -n 9 || { log "Another update is already running - skipping."; exit 0; }
    fi

    command -v curl >/dev/null 2>&1 || { log "ERROR: curl is not installed."; exit 1; }

    detect_geo_paths
    check_mounts

    local changed=0 errors=0 rc
    set +e
    fetch_one geoip   "$GEOIP_URL"   "$GEOIP_FILE";   rc=$?
    case $rc in 0) changed=1 ;; 2) errors=1 ;; esac
    fetch_one geosite "$GEOSITE_URL" "$GEOSITE_FILE"; rc=$?
    case $rc in 0) changed=1 ;; 2) errors=1 ;; esac
    set -e

    if [ "$changed" -eq 1 ]; then
        if [ "$RESTART_ON_CHANGE" = "true" ]; then
            restart_node || errors=1
        else
            log "Geo files changed; restart disabled. Restart '$CONTAINER' manually to apply."
        fi
    else
        log "No changes - node not touched."
    fi

    if [ "$errors" -ne 0 ]; then
        log "Finished with errors."
        exit 1
    fi
    log "Finished OK."
}

install_systemd() {
    cat >"/etc/systemd/system/${SVC_NAME}.service" <<EOF
[Unit]
Description=Update Remnawave geoip.dat/geosite.dat (roscomvpn)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SELF_PATH} update
EOF

    {
        echo "[Unit]"
        echo "Description=Nightly update of Remnawave geo files (roscomvpn)"
        echo ""
        echo "[Timer]"
        echo "OnCalendar=${TIMER_CALENDAR}"
        if [ "${TIMER_DELAY:-0}" -gt 0 ] 2>/dev/null; then
            echo "RandomizedDelaySec=${TIMER_DELAY}"
        fi
        echo "Persistent=true"
        echo ""
        echo "[Install]"
        echo "WantedBy=timers.target"
    } >"/etc/systemd/system/${SVC_NAME}.timer"

    systemctl daemon-reload
    systemctl enable --now "${SVC_NAME}.timer"
    log "systemd timer '${SVC_NAME}.timer' enabled (OnCalendar=${TIMER_CALENDAR})."
}

install_cron() {
    cat >"/etc/cron.d/${SVC_NAME}" <<EOF
# Nightly update of Remnawave geo files (roscomvpn)
0 4 * * * root ${SELF_PATH} update >/dev/null 2>&1
EOF
    log "cron job installed at /etc/cron.d/${SVC_NAME} (04:00 daily)."
}

install_self() {
    need_root

    # Place the script at SELF_PATH. When run normally we copy $0; when run via
    # process substitution (curl | bash) $0 is a pipe, so fetch a fresh copy.
    local src; src="$(readlink -f "$0" 2>/dev/null || true)"
    if [ -n "$src" ] && [ -f "$src" ] && [ -r "$src" ] && [ -s "$src" ] && head -n1 "$src" | grep -q '^#!'; then
        [ "$src" != "$SELF_PATH" ] && install -m 0755 "$src" "$SELF_PATH"
    else
        log "Fetching script from $RAW_URL"
        if ! curl -fsSL "$RAW_URL" -o "$SELF_PATH"; then
            log "ERROR: could not download script from $RAW_URL"
            exit 1
        fi
        chmod 0755 "$SELF_PATH"
    fi
    log "Installed script -> $SELF_PATH"
    touch "$LOG_FILE" 2>/dev/null || true

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        install_systemd
    else
        log "systemd not detected - falling back to cron."
        install_cron
    fi

    log "Running an initial update..."
    "$SELF_PATH" update || log "Initial update reported a problem - check the log."
    log "Installation complete."
}

uninstall_self() {
    need_root
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "${SVC_NAME}.timer" 2>/dev/null || true
        rm -f "/etc/systemd/system/${SVC_NAME}.timer" "/etc/systemd/system/${SVC_NAME}.service"
        systemctl daemon-reload 2>/dev/null || true
    fi
    rm -f "/etc/cron.d/${SVC_NAME}"
    rm -f "$SELF_PATH"
    log "Removed timer/service and $SELF_PATH (kept geo files, $LOG_FILE and $CONF_FILE)."
}

show_status() {
    detect_geo_paths
    echo "=== remna-geo-update status ==="
    echo "Compose file : $COMPOSE_FILE"
    echo "Container    : $CONTAINER"
    echo "geoip   src  : $GEOIP_URL"
    echo "geosite src  : $GEOSITE_URL"
    echo "geoip   dest : $GEOIP_FILE"
    echo "geosite dest : $GEOSITE_FILE"
    echo
    echo "--- files ---"
    local f
    for f in "$GEOIP_FILE" "$GEOSITE_FILE"; do
        if [ -f "$f" ]; then
            ls -l --time-style=long-iso "$f"
        else
            echo "MISSING: $f"
        fi
    done
    echo
    if command -v systemctl >/dev/null 2>&1; then
        echo "--- timer ---"
        systemctl list-timers "${SVC_NAME}.timer" --no-pager 2>/dev/null || true
        echo
    fi
    echo "--- last log lines ---"
    tail -n 15 "$LOG_FILE" 2>/dev/null || echo "(no log yet)"
}

usage() {
    cat <<EOF
remna-geo-update.sh - manage roscomvpn geoip.dat/geosite.dat for a Remnawave node

Commands:
  install      Install this script to ${SELF_PATH}, set up a nightly timer and run once.
  update       Download + compare; replace and restart the node only if changed. (default)
  status       Show current configuration, files and timer state.
  uninstall    Remove the timer/cron job and the installed script.
  help         Show this help.

Override settings via env vars or ${CONF_FILE}, e.g.:
  RESTART_ON_CHANGE=false
  TIMER_CALENDAR="*-*-* 03:30:00"
  CONTAINER=remnanode
EOF
}

# ------------------------------- dispatch -----------------------------------
case "${1:-update}" in
    install)          install_self ;;
    update|run)       do_update ;;
    status)           show_status ;;
    uninstall|remove) uninstall_self ;;
    help|-h|--help)   usage ;;
    *) echo "Unknown command: $1" >&2; usage; exit 1 ;;
esac
