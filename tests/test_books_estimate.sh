#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# tests/test_books_estimate.sh
#
# Regression suite for bin/books/books_estimate.sh (the catalog download-
# size estimator for a to-collect author list).  No real MariaDB is needed:
# the suite installs a mock `mysql` earlier in PATH that records its argv,
# reads the query on stdin, and emits canned rows for the five query shapes:
# the authorid/name dump, per-author qualifying, distinct qualifying,
# per-author full-oeuvre, and distinct full-oeuvre.
#
# Asserts the estimator's contract:
#   - connection argv matches the BookTracker-import contract (host/port/user/
#     database via flags; password via MYSQL_PWD only, never on the command
#     line; batch + raw mode)
#   - the to-collect list is normalized (BOM/CRLF, trailing whitespace,
#     blanks) and resolved to catalog authorids via the dump (trailing-trim
#     on the CONCAT name); the aggregates carry an IN-list of the matched
#     ids; unmatched list authors are counted
#   - the summary carries the distinct qualifying (rated 4/5, Фантастика,
#     ru) and distinct full-oeuvre (all ru) totals and the top-rated
#     qualifying authors
#   - the per-author breakdown TSV is written sorted TOP-RATED FIRST
#     (5-rated qualifying books desc, then qualifying count desc), contains
#     only list authors, and its columns are
#     author|q_books|q_bytes|q_rating5|q_avg|f_books|f_bytes
#   - dry-run connects, summarizes, and writes no breakdown file
#   - mysql failure is reported (exit 1), missing client / missing input
#     file exit 1, unknown option exits 2
#   - MariaDB lifecycle (mock tasklist + mock powershell.exe): an
#     already-running server is left untouched, a down server is started
#     and stopped again on exit, and --dry-run only reports would-start /
#     would-stop
#   - version header stays in sync with `--version` (1.0.x)
#
# Usage:  bash tests/test_books_estimate.sh
# Runs anywhere (pure text processing; the mock avoids any DB dependency).
# -----------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ESTIMATOR="$REPO_ROOT/bin/books/books_estimate.sh"

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

TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/estimate_test.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT

# --- mock mysql: records argv, reads stdin, emits the matching fixture -------
MOCK_BIN="$TMPDIR/mockbin"
MOCK_LOG="$TMPDIR/mysql-argv.log"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/mysql" <<'MOCK_EOF'
#!/usr/bin/env bash
printf 'MYSQL %s\n' "$*" >> "${MOCK_LOG:-/dev/null}"
query="$(cat)"
printf 'INLIST %s\n' "$(printf '%s' "$query" | grep -o 'IN ([0-9, ]*)' | head -n 1)" >> "${MOCK_LOG:-/dev/null}"
case "$query" in
    *"SELECT authorid,"*) cat "${MOCK_DUMP_FILE:-/dev/null}" ;;
    *q_rating5*)          cat "${MOCK_QUAL_PER_FILE:-/dev/null}" ;;
    *overall_books*Фантастика*) cat "${MOCK_QUAL_OVERALL_FILE:-/dev/null}" ;;
    *overall_books*)      cat "${MOCK_FULL_OVERALL_FILE:-/dev/null}" ;;
    *f_books*)            cat "${MOCK_FULL_PER_FILE:-/dev/null}" ;;
esac
exit "${MOCK_RC:-0}"
MOCK_EOF
chmod +x "$MOCK_BIN/mysql"

# --- fixtures ---------------------------------------------------------------
# dump: authorid + trimmed CONCAT name ('Другой Автор' is in the catalog but
# NOT on the list -> its id 4 must never enter the IN-list)
DUMP_FILE="$TMPDIR/dump-rows.txt"
printf '1\tАбби Линн\n'      >  "$DUMP_FILE"
printf '2\tДжо Аберкромби\n' >> "$DUMP_FILE"
printf '3\tАзимов Айзек\n'   >> "$DUMP_FILE"
printf '4\tДругой Автор\n'   >> "$DUMP_FILE"

# per-author qualifying: name | q_books | q_bytes | q_rating5 | q_avg
QUAL_PER_FILE="$TMPDIR/qual-per-rows.txt"
printf 'Абби Линн\t2\t1024\t2\t5.0\n'  >  "$QUAL_PER_FILE"
printf 'Джо Аберкромби\t4\t2048\t3\t4.8\n' >> "$QUAL_PER_FILE"
printf 'Азимов Айзек\t10\t4096\t7\t4.9\n'  >> "$QUAL_PER_FILE"

# distinct qualifying overall: total books | total bytes
QUAL_OVERALL_FILE="$TMPDIR/qual-overall-rows.txt"
printf '16\t7168\n' > "$QUAL_OVERALL_FILE"

