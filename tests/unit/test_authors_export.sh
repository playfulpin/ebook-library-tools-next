#!/usr/bin/env bash

# __ETL_TEST_ENV_GUARD__: a caller with set -x/set -v auto-exports SHELLOPTS;
# every child bash re-applies it (it is readonly when imported), so xtrace
# noise corrupts the suites output captures.  Re-exec clean instead.
if [[ ${SHELLOPTS-} == *xtrace* || ${SHELLOPTS-} == *verbose* ]]; then
    exec env -u SHELLOPTS -u BASHOPTS bash "$0" "$@"
fi
unset SHELLOPTS BASHOPTS 2>/dev/null || true

# -----------------------------------------------------------------------------
# tests/test_authors_export.sh
#
# Regression suite for bin/authors/authors_export.sh (the DB -> flat author
# list exporter).  No real MariaDB is needed: the suite installs a mock
# `mysql` earlier in PATH that records its argv and emits canned result rows.
#
# Asserts the exporter's contract:
#   - connection argv matches the BookTracker-import contract (host/port/user/
#     database via flags; password via MYSQL_PWD only, never on the command
#     line; batch + raw mode so rows come back unescaped)
#   - output normalization (BOM/CRLF, trailing whitespace, blank lines,
#     literal NULL rows are counted and dropped)
#   - dry-run counts and writes nothing; real runs write the file; stdout
#     mode; mysql failure is reported and leaves the output untouched
#   - MariaDB lifecycle (mock tasklist + mock powershell.exe, mirroring the
#     BookTracker-import MARIA_MOCK_RUNNING pattern): an already-running
#     server is left untouched, a down server is started and stopped again
#     on exit, a missing tasklist disables management, and --dry-run only
#     reports would-start / would-stop
#   - version header stays in sync with `--version` (1.0.x)
#
# Usage:  bash tests/test_authors_export.sh
# Runs anywhere (pure text processing; the mock avoids any DB dependency).
# -----------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXPORTER="$REPO_ROOT/bin/authors/authors_export.sh"

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

TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/export_test.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT

# --- mock mysql: records argv, emits $MOCK_ROWS_FILE rows, exits $MOCK_RC -----
MOCK_BIN="$TMPDIR/mockbin"
MOCK_LOG="$TMPDIR/mysql-argv.log"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/mysql" <<'MOCK_EOF'
#!/usr/bin/env bash
printf 'MYSQL %s\n' "$*" >> "${MOCK_LOG:-/dev/null}"
[[ -f "${MOCK_ROWS_FILE:-}" ]] && cat "$MOCK_ROWS_FILE"
exit "${MOCK_RC:-0}"
MOCK_EOF
chmod +x "$MOCK_BIN/mysql"

# rows fixture: trailing spaces, CRLF, a blank line, and a literal NULL row
ROWS_FILE="$TMPDIR/mock-rows.txt"
printf 'Абби Линн   \r\n'      >  "$ROWS_FILE"
printf 'Джо Аберкромби\r\n'    >> "$ROWS_FILE"
printf 'NULL\r\n'              >> "$ROWS_FILE"
printf '\r\n'                  >> "$ROWS_FILE"
printf 'Азимов Айзек \r\n'     >> "$ROWS_FILE"

QUERY_FILE="$TMPDIR/q.sql"
printf -- '-- mock query\r\nSELECT 1;\r\n' > "$QUERY_FILE"

OUT_FILE="$TMPDIR/authors.txt"

run_export() { # [args...] ; stdout->$OUT, stderr->$ERR ; rc->$RC
    OUT="$TMPDIR/stdout.txt" ERR="$TMPDIR/stderr.txt"
    # Point MARIA_TASKLIST at a nonexistent path by default so lifecycle
    # management is disabled (the exporter then connects directly); lifecycle
    # tests below override it with a mock tasklist via MARIA_TASKLIST_OVERRIDE.
    env PATH="$MOCK_BIN:$PATH" \
        MOCK_LOG="$MOCK_LOG" MOCK_ROWS_FILE="$ROWS_FILE" MOCK_RC="${MOCK_RC:-0}" \
        MYSQL_PASSWORD="${MOCK_PASSWORD:-}" \
        MARIA_TASKLIST="${MARIA_TASKLIST_OVERRIDE:-$TMPDIR/no-such-tasklist}" \
        MARIA_MOCK_RUNNING="${MARIA_MOCK_RUNNING:-0}" \
        QUERY_FILE="$QUERY_FILE" OUTPUT_FILE="$OUT_FILE" \
        bash "$EXPORTER" "$@" >"$OUT" 2>"$ERR"
    RC=$?
}

