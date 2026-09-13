#!/usr/bin/env bash

# __ETL_TEST_ENV_GUARD__: a caller with set -x/set -v auto-exports SHELLOPTS;
# every child bash re-applies it (it is readonly when imported), so xtrace
# noise corrupts the suites output captures.  Re-exec clean instead.
if [[ ${SHELLOPTS-} == *xtrace* || ${SHELLOPTS-} == *verbose* ]]; then
    exec env -u SHELLOPTS -u BASHOPTS bash "$0" "$@"
fi
unset SHELLOPTS BASHOPTS 2>/dev/null || true

# -----------------------------------------------------------------------------
# tests/test_authors_tree_build.sh
#
# Regression tests for the directory-tree builder:
#   bin/authors/authors_tree_build.sh (the version lives in the header
#                                  comment, not the file name)
#
# Every case runs the script with the same arguments and compares its
# "mkdir -p" output (the leading "cd <root>" line is checked separately)
# against a stored golden file.  A divergence from the expected output fails
# the suite.  The script at the repository root is the released artifact, so
# there is no separate release snapshot to drift.
#
# Coverage:
#   * multi-word names ("де Бальзак Оноре", "Ван Гог") -- a prefix that ends
#     with a space is a word boundary and must NOT become a directory level:
#     "д/де", never "д/де/де " or "В/Ва/Ван/Ван ".
#   * case variants ("Ван" vs "ван", "Достоевский" vs "достоевский") --
#     byte-order (LC_ALL=C) sorting must keep identical prefixes contiguous
#     so runs are exact and nothing is duplicated or dropped.
#   * duplicated names -- every line counts as an author.
#   * CRLF line endings and a blank line -- must be normalized away.
#   * edge cases -- single-character names, a name exactly equal to a
#     prefix, and names with a trailing space ("де ").
#   * apostrophes ("О'Брайен") -- a valid prefix may end in an apostrophe;
#     the SHELL output substitutes a caret ("mkdir -p О/О^"), while the SQL
#     output keeps the raw prefix and escapes it for the SQL literal.
#   * parameter combos -- the spaces case is also run with max=2 to exercise
#     the maximum-prefix-length boundary.
#   * defaults -- running without -m/-x must behave as -m 10 -x 5.
#   * SQL format (-f sql) -- the same tree rendered as dictionary_nested_set
#     rows (word, lft, rgt), checked against its own golden files.
#   * debug mode (-d ON) -- diagnostics go to stderr only; stdout must stay
#     identical to a normal run.
#   * CLI forms -- positional, named options, combined -f=sql, upper-case
#     values, usage errors (-h, missing args, unknown flags, invalid -d/-f).
#   * root directory resolution -- -r/--root-dir flag, ROOT_DIRECTORY env
#     var, flag-beats-env precedence.
#   * clean run (-c ON) -- ROOT_DIRECTORY is destroyed and rebuilt; the
#     emitted script leads with "rm -rf + mkdir -p + cd" so running it
#     rebuilds a pristine tree; stray files vanish; OFF (default) leaves
#     them alone; dangerous paths ("/", HOME) are refused; invalid values
#     rejected.
#
# Usage:
#   bash tests/test_authors_tree_build.sh          # check against goldens
#   bash tests/test_authors_tree_build.sh --regen  # rewrite the golden
#                                                    # files from current
#                                                    # script output
#
# IMPORTANT: the scripts slice UTF-8 prefixes character by character, so the
# shell must have multi-byte support.  Cygwin/MSYS bash does not; run from
# WSL instead:
#   wsl.exe bash tests/test_authors_tree_build.sh
# -----------------------------------------------------------------------------
set -uo pipefail

MODE="check"
if [[ "${1:-}" == "--regen" ]]; then
    MODE="regen"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Fixtures live in tests/fixtures/, goldens beside this suite; the
# tool under test is two levels up in bin/.
TESTS_DIR="$SCRIPT_DIR/../fixtures"
GOLDEN_DIR="$SCRIPT_DIR/golden"
mkdir -p "$GOLDEN_DIR"

# --- environment sanity -------------------------------------------------------
# The scripts slice UTF-8 by character; this probe fails on byte-based
# shells such as cygwin's bash.
probe='абв'
if [[ "${probe:0:1}" != 'а' ]]; then
    echo "ERROR: this shell slices multi-byte characters by byte." >&2
    echo "Run from WSL instead:  wsl.exe bash \"$0\"" >&2
    exit 2
fi

