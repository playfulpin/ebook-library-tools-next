#!/usr/bin/env bash

# __ETL_TEST_ENV_GUARD__: a caller with set -x/set -v auto-exports SHELLOPTS;
# every child bash re-applies it (it is readonly when imported), so xtrace
# noise corrupts the suites output captures.  Re-exec clean instead.
if [[ ${SHELLOPTS-} == *xtrace* || ${SHELLOPTS-} == *verbose* ]]; then
    exec env -u SHELLOPTS -u BASHOPTS bash "$0" "$@"
fi
unset SHELLOPTS BASHOPTS 2>/dev/null || true

# -----------------------------------------------------------------------------
# tests/test_library_report.sh
#
# Regression suite for bin/library/library_report.sh (the personal-library wish list
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
#   (good rows still work), password never on the mysql command line, and
#   the v1.1 NATIVE wishlist views (--native title|author|series|all over
#   mllbr_main.mlgroup/mlgroupname: group headers, author/series/title
#   grouping, added-date, not-in-library listing, library-name filter in
#   the SQL, empty-groups failure, view-name validation).
#
# Usage:  bash tests/test_library_report.sh
# Runs anywhere (pure text processing).
# -----------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOL="$REPO_ROOT/bin/library/library_report.sh"

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
MOCK_GROUPS="$TMPDIR_WS/native-groups.tsv"
MOCK_ASSIGN="$TMPDIR_WS/native-assign.tsv"
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
        # native wishlists: group metadata query vs assignment rows query
        # (the group query reads FROM mllbr_main.mlgroupname; the
        # assignments query reads FROM mllbr_main.mlgroup with a WHERE)
        *"FROM mllbr_main.mlgroupname gn"*) cat "${MOCK_GROUPS:-/dev/null}" ;;
        *"FROM mllbr_main.mlgroup g"*)      cat "${MOCK_ASSIGN:-/dev/null}" ;;
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
# native wishlist fixtures: groups (groupid TAB groupname TAB count) and
# assignments (bookid TAB groupid TAB date_gr; 555 is NOT in the catalog)
printf '2\tК прочтению\t3\n' > "$MOCK_GROUPS"
{ printf '101\t2\t2026-09-06 18:20:01\n'
  printf '103\t2\t2026-09-06 19:00:00\n'
  printf '555\t2\t2026-09-06 19:30:00\n'
} > "$MOCK_ASSIGN"

OUT="$TMPDIR_WS/stdout.txt"
ERR="$TMPDIR_WS/stderr.txt"

WISH="$TMPDIR_WS/wishlist.tsv"
CONF="$TMPDIR_WS/no-such.conf"
REPORTS="$TMPDIR_WS/reports"

