#!/usr/bin/env bash

###############################################################################
# bin/authors/authors_prefix_check.sh
#
# Version:       1.2.1
# Last updated:  2026-09-12
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Ultra-strict integrity checker for the AWK-generated prefix table (e.g.
#   tmp_SORTED_AUTHORS).  The table is tab-separated with four columns per
#   row:
#
#       prefix  count  start  end
#
#   where "prefix" is a name prefix and "count" is the number of authors that
#   share it, occupying the contiguous range [start..end] of the sorted author
#   list.  The checker validates every row and reports problems by severity.
#
# -----------------------------------------------------------------------------
# USAGE (positional or named options, or a mixture)
# -----------------------------------------------------------------------------
#   Positional style (backward compatible with the original 1.x CLI):
#
#       ./bin/authors/authors_prefix_check.sh [SEVERITY] prefix_table MAX_PREFIX_LENGTH
#
#   Named-option style:
#
#       ./bin/authors/authors_prefix_check.sh -t TABLE [-x MAX_PREFIX_LENGTH] [-s SEVERITY]
#
#   SEVERITY (default: all):
#       all        Show all PROBLEM messages (critical + warnings)
#       critical   Show only fatal errors
#       warnings   Show only non-fatal warnings
#       info       Show the per-row audit trail and informational notes
#
#   Values may be attached with '=' (-s=info), isolated (-s info), or spaced
#   out (-s = info).  The legacy severity flags --all/--critical/--warnings/
#   --info are accepted too.  Named options win over positional values.
#
# EXAMPLES
#   ./bin/authors/authors_prefix_check.sh tmp_SORTED_AUTHORS 5
#   ./bin/authors/authors_prefix_check.sh --critical tmp_SORTED_AUTHORS 5
#   ./bin/authors/authors_prefix_check.sh -t tmp_SORTED_AUTHORS -x 5 -s warnings
#
# -----------------------------------------------------------------------------
# SEVERITY LEVELS
# -----------------------------------------------------------------------------
#   CRITICAL (fatal, exit status 1 if any are found):
#       • Malformed row (fewer than four tab-separated columns)
#       • Empty prefix
#       • Table is not valid UTF-8 (whole-file check)
#       • Non-numeric count/start/end
#       • start > end
#       • Duplicate prefix
#
#   WARNING:
#       • Spaces in prefix
#       • Slashes in prefix
#       • Control characters in prefix
#       • Prefix longer than MAX_PREFIX_LENGTH
#       • Rows not in strict byte order (the toolchain guarantees a sorted
#         table; a violation means the generator's sort contract was broken)
#
#   INFO (per-row audit, shown with --info):
#       • Every valid row, with its count and range
#       • Singleton prefixes (count == 1)
#
# -----------------------------------------------------------------------------
# ALGORITHM & PERFORMANCE
# -----------------------------------------------------------------------------
#   The original script forked two external processes PER ROW (iconv for the
#   UTF-8 check and grep -P for control characters), which made it quadratic
#   in wall-clock terms: checking a 10k-row table took minutes.  The rewrite
#   eliminates subprocess-per-row work entirely:
#
#     1. WHOLE-FILE UTF-8 VALIDATION (one iconv call, not one per row)
#        The table is a single UTF-8 stream, so a file-level check is both
#        faster and STRICTER than the old per-prefix check (it also catches
#        invalid bytes in the numeric columns, which per-prefix iconv never
#        saw).  The trade-off: a failure is reported at file level instead of
#        pinpointing the exact row.
#
#     2. BUILTIN-ONLY PER-ROW CHECKS
#        Control characters, whitespace, slashes, and all numeric tests use
#        bash builtins ([[ =~ [[:cntrl:]] ]] etc.), so the hot loop never
#        leaves the shell.
#
#     3. SINGLE PASS OVER A LOADED ARRAY
#        The file is normalized once (CR stripped, BOM stripped) and read into
#        an array with mapfile; the checker iterates it by index, which also
#        gives exact line numbers in every diagnostic.
#
#     4. ORDER + DUPLICATE CHECKS ARE FREE SIDE EFFECTS
#        Because the loop already sees every row, byte-order verification
#        (compare against the previous prefix) and duplicate detection (one
#        associative array) cost O(1) extra per row.
#
#   COMPLEXITY
#      Time:  O(N)      -- one pass over N rows, every check is O(1) per row.
#      Space: O(N)      -- the loaded rows plus one entry per prefix in the
#                          duplicate-detection table.
#
# -----------------------------------------------------------------------------
# EXIT STATUS
# -----------------------------------------------------------------------------
#   0  -- no critical problems found
#   1  -- at least one critical problem found (or usage/validation errors)
#
###############################################################################

# Strict mode: exit on error, undefined variable use, or failed pipeline
# member.  This makes the checker fail fast instead of silently passing a
# corrupt table.
set -euo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

# Script version, kept in sync with the "# Version:" line in the header.
# SCRIPT_VERSION is parsed from this file's own header (version-sync contract).
# shellcheck disable=SC2155  # sed+head pipeline cannot fail; masking not a concern
readonly SCRIPT_VERSION="$(sed -n 's/^# Version:[[:space:]]*//p' "$0" | head -n 1)"

# Default severity filter and prefix-length limit.  Both are overridable from
# the command line; 5 matches the toolchain default used by the generator.
readonly DEFAULT_SEVERITY="all"
readonly DEFAULT_MAX_PREFIX_LENGTH=5

###############################################################################
# GLOBAL STATE
###############################################################################

# Inputs filled in by parse_arguments.
TABLE_FILE=""
MAX_PREFIX_LENGTH=""
SEVERITY=""
MAX_PREFIX_LENGTH_SET=false

# The normalized table rows (one string per line) and per-prefix duplicate
# detection.  The seen-table holds one entry per prefix; it is the only O(N)
# memory beyond the rows themselves.
declare -a TABLE_ROWS=()
declare -A SEEN_PREFIXES=()

# Severity counters for the summary line.
declare -i CRITICAL_COUNT=0
declare -i WARNING_COUNT=0
declare -i INFO_COUNT=0

###############################################################################
# FUNCTIONS
###############################################################################

# -----------------------------------------------------------------------------
# usage
#
# Print the command-line contract and exit with status 1.
# -----------------------------------------------------------------------------
usage() {
    echo "bin/authors/authors_prefix_check.sh v$SCRIPT_VERSION"
    echo ""
    echo "Usage: $0 [SEVERITY] prefix_table MAX_PREFIX_LENGTH"
    echo "   or: $0 -t TABLE [-x MAX_PREFIX_LENGTH] [-s SEVERITY]"
    echo ""
    echo "Examples:"
    echo "  $0 tmp_SORTED_AUTHORS 5"
    echo "  $0 --critical tmp_SORTED_AUTHORS 5"
    echo "  $0 -t tmp_SORTED_AUTHORS -x 5 -s warnings"
    echo ""
    echo "Severity modes (default: all):"
    echo "  --all        Show all problem messages (critical + warnings)"
    echo "  --critical   Show only fatal errors"
    echo "  --warnings   Show only non-fatal warnings"
    echo "  --info       Show the per-row audit trail and informational notes"
    echo "  -s, --severity=MODE   Same as the flags above, as a value"
    echo ""
    echo "Options:"
    echo "  -t, --table=FILE      Prefix table to check (4 tab-separated columns)"
    echo "  -x, --max-prefix=NUM  Maximum allowed prefix length [default: $DEFAULT_MAX_PREFIX_LENGTH]"
    echo "  -h, --help            Show this help message"
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
        -t|--table)      TABLE_FILE="$value" ;;
        -x|--max-prefix) MAX_PREFIX_LENGTH="$value"; MAX_PREFIX_LENGTH_SET=true ;;
        -s|--severity)   SEVERITY="$value" ;;
    esac
}

