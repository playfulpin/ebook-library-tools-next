#!/usr/bin/env bash

###############################################################################
# bin/authors/authors_prefix_build.sh
#
# Version:       1.0.4
# Last updated:  2026-08-11 20:39
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Generate the toolchain's prefix table (e.g. tmp_SORTED_AUTHORS) from a
#   flat list of author names.  The table is TAB-separated with four columns:
#
#       prefix<TAB>count<TAB>start<TAB>end
#
#   where "prefix" is a name prefix, "count" is the number of authors that
#   share it, and [start..end] is the contiguous 0-based index range those
#   authors occupy in the byte-sorted author list (end is inclusive, so
#   count == end - start + 1).
#
#   The table contains EVERY distinct prefix of EVERY author, from length 1
#   up to MAX_PREFIX_LENGTH (singletons included), and is the input consumed
#   by bin/authors/authors_prefix_check.sh (validator) and bin/authors/authors_prefix_tree.sh
#   (renderer).
#
# -----------------------------------------------------------------------------
# USAGE (two equivalent styles)
# -----------------------------------------------------------------------------
#   Positional style:
#
#       ./bin/authors/authors_prefix_build.sh <input_file> [<max_prefix_length>]
#
#   Named-option style (only the input file is required; -x defaults to 5):
#
#       ./bin/authors/authors_prefix_build.sh -i INPUT_FILE [-x MAX_PREFIX_LENGTH] \
#           [-o OUTPUT_FILE] [-d ON|OFF]
#
#   Both styles may be mixed; named options win over positional values.
#   Output goes to stdout unless -o/--output is given.
#
# EXAMPLES
#   ./bin/authors/authors_prefix_build.sh alphabet_from_db.txt 5 > tmp_SORTED_AUTHORS
#   ./bin/authors/authors_prefix_build.sh -i authors_list_clean_nfc.txt -x 5 -o tmp_SORTED_AUTHORS
#   ./bin/authors/authors_prefix_build.sh -i data/fixtures/authors_list_from_db.txt -x 5 -d on | head
#
# -----------------------------------------------------------------------------
# ALGORITHM (the sorted-range walk, from bin/authors/authors_tree_build.sh)
# -----------------------------------------------------------------------------
#   1. NORMALIZE + SORT
#      The input is read once, CRLF line endings are converted to LF, blank
#      lines are dropped, and the remaining lines are sorted with
#      LC_ALL=C (byte order) into the array SORTED_AUTHORS.  Byte order is
#      the toolchain's sort contract: locale collation is case-insensitive
#      in many environments, so "В" and "в" sort adjacent and same-prefix
#      runs stop being contiguous.
#
#   2. KEY INSIGHT: SORTED RANGES
#      Because SORTED_AUTHORS is sorted, every author that starts with a
#      given prefix P occupies a CONTIGUOUS RANGE of the array.  The row for
#      P is then read straight off the range bounds:
#
#          count = range_end - range_start
#          start = range_start
#          end   = range_end - 1
#
#      No counting table is required -- unlike the original AWK generator,
#      which accumulated count/start/end in associative arrays and then
#      dumped them in HASH order (the historical tmp_SORTED_AUTHORS is not
#      byte-sorted, which is why the integrity checker reports thousands of
#      byte-order warnings on it).
#
#   3. PREFIX-TREE WALK (pre-order = byte order)
#      Walk the prefix trie recursively, starting from each unique first
#      character and its contiguous range.  Inside a range, authors are
#      grouped by the character that follows the current prefix; each unique
#      character is a child prefix with its own contiguous sub-range.  Every
#      node emits one row (its range bounds ARE count/start/end), then the
#      walk descends into its children in byte order, stopping at
#      MAX_PREFIX_LENGTH.
#
#      Because the author array is byte-sorted, lexicographic order of the
#      prefix set equals a pre-order traversal of the trie: a node precedes
#      all of its descendants (its string is their prefix) and child
#      subtrees order by their first differing byte.  The emitted rows are
#      therefore byte-sorted by construction -- no final sort pass needed.
#
#   COMPLEXITY
#      Time:  O(N * L)   -- N authors, L = maximum prefix length.  Each tree
#                          level touches each author at most once via cheap
#                          substring comparisons; no subprocess is forked
#                          per row.
#      Space: O(N)       -- the sorted author array plus the recursion stack
#                          (depth is bounded by L, which is small).
#
# -----------------------------------------------------------------------------
# EXIT STATUS
# -----------------------------------------------------------------------------
#   0  -- table generated successfully
#   1  -- usage / validation error, or empty input
#
###############################################################################

