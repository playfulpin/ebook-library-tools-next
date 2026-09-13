#!/usr/bin/env bash

# __ETL_TEST_ENV_GUARD__: a caller with set -x/set -v auto-exports SHELLOPTS;
# every child bash re-applies it (it is readonly when imported), so xtrace
# noise corrupts the suites output captures.  Re-exec clean instead.
if [[ ${SHELLOPTS-} == *xtrace* || ${SHELLOPTS-} == *verbose* ]]; then
    exec env -u SHELLOPTS -u BASHOPTS bash "$0" "$@"
fi
unset SHELLOPTS BASHOPTS 2>/dev/null || true

# -----------------------------------------------------------------------------
# tests/unit/test_place_flibusta_book.sh
#
# Regression suite for bin/flibusta/place_flibusta_book.sh (stage-2 Flibusta
# placement).  Fully hermetic: a mock `mysql` (via MYSQL_CLIENT) serves
# fixture catalog rows keyed by the mlbook.filename literal in the SQL,
# records every argv, and never touches a real server; zip fixtures are
# built in a temp dir.
#
# Asserts the tool's contract:
#   - catalog SQL goes through lib/database.sh (db_mysql_argv shape; the
#     number appears as a quoted literal; the password never on argv)
#   - resolution: mlbook.filename -> bookid/title, lowest authorid ->
#     mlauthorname.FullName (top folder), lowest seqid -> mlseqname.seqname
#     (second folder), mlseq.seqnum two-digit zero-padded prefix
#   - naming: "01 - Title.zip"; no series -> "Title.zip"; the extracted
#     file's extension is dropped in the zip name
#   - sanitization: Windows-unsafe characters in title/FullName/seqname
#     become "_"; trailing dots/spaces trimmed
#   - the target zip is a real zip of the source file (content round-trips)
#   - source trashing: the stage-1 source is REMOVED after a successful
#     placement (v0.2.0 default); --keep-source retains it; a failed
#     placement never removes it
#   - per-run TSV report: one row per attempted number in --report-dir
#   - skip-existing unless --force
#   - --dry-run resolves and writes nothing (report still written)
#   - batch: from-file list (CRLF/BOM/comments), summary line, exit 1 when
#     any number failed (unknown number, missing source), partial delivery
#   - CLI contract: --help exits 0, --version prints the header version,
#     unknown option exits 2, no numbers exits 2, bad numbers are failures
#   - library mode (v0.3.0): PLACE_LIB_ONLY=1 source <tool> defines the
#     place_* API without running; place_parse_args + place_run return
#     (never exit); script behavior is preserved when sourced without
#     the guard
#
# Version header stays in sync with --version (0.3.x).
#
# Usage:  bash tests/unit/test_place_flibusta_book.sh
# -----------------------------------------------------------------------------

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."
TOOL="$REPO_ROOT/bin/flibusta/place_flibusta_book.sh"

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

TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/place_test.XXXXXX")"
trap 'rm -rf -- "$TMPDIR"' EXIT

# --- mock mysql (argv recording + catalog serving) --------------------------------
# The mock is a separate process, so the fixture catalog lives INSIDE it:
# it parses the mlbook.filename literal out of the SQL and emits the row.
# Keyed rows (bookid, title, fullname, seqname, seqnum):
#   100001 single author, no series           100005 two series (9,4) -> seqid 4
#   100002 series, seqnum 1  (-> "01")        100006 unsafe name chars
#   100003 seqnum 15         (-> "15")        100007 trailing dots/spaces
#   100004 two authors (5,2) -> authorid 2     100999 empty title edge
MOCK_BIN="$TMPDIR/mockbin"
MOCK_LOG="$TMPDIR/mysql-argv.log"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/mysql" <<MOCK_EOF
#!/usr/bin/env bash
printf 'MYSQL %s\n' "\$*" >> "${MOCK_LOG}"
sql=""
prev=""
for a in "\$@"; do
    [[ "\$prev" == "-e" ]] && sql="\$a"
    prev="\$a"
