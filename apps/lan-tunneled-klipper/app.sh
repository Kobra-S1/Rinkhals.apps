source /useremain/rinkhals/.current/tools.sh

APP_ROOT=$(dirname $(realpath $0))
APP_NAME=$(basename "$APP_ROOT")
STATE_DIR="/tmp/lan_tunnel"
WATCHDOG_PID_FILE="$STATE_DIR/lanModeWatchdog.pid"
FAKE_GKAPI_PID_FILE="$STATE_DIR/fake_gkapi_server.pid"
SOCAT_MAIN_PORT=7003
SOCAT_NOZZLE_PORT=7005
SOCAT_MAIN_PID_FILE="$STATE_DIR/socat-$SOCAT_MAIN_PORT.pid"
SOCAT_NOZZLE_PID_FILE="$STATE_DIR/socat-$SOCAT_NOZZLE_PORT.pid"

property_is_enabled() {
    [ "$1" = "True" ] || [ "$1" = "true" ] || [ "$1" = "1" ]
}

# Stop only the udhcpc instance that k3sysui starts for the configured interface.
# It must be stopped before assigning our static IP, otherwise DHCP can overwrite it.
stop_udhcpc_for_interface() {
    local target_interface="$1"
    local pid cmdline_path command

    # Start with the existing Rinkhals helper only as a broad candidate list.
    # Each candidate is verified below before any signal is sent.
    for pid in $(get_by_name udhcpc); do
        cmdline_path="/proc/$pid/cmdline"
        [ -r "$cmdline_path" ] || continue

        # The first NUL-separated cmdline field is the executable path. Require
        # basename "udhcpc" so another command mentioning udhcpc is ignored.
        command=$(tr '\000' '\n' < "$cmdline_path" | sed -n '1p')
        case "${command##*/}" in
            udhcpc) ;;
            *) continue ;;
        esac

        # Match the exact argument pair "-i <interface>". This keeps DHCP clients
        # for other printer interfaces alive and avoids substring matches.
        if ! tr '\000' '\n' < "$cmdline_path" | awk -v interface="$target_interface" '
            previous == "-i" && $0 == interface { found = 1 }
            { previous = $0 }
            END { exit !found }
        '; then
            continue
        fi

        log "Stopping udhcpc PID $pid for interface $target_interface"
        kill -TERM "$pid" 2>/dev/null || true
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then
            log "Force-stopping udhcpc PID $pid for interface $target_interface"
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done
}

# Apply MAC first, bringing the interface up again if needed. That up event can make
# k3sysui launch udhcpc, so stop it before setting the static LAN tunnel address.
apply_network_config() {
    local interface="$1"
    local mac_address="$2"
    local ip_address="$3"
    local netmask="$4"

    # Check if MAC needs changing
    if [ -n "$mac_address" ]; then
        local current_mac=$(ifconfig "$interface" | grep -o 'HWaddr [^ ]*' | awk '{print $2}')
        if [ -z "$current_mac" ]; then
            current_mac=$(ifconfig "$interface" | grep -o 'ether [^ ]*' | awk '{print $2}')
        fi

        if [ "$current_mac" != "$mac_address" ]; then
            log "MAC address needs changing, bringing interface down"
            ifconfig "$interface" down
            sleep 1
            log "Setting MAC address to $mac_address"
            ifconfig "$interface" hw ether "$mac_address"
            ifconfig "$interface" up
            log "Waiting for k3sysui to spawn udhcpc for $interface"
            sleep 3
        fi
    else
        # Even without MAC change, ensure interface is up
        ifconfig "$interface" up
        log "Waiting for k3sysui to spawn udhcpc for $interface"
        sleep 3
    fi

    stop_udhcpc_for_interface "$interface"

    log "Setting IP $ip_address with netmask $netmask on running interface"
    ifconfig "$interface" "$ip_address" netmask "$netmask"
}

verify_network_config() {
    local interface="$1"
    local expected_mac="$2"
    local expected_ip="$3"

    # Dump interface status for debugging
    log "Interface $interface status:"
    ifconfig "$interface" 2>&1 | while IFS= read -r line; do log "  $line"; done

    # Get current IP address
    local current_ip=$(ifconfig "$interface" | grep 'inet addr:' | cut -d: -f2 | awk '{print $1}')
    if [ -z "$current_ip" ]; then
        current_ip=$(ifconfig "$interface" | grep 'inet ' | awk '{print $2}')
    fi

    log "Verifying interface $interface: current IP='$current_ip', expected IP='$expected_ip'"

    # Verify IP address
    if [ "$current_ip" != "$expected_ip" ]; then
        log "IP address verification failed: expected '$expected_ip', got '$current_ip'"
        return 1
    fi

    # Verify MAC address if specified
    if [ -n "$expected_mac" ]; then
        local current_mac=$(ifconfig "$interface" | grep -o 'HWaddr [^ ]*' | awk '{print $2}')
        if [ -z "$current_mac" ]; then
            current_mac=$(ifconfig "$interface" | grep -o 'ether [^ ]*' | awk '{print $2}')
        fi
        log "Verifying interface $interface: current MAC='$current_mac', expected MAC='$expected_mac'"
        if [ "$current_mac" != "$expected_mac" ]; then
            log "MAC address verification failed: expected '$expected_mac', got '$current_mac'"
            return 1
        fi
    fi

    return 0
}

