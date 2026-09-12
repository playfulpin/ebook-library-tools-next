# -----------------------------------------------------------------------------
# lib/mariadb_lifecycle.sh
#
# Version:       1.0.1
# Last updated:  2026-09-03
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Shared MariaDB lifecycle management for tools that talk to the portable
#   MariaDB running on the Windows host (WSL2 <-> Windows interop), identical
#   to the logic in BookTracker-import's booktracker-ingest_functions.sh and
#   previously inlined in bin/authors/authors_export.sh.
#
#   The sourced tool defines `log()` (stderr timestamped line) and the
#   variables DRY_RUN and MYSQL_* before sourcing this file, then uses:
#
#       mariadb_maybe_start      start the server when it is down (or log
#                                would-start under --dry-run); aborts with a
#                                clear error when it cannot become ready
#       mariadb_stop_if_started  stop the server on exit - but only when this
#                                process started it (safe in an EXIT trap)
#
#   Behavior:
#     * mysqld.exe presence is checked via the Windows tasklist interop
#       (MARIA_TASKLIST).  When the interop binary is unavailable (e.g. plain
#       Linux CI) lifecycle management is disabled and the tool connects
#       directly.
#     * A stopped server is started with an elevated PowerShell
#       `Start-Process ... -Verb RunAs` (no UAC prompt when WSL2 runs
#       elevated), then polled with a bounded readiness probe - a connect to
#       an unbound 127.0.0.1 port can hang under WSL2 mirrored networking,
#       so every probe is wrapped in `timeout`.
#     * On exit the server is stopped with a graceful `SHUTDOWN` (flushes
#       MyISAM buffers so tables are not left marked crashed), waiting up to
#       MARIA_STOP_TIMEOUT before falling back to `taskkill /F`.
#     * A server that was already running is left untouched.
#
#   All settings are environment-overridable with the same defaults as
#   BookTracker-import config/config.sh:
#       MARIA_TASKLIST / MARIA_TASKKILL / MARIA_EXE / MARIA_BIN_DIR /
#       MARIA_START_TIMEOUT / MARIA_READY_TIMEOUT / MARIA_STOP_TIMEOUT
# -----------------------------------------------------------------------------

# --- defaults (same contract as BookTracker-import config/config.sh) ----------
# Client/connection defaults so every sourced tool probes and queries the
# Windows-side server over TCP (without -h, the client would use the local
# socket and never reach it).  Override with the same MYSQL_* env contract.
MYSQL_CLIENT="${MYSQL_CLIENT:-mysql}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_DATABASE="${MYSQL_DATABASE:-flibusta}"
MYSQL_EXTRA_ARGS="${MYSQL_EXTRA_ARGS:---default-character-set=utf8}"
MARIA_TASKLIST="${MARIA_TASKLIST:-/mnt/c/Windows/System32/tasklist.exe}"
MARIA_TASKKILL="${MARIA_TASKKILL:-/mnt/c/Windows/System32/taskkill.exe}"
MARIA_EXE="${MARIA_EXE:-C:\\mariadb-10.4.7-winx64\\bin\\mysqld.exe}"
MARIA_BIN_DIR="${MARIA_BIN_DIR:-C:\\mariadb-10.4.7-winx64\\bin}"
MARIA_START_TIMEOUT="${MARIA_START_TIMEOUT:-30}"
MARIA_READY_TIMEOUT="${MARIA_READY_TIMEOUT:-5}"
MARIA_STOP_TIMEOUT="${MARIA_STOP_TIMEOUT:-15}"
MARIA_MANAGE_OFF=0
_STARTED_MARIADB=0

# Return 0 when mysqld.exe is visible via the Windows tasklist interop.
# When the interop binary is unavailable, lifecycle management is disabled
# (MARIA_MANAGE_OFF=1) and the caller simply connects directly.
mariadb_running() {
    local tl="$MARIA_TASKLIST"
    if [[ ! -x "$tl" ]]; then
        log "warn : tasklist not available: $tl"
        MARIA_MANAGE_OFF=1
        return 1
    fi
    if "$tl" | grep -qi 'mysqld\.exe'; then
        return 0
    fi
    return 1
}

# Return 0 when the server actually answers a query (process presence is not
# enough: the elevated Start-Process can be slow or the UAC prompt can sit
# unaccepted).  The probe is bounded by `timeout` - an unbound 127.0.0.1
# port can hang instead of refusing under WSL2 mirrored networking.
mariadb_ready() {
    local probe_timeout="${MARIA_READY_TIMEOUT:-5}"
    local -a cmd=()
    if command -v timeout >/dev/null 2>&1; then
        cmd=(timeout "$probe_timeout")
    fi
    cmd+=("${MYSQL_CLIENT:-mysql}")
    [[ -n "${MYSQL_HOST:-}" ]] && cmd+=(-h "$MYSQL_HOST" --protocol=TCP)
    [[ -n "${MYSQL_PORT:-}" ]] && cmd+=(-P "$MYSQL_PORT")
    [[ -n "${MYSQL_USER:-}" ]] && cmd+=(-u "$MYSQL_USER")
    if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
        MYSQL_PWD="${MYSQL_PASSWORD}" "${cmd[@]}" -e "SELECT 1" >/dev/null 2>&1
    else
        "${cmd[@]}" -e "SELECT 1" >/dev/null 2>&1
    fi
}

