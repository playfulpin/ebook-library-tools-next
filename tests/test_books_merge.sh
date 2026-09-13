#!/usr/bin/env bash

# __ETL_TEST_ENV_GUARD__: a caller with set -x/set -v auto-exports SHELLOPTS;
# every child bash re-applies it (it is readonly when imported), so xtrace
# noise corrupts the suites output captures.  Re-exec clean instead.
if [[ ${SHELLOPTS-} == *xtrace* || ${SHELLOPTS-} == *verbose* ]]; then
    exec env -u SHELLOPTS -u BASHOPTS bash "$0" "$@"
fi
unset SHELLOPTS BASHOPTS 2>/dev/null || true


###############################################################################
# tests/test_books_merge.sh
#
# Regression suite for bin/books/books_merge.sh: build the author
# prefix tree IN MEMORY from a flat author list, then copy the files of
# every top-level archive author folder into a directory named after the
# author, placed under the deepest valid prefix, preserving book-series
# subfolders and never overwriting anything the user has not explicitly
# allowed.  Output lands in a timestamped, pruned staging tree
# (<output-root>/BooksInput_<timestamp>) ready for the rsync finalize step.
#
# Coverage:
#   * DRY RUN   -- resolves every author, writes all six reports, creates no
#                 staging directory and copies nothing (status would-copy).
#   * FULL RUN  -- mixed extensions (.fb2/.epub/.zip/.txt) land under the
#                 author folder inside the right prefix dir with content
#                 intact; book-series subfolders are copied recursively;
#                 unmatched authors are reported and left untouched; the
#                 staging tree contains no empty directories (pruned by
#                 construction).
#   * SKIP      -- Windows metadata (desktop.ini, Thumbs.db) is never copied.
#   * DUPLICATE -- a pre-existing destination file is never overwritten
#                 (policy never) and is recorded as duplicate-name.
#   * COLLISION -- two source folders that resolve to the same author folder
#                 with the same book name: first copy wins, second is
#                 recorded as collision.
#   * OVERWRITE -- --overwrite=force replaces existing files (status
#                 overwritten); --overwrite=ask with non-interactive stdin
#                 behaves like never.
#   * CONFIG    -- config file supplies input file/source/output-root/
#                 report-dir and behavior; command-line flags and
#                 environment variables override it.
#   * CLI       -- usage errors, -h/-v, missing/unknown options, dangerous
#                 output root, bad overwrite policy, missing config file.
#   * VERSION   -- bin and lib carry the same 0.2.x header version.
#
# Usage:
#   wsl.exe bash tests/test_books_merge.sh
#
# The prefix tree slices UTF-8 prefixes character by character, so the shell
# must have multi-byte support (WSL).  Cygwin/MSYS bash is byte-based and
# will mangle Cyrillic prefixes.
#
# IMPORTANT: every invocation passes --config pointing at an empty file so
# the repository's config/books_merge.conf (real user paths) can never leak
# into a test run.  The config group uses its own explicit config file.
#
# Exit status: 0 if every check passed, 1 otherwise.
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../bin/books/books_merge.sh"
LIB="$SCRIPT_DIR/../lib/books_functions.sh"

[[ -f "$SCRIPT" ]] || { echo "ERROR: $SCRIPT not found" >&2; exit 2; }
[[ -f "$LIB" ]] || { echo "ERROR: $LIB not found" >&2; exit 2; }

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Empty config used by every non-config test invocation (see header note).
EMPTY_CONFIG="$TMPDIR/empty.conf"
: > "$EMPTY_CONFIG"

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