configure_network() {
    NETWORK_ENABLED=$(get_app_property "$APP_NAME" network_enabled)
    property_is_enabled "$NETWORK_ENABLED" || return 0

    INTERFACE=$(get_app_property "$APP_NAME" interface)
    MAC_ADDRESS=$(get_app_property "$APP_NAME" mac_address)
    IP_ADDRESS=$(get_app_property "$APP_NAME" ip_address)
    NETMASK=$(get_app_property "$APP_NAME" netmask)

    if [ -z "$INTERFACE" ] || [ -z "$IP_ADDRESS" ] || [ -z "$NETMASK" ]; then
        log "Ethernet configuration skipped: interface, IP address, and netmask are required"
        return 1
    fi

    for attempt in 1 2 3; do
        log "Configuring Ethernet interface $INTERFACE (attempt $attempt)"
        apply_network_config "$INTERFACE" "$MAC_ADDRESS" "$IP_ADDRESS" "$NETMASK"
        sleep 1  # Allow interface to stabilize before verification

        if verify_network_config "$INTERFACE" "$MAC_ADDRESS" "$IP_ADDRESS"; then
            log "Ethernet interface $INTERFACE configured; checking again in 2 seconds for DHCP overwrite"
            sleep 2

            if verify_network_config "$INTERFACE" "$MAC_ADDRESS" "$IP_ADDRESS"; then
                log "Ethernet interface $INTERFACE configured successfully"
                return 0
            fi

            log "Ethernet configuration changed after initial verification"
        fi

        if [ "$attempt" -lt 3 ]; then
            log "Configuration verification failed, retrying in 2 seconds..."
            sleep 2
        fi
    done

    log "Failed to configure Ethernet interface $INTERFACE after 3 attempts"
    return 1
}

start_watchdog() {
    WATCHDOG_ENABLED=$(get_app_property "$APP_NAME" watchdog_enabled)
    property_is_enabled "$WATCHDOG_ENABLED" || return 0

    if [ -r "$WATCHDOG_PID_FILE" ] && kill -0 "$(cat "$WATCHDOG_PID_FILE")" 2>/dev/null; then
        log "LAN mode watchdog is already running"
        return 0
    fi

    log "Starting LAN mode watchdog"
    chmod +x "$APP_ROOT/lanModeWatchdog.sh"
    "$APP_ROOT/lanModeWatchdog.sh" &
    echo $! > "$WATCHDOG_PID_FILE"
}

stop_watchdog() {
    if [ -r "$WATCHDOG_PID_FILE" ]; then
        kill "$(cat "$WATCHDOG_PID_FILE")" 2>/dev/null || true
        rm -f "$WATCHDOG_PID_FILE"
    fi
}

record_socat_pid() {
    local pid="$1"
    local pid_file="$2"
    local start_time

    start_time=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)
    [ -n "$start_time" ] && echo "$pid $start_time" > "$pid_file"
}

get_recorded_socat_pid() {
    local pid_file="$1"
    local port="$2"
    local pid start_time command

    [ -r "$pid_file" ] || return 1
    read pid start_time < "$pid_file"

    case "$pid:$start_time" in
        *[!0-9:]*|:) return 1 ;;
    esac
    [ -r "/proc/$pid/cmdline" ] || return 1

    [ "$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start_time" ] || return 1

    command=$(tr '\000' '\n' < "/proc/$pid/cmdline" | sed -n '1p')
    case "${command##*/}" in
        socat) ;;
        *) return 1 ;;
    esac

    if ! tr '\000' '\n' < "/proc/$pid/cmdline" | awk -v listener="TCP-LISTEN:$port" '
        index($0, listener) == 1 { found = 1 }
        END { exit !found }
    '; then
        return 1
    fi

    echo "$pid"
}

stop_recorded_socat() {
    local pid_file="$1"
    local port="$2"
    local pid

    pid=$(get_recorded_socat_pid "$pid_file" "$port") || {
        rm -f "$pid_file"
        return 0
    }

    rm -f "$pid_file"
    log "Stopping socat PID $pid listening on TCP port $port"
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        log "Force-stopping socat PID $pid listening on TCP port $port"
        kill -KILL "$pid" 2>/dev/null || true
    fi
}

get_tunnel_listener_pids() {
    local pids=""
    local pid

    pid=$(get_recorded_socat_pid "$SOCAT_MAIN_PID_FILE" "$SOCAT_MAIN_PORT") && pids="$pid"
    pid=$(get_recorded_socat_pid "$SOCAT_NOZZLE_PID_FILE" "$SOCAT_NOZZLE_PORT") && pids="${pids}${pids:+ }$pid"

    echo "$pids"
}

