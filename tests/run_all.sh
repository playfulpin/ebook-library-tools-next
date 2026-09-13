#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# tests/run_all.sh
#
# Run the whole test battery in the canonical order: unit -> integration -> e2e.
#
# Replaces the old flat-directory loop
#     for t in tests/test_*.sh; do bash "$t"; done
# which no longer matches anything now that suites are grouped.
#
# Usage:
#   tests/run_all.sh              # run everything (unit, integration, e2e)
#   tests/run_all.sh unit         # one group only: unit | integration | e2e
#   tests/run_all.sh unit e2e     # several groups, in the given order
#   tests/run_all.sh -q           # quiet per-suite output (summary only)
#
# Exit codes:
#   0  every selected suite passed
#   1  at least one suite failed
#   2  usage error (unknown group)
# -----------------------------------------------------------------------------

set -u

# Same caller-shell guard as the suites: a traced caller (set -x / set -v)
# pollutes every child capture through the auto-exported SHELLOPTS.
if [[ ${SHELLOPTS-} == *xtrace* || ${SHELLOPTS-} == *verbose* ]]; then
    exec env -u SHELLOPTS -u BASHOPTS bash "$0" "$@"
fi
unset SHELLOPTS BASHOPTS 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ALL_GROUPS="unit integration e2e"
QUIET=0
SELECTED=""

usage() {
    cat <<USAGE
Usage: tests/run_all.sh [-q] [group ...]

Groups: unit, integration, e2e (default: all three, in that order)

Options:
  -q   quiet: print one line per suite, suppress suite stdout/stderr
  -h   show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -q|--quiet) QUIET=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        unit|integration|e2e) SELECTED="$SELECTED $1"; shift ;;
        *)
            echo "run_all: unknown group '$1'" >&2
            usage >&2
            exit 2
            ;;
    esac
done
# NB: deliberately not named GROUPS — that is a special bash variable
# (the user's group IDs) whose assignment is silently discarded.
SELECTED="${SELECTED:-$ALL_GROUPS}"

PASS=0
FAIL=0
declare -a FAILED=()

for group in $SELECTED; do
    group_dir="$SCRIPT_DIR/$group"
    if [[ ! -d "$group_dir" ]]; then
        echo "run_all: missing group directory $group_dir" >&2
        exit 2
    fi
    echo "=== $group ==="
    for suite in "$group_dir"/test_*.sh; do
        # A group with no suites leaves the glob literal; skip it.
        [[ -f "$suite" ]] || continue
        rel="tests/$group/$(basename "$suite")"
        if [[ "$QUIET" -eq 1 ]]; then
            if bash "$suite" >/dev/null 2>&1; then
                echo "ok   $rel"
                PASS=$((PASS + 1))
            else
                echo "FAIL $rel"
                FAILED+=("$rel")
                FAIL=$((FAIL + 1))
            fi
        else
            echo "--- $rel"
            if bash "$suite"; then
                PASS=$((PASS + 1))
            else
                FAILED+=("$rel")
                FAIL=$((FAIL + 1))
            fi
        fi
    done
done

echo "run_all: $PASS suite(s) passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    for suite in "${FAILED[@]}"; do
        echo "  failed: $suite"
    done
    exit 1
fi
exit 0
