#!/usr/bin/env bash

###############################################################################
# bin/library/library_backup.sh
#
# Version:       1.0.0
# Last updated:  2026-09-12
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Backup and restore the app-registered personal library database
#   (myprivatelib) before anything is ever populated into it.  myprivatelib is
#   the sibling library the MultiLib desktop app created (same 17-table ml*
#   schema as flibusta, empty, connectable from the app); this tool is the
#   safety net that must exist BEFORE the population tool (Phase 1 of
#   docs/archive/REPRESENTATION_PLAN.md) writes the first row.
#
#   Actions:
#       backup          logical dump (mysqldump) of the library DB, gzipped
#                       into BACKUP_DIR as <db>_<timestamp>.sql.gz, then
#                       integrity-checked (gzip -t); optional retention prune
#       restore FILE    restore a backup over the current library DB.  SAFE BY
#                       DESIGN: the current state is backed up automatically
#                       first, and restoring over a NON-EMPTY library requires
#                       --force
#       verify FILE     check a backup file: gzip integrity + dump sanity
#                       (contains CREATE TABLE / ends with the dump trailer)
#       list            list backups newest first with sizes
#
#   Connection settings use the SAME environment contract as the rest of the
#   toolchain (and BookTracker-import): MYSQL_CLIENT / MYSQL_HOST /
#   MYSQL_PORT / MYSQL_USER / MYSQL_PASSWORD / MYSQL_EXTRA_ARGS, with the
#   same defaults.  The password is passed via MYSQL_PWD only and never
#   appears on a client command line.  mysqldump is used for backups;
#   MYSQLDUMP_CLIENT overrides it.  MariaDB lifecycle mirrors
#   bin/authors/authors_export.sh: a server that is down is started
#   (elevated PowerShell) and, because this tool started it, stopped again
#   on exit (graceful SHUTDOWN with a taskkill fallback); a server that was
#   already running is left untouched.  --dry-run never starts or stops the
#   server and never creates or overwrites anything.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/library/library_backup.sh [options] [backup | restore FILE | verify FILE | list]
#
#   Actions (positional; default: backup):
#       backup               dump + gzip the library DB into BACKUP_DIR
#       restore FILE         restore a backup over the current library DB
#                            (auto-backs-up the current state first; requires
#                            --force when the library is not empty)
#       verify FILE          integrity-check a backup file
#       list                 list backups newest first
#
#   Options:
#       -f, --force          allow restore over a non-empty library DB
#       -n, --dry-run        report what would happen; change nothing
#       -d, --debug          print verbose diagnostics to stderr
#       -h, --help           show this help
#       -v, --version        print version and exit
#
#   Exit codes:
#       0   success (or --dry-run)
#       1   operational failure (client missing, server down, bad backup)
#       2   usage error
#
#   Environment / config (config/library_backup.conf; all overridable):
#       BACKUP_DIR      where backups live (default: /mnt/c/Backup_Go7/myprivatelib-backups)
#       BACKUP_DB       the library database to back up (default: myprivatelib)
#       BACKUP_KEEP     keep only the N newest backups; 0 = keep all (default: 0)
#       MYSQLDUMP_CLIENT  mysqldump binary (default: mysqldump)
#       MYSQL_CLIENT / MYSQL_HOST / MYSQL_PORT / MYSQL_USER / MYSQL_PASSWORD /
#       MYSQL_EXTRA_ARGS   same contract as BookTracker-import
#       MYSQL_CONNECT_TIMEOUT  mysql client TCP connect bound in seconds (default: 10)
#       MYSQL_CALL_TIMEOUT  mysqldump call bound in seconds via `timeout` (default: 90)
#       MARIA_*         lifecycle settings (see lib/mariadb_lifecycle.sh)
#
###############################################################################

set -euo pipefail

# --- shared infrastructure (refactor Phase 3) ----------------------------------
# common.sh sets set -Eeuo pipefail, resolves SCRIPT_DIR/PROJECT_ROOT at any
# bin/ depth, and provides log/debug/die.
# shellcheck source=../../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"
common_init

# SCRIPT_VERSION is parsed from this file's own header (version-sync contract).
# shellcheck disable=SC2155  # sed+head pipeline cannot fail; masking not a concern
readonly SCRIPT_VERSION="$(sed -n 's/^# Version:[[:space:]]*//p' "$0" | head -n 1)"

