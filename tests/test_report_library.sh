#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# tests/test_report_library.sh
#
# Regression suite for bin/report_library.sh (the personal-library wish list
# and reporting view).  No real MariaDB is needed: the suite installs a mock
# `mysql` that answers the read-only catalog join/search queries from fixture
# rows and records argv, and disables lifecycle management via a nonexistent
# MARIA_TASKLIST (mirroring the reconcile suite).
#
# Asserted contract:
#   wish-file format (5 TAB-separated fields, comments/blanks allowed,
#   BOM/CR tolerance), mutation commands (--add / --set-status / --remove
#   rewriting the file, header comments preserved, duplicates and invalid
#   statuses rejected), the DB view (period/author grouping, series #num,
#   rating, completion tally, "not in library" section), --no-db offline
#   view, --list, --search, TSV/MD exports, malformed-line tolerance
#   (good rows still work), and password never on the mysql command line.
#
# Usage:  bash tests/test_report_library.sh
# Runs anywhere (pure text processing).
# -----------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$REPO_ROOT/bin/report_library.sh"

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

TMPDIR_WS="$(mktemp -d "${TMPDIR:-/tmp}/wish_test.XXXXXX")"
trap 'rm -rf "$TMPDIR_WS"' EXIT

# --- mock mysql: catalog join + search from fixture rows, argv recording ------
MOCK_BIN="$TMPDIR_WS/mockbin"
MOCK_LOG="$TMPDIR_WS/mysql-argv.log"
MOCK_JOIN="$TMPDIR_WS/join-rows.tsv"
MOCK_SEARCH="$TMPDIR_WS/search-rows.tsv"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/mysql" <<'MOCK_EOF'
#!/usr/bin/env bash
printf 'MYSQL %s\n' "$*" >> "${MOCK_LOG:-/dev/null}"
for a in "$@"; do
    case "$a" in
        *"FROM mlbook b"*)
            if [[ "$a" == *"LIKE"* ]]; then
                cat "${MOCK_SEARCH:-/dev/null}"
            else
                cat "${MOCK_JOIN:-/dev/null}"
            fi
            ;;
    esac
done
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/mysql"

# join fixture: bookid TAB title TAB author TAB series TAB seqnum TAB rating
printf '101\tПервая книга\tАзимов Айзек\tОснование\t1\t5\n'  > "$MOCK_JOIN"
printf '102\tВторая книга\tАзимов Айзек\tОснование\t2\t4\n'  >> "$MOCK_JOIN"
printf '103\tСторонняя\tДругой Автор\t\t\t3\n'               >> "$MOCK_JOIN"
# search fixture: bookid TAB title TAB author
printf '201\tПиранья\tБушков Александр\n' > "$MOCK_SEARCH"

OUT="$TMPDIR_WS/stdout.txt"
ERR="$TMPDIR_WS/stderr.txt"

WISH="$TMPDIR_WS/wishlist.tsv"
CONF="$TMPDIR_WS/no-such.conf"
REPORTS="$TMPDIR_WS/reports"

run_tool() { # [args...]
    env PATH="$MOCK_BIN:$PATH" \
        MOCK_LOG="$MOCK_LOG" MOCK_JOIN="$MOCK_JOIN" MOCK_SEARCH="$MOCK_SEARCH" \
        MYSQL_PASSWORD="${MOCK_PASSWORD:-}" \
        REPORT_CONF_FILE="$CONF" \
        MARIA_TASKLIST="$TMPDIR_WS/no-tasklist" \
        REPORT_WISHLIST_FILE="$WISH" \
        REPORT_OUTPUT_DIR="$REPORTS" \
        bash "$TOOL" "$@" >"$OUT" 2>"$ERR"
    RC=$?
}

reset_wish() { # seed the wish file (header + rows)
    { echo "# header comment"
      echo ""
      printf '101\t2026-09-06\t2026-09\twish\tcycle one\n'
      printf '102\t2026-09-06\t2026-09\treading\t\n'
      printf '103\t2026-09-06\t2026-Q4\tdone\tno series here\n'
    } > "$WISH"
}

echo "== report_library =="

# --- 1. view: grouping, tallies, series/rating, not-in-library ----------------
reset_wish
printf '999\t2026-09-06\t2026-09\twish\tnot collected yet\n' >> "$WISH"
run_tool
if (( RC == 0 )); then report "view_run_ok" ok; else report "view_run_ok" fail "rc=$RC"; fi
grep -q "^== 2026-09 ==$" "$OUT" \
    && report "view_groups_by_period" ok || report "view_groups_by_period" fail "$(cat "$OUT")"
grep -q "^== 2026-Q4 ==$" "$OUT" \
    && report "view_second_period" ok || report "view_second_period" fail "no Q4 section"