# --- run the merge tool, capture stdout and stderr separately ---------------
# usage: run_merge <outfile> <errfile> [--stdin FILE] -- args...
run_merge() {
    local outfile="$1" errfile="$2"
    shift 2
    local stdin_file=""
    if [[ "${1:-}" == "--stdin" ]]; then
        stdin_file="$2"
        shift 2
    fi
    # A leading "--" separates the helper's own options from the tool's
    # arguments; strip it so it is never forwarded to the tool (where it
    # would end option parsing).
    if [[ "${1:-}" == "--" ]]; then
        shift
    fi
    set +e
    if [[ -n "$stdin_file" ]]; then
        bash "$SCRIPT" "$@" < "$stdin_file" > "$outfile" 2> "$errfile"
    else
        bash "$SCRIPT" "$@" > "$outfile" 2> "$errfile"
    fi
    LAST_RC=$?
    set -e
}

# --- report row counts by status ---------------------------------------------
count_status() { # report  status
    awk -F '\t' -v s="$2" 'NR>1 && $5==s {n++} END{print n+0}' "$1"
}
count_rows() { # report
    awk 'NR>1 {n++} END{print n+0}' "$1"
}

###############################################################################
# fixtures
###############################################################################
# write_basic_authors <file>
#   Five authors engineered so that with --min-authors 2 --max-prefix 4 the
#   valid prefixes are exactly: А, Аб, Абр, Абра, Т, То, Тол, Толс.
#   "Абрамов Александр Иванович" resolves to А/Аб/Абр/Абра and
#   "Толстой Лев Николаевич" to Т/То/Тол/Толс -- the same deepest prefixes
#   the old on-disk skeleton fixtures used.
write_basic_authors() {
    cat > "$1" <<'EOF'
Абрамов Александр Иванович
Абрамович Сергей
Толстой Алексей Константинович
Толстой Алексей Николаевич
Толстой Лев Николаевич
EOF
}

# build_basic_fixtures <dir> [precreate]
#   dir       - destination root for staging output/ and source/Author/
#   precreate - if "old", a destination file with OLD content is placed at
#               the author folder's Война и мир.fb2 (in the staging tree at
#               <dir>/BooksInput_<ts>) before merging
build_basic_fixtures() {
    local base="$1" precreate="${2:-}"
    local source="$base/source/Author"

    mkdir -p "$base"
    write_basic_authors "$base/authors.txt"

    mkdir -p "$source/Толстой Лев Николаевич/Серия Война и мир"
    printf 'fb2\n' > "$source/Толстой Лев Николаевич/Война и мир.fb2"
    printf 'epub\n' > "$source/Толстой Лев Николаевич/Анна Каренина.epub"
    printf 'zip\n'  > "$source/Толстой Лев Николаевич/collection.zip"
    printf 'txt\n'  > "$source/Толстой Лев Николаевич/notes.txt"
    printf 'meta\n' > "$source/Толстой Лев Николаевич/desktop.ini"
    printf 'nested\n' > "$source/Толстой Лев Николаевич/Серия Война и мир/secret.fb2"
    printf 'meta\n' > "$source/Толстой Лев Николаевич/Серия Война и мир/desktop.ini"

    mkdir -p "$source/Абрамов Александр Иванович"
    printf 'book\n' > "$source/Абрамов Александр Иванович/Рассказы.fb2"

    mkdir -p "$source/Неизвестный Автор"
    printf 'x\n' > "$source/Неизвестный Автор/thing.fb2"

    if [[ "$precreate" == "old" ]]; then
        mkdir -p "$base/BooksInput_$precreate/Т/То/Тол/Толс/Толстой Лев Николаевич"
        printf 'OLD\n' > "$base/BooksInput_$precreate/Т/То/Тол/Толс/Толстой Лев Николаевич/Война и мир.fb2"
    fi
}

