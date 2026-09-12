#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# tests/test_library_backup.sh
#
# Regression suite for bin/library/library_backup.sh (mysqldump backup / restore
# of the app-registered personal library DB).  No real MariaDB is needed: the
# suite installs mock `mysql` and `mysqldump` earlier in PATH that record
# their argv (and, for restore, the stdin fed to the client).
#
# Asserts the tool's contract:
#   - backup: mysqldump argv matches the toolchain connection contract
#     (host/port/user via flags, password via MYSQL_PWD only, db last),
#     produces a gzip-valid <db>_<ts>.sql.gz containing the dump, logs the
#     table count; BACKUP_KEEP prunes older backups
#   - dry-run: reports would-backup, creates nothing
#   - restore: refuses a missing/invalid backup, refuses to overwrite a
#     NON-EMPTY library without --force, auto-backs-up the current state
#     first, feeds the gunzipped dump into `mysql <db>` (stdin asserted)
#   - verify: gzip + dump sanity (CREATE TABLE / Dump completed trailer)
#   - list: shows backups
#   - MariaDB lifecycle (mock tasklist + mock powershell.exe, mirroring the
#     BookTracker-import MARIA_MOCK_RUNNING pattern): an already-running
#     server is left untouched, a down server is started and stopped again
#     on exit, --dry-run only reports would-start / would-stop
#   - version header stays in sync with `--version` (1.0.x)
#
# Usage:  bash tests/test_library_backup.sh
# Runs anywhere (pure text processing; the mock avoids any DB dependency).
# -----------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$REPO_ROOT/bin/library/library_backup.sh"

PASS_COUNT=0
FAIL_COUNT=0
declare -a FAILURE_LINES=()

report() { # label  ok|fail  [detail]
    local label="$1" status="$2" detail="${3:-}"
    if [[ "$status" == "ok" ]]; then
        echo "  PASS  $label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL  $label"
        [[ -n "$detail" ]] && echo "        $detail"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILURE_LINES+=("$label: $detail")
    fi
}

TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/backup_test.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT

# --- mock mysql: records argv; with -e answers the emptiness probe; otherwise
#     records stdin (restore feed) ---------------------------------------------
MOCK_BIN="$TMPDIR/mockbin"
MOCK_LOG="$TMPDIR/mysql-argv.log"
MOCK_STDIN="$TMPDIR/mysql-stdin.txt"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/mysql" <<'MOCK_EOF'
#!/usr/bin/env bash
printf 'MYSQL %s\n' "$*" >> "${MOCK_LOG:-/dev/null}"
if [[ "$*" == *"-e"* ]]; then
    printf '%s\n' "${MOCK_DB_ROWS:-0}"
else
    cat > "${MOCK_STDIN:-/dev/null}"
fi
exit "${MOCK_RC:-0}"
MOCK_EOF
chmod +x "$MOCK_BIN/mysql"

# --- mock mysqldump: records argv, emits a plausible 17-table dump ------------
cat > "$MOCK_BIN/mysqldump" <<'MOCK_EOF'
#!/usr/bin/env bash
printf 'MYSQLDUMP %s\n' "$*" >> "${MOCK_LOG:-/dev/null}"
{
    echo "-- MariaDB dump 10.4  Distrib 10.4.7-MariaDB, for Win64"
    echo "-- Host: 127.0.0.1    Database: myprivatelib"
    for i in $(seq 1 17); do
        echo "CREATE TABLE \`mltable_$i\` ("
        echo "  \`id\` int(11) NOT NULL"
        echo ") ENGINE=MyISAM DEFAULT CHARSET=utf8;"
    done
    echo "INSERT INTO \`mltable_1\` VALUES (1);"
    echo "-- Dump completed on 2026-09-04  0:30:00"
}
exit "${MOCK_RC:-0}"
MOCK_EOF
chmod +x "$MOCK_BIN/mysqldump"

# --- mock tasklist / powershell.exe (lifecycle) -------------------------------
cat > "$MOCK_BIN/tasklist" <<'TASKLIST_EOF'
#!/usr/bin/env bash
if [[ "${MARIA_MOCK_RUNNING:-0}" == "1" ]]; then
    printf 'mysqld.exe                   26464 Console                    1    123,456 K\n'
fi
exit 0
TASKLIST_EOF
cat > "$MOCK_BIN/powershell.exe" <<'PS_EOF'
#!/usr/bin/env bash
printf 'PS %s\n' "$*" >> "${MOCK_LOG:-/dev/null}"
exit 0
PS_EOF
chmod +x "$MOCK_BIN/tasklist" "$MOCK_BIN/powershell.exe"

