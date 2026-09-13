#!/usr/bin/env bash

# __ETL_TEST_ENV_GUARD__: a caller with set -x/set -v auto-exports SHELLOPTS;
# every child bash re-applies it (it is readonly when imported), so xtrace
# noise corrupts the suites output captures.  Re-exec clean instead.
if [[ ${SHELLOPTS-} == *xtrace* || ${SHELLOPTS-} == *verbose* ]]; then
    exec env -u SHELLOPTS -u BASHOPTS bash "$0" "$@"
fi
unset SHELLOPTS BASHOPTS 2>/dev/null || true


###############################################################################
# tests/test_e2e_pipeline.sh
#
# End-to-end regression suite for the toolchain's three-stage pipeline run on
# the REAL author list (data/fixtures/authors_list_from_db.txt, regenerated
# from the MariaDB catalog by bin/authors/authors_export.sh):
#
#     bin/authors/authors_prefix_build.sh  ->  bin/authors/authors_prefix_check.sh  ->  bin/authors/authors_prefix_tree.sh
#     (generate)                  (validate)                    (render)
#
# The per-tool suites test each script in isolation against hand-written
# fixtures.  This suite proves the REAL chain: the generator's output is
# consumable, unchanged, by the validator (which must report 0 criticals) and
# by the renderer (which must draw a multi-level tree whose counts match the
# generated table).  Cross-tool format drift -- the failure mode no single
# suite can see -- is exactly what this test locks out.
#
# Coverage:
#   * STAGE 1 (generate) -- bin/authors/authors_prefix_build.sh on the real list exits 0,
#     emits a non-empty table, and the table is in strict byte order (the
#     exact property the historical AWK table violated with 6,483 warnings).
#   * STAGE 2 (validate) -- bin/authors/authors_prefix_check.sh accepts the generated
#     table with exit 0, reports "0 critical", and checked the same row count
#     the generator emitted.
#   * STAGE 3 (render)  -- bin/authors/authors_prefix_tree.sh accepts the generated
#     table with exit 0, prints the tree header and category sections, and
#     descends at least three levels (the utf8_chop regression: a broken
#     parent-prefix helper leaves every child under a nonexistent parent and
#     the tree never descends).
#   * CROSS-STAGE -- a concrete prefix's count is carried intact from the
#     generated table into the rendered tree, proving both scripts agree on
#     the table's column layout.
#
# Usage:
#   bash tests/test_e2e_pipeline.sh
#
# IMPORTANT: every stage slices UTF-8 prefixes character by character, so the
# shell must have multi-byte support.  Cygwin/MSYS bash does not; run from
# WSL instead:
#   wsl.exe bash tests/test_e2e_pipeline.sh
#
# Exit status: 0 if every check passed, 1 otherwise; 2 if the environment is
# unusable.  Skips (exit 0) if a hard prerequisite file/tool is absent, so a
# bare checkout without the real author list or the validator stays green.
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATOR="$SCRIPT_DIR/../../bin/authors/authors_prefix_build.sh"
VALIDATOR="$SCRIPT_DIR/../../bin/authors/authors_prefix_check.sh"
VISUALIZER="$SCRIPT_DIR/../../bin/authors/authors_prefix_tree.sh"
REAL_LIST="$SCRIPT_DIR/../../data/fixtures/authors_list_from_db.txt"

# --- environment sanity -------------------------------------------------------
# The scripts slice UTF-8 by character; this probe fails on byte-based shells
# such as cygwin's bash.
probe='абв'
if [[ "${probe:0:1}" != 'а' ]]; then
    echo "ERROR: this shell slices multi-byte characters by byte." >&2
    echo "Run from WSL instead:  wsl.exe bash \"$0\"" >&2
    exit 2
fi

for f in "$GENERATOR" "$VISUALIZER"; do
    [[ -f "$f" ]] || { echo "ERROR: $f not found" >&2; exit 2; }
done

# Hard prerequisites that may be absent from a bare checkout: skip rather than
# fail, matching the per-tool suites' integration groups.
if [[ ! -f "$REAL_LIST" ]]; then
    echo "SKIP  (data/fixtures/authors_list_from_db.txt not found)"
    exit 0
fi
if [[ ! -f "$VALIDATOR" ]]; then
    echo "SKIP  (bin/authors/authors_prefix_check.sh not found)"
    exit 0
fi
if ! command -v gawk >/dev/null 2>&1; then
    echo "SKIP  (gawk not found; the renderer requires it)"
    exit 0
fi

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