###############################################################################
# dry run: resolve and report, copy nothing
###############################################################################
run_dry_run_tests() {
    echo "== dry run =="
    local base="$TMPDIR/dry" out="$TMPDIR/dry_out.txt" err="$TMPDIR/dry_err.txt"
    local reports="$TMPDIR/dry_reports"
    build_basic_fixtures "$base"

    run_merge "$out" "$err" -- \
        --config "$EMPTY_CONFIG" \
        --source "$base/source/Author" \
        --input-file "$base/authors.txt" \
        --output-root "$base" \
        --timestamp dry \
        --report-dir "$reports" \
        --min-authors 2 --max-prefix 4 \
        --dry-run

    if (( LAST_RC == 0 )); then
        report "dry_run_exits_0" ok
    else
        report "dry_run_exits_0" fail "exit code $LAST_RC"
    fi

    # No staging tree may be created by a dry run.
    if [[ ! -d "$base/BooksInput_dry" ]]; then
        report "dry_run_copies_nothing" ok
    else
        report "dry_run_copies_nothing" fail "staging tree created in dry run"
    fi

    if [[ -f "$reports/merge-manifest.tsv" ]]; then
        report "dry_run_manifest_written" ok
    else
        report "dry_run_manifest_written" fail "merge-manifest.tsv missing"
    fi

    # 6 real files would-copy, 2 desktop.ini skipped, 1 unmatched.
    local wc sk un
    wc="$(count_status "$reports/merge-manifest.tsv" "would-copy")"
    sk="$(count_status "$reports/merge-manifest.tsv" "skipped")"
    un="$(count_status "$reports/merge-manifest.tsv" "unmatched-author")"
    if (( wc == 6 && sk == 2 && un == 1 )); then
        report "dry_run_statuses" ok
    else
        report "dry_run_statuses" fail "would-copy=$wc skipped=$sk unmatched=$un (expect 6/2/1)"
    fi

    # The author resolves into its own folder under the prefix.
    if grep -q "Т/То/Тол/Толс/Толстой Лев Николаевич/Серия Война и мир/secret.fb2" \
        "$reports/merge-manifest.tsv"; then
        report "dry_run_author_folder" ok
    else
        report "dry_run_author_folder" fail "author folder missing from destination path"
    fi

    if grep -q "Неизвестный Автор" "$reports/unmatched-authors.tsv"; then
        report "dry_run_unmatched_reported" ok
    else
        report "dry_run_unmatched_reported" fail "unmatched author missing from report"
    fi
}

###############################################################################
# full run: mixed formats + series land under the author in the prefix dirs
###############################################################################
run_full_run_tests() {
    echo "== full run =="
    local base="$TMPDIR/full" out="$TMPDIR/full_out.txt" err="$TMPDIR/full_err.txt"
    local reports="$TMPDIR/full_reports"
    local tol="$base/BooksInput_full/Т/То/Тол/Толс/Толстой Лев Николаевич"
    build_basic_fixtures "$base"

    run_merge "$out" "$err" -- \
        --config "$EMPTY_CONFIG" \
        --source "$base/source/Author" \
        --input-file "$base/authors.txt" \
        --output-root "$base" \
        --timestamp full \
        --report-dir "$reports" \
        --min-authors 2 --max-prefix 4

    if (( LAST_RC == 0 )); then
        report "full_run_exits_0" ok
    else
        report "full_run_exits_0" fail "exit code $LAST_RC"
    fi

    local ok=true
    [[ "$(cat "$tol/Война и мир.fb2")" == "fb2" ]] || ok=false
    [[ "$(cat "$tol/Анна Каренина.epub")" == "epub" ]] || ok=false
    [[ "$(cat "$tol/collection.zip")" == "zip" ]] || ok=false
    [[ "$(cat "$tol/notes.txt")" == "txt" ]] || ok=false
    [[ "$(cat "$base/BooksInput_full/А/Аб/Абр/Абра/Абрамов Александр Иванович/Рассказы.fb2")" == "book" ]] || ok=false
    if [[ "$ok" == true ]]; then
        report "full_run_mixed_formats_copied" ok
    else
        report "full_run_mixed_formats_copied" fail "a copied file is missing or has wrong content"
    fi

    if [[ "$(cat "$tol/Серия Война и мир/secret.fb2")" == "nested" ]]; then
        report "full_run_series_copied" ok
    else
        report "full_run_series_copied" fail "series book missing or wrong content"
    fi

    if [[ -z "$(find "$base/BooksInput_full" -name 'desktop.ini')" ]]; then
        report "full_run_desktop_ini_skipped" ok
    else
        report "full_run_desktop_ini_skipped" fail "desktop.ini was copied into the staging tree"
    fi

    # The staging tree is pruned by construction: only directories holding a
    # copied file exist, so there are no empty directories.
    if [[ "$(find "$base/BooksInput_full" -type d -empty | wc -l)" == "0" ]]; then
        report "full_run_staging_pruned" ok
    else
        report "full_run_staging_pruned" fail "empty directories found in the staging tree"
    fi

    if [[ -f "$base/source/Author/Толстой Лев Николаевич/Война и мир.fb2" \
       && -f "$base/source/Author/Неизвестный Автор/thing.fb2" ]]; then
        report "full_run_source_untouched" ok
    else
        report "full_run_source_untouched" fail "source archive was modified"
    fi

    local copied
    copied="$(count_status "$reports/merge-manifest.tsv" "copied")"
    if (( copied == 6 )); then
        report "full_run_manifest_copied" ok
    else
        report "full_run_manifest_copied" fail "copied=$copied (expect 6)"
    fi
}

