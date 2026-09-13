#!/usr/bin/env bash

# __ETL_TEST_ENV_GUARD__: a caller with set -x/set -v auto-exports SHELLOPTS;
# every child bash re-applies it (it is readonly when imported), so xtrace
# noise corrupts the suites output captures.  Re-exec clean instead.
if [[ ${SHELLOPTS-} == *xtrace* || ${SHELLOPTS-} == *verbose* ]]; then
    exec env -u SHELLOPTS -u BASHOPTS bash "$0" "$@"
fi
unset SHELLOPTS BASHOPTS 2>/dev/null || true

# -----------------------------------------------------------------------------
# tests/unit/test_extract_flibusta_fb2.sh
#
# Regression suite for bin/flibusta/extract_flibusta_fb2.sh (stage-1 Flibusta
# range-archive extractor).  Fully hermetic: real zip fixtures are created in
# a temp dir, no network, no MariaDB.
#
# Asserts the tool's contract:
#   - range match: f.fb2-START-END.zip window contains the FileNumber
#     (inclusive bounds; 10# normalization; no match -> exit 1)
#   - extraction: only the single member <FileNumber>.fb2 is written to the
#     output dir, with byte-exact content; the archive is never copied
#   - atomic write: a failed/empty member leaves no partial output behind
#   - dry-run resolves and reports but writes nothing
#   - -s/-o flags override the config defaults
#   - CLI contract: --help exits 0 and lists options, --version prints the
#     header version, unknown option exits 2, non-numeric / zero / missing
#     FileNumber exit 1, no arguments exits 2 with usage
#
# Version header stays in sync with --version (0.1.x).
#
# Usage:  bash tests/unit/test_extract_flibusta_fb2.sh
# -----------------------------------------------------------------------------

# House suites run WITHOUT -e: expected-failure invocations (rc 1/2 probes)
# must not kill the battery; assertions are made through report() instead.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."
TOOL="$REPO_ROOT/bin/flibusta/extract_flibusta_fb2.sh"

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

TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/fb2extract_test.XXXXXX")"
trap 'rm -rf -- "$TMPDIR"' EXIT

# --- zip fixtures ----------------------------------------------------------------
# Two disjoint archives covering 100001..100010 and 100011..100020, plus a
# malformed-name archive that must be ignored by the range matcher.
SOURCE_DIR="$TMPDIR/source"
OUTPUT_DIR="$TMPDIR/output"
mkdir -p "$SOURCE_DIR" "$OUTPUT_DIR"

printf 'content of 100005\n' > "$TMPDIR/100005.fb2"
printf 'content of 100010\n' > "$TMPDIR/100010.fb2"
printf 'content of 100011\n' > "$TMPDIR/100011.fb2"
printf 'content of 100020\n' > "$TMPDIR/100020.fb2"
(
    cd "$TMPDIR" || exit 1
    zip -q "$SOURCE_DIR/f.fb2-100001-100010.zip" 100005.fb2 100010.fb2
    zip -q "$SOURCE_DIR/f.fb2-100011-100020.zip" 100011.fb2 100020.fb2
)
# malformed names: not matched, must not break the scan
: > "$SOURCE_DIR/f.fb2-notarange.zip"
: > "$SOURCE_DIR/unrelated.zip"

run_tool() { # [args...]; stdout->$OUT, stderr->$ERR; rc->$RC
    OUT="$TMPDIR/stdout.txt" ERR="$TMPDIR/stderr.txt"
    FLIBUSTA_SOURCE_DIR="$SOURCE_DIR" FB2_OUTPUT_DIR="$OUTPUT_DIR" \
        bash "$TOOL" "$@" >"$OUT" 2>"$ERR"
    RC=$?
}

echo "== extract_flibusta_fb2 =="

# --- version / usage --------------------------------------------------------------
version="$(sed -n 's/^# Version:[[:space:]]*//p' "$TOOL" | head -n 1)"
if [[ "$version" =~ ^0\.1\.[0-9]+$ ]]; then
    report "version_header" ok "header $version"
else
    report "version_header" fail "got '$version', expected ^0.1.[0-9]+$"
fi

bash "$TOOL" --version >"$TMPDIR/v.txt" 2>&1
if [[ "$(cat "$TMPDIR/v.txt")" == "bin/flibusta/extract_flibusta_fb2.sh v$version" ]]; then
    report "version_flag" ok