stop_tunnel_listeners() {
    stop_recorded_socat "$SOCAT_MAIN_PID_FILE" "$SOCAT_MAIN_PORT"
    stop_recorded_socat "$SOCAT_NOZZLE_PID_FILE" "$SOCAT_NOZZLE_PORT"
}

start_fake_gkapi_server() {
    local pid start_time

    nohup python3 "$APP_ROOT/fake_gkapi_server.py" > /tmp/fake_gkapi.log 2>&1 &
    pid=$!
    start_time=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)
    [ -n "$start_time" ] && echo "$pid $start_time" > "$FAKE_GKAPI_PID_FILE"
}

stop_fake_gkapi_server() {
    local pid

    # Remove PID file if it exists
    rm -f "$FAKE_GKAPI_PID_FILE"

    # Find and stop all fake_gkapi_server.py processes
    for pid in $(ps | grep 'fake_gkapi_server.py' | grep -v grep | awk '{print $1}'); do
        log "Stopping fake gkapi server PID $pid"
        kill -TERM "$pid" 2>/dev/null || true
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then
            log "Force-stopping fake gkapi server PID $pid"
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done
}

reset_mcus() {
    case "${KOBRA_MODEL_CODE:-}" in
        KS1|KS1M)
            log "MCU Reset"
            echo 116 > /sys/class/gpio/export 2>/dev/null || true
            echo out > /sys/class/gpio/gpio116/direction
            echo 0 > /sys/class/gpio/gpio116/value
            sleep 1
            echo 1 > /sys/class/gpio/gpio116/value
            ;;
        *)
            log "MCU reset is not applicable for model ${KOBRA_MODEL_CODE:-unknown}; skipping"
            ;;
    esac
}

status() {
    mkdir -p "$STATE_DIR"
    PIDS=$(get_tunnel_listener_pids)

    if [ -n "$PIDS" ]; then
        report_status $APP_STATUS_STARTED "$PIDS"
    else
        report_status $APP_STATUS_STOPPED
    fi
}
start() {
        (
        mkdir -p "$STATE_DIR"
        echo 1 > "$STATE_DIR/.status"
        configure_network || exit 1
        sleep 5
        start_watchdog
        cd "$APP_ROOT"
        chmod +x ./pwm_jingle.sh
        ./pwm_jingle.sh start
        sleep 1
        log "Started lan_tunnel $EXAMPLE_VERSION from $APP_ROOT"

        sleep 17
        kill_by_name gklib

        reset_mcus

        log "Socat start"
        sleep 2
        stop_tunnel_listeners
        nice -n -20 socat -ly -d -d -T 10 TCP-LISTEN:$SOCAT_MAIN_PORT,reuseaddr,fork,max-children=1,nodelay,keepalive,keepidle=5,keepintvl=1,keepcnt=3 FILE:/dev/ttyS3,rawer,b576000,echo=0,clocal,crtscts=0 &
        record_socat_pid "$!" "$SOCAT_MAIN_PID_FILE"
        nice -n -20 socat -ly -d -d -T 10 TCP-LISTEN:$SOCAT_NOZZLE_PORT,reuseaddr,fork,max-children=1,nodelay,keepalive,keepidle=5,keepintvl=1,keepcnt=3 FILE:/dev/ttyS5,rawer,b576000,echo=0,clocal,crtscts=0 &
        record_socat_pid "$!" "$SOCAT_NOZZLE_PID_FILE"
        cd "$APP_ROOT"
        chmod +x ./pwm_jingle.sh
        ./pwm_jingle.sh imperial

        # --- GKAPI PATCH/Fake server logic (only for KS1) ---
        if [ "${KOBRA_MODEL_CODE:-}" = "KS1" ] || [ "${KOBRA_MODEL_CODE:-}" = "KS1M" ]; then
            "$APP_ROOT/gkapi_patched_run.sh" ensure-original || true
            killall -q gkapi 2>/dev/null || true
            start_fake_gkapi_server
        fi
        ) &
}

stop() {
    (
        mkdir -p "$STATE_DIR"
        echo 0 > "$STATE_DIR/.status"
        stop_watchdog
        log "Stopped lan_tunnel"
        stop_tunnel_listeners
        sleep 5
        reset_mcus
        sleep 2

        # --- GKAPI PATCH/Fake server logic (only for KS1) ---
        if [ "${KOBRA_MODEL_CODE:-}" = "KS1" ] || [ "${KOBRA_MODEL_CODE:-}" = "KS1M" ]; then
            stop_fake_gkapi_server
            "$APP_ROOT/gkapi_patched_run.sh" run-patched || true
        fi

        cd /userdata/app/gk
        LD_LIBRARY_PATH=/userdata/app/gk:$LD_LIBRARY_PATH \
                ./gklib -a /tmp/unix_uds1 /userdata/app/gk/printer_data/config/printer.generated.cfg &> $RINKHALS_ROOT/logs/gklib.log &
        log "gklib started"
    ) &
}

case "$1" in
    status)
        status
        ;;
    start)
        start
        ;;
    stop)
        stop
        ;;
    *)
        echo "Usage: $0 {status|start|stop}" >&2
        exit 1
        ;;
esac