BACKUP_DIR="$TMPDIR/backups"

run_tool() { # [args...] ; stdout->$OUT, stderr->$ERR ; rc->$RC
    OUT="$TMPDIR/stdout.txt" ERR="$TMPDIR/stderr.txt"
    env PATH="$MOCK_BIN:$PATH" \
        MOCK_LOG="$MOCK_LOG" MOCK_STDIN="$MOCK_STDIN" \
        MOCK_DB_ROWS="${MOCK_DB_ROWS:-0}" MOCK_RC="${MOCK_RC:-0}" \
        MYSQL_PASSWORD="${MOCK_PASSWORD:-}" \
        MARIA_TASKLIST="${MARIA_TASKLIST_OVERRIDE:-$TMPDIR/no-such-tasklist}" \
        MARIA_MOCK_RUNNING="${MARIA_MOCK_RUNNING:-0}" \
        CONF_FILE="$TMPDIR/no-such.conf" \
        BACKUP_DIR="$BACKUP_DIR" BACKUP_DB="${BACKUP_DB:-myprivatelib}" \
        BACKUP_KEEP="${BACKUP_KEEP:-0}" \
        bash "$TOOL" "$@" >"$OUT" 2>"$ERR"
    RC=$?
}

echo "== library_backup =="

# --- version / usage -----------------------------------------------------------
version="$(sed -n 's/^# Version:[[:space:]]*//p' "$TOOL" | head -n 1)"
case "$version" in
    1.0.*) report "version_header" ok "header $version" ;;
    *)     report "version_header" fail "got '$version', expected 1.0.x" ;;
esac

bash "$TOOL" --version >"$TMPDIR/v.txt" 2>&1
if [[ "$(cat "$TMPDIR/v.txt")" == "bin/library/library_backup.sh v$version" ]]; then
    report "version_flag" ok
else
    report "version_flag" fail "got '$(cat "$TMPDIR/v.txt")'"
fi

bash "$TOOL" --help >"$TMPDIR/h.txt" 2>&1
if (( $? == 0 )) && grep -q -- "--force" "$TMPDIR/h.txt" && grep -q "restore" "$TMPDIR/h.txt"; then
    report "help_exit0" ok
else
    report "help_exit0" fail "help must exit 0 and list actions"
fi

bash "$TOOL" --bogus >"$TMPDIR/u.txt" 2>&1
if (( $? == 2 )); then
    report "unknown_option_exit2" ok
else
    report "unknown_option_exit2" fail "expected exit 2"
fi

bash "$TOOL" restore >"$TMPDIR/u2.txt" 2>&1
if (( $? == 2 )); then
    report "restore_without_file_exit2" ok
else
    report "restore_without_file_exit2" fail "expected exit 2"
fi

# --- backup: argv contract + gz artifact ----------------------------------------
rm -f "$MOCK_LOG"
MOCK_RC=0 run_tool backup
argv="$(cat "$MOCK_LOG")"
if [[ "$argv" == *"MYSQLDUMP -h 127.0.0.1 --protocol=TCP -P 3306 -u root --default-character-set=utf8 myprivatelib"* ]]; then
    report "backup_argv_contract" ok
else
    report "backup_argv_contract" fail "got: $argv"
fi
gz="$(ls -1 "$BACKUP_DIR"/myprivatelib_*.sql.gz 2>/dev/null | head -n 1 || true)"
if (( RC == 0 )) && [[ -n "$gz" ]] && gzip -t "$gz" \
   && [[ "$(zcat "$gz" | grep -c '^CREATE TABLE')" == "17" ]] \
   && grep -q "backed up myprivatelib (17 tables)" "$ERR"; then
    report "backup_creates_gz" ok
else
    report "backup_creates_gz" fail "rc=$RC gz=${gz:-none} stderr=$(head -2 "$ERR")"
fi

# --- password never on the command line ------------------------------------------
rm -f "$MOCK_LOG"
MOCK_RC=0 MOCK_PASSWORD=s3cret run_tool backup
argv="$(cat "$MOCK_LOG")"
if [[ "$argv" == *"s3cret"* ]]; then
    report "password_never_on_cmdline" fail "password leaked into argv"
else
    report "password_never_on_cmdline" ok
fi