echo "== authors_export =="

# --- version / usage -----------------------------------------------------------
version="$(sed -n 's/^# Version:[[:space:]]*//p' "$EXPORTER" | head -n 1)"
if [[ "$version" =~ ^1\.0\.[0-9]+$ ]]; then
    report "version_header" ok "header $version"
else
    report "version_header" fail "got '$version', expected ^1.0.[0-9]+$"
fi

bash "$EXPORTER" --version >"$TMPDIR/v.txt" 2>&1
if [[ "$(cat "$TMPDIR/v.txt")" == "bin/authors/authors_export.sh v$version" ]]; then
    report "version_flag" ok
else
    report "version_flag" fail "got '$(cat "$TMPDIR/v.txt")'"
fi

bash "$EXPORTER" --help >"$TMPDIR/h.txt" 2>&1
if (( $? == 0 )) && grep -q -- "--query-file" "$TMPDIR/h.txt"; then
    report "help_exit0" ok
else
    report "help_exit0" fail "help must exit 0 and list options"
fi

bash "$EXPORTER" --bogus >"$TMPDIR/u.txt" 2>&1
if (( $? == 2 )); then
    report "unknown_option_exit2" ok
else
    report "unknown_option_exit2" fail "expected exit 2"
fi

# --- connection argv + password handling ----------------------------------------
rm -f "$MOCK_LOG"
MOCK_RC=0 MOCK_PASSWORD=s3cret run_export -o "$OUT_FILE"
argv="$(cat "$MOCK_LOG")"
if [[ -z "$argv" ]]; then
    report "mock_was_called" fail "mock mysql never invoked"
else
    report "mock_was_called" ok
fi
if [[ "$argv" == *"-h 127.0.0.1"* && "$argv" == *"--protocol=TCP"* \
      && "$argv" == *"-P 3306"* && "$argv" == *"-u root"* \
      && "$argv" == *"--default-character-set=utf8"* \
      && "$argv" == *"--init-command=SET NAMES utf8"* \
      && "$argv" == *" flibusta -B --skip-column-names --raw"* ]]; then
    report "argv_contract" ok
else
    report "argv_contract" fail "got: $argv"
fi
if [[ "$argv" == *"s3cret"* ]]; then
    report "password_never_on_cmdline" fail "password leaked into argv"
else
    report "password_never_on_cmdline" ok
fi

# --- real run: normalized rows written to the output file ----------------------
if [[ -f "$OUT_FILE" ]] \
   && [[ "$(wc -l < "$OUT_FILE" | tr -d ' ')" == "3" ]] \
   && ! grep -q 'NULL' "$OUT_FILE" \
   && ! grep -q ' $' "$OUT_FILE" \
   && ! grep -q $'\r' "$OUT_FILE" \
   && grep -q '^Абби Линн$' "$OUT_FILE" \
   && grep -q '^Джо Аберкромби$' "$OUT_FILE" \
   && grep -q '^Азимов Айзек$' "$OUT_FILE"; then
    report "real_run_normalizes" ok
else
    report "real_run_normalizes" fail "output: $(tr '\n' '|' < "$OUT_FILE" 2>/dev/null)"
fi

# --- NULL rows are reported -----------------------------------------------------
if grep -q "dropped 1 NULL row" "$ERR"; then
    report "null_rows_reported" ok
else
    report "null_rows_reported" fail "stderr: $(head -3 "$ERR")"
fi

# --- dry-run: counts authors, writes nothing ------------------------------------
rm -f "$OUT_FILE"
MOCK_RC=0 run_export --dry-run
if (( RC == 0 )) && [[ ! -e "$OUT_FILE" ]] \
   && grep -q "3 author(s) would be written" "$ERR"; then
    report "dry_run_counts_no_write" ok
else
    report "dry_run_counts_no_write" fail "rc=$RC out=${OUT_FILE:-missing} stderr=$(head -2 "$ERR")"
fi

# --- stdout mode ----------------------------------------------------------------
rm -f "$OUT_FILE"
MOCK_RC=0 run_export -o -
if (( RC == 0 )) && [[ "$(wc -l < "$OUT" | tr -d ' ')" == "3" ]] \
   && grep -q '^Джо Аберкромби$' "$OUT"; then
    report "stdout_mode" ok
