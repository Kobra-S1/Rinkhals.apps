#!/bin/sh

. /useremain/rinkhals/.current/tools.sh

APP_ROOT=$(dirname $(realpath $0))
LOG_FILE="${RINKHALS_LOGS:-/tmp/rinkhals}/app-cloud2lan-bridge.log"

cd "$APP_ROOT"

# Crash-loop-aware supervisor. Restarts the python script if it exits
# non-zero, rate-limited so a fast crash loop doesn't burn CPU forever.
# Modeled on moonraker.sh's start_moonraker_with_restart.
start_with_restart() {
    crash_count=0
    crash_window_start=$(date +%s)
    max_crashes=5
    crash_window=300   # 5 minutes
    cooldown=10

    while true; do
        # Reset the crash counter if we've been up for a while.
        current_time=$(date +%s)
        if [ $((current_time - crash_window_start)) -gt $crash_window ]; then
            crash_count=0
            crash_window_start=$current_time
        fi

        echo "$(date): Starting cloud2lan-bridge (crash count: $crash_count/$max_crashes)" >> "$LOG_FILE"
        python ./cloud2lan-bridge.py >> "$LOG_FILE" 2>&1
        exit_code=$?
        echo "$(date): cloud2lan-bridge exited with code $exit_code" >> "$LOG_FILE"

        # Exit code 0 = clean stop, don't respawn.
        if [ $exit_code -eq 0 ]; then
            echo "$(date): Clean shutdown, exiting supervisor" >> "$LOG_FILE"
            break
        fi

        crash_count=$((crash_count + 1))
        if [ $crash_count -ge $max_crashes ]; then
            echo "$(date): Too many crashes ($crash_count) in ${crash_window}s, giving up" >> "$LOG_FILE"
            break
        fi

        echo "$(date): Waiting ${cooldown}s before restart..." >> "$LOG_FILE"
        sleep $cooldown
    done
}

start_with_restart