declare -a SCRIPTS=(
    "bin/authors/authors_tree_build.sh"
)
for s in "${SCRIPTS[@]}"; do
    [[ -f "$SCRIPT_DIR/../../$s" ]] || { echo "ERROR: $SCRIPT_DIR/../../$s not found" >&2; exit 2; }
done

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

# --- run one shell-format invocation against a golden -------------------------
# usage: check_case LABEL SCRIPT SANDBOX GOLDEN INPUT MIN MAX
check_case() {
    local label="$1" script="$2" sandbox="$3" golden="$4" input="$5" min="$6" max="$7"
    local output rc cd_line
    output="$(bash "$script" "$input" "$min" "$max" 2>&1)"
    rc=$?
    if (( rc != 0 )); then
        report "$label" fail "exit code $rc"
        return
    fi
    cd_line="$(printf '%s\n' "$output" | head -n 1)"
    if [[ "$cd_line" != "cd $sandbox" ]]; then
        report "$label" fail "first line is '$cd_line', expected 'cd $sandbox'"
        return
    fi
    if [[ "$MODE" == "regen" ]]; then
        printf '%s\n' "$output" | tail -n +2 > "$golden"
        report "$label" ok "(golden regenerated)"
        return
    fi
    if printf '%s\n' "$output" | tail -n +2 | diff -q - "$golden" >/dev/null 2>&1; then
        report "$label" ok
    else
        report "$label" fail "output differs from $(basename "$golden")"
    fi
}

# --- run one arbitrary invocation against a golden (exact match, no cd line) --
# usage: check_output_exact LABEL SCRIPT GOLDEN ARGS...
check_output_exact() {
    local label="$1" script="$2" golden="$3"
    shift 3
    local output rc
    output="$(bash "$script" "$@" 2>&1)"
    rc=$?
    if (( rc != 0 )); then
        report "$label" fail "exit code $rc"
        return
    fi
    if [[ "$MODE" == "regen" ]]; then
        printf '%s\n' "$output" > "$golden"
        report "$label" ok "(golden regenerated)"
        return
    fi
    if printf '%s\n' "$output" | diff -q - "$golden" >/dev/null 2>&1; then
        report "$label" ok
    else
        report "$label" fail "output differs from $(basename "$golden")"
    fi
}

# --- sandboxed copies: swap the hardcoded ROOT_DIRECTORY for a scratch dir ----
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/fb_test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

declare -A COPY SB
for s in "${SCRIPTS[@]}"; do
    # The entry may carry a bin/ prefix; the scratch names must be bare.
    base="$(basename "${s%.sh}")"
    SB[$s]="$tmp_root/sandbox_$base"
    mkdir -p "${SB[$s]}"
    sed "s|/mnt/c/Backup_Go7/Empty_Skeleton|${SB[$s]}|g" "$SCRIPT_DIR/../../$s" > "$tmp_root/copy_$base.sh"
    COPY[$s]="$tmp_root/copy_$base.sh"
done

# --- runtime fixtures ----------------------------------------------------------
# edge: single-char names, names exactly equal to a prefix, and names with a
# trailing space ("де ").  Generated here so invisible trailing spaces cannot
# be trimmed by an editor.
edge_file="$tmp_root/case_edge.txt"
{
    for _ in {1..8}; do printf 'И\n'; done
    for _ in {1..7}; do printf 'Ив\n'; done
    for _ in {1..8}; do printf 'Иван\n'; done
    for _ in {1..8}; do printf 'Иванов Петр\n'; done
    printf 'Иванов Иван\n'
    for _ in {1..7}; do printf 'де \n'; done          # trailing space!
} > "$edge_file"

# crlf: Windows line endings, plus a blank CRLF line to exercise normalization
crlf_file="$tmp_root/case_crlf.txt"
{
    for _ in {1..8}; do printf 'Апулей Луций\r\n'; done
    printf '\r\n'                                     # blank CRLF line
    for _ in {1..7}; do printf 'Гомер\r\n'; done
} > "$crlf_file"

# --- shell-format cases ---------------------------------------------------------
# label | input | min | max | golden
CASES=(
    "spaces_m6_x5|$TESTS_DIR/case_spaces.txt|6|5|$GOLDEN_DIR/spaces_m6_x5.txt"
    "spaces_m6_x2|$TESTS_DIR/case_spaces.txt|6|2|$GOLDEN_DIR/spaces_m6_x2.txt"
    "case_variants_m6_x5|$TESTS_DIR/case_case_variants.txt|6|5|$GOLDEN_DIR/case_variants_m6_x5.txt"
    "duplicates_m6_x5|$TESTS_DIR/case_duplicates.txt|6|5|$GOLDEN_DIR/duplicates_m6_x5.txt"
    "edge_m6_x5|$edge_file|6|5|$GOLDEN_DIR/edge_m6_x5.txt"
    "crlf_m6_x5|$crlf_file|6|5|$GOLDEN_DIR/crlf_m6_x5.txt"
    "apostrophe_m6_x5|$TESTS_DIR/case_apostrophe.txt|6|5|$GOLDEN_DIR/apostrophe_m6_x5.txt"
)

