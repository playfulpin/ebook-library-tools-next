#!/usr/bin/env bash

# __ETL_TEST_ENV_GUARD__: a caller with set -x/set -v auto-exports SHELLOPTS;
# every child bash re-applies it (it is readonly when imported), so xtrace
# noise corrupts the suites output captures.  Re-exec clean instead.
if [[ ${SHELLOPTS-} == *xtrace* || ${SHELLOPTS-} == *verbose* ]]; then
    exec env -u SHELLOPTS -u BASHOPTS bash "$0" "$@"
fi
unset SHELLOPTS BASHOPTS 2>/dev/null || true


###############################################################################
# tests/test_authors_prefix_tree.sh
#
# Regression suite for bin/authors/authors_prefix_tree.sh, the toolchain's prefix-tree
# renderer.  It consumes a prefix table (prefix<TAB>count<TAB>start<TAB>end,
# as produced by bin/authors/authors_prefix_build.sh) and draws the hierarchical tree.
#
# Coverage:
#   * GOLDEN FILES -- the rendered tree must be byte-identical to a stored
#     golden for the full output, a --filter Cyrillic run, and a --depth 2
#     run.  Run with --regen to refresh the goldens from current output.
#   * DESCENT REGRESSION -- the mini fixture has punctuation roots (`"`, `(`)
#     and a Cyrillic branch; the tree must descend through EVERY level.  The
#     historical utf8_chop returned the reversed tail instead of the parent
#     prefix, so children were attached to nonexistent parents and the tree
#     stopped at the roots -- this check locks the fix in.
#   * FILTERS -- --filter Symbols shows only the Symbols section,
#     --filter Cyrillic only the Cyrillic section.
#   * DEPTH -- --depth N truncates the tree at depth N.
#   * CLI -- a missing/nonexistent table prints usage with the version and
#     exits 1.
#   * VERSION HEADER -- the script at the repository root is the released
#     artifact, and its header must carry the 2.8.x ladder.
#
# Usage:
#   bash test_bin/authors/authors_prefix_tree.sh          # check against goldens
#   bash test_bin/authors/authors_prefix_tree.sh --regen  # rewrite golden files
#   bash test_bin/authors/authors_prefix_tree.sh --list   # list the check groups
#   bash test_bin/authors/authors_prefix_tree.sh golden   # run one group only
#
# IMPORTANT: the renderer needs gawk for its Unicode tree logic.  Run from
# WSL (the suite's fixtures contain UTF-8 and multi-byte prefixes).
#
# Exit status: 0 if every check passed, 1 otherwise.
###############################################################################

set -euo pipefail

MODE="check"
if [[ "${1:-}" == "--regen" ]]; then
    MODE="regen"
    shift
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../bin/authors/authors_prefix_tree.sh"
# The suite lives in tests/ together with its fixtures and goldens.
TESTS_DIR="$SCRIPT_DIR"
GOLDEN_DIR="$TESTS_DIR/golden"

[[ -f "$SCRIPT" ]] || { echo "ERROR: $SCRIPT not found" >&2; exit 2; }
if ! command -v gawk >/dev/null 2>&1; then
    echo "ERROR: gawk not found (the renderer requires it)." >&2
    echo "Run from WSL:  wsl.exe bash \"$0\"" >&2
    exit 2
fi
mkdir -p "$GOLDEN_DIR"

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

# --- run the visualizer, capture stdout+stderr --------------------------------
viz() { # <outfile> <args...>
    local outfile="$1"
    shift
    set +e
    bash "$SCRIPT" "$@" > "$outfile" 2>&1
    LAST_RC=$?
    set -e
}

###############################################################################
# golden: byte-identical rendered trees vs stored goldens
###############################################################################
run_golden_tests() {
    echo "== golden files =="
    local out="$TMPDIR/viz_out.txt"

    # fixture | args... | golden name
    local -a CASES=(
        "viz_mini.txt||viz_mini_full.txt"
        "viz_spaces.txt||viz_spaces_full.txt"
        "viz_spaces.txt|--filter Cyrillic|viz_spaces_cyrillic.txt"
        "viz_spaces.txt|--depth 2|viz_spaces_depth2.txt"
    )

    for c in "${CASES[@]}"; do
        IFS='|' read -r fixture extra_args golden <<< "$c"
        label="${golden%.txt}"

        # shellcheck disable=SC2086  # extra_args carries intentional spaces
        viz "$out" "$TESTS_DIR/$fixture" $extra_args
        if (( LAST_RC != 0 )); then
            report "$label" fail "exit code $LAST_RC"
            continue
        fi

        if [[ "$MODE" == "regen" ]]; then
            cp "$out" "$GOLDEN_DIR/$golden"
            report "$label" ok "(golden regenerated)"
            continue
        fi

        if diff -q "$out" "$GOLDEN_DIR/$golden" >/dev/null 2>&1; then
            report "$label" ok
        else
            report "$label" fail "output differs from $golden"
        fi
    done
}

