#!/usr/bin/env bash

# __ETL_TEST_ENV_GUARD__: a caller with set -x/set -v auto-exports SHELLOPTS;
# every child bash re-applies it (it is readonly when imported), so xtrace
# noise corrupts the suites output captures.  Re-exec clean instead.
if [[ ${SHELLOPTS-} == *xtrace* || ${SHELLOPTS-} == *verbose* ]]; then
    exec env -u SHELLOPTS -u BASHOPTS bash "$0" "$@"
fi
unset SHELLOPTS BASHOPTS 2>/dev/null || true


###############################################################################
# tests/test_books_finalize.sh
#
# Regression suite for bin/books/books_finalize.sh, the rsync wrapper
# that finalizes a timestamped staging tree (BooksInput_<ts>, produced by
# bin/books/books_merge.sh, already pruned) into the Books library.
# The destination wins: --ignore-existing never overwrites a file already
# present in the library.  A per-file TSV report records every copied file
# and every kept-existing conflict.
#
# Coverage:
#   * DRY RUN      -- resolves the staging tree, writes a would-copy/would-keep
#                     report, and changes nothing.
#   * FULL RUN     -- new content is copied into Books, pre-existing files
#                     are kept, staging is retained, the report records both.
#   * AUTO-DETECT  -- with no --source, the newest BooksInput_* folder under
#                     --output-root is used.
#   * PROGRESS     -- the pv -l progress filter (extracted from the script)
#                     strips rsync's header/blank/summary lines so the line
#                     tally equals the files+dirs item count (exact 100%),
#                     with and without a pre-existing destination.
#   * CLI          -- usage errors, -h/-v, path-safety guards (dangerous
#                     root, non-BooksInput_* source, target inside source).
#   * VERSION      -- script carries a 0.2.x header version.
#
# Usage:
#   bash tests/test_books_finalize.sh
#
# Requires rsync on PATH; the suite SKIPS (exit 0) when it is absent (e.g.
# Git Bash without rsync).  Ubuntu CI runners ship rsync.
#
# Exit status: 0 if every check passed, 1 otherwise; 2 if misconfigured.
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../../bin/books/books_finalize.sh"

[[ -f "$SCRIPT" ]] || { echo "ERROR: $SCRIPT not found" >&2; exit 2; }

# rsync is a hard prerequisite of the tool; skip the whole suite without it
# so a bare Git Bash (no rsync) stays green.
if ! command -v rsync >/dev/null 2>&1; then
    echo "SKIP  (rsync not found on PATH)"
    exit 0
fi

# MSYS/Cygwin rsync misreads converted Windows-drive paths as remote hosts
# ("The source and destination cannot both be remote"), so the suite -- like
# the tool -- is only usable where rsync sees real POSIX paths (WSL, Linux).
# Probing uname is far cheaper and more reliable than letting every check
# fail with that cryptic rsync usage error.
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        echo "SKIP  (MSYS rsync cannot sync Windows-drive paths; run from WSL)"
        exit 0
        ;;
esac

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

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

run_script() { # out err -- args...
    local out="$1" err="$2"
    shift 2
    if [[ "${1:-}" == "--" ]]; then shift; fi
    set +e
    bash "$SCRIPT" "$@" > "$out" 2> "$err"
    LAST_RC=$?
    set -e
}

###############################################################################
# fixture: a BooksInput_* staging tree + a Books library with one conflict
###############################################################################
build_fixture() { # base
    local base="$1"
    local staging="$base/BooksInput_t1" books="$base/Books"

    mkdir -p "$staging/Т/То/Толс/Толстой Лев Николаевич"
    mkdir -p "$staging/С/Сл"
    mkdir -p "$staging/emptyA"
    mkdir -p "$books/С/Сл"

    printf 'fb2\n' > "$staging/Т/То/Толс/Толстой Лев Николаевич/Война и мир.fb2"
    printf 'SRC\n' > "$staging/С/Сл/Same.fb2"
    printf 'TGT\n' > "$books/С/Сл/Same.fb2"    # pre-existing conflict, wins
    printf 'KEEP\n' > "$books/keep.fb2"
}

# --- locate the single generated report file in REPORT_DIR ------------------
report_for() { # report_dir -> prints the file path (or nothing)
    find "$1" -maxdepth 1 -name 'books_finalize_*.tsv' | head -n 1
}

# The real-run progress pipeline pipes rsync's listing through
#   grep --line-buffered -v -E '<filter>' | pv -l -s <item-count>
# The filter regex lives in the script; extract it verbatim so this suite
# tests the actual implementation and fails loudly if the script line
# ever changes shape.
SYNC_FILTER="$(sed -n "s|.*grep --line-buffered -v -E '\([^']*\)'.*|\1|p" "$SCRIPT" | head -n 1)"
if [[ -z "$SYNC_FILTER" ]]; then
    echo "ERROR: cannot extract the progress filter regex from $SCRIPT" >&2
    exit 2
fi