###############################################################################
# skip: Windows metadata never lands in the library
###############################################################################
run_skip_tests() {
    echo "== skip list =="
    local base="$TMPDIR/skip" out="$TMPDIR/skip_out.txt" err="$TMPDIR/skip_err.txt"
    local reports="$TMPDIR/skip_reports"
    local source="$base/source/Author"

    mkdir -p "$base"
    write_basic_authors "$base/authors.txt"
    mkdir -p "$source/Толстой Лев Николаевич/Серия"
    printf 'fb2\n' > "$source/Толстой Лев Николаевич/real.fb2"
    printf 'meta\n' > "$source/Толстой Лев Николаевич/desktop.ini"
    printf 'meta\n' > "$source/Толстой Лев Николаевич/Thumbs.db"
    printf 'meta\n' > "$source/Толстой Лев Николаевич/Серия/desktop.ini"
    printf 'meta\n' > "$source/Толстой Лев Николаевич/Серия/Thumbs.db"

    run_merge "$out" "$err" -- \
        --config "$EMPTY_CONFIG" \
        --source "$source" --input-file "$base/authors.txt" \
        --output-root "$base" --timestamp skip \
        --report-dir "$reports" --min-authors 2 --max-prefix 4

    local tol="$base/BooksInput_skip/Т/То/Тол/Толс/Толстой Лев Николаевич"
    if [[ -f "$tol/real.fb2" ]] \
       && [[ ! -e "$tol/desktop.ini" ]] \
       && [[ ! -e "$tol/Thumbs.db" ]] \
       && [[ ! -e "$tol/Серия/desktop.ini" ]] \
       && [[ ! -e "$tol/Серия/Thumbs.db" ]]; then
        report "skip_metadata_not_copied" ok
    else
        report "skip_metadata_not_copied" fail "a skipped metadata file reached the staging tree"
    fi

    local sk
    sk="$(count_status "$reports/merge-manifest.tsv" "skipped")"
    if (( sk == 4 )) && grep -q "Windows metadata" "$reports/skipped-files.tsv"; then
        report "skip_metadata_recorded" ok
    else
        report "skip_metadata_recorded" fail "skipped rows=$sk (expect 4), reason not in skipped-files"
    fi
}