# Strict mode: exit on error, undefined variable use, or failed pipeline
# member.  This makes the generator fail fast instead of emitting a partial,
# silently wrong table.
set -euo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

# Script version, kept in sync with the "# Version:" line in the header.
readonly SCRIPT_VERSION="$(sed -n 's/^# Version:[[:space:]]*//p' "$0" | head -n 1)"

# Walker variant marker, printed in the startup banner.  This names the
# byte-order-critical design choice: the PRE-ORDER TRIE WALKER emits rows in
# lexicographic byte order by construction (see ALGORITHM in the header).  A
# stale copy of this script either prints an older version here or no banner
# at all, so running it is instantly recognizable.
readonly WALKER_VARIANT="pre-order trie walker"

# Defaults for the optional command-line switches (-x, -o, -d).
# MAX_PREFIX_LENGTH is measured in characters and matches the toolchain
# default used by bin/authors/authors_tree_build.sh and bin/authors/authors_prefix_check.sh.
readonly DEFAULT_MAX_PREFIX_LENGTH=5
readonly DEFAULT_DEBUG_MODE="OFF"

###############################################################################
# GLOBAL STATE
###############################################################################

# The sorted, normalized author list (see read_and_sort_authors).
declare -a SORTED_AUTHORS=()
declare -i TOTAL_AUTHORS=0

# Inputs filled in by parse_arguments.
INPUT_FILE=""
MAX_PREFIX_LENGTH=""
OUTPUT_FILE=""
DEBUG_MODE=""

# Track whether -x was given explicitly, so a positional argument does not
# silently override a deliberate command-line choice.
MAX_PREFIX_LENGTH_SET=false

# Debug counters: total rows emitted and per-level row counts.
declare -i TOTAL_ROW_COUNT=0

###############################################################################
# FUNCTIONS
###############################################################################

# -----------------------------------------------------------------------------
# usage
#
# Print the command-line contract to standard error and exit with status 1.
# -----------------------------------------------------------------------------
usage() {
    echo "bin/authors/authors_prefix_build.sh v$SCRIPT_VERSION"
    echo ""
    echo "Usage: $0 <input_file> [<max_prefix_length>]"
    echo "   or: $0 -i FILE [-x NUM] [-o FILE] [-d ON|OFF]"
    echo ""
    echo "Required:"
    echo "  -i, --input-file=FILE  Path to the file containing author names (one per line)"
    echo ""
    echo "Optional:"
    echo "  -x, --max-prefix=NUM   Maximum prefix length in characters [default: 5]"
    echo "  -o, --output=FILE      Write the table to FILE instead of stdout"
    echo "  -d, --debugger=ON|OFF  Enable or disable debug mode [default: OFF]"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Output format (TAB-separated):"
    echo "  prefix<TAB>count<TAB>start<TAB>end"
    exit 1
}

# -----------------------------------------------------------------------------
# assign_option
#
# Store one named-option value into its target variable.  -x is also marked
# as explicitly set so a positional argument never overrides it.
#
# Arguments:
#   $1 - the flag as written by the user, e.g. "--max-prefix"
#   $2 - the value, e.g. "5"
# -----------------------------------------------------------------------------
assign_option() {
    local flag="$1"
    local value="$2"

    case "$flag" in
        -i|--input-file)  INPUT_FILE="$value" ;;
        -x|--max-prefix)  MAX_PREFIX_LENGTH="$value"; MAX_PREFIX_LENGTH_SET=true ;;
        -o|--output)      OUTPUT_FILE="$value" ;;
        -d|--debugger)    DEBUG_MODE="$value" ;;
    esac
}