# Start the portable MariaDB via an elevated PowerShell process.  Sets the
# guard so mariadb_stop_if_started knows it was this process that launched
# the server.  Returns 1 when the server does not answer within
# MARIA_START_TIMEOUT seconds.
mariadb_start() {
    local exe="$MARIA_EXE" dir="$MARIA_BIN_DIR" timeout="$MARIA_START_TIMEOUT" deadline
    if (( DRY_RUN )); then
        log "info : [dry-run] would start MariaDB: $exe --console"
        _STARTED_MARIADB=1
        return 0
    fi
    log "info : starting MariaDB (expect an elevated PowerShell window)"
    if ! command -v powershell.exe >/dev/null 2>&1; then
        log "error: powershell.exe not found; cannot start MariaDB (start it manually)"
        return 1
    fi
    if ! powershell.exe -NoProfile -Command \
        "Start-Process '$exe' -ArgumentList '--console' -WorkingDirectory '$dir' -Verb RunAs"; then
        log "error: failed to start MariaDB (Start-Process returned an error)"
        return 1
    fi
    _STARTED_MARIADB=1
    log "info : MariaDB start command issued; waiting for the server to answer..."
    deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        if mariadb_ready; then
            log "info : MariaDB ready"
            return 0
        fi
        sleep 1
    done
    log "error: MariaDB did not become ready within ${timeout}s (accept the UAC prompt or run WSL2 elevated)"
    _STARTED_MARIADB=0
    return 1
}

# Start the server when it is down; log and continue when lifecycle
# management is unavailable.  Aborts the tool (exit 1) when the start
# command was issued but the server never became ready.
mariadb_maybe_start() {
    if (( DRY_RUN )); then
        mariadb_start
        return 0
    fi
    if mariadb_running; then
        log "info : MariaDB already running; leaving it untouched"
        return 0
    fi
    if (( MARIA_MANAGE_OFF )); then
        log "info : MariaDB lifecycle management unavailable (no tasklist); connecting directly"
        return 0
    fi
    if ! mariadb_start; then
        return 1
    fi
    return 0
}

# Ask the running server to shut down cleanly (flushes MyISAM buffers).
mariadb_shutdown() {
    local -a cmd=("${MYSQL_CLIENT:-mysql}")
    [[ -n "${MYSQL_HOST:-}" ]] && cmd+=(-h "$MYSQL_HOST" --protocol=TCP)
    [[ -n "${MYSQL_PORT:-}" ]] && cmd+=(-P "$MYSQL_PORT")
    [[ -n "${MYSQL_USER:-}" ]] && cmd+=(-u "$MYSQL_USER")
    if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
        MYSQL_PWD="${MYSQL_PASSWORD}" "${cmd[@]}" -e "SHUTDOWN" >/dev/null 2>&1
    else
        "${cmd[@]}" -e "SHUTDOWN" >/dev/null 2>&1
    fi
}

# Stop MariaDB when this process started it (guard set): graceful SHUTDOWN
# first, wait up to MARIA_STOP_TIMEOUT for mysqld to exit, then taskkill /F.
# A no-op otherwise, so it is safe to call from an EXIT trap on every path.
mariadb_stop_if_started() {
    if (( MARIA_MANAGE_OFF )) || [[ "$_STARTED_MARIADB" != 1 ]]; then
        return 0
    fi
    if (( DRY_RUN )); then
        log "info : [dry-run] would stop MariaDB"
        _STARTED_MARIADB=0
        return 0
    fi
    log "info : stopping MariaDB (graceful shutdown)"
    local waited=0 timeout="$MARIA_STOP_TIMEOUT" client_pid
    mariadb_shutdown &
    client_pid=$!
    while (( waited < timeout )); do
        sleep 1
        if ! mariadb_running; then
            kill "$client_pid" 2>/dev/null || true
            wait "$client_pid" 2>/dev/null || true
            log "info : MariaDB stopped"
            _STARTED_MARIADB=0
            return 0
        fi
        waited=$((waited + 1))
    done
    kill "$client_pid" 2>/dev/null || true
    wait "$client_pid" 2>/dev/null || true
    log "warn : mysqld.exe still running after ${timeout}s; force-killing"
    local tk="$MARIA_TASKKILL"
    if [[ ! -x "$tk" ]]; then
        log "warn : taskkill not available: $tk"
        _STARTED_MARIADB=0
        return 0
    fi
    if "$tk" /F /IM mysqld.exe >/dev/null 2>&1; then
        log "info : MariaDB stopped (forced)"
    else
        log "warn : taskkill may not have stopped MariaDB (already exited?)"
    fi
    _STARTED_MARIADB=0
    return 0
}