###############################################################################
# progress filter: stripped listing must tally exactly files+dirs (100%)
###############################################################################
run_progress_tests() {
    echo "== progress filter (exact 100% tally) =="
    local base="$TMPDIR/prog"
    local staging="$base/BooksInput_t1" books="$base/Books"
    mkdir -p "$staging/d1" "$staging/d2/d3" "$books"
    for i in $(seq 1 40); do printf 'x\n' > "$staging/d1/f$i.bin"; done
    for i in $(seq 1 30); do printf 'y\n' > "$staging/d2/d3/g$i.bin"; done

    local items n
    items="$(find "$staging" -mindepth 1 \( -type f -o -type d \) | wc -l | tr -d ' ')"

    # Destination already exists (the script validates the target upfront),
    # so rsync emits one line per file/dir plus header/summary noise.
    n="$(rsync -av "$staging/" "$books/" 2>/dev/null \
        | grep --line-buffered -v -E "$SYNC_FILTER" | wc -l | tr -d ' ' || true)"
    if [[ "$n" == "$items" ]]; then
        report "progress_filter_existing_dst" ok "$n/$items lines"
    else
        report "progress_filter_existing_dst" fail "filtered $n lines, expected $items"
    fi

    # Fresh destination: rsync additionally emits 'created directory' and the
    # './' root line; the filter must strip those too (worst case).
    n="$(rsync -av "$staging/" "$base/Books_fresh/" 2>/dev/null \
        | grep --line-buffered -v -E "$SYNC_FILTER" | wc -l | tr -d ' ' || true)"
    if [[ "$n" == "$items" ]]; then
        report "progress_filter_fresh_dst" ok "$n/$items lines"
    else
        report "progress_filter_fresh_dst" fail "filtered $n lines, expected $items"
    fi
}

###############################################################################
# dry run: no changes
###############################################################################
run_dry_tests() {
    echo "== dry run =="
    local base="$TMPDIR/dry" out="$TMPDIR/dry_out.txt" err="$TMPDIR/dry_err.txt"
    local reports="$TMPDIR/dry_reports"
    build_fixture "$base"

    run_script "$out" "$err" -- \
        --source "$base/BooksInput_t1" --target "$base/Books" \
        --report-dir "$reports" --dry-run

    if (( LAST_RC == 0 )); then
        report "dry_exits_0" ok
    else
        report "dry_exits_0" fail "exit code $LAST_RC"
    fi

    # Nothing may change in the library.
    if [[ "$(cat "$base/Books/С/Сл/Same.fb2")" == "TGT" ]] \
       && [[ "$(cat "$base/Books/keep.fb2")" == "KEEP" ]] \
       && [[ ! -e "$base/Books/Т/То/Толс/Толстой Лев Николаевич/Война и мир.fb2" ]]; then
        report "dry_nothing_changed" ok
    else
        report "dry_nothing_changed" fail "dry run changed the library"
    fi

    local rfile
    rfile="$(report_for "$reports")"
    if [[ -n "$rfile" ]] && grep -q 'would-copy' "$rfile" \
       && grep -q 'would-keep' "$rfile"; then
        report "dry_report_rows" ok
    else
        report "dry_report_rows" fail "report lacks would-copy/would-keep rows"
    fi
}

###############################################################################
# full run: copy new content, keep conflicts, retain staging
###############################################################################
run_full_tests() {
    echo "== full run =="
    local base="$TMPDIR/full" out="$TMPDIR/full_out.txt" err="$TMPDIR/full_err.txt"
    local reports="$TMPDIR/full_reports"
    build_fixture "$base"

    run_script "$out" "$err" -- \
        --source "$base/BooksInput_t1" --target "$base/Books" \
        --report-dir "$reports"

    if (( LAST_RC == 0 )); then
        report "full_exits_0" ok
    else
        report "full_exits_0" fail "exit code $LAST_RC"
    fi

    local ok=true
    [[ "$(cat "$base/Books/Т/То/Толс/Толстой Лев Николаевич/Война и мир.fb2")" == "fb2" ]] || ok=false
    [[ "$(cat "$base/Books/С/Сл/Same.fb2")" == "TGT" ]] || ok=false          # not overwritten
    [[ "$(cat "$base/Books/keep.fb2")" == "KEEP" ]] || ok=false
    if [[ "$ok" == true ]]; then
        report "full_copy_no_overwrite" ok
    else
        report "full_copy_no_overwrite" fail "copy or overwrite behavior wrong"
    fi

    # Staging retained intact.
    if [[ -d "$base/BooksInput_t1" ]] \
       && [[ -f "$base/BooksInput_t1/Т/То/Толс/Толстой Лев Николаевич/Война и мир.fb2" ]]; then
        report "full_staging_retained" ok
    else
        report "full_staging_retained" fail "staging folder was not retained"
    fi

    local rfile
    rfile="$(report_for "$reports")"
    if [[ -n "$rfile" ]] && grep -q '^copied\|copied' "$rfile" \
       && grep -q 'kept-existing' "$rfile" \
       && grep -q 'Same.fb2' "$rfile"; then
        report "full_report_rows" ok
    else
        report "full_report_rows" fail "report does not record copied and kept-existing"
    fi
}

