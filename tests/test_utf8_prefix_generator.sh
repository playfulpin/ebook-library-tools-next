#!/usr/bin/env bash

# __ETL_TEST_ENV_GUARD__: a caller with set -x/set -v auto-exports SHELLOPTS;
# every child bash re-applies it (it is readonly when imported), so xtrace
# noise corrupts the suites output captures.  Re-exec clean instead.
if [[ ${SHELLOPTS-} == *xtrace* || ${SHELLOPTS-} == *verbose* ]]; then
    exec env -u SHELLOPTS -u BASHOPTS bash "$0" "$@"
fi
unset SHELLOPTS BASHOPTS 2>/dev/null || true


###############################################################################
# tests/test_utf8_prefix_generator.sh
#
# Direct regression suite for lib/utf8_prefix_generator.awk, the original AWK
# prefix-table generator.  Unlike the parity group in
# tests/test_authors_prefix_build.sh -- which only ever compares this script against
# the newer generator (a SYMMETRIC check: both can share a bug and still
# agree) -- this suite asserts the AWK script's own output, row for row.
#
# Coverage:
#   * UTF-8 prefix slicing at every length (multibyte, 3-byte, 4-byte chars).
#   * maxlen capping -- long authors stop at maxlen, short authors emit fewer
#     rows, a 1-char author emits exactly one row.
#   * multi-word authors -- a space is a character, never a field separator
#     (FS="\n"), so prefixes like "де " survive intact.
#   * count/start/end -- shared prefixes aggregate counts and span contiguous
#     0-based ranges; disjoint authors get their own index.
#   * TAB-separated 4-column output (the exact corruption the historical
#     whitespace-splitting version introduced).
#   * BYTE LOCALE -- the same output under LC_ALL=C, locking in the utf8_prefix
#     off-by-one fix (the old code broke at a character's lead byte and sliced
#     multi-byte characters in half under a byte locale).
#
# Usage:
#   bash tests/test_utf8_prefix_generator.sh
#
# IMPORTANT: gawk must run in a UTF-8 locale (character mode).  Cygwin/MSYS
# gawk is byte-oriented; run from WSL instead:
#   wsl.exe bash tests/test_utf8_prefix_generator.sh
#
# Exit status: 0 if every check passed, 1 otherwise; 2 if the environment is
# unusable.
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWK_SCRIPT="$SCRIPT_DIR/../lib/utf8_prefix_generator.awk"

# --- environment sanity -------------------------------------------------------
if ! command -v gawk >/dev/null 2>&1; then
    echo "ERROR: gawk not found." >&2
    exit 2
fi
if [[ ! -f "$AWK_SCRIPT" ]]; then
    echo "ERROR: $AWK_SCRIPT not found." >&2
    exit 2
fi
# The script relies on gawk's character mode: length("аб") must be 2, not the
# 4 bytes a byte-oriented gawk would report.  Byte-oriented gawk (Cygwin/MSYS)
# produces corrupted prefixes, so refuse to run there.
if ! gawk 'BEGIN{ exit (length("аб") == 2) ? 0 : 1 }' 2>/dev/null; then
    echo "ERROR: gawk is byte-oriented (length('аб') != 2)." >&2
    echo "Run from WSL instead:  wsl.exe bash \"$0\"" >&2
    exit 2
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

# -----------------------------------------------------------------------------
# gen <outfile> <maxlen> [C]  -- run the AWK generator on stdin, byte-sort the
# rows (the END block dumps in hash order, which is undefined), and write the
# result to <outfile>.  With the "C" flag, gawk runs under LC_ALL=C (byte
# mode) to exercise the byte-level UTF-8 handling.
# -----------------------------------------------------------------------------
gen() {
    local outfile="$1" maxlen="$2" byte="${3:-}"
    cat > "$TMPDIR/in.txt"
    if [[ "$byte" == "C" ]]; then
        LC_ALL=C gawk -v maxlen="$maxlen" -F '\n' -f "$AWK_SCRIPT" "$TMPDIR/in.txt" 2>/dev/null
    else
        gawk -v maxlen="$maxlen" -F '\n' -f "$AWK_SCRIPT" "$TMPDIR/in.txt" 2>/dev/null
    fi | LC_ALL=C sort > "$outfile"
}