# --- defaults (same contract as the rest of the toolchain) --------------------
MYSQL_CLIENT="${MYSQL_CLIENT:-mysql}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_EXTRA_ARGS="${MYSQL_EXTRA_ARGS:---default-character-set=utf8}"
MYSQLDUMP_CLIENT="${MYSQLDUMP_CLIENT:-mysqldump}"
# Bound the TCP connect: under WSL2 mirrored networking an unbound/hung
# 127.0.0.1 connect can block indefinitely instead of failing fast.
MYSQL_CONNECT_TIMEOUT="${MYSQL_CONNECT_TIMEOUT:-10}"

# --- config file ---------------------------------------------------------------
CONF_FILE="${CONF_FILE:-$PROJECT_ROOT/config/library_backup.conf}"
# shellcheck source=../../config/library_backup.conf
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

BACKUP_DIR="${BACKUP_DIR:-/mnt/c/Backup_Go7/myprivatelib-backups}"
BACKUP_DB="${BACKUP_DB:-myprivatelib}"
BACKUP_KEEP="${BACKUP_KEEP:-0}"
# shellcheck disable=SC2034  # read by lib/mariadb_lifecycle.sh + lib/logging.sh at runtime
DEBUG=0
# shellcheck disable=SC2034  # read by lib/mariadb_lifecycle.sh at runtime
DRY_RUN=0
FORCE=0

# --- shared MariaDB lifecycle (lib/mariadb_lifecycle.sh) -----------------------
# shellcheck source=../lib/mariadb_lifecycle.sh
source "$PROJECT_ROOT/lib/mariadb_lifecycle.sh"

# Shared client argv assembly, both clients (lib/database.sh — Follow-It §8:
# the DB client command line is a hard boundary owned by the lib).
# shellcheck source=../lib/database.sh
source "$PROJECT_ROOT/lib/database.sh"

cleanup() {
    [[ -n "${tmp_gz:-}" ]] && rm -f "$tmp_gz"
    [[ -n "${tmp_dump:-}" ]] && rm -f "$tmp_dump"
    [[ -n "${tmp_out:-}" ]] && rm -f "$tmp_out"
    mariadb_stop_if_started
    return 0
}
trap cleanup EXIT

# --- build client argv via lib/database.sh (password never included) ------------
# Both client argvs come from the shared lib (Follow-It §8); this tool adds
# the mysql-only WSL2 hung-connect guard (--connect-timeout) caller-side —
# mysqldump rejects the flag, so its calls are bounded with `timeout` instead.
build_client_args() { # name mysql|mysqldump -> sets $mysql_args / $mysqldump_args
    local which="$1"
    if [[ "$which" == mysqldump ]]; then
        mysqldump_args=()
        while IFS= read -r arg; do mysqldump_args+=("$arg"); done < <(db_mysqldump_argv "")
    else
        mysql_args=()
        while IFS= read -r arg; do mysql_args+=("$arg"); done < <(db_mysql_argv "")
        mysql_args+=(--connect-timeout="$MYSQL_CONNECT_TIMEOUT")
    fi
}

# Run the mysql client argv; stdin passes through (used for restore).
run_mysql() { # [args...]
    local -a a=("$@")
    if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
        MYSQL_PWD="$MYSQL_PASSWORD" "${a[@]}"
    else
        "${a[@]}"
    fi
}

# --- library non-empty check (table_rows is engine-accurate for MyISAM) ----------
library_has_rows() {
    local n
    n="$(run_mysql "${mysql_args[@]}" -N -e \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$BACKUP_DB' AND table_rows > 0" 2>/dev/null || true)"
    n="${n:-0}"
    [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 ))
}

