#!/usr/bin/env bash

# __ETL_TEST_ENV_GUARD__: a caller with set -x/set -v auto-exports SHELLOPTS;
# every child bash re-applies it (it is readonly when imported), so xtrace
# noise corrupts the suites output captures.  Re-exec clean instead.
if [[ ${SHELLOPTS-} == *xtrace* || ${SHELLOPTS-} == *verbose* ]]; then
    exec env -u SHELLOPTS -u BASHOPTS bash "$0" "$@"
fi
unset SHELLOPTS BASHOPTS 2>/dev/null || true

# -----------------------------------------------------------------------------
# tests/unit/test_extract_author_flibusta.sh
#
# Regression suite for bin/flibusta/extract_author_flibusta.sh (stage-1
# Flibusta extraction by AUTHOR NAME).  Fully hermetic: a mock `mysql`
# (via MYSQL_CLIENT) serves a fixture catalog keyed by the LIKE pattern
# and the IN(...) authorids, records every argv, and never touches a real
# server; the fb2 range archive is a real zip fixture.
#
# Fixture catalog (inside the mock):
#   "Толстой Лев"    authorid 2  -> numbers 100001, 100002 (both in archive)
#   "Толстой Алексей" authorid 5 -> numbers 100002 (shared!), 100005
#   "O'Brien Connor" authorid 9  -> number 100009 (member ABSENT from archive)
#   "Zelda wild%Name" authorid 11 -> number 100011 (member ABSENT; dry-run only)
#
# Asserts the tool's contract:
#   - catalog SQL goes through lib/database.sh (argv shape; no password)
#   - the name reaches the SQL as a LIKE pattern, quote-escaped (O''Brien)
#     and %-escaped (wild\%Name); the books SQL carries the fb2 REGEXP guard
#   - resolution: name -> authorids -> bare-number filenames only
#   - extraction: members land in the output dir, content round-trips
#   - dedupe: a book under two matched authors is extracted once
#   - skip-existing (summary counts skips), --force re-extracts
#   - --limit N reaches the SQL and the mock applies it
#   - --dry-run resolves and extracts nothing
#   - from-file (BOM/CRLF/comments); no-match name -> exit 1; member-absent
#     number -> per-book failure, batch continues
#   - CLI contract: --help exit 0, --version, unknown option 2, no args 2
#
# Version header stays in sync with --version (0.1.x).
#
# Usage:  bash tests/unit/test_extract_author_flibusta.sh
# -----------------------------------------------------------------------------

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."
TOOL="$REPO_ROOT/bin/flibusta/extract_author_flibusta.sh"

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

TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/authext_test.XXXXXX")"
trap 'rm -rf -- "$TMPDIR"' EXIT

# --- mock mysql (argv recording + catalog serving) --------------------------------
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

# authors query: pull the LIKE pattern, unescape doubled quotes
if [[ "\$sql" == *"FROM mlauthorname"* ]]; then
    pat="\$(printf '%s' "\$sql" | sed -n "s/.*LIKE '%\\\\(.*\\\\)%'.*/\\\\1/p")"
    pat="\${pat//\'\'/\'}"
    case "\$pat" in
        "Толстой Лев")      printf '2\tТолстой Лев\n' ;;
        "Толстой Алексей")  printf '5\tТолстой Алексей\n' ;;
        "Толстой")          printf '2\tТолстой Лев\n5\tТолстой Алексей\n' ;;
        "O'Brien")          printf '9\tO'"'"'Brien Connor\n' ;;
        "wild%Name")        printf '11\tZelda wild%%Name\n' ;;
    esac
    exit 0
fi

# books query: ids from IN (...), optional LIMIT n
if [[ "\$sql" == *"FROM mlbook"* ]]; then
    ids="\$(printf '%s' "\$sql" | sed -n "s/.*IN (\\\\([^)]*\\\\)).*/\\\\1/p")"
    limit="\$(printf '%s' "\$sql" | sed -n "s/.*LIMIT \\\\([0-9]*\\\\).*/\\\\1/p")"
    limit="\${limit:-0}"
    IFS=',' read -r -a idarr <<< "\$ids"
    count=0
    for id in "\${idarr[@]}"; do
        id="\$(printf '%s' "\$id" | tr -d ' ')"
        case "\$id" in
            2)  printf '100001\t2\tТолстой Лев\n100002\t2\tТолстой Лев\n' ;;
            5)  printf '100002\t5\tТолстой Алексей\n100005\t5\tТолстой Алексей\n' ;;
            9)  printf '100009\t9\tO'"'"'Brien Connor\n' ;;
            11) printf '100011\t11\tZelda wild%%Name\n' ;;
        esac
    done | awk -v lim="\$limit" 'lim == 0 || NR <= lim'
    exit 0