###############################################################################
# duplicate: pre-existing destination file is never overwritten (never)
###############################################################################
run_duplicate_tests() {
    echo "== duplicate-name =="
    local base="$TMPDIR/dup" out="$TMPDIR/dup_out.txt" err="$TMPDIR/dup_err.txt"
    local reports="$TMPDIR/dup_reports"
    build_basic_fixtures "$base" "old"

    run_merge "$out" "$err" -- \
        --config "$EMPTY_CONFIG" \
        --source "$base/source/Author" \
        --input-file "$base/authors.txt" \
        --output-root "$base" \
        --timestamp old \
        --report-dir "$reports" \
        --min-authors 2 --max-prefix 4

    if [[ "$(cat "$base/BooksInput_old/Т/То/Тол/Толс/Толстой Лев Николаевич/Война и мир.fb2")" == "OLD" ]]; then
        report "duplicate_not_overwritten" ok
    else
        report "duplicate_not_overwritten" fail "pre-existing destination file was overwritten"
    fi

    local dn
    dn="$(count_status "$reports/merge-manifest.tsv" "duplicate-name")"
    if (( dn >= 1 )) && grep -q "Война и мир.fb2" "$reports/duplicates.tsv"; then
        report "duplicate_recorded" ok
    else
        report "duplicate_recorded" fail "duplicate-name rows=$dn, file not in duplicates.tsv"
    fi
}

###############################################################################
# collision: two source folders -> same author folder -> same book name
###############################################################################
run_collision_tests() {
    echo "== collision =="
    local base="$TMPDIR/coll" out="$TMPDIR/coll_out.txt" err="$TMPDIR/coll_err.txt"
    local reports="$TMPDIR/coll_reports"
    local source="$base/source/Author"

    mkdir -p "$base"
    cat > "$base/authors.txt" <<'EOF'
Майоров Иван
Майоров Пётр
EOF
    # A leading-space folder name trims to the same author ("Майоров Иван")
    # as the plain one, so both resolve to М/Май/Майо/Майоров Иван.  Space
    # (0x20) sorts before Cyrillic М (0xD0), so the leading-space folder is
    # processed first.
    mkdir -p "$source/ Майоров Иван" "$source/Майоров Иван"
    printf 'one\n' > "$source/ Майоров Иван/same.fb2"
    printf 'two\n' > "$source/Майоров Иван/same.fb2"

    run_merge "$out" "$err" -- \
        --config "$EMPTY_CONFIG" \
        --source "$source" \
        --input-file "$base/authors.txt" \
        --output-root "$base" --timestamp coll \
        --report-dir "$reports" \
        --min-authors 2 --max-prefix 4

    if [[ "$(cat "$base/BooksInput_coll/М/Ма/Май/Майо/Майоров Иван/same.fb2")" == "one" ]]; then
        report "collision_first_copy_wins" ok
    else
        report "collision_first_copy_wins" fail "first source did not win"
    fi

    local coll
    coll="$(count_status "$reports/merge-manifest.tsv" "collision")"
    if (( coll == 1 )) && grep -q "Майоров Иван" "$reports/collisions.tsv"; then
        report "collision_recorded" ok
    else
        report "collision_recorded" fail "collision rows=$coll, author missing from collisions.tsv"
    fi
}

###############################################################################
# overwrite: force replaces, ask (non-interactive) behaves like never
###############################################################################
run_overwrite_tests() {
    echo "== overwrite policy =="

    # --- force --------------------------------------------------------------
    local base="$TMPDIR/owf" out="$TMPDIR/owf_out.txt" err="$TMPDIR/owf_err.txt"
    local reports="$TMPDIR/owf_reports"
    build_basic_fixtures "$base" "old"

    run_merge "$out" "$err" -- \
        --config "$EMPTY_CONFIG" \
        --source "$base/source/Author" \
        --input-file "$base/authors.txt" \
        --output-root "$base" \
        --timestamp old \
        --report-dir "$reports" \
        --min-authors 2 --max-prefix 4 \
        --overwrite force

    if [[ "$(cat "$base/BooksInput_old/Т/То/Тол/Толс/Толстой Лев Николаевич/Война и мир.fb2")" == "fb2" ]]; then
        report "overwrite_force_replaces" ok
    else
        report "overwrite_force_replaces" fail "existing file was not replaced"
    fi

    local ow
    ow="$(count_status "$reports/merge-manifest.tsv" "overwritten")"
    if (( ow >= 1 )); then
        report "overwrite_force_recorded" ok
    else
        report "overwrite_force_recorded" fail "no overwritten rows in manifest"
    fi

    # --- ask with non-interactive stdin: behaves like never -------------------
    local base2="$TMPDIR/owa" out2="$TMPDIR/owa_out.txt" err2="$TMPDIR/owa_err.txt"
    local reports2="$TMPDIR/owa_reports"
    build_basic_fixtures "$base2" "old"

    run_merge "$out2" "$err2" --stdin /dev/null -- \
        --config "$EMPTY_CONFIG" \
        --source "$base2/source/Author" \
        --input-file "$base2/authors.txt" \
        --output-root "$base2" \
        --timestamp old \
        --report-dir "$reports2" \
        --min-authors 2 --max-prefix 4 \
        --overwrite ask

    if [[ "$(cat "$base2/BooksInput_old/Т/То/Тол/Толс/Толстой Лев Николаевич/Война и мир.fb2")" == "OLD" ]]; then
        report "overwrite_ask_noninteractive_skips" ok
    else
        report "overwrite_ask_noninteractive_skips" fail "non-interactive ask overwrote a file"
    fi

    local dn
    dn="$(count_status "$reports2/merge-manifest.tsv" "duplicate-name")"
    if (( dn >= 1 )); then
        report "overwrite_ask_recorded" ok
    else
        report "overwrite_ask_recorded" fail "non-interactive ask did not record duplicate-name"
    fi
}