for s in "${SCRIPTS[@]}"; do
    echo "== $s =="
    for c in "${CASES[@]}"; do
        IFS='|' read -r label input min max golden <<< "$c"
        check_case "$label" "${COPY[$s]}" "${SB[$s]}" "$golden" "$input" "$min" "$max"
    done
done

# --- main script: CLI forms, defaults, SQL, debug ------------------------------
main_copy="${COPY[bin/authors/authors_tree_build.sh]}"
main_sb="${SB[bin/authors/authors_tree_build.sh]}"
echo "== bin/authors/authors_tree_build.sh: CLI forms =="

# named options must produce the same output as positional arguments
output_named="$(bash "$main_copy" -i "$TESTS_DIR/case_spaces.txt" -m 6 -x 5 2>&1)"
rc=$?
if (( rc == 0 )) \
   && [[ "$(printf '%s\n' "$output_named" | head -n 1)" == "cd $main_sb" ]] \
   && printf '%s\n' "$output_named" | tail -n +2 \
      | diff -q - "$GOLDEN_DIR/spaces_m6_x5.txt" >/dev/null 2>&1; then
    report "named_options" ok
else
    report "named_options" fail "exit $rc or output differs from spaces_m6_x5.txt"
fi

# defaults: -i without -m/-x must behave as -m 10 -x 5 (case_spaces: "де"=11
# authors, "Ван"=7 < 10, so the only valid branch is д/де)
output_defaults="$(bash "$main_copy" -i "$TESTS_DIR/case_spaces.txt" 2>&1)"
output_explicit="$(bash "$main_copy" -i "$TESTS_DIR/case_spaces.txt" -m 10 -x 5 2>&1)"
if (( $? == 0 )) \
   && [[ "$output_defaults" == "$output_explicit" ]] \
   && printf '%s\n' "$output_defaults" | tail -n +2 \
      | diff -q - <(printf 'mkdir -p д/де\n') >/dev/null 2>&1; then
    report "defaults_m10_x5" ok
else
    report "defaults_m10_x5" fail "defaults != explicit -m 10 -x 5, or output != 'mkdir -p д/де'"
fi

# missing arguments -> usage error (non-zero exit)
if bash "$main_copy" >/dev/null 2>&1; then
    report "no_args_fails" fail "expected non-zero exit"
else
    report "no_args_fails" ok
fi

# unknown flag -> rejected loudly (non-zero exit)
if bash "$main_copy" --bogus >/dev/null 2>&1; then
    report "unknown_flag_fails" fail "expected non-zero exit"
else
    report "unknown_flag_fails" ok
fi

# -h -> help text, non-zero exit (usage() exits 1 by contract)
if bash "$main_copy" -h >/dev/null 2>&1; then
    report "help_flag" fail "expected non-zero exit (usage exits 1)"
else
    report "help_flag" ok
fi

echo "== bin/authors/authors_tree_build.sh: SQL format (-f sql) =="

# label | input | min | max | golden
SQL_CASES=(
    "sql_spaces_m6_x5|$TESTS_DIR/case_spaces.txt|6|5|$GOLDEN_DIR/spaces_m6_x5_sql.txt"
    "sql_case_variants_m6_x5|$TESTS_DIR/case_case_variants.txt|6|5|$GOLDEN_DIR/case_variants_m6_x5_sql.txt"
    "sql_apostrophe_m6_x5|$TESTS_DIR/case_apostrophe.txt|6|5|$GOLDEN_DIR/apostrophe_m6_x5_sql.txt"
)
for c in "${SQL_CASES[@]}"; do
    IFS='|' read -r label input min max golden <<< "$c"
    check_output_exact "$label" "$main_copy" "$golden" -i "$input" -m "$min" -x "$max" -f sql
done

# combined form (-f=sql) and upper-case value (-f SHELL) must work too
check_output_exact "sql_f_equals" "$main_copy" "$GOLDEN_DIR/spaces_m6_x5_sql.txt" \
    -i "$TESTS_DIR/case_spaces.txt" -m 6 -x 5 -f=sql