###############################################################################
# regression: the tree descends through every level (utf8_chop fix)
###############################################################################
run_regression_tests() {
    echo "== descent regression =="
    local out="$TMPDIR/viz_regress.txt"

    viz "$out" "$TESTS_DIR/viz_mini.txt"

    # Punctuation root " must descend five levels: " -> "Ж -> "Жу -> "Жур -> "Журн
    if (( LAST_RC == 0 )) \
       && grep -q '│   └── "Ж ' "$out" \
       && grep -q '│       └── "Жу ' "$out" \
       && grep -q '│           └── "Жур ' "$out" \
       && grep -q '│               └── "Журн ' "$out"; then
        report "quote_branch_descends" ok
    else
        report "quote_branch_descends" fail '" branch must reach "Журн'
    fi

    # Cyrillic branch must descend three levels: А -> Аб -> Абв/Абг
    if (( LAST_RC == 0 )) \
       && grep -q '└── Аб ' "$out" \
       && grep -q '├── Абв ' "$out" \
       && grep -q '└── Абг ' "$out"; then
        report "cyrillic_branch_descends" ok
    else
        report "cyrillic_branch_descends" fail 'А branch must reach Абв/Абг'
    fi
}

###############################################################################
# filters and depth
###############################################################################
run_filter_tests() {
    echo "== filters =="
    local out="$TMPDIR/viz_filter.txt"

    # viz_mini has both a punctuation root and a Cyrillic root, so the filter
    # must isolate one section while hiding the other.
    viz "$out" "$TESTS_DIR/viz_mini.txt" --filter Symbols
    if (( LAST_RC == 0 )) \
       && grep -q '^Symbols$' "$out" \
       && grep -q '└── "Ж ' "$out" \
       && ! grep -q '^Cyrillic$' "$out"; then
        report "filter_symbols_only" ok
    else
        report "filter_symbols_only" fail "Symbols filter leaked other sections"
    fi

    viz "$out" "$TESTS_DIR/viz_mini.txt" --filter Cyrillic
    if (( LAST_RC == 0 )) \
       && grep -q '^Cyrillic$' "$out" \
       && grep -q '└── Аб ' "$out" \
       && ! grep -q '^Symbols$' "$out"; then
        report "filter_cyrillic_only" ok
    else
        report "filter_cyrillic_only" fail "Cyrillic filter leaked other sections"
    fi
}

run_depth_tests() {
    echo "== depth =="
    local out="$TMPDIR/viz_depth.txt"

    # Roots count as depth 1, so --depth 2 shows the root and ONE level of
    # children (" and "Ж) but must stop before "Жу.
    viz "$out" "$TESTS_DIR/viz_mini.txt" --depth 2
    if (( LAST_RC == 0 )) \
       && grep -q '└── "Ж ' "$out" \
       && ! grep -q '└── "Жу ' "$out"; then
        report "depth_2_truncates" ok
    else
        report "depth_2_truncates" fail "depth 2 must stop below \"Ж"
    fi
}

###############################################################################
# cli: usage errors and version
###############################################################################
run_cli_tests() {
    echo "== CLI =="
    local out="$TMPDIR/viz_cli.txt"

    viz "$out"
    if (( LAST_RC != 0 )) && grep -qE 'authors_prefix_tree\.sh v[0-9]+\.[0-9]+\.[0-9]+' "$out"; then
        report "cli_no_table_usage" ok
    else
        report "cli_no_table_usage" fail "missing table must print usage with version and exit 1"
    fi

    viz "$out" /nonexistent.txt
    if (( LAST_RC != 0 )) && grep -q 'Usage:' "$out"; then
        report "cli_missing_file" ok
    else
        report "cli_missing_file" fail "nonexistent table must print usage and exit 1"
    fi
}

###############################################################################
# version header
###############################################################################
run_release_tests() {
    echo "== version header =="

    # The script at the repository root is the released artifact; its header
    # must carry the shared 2.8.x semver ladder.
    version="$(sed -n 's/^# Version:[[:space:]]*//p' "$SCRIPT" | head -n 1)"
    if [[ "$version" =~ ^2\.8\.[0-9]+$ ]]; then
        report "version_authors_prefix_tree" ok
    else
        report "version_authors_prefix_tree" fail "got '$version', expected ^2\\.8\\.[0-9]+$"
    fi
}

###############################################################################
# dispatch
###############################################################################
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

case "${1:-all}" in
    all)       run_golden_tests; run_regression_tests; run_filter_tests
               run_depth_tests; run_cli_tests; run_release_tests ;;
    golden)    run_golden_tests ;;
    regression) run_regression_tests ;;
    filter)    run_filter_tests ;;
    depth)     run_depth_tests ;;
    cli)       run_cli_tests ;;
    release)   run_release_tests ;;
    --list)
        echo "golden:     viz_mini_full, viz_spaces_full, viz_spaces_cyrillic, viz_spaces_depth2"
        echo "regression: quote + Cyrillic branches descend through every level"
        echo "filter:     --filter Symbols / Cyrillic isolate their sections"
        echo "depth:      --depth 2 truncates the tree"
        echo "cli:        missing table prints usage + version, exits 1"
        echo "release:    2.8.x version header"
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