###############################################################################
# config: file supplies paths + behavior; flags and env override it
###############################################################################
run_config_tests() {
    echo "== config file =="
    local base="$TMPDIR/cfg" out="$TMPDIR/cfg_out.txt" err="$TMPDIR/cfg_err.txt"
    local cfg="$TMPDIR/cfg.conf"

    local cfg_source="$base/source/Author"
    local cfg_reports="$base/cfg_reports"
    mkdir -p "$base" "$cfg_source/Толстой Лев Николаевич/Серия"
    printf 'fb2\n' > "$cfg_source/Толстой Лев Николаевич/Война и мир.fb2"
    printf 'nested\n' > "$cfg_source/Толстой Лев Николаевич/Серия/том1.fb2"
    write_basic_authors "$base/cfg_authors.txt"

    cat > "$cfg" <<EOF
MERGE_INPUT_FILE="$base/cfg_authors.txt"
MERGE_SOURCE_DIR="$cfg_source"
MERGE_OUTPUT_DIR="$base"
MERGE_REPORT_DIR="$cfg_reports"
MERGE_RECURSIVE="OFF"
MERGE_MIN_AUTHORS=2
MERGE_MAX_PREFIX=4
EOF

    # No path flags: everything comes from the config file.
    run_merge "$out" "$err" -- --config "$cfg" --timestamp cfg1
    if (( LAST_RC == 0 )) \
       && [[ -f "$base/BooksInput_cfg1/Т/То/Тол/Толс/Толстой Лев Николаевич/Война и мир.fb2" ]] \
       && [[ ! -e "$base/BooksInput_cfg1/Т/То/Тол/Толс/Толстой Лев Николаевич/Серия/том1.fb2" ]] \
       && [[ -f "$cfg_reports/merge-manifest.tsv" ]]; then
        report "config_paths_and_behavior" ok
    else
        report "config_paths_and_behavior" fail "config file was not honored (paths or MERGE_RECURSIVE=OFF)"
    fi

    # Flags override the config file.
    local src2="$TMPDIR/cfg_src2" out2="$TMPDIR/cfg_out2.txt" err2="$TMPDIR/cfg_err2.txt"
    local rep2="$TMPDIR/cfg_rep2"
    mkdir -p "$src2/Толстой Лев Николаевич/Серия"
    printf 'fb2\n' > "$src2/Толстой Лев Николаевич/Война и мир.fb2"
    printf 'nested\n' > "$src2/Толстой Лев Николаевич/Серия/том1.fb2"

    run_merge "$out2" "$err2" -- \
        --config "$cfg" \
        --source "$src2" --input-file "$base/cfg_authors.txt" \
        --output-root "$base" --timestamp cfg2 --report-dir "$rep2" \
        --recursive
    if (( LAST_RC == 0 )) \
       && [[ -f "$base/BooksInput_cfg2/Т/То/Тол/Толс/Толстой Лев Николаевич/Серия/том1.fb2" ]] \
       && [[ ! -f "$base/BooksInput_cfg1/Т/То/Тол/Толс/Толстой Лев Николаевич/Серия/том1.fb2" ]]; then
        report "config_flags_override" ok
    else
        report "config_flags_override" fail "command-line flags did not override the config file"
    fi

    # Environment variables override the config file.
    local src3="$TMPDIR/cfg_src3" out3="$TMPDIR/cfg_out3.txt" err3="$TMPDIR/cfg_err3.txt"
    local rep3="$TMPDIR/cfg_rep3"
    mkdir -p "$src3/Толстой Лев Николаевич"
    printf 'env\n' > "$src3/Толстой Лев Николаевич/env.fb2"

    set +e
    MERGE_SOURCE_DIR="$src3" bash "$SCRIPT" \
        --config "$cfg" --input-file "$base/cfg_authors.txt" \
        --output-root "$base" --timestamp cfg3 --report-dir "$rep3" \
        > "$out3" 2> "$err3"
    rc_env=$?
    set -e
    if (( rc_env == 0 )) && [[ -f "$base/BooksInput_cfg3/Т/То/Тол/Толс/Толстой Лев Николаевич/env.fb2" ]]; then
        report "config_env_overrides" ok
    else
        report "config_env_overrides" fail "environment variable did not override the config file"
    fi
}