# per-author full oeuvre: name | f_books | f_bytes
FULL_PER_FILE="$TMPDIR/full-per-rows.txt"
printf 'Абби Линн\t3\t1536\n'   >  "$FULL_PER_FILE"
printf 'Джо Аберкромби\t5\t2560\n'  >> "$FULL_PER_FILE"
printf 'Азимов Айзек\t12\t5120\n'   >> "$FULL_PER_FILE"

# distinct full oeuvre overall: total books | total bytes
FULL_OVERALL_FILE="$TMPDIR/full-overall-rows.txt"
printf '20\t9216\n' > "$FULL_OVERALL_FILE"

# to-collect list: 4 names, one ('Никто Такой') not in the catalog at all
LIST_FILE="$TMPDIR/to-collect.txt"
printf 'Абби Линн\n'      >  "$LIST_FILE"
printf 'Джо Аберкромби\n' >> "$LIST_FILE"
printf 'Азимов Айзек\n'   >> "$LIST_FILE"
printf 'Никто Такой\n'    >> "$LIST_FILE"

OUT_FILE="$TMPDIR/breakdown.tsv"
REPORT_DIR="$TMPDIR/reports"
mkdir -p "$REPORT_DIR"

run_estimate() { # [args...] ; stdout->$OUT, stderr->$ERR ; rc->$RC
    OUT="$TMPDIR/stdout.txt" ERR="$TMPDIR/stderr.txt"
    # Point MARIA_TASKLIST at a nonexistent path by default so lifecycle
    # management is disabled (connect directly); lifecycle tests override it.
    env PATH="$MOCK_BIN:$PATH" \
        MOCK_LOG="$MOCK_LOG" MOCK_DUMP_FILE="$DUMP_FILE" \
        MOCK_QUAL_PER_FILE="$QUAL_PER_FILE" MOCK_QUAL_OVERALL_FILE="$QUAL_OVERALL_FILE" \
        MOCK_FULL_PER_FILE="$FULL_PER_FILE" MOCK_FULL_OVERALL_FILE="$FULL_OVERALL_FILE" \
        MOCK_RC="${MOCK_RC:-0}" \
        MYSQL_PASSWORD="${MOCK_PASSWORD:-}" \
        MARIA_TASKLIST="${MARIA_TASKLIST_OVERRIDE:-$TMPDIR/no-such-tasklist}" \
        MARIA_MOCK_RUNNING="${MARIA_MOCK_RUNNING:-0}" \
        ESTIMATE_INPUT_FILE="$LIST_FILE" ESTIMATE_REPORT_DIR="$REPORT_DIR" \
        bash "$ESTIMATOR" "$@" >"$OUT" 2>"$ERR"
    RC=$?
}

echo "== books_estimate =="

# --- version / usage -----------------------------------------------------------
version="$(sed -n 's/^# Version:[[:space:]]*//p' "$ESTIMATOR" | head -n 1)"
if [[ "$version" =~ ^1\.0\.[0-9]+$ ]]; then
    report "version_header" ok "header $version"
else
    report "version_header" fail "got '$version', expected ^1.0.[0-9]+$"
fi

bash "$ESTIMATOR" --version >"$TMPDIR/v.txt" 2>&1
if [[ "$(cat "$TMPDIR/v.txt")" == "bin/books/books_estimate.sh v$version" ]]; then
    report "version_flag" ok
else
    report "version_flag" fail "got '$(cat "$TMPDIR/v.txt")'"
fi

bash "$ESTIMATOR" --help >"$TMPDIR/h.txt" 2>&1
if (( $? == 0 )) && grep -q -- "--input-file" "$TMPDIR/h.txt"; then
    report "help_exit0" ok
else
    report "help_exit0" fail "help must exit 0 and list options"
fi

bash "$ESTIMATOR" --bogus >"$TMPDIR/u.txt" 2>&1
if (( $? == 2 )); then
    report "unknown_option_exit2" ok
else
    report "unknown_option_exit2" fail "expected exit 2"
fi

# --- connection argv + password handling ----------------------------------------
rm -f "$MOCK_LOG"
MOCK_RC=0 MOCK_PASSWORD=s3cret run_estimate -o "$OUT_FILE"
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
if (( $(grep -c '^MYSQL ' "$MOCK_LOG" || true) == 5 )); then
    report "five_queries_run" ok
else
    report "five_queries_run" fail "expected 5 mysql invocations, got $(grep -c '^MYSQL ' "$MOCK_LOG" || true)"
fi
if grep -q 'INLIST IN (1,2,3)' "$MOCK_LOG"; then
    report "inlist_resolved" ok
else
    report "inlist_resolved" fail "authorids 1,2,3 not resolved into the IN-list: $(grep INLIST "$MOCK_LOG" | head -1)"
fi

