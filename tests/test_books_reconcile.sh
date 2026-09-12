#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# tests/test_books_reconcile.sh
#
# Regression suite for bin/books/books_reconcile.sh (catalog scope vs on-disk
# library reconciliation).  No real MariaDB and no real library are needed:
# the suite builds a fake library tree and a fake scope file, and installs a
# mock `mysql` for the mlauthorname snapshot (or runs with --no-db).
#
# Asserts the classification contract:
#   matched / missing / empty / orphan-known / orphan-unknown rows, the TSV
#   report shape, --dry-run writing nothing, --no-db degrading gracefully,
#   mock-snapshot book counts + known-orphan classification, password never
#   on the mysql command line, and usage/error paths.
#
# Usage:  bash tests/test_books_reconcile.sh
# Runs anywhere (pure text processing; lifecycle management is disabled via a
# nonexistent MARIA_TASKLIST, mirroring the exporter suite).
# -----------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$REPO_ROOT/bin/books/books_reconcile.sh"

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

TMPDIR_WS="$(mktemp -d "${TMPDIR:-/tmp}/recon_test.XXXXXX")"
trap 'rm -rf "$TMPDIR_WS"' EXIT

# --- fake library (flat <letter>/<author>[/series] layout) ---------------------
LIB="$TMPDIR_WS/lib"
mkdir -p "$LIB/А/Абби Линн" "$LIB/А/Азимов Айзек" "$LIB/M/MeXXanik Гоблин/Серия"
mkdir -p "$LIB/M/Стругацкие Братья" "$LIB/П/Пустой Автор"  # empty, not on the list
printf 'x' > "$LIB/А/Азимов Айзек/kniga1.fb2"
printf 'x' > "$LIB/M/MeXXanik Гоблин/Серия/book1.fb2"
printf 'x' > "$LIB/M/MeXXanik Гоблин/loose.zip"
printf 'x' > "$LIB/M/Стругацкие Братья/kniga1.fb2"
# "Абби Линн" exists but stays empty on purpose

# --- fake scope file -----------------------------------------------------------
SCOPE="$TMPDIR_WS/scope.txt"
printf 'Азимов Айзек\nАбби Линн\nМартынов Георгий\n' > "$SCOPE"

# --- mock mysql: catalog snapshot rows + argv recording ------------------------
MOCK_BIN="$TMPDIR_WS/mockbin"
MOCK_LOG="$TMPDIR_WS/mysql-argv.log"
MOCK_CATALOG="$TMPDIR_WS/catalog-rows.tsv"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/mysql" <<'MOCK_EOF'
#!/usr/bin/env bash
printf 'MYSQL %s\n' "$*" >> "${MOCK_LOG:-/dev/null}"
for a in "$@"; do
    if [[ "$a" == *"SELECT FullName, TotalCount FROM mlauthorname"* ]]; then
        cat "${MOCK_CATALOG:-/dev/null}"
    fi
done
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/mysql"
printf 'MeXXanik Гоблин\t12\nАзимов Айзек\t25\nСтругацкие Братья\t4\nПустой Автор\t3\n' > "$MOCK_CATALOG"

REPORT_DIR="$TMPDIR_WS/reports"
OUT="$TMPDIR_WS/stdout.txt"
ERR="$TMPDIR_WS/stderr.txt"
RC=0

run_tool() { # [args...]
    env PATH="$MOCK_BIN:$PATH" \
        MOCK_LOG="$MOCK_LOG" MOCK_CATALOG="$MOCK_CATALOG" \
        MYSQL_PASSWORD="${MOCK_PASSWORD:-}" \
        RECON_CONF_FILE="$TMPDIR_WS/no-such.conf" \
        MARIA_TASKLIST="$TMPDIR_WS/no-tasklist" \
        RECON_REPORT_DIR="$REPORT_DIR" \
        bash "$TOOL" "$@" >"$OUT" 2>"$ERR"
    RC=$?
}

echo "== books_reconcile =="

# --- version / usage ------------------------------------------------------------
version="$(sed -n 's/^# Version:[[:space:]]*//p' "$TOOL" | head -n 1)"
if [[ "$version" =~ ^1\.0\.[0-9]+$ ]]; then
    report "version_header" ok "header $version"