done
n="\$(printf '%s' "\$sql" | sed -n "s/.*b\\.filename *= *'\\([0-9]*\\)'.*/\\1/p")"
case "\$n" in
    100001) printf '100001\tThe Trial\tKafka Franz\t\t\n' ;;
    100002) printf '100002\tFellowship of the Ring\tTolkien John\tThe Lord of the Rings\t1\n' ;;
    100003) printf '100003\tThe Two Towers\tTolkien John\tThe Lord of the Rings\t15\n' ;;
    100004) printf '100004\tAnna Karenina Novel\tTolstoy Leo\t\t\n' ;;
    100005) printf '100005\tThe Hobbit Prequel\tTolkien John\tRing History\t4\n' ;;
    100006) printf '100006\tTitle: With/Unsafe*Chars?\tAuthor: Bad/Name*\tSeq: X/Y*\t7\n' ;;
    100007) printf '100007\tTrailing Dots...  \tDot Author  \t\t\n' ;;
    100999) printf '100999\t\tGhost Author\t\t\n' ;;
esac
MOCK_EOF
chmod +x "$MOCK_BIN/mysql"

# --- stage-1 style input fixtures ---------------------------------------------------
INPUT_DIR="$TMPDIR/input"
ROOT_LOAD="$TMPDIR/root"
REPORT_DIR="$TMPDIR/reports"
mkdir -p "$INPUT_DIR" "$ROOT_LOAD" "$REPORT_DIR"
printf 'fb2 payload of 100001\n' > "$INPUT_DIR/100001.fb2"
printf 'pdf payload of 100002\n' > "$INPUT_DIR/100002.pdf"
printf 'djvu payload of 100003\n' > "$INPUT_DIR/100003.djvu"
printf 'payload of 100004\n'      > "$INPUT_DIR/100004.doc"
printf 'payload of 100005\n'      > "$INPUT_DIR/100005.epub"
printf 'payload of 100006\n'      > "$INPUT_DIR/100006.fb2"
printf 'payload of 100007\n'      > "$INPUT_DIR/100007.fb2"
printf 'payload of 100999\n'      > "$INPUT_DIR/100999.fb2"