output_fshell="$(bash "$main_copy" -i "$TESTS_DIR/case_spaces.txt" -m 6 -x 5 -f SHELL 2>&1)"
rc=$?
if (( rc == 0 )) \
   && [[ "$(printf '%s\n' "$output_fshell" | head -n 1)" == "cd $main_sb" ]] \
   && printf '%s\n' "$output_fshell" | tail -n +2 \
      | diff -q - "$GOLDEN_DIR/spaces_m6_x5.txt" >/dev/null 2>&1; then
    report "format_uppercase_shell" ok
else
    report "format_uppercase_shell" fail "exit $rc or output differs from spaces_m6_x5.txt"
fi

# invalid format / debug values -> rejected
if bash "$main_copy" -i "$TESTS_DIR/case_spaces.txt" -f YAML >/dev/null 2>&1; then
    report "invalid_format_fails" fail "expected non-zero exit"
else
    report "invalid_format_fails" ok
fi
if bash "$main_copy" -i "$TESTS_DIR/case_spaces.txt" -d MAYBE >/dev/null 2>&1; then
    report "invalid_debug_fails" fail "expected non-zero exit"
else
    report "invalid_debug_fails" ok
fi

echo "== bin/authors/authors_tree_build.sh: debug mode (-d ON) =="

# diagnostics must go to stderr only; stdout must be identical to a normal run
dbg_out="$tmp_root/dbg_out.txt"
dbg_err="$tmp_root/dbg_err.txt"
bash "$main_copy" -i "$TESTS_DIR/case_spaces.txt" -m 6 -x 5 -d ON > "$dbg_out" 2> "$dbg_err"
rc=$?
if (( rc == 0 )) \
   && grep -q '^DEBUG:' "$dbg_err" \
   && [[ "$(head -n 1 "$dbg_out")" == "cd $main_sb" ]] \
   && tail -n +2 "$dbg_out" | diff -q - "$GOLDEN_DIR/spaces_m6_x5.txt" >/dev/null 2>&1; then
    report "debugger_on" ok
else
    report "debugger_on" fail "exit $rc, no DEBUG on stderr, or stdout differs from golden"
fi

# lower-case -d off must be accepted and stay silent
output_dbg_off="$(bash "$main_copy" -i "$TESTS_DIR/case_spaces.txt" -m 6 -x 5 -d off 2>&1)"
rc=$?
if (( rc == 0 )) \
   && printf '%s\n' "$output_dbg_off" | tail -n +2 \
      | diff -q - "$GOLDEN_DIR/spaces_m6_x5.txt" >/dev/null 2>&1; then
    report "debugger_off_lowercase" ok
else
    report "debugger_off_lowercase" fail "exit $rc or output differs from spaces_m6_x5.txt"
fi


# --- root directory (-r flag, ROOT_DIRECTORY env) and clean run (-c) -------------
echo "== root directory and clean run =="

custom_root_a="$tmp_root/custom_root_a"
custom_root_b="$tmp_root/custom_root_b"

# -r/--root-dir flag overrides the (sed-swapped) built-in default
output_rflag="$(bash "$main_copy" -i "$TESTS_DIR/case_spaces.txt" -m 6 -x 5 -r "$custom_root_a" 2>&1)"
rc=$?
if (( rc == 0 )) \
   && [[ "$(printf '%s\n' "$output_rflag" | head -n 1)" == "cd $custom_root_a" ]] \
   && printf '%s\n' "$output_rflag" | tail -n +2 \
      | diff -q - "$GOLDEN_DIR/spaces_m6_x5.txt" >/dev/null 2>&1; then
    report "root_flag" ok
else
    report "root_flag" fail "exit $rc or cd line differs or output != golden"
fi

# ROOT_DIRECTORY environment variable is honored as a fallback
output_renv="$(ROOT_DIRECTORY="$custom_root_b" bash "$main_copy" -i "$TESTS_DIR/case_spaces.txt" -m 6 -x 5 2>&1)"
rc=$?
if (( rc == 0 )) && [[ "$(printf '%s\n' "$output_renv" | head -n 1)" == "cd $custom_root_b" ]]; then
    report "root_env_var" ok
else
    report "root_env_var" fail "exit $rc or ROOT_DIRECTORY env var ignored"
fi

# explicit -r beats the ROOT_DIRECTORY environment variable
output_rprec="$(ROOT_DIRECTORY="$custom_root_a" bash "$main_copy" -i "$TESTS_DIR/case_spaces.txt" -m 6 -x 5 -r "$custom_root_b" 2>&1)"
rc=$?
if (( rc == 0 )) && [[ "$(printf '%s\n' "$output_rprec" | head -n 1)" == "cd $custom_root_b" ]]; then
    report "root_flag_beats_env" ok