###############################################################################
# auto-detect: newest BooksInput_* under --output-root
###############################################################################
run_auto_detect_tests() {
    echo "== auto-detect BooksInput_* =="
    local base="$TMPDIR/ad" out="$TMPDIR/ad_out.txt" err="$TMPDIR/ad_err.txt"
    local reports="$TMPDIR/ad_reports"
    build_fixture "$base"
    # A second, older staging folder: discovery must pick the newest.
    mkdir -p "$base/BooksInput_old"
    printf 'stale\n' > "$base/BooksInput_old/stale.fb2"

    run_script "$out" "$err" -- \
        --output-root "$base" --target "$base/Books" \
        --report-dir "$reports"

    if (( LAST_RC == 0 )); then
        report "auto_detect_exits_0" ok
    else
        report "auto_detect_exits_0" fail "exit code $LAST_RC"
    fi

    if grep -q "auto-discovered staging: $base/BooksInput_t1" "$out"; then
        report "auto_detect_newest" ok
    else
        report "auto_detect_newest" fail "did not auto-discover the newest staging folder"
    fi

    if [[ "$(cat "$base/Books/Т/То/Толс/Толстой Лев Николаевич/Война и мир.fb2")" == "fb2" ]]; then
        report "auto_detect_copied" ok
    else
        report "auto_detect_copied" fail "newest staging was not copied into Books"
    fi
}

###############################################################################
# cli: errors and options
###############################################################################
run_cli_tests() {
    echo "== CLI =="
    local out="$TMPDIR/cli_out.txt" err="$TMPDIR/cli_err.txt"
    local sk="$TMPDIR/cli_sk" books="$TMPDIR/cli_books"
    mkdir -p "$sk/f" "$books"

    # -h prints version and exits non-zero (usage exits 1).
    run_script "$out" "$err" -- -h
    if (( LAST_RC != 0 )) && grep -qE 'books_finalize.sh v[0-9]+\.[0-9]+\.[0-9]+' "$err"; then
        report "cli_help_version" ok
    else
        report "cli_help_version" fail "-h must print the version and exit 1"
    fi

    # -v prints version and exits 0.
    run_script "$out" "$err" -- -v
    if (( LAST_RC == 0 )) && grep -qE 'v[0-9]+\.[0-9]+\.[0-9]+' "$out"; then
        report "cli_version" ok
    else
        report "cli_version" fail "-v must print the version and exit 0"
    fi

    local -a ERROR_CASES=(
        "cli_unknown_flag|--bogus"
        "cli_bad_source|--source /nonexistent --target $books"
        "cli_bad_target|--source $sk --target /nonexistent"
        "cli_target_inside_source|--source $sk --target $sk/sub"
        "cli_not_booksinput|--source $sk/f --target $books"
    )
    # Isolate the flag-less cases from the real machine: point the script's
    # environment fallbacks at guaranteed-missing paths so it must fail on
    # validation regardless of what exists under /mnt/c/Backup_Go7 (a stray
    # Empty_Skeleton once made an unreleased case exit 0 and run a real
    # finalize).  Explicit flags in the other cases override these env vars.
    for c in "${ERROR_CASES[@]}"; do
        IFS='|' read -r label args <<< "$c"
        MERGE_OUTPUT_DIR="$TMPDIR/no_such_root" \
        MERGE_TARGET_DIR="$TMPDIR/no_such_target" \
        MERGE_REPORT_DIR="$TMPDIR/cli_reports" \
            run_script "$out" "$err" -- $args
        if (( LAST_RC != 0 )); then
            report "$label" ok
        else
            report "$label" fail "expected non-zero exit"
        fi
    done

    # No source and no discovery root: must fail.
    run_script "$out" "$err" -- --output-root "$TMPDIR/no_such_root" --target "$books"
    if (( LAST_RC != 0 )); then
        report "cli_no_staging_found" ok
    else
        report "cli_no_staging_found" fail "expected non-zero exit when no BooksInput_* exists"
    fi
}

###############################################################################
# version header
###############################################################################
run_release_tests() {
    echo "== version header =="
    local v
    v="$(sed -n 's/^# Version:[[:space:]]*//p' "$SCRIPT" | head -n 1)"
    if [[ "$v" =~ ^0\.2\.[0-9]+$ ]]; then
        report "version_header" ok
    else
        report "version_header" fail "got '$v', expected ^0\\.2\\.[0-9]+$"
    fi
}

###############################################################################
# dispatch
###############################################################################
case "${1:-all}" in
    all)    run_dry_tests; run_full_tests; run_auto_detect_tests
            run_progress_tests; run_cli_tests; run_release_tests ;;
    dry)    run_dry_tests ;;
    full)   run_full_tests ;;
    auto)   run_auto_detect_tests ;;
    progress) run_progress_tests ;;
    cli)    run_cli_tests ;;
    release) run_release_tests ;;
    --list)
        echo "dry:         would-copy/would-keep report, nothing changed"
        echo "full:        rsync copy with --ignore-existing (destination wins)"
        echo "auto:        newest BooksInput_* auto-discovered"
        echo "progress:    pv -l filter strips header lines -> exact 100% tally"
        echo "cli:         usage errors, -h/-v, path-safety guards"
        echo "release:     0.2.x version header"
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
