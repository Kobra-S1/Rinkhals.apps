. /useremain/rinkhals/.current/tools.sh

APP_ROOT=$(dirname $(realpath $0))

status() {
    PID=$(get_by_name cloud2lan-bridge.py)

    if [ "$PID" == "" ]; then
        report_status $APP_STATUS_STOPPED
    else
        report_status $APP_STATUS_STARTED "$PID"
    fi
}
start() {
    stop

    cd $APP_ROOT

    chmod +x cloud2lan-bridge.sh
    # Detach stdin/stdout/stderr from /dev/null. cloud2lan-bridge.sh is a
    # long-lived supervisor, so if it inherited this shell's fds it would hold
    # them open. When start is invoked from the on-screen menu (rinkhals-ui.py),
    # which captures the command's output through a pipe, that keeps the pipe's
    # write end open and hangs the UI (a frozen touchscreen). The supervisor
    # writes everything to app-cloud2lan-bridge.log.
    ./cloud2lan-bridge.sh </dev/null >/dev/null 2>&1 &
}
stop() {
    # Kill the supervisor first so it doesn't immediately respawn the python.
    kill_by_name cloud2lan-bridge.sh
    kill_by_name cloud2lan-bridge.py
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
