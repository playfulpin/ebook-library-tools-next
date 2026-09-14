#!/usr/bin/env bash

# __ETL_TEST_ENV_GUARD__: a caller with set -x/set -v auto-exports SHELLOPTS;
# every child bash re-applies it (it is readonly when imported), so xtrace
# noise corrupts the suites output captures.  Re-exec clean instead.
if [[ ${SHELLOPTS-} == *xtrace* || ${SHELLOPTS-} == *verbose* ]]; then
    exec env -u SHELLOPTS -u BASHOPTS bash "$0" "$@"
fi
unset SHELLOPTS BASHOPTS 2>/dev/null || true

# -----------------------------------------------------------------------------
# tests/unit/test_run_round.sh
#
# Regression suite for bin/flibusta/run_round.sh - the single-process round
# orchestrator.  Fully hermetic: a mock `mysql` (via MYSQL_CLIENT) serves a
# fixture catalog, the range archives are real zip fixtures, and the round
# is driven through the tool's CLI (the tool sources both stage libraries
# internally - that composition is itself under test).
#
# Fixture catalog (inside the mock):
#   filename 100031 -> bookid 31, author "Круглов Лев", no series
#   filename 100032 -> bookid 32, author "Круглов Лев", series "Колесо" #3
#   100039 absent from the catalog (place-stage failure path)
#
# Asserts:
#   - full round: extract -> place -> zip appears under
#     ROOT_LOAD/<Author>/[<Series>/]<title>.zip; source member trashed
#   - round report: one row per number, statuses placed/failed-stage2
#   - failed-stage1: a sparse number (in range, absent member) reports
#     failed-stage1, stage 2 never sees it, exit 1
#   - catalog-miss number: extracted by stage 1, failed-stage2 in the report
#   - --extract-only: placement skipped, status extracted, no zips
#   - --dry-run: no files written, would-place rows
#   - CLI: --help exit 0, --version line, unknown option 2, no args 2
#
# Version header stays in sync with --version (0.1.x).
#
# Usage:  bash tests/unit/test_run_round.sh
# -----------------------------------------------------------------------------

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."
TOOL="$REPO_ROOT/bin/flibusta/run_round.sh"

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

TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/runround_test.XXXXXX")"
trap 'rm -rf -- "$TMPDIR"' EXIT

# --- mock mysql (catalog serving; mirrors the place suite's fixture) -----------------
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
serve_row() {
    local fn="\$1"
    case "\$fn" in
        100031) printf '31\tКолесо фортуны\tКруглов Лев\t\t\n' ;;
        100032) printf '32\tТень недруга\tКруглов Лев\tКолесо\t3\n' ;;
        *)      return 0 ;;
    esac
}
# place_lookup: filename = N (bare, fb2) or LIKE N.%  (the sed mirrors the
# place suite's proven extraction: anchor on 'WHERE b.filename = ')
if [[ "\$sql" == *"FROM mlbook b"* ]]; then
    n="\$(printf '%s' "\$sql" | sed -n "s/.*WHERE b\\.filename *= *'\\([0-9]*\\)'.*/\\1/p")"
    serve_row "\$n"
    exit 0
fi
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/mysql"

# --- zip fixtures: two fb2 archives, one sparse member --------------------------------
SOURCE_DIR="$TMPDIR/archives"
OUT_DIR="$TMPDIR/toload"
REPORT_DIR="$TMPDIR/reports"
mkdir -p "$SOURCE_DIR" "$OUT_DIR" "$REPORT_DIR"
STAGE="$TMPDIR/stage"; mkdir -p "$STAGE"
printf 'fb2 payload of 100031\n' > "$STAGE/100031.fb2"
printf 'fb2 payload of 100032\n' > "$STAGE/100032.fb2"
printf 'fb2 payload of 100035\n' > "$STAGE/100035.fb2"
(cd "$STAGE" && zip -q "$SOURCE_DIR/f.fb2-100031-100040.zip" 100031.fb2 100032.fb2 100035.fb2)
rm -rf "$STAGE"

run_tool() { # [args...]; stdout->$OUT, stderr->$ERR; rc->$RC
    OUT="$TMPDIR/stdout.txt" ERR="$TMPDIR/stderr.txt"
    : > "$MOCK_LOG"
    MYSQL_CLIENT="$MOCK_BIN/mysql" FLIBUSTA_DB=flibusta \
    FLIBUSTA_SOURCE_DIR="$SOURCE_DIR" FB2_OUTPUT_DIR="$OUT_DIR" \
    PLACE_INPUT_DIR="$OUT_DIR" ROOT_LOAD="$OUT_DIR" \
    PLACE_REPORT_DIR="$REPORT_DIR" ROUND_REPORT_DIR="$REPORT_DIR" \
    MARIA_TASKLIST="$TMPDIR/no-such-tasklist" \
        bash "$TOOL" "$@" >"$OUT" 2>"$ERR"
    RC=$?
}

