#!/usr/bin/env bash

# __ETL_TEST_ENV_GUARD__: a caller with set -x/set -v auto-exports SHELLOPTS;
# every child bash re-applies it (it is readonly when imported), so xtrace
# noise corrupts the suites output captures.  Re-exec clean instead.
if [[ ${SHELLOPTS-} == *xtrace* || ${SHELLOPTS-} == *verbose* ]]; then
    exec env -u SHELLOPTS -u BASHOPTS bash "$0" "$@"
fi
unset SHELLOPTS BASHOPTS 2>/dev/null || true

# -----------------------------------------------------------------------------
# tests/unit/test_extract_bookid_flibusta.sh
#
# Regression suite for bin/flibusta/extract_bookid_flibusta.sh (stage-1 Flibusta
# range-archive extractor, fb2 + usr families, batch mode).  Fully hermetic:
# real zip fixtures are created in a temp dir; no network, no MariaDB.
#
# Asserts the tool's contract:
#   - range match per family: f.fb2-* / f.usr-*, inclusive bounds, 10#
#     normalization, malformed names ignored, no match -> item failure
#   - fb2 member: exact <N>.fb2
#   - usr member: prefix <N>. with any real extension (pdf, djvu, .pdf.zip);
#     output keeps the member's real basename
#   - sparse members: a number inside a range but absent from the archive
#     fails that item without killing the batch
#   - type chain: both = fb2 first, usr fallback; a usr hit after a sparse
#     fb2 member counts as delivered (exit 0)
#   - batch: summary line, per-item progress, exit 1 when any number failed,
#     invalid numbers are failures not aborts
#   - --from-file: numbers read from a list (CRLF, blank lines, comments,
#     BOM tolerated)
#   - skip-existing unless --force
#   - CLI contract: --help exits 0, --version prints the header version,
#     unknown option exits 2, bad --type exits 2, no numbers exits 2
#   - dry-run resolves and writes nothing
#
# Version header stays in sync with --version (0.3.x).
#
# Usage:  bash tests/unit/test_extract_bookid_flibusta.sh
# -----------------------------------------------------------------------------

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."
TOOL="$REPO_ROOT/bin/flibusta/extract_bookid_flibusta.sh"

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
SOURCE_DIR="$TMPDIR/source"
OUTPUT_DIR="$TMPDIR/output"
mkdir -p "$SOURCE_DIR" "$OUTPUT_DIR"

printf 'content of 100005\n' > "$TMPDIR/100005.fb2"
printf 'content of 100010\n' > "$TMPDIR/100010.fb2"
printf 'content of 100011\n' > "$TMPDIR/100011.fb2"
printf 'content of 100020\n' > "$TMPDIR/100020.fb2"
printf 'usr pdf of 20005\n'  > "$TMPDIR/20005.pdf"
printf 'usr djvu of 20011\n' > "$TMPDIR/20011.djvu"
printf 'usr dbl-zip of 20015\n' > "$TMPDIR/20015.pdf.zip"
printf 'sparse-range member\n' > "$TMPDIR/300010.fb2"
(
    cd "$TMPDIR" || exit 1
    # fb2 family
    zip -q "$SOURCE_DIR/f.fb2-100001-100010.zip" 100005.fb2 100010.fb2
    zip -q "$SOURCE_DIR/f.fb2-100011-100020.zip" 100011.fb2 100020.fb2
    zip -q "$SOURCE_DIR/f.fb2-300001-300020.zip" 300010.fb2   # sparse: only 300010
    # usr family: mixed real extensions, zero-padded range name (members are
    # UNPADDED, as in the real data: 91841.fb2 lives in fb2-000024-030559.zip)
    zip -q "$SOURCE_DIR/f.usr-020001-020020.zip" 20005.pdf 20011.djvu 20015.pdf.zip
    # oldest-style usr: title-named members only (no numbered members at all)
    zip -q "$SOURCE_DIR/f.usr-030001-030010.zip" Author_Title.rar
    # malformed names: must be ignored by the range matcher
    : > "$SOURCE_DIR/f.fb2-notarange.zip"
    : > "$SOURCE_DIR/unrelated.zip"
)

run_tool() { # [args...]; stdout->$OUT, stderr->$ERR; rc->$RC
    OUT="$TMPDIR/stdout.txt" ERR="$TMPDIR/stderr.txt"
    FLIBUSTA_SOURCE_DIR="$SOURCE_DIR" FB2_OUTPUT_DIR="$OUTPUT_DIR" \
        bash "$TOOL" "$@" >"$OUT" 2>"$ERR"
    RC=$?
}