fi
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/mysql"

# --- fb2 archive fixture -----------------------------------------------------------
SOURCE_DIR="$TMPDIR/archives"
OUTPUT_DIR="$TMPDIR/out"
REPORT_CWD="$TMPDIR"
mkdir -p "$SOURCE_DIR"
STAGE="$TMPDIR/stage"; mkdir -p "$STAGE"
printf 'fb2 payload of 100001\n' > "$STAGE/100001.fb2"
printf 'fb2 payload of 100002\n' > "$STAGE/100002.fb2"
printf 'fb2 payload of 100005\n' > "$STAGE/100005.fb2"
(cd "$STAGE" && zip -q "$SOURCE_DIR/f.fb2-100001-200000.zip" 100001.fb2 100002.fb2 100005.fb2)
rm -rf "$STAGE"

run_tool() { # [args...]; stdout->$OUT, stderr->$ERR; rc->$RC
    OUT="$TMPDIR/stdout.txt" ERR="$TMPDIR/stderr.txt"
    : > "$MOCK_LOG"
    cd "$REPORT_CWD" || return 99
    MYSQL_CLIENT="$MOCK_BIN/mysql" FLIBUSTA_DB=flibusta \
    FLIBUSTA_SOURCE_DIR="$SOURCE_DIR" FB2_OUTPUT_DIR="$OUTPUT_DIR" \
    MARIA_TASKLIST="$TMPDIR/no-such-tasklist" \
        bash "$TOOL" "$@" >"$OUT" 2>"$ERR"
    RC=$?
}

clean_out() { rm -rf "$OUTPUT_DIR"; mkdir -p "$OUTPUT_DIR"; }

echo "== extract_author_flibusta =="

# --- version / usage --------------------------------------------------------------
version="$(sed -n 's/^# Version:[[:space:]]*//p' "$TOOL" | head -n 1)"
if [[ "$version" =~ ^0\.1\.[0-9]+$ ]]; then
    report "version_header" ok "header $version"
else
    report "version_header" fail "got '$version', expected ^0.1.[0-9]+$"
fi

bash "$TOOL" --version >"$TMPDIR/v.txt" 2>&1
if [[ "$(cat "$TMPDIR/v.txt")" == "bin/flibusta/extract_author_flibusta.sh v$version" ]]; then
    report "version_flag" ok
else
    report "version_flag" fail "got '$(cat "$TMPDIR/v.txt")'"
fi

bash "$TOOL" --help >"$TMPDIR/h.txt" 2>&1
hrc=$?
if (( hrc == 0 )) && grep -q -- "--limit" "$TMPDIR/h.txt" && grep -q -- "--from-file" "$TMPDIR/h.txt"; then
    report "help_exit0" ok
else
    report "help_exit0" fail "rc=$hrc, help must exit 0 and list options"
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

# --- DB boundary + SQL shape --------------------------------------------------------
clean_out
run_tool --dry-run "Толстой"
db_line="$(grep '^MYSQL ' "$MOCK_LOG" | head -n 1)"
if [[ "$db_line" == *" --protocol=TCP "* ]] && [[ "$db_line" == *" -u root "* ]] \
   && [[ "$db_line" == *"--init-command=SET NAMES utf8"* ]] \
   && [[ "$db_line" != *s3cret* ]]; then
    report "db_argv_via_lib" ok
else
    report "db_argv_via_lib" fail "got: $db_line"
fi

if grep -q "LIKE '%Толстой%'" "$MOCK_LOG"; then
    report "name_like_pattern" ok
else
    report "name_like_pattern" fail "SQL: $(tail -1 "$MOCK_LOG")"
fi

if grep -q "REGEXP" "$MOCK_LOG"; then
    report "sql_fb2_regexp_guard" ok
else
    report "sql_fb2_regexp_guard" fail "books SQL has no REGEXP guard"
fi

# --- dry-run resolves, writes nothing ------------------------------------------------
if (( RC == 0 )) && (( $(find "$OUTPUT_DIR" -type f | wc -l) == 0 )) \
   && grep -q "dry-run: 3 book(s) resolvable" "$ERR"; then
    report "dryrun_resolves_nothing" ok