# --- dry-run: reports, creates nothing ---------------------------------------------
rm -rf "$BACKUP_DIR"
MOCK_RC=0 run_tool --dry-run backup
if (( RC == 0 )) && [[ ! -e "$BACKUP_DIR" ]] \
   && grep -q "would back up myprivatelib" "$ERR"; then
    report "dry_run_no_write" ok
else
    report "dry_run_no_write" fail "rc=$RC dir=${BACKUP_DIR:-absent} stderr=$(head -2 "$ERR")"
fi

# --- retention: BACKUP_KEEP=1 prunes older backups ---------------------------------
rm -rf "$BACKUP_DIR"; mkdir -p "$BACKUP_DIR"
printf 'old1'  > "$BACKUP_DIR/myprivatelib_20200101-000000.sql.gz"
printf 'old2'  > "$BACKUP_DIR/myprivatelib_20200102-000000.sql.gz"
MOCK_RC=0 BACKUP_KEEP=1 run_tool backup
if (( RC == 0 )) && [[ "$(ls -1 "$BACKUP_DIR"/myprivatelib_*.sql.gz | wc -l)" == "1" ]] \
   && ! ls "$BACKUP_DIR"/myprivatelib_2020010*.sql.gz >/dev/null 2>&1 \
   && grep -q "pruning backups beyond the newest 1" "$ERR"; then
    report "retention_prunes" ok
else
    report "retention_prunes" fail "rc=$RC files=$(ls -1 "$BACKUP_DIR" 2>/dev/null | tr '\n' ' ')"
fi

# --- list ---------------------------------------------------------------------------
MOCK_RC=0 run_tool list
if (( RC == 0 )) && grep -q "myprivatelib_.*\.sql\.gz" "$OUT"; then
    report "list_shows_backups" ok
else
    report "list_shows_backups" fail "rc=$RC stdout=$(head -3 "$OUT")"
fi

# --- verify --------------------------------------------------------------------------
gz="$(ls -1 "$BACKUP_DIR"/myprivatelib_*.sql.gz | head -n 1)"
MOCK_RC=0 run_tool verify "$gz"
if (( RC == 0 )) && grep -q "OK: .* (17 tables, gzip valid)" "$ERR"; then
    report "verify_ok" ok
else
    report "verify_ok" fail "rc=$RC stderr=$(head -3 "$ERR")"
fi

printf 'junk' > "$TMPDIR/broken.gz"
MOCK_RC=0 run_tool verify "$TMPDIR/broken.gz"
if (( RC == 1 )) && grep -q "integrity check failed" "$ERR"; then
    report "verify_rejects_corrupt" ok
else
    report "verify_rejects_corrupt" fail "rc=$RC stderr=$(head -2 "$ERR")"
fi

# --- restore: missing file / empty DB path -------------------------------------------
MOCK_RC=0 run_tool restore "$TMPDIR/nope.sql.gz"
if (( RC == 1 )) && grep -q "backup file not found" "$ERR"; then
    report "restore_missing_file" ok
else
    report "restore_missing_file" fail "rc=$RC stderr=$(head -2 "$ERR")"
fi

rm -f "$MOCK_LOG" "$MOCK_STDIN"
MOCK_DB_ROWS=0 MOCK_RC=0 run_tool restore "$gz"
argv="$(cat "$MOCK_LOG")"
stdin="$(cat "$MOCK_STDIN" 2>/dev/null || true)"
if (( RC == 0 )) && grep -q "restored myprivatelib from" "$ERR" \
   && [[ "$argv" == *" myprivatelib" ]] \
   && [[ "$stdin" == *"CREATE TABLE"* ]] \
   && grep -q "backed up myprivatelib (17 tables)" "$ERR"; then
    report "restore_over_empty" ok
else
    report "restore_over_empty" fail "rc=$RC argv=$argv stdin_len=${#stdin}"
fi

# --- restore: refuses a non-empty library without --force ------------------------------
MOCK_DB_ROWS=3 MOCK_RC=0 run_tool restore "$gz"
if (( RC == 1 )) && grep -q "not empty; refusing to restore" "$ERR"; then
    report "restore_refuses_nonempty" ok
else
    report "restore_refuses_nonempty" fail "rc=$RC stderr=$(head -2 "$ERR")"
fi

# --- restore --force over non-empty: proceeds -------------------------------------------
rm -f "$MOCK_LOG" "$MOCK_STDIN"
MOCK_DB_ROWS=3 MOCK_RC=0 run_tool restore --force "$gz"
if (( RC == 0 )) && grep -q "restored myprivatelib from" "$ERR"; then
    report "restore_force_nonempty" ok