out_has() { # $1 = file, $2 = expected content -> 0/1
    [[ -f "$1" ]] && [[ "$(cat "$1" 2>/dev/null)" == "$2" ]]
}

echo "== extract_bookid_flibusta =="

# --- version / usage --------------------------------------------------------------
version="$(sed -n 's/^# Version:[[:space:]]*//p' "$TOOL" | head -n 1)"
if [[ "$version" =~ ^0\.3\.[0-9]+$ ]]; then
    report "version_header" ok "header $version"
else
    report "version_header" fail "got '$version', expected ^0.3.[0-9]+$"
fi

bash "$TOOL" --version >"$TMPDIR/v.txt" 2>&1
if [[ "$(cat "$TMPDIR/v.txt")" == "bin/flibusta/extract_bookid_flibusta.sh v$version" ]]; then
    report "version_flag" ok
else
    report "version_flag" fail "got '$(cat "$TMPDIR/v.txt")'"
fi

bash "$TOOL" --help >"$TMPDIR/h.txt" 2>&1
if (( $? == 0 )) && grep -q -- "--from-file" "$TMPDIR/h.txt" && grep -q -- "--type" "$TMPDIR/h.txt"; then
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

run_tool --type bogus 100005
if (( RC == 2 )); then
    report "bad_type_exit2" ok
else
    report "bad_type_exit2" fail "expected exit 2, got $RC"
fi

# --- fb2 family ---------------------------------------------------------------------
run_tool 100005
if (( RC == 0 )) && out_has "$OUTPUT_DIR/100005.fb2" "content of 100005" \
   && [[ "$(head -n 1 "$ERR")" == *"f.fb2-100001-100010.zip"* ]]; then
    report "fb2_extract" ok
else
    report "fb2_extract" fail "rc=$RC err=$(head -2 "$ERR")"
fi

run_tool 100020
if (( RC == 0 )) && out_has "$OUTPUT_DIR/100020.fb2" "content of 100020" \
   && [[ "$(head -n 1 "$ERR")" == *"f.fb2-100011-100020.zip"* ]]; then
    report "fb2_inclusive_upper_bound" ok
else
    report "fb2_inclusive_upper_bound" fail "rc=$RC"
fi

# zero-padded range names: 020001-020020 must match 20005..20020 after 10#
run_tool --type usr 20005
if (( RC == 0 )) && out_has "$OUTPUT_DIR/20005.pdf" "usr pdf of 20005"; then
    report "usr_zero_padded_range" ok
else
    report "usr_zero_padded_range" fail "rc=$RC err=$(head -2 "$ERR")"
fi

# --- usr family: real extensions preserved ------------------------------------------
run_tool --type usr 20011
if (( RC == 0 )) && out_has "$OUTPUT_DIR/20011.djvu" "usr djvu of 20011"; then
    report "usr_real_extension_kept" ok
else
    report "usr_real_extension_kept" fail "rc=$RC"
fi

run_tool --type usr 20015
if (( RC == 0 )) && out_has "$OUTPUT_DIR/20015.pdf.zip" "usr dbl-zip of 20015"; then
    report "usr_double_suffix_kept" ok
else
    report "usr_double_suffix_kept" fail "rc=$RC"
fi

# --- both: fb2 first, usr fallback ----------------------------------------------------
run_tool --type both 20011
if (( RC == 0 )) && out_has "$OUTPUT_DIR/20011.djvu" "usr djvu of 20011" \
   && [[ ! -e "$OUTPUT_DIR/20011.fb2" ]]; then
    report "both_fb2_miss_usr_hit" ok
else
    report "both_fb2_miss_usr_hit" fail "rc=$RC err=$(head -3 "$ERR")"
fi