# --- backup ------------------------------------------------------------------------
do_backup() {
    command -v "$MYSQLDUMP_CLIENT" >/dev/null 2>&1 \
        || die "${MYSQLDUMP_CLIENT} not found; install a mariadb-client or set MYSQLDUMP_CLIENT"
    local ts out tables
    ts="$(date +%Y%m%d-%H%M%S)"
    out="$BACKUP_DIR/${BACKUP_DB}_${ts}.sql.gz"
    if (( DRY_RUN )); then
        log "dry-run: would back up $BACKUP_DB -> $out"
        return 0
    fi
    mkdir -p "$BACKUP_DIR"
    tmp_dump="$(mktemp)"
    tmp_gz="$(mktemp)"
    tmp_err="$(mktemp)"
    debug "mysqldump argv (password omitted): ${mysqldump_args[*]} $BACKUP_DB"
    local dump_rc=0
    # `timeout` cannot exec a shell function, so the real binary is invoked
    # directly (with MYSQL_PWD when a password is set) whenever timeout is
    # available; otherwise fall back to run_mysql.
    if command -v timeout >/dev/null 2>&1; then
        if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
            MYSQL_PWD="$MYSQL_PASSWORD" timeout "${MYSQL_CALL_TIMEOUT:-90}" \
                "${mysqldump_args[@]}" "$BACKUP_DB" > "$tmp_dump" 2> "$tmp_err" || dump_rc=$?
        else
            timeout "${MYSQL_CALL_TIMEOUT:-90}" \
                "${mysqldump_args[@]}" "$BACKUP_DB" > "$tmp_dump" 2> "$tmp_err" || dump_rc=$?
        fi
    else
        run_mysql "${mysqldump_args[@]}" "$BACKUP_DB" > "$tmp_dump" 2> "$tmp_err" || dump_rc=$?
    fi
    if (( dump_rc != 0 )); then
        sed 's/^/  /' "$tmp_err" >&2 || true
        die "mysqldump failed for $BACKUP_DB (rc $dump_rc; server up? check MYSQL_* settings)"
    fi
    tables="$(grep -c '^CREATE TABLE' "$tmp_dump" || true)"
    gzip -c "$tmp_dump" > "$tmp_gz"
    gzip -t "$tmp_gz" || die "backup failed integrity check (gzip -t)"
    mv "$tmp_gz" "$out"; tmp_gz=""
    rm -f "$tmp_dump"; tmp_dump=""
    log "info : backed up $BACKUP_DB ($tables tables) -> $out"
    if (( BACKUP_KEEP > 0 )); then
        local keep=$((BACKUP_KEEP + 1))
        local old
        old="$(ls -1t "$BACKUP_DIR"/"${BACKUP_DB}"_*.sql.gz 2>/dev/null | tail -n +"$keep" || true)"
        if [[ -n "$old" ]]; then
            log "info : pruning backups beyond the newest $BACKUP_KEEP"
            printf '%s\n' "$old" | xargs -r rm -f
        fi
    fi
}

# --- restore --------------------------------------------------------------------------
do_restore() {
    local file="${1:-}"
    [[ -n "$file" ]] || { echo "Error: restore needs a FILE argument" >&2; exit 2; }
    [[ -f "$file" ]] || die "backup file not found: $file"
    if ! gzip -t "$file" 2>/dev/null; then
        die "backup failed integrity check (gzip -t): $file"
    fi
    if ! zcat "$file" 2>/dev/null | grep -q '^CREATE TABLE'; then
        die "backup does not look like a library dump (no CREATE TABLE): $file"
    fi
    if library_has_rows && (( ! FORCE )); then
        die "$BACKUP_DB is not empty; refusing to restore over it (use --force to overwrite)"
    fi
    log "info : restoring $file over $BACKUP_DB"
    if (( DRY_RUN )); then
        log "dry-run: would back up the current $BACKUP_DB state first (pre-restore safety copy)"
        log "dry-run: would restore $file (gunzip | $MYSQL_CLIENT $BACKUP_DB)"
        return 0
    fi
    # safe by design: back up the current state first
    do_backup
    tmp_out="$(mktemp)"
    if ! zcat "$file" 2>/dev/null | run_mysql "${mysql_args[@]}" "$BACKUP_DB" >/dev/null 2> "$tmp_out"; then
        sed 's/^/  /' "$tmp_out" >&2 || true
        die "restore failed; the pre-restore backup above preserves the previous state"
    fi
    log "info : restored $BACKUP_DB from $file"
}

# --- verify ----------------------------------------------------------------------------
do_verify() {
    local file="${1:-}"
    [[ -n "$file" ]] || { echo "Error: verify needs a FILE argument" >&2; exit 2; }
    [[ -f "$file" ]] || die "backup file not found: $file"
    if (( DRY_RUN )); then
        log "dry-run: would verify $file"
        return 0
    fi
    if ! gzip -t "$file" 2>/dev/null; then
        die "integrity check failed (gzip -t): $file"
    fi
    local tables trailer
    tables="$(zcat "$file" 2>/dev/null | grep -c '^CREATE TABLE' || true)"
    trailer="$(zcat "$file" 2>/dev/null | tail -1 | grep -c 'Dump completed' || true)"
    if (( tables == 0 )); then
        die "dump sanity check failed (no CREATE TABLE): $file"
    fi
    if (( trailer == 0 )); then
        log "warn : dump trailer ('-- Dump completed') not found in $file"
    fi
    log "info : OK: $file ($tables tables, gzip valid)"
}