# -----------------------------------------------------------------------------
# parse_arguments
#
# Accept command-line arguments in either style (or a mixture of both):
#
#   * Named options: -t/--table, -x/--max-prefix, -s/--severity, -h/--help,
#     plus the legacy severity flags --all/--critical/--warnings/--info.
#     Values may be attached with '=' (-t=file), isolated (-t file), or
#     spaced out (-t = file).
#   * Positional arguments fill the table file and max prefix length -- but
#     only where a named option has not already supplied the value.
#   * Unknown option-like tokens fail loudly instead of being guessed at.
# -----------------------------------------------------------------------------
parse_arguments() {
    local -a positional=()
    local arg flag value

    while (( $# > 0 )); do
        arg="$1"

        case "$arg" in
            -h|--help)
                usage
                ;;

            # Legacy severity flags: --all, --critical, --warnings, --info.
            --all|--critical|--warnings|--info)
                SEVERITY="${arg#--}"
                ;;

            # Combined form: flag and value in one token (e.g. -t=file).
            -t=*|--table=*|-x=*|--max-prefix=*|-s=*|--severity=*)
                flag="${arg%%=*}"
                value="${arg#*=}"

                if [[ -z "$value" ]]; then
                    echo "Error: $flag requires a value." >&2
                    exit 1
                fi

                assign_option "$flag" "$value"
                ;;

            # Isolated form: flag and value as separate tokens (e.g. -t file).
            -t|--table|-x|--max-prefix|-s|--severity)
                if (( $# < 2 )); then
                    echo "Error: $arg requires a value." >&2
                    exit 1
                fi

                value="$2"

                # Tolerate "-t = file" (isolated '=').
                if [[ "$value" == "=" ]]; then
                    if (( $# < 3 )); then
                        echo "Error: $arg requires a value." >&2
                        exit 1
                    fi
                    value="$3"
                    shift
                # Tolerate "-t =file" (leading '=' glued to the value).
                elif [[ "$value" == =* ]]; then
                    value="${value#=}"
                fi

                assign_option "$arg" "$value"
                shift
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

    # Positional arguments fill the command slots in canonical order (table
    # file, then max prefix length), skipping any slot already supplied via a
    # named option.
    local -a remaining_positional=("${positional[@]}")

    if [[ -z "$TABLE_FILE" ]] && (( ${#remaining_positional[@]} > 0 )); then
        TABLE_FILE="${remaining_positional[0]}"
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
    [[ -n "$SEVERITY" ]] || SEVERITY="$DEFAULT_SEVERITY"
}

# -----------------------------------------------------------------------------
# emit
#
# Print a diagnostic only if the active severity mode selects its level:
#
#     all        -> critical + warnings (every problem)
#     critical   -> critical only
#     warnings   -> warnings only
#     info       -> info only (per-row audit + notes)
#
# Arguments:
#   $1 - level: CRITICAL | WARNING | INFO
#   $2 - message
# -----------------------------------------------------------------------------
emit() {
    local level="$1"
    local msg="$2"

    case "$SEVERITY" in
        all)      [[ "$level" != "INFO" ]] && echo "$msg" ;;
        critical) [[ "$level" == "CRITICAL" ]] && echo "$msg" ;;
        warnings) [[ "$level" == "WARNING" ]] && echo "$msg" ;;
        info)     [[ "$level" == "INFO" ]] && echo "$msg" ;;
    esac

    # Always succeed: a suppressed message is not an error, and set -e must
    # never abort the check because a diagnostic was filtered out.
    return 0
}

# -----------------------------------------------------------------------------
# load_table
#
# Validate the table file as a single UTF-8 stream, then normalize and load
# every line into TABLE_ROWS:
#
#   1. iconv validates the WHOLE file at once -- one external process total
#      instead of one per row (see ALGORITHM & PERFORMANCE in the header).
#   2. tr strips CR bytes so tables with CRLF endings still parse cleanly.
#   3. A leading UTF-8 BOM (if any) is stripped from the first row.
#   4. mapfile reads the normalized stream into the array in one shot.
#
# Exits 1 if the file is empty -- an empty table cannot be a valid prefix
# table.
# -----------------------------------------------------------------------------
load_table() {
    # --- Whole-file UTF-8 validation (single iconv invocation) ---------------
    if ! iconv -f UTF-8 -t UTF-8 "$TABLE_FILE" > /dev/null 2>&1; then
        emit CRITICAL "table is not valid UTF-8 (file-level check)"
        CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
    fi

    # --- Normalize and load --------------------------------------------------
    mapfile -t TABLE_ROWS < <(tr -d '\r' < "$TABLE_FILE")

    # Strip a leading UTF-8 BOM (EF BB BF) from the first row, if present.
    if (( ${#TABLE_ROWS[@]} > 0 )); then
        TABLE_ROWS[0]="${TABLE_ROWS[0]#$'\xEF\xBB\xBF'}"
    fi

    if (( ${#TABLE_ROWS[@]} == 0 )); then
        echo "Error: prefix table '$TABLE_FILE' is empty." >&2
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# check_table
#
# Iterate every loaded row once and apply all row-level checks.  Row-level
# problems are reported through emit(); the summary line is always printed.
#
# Row-level checks, per row:
#   * malformed        -- fewer than four tab-separated columns          CRITICAL
#   * empty prefix     -- first column is empty                          CRITICAL
#   * numeric columns  -- count, start, end must be non-negative integers CRITICAL
#   * range order      -- start <= end (only when both are numeric)      CRITICAL
#   * duplicate prefix -- prefix seen earlier in the table               CRITICAL
#   * spaces / slashes / control characters in the prefix                WARNING
#   * prefix too long  -- longer than MAX_PREFIX_LENGTH                  WARNING
#   * byte order       -- prefix not strictly greater than the previous
#                         prefix (the toolchain guarantees a sorted table) WARNING
#   * valid row        -- audit line with count and range                INFO
# -----------------------------------------------------------------------------
check_table() {
    local total_rows="${#TABLE_ROWS[@]}"
    local i line prefix count start end
    local ALL_NUMERIC=false
    local -a fields=()
    local previous_prefix="" first_row=true

    echo "Checking prefix table: $TABLE_FILE"
    echo "----------------------------------------"

    for (( i = 0; i < total_rows; i++ )); do
        line="${TABLE_ROWS[i]}"

        # --- 1a. Empty prefix -----------------------------------------------
        # read -a silently drops a LEADING empty field, so a row that begins
        # with a tab would otherwise be misclassified as malformed.  Detect
        # it from the raw line first: the prefix column is empty.
        if [[ "$line" == $'\t'* ]]; then
            emit CRITICAL "row $((i + 1)): empty prefix detected (invalid)"
            CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
            continue
        fi

        fields=()
        IFS=$'\t' read -r -a fields <<< "$line"

        # --- 1. Malformed row: need exactly 4 tab-separated columns --------
        if (( ${#fields[@]} < 4 )); then
            emit CRITICAL "row $((i + 1)): malformed row (expected 4 tab-separated columns)"
            CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
            continue
        fi

        prefix="${fields[0]}"
        count="${fields[1]}"
        start="${fields[2]}"
        end="${fields[3]}"

        # --- 2. Empty prefix -----------------------------------------------
        if [[ -z "$prefix" ]]; then
            emit CRITICAL "row $((i + 1)): empty prefix detected (invalid)"
            CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
        fi

        # --- 3. Numeric count/start/end -------------------------------------
        # Fast path: on a healthy table every numeric field is a non-empty
        # run of digits, so ONE regex over the concatenated fields decides for
        # all three at once.  The individual tests below run only when the
        # combined match fails -- rare in practice -- which keeps the hot
        # loop at a single regex instead of three.  The -n guards are load-
        # bearing: without them an EMPTY field would vanish into the
        # concatenation and silently pass.
        if [[ -n "$count" && -n "$start" && -n "$end" && "$count$start$end" =~ ^[0-9]+$ ]]; then
            ALL_NUMERIC=true
        else
            ALL_NUMERIC=false

            if [[ ! "$count" =~ ^[0-9]+$ ]]; then
                emit CRITICAL "row $((i + 1)): non-numeric count for prefix [$prefix]: $count"
                CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
            fi

            if [[ ! "$start" =~ ^[0-9]+$ ]]; then
                emit CRITICAL "row $((i + 1)): non-numeric start index for prefix [$prefix]: $start"
                CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
            fi

            if [[ ! "$end" =~ ^[0-9]+$ ]]; then
                emit CRITICAL "row $((i + 1)): non-numeric end index for prefix [$prefix]: $end"
                CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
            fi
        fi

        # --- 4. Range order: start <= end -----------------------------------
        # Only meaningful when both bounds are numeric; ALL_NUMERIC carries
        # that guarantee from check 3 without re-matching the regex.
        if [[ "$ALL_NUMERIC" == true ]] && (( start > end )); then
            emit CRITICAL "row $((i + 1)): start > end for prefix [$prefix]: $start > $end"
            CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
        fi

        # --- 5. Duplicate prefix --------------------------------------------
        # The table is generated from a sorted author list, so every prefix
        # must be unique.  An associative array gives exact O(1) detection
        # regardless of row order.
        if [[ -n "${SEEN_PREFIXES[$prefix]:-}" ]]; then
            emit CRITICAL "row $((i + 1)): duplicate prefix detected: [$prefix]"
            CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
        fi
        SEEN_PREFIXES[$prefix]=1

        # --- 6. Prefix hygiene: spaces, slashes, control characters --------
        # Same fast-path pattern as check 3: one regex covering all three
        # categories decides the common case; the individual tests run only
        # when something matched, and each one fires its own warning (a
        # prefix with both a space and a slash still reports both).
        if [[ "$prefix" =~ [[:space:]]|[[:cntrl:]]|/ ]]; then
            if [[ "$prefix" =~ [[:space:]] ]]; then
                emit WARNING "row $((i + 1)): space detected in prefix: [$prefix]"
                WARNING_COUNT=$((WARNING_COUNT + 1))
            fi

            if [[ "$prefix" == */* ]]; then
                emit WARNING "row $((i + 1)): slash detected in prefix: [$prefix]"
                WARNING_COUNT=$((WARNING_COUNT + 1))
            fi

            if [[ "$prefix" =~ [[:cntrl:]] ]]; then
                emit WARNING "row $((i + 1)): control character detected in prefix: [$prefix]"
                WARNING_COUNT=$((WARNING_COUNT + 1))
            fi
        fi

        # --- 7. Prefix length limit ------------------------------------------
        # ${#prefix} counts characters (the shell is multibyte-aware under
        # WSL), matching how the generator measures prefix depth.
        if (( ${#prefix} > MAX_PREFIX_LENGTH )); then
            emit WARNING "row $((i + 1)): prefix too long (>${MAX_PREFIX_LENGTH}) [$prefix]"
            WARNING_COUNT=$((WARNING_COUNT + 1))
        fi

        # --- 8. Byte order ---------------------------------------------------
        # The toolchain sorts the table with LC_ALL=C (byte order), and the
        # range-based tree walk in bin/authors/authors_tree_build.sh DEPENDS on
        # contiguity.  LC_ALL=C forces the comparison to byte order so case
        # variants (В vs в) are checked exactly as the generator sorted them.
        if [[ "$first_row" == true ]]; then
            first_row=false
        elif LC_ALL=C test "$prefix" \< "$previous_prefix"; then
            emit WARNING "row $((i + 1)): rows not in byte order ([$prefix] before [$previous_prefix])"
            WARNING_COUNT=$((WARNING_COUNT + 1))
        fi
        previous_prefix="$prefix"

        # --- 9. Info audit line ----------------------------------------------
        emit INFO "row $((i + 1)): OK [$prefix] count=$count range=$start..$end"
        INFO_COUNT=$((INFO_COUNT + 1))

        # ALL_NUMERIC is the guard here: with set -u, an arithmetic
        # evaluation of a non-numeric count (e.g. "abc") would abort the
        # whole check mid-table.  10# forces decimal so leading zeros never
        # parse as octal.
        if [[ "$ALL_NUMERIC" == true ]] && (( 10#$count == 1 )); then
            emit INFO "row $((i + 1)): singleton prefix (count=1) [$prefix]"
            INFO_COUNT=$((INFO_COUNT + 1))
        fi
    done
}

# -----------------------------------------------------------------------------
# main
#
# Program entry point:
#   1. Parse the arguments (positional, named options, or a mixture).
#   2. Validate the table file, the numeric argument, and the severity mode.
#   3. Load the table (whole-file UTF-8 check + normalization).
#   4. Run every row-level check in one pass.
#   5. Print the summary and exit non-zero if any critical problem was found.
# -----------------------------------------------------------------------------
main() {
    parse_arguments "$@"

    # --- Table file must be given, exist, and be a regular file -------------
    if [[ -z "$TABLE_FILE" ]]; then
        echo "Error: No prefix table given (use a positional argument or -t/--table)." >&2
        usage
    fi

    if [[ ! -f "$TABLE_FILE" ]]; then
        echo "Error: Prefix table file '$TABLE_FILE' not found." >&2
        exit 1
    fi

    # --- Max prefix length must be a positive integer -----------------------
    if [[ ! "$MAX_PREFIX_LENGTH" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: max_prefix_length must be a positive integer, got '$MAX_PREFIX_LENGTH'." >&2
        exit 1
    fi

    # --- Severity must be one of the four known modes ------------------------
    # Accepted case-insensitively and normalized to lower case.
    case "${SEVERITY,,}" in
        all|critical|warnings|info)
            SEVERITY="${SEVERITY,,}"
            ;;
        *)
            echo "Error: severity must be all, critical, warnings, or info, got '$SEVERITY'." >&2
            usage
            ;;
    esac

    # --- Run the pipeline ----------------------------------------------------
    load_table
    check_table

    # --- Summary -------------------------------------------------------------
    echo "----------------------------------------"
    echo "Checked ${#TABLE_ROWS[@]} rows: $CRITICAL_COUNT critical, $WARNING_COUNT warnings, $INFO_COUNT info."

    if (( CRITICAL_COUNT > 0 )); then
        exit 1
    fi
}

###############################################################################
# ENTRY POINT
###############################################################################

main "$@"