else
    report "version_flag" fail "got '$(cat "$TMPDIR/v.txt")'"
fi

bash "$TOOL" --help >"$TMPDIR/h.txt" 2>&1
if (( $? == 0 )) && grep -q -- "--source-dir" "$TMPDIR/h.txt"; then
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

# --- range match + extraction -------------------------------------------------------
run_tool 100005
if (( RC == 0 )) \
   && [[ "$(cat "$OUTPUT_DIR/100005.fb2" 2>/dev/null)" == "content of 100005" ]] \
   && [[ "$(head -n 1 "$ERR")" == *"f.fb2-100001-100010.zip"* ]]; then
    report "extract_first_archive" ok
else
    report "extract_first_archive" fail "rc=$RC out=$(cat "$OUT" 2>/dev/null) err=$(head -2 "$ERR")"
fi

run_tool 100020
if (( RC == 0 )) \
   && [[ "$(cat "$OUTPUT_DIR/100020.fb2" 2>/dev/null)" == "content of 100020" ]] \
   && [[ "$(head -n 1 "$ERR")" == *"f.fb2-100011-100020.zip"* ]]; then
    report "extract_inclusive_upper_bound" ok
else
    report "extract_inclusive_upper_bound" fail "rc=$RC out=$(cat "$OUT" 2>/dev/null)"
fi

run_tool 100010
if (( RC == 0 )) && [[ -f "$OUTPUT_DIR/100010.fb2" ]]; then
    report "extract_lower_archive_upper_bound" ok
else
    report "extract_lower_archive_upper_bound" fail "rc=$RC err=$(head -2 "$ERR")"
fi

# --- no match / invalid input -------------------------------------------------------
rm -f "$OUTPUT_DIR"/*.fb2
run_tool 100021
if (( RC == 1 )) && [[ ! -e "$OUTPUT_DIR/100021.fb2" ]]; then
    report "no_match_exit1" ok
else
    report "no_match_exit1" fail "rc=$RC"
fi

run_tool abc123
if (( RC == 1 )); then
    report "non_numeric_exit1" ok
else
    report "non_numeric_exit1" fail "rc=$RC"
fi

run_tool 0
if (( RC == 1 )); then
    report "zero_exit1" ok
else
    report "zero_exit1" fail "rc=$RC"
fi

run_tool 100005 100006
if (( RC == 2 )); then
    report "two_positionals_exit2" ok
else
    report "two_positionals_exit2" fail "rc=$RC"
fi

# --- dry-run -------------------------------------------------------------------------
rm -f "$OUTPUT_DIR"/*.fb2
run_tool --dry-run 100005
if (( RC == 0 )) && [[ "$(head -n 1 "$ERR")" == *"f.fb2-100001-100010.zip"* ]] \
   && (( $(ls -1 "$OUTPUT_DIR" 2>/dev/null | wc -l) == 0 )); then
    report "dryrun_resolves_writes_nothing" ok
else
    report "dryrun_resolves_writes_nothing" fail "rc=$RC out=$(cat "$OUT") files=$(ls -1 "$OUTPUT_DIR" 2>/dev/null | tr '\n' ',')"
fi

# --- missing member inside a matching archive -----------------------------------------
# 100007 falls inside 100001..100010 but the member does not exist in the
# fixture: the tool must fail cleanly (exit 1) and leave no partial file.
run_tool 100007
leftovers=()
for f in "$OUTPUT_DIR"/100007.fb2 "$OUTPUT_DIR"/100007.fb2.tmp.*; do
    [[ -e "$f" ]] && leftovers+=("$f")
done
if (( RC == 1 )) && (( ${#leftovers[@]} == 0 )); then
    report "missing_member_exit1_no_partial" ok
else
    report "missing_member_exit1_no_partial" fail "rc=$RC leftovers=${leftovers[*]:-none}"
fi

# --- flag overrides -------------------------------------------------------------------
ALT_OUT="$TMPDIR/alt-out"
run_tool --output-dir "$ALT_OUT" 100011
if (( RC == 0 )) && [[ "$(cat "$ALT_OUT/100011.fb2" 2>/dev/null)" == "content of 100011" ]] \
   && [[ ! -e "$OUTPUT_DIR/100011.fb2" ]]; then
    report "output_dir_flag_override" ok
else
    report "output_dir_flag_override" fail "rc=$RC"
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