###############################################################################
# STAGE 1: generate
###############################################################################
echo "== stage 1: generate (bin/authors/authors_prefix_build.sh) =="
TABLE="$TMPDIR/table.txt"

set +e
bash "$GENERATOR" "$REAL_LIST" 5 > "$TABLE" 2> "$TMPDIR/gen_err.txt"
rc=$?
set -e

if (( rc == 0 )); then
    report "generate_exits_0" ok
else
    report "generate_exits_0" fail "exit code $rc"
fi

if [[ -s "$TABLE" ]]; then
    report "generate_nonempty" ok
else
    report "generate_nonempty" fail "generated table is empty"
fi

# Byte order is the generator's core contract (LC_ALL=C, pre-order trie walk).
# The historical AWK table carried 6,483 byte-order warnings; zero is required.
# gawk types numeric-looking prefixes as numbers ("100" vs "100 "), so the
# comparison is forced back to bytes with a "" concatenation.
n=$(LC_ALL=C awk -F '\t' 'NR>1 && (prev "") >= ($1 "") {bad++} {prev=$1} END{print bad+0}' "$TABLE")
if (( n == 0 )); then
    report "generate_byte_order" ok
else
    report "generate_byte_order" fail "$n byte-order violations"
fi

###############################################################################
# STAGE 2: validate
###############################################################################
echo "== stage 2: validate (bin/authors/authors_prefix_check.sh) =="

set +e
bash "$VALIDATOR" -t "$TABLE" -x 5 > "$TMPDIR/validate.txt" 2>&1
rc=$?
set -e

if (( rc == 0 )); then
    report "validate_exits_0" ok
else
    report "validate_exits_0" fail "exit code $rc"
fi

# Anchored on ': 0 critical,' so a count like 10 is never mistaken for 0.
if grep -q ': 0 critical,' "$TMPDIR/validate.txt"; then
    report "validate_zero_critical" ok
else
    report "validate_zero_critical" fail "summary does not report 0 criticals"
fi

# The validator must have checked exactly the rows the generator emitted.
table_rows=$(awk 'END{print NR}' "$TABLE")
checked=$(sed -nE 's/^Checked ([0-9]+) rows:.*/\1/p' "$TMPDIR/validate.txt" | head -n 1)
if [[ -n "$checked" && "$checked" == "$table_rows" ]]; then
    report "validate_row_count_matches" ok
else
    report "validate_row_count_matches" fail "validator checked '$checked' rows, table has '$table_rows'"
fi

###############################################################################
# STAGE 3: render
###############################################################################
echo "== stage 3: render (bin/authors/authors_prefix_tree.sh) =="

set +e
bash "$VISUALIZER" "$TABLE" > "$TMPDIR/render.txt" 2>&1
rc=$?
set -e

if (( rc == 0 )); then
    report "render_exits_0" ok
else
    report "render_exits_0" fail "exit code $rc"
fi

if grep -q '^Prefix Tree Visualization$' "$TMPDIR/render.txt"; then
    report "render_header" ok
else
    report "render_header" fail "missing tree header"
fi

if grep -q '^Cyrillic$' "$TMPDIR/render.txt"; then
    report "render_has_category_sections" ok
else
    report "render_has_category_sections" fail "missing Cyrillic category section"
fi

# The tree must descend at least three levels.  The historical utf8_chop bug
# attached every child to a nonexistent parent, so no branch continuation ever
# printed below a root.  Two indent units (each '│   ' or '    ', i.e. four
# columns) precede a depth-3 branch line.
if grep -qE '^(│   |    ){2,}(├── |└── )' "$TMPDIR/render.txt"; then
    report "render_descends" ok
else
    report "render_descends" fail "no branch reached depth 3 (tree stopped at roots?)"
fi

###############################################################################
# CROSS-STAGE: the count survives generator -> renderer intact
###############################################################################
echo "== cross-stage =="

# Pick a concrete prefix from the generated table and confirm the renderer
# shows the identical count for it.
prefix="А"
count=$(awk -F '\t' -v p="$prefix" '$1 == p {print $2; exit}' "$TABLE")
if [[ -n "$count" ]] && grep -qF "$prefix (count: $count, " "$TMPDIR/render.txt"; then
    report "count_consistent_across_stages" ok
else
    report "count_consistent_across_stages" fail "prefix '$prefix' count '$count' not rendered intact"
fi

###############################################################################
# summary
###############################################################################
echo ""
echo "=============================="
echo "PASS: $PASS_COUNT   FAIL: $FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then
    printf '  %s\n' "${FAILURE_LINES[@]}"
    exit 1
fi
echo "All tests passed."