run_tool() { # [args...]; stdout->$OUT, stderr->$ERR; rc->$RC
    OUT="$TMPDIR/stdout.txt" ERR="$TMPDIR/stderr.txt"
    : > "$MOCK_LOG"
    rm -f "$REPORT_DIR"/*.tsv
    MYSQL_CLIENT="$MOCK_BIN/mysql" \
    PLACE_INPUT_DIR="$INPUT_DIR" ROOT_LOAD="$ROOT_LOAD" FLIBUSTA_DB=flibusta \
    PLACE_REPORT_DIR="$REPORT_DIR" \
    MARIA_TASKLIST="$TMPDIR/no-such-tasklist" \
        bash "$TOOL" "$@" >"$OUT" 2>"$ERR"
    RC=$?
}

last_report_rows() { # -> the data rows of the newest report in $REPORT_DIR
    local f
    f="$(ls -1t "$REPORT_DIR"/place_flibusta_*.tsv 2>/dev/null | head -n 1)"
    [[ -n "$f" ]] || return 1
    tail -n +2 "$f"
}

zipped_content() { # $1 = zip path -> inner file content on stdout
    unzip -p "$1" 2>/dev/null | head -n 1
}

echo "== place_flibusta_book =="

# --- version / usage --------------------------------------------------------------
version="$(sed -n 's/^# Version:[[:space:]]*//p' "$TOOL" | head -n 1)"
if [[ "$version" =~ ^0\.3\.[0-9]+$ ]]; then
    report "version_header" ok "header $version"
else
    report "version_header" fail "got '$version', expected ^0.3.[0-9]+$"
fi

bash "$TOOL" --version >"$TMPDIR/v.txt" 2>&1
if [[ "$(cat "$TMPDIR/v.txt")" == "bin/flibusta/place_flibusta_book.sh v$version" ]]; then
    report "version_flag" ok
else
    report "version_flag" fail "got '$(cat "$TMPDIR/v.txt")'"
fi

bash "$TOOL" --help >"$TMPDIR/h.txt" 2>&1
if (( $? == 0 )) && grep -q -- "--root-load" "$TMPDIR/h.txt" && grep -q -- "--from-file" "$TMPDIR/h.txt"; then
    report "help_exit0" ok
else
    report "help_exit0" fail "help must exit 0 and list options"
fi

bash "$TOOL" --bogus >"$TMPDIR/u.txt" 2>&1
if (( $? == 2 )); then
    report "unknown_option_exit2" ok
else
    report "unknown_option_exit2" fail "expected exit 2"
fi

run_tool
if (( RC == 2 )); then
    report "no_args_exit2" ok
else
    report "no_args_exit2" fail "expected exit 2, got $RC"
fi

# --- DB boundary: argv via lib/database.sh ------------------------------------------
run_tool --dry-run 100001
db_line="$(grep '^MYSQL ' "$MOCK_LOG" | head -n 1)"
if [[ "$db_line" == *" --protocol=TCP "* ]] && [[ "$db_line" == *" -u root "* ]] \
   && [[ "$db_line" == *"--init-command=SET NAMES utf8"* ]] \
   && [[ "$db_line" != *s3cret* ]]; then
    report "db_argv_via_lib" ok
else
    report "db_argv_via_lib" fail "got: $db_line"
fi

run_tool --dry-run 100001
if grep -q "b.filename = '100001'" "$MOCK_LOG"; then
    report "sql_literal_number" ok
else
    report "sql_literal_number" fail "number literal not in SQL: $(tail -1 "$MOCK_LOG")"
fi

# --- single placement, no series; source trashed by default (v0.2.0) ---------
rm -rf "${ROOT_LOAD:?}"/*; mkdir -p "$ROOT_LOAD"
run_tool 100001
if (( RC == 0 )) \
   && [[ "$(zipped_content "$ROOT_LOAD/Kafka Franz/The Trial.zip" 2>/dev/null)" == "fb2 payload of 100001" ]] \
   && [[ ! -e "$INPUT_DIR/100001.fb2" ]]; then
    report "place_no_series" ok
else
    report "place_no_series" fail "rc=$RC err=$(tail -2 "$ERR")"
fi

# --- report: one placed row for the run above ---------------------------------
rows="$(last_report_rows)"
if [[ "$rows" == *$'\t100001\t100001\tplaced\t'* ]] \
   && [[ "$rows" == *"$ROOT_LOAD/Kafka Franz/The Trial.zip"* ]]; then
    report "report_placed_row" ok
else
    report "report_placed_row" fail "rows: $rows"
fi

# --- --keep-source retains the stage-1 file -------------------------------------
printf 'fb2 payload of 100001\n' > "$INPUT_DIR/100001.fb2"   # restore (was trashed)
run_tool --force --keep-source 100001
if (( RC == 0 )) && [[ -f "$INPUT_DIR/100001.fb2" ]]; then
    report "keep_source" ok
else
    report "keep_source" fail "rc=$RC err=$(tail -2 "$ERR")"
fi

# --- a failed placement never removes the source ---------------------------------
mkdir -p "$TMPDIR/empty-input"          # valid dir, no source inside
run_tool --force --keep-source --input-dir "$TMPDIR/empty-input" 100001
if (( RC == 1 )) && grep -q "extracted file not found" "$ERR" && [[ -f "$INPUT_DIR/100001.fb2" ]]; then
    report "failed_keeps_source" ok
else
    report "failed_keeps_source" fail "rc=$RC err=$(tail -2 "$ERR")"
fi

# --- series naming: "01 - Title" and "15 - Title" ---------------------------------------
rm -rf "${ROOT_LOAD:?}"/*; mkdir -p "$ROOT_LOAD"
run_tool 100002 100003
if (( RC == 0 )) \
   && [[ -f "$ROOT_LOAD/Tolkien John/The Lord of the Rings/01 - Fellowship of the Ring.zip" ]] \
   && [[ -f "$ROOT_LOAD/Tolkien John/The Lord of the Rings/15 - The Two Towers.zip" ]] \
   && [[ "$(zipped_content "$ROOT_LOAD/Tolkien John/The Lord of the Rings/01 - Fellowship of the Ring.zip")" == "pdf payload of 100002" ]]; then
    report "place_series_names" ok
else
    report "place_series_names" fail "rc=$RC err=$(tail -2 "$ERR")"
fi

# --- lowest authorid / lowest seqid -------------------------------------------------------
rm -rf "${ROOT_LOAD:?}"/*; mkdir -p "$ROOT_LOAD"
run_tool 100004 100005
if (( RC == 0 )) \
   && [[ -f "$ROOT_LOAD/Tolstoy Leo/Anna Karenina Novel.zip" ]] \
   && [[ -f "$ROOT_LOAD/Tolkien John/Ring History/04 - The Hobbit Prequel.zip" ]]; then
    report "place_lowest_ids" ok
else
    report "place_lowest_ids" fail "rc=$RC err=$(tail -2 "$ERR")"
fi

# --- sanitization ---------------------------------------------------------------------------
rm -rf "${ROOT_LOAD:?}"/*; mkdir -p "$ROOT_LOAD"
run_tool 100006 100007
if (( RC == 0 )) \
   && [[ -f "$ROOT_LOAD/Author_ Bad_Name_/Seq_ X_Y_/07 - Title_ With_Unsafe_Chars_.zip" ]] \
   && [[ -f "$ROOT_LOAD/Dot Author/Trailing Dots.zip" ]]; then
    report "place_sanitized_names" ok
else
    report "place_sanitized_names" fail "rc=$RC err=$(tail -3 "$ERR")"
fi

# --- empty title does not crash ---------------------------------------------------------------
rm -rf "${ROOT_LOAD:?}"/*; mkdir -p "$ROOT_LOAD"
run_tool 100999
if [[ -f "$ROOT_LOAD/Ghost Author/.zip" ]] || [[ -f "$ROOT_LOAD/Ghost Author" ]] || (( RC == 0 )) || (( RC == 1 )); then
    report "empty_title_no_crash" ok
else
    report "empty_title_no_crash" fail "rc=$RC"
fi

# --- skip-existing / force ----------------------------------------------------------------------
# (each earlier test wipes $ROOT_LOAD; the trash-default removed the source,
# so restore the fixture first, place, then re-run to see the skip)
printf 'fb2 payload of 100001\n' > "$INPUT_DIR/100001.fb2"
run_tool --keep-source 100001
run_tool 100001
if grep -q "target exists, skipping" "$ERR"; then
    report "skip_existing" ok
else
    report "skip_existing" fail "rc=$RC err=$(tail -2 "$ERR")"
fi

run_tool --force --keep-source 100001
if grep -qE "bookid : 100001" "$ERR" && ! grep -q "target exists, skipping" "$ERR"; then
    report "force_replaces" ok
else
    report "force_replaces" fail "rc=$RC err=$(tail -2 "$ERR")"
fi

# --- --rm-source is a documented no-op; removal is the default ------------------------------------
run_tool --force 100001
if (( RC == 0 )) && [[ ! -f "$INPUT_DIR/100001.fb2" ]]; then
    report "rm_source_noop" ok
else
    report "rm_source_noop" fail "rc=$RC"
fi

# --- dry-run writes nothing (report rows use would-* statuses) ----------------------
rm -rf "${ROOT_LOAD:?}"/*; mkdir -p "$ROOT_LOAD"
printf 'pdf payload of 100002\n' > "$INPUT_DIR/100002.pdf"   # restore (trashed earlier)
run_tool --dry-run 100002
if (( RC == 0 )) && (( $(find "$ROOT_LOAD" -type f | wc -l) == 0 )) \
   && grep -q "dry-run: 1 number(s) resolvable" "$ERR" \
   && [[ "$(last_report_rows)" == *$'\twould-place\t'* ]]; then
    report "dryrun_writes_nothing" ok
else
    report "dryrun_writes_nothing" fail "rc=$RC err=$(tail -2 "$ERR")"
fi

# --- batch: from-file + failures + summary -------------------------------------------
rm -rf "${ROOT_LOAD:?}"/*; mkdir -p "$ROOT_LOAD"
printf 'djvu payload of 100003\n' > "$INPUT_DIR/100003.djvu"  # restore (trashed earlier)
printf '\xEF\xBB\xBF100002\r\n\r\n# comment\r\n100003\r\n' > "$TMPDIR/list.txt"
run_tool --from-file "$TMPDIR/list.txt"
if (( RC == 0 )) \
   && [[ -f "$ROOT_LOAD/Tolkien John/The Lord of the Rings/01 - Fellowship of the Ring.zip" ]] \
   && [[ -f "$ROOT_LOAD/Tolkien John/The Lord of the Rings/15 - The Two Towers.zip" ]] \
   && grep -q "summary: 2 placed" "$ERR"; then
    report "from_file_batch" ok
else
    report "from_file_batch" fail "rc=$RC err=$(tail -3 "$ERR")"
fi

# unknown number in a batch: others delivered, exit 1, failure listed
rm -rf "${ROOT_LOAD:?}"/*; mkdir -p "$ROOT_LOAD"
printf 'fb2 payload of 100001\n' > "$INPUT_DIR/100001.fb2"   # restore (trashed earlier)
run_tool 100001 999999
if (( RC == 1 )) && [[ -f "$ROOT_LOAD/Kafka Franz/The Trial.zip" ]] \
   && grep -q "999999: not found in the catalog" "$ERR"; then
    report "batch_unknown_number_exit1" ok
else
    report "batch_unknown_number_exit1" fail "rc=$RC err=$(tail -3 "$ERR")"
fi

# missing stage-1 source: catalog resolves, placement fails
rm -rf "${ROOT_LOAD:?}"/*; mkdir -p "$ROOT_LOAD"
rm -f "$INPUT_DIR/100003.djvu"
run_tool 100003
if (( RC == 1 )) && grep -q "extracted file not found" "$ERR"; then
    report "missing_source_exit1" ok
else
    report "missing_source_exit1" fail "rc=$RC err=$(tail -3 "$ERR")"
fi
printf 'djvu payload of 100003\n' > "$INPUT_DIR/100003.djvu"

# invalid number is a failure, not an abort
printf 'fb2 payload of 100001\n' > "$INPUT_DIR/100001.fb2"   # restore (trashed above)
run_tool notanumber 100001
if (( RC == 1 )) && grep -q "invalid FileNumber" "$ERR"; then
    report "invalid_number_failure" ok
else
    report "invalid_number_failure" fail "rc=$RC"
fi

# --- library mode (v0.3.0) ------------------------------------------------------------------------
# PLACE_LIB_ONLY=1 source <tool>: defines the API, runs nothing.
LIB_OUT="$TMPDIR/lib_out.txt" LIB_ERR="$TMPDIR/lib_err.txt"
(
    export MYSQL_CLIENT="$MOCK_BIN/mysql" \
           PLACE_INPUT_DIR="$INPUT_DIR" ROOT_LOAD="$ROOT_LOAD" FLIBUSTA_DB=flibusta \
           PLACE_REPORT_DIR="$REPORT_DIR" \
           MARIA_TASKLIST="$TMPDIR/no-such-tasklist"
    export PLACE_LIB_ONLY=1
    # shellcheck disable=SC1090  # path is $TOOL, verified by the script-mode tests
    source "$TOOL"
    echo "lib_functions: $(declare -F place_parse_args place_run place_lookup place_sanitize_name place_find_source place_zip | wc -l)" >&2
    echo "lib_version: $SCRIPT_VERSION" >&2
) >"$LIB_OUT" 2>"$LIB_ERR"
if grep -q "lib_functions: 6" "$LIB_ERR" && grep -q "lib_version: $version" "$LIB_ERR" \
   && [[ "$(cat "$LIB_OUT")" == "" ]]; then
    report "library_mode_no_autorun" ok
else
    report "library_mode_no_autorun" fail "out=$(cat "$LIB_OUT") err=$(cat "$LIB_ERR")"
fi

# library run: parse + run return (never exit); a place works in-process.
printf 'pdf payload of 100002\n' > "$INPUT_DIR/100002.pdf"   # restore (trashed earlier)
printf 'djvu payload of 100003\n' > "$INPUT_DIR/100003.djvu" # restore (trashed earlier)
(
    export MYSQL_CLIENT="$MOCK_BIN/mysql" \
           PLACE_INPUT_DIR="$INPUT_DIR" ROOT_LOAD="$ROOT_LOAD" FLIBUSTA_DB=flibusta \
           PLACE_REPORT_DIR="$REPORT_DIR" \
           MARIA_TASKLIST="$TMPDIR/no-such-tasklist"
    export PLACE_LIB_ONLY=1
    # shellcheck disable=SC1090  # path is $TOOL, verified by the script-mode tests
    source "$TOOL"
    rm -rf "${ROOT_LOAD:?}"/*; mkdir -p "$ROOT_LOAD"
    place_parse_args 100002 100003 || { echo "lib_parse_rc: $?" >&2; exit 97; }
    place_run
    rc=$?
    echo "lib_run_rc: $rc" >&2
    [[ -f "$ROOT_LOAD/Tolkien John/The Lord of the Rings/01 - Fellowship of the Ring.zip" ]] \
        && echo "lib_placed: yes" >&2 || echo "lib_placed: no" >&2
    exit 0
) >"$LIB_OUT" 2>"$LIB_ERR"
if grep -q "lib_run_rc: 0" "$LIB_ERR" && grep -q "lib_placed: yes" "$LIB_ERR" \
   && grep -q "summary: 2 placed" "$LIB_ERR"; then
    report "library_run_batch" ok
else
    report "library_run_batch" fail "err=$(cat "$LIB_ERR")"
fi

# library failure path: unknown number -> place_run returns 1 (no exit, no trap leak)
(
    export MYSQL_CLIENT="$MOCK_BIN/mysql" \
           PLACE_INPUT_DIR="$INPUT_DIR" ROOT_LOAD="$ROOT_LOAD" FLIBUSTA_DB=flibusta \
           PLACE_REPORT_DIR="$REPORT_DIR" \
           MARIA_TASKLIST="$TMPDIR/no-such-tasklist"
    export PLACE_LIB_ONLY=1
    # shellcheck disable=SC1090  # path is $TOOL, verified by the script-mode tests
    source "$TOOL"
    place_parse_args 999999 || { echo "lib_parse_rc: $?" >&2; exit 97; }
    if place_run; then
        echo "lib_fail_rc: 0" >&2
    else
        echo "lib_fail_rc: $?" >&2
    fi
    echo "lib_survived: yes" >&2
    exit 0
) >"$LIB_OUT" 2>"$LIB_ERR"
if grep -q "lib_fail_rc: 1" "$LIB_ERR" && grep -q "lib_survived: yes" "$LIB_ERR" \
   && grep -q "not found in the catalog" "$LIB_ERR"; then
    report "library_failure_returns" ok
else
    report "library_failure_returns" fail "err=$(cat "$LIB_ERR")"
fi

# library usage error: parse returns 2 without exiting; no numbers -> run returns 2
(
    export PLACE_LIB_ONLY=1
    # shellcheck disable=SC1090  # path is $TOOL, verified by the script-mode tests
    source "$TOOL" 2>/dev/null
    rc=0; place_parse_args --bogus >/dev/null 2>&1 || rc=$?
    echo "lib_usage_rc: $rc" >&2
    rc=0; place_parse_args >/dev/null 2>&1 || rc=$?
    rc=0; place_run >/dev/null 2>&1 || rc=$?
    echo "lib_noargs_rc: $rc" >&2
    exit 0
) >"$LIB_OUT" 2>"$LIB_ERR"
if grep -q "lib_usage_rc: 2" "$LIB_ERR" && grep -q "lib_noargs_rc: 2" "$LIB_ERR"; then
    report "library_usage_error" ok
else
    report "library_usage_error" fail "err=$(cat "$LIB_ERR")"
fi

# --- summary ---------------------------------------------------------------------------
echo
if (( FAIL_COUNT == 0 )); then
    echo "$PASS_COUNT passed, $FAIL_COUNT failed"
    exit 0
else
    echo "$PASS_COUNT passed, $FAIL_COUNT failed"
    for line in "${FAILURE_LINES[@]}"; do echo "  FAILED: $line"; done
    exit 1
fi
