#!/usr/bin/env bash

###############################################################################
# bin/authors/authors_export.sh
#
# Version:       1.0.2
# Last updated:  2026-09-03
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Regenerate the flat author list consumed by the toolchain
#   (data/fixtures/authors_list_from_db.txt) straight from the MariaDB
#   catalog, instead of maintaining a static snapshot by hand.
#
#   The SQL to run defaults to data/sql/qry_authors_4_and_5_all.sql (authors
#   with at least one book rated 4 or 5 and enough books overall); any query
#   that returns one author name per row works.
#
#   Connection settings use the SAME environment contract as the
#   BookTracker-import project (config/config.sh, "MySQL ingestion" section):
#   MYSQL_CLIENT / MYSQL_HOST / MYSQL_PORT / MYSQL_USER / MYSQL_PASSWORD /
#   MYSQL_DATABASE / MYSQL_EXTRA_ARGS, with the same defaults.  Both projects
#   talk to the same portable MariaDB on the Windows host.  The password is
#   passed via MYSQL_PWD only and never appears on the mysql command line.
#
#   The tool is intentionally read-only against the catalog: it connects with
#   the configured client, runs the query in batch mode, normalizes the rows
#   (BOM/CRLF, trailing whitespace, blank lines, literal NULL rows), and
#   writes the result.  MariaDB lifecycle mirrors bin/booktracker-ingest.sh:
#   if the server is not running it is started (elevated PowerShell) and,
#   because the exporter started it, stopped again on exit (graceful
#   SHUTDOWN with a taskkill fallback); a server that was already running is
#   left untouched.  --dry-run never starts or stops the server.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/authors/authors_export.sh [options]
#
#   Options:
#       -q, --query-file FILE   SQL file to execute
#                               [default: data/sql/qry_authors_4_and_5_all.sql]
#       -o, --output FILE       write the author list here
#                               [default: data/fixtures/authors_list_from_db.txt]
#                               ('-' writes to stdout)
#       -n, --dry-run           connect, count the authors, and report what
#                               would be written; change nothing
#       -d, --debug             print verbose diagnostics to stderr
#       -h, --help              show this help
#       -v, --version           print version and exit
#
#   Exit codes:
#       0   success (or --dry-run)
#       1   operational failure (client missing, server down, bad query)
#       2   usage error
#
#   Environment (all optional; same contract as BookTracker-import):
#       MYSQL_CLIENT      client binary (default: mysql)
#       MYSQL_HOST        server host (default: 127.0.0.1)
#       MYSQL_PORT        server port (default: 3306)
#       MYSQL_USER        login user (default: root)
#       MYSQL_PASSWORD    login password (default: empty; MYSQL_PWD only)
#       MYSQL_DATABASE    catalog database (default: flibusta)
#       MYSQL_EXTRA_ARGS  extra client option (default: --default-character-set=utf8)
#
#   MariaDB lifecycle (all optional; same defaults as BookTracker-import):
#       MARIA_TASKLIST      tasklist.exe path (default: /mnt/c/Windows/System32/tasklist.exe)
#       MARIA_TASKKILL      taskkill.exe path (default: /mnt/c/Windows/System32/taskkill.exe)
#       MARIA_EXE           mysqld.exe path  (default: C:\mariadb-10.4.7-winx64\bin\mysqld.exe)
#       MARIA_BIN_DIR       mysqld.exe dir   (default: C:\mariadb-10.4.7-winx64\bin)
#       MARIA_START_TIMEOUT seconds to wait for the server (default: 30)
#       MARIA_READY_TIMEOUT seconds per readiness probe (default: 5)
#       MARIA_STOP_TIMEOUT  seconds to wait for graceful shutdown (default: 15)
#
###############################################################################

set -euo pipefail

# --- shared infrastructure (refactor Phase 3) ----------------------------------
# common.sh sets set -Eeuo pipefail, resolves SCRIPT_DIR/PROJECT_ROOT at any
# bin/ depth, and provides log/debug/die; it does NOT source database.sh
# (opt-in), and mariadb_lifecycle.sh stays sourced explicitly below.
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"
common_init

# SCRIPT_VERSION is parsed from this file's own header (version-sync contract).
# shellcheck disable=SC2155  # sed+head pipeline cannot fail; masking not a concern
readonly SCRIPT_VERSION="$(sed -n 's/^# Version:[[:space:]]*//p' "$0" | head -n 1)"