# -----------------------------------------------------------------------------
# expect <outfile> <spec>...  -- write the expected rows.  Each spec is
# "prefix:count:start:end"; the rows are byte-sorted so order is irrelevant.
# -----------------------------------------------------------------------------
expect() {
    local outfile="$1"
    shift
    : > "$outfile"
    local spec p c s e
    for spec in "$@"; do
        IFS=':' read -r p c s e <<< "$spec"
        printf '%s\t%d\t%d\t%d\n' "$p" "$c" "$s" "$e" >> "$outfile"
    done
    LC_ALL=C sort "$outfile" -o "$outfile"
}

# -----------------------------------------------------------------------------
# check <label> <maxlen> [C] <spec>...  -- feed the author list on stdin, run
# the generator, and compare the sorted rows against the expected specs.
# -----------------------------------------------------------------------------
check() {
    local label="$1" maxlen="$2"
    shift 2
    local byte=""
    if [[ "${1:-}" == "C" ]]; then
        byte="C"
        shift
    fi

    gen "$TMPDIR/out.txt" "$maxlen" "$byte"
    expect "$TMPDIR/expected.txt" "$@"

    if diff -q "$TMPDIR/out.txt" "$TMPDIR/expected.txt" >/dev/null 2>&1; then
        report "$label" ok
    else
        report "$label" fail "$(diff "$TMPDIR/expected.txt" "$TMPDIR/out.txt" | head -n 4 | tr '\n' ' ')"
    fi
}

###############################################################################
# UTF-8 prefix slicing
###############################################################################
echo "== UTF-8 prefix slicing =="

# Every prefix length of a multibyte (2-byte-per-char Cyrillic) author.
check multibyte_prefixes 5 \
    "а:1:0:0" "аб:1:0:0" "абв:1:0:0" <<< $'абв\n'

# 3-byte (CJK) and 4-byte (emoji) characters must each count as ONE character.
check wide_utf8_3_and_4_byte 5 \
    "大:1:0:0" "大😀:1:0:0" <<< $'大😀\n'

# ASCII is the trivial case and must be unaffected.
check ascii_prefixes 5 \
    "a:1:0:0" "ab:1:0:0" "abc:1:0:0" <<< $'abc\n'

###############################################################################
# maxlen capping
###############################################################################
echo "== maxlen capping =="

# Long author capped at maxlen=2: only "И" and "Ив".
check maxlen_cap 2 \
    "И:1:0:0" "Ив:1:0:0" <<< $'Иван Петров\n'

# A 1-character author emits exactly one prefix even when maxlen is larger.
check short_author_single_prefix 5 \
    "И:1:0:0" <<< $'И\n'

###############################################################################
# multi-word authors (space is a character, never a separator)
###############################################################################
echo "== multi-word authors =="

# FS="\n" means the space in "де Бальзак Оноре" is part of the prefix.  The
# first five characters are: д е ' ' Б а.
check multi_word_spaces_preserved 5 \
    "д:1:0:0" "де:1:0:0" "де :1:0:0" "де Б:1:0:0" "де Ба:1:0:0" <<< $'де Бальзак Оноре\n'

# An author that ENDS in a space must keep that trailing space in its last
# prefix (the same "де " boundary the shell suite exercises).
check trailing_space_author 3 \
    "д:1:0:0" "де:1:0:0" "де :1:0:0" <<< $'де \n'

###############################################################################
# count / start / end
###############################################################################
echo "== count / start / end =="

# Shared prefixes aggregate over contiguous ranges; the deepest prefix is a
# singleton at the range's tail.
check counts_and_ranges 5 \
    "а:3:0:2" "аб:3:0:2" "абв:1:2:2" <<< $'аб\nаб\nабв\n'

# Disjoint authors land at their own 0-based index.
check start_end_indexing 5 \
    "а:1:0:0" "аб:1:0:0" "абв:1:0:0" "б:1:1:1" <<< $'абв\nб\n'

###############################################################################
# byte locale (the utf8_prefix off-by-one fix)
###############################################################################
echo "== byte locale (LC_ALL=C) =="

# Under a byte-oriented locale the generator must STILL emit full characters,
# not the lead-byte-only fragments the historical utf8_prefix produced.
check byte_mode_locale_c 3 C \
    "а:1:0:0" "аб:1:0:0" "абв:1:0:0" <<< $'абв\n'

check byte_mode_multibyte_prefixes 5 C \
    "д:1:0:0" "де:1:0:0" "де :1:0:0" "де Б:1:0:0" "де Ба:1:0:0" <<< $'де Бальзак Оноре\n'

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