grep -q "Азимов Айзек" "$OUT" \
    && report "view_groups_by_author" ok || report "view_groups_by_author" fail "author missing"
grep -q "Основание #1" "$OUT" && grep -q "Основание #2" "$OUT" \
    && report "view_series_position" ok || report "view_series_position" fail "series #num missing"
grep -q "rating 5" "$OUT" \
    && report "view_rating" ok || report "view_rating" fail "rating missing"
grep -q "\[x\]" "$OUT" && grep -q "\[~\]" "$OUT" && grep -q "\[ \]" "$OUT" \
    && report "view_status_marks" ok || report "view_status_marks" fail "status marks missing"
grep -q "wish list: 4 entries  (wish 2, reading 1, done 1)" "$OUT" \
    && report "view_completion_tally" ok || report "view_completion_tally" fail "$(head -1 "$OUT")"
grep -q "not in library" "$OUT" && grep -q "\[?\] 999 (2026-09)  -- not collected yet" "$OUT" \
    && report "view_not_in_library" ok || report "view_not_in_library" fail "$(grep -A2 'not in library' "$OUT" || true)"

# --- 2. --list: raw entries, comments preserved, no DB touch -------------------
: > "$MOCK_LOG"
run_tool --list
if (( RC == 0 )); then report "list_run_ok" ok; else report "list_run_ok" fail "rc=$RC"; fi
grep -q "^101	2026-09-06	2026-09	wish	cycle one$" "$OUT" \
    && report "list_raw_rows" ok || report "list_raw_rows" fail "$(cat "$OUT")"
[[ -s "$MOCK_LOG" ]] && report "list_no_db_touch" fail "mysql was invoked" \
    || report "list_no_db_touch" ok

# --- 3. --add -------------------------------------------------------------------
reset_wish
run_tool --add 777 --period 2026-10 --note "autumn plan"
if (( RC == 0 )); then report "add_run_ok" ok; else report "add_run_ok" fail "rc=$RC err=$(cat "$ERR")"; fi
grep -q "^777	$(date +%Y-%m-%d)	2026-10	wish	autumn plan$" "$WISH" \
    && report "add_writes_row" ok || report "add_writes_row" fail "$(tail -2 "$WISH" | cat -A)"
head -1 "$WISH" | grep -q "^# header comment$" \
    && report "add_preserves_header" ok || report "add_preserves_header" fail "$(head -1 "$WISH")"
run_tool --add 777
(( RC != 0 )) && report "add_rejects_duplicate" ok || report "add_rejects_duplicate" fail "rc=$RC"
run_tool --add notanumber
(( RC != 0 )) && report "add_rejects_nonnumeric" ok || report "add_rejects_nonnumeric" fail "rc=$RC"

# --- 4. --set-status -------------------------------------------------------------
reset_wish
run_tool --set-status 101 done
if (( RC == 0 )); then report "set_status_ok" ok; else report "set_status_ok" fail "rc=$RC err=$(cat "$ERR")"; fi
grep -q "^101	2026-09-06	2026-09	done	cycle one$" "$WISH" \
    && report "set_status_updates_row" ok || report "set_status_updates_row" fail "$(grep '^101' "$WISH")"
run_tool --set-status 101 bogus
(( RC != 0 )) && report "set_status_rejects_bad_status" ok || report "set_status_rejects_bad_status" fail "rc=$RC"
run_tool --set-status 404 done
(( RC != 0 )) && report "set_status_rejects_missing_id" ok || report "set_status_rejects_missing_id" fail "rc=$RC"

# --- 5. --remove ------------------------------------------------------------------
reset_wish
run_tool --remove 102
if (( RC == 0 )); then report "remove_ok" ok; else report "remove_ok" fail "rc=$RC err=$(cat "$ERR")"; fi
grep -q "^102	" "$WISH" && report "remove_deletes_row" fail "row still present" \
    || report "remove_deletes_row" ok
grep -q "^101	" "$WISH" \
    && report "remove_keeps_others" ok || report "remove_keeps_others" fail "101 lost"
run_tool --remove 404
(( RC != 0 )) && report "remove_rejects_missing_id" ok || report "remove_rejects_missing_id" fail "rc=$RC"

# --- 6. --search -------------------------------------------------------------------
: > "$MOCK_LOG"
reset_wish
run_tool --search piranha
if (( RC == 0 )); then report "search_ok" ok; else report "search_ok" fail "rc=$RC"; fi
grep -q "^201	Пиранья	Бушков Александр$" "$OUT" \
    && report "search_lists_candidates" ok || report "search_lists_candidates" fail "$(cat "$OUT")"
grep -q "MYSQL .*\-\-default-character-set=utf8" "$MOCK_LOG" \
    && report "search_uses_mysql_contract" ok || report "search_uses_mysql_contract" fail "$(cat "$MOCK_LOG")"