else
    report "version_header" fail "got '$version', expected ^1.0.[0-9]+$"
fi
bash "$TOOL" --version >"$TMPDIR_WS/v.txt" 2>&1
if [[ "$(cat "$TMPDIR_WS/v.txt")" == "bin/books/books_reconcile.sh v$version" ]]; then
    report "version_flag" ok
else
    report "version_flag" fail
fi
bash "$TOOL" --help >"$TMPDIR_WS/h.txt" 2>&1
if (( $? == 0 )) && grep -q -- "--library-root" "$TMPDIR_WS/h.txt"; then
    report "help_exit0" ok
else
    report "help_exit0" fail
fi
bash "$TOOL" --bogus >"$TMPDIR_WS/u.txt" 2>&1
if (( $? == 2 )); then
    report "unknown_option_exit2" ok
else
    report "unknown_option_exit2" fail
fi

# --- no-db classification (matched / missing / empty / orphan-unknown) ---------
rm -f "$REPORT_DIR"/*
run_tool -l "$LIB" -s "$SCOPE" --no-db
report_file="$(ls "$REPORT_DIR"/books_reconcile_*.tsv 2>/dev/null | head -1)"
if (( RC == 0 )) && [[ -n "$report_file" ]]; then
    report "no_db_run_writes_report" ok
else
    report "no_db_run_writes_report" fail "rc=$RC file=${report_file:-missing}"
fi
row_empty=$'\tАбби Линн\t1\t1\t0\t-\t0\tempty'
row_missing=$'\tМартынов Георгий\t1\t0\t0\t-\t-\tmissing'
row_orphan=$'\tMeXXanik Гоблин\t0\t1\t0\t-\t2\torphan-unknown'
row_matched=$'\tАзимов Айзек\t1\t1\t0\t-\t1\tmatched'
if grep -qF "$row_empty" "$report_file" \
   && grep -qF "$row_missing" "$report_file" \
   && grep -qF "$row_orphan" "$report_file" \
   && grep -qF "$row_matched" "$report_file"; then
    report "no_db_classification" ok
else
    report "no_db_classification" fail "report: $(tr '\n' '|' < "$report_file")"
fi
if grep -qF "$row_matched" "$report_file"; then
    report "matched_has_files" ok
else
    report "matched_has_files" fail
fi
# the human summary speaks the personal-collection model: progress against
# the recommended list, with beyond-the-list content counted separately
# (no-db run above: 3 scope authors -> Азимов collected, Мартынов still to
# collect, Абби empty; MeXXanik + Стругацкие beyond list, unknown)
if grep -qE "collection progress \(recommended-author list: 3 author\(s\)\):" "$OUT" \
   && grep -qE "authors \(from list\)[[:space:]]+1[[:space:]]+33.3% of the list" "$OUT" \
   && grep -qE "authors \(beyond list\)[[:space:]]+2[[:space:]]+66.7% of all loaded authors" "$OUT" \
   && grep -qE "listed / unlisted author ratio[[:space:]]+33.3%$" "$OUT" \
   && grep -qE "authors \(remaining to collect\)[[:space:]]+2$" "$OUT" \
   && grep -qE "books on disk[[:space:]]+4$" "$OUT" \
   && grep -qE "books \(from listed authors\)[[:space:]]+1[[:space:]]+25.0% of books on disk" "$OUT" \
   && grep -qE "books \(beyond list authors\)[[:space:]]+3[[:space:]]+75.0% of books on disk" "$OUT" \
   && grep -qE "listed / unlisted books ratio[[:space:]]+25.0%$" "$OUT" \
   && grep -qE "empty \(folder, no books\)[[:space:]]+1$" "$OUT"; then
    report "summary_collection_progress_no_db" ok
else
    report "summary_collection_progress_no_db" fail "$(tr '\n' '|' < "$OUT")"
fi
# the run also exports the next-round shopping list: every recommended
# author with no books on disk yet (Мартынов Георгий missing + Абби Линн
# empty folder), byte-ordered, one canonical name per line
report_file="$(ls "$REPORT_DIR"/books_reconcile_to_collect_*.txt 2>/dev/null | head -1)"
if [[ -n "$report_file" ]] \
   && grep -qF "Мартынов Георгий" "$report_file" \
   && grep -qF "Абби Линн" "$report_file" \
   && [[ "$(wc -l < "$report_file" | tr -d ' ')" == "2" ]]; then
    report "to_collect_list_exported" ok
else
    report "to_collect_list_exported" fail "file=${report_file:-missing}"
fi
if [[ -n "$report_file" ]] && head -n 1 "$report_file" | grep -qF "Абби Линн"; then
    report "to_collect_list_byte_order" ok
else
    report "to_collect_list_byte_order" fail "first line: $(head -n 1 "$report_file" 2>/dev/null)"
fi

# --- dry-run writes nothing -----------------------------------------------------
before="$(ls "$REPORT_DIR" | wc -l)"
run_tool -l "$LIB" -s "$SCOPE" --no-db --dry-run
after="$(ls "$REPORT_DIR" | wc -l)"
if (( RC == 0 )) && (( before == after )) && grep -q "dry-run: report would be written" "$ERR"; then
    report "dry_run_no_write" ok
else
    report "dry_run_no_write" fail "rc=$RC before=$before after=$after"
fi

# --- db snapshot: book counts + orphan-known ------------------------------------
rm -f "$REPORT_DIR"/* "$MOCK_LOG"
MOCK_PASSWORD=s3cret run_tool -l "$LIB" -s "$SCOPE"
report_file="$(ls "$REPORT_DIR"/books_reconcile_*.tsv 2>/dev/null | head -1)"
row_known=$'\tMeXXanik Гоблин\t0\t1\t1\t12\t2\torphan-known'
row_counts=$'\tАзимов Айзек\t1\t1\t1\t25\t1\tmatched'
if grep -qF "$row_known" "$report_file"; then
    report "db_orphan_known_with_counts" ok
else
    report "db_orphan_known_with_counts" fail "report: $(tr '\n' '|' < "$report_file")"
fi
if grep -qF "$row_counts" "$report_file"; then
    report "db_matched_book_count" ok
else
    report "db_matched_book_count" fail
fi
argv="$(cat "$MOCK_LOG")"
if [[ "$argv" == *"s3cret"* ]]; then
    report "db_password_never_on_cmdline" fail "password leaked into argv"
else
    report "db_password_never_on_cmdline" ok
fi
# db run above: beyond-the-list content (MeXXanik + Стругацкие) is now
# known to the catalog via the mock snapshot
if grep -qE "authors \(from list\)[[:space:]]+1[[:space:]]+33.3% of the list" "$OUT" \
   && grep -qE "listed / unlisted author ratio[[:space:]]+33.3%$" "$OUT" \
   && grep -qE "books \(from listed authors\)[[:space:]]+1[[:space:]]+25.0% of books on disk" "$OUT" \
   && grep -qE "listed / unlisted books ratio[[:space:]]+25.0%$" "$OUT"; then
    report "summary_ratio_lines_db" ok
else
    report "summary_ratio_lines_db" fail "$(tr '\n' '|' < "$OUT")"
fi
# beyond-books review export (db run above): every on-disk file attributed
# to a beyond-list author (MeXXanik Гоблин + Стругацкие Братья), as
# author<TAB>relative-path; collected-author files are excluded
beyond_file="$(ls "$REPORT_DIR"/books_reconcile_beyond_books_*.tsv 2>/dev/null | head -1)"
row_a=$'MeXXanik Гоблин\tM/MeXXanik Гоблин/loose.zip'
row_b=$'MeXXanik Гоблин\tM/MeXXanik Гоблин/Серия/book1.fb2'
row_c=$'Стругацкие Братья\tM/Стругацкие Братья/kniga1.fb2'
if [[ -n "$beyond_file" ]] \
   && [[ "$(wc -l < "$beyond_file" | tr -d ' ')" == "3" ]] \
   && grep -qF "$row_a" "$beyond_file" \
   && grep -qF "$row_b" "$beyond_file" \
   && grep -qF "$row_c" "$beyond_file"; then
    report "beyond_books_export_content" ok
else
    report "beyond_books_export_content" fail "file=${beyond_file:-missing} lines=$(wc -l < "${beyond_file:-/dev/null}" 2>/dev/null | tr -d ' ')"
fi
if [[ -n "$beyond_file" ]] && ! grep -qF $'Азимов Айзек\t' "$beyond_file"; then
    report "beyond_books_excludes_collected" ok
else
    report "beyond_books_excludes_collected" fail "collected-author file leaked into the export"
fi
# a book-less folder that matches a catalog name but is not on the list is
# not an author-with-books: it must not appear in the report or the export
if ! grep -qF $'\tПустой Автор\t' "$report_file" \
   && [[ -n "$beyond_file" ]] && ! grep -qF $'Пустой Автор\t' "$beyond_file"; then
    report "bookless_beyond_folder_not_reported" ok
else
    report "bookless_beyond_folder_not_reported" fail "book-less 'Пустой Автор' folder leaked into report/export"
fi

# --- nested skeleton layout (DB mode): authors at depth>2 are found -----------
# The merge pipeline nests authors under structural prefix dirs
# (<letter>/<prefix>/.../<author>[/series]); the disk scan must recognize the
# author folder by NAME at any depth and never report prefix dirs as orphans
# or double-count series files under nested authors.
NESTED="$TMPDIR_WS/nested"
mkdir -p "$NESTED/А/Аб/Абр/Абра/Абрамов Александр/Серия"
mkdir -p "$NESTED/А/Аб/Абби Линн"
mkdir -p "$NESTED/А/Ал"        # structural prefix dir, no files, not an author
printf 'x' > "$NESTED/А/Аб/Абр/Абра/Абрамов Александр/Серия/kniga1.fb2"
printf 'x' > "$NESTED/А/Аб/Абр/Абра/Абрамов Александр/Серия/kniga2.fb2"
printf 'x' > "$NESTED/А/Аб/Абби Линн/kniga1.fb2"

NESTED_SCOPE="$TMPDIR_WS/scope_nested.txt"
printf 'Абрамов Александр\nАбби Линн\nАзимов Айзек\n' > "$NESTED_SCOPE"
# mock catalog knows both nested authors + one extra
printf 'Абрамов Александр\t9\nАбби Линн\t3\nАзимов Айзек\t7\n' > "$MOCK_CATALOG"
rm -f "$REPORT_DIR"/* "$MOCK_LOG"
run_tool -l "$NESTED" -s "$NESTED_SCOPE"
report_file="$(ls "$REPORT_DIR"/books_reconcile_*.tsv 2>/dev/null | head -1)"
row_nested=$'\tАбрамов Александр\t1\t1\t1\t9\t2\tmatched'
row_nested_ci=$'\tАбби Линн\t1\t1\t1\t3\t1\tmatched'
row_nested_miss=$'\tАзимов Айзек\t1\t0\t1\t7\t-\tmissing'
if grep -qF "$row_nested" "$report_file" \
   && grep -qF "$row_nested_ci" "$report_file" \
   && grep -qF "$row_nested_miss" "$report_file"; then
    report "nested_authors_found_at_depth" ok
else
    report "nested_authors_found_at_depth" fail "report: $(tr '\n' '|' < "$report_file")"
fi
if grep -qF "$'\tАл\t'" "$report_file"; then
    report "prefix_dir_not_reported" fail "structural dir А/Ал leaked into report"
else
    report "prefix_dir_not_reported" ok
fi
# series files counted once under the nested author, no stray rows for series
if grep -qF "$'\tСерия\t'" "$report_file"; then
    report "series_dir_not_stray" fail "series dir reported as orphan"
else
    report "series_dir_not_stray" ok
fi

# --- error paths -----------------------------------------------------------------
run_tool -l "$TMPDIR_WS/nope-lib" -s "$SCOPE" --no-db
if (( RC == 1 )) && grep -q "library root not found" "$ERR"; then
    report "missing_library_root" ok
else
    report "missing_library_root" fail "rc=$RC stderr=$(head -2 "$ERR")"
fi

run_tool -l "$LIB" -s "$TMPDIR_WS/nope-scope.txt" --no-db
if (( RC == 1 )) && grep -q "scope file not found" "$ERR"; then
    report "missing_scope_file" ok
else
    report "missing_scope_file" fail
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