else
    report "dryrun_resolves_nothing" fail "rc=$RC err=$(tail -3 "$ERR")"
fi

# --- single-author extract (content round-trip) --------------------------------------
clean_out
run_tool "Толстой Алексей"
if (( RC == 0 )) \
   && [[ "$(head -n1 "$OUTPUT_DIR/100005.fb2" 2>/dev/null)" == "fb2 payload of 100005" ]]; then
    report "single_author_extract" ok
else
    report "single_author_extract" fail "rc=$RC err=$(tail -3 "$ERR")"
fi

# --- multi-author batch + cross-author dedupe -----------------------------------------
# "Толстой" matches authors 2 and 5; 100002 is a book of BOTH -> extracted once.
clean_out
run_tool "Толстой"
if (( RC == 0 )) \
   && [[ -f "$OUTPUT_DIR/100001.fb2" ]] && [[ -f "$OUTPUT_DIR/100002.fb2" ]] \
   && [[ -f "$OUTPUT_DIR/100005.fb2" ]] \
   && grep -q "summary: 3 book(s) delivered" "$ERR"; then
    report "batch_dedupe" ok
else
    report "batch_dedupe" fail "rc=$RC err=$(tail -3 "$ERR")"
fi

# --- skip-existing / force --------------------------------------------------------------
run_tool "Толстой Лев"
if (( RC == 0 )) && grep -q "2 of them skipped (exist)" "$ERR"; then
    report "skip_existing" ok
else
    report "skip_existing" fail "rc=$RC err=$(tail -2 "$ERR")"
fi

run_tool --force "Толстой Лев"
if (( RC == 0 )) && grep -q "0 of them skipped" "$ERR"; then
    report "force_reextract" ok
else
    report "force_reextract" fail "rc=$RC err=$(tail -2 "$ERR")"
fi

# --- no author matched --------------------------------------------------------------------
clean_out
run_tool "Nobody"
if (( RC == 1 )) && grep -q "no author matched" "$ERR"; then
    report "no_author_match_exit1" ok
else
    report "no_author_match_exit1" fail "rc=$RC err=$(tail -2 "$ERR")"
fi

# --- member absent from the archive: per-book failure, batch reports it --------------------
clean_out
run_tool "O'Brien"
if (( RC == 1 )) && grep -q "member not present" "$ERR"; then
    report "member_absent_exit1" ok
else
    report "member_absent_exit1" fail "rc=$RC err=$(tail -3 "$ERR")"
fi

# --- SQL escaping: quote (O''Brien) and percent (wild\%Name) --------------------------------
clean_out
run_tool --dry-run "O'Brien" "wild%Name"
if grep -q "LIKE '%O''Brien%'" "$MOCK_LOG" && grep -q "LIKE '%wild\\\\%Name%'" "$MOCK_LOG"; then
    report "sql_escaping" ok
else
    report "sql_escaping" fail "SQL: $(grep -o "LIKE '[^']*'" "$MOCK_LOG" | tr '\n' ' ')"
fi

# --- --limit reaches the SQL and is applied ---------------------------------------------------
clean_out
run_tool --limit 1 "Толстой Лев"
if grep -q "LIMIT 1" "$MOCK_LOG" && grep -q "summary: 1 book(s) delivered" "$ERR"; then
    report "limit_clause" ok
else
    report "limit_clause" fail "rc=$RC err=$(tail -2 "$ERR")"
fi

# --- from-file (BOM/CRLF/comments) --------------------------------------------------------------
clean_out
printf '\xEF\xBB\xBFТолстой Лев\r\n\r\n# comment\r\nТолстой Алексей\r\n' > "$TMPDIR/names.txt"
run_tool --from-file "$TMPDIR/names.txt"
if (( RC == 0 )) && [[ -f "$OUTPUT_DIR/100001.fb2" ]] && [[ -f "$OUTPUT_DIR/100005.fb2" ]] \
   && grep -q "summary: 3 book(s) delivered" "$ERR"; then
    report "from_file_batch" ok
else
    report "from_file_batch" fail "rc=$RC err=$(tail -3 "$ERR")"
fi

# --- summary --------------------------------------------------------------------------------------
echo
if (( FAIL_COUNT == 0 )); then
    echo "$PASS_COUNT passed, $FAIL_COUNT failed"
    exit 0
else
    echo "$PASS_COUNT passed, $FAIL_COUNT failed"
    for line in "${FAILURE_LINES[@]}"; do echo "  FAILED: $line"; done
    exit 1
fi