# --- summary: distinct totals and unmatched count ---------------------------------
if (( RC == 0 )) \
   && grep -q "recommended-author list: 4 author" "$OUT" \
   && grep -q "authors matched in catalog             3" "$OUT" \
   && grep -q "authors unmatched (name drift)         1" "$OUT" \
   && grep -q "qualifying books (rated 4/5, Фантастика, ru)    16   ~0.0 GB" "$OUT" \
   && grep -q "full oeuvre (all ru books)            20   ~0.0 GB" "$OUT" \
   && grep -q "top-rated qualifying authors" "$OUT" \
   && grep -q "Азимов Айзек" "$OUT"; then
    report "summary_totals" ok
else
    report "summary_totals" fail "rc=$RC stdout: $(tr '\n' '|' < "$OUT" | head -c 600)"
fi

# --- breakdown artifact: only list authors, sorted top-rated first ---------------
if [[ -f "$OUT_FILE" ]] \
   && [[ "$(wc -l < "$OUT_FILE" | tr -d ' ')" == "3" ]] \
   && ! grep -q 'Другой Автор' "$OUT_FILE" \
   && ! grep -q 'Никто Такой' "$OUT_FILE" \
   && head -n 1 "$OUT_FILE" | grep -q $'^Азимов Айзек\t10\t4096\t7\t4.9\t12\t5120$' \
   && sed -n '2p' "$OUT_FILE" | grep -q $'^Джо Аберкромби\t4\t2048\t3\t4.8\t5\t2560$' \
   && sed -n '3p' "$OUT_FILE" | grep -q $'^Абби Линн\t2\t1024\t2\t5.0\t3\t1536$'; then
    report "breakdown_top_rated_first" ok
else
    report "breakdown_top_rated_first" fail "file: $(tr '\n' '|' < "$OUT_FILE" 2>/dev/null)"
fi
if grep -q "prioritized breakdown (3 author(s)) written to $OUT_FILE" "$ERR"; then
    report "breakdown_path_logged" ok
else
    report "breakdown_path_logged" fail "stderr: $(head -3 "$ERR")"
fi

# --- default output path (report dir exists) --------------------------------------
rm -f "$REPORT_DIR"/books_estimate_*.tsv
MOCK_RC=0 run_estimate
if (( RC == 0 )) && ls "$REPORT_DIR"/books_estimate_*.tsv >/dev/null 2>&1; then
    report "default_output_path" ok
else
    report "default_output_path" fail "rc=$RC no books_estimate_*.tsv in $REPORT_DIR"
fi

# --- dry-run: connects, summarizes, writes nothing ---------------------------------
rm -f "$OUT_FILE"
MOCK_RC=0 run_estimate --dry-run
if (( RC == 0 )) && [[ ! -e "$OUT_FILE" ]] \
   && grep -q "would write breakdown" "$ERR" \
   && grep -q "recommended-author list: 4 author" "$OUT"; then
    report "dry_run_no_write" ok
else
    report "dry_run_no_write" fail "rc=$RC file=${OUT_FILE:-missing} stderr=$(head -2 "$ERR")"
fi

# --- mysql failure: reported, no breakdown written ---------------------------------
rm -f "$OUT_FILE"
MOCK_RC=7 run_estimate -o "$OUT_FILE"
if (( RC == 1 )) && [[ ! -e "$OUT_FILE" ]] && grep -q "query failed" "$ERR"; then
    report "mysql_failure_rc1" ok
else
    report "mysql_failure_rc1" fail "rc=$RC stderr=$(head -3 "$ERR")"
fi

# --- missing client / missing input file --------------------------------------------
env PATH="$MOCK_BIN:$PATH" ESTIMATE_INPUT_FILE="$LIST_FILE" \
    MYSQL_CLIENT=definitely-not-mysql \
    bash "$ESTIMATOR" >/dev/null 2>"$ERR"
if (( $? == 1 )) && grep -q "definitely-not-mysql not found" "$ERR"; then
    report "missing_client" ok
else
    report "missing_client" fail "stderr: $(head -2 "$ERR")"
fi

env PATH="$MOCK_BIN:$PATH" ESTIMATE_INPUT_FILE="$TMPDIR/nope.txt" \
    bash "$ESTIMATOR" >/dev/null 2>"$ERR"
if (( $? == 1 )) && grep -q "input file not found" "$ERR"; then
    report "missing_input_file" ok
else
    report "missing_input_file" fail "stderr: $(head -2 "$ERR")"
fi

# --- MariaDB lifecycle (mock tasklist + mock powershell.exe) ----------------------
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

# 1) server already running -> connects and leaves it untouched
rm -f "$OUT_FILE" "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$MOCK_BIN/tasklist" MARIA_MOCK_RUNNING=1 MOCK_RC=0 run_estimate -o "$OUT_FILE"
if (( RC == 0 )) && grep -q "already running" "$ERR" \
   && ! grep -q "stopping MariaDB" "$ERR" \
   && [[ -f "$OUT_FILE" ]]; then
    report "lifecycle_already_running_untouched" ok
