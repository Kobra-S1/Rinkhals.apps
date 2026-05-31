#!/bin/sh

. /useremain/rinkhals/.current/tools.sh

# ---------------------------------------------------------------------------
# Read writable user properties. These mirror the editable fields in the
# Rinkhals Web Configure drawer; defaults come from app.json's "default"
# entries via get_app_property when the user hasn't set a value.
# ---------------------------------------------------------------------------

# Map our "True"/"False" enum values to the literals Tailscale's CLI expects.
bool_for_cli() {
    case "$1" in
        True|true|1|yes) echo "true" ;;
        *) echo "false" ;;
    esac
}

read_user_settings() {
    SSH_ENABLED=$(bool_for_cli "$(get_app_property tailscale ssh_enabled)")
    USER_HOSTNAME=$(get_app_property tailscale hostname)
    ADVERTISE_EXIT_NODE=$(bool_for_cli "$(get_app_property tailscale advertise_exit_node)")
    ACCEPT_DNS=$(bool_for_cli "$(get_app_property tailscale accept_dns)")
    ACCEPT_ROUTES=$(bool_for_cli "$(get_app_property tailscale accept_routes)")
}

# ---------------------------------------------------------------------------
# Bring the daemon up. We always pass the current settings on the initial
# `tailscale up` call, then use `tailscale set` for any subsequent changes
# the user makes via the web portal.
# ---------------------------------------------------------------------------

tailscale_cli() {
    "$TAILSCALE_BIN_DIR/tailscale" --socket="$TAILSCALE_SOCKET" "$@"
}

start_daemon() {
    nohup "$TAILSCALE_BIN_DIR/tailscaled" \
        --tun=userspace-networking \
        --statedir="$TAILSCALE_DATA_DIR" \
        --socket="$TAILSCALE_SOCKET" \
        --port=41641 \
        > "$TAILSCALED_LOG_FILE" 2>&1 &

    echo $! > "$TAILSCALE_PID_FILE"
    sleep 3
}

bring_up() {
    UP_ARGS="--accept-dns=$ACCEPT_DNS --accept-routes=$ACCEPT_ROUTES --ssh=$SSH_ENABLED"
    if [ -n "$USER_HOSTNAME" ]; then
        UP_ARGS="$UP_ARGS --hostname=$USER_HOSTNAME"
    fi
    if [ "$ADVERTISE_EXIT_NODE" = "true" ]; then
        UP_ARGS="$UP_ARGS --advertise-exit-node"
    fi

    log "tailscale up $UP_ARGS"
    tailscale_cli up $UP_ARGS >> "$TAILSCALE_LOG_FILE" 2>&1 &
}

# Apply a single setting at runtime. Tailscale persists these in tailscaled's
# state so they survive restarts. We compare against what's already in effect
# (cached in APPLIED_*) so we don't spam the CLI every poll.
APPLIED_SSH=""
APPLIED_HOSTNAME=""
APPLIED_EXIT_NODE=""
APPLIED_DNS=""
APPLIED_ROUTES=""

apply_runtime_changes() {
    if [ "$SSH_ENABLED" != "$APPLIED_SSH" ]; then
        log "applying ssh=$SSH_ENABLED"
        tailscale_cli set --ssh="$SSH_ENABLED" >> "$TAILSCALE_LOG_FILE" 2>&1 \
            && APPLIED_SSH="$SSH_ENABLED"
    fi
    if [ "$USER_HOSTNAME" != "$APPLIED_HOSTNAME" ] && [ -n "$USER_HOSTNAME" ]; then
        log "applying hostname=$USER_HOSTNAME"
        tailscale_cli set --hostname="$USER_HOSTNAME" >> "$TAILSCALE_LOG_FILE" 2>&1 \
            && APPLIED_HOSTNAME="$USER_HOSTNAME"
    fi
    if [ "$ADVERTISE_EXIT_NODE" != "$APPLIED_EXIT_NODE" ]; then
        log "applying advertise-exit-node=$ADVERTISE_EXIT_NODE"
        tailscale_cli set --advertise-exit-node="$ADVERTISE_EXIT_NODE" >> "$TAILSCALE_LOG_FILE" 2>&1 \
            && APPLIED_EXIT_NODE="$ADVERTISE_EXIT_NODE"
    fi
    if [ "$ACCEPT_DNS" != "$APPLIED_DNS" ]; then
        log "applying accept-dns=$ACCEPT_DNS"
        tailscale_cli set --accept-dns="$ACCEPT_DNS" >> "$TAILSCALE_LOG_FILE" 2>&1 \
            && APPLIED_DNS="$ACCEPT_DNS"
    fi
    if [ "$ACCEPT_ROUTES" != "$APPLIED_ROUTES" ]; then
        log "applying accept-routes=$ACCEPT_ROUTES"
        tailscale_cli set --accept-routes="$ACCEPT_ROUTES" >> "$TAILSCALE_LOG_FILE" 2>&1 \
            && APPLIED_ROUTES="$ACCEPT_ROUTES"
    fi
}