# --- defaults (same contract as BookTracker-import config/config.sh) ---------
MYSQL_CLIENT="${MYSQL_CLIENT:-mysql}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_DATABASE="${MYSQL_DATABASE:-flibusta}"
MYSQL_EXTRA_ARGS="${MYSQL_EXTRA_ARGS:---default-character-set=utf8}"

# MariaDB lifecycle settings and functions come from the shared
# lib/mariadb_lifecycle.sh (sourced below).

QUERY_FILE="${QUERY_FILE:-$PROJECT_ROOT/data/sql/qry_authors_4_and_5_all.sql}"
OUTPUT_FILE="${OUTPUT_FILE:-$PROJECT_ROOT/data/fixtures/authors_list_from_db.txt}"
DRY_RUN=0

# --- shared MariaDB lifecycle (lib/mariadb_lifecycle.sh) -----------------------
# shellcheck source=../../lib/mariadb_lifecycle.sh
source "$PROJECT_ROOT/lib/mariadb_lifecycle.sh"

# EXIT trap: remove temp files and stop MariaDB only if this script started it.
cleanup() {
    [[ -n "${tmp_out:-}" ]] && rm -f "$tmp_out"
    [[ -n "${tmp_err:-}" ]] && rm -f "$tmp_err"
    [[ -n "${tmp_clean:-}" ]] && rm -f "$tmp_clean"
    mariadb_stop_if_started
    return 0
}
trap cleanup EXIT

print_help() {
    cat >&2 <<'EOF'
Usage: authors_export.sh [options]

Regenerate the flat author list (one name per line) from the MariaDB
catalog by running a query file, e.g. data/sql/qry_authors_4_and_5_all.sql.
Connection settings mirror the BookTracker-import contract (MYSQL_CLIENT,
MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD, MYSQL_DATABASE,
MYSQL_EXTRA_ARGS); the password is passed via MYSQL_PWD only.

MariaDB lifecycle: when the server is not running it is started (elevated
PowerShell, as in bin/booktracker-ingest.sh) and stopped again on exit
(graceful SHUTDOWN); a server that was already running is left untouched.
--dry-run never starts or stops the server (it reports what it would do).

Options:
  -q, --query-file FILE   SQL file to execute
                          [default: data/sql/qry_authors_4_and_5_all.sql]
  -o, --output FILE       write the author list here ('-' = stdout)
                          [default: data/fixtures/authors_list_from_db.txt]
  -n, --dry-run           connect, count the authors, change nothing
  -d, --debug             verbose diagnostics on stderr
  -h, --help              show this help
  -v, --version           print version and exit

Exit codes: 0 success, 1 operational failure, 2 usage error.
EOF
}

# --- arg parsing --------------------------------------------------------------
while (( $# > 0 )); do
    case "$1" in
        -q|--query-file)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a FILE argument" >&2; exit 2; }
            QUERY_FILE="$2"; shift 2 ;;
        --query-file=*) QUERY_FILE="${1#*=}"; shift ;;
        -o|--output)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a FILE argument" >&2; exit 2; }
            OUTPUT_FILE="$2"; shift 2 ;;
        --output=*) OUTPUT_FILE="${1#*=}"; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -d|--debug)   DEBUG=1; shift ;;
        -h|--help)    print_help; exit 0 ;;        -v|--version) echo "bin/authors/authors_export.sh v$SCRIPT_VERSION"; exit 0 ;;
        *) echo "Error: unknown option '$1'" >&2; echo "Try '$0 --help'." >&2; exit 2 ;;
    esac
done

# --- validation ----------------------------------------------------------------
[[ -n "${MYSQL_DATABASE:-}" ]] || die "MYSQL_DATABASE is empty (set it, e.g. flibusta)"
[[ -f "$QUERY_FILE" ]] || die "query file not found: $QUERY_FILE"
if ! command -v "${MYSQL_CLIENT:-mysql}" >/dev/null 2>&1; then
    die "${MYSQL_CLIENT:-mysql} not found; install a mysql/mariadb client or set MYSQL_CLIENT"
fi

# --- MariaDB lifecycle: start when down, stop on exit when we started it -------
mariadb_maybe_start \
    || die "cannot start MariaDB (accept the UAC prompt or run WSL2 elevated, or start the server manually)"