# sparse fb2 member (300005 in range, absent) + absent usr: item failure
rm -f "$OUTPUT_DIR"/*
run_tool 300005
if (( RC == 1 )) && (( $(ls -1 "$OUTPUT_DIR" 2>/dev/null | wc -l) == 0 )); then
    report "sparse_member_exit1" ok
else
    report "sparse_member_exit1" fail "rc=$RC"
fi

# oldest usr style: title-named members only -> not delivered
run_tool --type usr 30005
if (( RC == 1 )); then
    report "usr_titled_only_not_delivered" ok
else
    report "usr_titled_only_not_delivered" fail "rc=$RC"
fi

# --- batch ------------------------------------------------------------------------------
rm -f "$OUTPUT_DIR"/*
run_tool 100005 100020
if (( RC == 0 )) && out_has "$OUTPUT_DIR/100005.fb2" "content of 100005" \
   && out_has "$OUTPUT_DIR/100020.fb2" "content of 100020" \
   && grep -q "summary: 2 delivered" "$ERR"; then
    report "batch_two_ok" ok
else
    report "batch_two_ok" fail "rc=$RC err=$(tail -3 "$ERR")"
fi

# batch with one failing number: good ones delivered, exit 1, failure listed
rm -f "$OUTPUT_DIR"/*
run_tool 100005 999999
if (( RC == 1 )) && out_has "$OUTPUT_DIR/100005.fb2" "content of 100005" \
   && grep -q "999999" "$ERR"; then
    report "batch_partial_failure_exit1" ok
else
    report "batch_partial_failure_exit1" fail "rc=$RC err=$(tail -3 "$ERR")"
fi

# invalid number inside a batch is a failure, not an abort
rm -f "$OUTPUT_DIR"/*
run_tool notanumber 100005
if (( RC == 1 )) && out_has "$OUTPUT_DIR/100005.fb2" "content of 100005"; then
    report "batch_invalid_number_failure" ok
else
    report "batch_invalid_number_failure" fail "rc=$RC"
fi

# --- from-file ----------------------------------------------------------------------------
rm -f "$OUTPUT_DIR"/*
printf '\xEF\xBB\xBF100005\r\n\r\n# a comment\r\n100011\r\n' > "$TMPDIR/list.txt"
run_tool --from-file "$TMPDIR/list.txt"
if (( RC == 0 )) && out_has "$OUTPUT_DIR/100005.fb2" "content of 100005" \
   && out_has "$OUTPUT_DIR/100011.fb2" "content of 100011" \
   && grep -q "summary: 2 delivered" "$ERR"; then
    report "from_file_bom_crlf_comments" ok
else
    report "from_file_bom_crlf_comments" fail "rc=$RC err=$(tail -3 "$ERR")"
fi

# from-file mixed with positionals
rm -f "$OUTPUT_DIR"/*
run_tool --from-file "$TMPDIR/list.txt" 100020
if (( RC == 0 )) && out_has "$OUTPUT_DIR/100020.fb2" "content of 100020" \
   && grep -q "summary: 3 delivered" "$ERR"; then
    report "from_file_with_positionals" ok
else
    report "from_file_with_positionals" fail "rc=$RC err=$(tail -3 "$ERR")"
fi

# --- skip-existing / force ------------------------------------------------------------------
# outputs already exist from the previous test; default run skips all
run_tool 100005 100011 100020
if (( RC == 0 )) && grep -q "3 delivered, 3 of them skipped" "$ERR"; then
    report "skip_existing" ok
else
    report "skip_existing" fail "rc=$RC err=$(tail -2 "$ERR")"
fi

# --force re-extracts (single-number runs log the archive line only on a
# real attempt; a skipped item logs nothing about the archive)
run_tool --force 100005
if (( RC == 0 )) && grep -q "archive: .*f\.fb2-100001-100010\.zip" "$ERR"; then
    report "force_reextracts" ok
else
    report "force_reextracts" fail "rc=$RC err=$(tail -2 "$ERR")"
fi

# --- dry-run ----------------------------------------------------------------------------------
rm -f "$OUTPUT_DIR"/*
run_tool --dry-run 100005 100020
if (( RC == 0 )) && grep -q "dry-run: 2 item(s) resolvable" "$ERR" \
   && (( $(ls -1 "$OUTPUT_DIR" 2>/dev/null | wc -l) == 0 )); then
    report "dryrun_resolves_writes_nothing" ok
else
    report "dryrun_resolves_writes_nothing" fail "rc=$RC files=$(ls -1 "$OUTPUT_DIR" | tr '\n' ',')"
fi

# dry-run reports the failure too
run_tool --dry-run 999999
if (( RC == 1 )) && grep -q "dry-run: 0 item(s) resolvable, 1 failed" "$ERR"; then
    report "dryrun_failure_counted" ok
else
    report "dryrun_failure_counted" fail "rc=$RC"
fi

# --- output-dir flag override ------------------------------------------------------------------
ALT_OUT="$TMPDIR/alt-out"
run_tool --output-dir "$ALT_OUT" 100011
if (( RC == 0 )) && out_has "$ALT_OUT/100011.fb2" "content of 100011" \
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