run_tool() { # [args...]
    env PATH="$MOCK_BIN:$PATH" \
        MOCK_LOG="$MOCK_LOG" MOCK_JOIN="$MOCK_JOIN" MOCK_SEARCH="$MOCK_SEARCH" \
        MOCK_GROUPS="$MOCK_GROUPS" MOCK_ASSIGN="$MOCK_ASSIGN" \
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

echo "== library_report =="

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

# --- 6b. native wishlists (mllbr_main views, v1.1) ------------------------------
reset_wish
: > "$MOCK_LOG"
run_tool --native author
if (( RC == 0 )); then report "native_run_ok" ok; else report "native_run_ok" fail "rc=$RC err=$(cat "$ERR")"; fi
grep -q "native wishlists (library 'myprivatelib'): 2 entries" "$OUT" \
    && report "native_header_tally" ok || report "native_header_tally" fail "$(head -1 "$OUT")"
grep -q "^== К прочтению (3) ==$" "$OUT" \
    && report "native_group_header" ok || report "native_group_header" fail "$(grep '==' "$OUT" | head -2)"
grep -q "Азимов Айзек" "$OUT" && grep -q "Другой Автор" "$OUT" \
    && report "native_author_grouping" ok || report "native_author_grouping" fail "authors missing"
grep -q "101  Первая книга  (Основание #1, rating 5)  -- added 2026-09-06 18:20:01" "$OUT" \
    && report "native_row_shape" ok || report "native_row_shape" fail "$(grep -A1 'Азимов' "$OUT")"
grep -q "^not in library (assigned in-app, absent from the catalog):$" "$OUT" \
    && grep -q "\[?\] 555 (К прочтению)  -- added 2026-09-06 19:30:00" "$OUT" \
    && report "native_not_in_library" ok || report "native_not_in_library" fail "$(grep -A2 'not in library' "$OUT")"

grep -q "g.library = 'myprivatelib'" "$MOCK_LOG" \
    && report "native_library_scoped_sql" ok || report "native_library_scoped_sql" fail "no library filter in SQL"

run_tool --native title
grep -q "Первая книга  \[101\]" "$OUT" \
    && report "native_title_view" ok || report "native_title_view" fail "$(cat "$OUT")"
run_tool --native series
grep -q "^  Основание$" "$OUT" && grep -q "#1  Первая книга  \[101\]" "$OUT" \
    && grep -q "^  (no series)$" "$OUT" \
    && report "native_series_view" ok || report "native_series_view" fail "$(cat "$OUT")"
run_tool --native all
grep -q "===== by author =====" "$OUT" && grep -q "===== by title =====" "$OUT" \
    && grep -q "===== by series =====" "$OUT" \
    && report "native_all_views" ok || report "native_all_views" fail "section headers missing"
run_tool --native bogus
(( RC != 0 )) && report "native_rejects_bad_view" ok || report "native_rejects_bad_view" fail "rc=$RC"

REPORT_GROUP_LIBRARY=otherlib run_tool --native author
grep -q "g.library = 'otherlib'" "$MOCK_LOG" \
    && report "native_library_override" ok || report "native_library_override" fail "override ignored"
grep -q "native wishlists (library 'otherlib')" "$OUT" \
    && report "native_library_override_header" ok || report "native_library_override_header" fail "$(head -1 "$OUT")"

# empty native state -> clean failure with a hint, not a crash
: > "$MOCK_GROUPS"; : > "$MOCK_ASSIGN"
run_tool --native author
if (( RC == 1 )) && grep -q "no native wishlist entries" "$ERR"; then
    report "native_empty_state_fails_cleanly" ok
else
    report "native_empty_state_fails_cleanly" fail "rc=$RC err=$(cat "$ERR")"
fi
printf '2\tК прочтению\t3\n' > "$MOCK_GROUPS"
{ printf '101\t2\t2026-09-06 18:20:01\n'; printf '103\t2\t2026-09-06 19:00:00\n'; printf '555\t2\t2026-09-06 19:30:00\n'; } > "$MOCK_ASSIGN"

# --- 6c. hybrid view (TSV plan x native app state, v1.2) -------------------------
# fixtures: native assignments = 101 (wish group, i.e. "app" state), 103
# (read group -> "done"), 555 (wish group, NOT in catalog); the TSV has
# 101 wish / 102 reading / 103 done, and 999 not-collected.
printf '1\tИзбранное\t0\n' >> "$MOCK_GROUPS"
printf '3\tПрочитано\t1\n' >> "$MOCK_GROUPS"
{ printf '101\t2\t2026-09-06 18:20:01\n'
  printf '103\t3\t2026-09-05 10:00:00\n'
  printf '555\t2\t2026-09-06 19:30:00\n'
  printf '104\t1\t2026-09-06 20:00:00\n'
  printf '105\t2\t2026-09-06 20:30:00\n'
} > "$MOCK_ASSIGN"
printf '101\tПервая книга\tАзимов Айзек\tОснование\t1\t5\n'  >> "$MOCK_JOIN"
printf '104\tЛюбимая книга\tАзимов Айзек\t\t\t4\n'            >> "$MOCK_JOIN"
printf '105\tТолько в приложении\tАзимов Айзек\t\t\t4\n'      >> "$MOCK_JOIN"

reset_wish
printf '104\t2026-09-06\t\twish\tfavorite via app\n' >> "$WISH"
printf '999\t2026-09-06\t2026-09\twish\tnot collected yet\n' >> "$WISH"
run_tool --hybrid
if (( RC == 0 )); then report "hybrid_run_ok" ok; else report "hybrid_run_ok" fail "rc=$RC err=$(cat "$ERR")"; fi
# tallies: TSV = 101 wish, 102 reading, 103 done, 104 wish, 999 wish; native
# flips 103 to done (Прочитано) -> wish 3 (101, 104, 999), reading 1, done 1;
# app-known = 101, 103, 104, 105; favorite = 104 (Избранное)
grep -q "hybrid plan: 5 entries  (wish 3, reading 1, done 1; app 4, favorites 1)" "$OUT" \
    && report "hybrid_header_tally" ok || report "hybrid_header_tally" fail "$(head -1 "$OUT")"
grep -q '^== 2026-09 ==$' "$OUT" && grep -q '^== (no period) ==$' "$OUT" \
    && report "hybrid_period_sections" ok || report "hybrid_period_sections" fail "$(grep '^==' "$OUT")"
grep -q '\[app+tsv\] 101' "$OUT" \
    && report "hybrid_both_source_tag" ok || report "hybrid_both_source_tag" fail "no [app+tsv] tag"
grep -q '\[tsv\] 102' "$OUT" \
    && report "hybrid_tsv_source_tag" ok || report "hybrid_tsv_source_tag" fail "no [tsv] tag"
grep -q '\[app\] 105' "$OUT" && grep -q 'Только в приложении' "$OUT" \
    && report "hybrid_app_source_tag" ok || report "hybrid_app_source_tag" fail "no [app] tag"
# 103 is in the app READ group -> status must flip to done [x] even though
# the TSV said done already; 101 stays [ ] (app "К прочтению" = wish, TSV wish)
grep -q '\[x\] \[app+tsv\] 103' "$OUT" \
    && report "hybrid_native_read_overrides" ok || report "hybrid_native_read_overrides" fail "$(grep 103 "$OUT")"
grep -q '\[app+tsv\] ★ 104' "$OUT" \
    && report "hybrid_favorite_marker" ok || report "hybrid_favorite_marker" fail "no favorite star"
grep -q 'Любимая книга' "$OUT" \
    && report "hybrid_app_row_has_catalog" ok || report "hybrid_app_row_has_catalog" fail "app-only row lost catalog join"
grep -q 'marked in app: К прочтению' "$OUT" \
    && report "hybrid_app_note_lists_groups" ok || report "hybrid_app_note_lists_groups" fail "no app-group note"
grep -q '\[?\] 999 \[tsv\]' "$OUT" \
    && report "hybrid_notin_tsv_tag" ok || report "hybrid_notin_tsv_tag" fail "$(grep -A3 'not in library' "$OUT")"
grep -q '\[?\] 555 \[app\] (read in app)\|\[?\] 555 \[app\]' "$OUT" \
    && report "hybrid_notin_app_tag" ok || report "hybrid_notin_app_tag" fail "no [app] notin row"

: > "$MOCK_LOG"
run_tool --hybrid
grep -q "g.library = 'myprivatelib'" "$MOCK_LOG" \
    && report "hybrid_library_scoped_sql" ok || report "hybrid_library_scoped_sql" fail "no library filter"

# restore the v1.1-era native fixtures for the section above (idempotent for re-runs)
printf '2\tК прочтению\t3\n' > "$MOCK_GROUPS"
{ printf '101\t2\t2026-09-06 18:20:01\n'; printf '103\t2\t2026-09-06 19:00:00\n'; printf '555\t2\t2026-09-06 19:30:00\n'; } > "$MOCK_ASSIGN"

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
echo "All library_report tests passed."
exit 0