# --- 7. exports ----------------------------------------------------------------------
rm -rf "$REPORTS"
reset_wish
run_tool --export md
md_file="$(ls "$REPORTS"/report_wishlist_*.md 2>/dev/null | head -1)"
if (( RC == 0 )) && [[ -n "$md_file" ]]; then
    report "export_md_written" ok
    grep -q "^## 2026-09$" "$md_file" && grep -q "^### Азимов Айзек$" "$md_file" \
        && grep -q '^- \[ \] \*\*Первая книга\*\*' "$md_file" \
        && report "export_md_content" ok || report "export_md_content" fail "$(cat "$md_file")"
else
    report "export_md_written" fail "rc=$RC file=${md_file:-missing} err=$(cat "$ERR")"
fi
rm -rf "$REPORTS"
run_tool --export tsv
tsv_file="$(ls "$REPORTS"/report_wishlist_*.tsv 2>/dev/null | head -1)"
if (( RC == 0 )) && [[ -n "$tsv_file" ]]; then
    report "export_tsv_written" ok
    grep -q "^bookid	status	period	added	title	author	series	seqnum	rating	note$" "$tsv_file" \
        && grep -q "^101	wish	2026-09	2026-09-06	Первая книга	Азимов Айзек	Основание	1	5	cycle one$" "$tsv_file" \
        && report "export_tsv_content" ok || report "export_tsv_content" fail "$(head -3 "$tsv_file" | cat -A)"
else
    report "export_tsv_written" fail "rc=$RC file=${tsv_file:-missing}"
fi

# --- 8. --no-db offline view --------------------------------------------------------
reset_wish
run_tool --no-db
if (( RC == 0 )); then report "no_db_view_ok" ok; else report "no_db_view_ok" fail "rc=$RC"; fi
grep -q "== 2026-09 ==" "$OUT" \
    && report "no_db_shows_entries" ok || report "no_db_shows_entries" fail "$(cat "$OUT")"
grep -q "(title unknown)" "$OUT" \
    && report "no_db_marks_unknown_titles" ok || report "no_db_marks_unknown_titles" fail "offline view has no unknown-title marker"

# --- 9. malformed-line tolerance -------------------------------------------------------
reset_wish
printf 'garbage line without tabs\n' >> "$WISH"
run_tool
if (( RC == 0 )); then report "malformed_line_skipped" ok; else report "malformed_line_skipped" fail "rc=$RC"; fi
grep -q "warn: skipping malformed" "$ERR" \
    && report "malformed_line_warned" ok || report "malformed_line_warned" fail "$(cat "$ERR")"
grep -q "Азимов Айзек" "$OUT" \
    && report "malformed_good_rows_still_render" ok || report "malformed_good_rows_still_render" fail "good rows lost"

# --- 10. BOM + CR tolerance ----------------------------------------------------------------
printf '\xEF\xBB\xBF# bom header\r\n' > "$WISH"
printf '101\t2026-09-06\t2026-09\twish\tcrlf row\r\n' >> "$WISH"
run_tool --list
if (( RC == 0 )) && grep -q "^101	2026-09-06	2026-09	wish	crlf row$" "$OUT"; then
    report "bom_cr_tolerated" ok
else
    report "bom_cr_tolerated" fail "rc=$RC out=$(cat "$OUT" | cat -A)"
fi

# --- 11. password hygiene ---------------------------------------------------------------------
: > "$MOCK_LOG"
MOCK_PASSWORD="s3cret" run_tool --search piranha
if grep -q "s3cret" "$MOCK_LOG" 2>/dev/null; then
    report "password_never_on_argv" fail "password leaked to mysql argv"
else
    report "password_never_on_argv" ok
fi

# --- 12. usage paths ----------------------------------------------------------------------------
run_tool --bogus
(( RC == 2 )) && report "unknown_option_exit2" ok || report "unknown_option_exit2" fail "rc=$RC"
run_tool --export pdf
(( RC != 0 )) && report "export_bad_format_rejected" ok || report "export_bad_format_rejected" fail "rc=$RC"
run_tool --help >/dev/null 2>&1
(( RC == 0 )) && report "help_exits_0" ok || report "help_exits_0" fail "rc=$RC"
run_tool --version >/dev/null 2>&1
(( RC == 0 )) && report "version_exits_0" ok || report "version_exits_0" fail "rc=$RC"

# --- summary -----------------------------------------------------------------------------------
echo
echo "=============================="
echo "PASS: $PASS_COUNT   FAIL: $FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then
    printf '  - %s\n' "${FAILURE_LINES[@]}"
    exit 1
fi
echo "All report_library tests passed."
exit 0