else
    report "lifecycle_already_running_untouched" fail "rc=$RC stderr=$(head -3 "$ERR")"
fi

# 2) server down -> started (elevated PS), queried, stopped gracefully on exit
rm -f "$OUT_FILE" "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$MOCK_BIN/tasklist" MARIA_MOCK_RUNNING=0 MOCK_RC=0 run_estimate -o "$OUT_FILE"
if (( RC == 0 )) \
   && grep -q "starting MariaDB" "$ERR" \
   && grep -q "MariaDB ready" "$ERR" \
   && grep -q "stopping MariaDB (graceful shutdown)" "$ERR" \
   && grep -q "MariaDB stopped" "$ERR" \
   && grep -q "Start-Process" "$MOCK_LOG" \
   && [[ -f "$OUT_FILE" ]]; then
    report "lifecycle_start_query_stop" ok
else
    report "lifecycle_start_query_stop" fail "rc=$RC stderr=$(head -4 "$ERR") pslog=$(cat "$MOCK_LOG")"
fi

# 3) no tasklist interop -> management disabled, connects directly
rm -f "$OUT_FILE" "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$TMPDIR/no-such-tasklist" MOCK_RC=0 run_estimate -o "$OUT_FILE"
if (( RC == 0 )) && grep -q "tasklist not available" "$ERR" \
   && ! grep -q "starting MariaDB" "$ERR" \
   && [[ -f "$OUT_FILE" ]]; then
    report "lifecycle_no_tasklist_disables_mgmt" ok
else
    report "lifecycle_no_tasklist_disables_mgmt" fail "rc=$RC stderr=$(head -3 "$ERR")"
fi

# 4) dry-run reports would-start / would-stop but never touches the server
rm -f "$OUT_FILE" "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$MOCK_BIN/tasklist" MARIA_MOCK_RUNNING=0 MOCK_RC=0 run_estimate --dry-run
if (( RC == 0 )) && grep -q "\[dry-run\] would start MariaDB" "$ERR" \
   && grep -q "\[dry-run\] would stop MariaDB" "$ERR" \
   && ! grep -q "Start-Process" "$MOCK_LOG"; then
    report "lifecycle_dryrun_reports_only" ok
else
    report "lifecycle_dryrun_reports_only" fail "rc=$RC stderr=$(head -4 "$ERR") pslog=$(cat "$MOCK_LOG")"
fi

# 5) held-open stdin must not stall the readiness probe.  The probe used to
#    inherit stdin; from an interactive terminal the mock mysql's `cat` then
#    blocked and every probe burned its full 5s timeout (6 probes < the 30s
#    window -> "did not become ready").  A fifo held open by a 60s sleeper
#    stands in for the never-closing TTY; the tool must still finish on its
#    own within 20s.
rm -f "$OUT_FILE" "$MOCK_LOG"
mkfifo "$TMPDIR/stdin_stall.fifo"
sleep 60 > "$TMPDIR/stdin_stall.fifo" &
STALL_PID=$!
# run_estimate hardcodes ERR="$TMPDIR/stderr.txt"; in a background subshell
# its OUT/ERR/RC globals do not reach us, so reference the paths directly.
MARIA_TASKLIST_OVERRIDE="$MOCK_BIN/tasklist" MARIA_MOCK_RUNNING=0 MOCK_RC=0 \
    run_estimate -o "$OUT_FILE" < "$TMPDIR/stdin_stall.fifo" &
TOOL_PID=$!
for _ in $(seq 1 20); do
    kill -0 "$TOOL_PID" 2>/dev/null || break
    sleep 1
done
if kill -0 "$TOOL_PID" 2>/dev/null; then
    report "lifecycle_held_stdin_does_not_stall_probe" fail \
        "tool still running after 20s (readiness probe stalled on stdin)"
    kill "$TOOL_PID" 2>/dev/null
else
    wait "$TOOL_PID"; TOOL_RC=$?
    if (( TOOL_RC == 0 )) && grep -q "MariaDB ready" "$TMPDIR/stderr.txt"; then
        report "lifecycle_held_stdin_does_not_stall_probe" ok
    else
        report "lifecycle_held_stdin_does_not_stall_probe" fail \
            "rc=$TOOL_RC stderr=$(head -4 "$TMPDIR/stderr.txt")"
    fi
fi
kill "$STALL_PID" 2>/dev/null
wait "$STALL_PID" 2>/dev/null

echo ""
echo "=============================="
echo "PASS: $PASS_COUNT   FAIL: $FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then
    printf '  - %s\n' "${FAILURE_LINES[@]}"
    exit 1
fi
echo "All tests passed."
exit 0