# ---------------------------------------------------------------------------
# Status publishing. We poll `tailscale status --json`, extract the handful
# of fields the Rinkhals Web portal cares about into a compact JSON blob,
# and write it under the "status" property in the temp-config file the
# portal already polls for property values.
# ---------------------------------------------------------------------------

CONFIG_DIR=/tmp/rinkhals/apps
CONFIG_FILE="$CONFIG_DIR/tailscale.config"

# Write a single property into the temp config file. Use jq --arg so we
# don't have to worry about embedded quotes in the value (the status blob
# is itself a JSON string and would break a shell-interpolated jq expression).
write_temp_property() {
    local key=$1 value=$2
    mkdir -p "$CONFIG_DIR"
    local current
    current=$(cat "$CONFIG_FILE" 2>/dev/null)
    : "${current:='{}'}"
    echo "$current" | jq --arg k "$key" --arg v "$value" '.[$k] = $v' > "$CONFIG_FILE.tmp" \
        && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}

publish_status() {
    local raw status_json
    raw=$(tailscale_cli status --json 2>/dev/null)
    if [ -n "$raw" ]; then
        status_json=$(echo "$raw" | jq -c '{
            state: (.BackendState // "Unknown"),
            tailnet_ip: ((.TailscaleIPs // [])[0] // ""),
            magic_dns: (if (.MagicDNSSuffix // "") == "" then ""
                else ((.Self.HostName // "") + "." + .MagicDNSSuffix) end),
            tailnet_name: (.CurrentTailnet.Name // ""),
            hostname: (.Self.HostName // ""),
            ssh: (.Self.Capabilities // [] | any(. == "https://tailscale.com/cap/ssh")),
            exit_node: (.Self.ExitNodeOption // false),
            online: (.Self.Online // false),
            peer_count: ((.Peer // {}) | length)
        }' 2>/dev/null)
    fi
    [ -z "$status_json" ] && status_json='{"state":"Unknown"}'
    write_temp_property status "$status_json"
}

# Scrape the daemon log for a login URL. Tailscale only prints it while
# unauthenticated; once logged in this loop quickly stops finding new ones,
# which is fine - the existing value in the temp config stays put.
publish_login_url() {
    local line url
    line=$(tail -n 30 "$TAILSCALE_LOG_FILE" 2>/dev/null | grep https://login.tailscale.com | tail -n 1)
    if [ -n "$line" ]; then
        url=$(echo "$line" | sed -r -e 's/.*(http[s]?:\/\/[^[:space:]]+).*/\1/')
        if [ -n "$url" ]; then
            write_temp_property account_login "$url"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

read_user_settings
start_daemon
bring_up

# Seed the "applied" cache with what we just passed to `tailscale up` so the
# first apply_runtime_changes pass is a no-op.
APPLIED_SSH="$SSH_ENABLED"
APPLIED_HOSTNAME="$USER_HOSTNAME"
APPLIED_EXIT_NODE="$ADVERTISE_EXIT_NODE"
APPLIED_DNS="$ACCEPT_DNS"
APPLIED_ROUTES="$ACCEPT_ROUTES"

while true; do
    read_user_settings
    apply_runtime_changes
    publish_login_url
    publish_status
    sleep 5
done