# -----------------------------------------------------------------------------
# parse_arguments
#
# Accept command-line arguments in either style (or a mixture of both):
#
#   * Named options: -i/--input-file, -x/--max-prefix, -o/--output,
#     -d/--debugger, -h/--help.  Values may be attached with '=' (-i=file),
#     isolated (-i file), or spaced out (-i = file).
#   * Positional arguments fill the input file and max prefix length -- but
#     only where a named option has not already supplied the value.
#   * "--" ends option parsing; everything after it is positional.
# -----------------------------------------------------------------------------
parse_arguments() {
    local -a positional=()
    local arg flag value

    while (( $# > 0 )); do
        arg="$1"

        case "$arg" in
            -h|--help)
                # usage() itself exits 1, per the script's contract.
                usage
                ;;

            # Combined form: flag and value in one token (e.g. -i=file).
            -i=*|--input-file=*|-x=*|--max-prefix=*|-o=*|--output=*|-d=*|--debugger=*)
                flag="${arg%%=*}"
                value="${arg#*=}"

                if [[ -z "$value" ]]; then
                    echo "Error: $flag requires a value." >&2
                    exit 1
                fi

                assign_option "$flag" "$value"
                ;;

            # Isolated form: flag and value as separate tokens (e.g. -i file).
            -i|--input-file|-x|--max-prefix|-o|--output|-d|--debugger)
                if (( $# < 2 )); then
                    echo "Error: $arg requires a value." >&2
                    exit 1
                fi

                value="$2"

                # Tolerate "-i = file" (isolated '=').
                if [[ "$value" == "=" ]]; then
                    if (( $# < 3 )); then
                        echo "Error: $arg requires a value." >&2
                        exit 1
                    fi
                    value="$3"
                    shift
                # Tolerate "-i =file" (leading '=' glued to the value).
                elif [[ "$value" == =* ]]; then
                    value="${value#=}"
                fi

                assign_option "$arg" "$value"
                shift
                ;;

            --)
                # Everything after "--" is treated as positional.
                shift
                positional+=("$@")
                break
                ;;

            -*)
                # Unknown option-like token: fail loudly rather than guessing.
                echo "Error: Unexpected option or argument '$arg'." >&2
                usage
                ;;

            *)
                # Anything else is a positional argument.
                positional+=("$arg")
                ;;
        esac

        shift
    done

    # Positional arguments fill the command slots in canonical order (input
    # file, then max prefix length), skipping any slot already supplied via a
    # named option.
    local -a remaining_positional=("${positional[@]}")

    if [[ -z "$INPUT_FILE" ]] && (( ${#remaining_positional[@]} > 0 )); then
        INPUT_FILE="${remaining_positional[0]}"
        remaining_positional=("${remaining_positional[@]:1}")
    fi

    if [[ "$MAX_PREFIX_LENGTH_SET" == false ]] && (( ${#remaining_positional[@]} > 0 )); then
        MAX_PREFIX_LENGTH="${remaining_positional[0]}"
        remaining_positional=("${remaining_positional[@]:1}")
    fi

    if (( ${#remaining_positional[@]} > 0 )); then
        echo "Error: Too many positional arguments." >&2
        usage
    fi

    # Apply defaults for the optional values.
    [[ -n "$MAX_PREFIX_LENGTH" ]] || MAX_PREFIX_LENGTH="$DEFAULT_MAX_PREFIX_LENGTH"
    [[ -n "$DEBUG_MODE" ]] || DEBUG_MODE="$DEFAULT_DEBUG_MODE"
}

# -----------------------------------------------------------------------------
# read_and_sort_authors
#
# Load INPUT_FILE into SORTED_AUTHORS.
#
# Pipeline stages, in order:
#   1. sed '1s/^\xEF\xBB\xBF//' -- strip a leading UTF-8 BOM (EF BB BF).
#      A BOM is invisible metadata, not part of the first author's name;
#      without this stage its bytes sort to the END of the byte-ordered
#      array (EF > D0), silently creating a bogus "BOM-only" prefix row.
#   2. tr -d '\r'   -- strip Windows CR characters (CRLF -> LF).
#   3. grep -v '^$' -- drop blank lines.
#   4. LC_ALL=C sort -- sort in byte order; identical prefixes become
#                      adjacent, which the range walker depends on.
#
# The pipeline writes into a global via "mapfile", which is far faster than
# appending to an array inside a shell loop.
# -----------------------------------------------------------------------------
read_and_sort_authors() {
    mapfile -t SORTED_AUTHORS < <(
        sed '1s/^\xEF\xBB\xBF//' "$INPUT_FILE" |
        tr -d '\r' |
        grep -v '^$' |
        LC_ALL=C sort
    )

    TOTAL_AUTHORS=${#SORTED_AUTHORS[@]}

    if (( TOTAL_AUTHORS == 0 )); then
        echo "Error: Input file '$INPUT_FILE' contains no valid author lines." >&2
        exit 1
    fi

    if [[ "$DEBUG_MODE" == "ON" ]]; then
        printf "DEBUG: input file: '%s'  total authors: %d\n" "$INPUT_FILE" "$TOTAL_AUTHORS" >&2
    fi
}

# -----------------------------------------------------------------------------
# emit_table_row
#
# Print one table row: prefix<TAB>count<TAB>start<TAB>end.
#
# Arguments:
#   $1 - the prefix
#   $2 - count (number of authors sharing the prefix)
#   $3 - start (0-based index of the first such author)
#   $4 - end   (0-based index of the last such author, inclusive)
#
# The single printf is one builtin call -- no per-row subprocess, which is
# what keeps the generator fast on large author lists.
# -----------------------------------------------------------------------------
emit_table_row() {
    printf '%s\t%d\t%d\t%d\n' "$1" "$2" "$3" "$4"
    TOTAL_ROW_COUNT=$((TOTAL_ROW_COUNT + 1))
}

# -----------------------------------------------------------------------------
# process_prefix
#
# Recursively walk one branch of the prefix tree and emit one row per node,
# in PRE-ORDER (node before its children, children in byte order).  This is
# the same sorted-range recursion that bin/authors/authors_tree_build.sh uses to
# build directory trees -- the difference is that EVERY prefix becomes a row:
# there is no minimum-count filter and no space-boundary skip, because the
# table must list every prefix exactly once.
#
# Arguments:
#   $1 - current prefix
#   $2 - range_start: first index (inclusive) of SORTED_AUTHORS whose authors
#        start with the current prefix
#   $3 - range_end:   index just past the last such author (exclusive)
#
# Every author in [range_start, range_end) starts with the current prefix, so
# the row is read straight off the range bounds:
#   count = range_end - range_start
#   start = range_start
#   end   = range_end - 1
#
# WHY PRE-ORDER IS BYTE ORDER: lexicographic order of a prefix-closed set is
# exactly a depth-first pre-order traversal of the prefix trie -- a node
# precedes all of its descendants (its string is their prefix), and the
# subtrees of two children are ordered by their first differing byte.  The
# author array is byte-sorted, so children are discovered in byte order and
# the emitted rows need no final sort.
# -----------------------------------------------------------------------------
process_prefix() {
    local current_prefix="$1"
    local range_start="$2"
    local range_end="$3"   # exclusive end of the contiguous author range

    local prefix_length=${#current_prefix}

    local i                    # loop cursor over the author range
    local current_author
    local next_character
    local child_start child_end # indices delimiting one child sub-range

    # --- Emit this prefix's row ---------------------------------------------
    emit_table_row "$current_prefix" "$(( range_end - range_start ))" \
        "$range_start" "$(( range_end - 1 ))"

    if [[ "$DEBUG_MODE" == "ON" ]]; then
        printf "DEBUG: prefix='%-*s' count=%4d range=%d..%d\n" \
            "$MAX_PREFIX_LENGTH" "$current_prefix" \
            "$(( range_end - range_start ))" "$range_start" "$(( range_end - 1 ))" >&2
    fi

    # --- Maximum depth reached: no children ---------------------------------
    if (( prefix_length >= MAX_PREFIX_LENGTH )); then
        return
    fi

    # --- Discover children in one pass over the range -----------------------
    # The range is byte-sorted, so authors with the same next character are
    # adjacent.  Walk it once: for each distinct next character, extend the
    # run to its end, then recurse.  An author exactly equal to the prefix
    # has no character after it and starts no child branch -- it still
    # contributes to the prefix's count (matching the AWK generator, which
    # caps each author's prefixes at the author's own length).
    for (( i = range_start; i < range_end; )); do
        current_author="${SORTED_AUTHORS[i]}"

        if (( ${#current_author} <= prefix_length )); then
            (( i += 1 ))
            continue
        fi

        # First character of this child run.
        next_character="${current_author:prefix_length:1}"

        # Expand the run: keep moving while the next character is unchanged.
        child_start=$i
        (( i += 1 ))
        while (( i < range_end )); do
            if [[ "${SORTED_AUTHORS[i]:prefix_length:1}" != "$next_character" ]]; then
                break
            fi
            (( i += 1 ))
        done
        child_end=$i

        # Note: a space next character is a legitimate CHILD here -- unlike
        # bin/authors/authors_tree_build.sh, which skips word boundaries when
        # building directories.  The table lists every prefix, so "де " is a
        # valid row (and bin/authors/authors_prefix_check.sh reports it as a warning).
        process_prefix "${current_prefix}${next_character}" "$child_start" "$child_end"
    done
}

# -----------------------------------------------------------------------------
# emit_prefix_table
#
# Drive the tree walk from the root level: split the whole sorted array into
# contiguous ranges by first character, then recurse into each range.
# -----------------------------------------------------------------------------
emit_prefix_table() {
    local i=0
    local root_prefix
    local child_start child_end

    while (( i < TOTAL_AUTHORS )); do
        root_prefix="${SORTED_AUTHORS[i]:0:1}"
        child_start=$i

        # Extend the run while the first character is unchanged.
        while (( i < TOTAL_AUTHORS )); do
            if [[ "${SORTED_AUTHORS[i]:0:1}" != "$root_prefix" ]]; then
                break
            fi
            (( i += 1 ))
        done

        child_end=$i
        process_prefix "$root_prefix" "$child_start" "$child_end"
    done
}

# -----------------------------------------------------------------------------
# main
#
# Program entry point:
#   1. Parse the arguments (positional, named options, or a mixture).
#   2. Validate the input file and the numeric argument.
#   3. Load and byte-sort the author list.
#   4. Redirect output if -o was given.
#   5. Walk the per-level runs and emit the table rows.
# -----------------------------------------------------------------------------
main() {
    parse_arguments "$@"

    # --- Input file must be given, exist, and be a regular file -------------
    if [[ -z "$INPUT_FILE" ]]; then
        echo "Error: No input file given (use a positional argument or -i/--input-file)." >&2
        usage
    fi

    if [[ ! -f "$INPUT_FILE" ]]; then
        echo "Error: File '$INPUT_FILE' not found." >&2
        exit 1
    fi

    # --- Max prefix length must be a positive integer ------------------------
    # The regex rejects 0, negatives, empty strings, and non-numeric input.
    if [[ ! "$MAX_PREFIX_LENGTH" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: max_prefix_length must be a positive integer, got '$MAX_PREFIX_LENGTH'." >&2
        exit 1
    fi

    # --- Debug mode must be valid --------------------------------------------
    # Values are accepted case-insensitively and normalized to upper case.
    case "${DEBUG_MODE^^}" in
        ON|OFF)
            DEBUG_MODE="${DEBUG_MODE^^}"
            ;;
        *)
            echo "Error: debugger must be ON or OFF, got '$DEBUG_MODE'." >&2
            usage
            ;;
    esac

    # --- Startup banner (stderr only) ----------------------------------------
    # stdout carries the table and is usually redirected straight into a file
    # (tmp_SORTED_AUTHORS), so the banner goes to stderr: always visible in an
    # interactive run, never mixed into the table stream.  The version and the
    # walker variant make a stale copy instantly recognizable -- it prints an
    # older version or no banner at all.  Usage/validation errors still exit
    # before this point, so -h and bad invocations don't banner.
    echo "bin/authors/authors_prefix_build.sh v$SCRIPT_VERSION ($WALKER_VARIANT)" >&2

    # --- Run the pipeline ----------------------------------------------------
    read_and_sort_authors

    # Redirect stdout to the output file before emitting any rows.
    if [[ -n "$OUTPUT_FILE" ]]; then
        exec > "$OUTPUT_FILE"
    fi

    emit_prefix_table

    if [[ "$DEBUG_MODE" == "ON" ]]; then
        printf 'DEBUG: emitted %d rows for %d authors (max prefix length %d)\n' \
            "$TOTAL_ROW_COUNT" "$TOTAL_AUTHORS" "$MAX_PREFIX_LENGTH" >&2
        printf 'DEBUG: elapsed time: %02d:%02d:%02d (%ds)\n' \
            "$((SECONDS / 3600))" "$(((SECONDS % 3600) / 60))" "$((SECONDS % 60))" "$SECONDS" >&2
    fi
}

###############################################################################
# ENTRY POINT
###############################################################################

main "$@"