clean_dirs() { rm -rf "$OUT_DIR"/* "$REPORT_DIR"/* 2>/dev/null; mkdir -p "$OUT_DIR" "$REPORT_DIR"; }

echo "== run_round =="

# --- version / usage -------------------------------------------------------------------
version="$(sed -n 's/^# Version:[[:space:]]*//p' "$TOOL" | head -n 1)"
if [[ "$version" =~ ^0\.1\.[0-9]+$ ]]; then
    report "version_header" ok "header $version"
else
    report "version_header" fail "got '$version', expected ^0.1.[0-9]+$"
fi

bash "$TOOL" --version >"$TMPDIR/v.txt" 2>&1
if [[ "$(cat "$TMPDIR/v.txt")" == "bin/flibusta/run_round.sh v$version" ]]; then
    report "version_flag" ok
else
    report "version_flag" fail "got '$(cat "$TMPDIR/v.txt")'"
fi

bash "$TOOL" --help >"$TMPDIR/h.txt" 2>&1
hrc=$?
if (( hrc == 0 )) && grep -q -- "--extract-only" "$TMPDIR/h.txt" && grep -q -- "--report-dir" "$TMPDIR/h.txt"; then
    report "help_exit0" ok
else
    report "help_exit0" fail "rc=$hrc"
fi

bash "$TOOL" --bogus >"$TMPDIR/u.txt" 2>&1
if (( $? == 2 )); then
    report "unknown_option_exit2" ok
else
    report "unknown_option_exit2" fail "expected exit 2"
fi

bash "$TOOL" >"$TMPDIR/n.txt" 2>&1
if (( $? == 2 )); then
    report "no_args_exit2" ok
else
    report "no_args_exit2" fail "expected exit 2"
fi

# --- full round: extract + place ---------------------------------------------------------
clean_dirs
run_tool --type fb2 100031 100032
last_report="$(ls -1t "$REPORT_DIR"/run_round_*.tsv 2>/dev/null | head -1)"
row31="$(awk -F'\t' '$2==100031' "$last_report" 2>/dev/null | tail -1)"
row32="$(awk -F'\t' '$2==100032' "$last_report" 2>/dev/null | tail -1)"
zip31="$OUT_DIR/Круглов Лев/Колесо фортуны.zip"
zip32="$OUT_DIR/Круглов Лев/Колесо/03 - Тень недруга.zip"
if (( RC == 0 )) && [[ -s "$zip31" ]] && [[ -s "$zip32" ]] \
   && [[ "$row31" == *$'\t'placed$'\t'* ]] && [[ "$row32" == *$'\t'placed$'\t'* ]]; then
    report "full_round_places" ok "2 zips placed (flat + series)"
else
    report "full_round_places" fail "rc=$RC zip31=$([[ -s "$zip31" ]] && echo yes || echo NO) zip32=$([[ -s "$zip32" ]] && echo yes || echo NO) err=$(tail -2 "$ERR" | tr '\n' ';')"
fi

# round-trip: the placed zip holds the stage-1 payload
if unzip -p "$zip31" 2>/dev/null | grep -q "fb2 payload of 100031"; then
    report "placed_zip_roundtrip" ok
else
    report "placed_zip_roundtrip" fail "content mismatch in $zip31"
fi

# source member was trashed by stage 2 (default)
if [[ ! -e "$OUT_DIR/100031.fb2" ]]; then
    report "source_trashed_after_place" ok
else
    report "source_trashed_after_place" fail "$(ls "$OUT_DIR" | tr '\n' ' ')"
fi

# report statuses use the joined vocabulary
if grep -q "status" "$last_report" && grep -qE "placed" "$last_report"; then
    report "report_header_and_rows" ok
else
    report "report_header_and_rows" fail "report: $(head -2 "$last_report" | tr '\n' ';')"
fi

# --- sparse number: failed-stage1, stage 2 never sees it ------------------------------------
clean_dirs
# 100033 sits inside the f.fb2-100031-100040 window but the archive holds no
# such member (sparse), and it is not in the catalog either: stage 1 must
# fail it BEFORE stage 2 ever looks it up.
run_tool --type fb2 100033 100031 2>/dev/null
last_report="$(ls -1t "$REPORT_DIR"/run_round_*.tsv 2>/dev/null | head -1)"
row33="$(awk -F'\t' '$2==100033' "$last_report" 2>/dev/null | tail -1)"
if (( RC == 1 )) && [[ "$row33" == *$'\t'failed-stage1$'\t'* ]]; then
    report "sparse_number_failed_stage1" ok
else
    report "sparse_number_failed_stage1" fail "rc=$RC row=$row33"
fi

# --- catalog miss: stage 1 delivers, stage 2 fails -------------------------------------------
clean_dirs
run_tool --type fb2 100039 2>/dev/null          # member absent too; use 100035 variant
# 100039 is absent from the ARCHIVE as well; the catalog-miss path needs an
# extractable number with no catalog row: patch the archive on the fly.
run_tool --type fb2 --help >/dev/null 2>&1
clean_dirs
STAGE="$TMPDIR/stage2"; mkdir -p "$STAGE"
printf 'fb2 payload of 100036\n' > "$STAGE/100036.fb2"
(cd "$STAGE" && zip -q "$SOURCE_DIR/f.fb2-100031-100040.zip" 100036.fb2)
rm -rf "$STAGE"
run_tool --type fb2 100036 2>/dev/null          # extractable, not in catalog
last_report="$(ls -1t "$REPORT_DIR"/run_round_*.tsv 2>/dev/null | head -1)"
row36="$(awk -F'\t' '$2==100036' "$last_report" 2>/dev/null | tail -1)"
if (( RC == 1 )) && [[ "$row36" == *$'\t'failed-stage2$'\t'* ]]; then
    report "catalog_miss_failed_stage2" ok
else
    report "catalog_miss_failed_stage2" fail "rc=$RC row=$row36"
fi

# --- --extract-only ---------------------------------------------------------------------------
clean_dirs
run_tool --type fb2 --extract-only 100031 100032
last_report="$(ls -1t "$REPORT_DIR"/run_round_*.tsv 2>/dev/null | head -1)"
row31="$(awk -F'\t' '$2==100031' "$last_report" 2>/dev/null | tail -1)"
if (( RC == 0 )) && [[ -s "$OUT_DIR/100031.fb2" ]] && [[ "$row31" == *$'\t'extracted$'\t'* ]] \
   && (( $(find "$OUT_DIR" -name "*.zip" | wc -l) == 0 )); then
    report "extract_only" ok
else
    report "extract_only" fail "rc=$RC row=$row31 zips=$(find "$OUT_DIR" -name '*.zip' | wc -l)"
fi

# --- --dry-run: nothing written -----------------------------------------------------------------
clean_dirs
run_tool --type fb2 -n 100031 100032
last_report="$(ls -1t "$REPORT_DIR"/run_round_*.tsv 2>/dev/null | head -1)"
wrote_anything=0
(( $(find "$OUT_DIR" -type f | wc -l) > 0 )) && wrote_anything=1
row31="$(awk -F'\t' '$2==100031' "$last_report" 2>/dev/null | tail -1)"
if (( RC == 0 )) && (( wrote_anything == 0 )) && [[ "$row31" == *$'\t'placed$'\t'*"dry run"* ]]; then
    report "dry_run_writes_nothing" ok
else
    report "dry_run_writes_nothing" fail "rc=$RC wrote=$wrote_anything row=$row31"
fi

# --- retry loop: re-running a round skips already-placed targets ---------------------------------
# (previous tests cleaned the dirs, so run the round twice HERE: first pass
# places, second pass must skip the existing targets)
clean_dirs
run_tool --type fb2 100031 100032
run_tool --type fb2 100031 100032
last_report="$(ls -1t "$REPORT_DIR"/run_round_*.tsv 2>/dev/null | head -1)"
row31="$(awk -F'\t' '$2==100031' "$last_report" 2>/dev/null | tail -1)"
if (( RC == 0 )) && [[ "$row31" == *$'\t'skipped$'\t'* ]]; then
    report "rerun_skips_placed" ok
else
    report "rerun_skips_placed" fail "rc=$RC row=$row31"
fi

# --- from-file + positional mix --------------------------------------------------------------------
clean_dirs
printf '100031\n# comment\n100032\n' > "$TMPDIR/nums.txt"
run_tool --type fb2 -f "$TMPDIR/nums.txt"
last_report="$(ls -1t "$REPORT_DIR"/run_round_*.tsv 2>/dev/null | head -1)"
if (( RC == 0 )) && (( $(grep -c "^20" "$last_report" 2>/dev/null || true) >= 2 )); then
    report "from_file_round" ok
else
    report "from_file_round" fail "rc=$RC report=$(cat "$last_report" 2>/dev/null | tr '\n' ';')"
fi

# --- summary ----------------------------------------------------------------------------------------
echo
if (( FAIL_COUNT == 0 )); then
    echo "$PASS_COUNT passed, $FAIL_COUNT failed"
    exit 0
else
    echo "$PASS_COUNT passed, $FAIL_COUNT failed"
    for line in "${FAILURE_LINES[@]}"; do echo "  FAILED: $line"; done
    exit 1
fi