###############################################################################
# cli: usage errors and options
###############################################################################
run_cli_tests() {
    echo "== CLI =="
    local out="$TMPDIR/cli_out.txt" err="$TMPDIR/cli_err.txt"
    local source="$TMPDIR/cli_source" list="$TMPDIR/cli_authors.txt" root="$TMPDIR/cli_root"
    mkdir -p "$source/Толстой Лев Николаевич" "$root"
    write_basic_authors "$list"

    # -h prints the version and exits non-zero (usage() exits 1).
    run_merge "$out" "$err" -- -h
    if (( LAST_RC != 0 )) && grep -qE 'books_merge.sh v[0-9]+\.[0-9]+\.[0-9]+' "$err"; then
        report "cli_help_version" ok
    else
        report "cli_help_version" fail "-h must print the version to stderr and exit 1"
    fi

    # -v prints the version and exits 0.
    run_merge "$out" "$err" -- -v
    if (( LAST_RC == 0 )) && grep -qE 'v[0-9]+\.[0-9]+\.[0-9]+' "$out"; then
        report "cli_version" ok
    else
        report "cli_version" fail "-v must print the version and exit 0"
    fi

    local -a ERROR_CASES=(
        "cli_no_args|--config $EMPTY_CONFIG"
        "cli_unknown_flag|--config $EMPTY_CONFIG --bogus"
        "cli_missing_source|--config $EMPTY_CONFIG --input-file $list --output-root $root"
        "cli_missing_input|--config $EMPTY_CONFIG --source $source --output-root $root"
        "cli_missing_root|--config $EMPTY_CONFIG --source $source --input-file $list"
        "cli_bad_source|--config $EMPTY_CONFIG --source /nonexistent --input-file $list --output-root $root"
        "cli_bad_input|--config $EMPTY_CONFIG --source $source --input-file /nonexistent --output-root $root"
        "cli_bad_root|--config $EMPTY_CONFIG --source $source --input-file $list --output-root /"
        "cli_bad_min|--config $EMPTY_CONFIG --source $source --input-file $list --output-root $root --min-authors 0"
        "cli_bad_max|--config $EMPTY_CONFIG --source $source --input-file $list --output-root $root --max-prefix abc"
        "cli_bad_overwrite|--config $EMPTY_CONFIG --source $source --input-file $list --output-root $root --overwrite maybe"
        "cli_missing_config|--config /nonexistent.conf --source $source --input-file $list --output-root $root"
    )
    for c in "${ERROR_CASES[@]}"; do
        IFS='|' read -r label args <<< "$c"
        run_merge "$out" "$err" -- $args
        if (( LAST_RC != 0 )); then
            report "$label" ok
        else
            report "$label" fail "expected non-zero exit"
        fi
    done

    # Combined and isolated option forms both work.
    run_merge "$out" "$err" -- \
        --config="$EMPTY_CONFIG" --source="$source" --input-file="$list" \
        --output-root="$root" --timestamp=form1 \
        --report-dir="$TMPDIR/cli_r1" --dry-run --min-authors=2 --max-prefix=4
    rc_combined=$LAST_RC
    run_merge "$out" "$err" -- \
        --config "$EMPTY_CONFIG" --source "$source" --input-file "$list" \
        --output-root "$root" --timestamp form2 \
        --report-dir "$TMPDIR/cli_r2" --dry-run --min-authors 2 --max-prefix 4
    rc_isolated=$LAST_RC
    if (( rc_combined == 0 && rc_isolated == 0 )) \
       && diff -q "$TMPDIR/cli_r1/merge-manifest.tsv" "$TMPDIR/cli_r2/merge-manifest.tsv" >/dev/null 2>&1; then
        report "cli_forms_identical" ok
    else
        report "cli_forms_identical" fail "combined and isolated option forms differ"
    fi
}