else
    report "root_flag_beats_env" fail "exit $rc or -r did not override the env var"
fi

# clean run ON: stray file in the root is destroyed, and the emitted script
# leads with rm -rf + mkdir -p + cd so running it destroys and rebuilds too
mkdir -p "$main_sb"
echo leftover > "$main_sb/stray.txt"
output_clean="$(bash "$main_copy" -i "$TESTS_DIR/case_spaces.txt" -m 6 -x 5 -c ON 2>&1)"
rc=$?
if (( rc == 0 )) \
   && [[ ! -e "$main_sb/stray.txt" ]] \
   && [[ "$(printf '%s\n' "$output_clean" | sed -n '1p')" == "rm -rf $main_sb" ]] \
   && [[ "$(printf '%s\n' "$output_clean" | sed -n '2p')" == "mkdir -p $main_sb" ]] \
   && [[ "$(printf '%s\n' "$output_clean" | sed -n '3p')" == "cd $main_sb" ]] \
   && printf '%s\n' "$output_clean" | tail -n +4 \
      | diff -q - "$GOLDEN_DIR/spaces_m6_x5.txt" >/dev/null 2>&1; then
    report "clean_run_on" ok
else
    report "clean_run_on" fail "exit $rc, stray file survived, or rm/mkdir/cd trio missing"
fi

# executing the clean-run output destroys the old tree and rebuilds it
mkdir -p "$main_sb"
echo leftover > "$main_sb/stray.txt"
bash "$main_copy" -i "$TESTS_DIR/case_spaces.txt" -m 6 -x 5 -c ON > "$tmp_root/clean_script.sh" 2>/dev/null
rc=$?
if (( rc == 0 )) && bash "$tmp_root/clean_script.sh" \
   && [[ ! -e "$main_sb/stray.txt" ]] \
   && [[ -d "$main_sb/д/де" ]] \
   && [[ -d "$main_sb/В/Ва/Ван" ]]; then
    report "clean_run_output_rebuilds" ok
else
    report "clean_run_output_rebuilds" fail "exit $rc or rebuilt tree is incomplete"
fi

# clean run OFF (default): stray files must be left alone
mkdir -p "$main_sb"
echo leftover > "$main_sb/stray.txt"
output_noclean="$(bash "$main_copy" -i "$TESTS_DIR/case_spaces.txt" -m 6 -x 5 2>&1)"
rc=$?
if (( rc == 0 )) && [[ -e "$main_sb/stray.txt" ]]; then
    report "clean_run_off_default" ok
else
    report "clean_run_off_default" fail "exit $rc or stray file was removed without -c ON"
fi

# invalid -c value rejected
if bash "$main_copy" -i "$TESTS_DIR/case_spaces.txt" -m 6 -x 5 -c MAYBE >/dev/null 2>&1; then
    report "invalid_clean_run_fails" fail "expected non-zero exit"
else
    report "invalid_clean_run_fails" ok
fi

# dangerous root paths are refused when cleaning (must not touch / or HOME)
if ROOT_DIRECTORY=/ bash "$main_copy" -i "$TESTS_DIR/case_spaces.txt" -m 6 -x 5 -c ON >/dev/null 2>&1; then
    report "clean_run_refuses_dangerous" fail "expected non-zero exit for ROOT_DIRECTORY=/"
else
    report "clean_run_refuses_dangerous" ok
fi

# --- version headers ------------------------------------------------------------
# The script must carry the shared 6.6.x semver ladder in its header, so
# every 0.0.1 bump is visible there (and therefore in -h output).  The value
# is read from the header itself -- the same single source of truth the
# script uses to print "v<version>" in its usage text.
echo "== version headers =="
for s in "${SCRIPTS[@]}"; do
    version="$(sed -n 's/^# Version:[[:space:]]*//p' "$SCRIPT_DIR/../../$s" | head -n 1)"
    if [[ "$version" =~ ^6\.6\.[0-9]+$ ]]; then
        report "version_${s%.sh}" ok
    else
        report "version_${s%.sh}" fail "got '$version', expected ^6\.6\.[0-9]+$"
    fi
done

# --- summary --------------------------------------------------------------------
echo
echo "=============================="
echo "PASS: $PASS_COUNT   FAIL: $FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then
    printf '  - %s\n' "${FAILURE_LINES[@]}"
    exit 1
fi
echo "All tests passed."
exit 0