else
    report "stdout_mode" fail "rc=$RC"
fi

# --- mysql failure: reported, output untouched -----------------------------------
printf 'old-content\n' > "$OUT_FILE"
MOCK_RC=7 run_export
if (( RC == 1 )) && [[ "$(cat "$OUT_FILE")" == "old-content" ]] \
   && grep -q "query failed" "$ERR"; then
    report "mysql_failure_rc1" ok
else
    report "mysql_failure_rc1" fail "rc=$RC content=$(cat "$OUT_FILE")"
fi
rm -f "$OUT_FILE"

# --- missing client / missing query file -----------------------------------------
env QUERY_FILE="$QUERY_FILE" OUTPUT_FILE="$OUT_FILE" \
    MYSQL_CLIENT=definitely-not-mysql \
    bash "$EXPORTER" >/dev/null 2>"$ERR"
if (( $? == 1 )) && grep -q "definitely-not-mysql not found" "$ERR"; then
    report "missing_client" ok
else
    report "missing_client" fail "stderr: $(head -2 "$ERR")"
fi

env PATH="$MOCK_BIN:$PATH" QUERY_FILE="$TMPDIR/nope.sql" OUTPUT_FILE="$OUT_FILE" \
    bash "$EXPORTER" >/dev/null 2>"$ERR"
if (( $? == 1 )) && grep -q "query file not found" "$ERR"; then
    report "missing_query_file" ok
else
    report "missing_query_file" fail "stderr: $(head -2 "$ERR")"
fi

# --- MariaDB lifecycle (mock tasklist + mock powershell.exe) ------------------
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

echo "== MariaDB lifecycle =="

# 1) server already running -> exporter connects and leaves it untouched
rm -f "$OUT_FILE" "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$MOCK_BIN/tasklist" MARIA_MOCK_RUNNING=1 MOCK_RC=0 run_export -o "$OUT_FILE"
if (( RC == 0 )) && grep -q "already running" "$ERR" \
   && ! grep -q "stopping MariaDB" "$ERR" \
   && grep -q '^Джо Аберкромби$' "$OUT_FILE"; then
    report "lifecycle_already_running_untouched" ok
else
    report "lifecycle_already_running_untouched" fail "rc=$RC stderr=$(head -3 "$ERR")"
fi

# 2) server down -> started (elevated PS), queried, stopped gracefully on exit
rm -f "$OUT_FILE" "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$MOCK_BIN/tasklist" MARIA_MOCK_RUNNING=0 MOCK_RC=0 run_export -o "$OUT_FILE"
if (( RC == 0 )) \
   && grep -q "starting MariaDB" "$ERR" \
   && grep -q "MariaDB ready" "$ERR" \
   && grep -q "stopping MariaDB (graceful shutdown)" "$ERR" \
   && grep -q "MariaDB stopped" "$ERR" \
   && grep -q "Start-Process" "$MOCK_LOG" \
   && grep -q '^Азимов Айзек$' "$OUT_FILE"; then
    report "lifecycle_start_query_stop" ok
else
    report "lifecycle_start_query_stop" fail "rc=$RC stderr=$(head -4 "$ERR") pslog=$(cat "$MOCK_LOG")"
fi

# 3) no tasklist interop -> management disabled, exporter connects directly
rm -f "$OUT_FILE" "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$TMPDIR/no-such-tasklist" MOCK_RC=0 run_export -o "$OUT_FILE"
if (( RC == 0 )) && grep -q "tasklist not available" "$ERR" \
   && ! grep -q "starting MariaDB" "$ERR" \
   && grep -q '^Абби Линн$' "$OUT_FILE"; then
    report "lifecycle_no_tasklist_disables_mgmt" ok
else
    report "lifecycle_no_tasklist_disables_mgmt" fail "rc=$RC stderr=$(head -3 "$ERR")"
fi

# 4) dry-run reports would-start / would-stop but never touches the server
rm -f "$OUT_FILE" "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$MOCK_BIN/tasklist" MARIA_MOCK_RUNNING=0 MOCK_RC=0 run_export --dry-run
if (( RC == 0 )) && grep -q "\\[dry-run\\] would start MariaDB" "$ERR" \
   && grep -q "\\[dry-run\\] would stop MariaDB" "$ERR" \
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