###############################################################################
# version header: bin and lib share the same 0.2.x version
###############################################################################
run_release_tests() {
    echo "== version header =="
    local vbin vlib
    vbin="$(sed -n 's/^# Version:[[:space:]]*//p' "$SCRIPT" | head -n 1)"
    vlib="$(sed -n 's/^# Version:[[:space:]]*//p' "$LIB" | head -n 1)"

    if [[ "$vbin" =~ ^0\.2\.[0-9]+$ ]]; then
        report "version_bin" ok
    else
        report "version_bin" fail "got '$vbin', expected ^0\\.2\\.[0-9]+$"
    fi
    if [[ "$vlib" =~ ^0\.2\.[0-9]+$ ]]; then
        report "version_lib" ok
    else
        report "version_lib" fail "got '$vlib', expected ^0\\.2\\.[0-9]+$"
    fi
    if [[ "$vbin" == "$vlib" ]]; then
        report "version_in_sync" ok
    else
        report "version_in_sync" fail "bin '$vbin' != lib '$vlib'"
    fi
}

###############################################################################
# dispatch
###############################################################################
case "${1:-all}" in
    all)      run_dry_run_tests; run_full_run_tests; run_skip_tests
              run_duplicate_tests; run_collision_tests; run_overwrite_tests
              run_config_tests; run_cli_tests; run_release_tests ;;
    dry)      run_dry_run_tests ;;
    full)     run_full_run_tests ;;
    skip)     run_skip_tests ;;
    duplicate) run_duplicate_tests ;;
    collision) run_collision_tests ;;
    overwrite) run_overwrite_tests ;;
    config)   run_config_tests ;;
    cli)      run_cli_tests ;;
    release)  run_release_tests ;;
    --list)
        echo "dry:        resolve + report only, nothing copied"
        echo "full:       mixed formats + series copied under the author folder"
        echo "skip:       desktop.ini / Thumbs.db are never copied"
        echo "duplicate:  pre-existing destination never overwritten"
        echo "collision:  same author folder + name from two sources"
        echo "overwrite:  force replaces, ask (non-interactive) behaves like never"
        echo "config:     config file paths + behavior; flags/env override"
        echo "cli:        usage errors, -h/-v, option forms"
        echo "release:    matching 0.2.x version headers"
        exit 0
        ;;
    *) echo "Unknown check group '$1'." >&2; exit 1 ;;
esac

echo ""
echo "=============================="
echo "PASS: $PASS_COUNT   FAIL: $FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then
    printf '  %s\n' "${FAILURE_LINES[@]}"
    exit 1
fi
echo "All tests passed."