# --- build the client argv (password never included) --------------------------
mysql_args=("${MYSQL_CLIENT:-mysql}")
[[ -n "${MYSQL_HOST:-}" ]] && mysql_args+=(-h "$MYSQL_HOST" --protocol=TCP)
[[ -n "${MYSQL_PORT:-}" ]] && mysql_args+=(-P "$MYSQL_PORT")
[[ -n "${MYSQL_USER:-}" ]] && mysql_args+=(-u "$MYSQL_USER")
[[ -n "${MYSQL_EXTRA_ARGS:-}" ]] && mysql_args+=("$MYSQL_EXTRA_ARGS")

# The server may ignore the client's handshake charset (e.g. configured with
# skip-character-set-client-handshake) and transcode results to its own
# default (cp1251), which would corrupt the UTF-8 list.  Pin the session
# charset explicitly: honor --default-character-set from MYSQL_EXTRA_ARGS
# (default: utf8) via --init-command, which the server always applies.
charset="utf8"
case " ${MYSQL_EXTRA_ARGS:-} " in
    *" --default-character-set="*)
        charset="${MYSQL_EXTRA_ARGS##*--default-character-set=}"
        charset="${charset%% *}"
        ;;
esac
mysql_args+=(--init-command="SET NAMES $charset")

[[ -n "${MYSQL_DATABASE:-}" ]] && mysql_args+=("$MYSQL_DATABASE")

# Batch mode: -B tab-separated rows, --skip-column-names, --raw = no escaping.
mysql_args+=(-B --skip-column-names --raw)

debug "mysql argv (password omitted): ${mysql_args[*]}"
debug "query file: $QUERY_FILE"

# --- run the query (stdin = query file with BOM/CRLF normalized) --------------
# Output rows are captured to a temp file so the write is atomic and the row
# count is known before anything is touched.
tmp_out="$(mktemp)"
tmp_err="$(mktemp)"

# The query file lives in Windows/CR format; strip CRs so mysql parses it.
run_rc=0
sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' < "$QUERY_FILE" \
    | { if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
            MYSQL_PWD="$MYSQL_PASSWORD" "${mysql_args[@]}" > "$tmp_out" 2> "$tmp_err"
        else
            "${mysql_args[@]}" > "$tmp_out" 2> "$tmp_err"
        fi
      } || run_rc=$?

if (( run_rc != 0 )); then
    log "error: mysql query failed (exit $run_rc)"
    sed 's/^/  /' "$tmp_err" >&2
    die "query failed; is MariaDB running? (start it first)"
fi

if (( DEBUG )); then
    debug "query returned $(wc -l < "$tmp_out" | tr -d ' ') raw row(s)"
fi

# --- normalize rows: BOM, CR, trailing whitespace, blanks, literal NULL --------
# Literal "NULL" rows appear when the SELECT concatenates a NULL name part
# (MariaDB CONCAT returns NULL); such authors carry no usable name, so they
# are counted and dropped rather than polluting the list with a "NULL" entry.
tmp_clean="$(mktemp)"

sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -e 's/[[:space:]]*$//' "$tmp_out" \
    | grep -v '^$' \
    > "$tmp_clean" || true

null_count=0
if grep -q -x 'NULL' "$tmp_clean"; then
    null_count="$(grep -c -x 'NULL' "$tmp_clean")"
    log "warn : dropped $null_count NULL row(s) (CONCAT of an empty name part)"
fi
grep -v -x 'NULL' "$tmp_clean" > "$tmp_out" || true   # reuse tmp_out for final rows

author_count="$(wc -l < "$tmp_out" | tr -d ' ')"
[[ -n "$author_count" ]] || author_count=0

# --- write or report -----------------------------------------------------------
if (( DRY_RUN )); then
    if [[ "$OUTPUT_FILE" == "-" ]]; then
        log "dry-run: $author_count author(s) would be written to stdout"
    else
        log "dry-run: $author_count author(s) would be written to $OUTPUT_FILE"
    fi
    exit 0
fi

if [[ "$OUTPUT_FILE" == "-" ]]; then
    cat "$tmp_out"
    log "info : $author_count author(s) written to stdout"
else
    out_dir="$(dirname "$OUTPUT_FILE")"
    [[ -d "$out_dir" ]] || die "output directory does not exist: $out_dir"
    mv "$tmp_out" "$OUTPUT_FILE"
    log "info : $author_count author(s) written to $OUTPUT_FILE"
fi

exit 0