# --- list -------------------------------------------------------------------------------
do_list() {
    if (( DRY_RUN )); then
        log "dry-run: would list backups in $BACKUP_DIR"
        return 0
    fi
    if [[ ! -d "$BACKUP_DIR" ]] || ! ls -1 "$BACKUP_DIR"/"${BACKUP_DB}"_*.sql.gz >/dev/null 2>&1; then
        log "info : no backups found in $BACKUP_DIR"
        return 0
    fi
    ls -lht "$BACKUP_DIR"/"${BACKUP_DB}"_*.sql.gz \
        | awk '{printf "%s  %8.1f MB  %s\n", $6, $5/1048576, $9}'
}

print_help() {
    cat >&2 <<'EOF'
Usage: library_backup.sh [options] [backup | restore FILE | verify FILE | list]

Backup and restore the personal library database (myprivatelib) with
mysqldump.  This is the safety net that must exist BEFORE anything is
populated into myprivatelib (see docs/archive/REPRESENTATION_PLAN.md).

Actions (positional; default: backup):
  backup               dump + gzip the library DB into BACKUP_DIR
  restore FILE         restore a backup over the current library DB;
                       backs up the current state first; refuses to
                       overwrite a non-empty library without --force
  verify FILE          integrity-check a backup file (gzip + dump sanity)
  list                 list backups newest first with sizes

Options:
  -f, --force          allow restore over a non-empty library DB
  -n, --dry-run        report what would happen; change nothing
  -d, --debug          verbose diagnostics on stderr
  -h, --help           show this help
  -v, --version        print version and exit

Exit codes: 0 success, 1 operational failure, 2 usage error.

Environment / config (config/library_backup.conf, all overridable):
  BACKUP_DIR / BACKUP_DB / BACKUP_KEEP
  MYSQLDUMP_CLIENT, MYSQL_CLIENT, MYSQL_HOST, MYSQL_PORT, MYSQL_USER,
  MYSQL_PASSWORD (MYSQL_PWD only), MYSQL_EXTRA_ARGS,
  MYSQL_CONNECT_TIMEOUT (mysql only, default: 10s), MYSQL_CALL_TIMEOUT
  (mysqldump bound, default: 90s), MARIA_*
EOF
}

# --- arg parsing ---------------------------------------------------------------------------
ACTION="backup"
RESTORE_FILE=""
while (( $# > 0 )); do
    case "$1" in
        backup|list)  ACTION="$1"; shift ;;
        restore|verify) ACTION="$1"; shift ;;
        -f|--force)   FORCE=1; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -d|--debug)
            # shellcheck disable=SC2034  # read by lib/logging.sh at runtime
            DEBUG=1; shift ;;
        -h|--help)    print_help; exit 0 ;;
        -v|--version) echo "bin/library/library_backup.sh v$SCRIPT_VERSION"; exit 0 ;;
        -*)
            echo "Error: unknown option '$1'" >&2; echo "Try '$0 --help'." >&2; exit 2 ;;
        *)
            # positional: the FILE argument for restore/verify (any order)
            if [[ -n "$RESTORE_FILE" ]]; then
                echo "Error: unexpected argument '$1'" >&2; echo "Try '$0 --help'." >&2; exit 2
            fi
            RESTORE_FILE="$1"; shift ;;
    esac
done

# --- post-parse validation of the positional FILE -------------------------------
case "$ACTION" in
    restore|verify)
        [[ -n "$RESTORE_FILE" ]] || { echo "Error: $ACTION needs a FILE argument" >&2; exit 2; }
        ;;
    *)
        [[ -z "$RESTORE_FILE" ]] || { echo "Error: unexpected argument '$RESTORE_FILE' for action '$ACTION'" >&2; exit 2; }
        ;;
esac

# --- validation -------------------------------------------------------------------------------
[[ -n "$BACKUP_DB" ]] || die "BACKUP_DB is empty"
command -v "$MYSQL_CLIENT" >/dev/null 2>&1 \
    || die "$MYSQL_CLIENT not found; install a mysql/mariadb client or set MYSQL_CLIENT"

build_client_args mysql
build_client_args mysqldump

# --- lifecycle + dispatch ---------------------------------------------------------------------
mariadb_maybe_start \
    || die "cannot start MariaDB (accept the UAC prompt or run WSL2 elevated, or start the server manually)"

case "$ACTION" in
    backup)  do_backup ;;
    restore) do_restore "$RESTORE_FILE" ;;
    verify)  do_verify "$RESTORE_FILE" ;;
    list)    do_list ;;
esac

exit 0