else
    report "restore_force_nonempty" fail "rc=$RC stderr=$(head -2 "$ERR")"
fi

# --- restore dry-run: reports, writes nothing ---------------------------------------------
MOCK_DB_ROWS=0 MOCK_RC=0 run_tool --dry-run restore "$TMPDIR/nope.sql.gz" >/dev/null 2>"$ERR"
if (( RC == 1 )) && grep -q "backup file not found" "$ERR"; then
    report "restore_dryrun_missing_still_errors" ok
else
    report "restore_dryrun_missing_still_errors" fail "rc=$RC stderr=$(head -2 "$ERR")"
fi
mkdir -p "$BACKUP_DIR"
gz_src="$(ls -1 "$BACKUP_DIR"/myprivatelib_*.sql.gz 2>/dev/null | head -n 1)"
gz2="$BACKUP_DIR/sample.sql.gz"
zcat "$gz_src" | gzip -c > "$gz2"
rm -f "$BACKUP_DIR"/myprivatelib_*.sql.gz
MOCK_DB_ROWS=0 MOCK_RC=0 run_tool --dry-run restore "$gz2"
if (( RC == 0 )) && [[ -z "$(ls -1 "$BACKUP_DIR" | grep -v sample)" ]] \
   && grep -q "would restore $gz2" "$ERR"; then
    report "restore_dryrun_reports_only" ok
else
    report "restore_dryrun_reports_only" fail "rc=$RC dir=$(ls -1 "$BACKUP_DIR" | tr '\n' ' ')"
fi

# --- MariaDB lifecycle (mock tasklist + mock powershell.exe) ----------------------------
echo "== MariaDB lifecycle =="

# 1) server already running -> left untouched
rm -f "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$MOCK_BIN/tasklist" MARIA_MOCK_RUNNING=1 MOCK_RC=0 run_tool list
if (( RC == 0 )) && grep -q "already running" "$ERR" \
   && ! grep -q "stopping MariaDB" "$ERR"; then
    report "lifecycle_already_running_untouched" ok
else
    report "lifecycle_already_running_untouched" fail "rc=$RC stderr=$(head -3 "$ERR")"
fi

# 2) server down -> started (elevated PS), used, stopped gracefully on exit
rm -f "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$MOCK_BIN/tasklist" MARIA_MOCK_RUNNING=0 MOCK_RC=0 run_tool list
if (( RC == 0 )) \
   && grep -q "starting MariaDB" "$ERR" \
   && grep -q "MariaDB ready" "$ERR" \
   && grep -q "stopping MariaDB (graceful shutdown)" "$ERR" \
   && grep -q "MariaDB stopped" "$ERR" \
   && grep -q "Start-Process" "$MOCK_LOG"; then
    report "lifecycle_start_use_stop" ok
else
    report "lifecycle_start_use_stop" fail "rc=$RC stderr=$(head -4 "$ERR") pslog=$(cat "$MOCK_LOG")"
fi

# 3) no tasklist interop -> management disabled, tool connects directly
rm -f "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$TMPDIR/no-such-tasklist" MOCK_RC=0 run_tool list
if (( RC == 0 )) && grep -q "tasklist not available" "$ERR" \
   && ! grep -q "starting MariaDB" "$ERR"; then
    report "lifecycle_no_tasklist_disables_mgmt" ok
else
    report "lifecycle_no_tasklist_disables_mgmt" fail "rc=$RC stderr=$(head -3 "$ERR")"
fi

# 4) dry-run reports would-start / would-stop, never touches the server
rm -f "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$MOCK_BIN/tasklist" MARIA_MOCK_RUNNING=0 MOCK_RC=0 run_tool --dry-run list
if (( RC == 0 )) && grep -q "\[dry-run\] would start MariaDB" "$ERR" \
   && grep -q "\[dry-run\] would stop MariaDB" "$ERR" \
   && ! grep -q "Start-Process" "$MOCK_LOG"; then
    report "lifecycle_dryrun_reports_only" ok
else
    report "lifecycle_dryrun_reports_only" fail "rc=$RC stderr=$(head -4 "$ERR") pslog=$(cat "$MOCK_LOG")"
fi

echo ""
echo "=============================="
echo "PASS: $PASS_COUNT   FAIL: $FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then
    printf '  - %s\n' "${FAILURE_LINES[@]}"
    exit 1
fi
echo "All tests passed."
exit 0