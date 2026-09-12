#!/usr/bin/env bash

###############################################################################
# bin/authors/authors_tree_build.sh
#
# Version:       6.6.10
# Last updated:  2026-09-01 14:06
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Generate "mkdir -p" shell commands that build a nested directory hierarchy
#   from a flat list of author names.  Example transformation:
#
#       Input author:          Абрамов Александр Иванович
#       Generated directory:   А/Аб/Абр/Абра
#
#   A directory level is created only when its name prefix is shared by at
#   least MINIMUM_AUTHORS authors.  Only the DEEPEST valid directory of every
#   branch is printed, because "mkdir -p" implicitly creates all missing
#   parent directories (А, Аб, Абр in the example above).
#
# -----------------------------------------------------------------------------
# USAGE (two equivalent styles)
# -----------------------------------------------------------------------------
#   Positional style (all three arguments required, in order):
#
#       ./bin/authors/authors_tree_build.sh <input_file> <minimum_authors> <maximum_prefix_length>
#
#   Named-option style (only the input file is required; -m and -x default
#   to 10 and 5):
#
#       ./bin/authors/authors_tree_build.sh -i INPUT_FILE \
#           [-m MINIMUM_AUTHORS] [-x MAX_PREFIX_LENGTH] [-d ON|OFF] [-f SHELL|SQL]
#
#   Both styles may be mixed; named options win over positional values.
#
# EXAMPLES
#   ./bin/authors/authors_tree_build.sh data/fixtures/authors_list_from_db.txt 6 5
#   ./bin/authors/authors_tree_build.sh -i data/fixtures/authors_list_from_db.txt -m 6 -x 5
#   ./bin/authors/authors_tree_build.sh --input-file=data/fixtures/authors_list_from_db.txt --min-authors=6 --max-prefix=5
#   ./bin/authors/authors_tree_build.sh -i data/fixtures/authors_list_from_db.txt -f sql -d on
#
# -----------------------------------------------------------------------------
# OUTPUT
# -----------------------------------------------------------------------------
#   cd /mnt/c/Backup_Go7/Empty_Skeleton
#   mkdir -p А/Аб/Абр/Абра
#
#   With -f sql the same tree is emitted as SQL statements for the
#   dictionary_nested_set table (word, lft, rgt) instead.
#
#   APOSTROPHES: author names may legitimately contain an apostrophe
#   (e.g. "О'Брайен"), and a prefix ending in one would otherwise become a
#   directory component with an embedded quote ("О/О'").  The SHELL output
#   substitutes a caret for every apostrophe ("О/О^") so emitted paths stay
#   clean and safe to copy-paste.  The SQL output keeps the raw prefix (its
#   rows escape single quotes for the SQL literal).
#
# -----------------------------------------------------------------------------
# ALGORITHM
# -----------------------------------------------------------------------------
#   1. NORMALIZE + SORT
#      The input is read once, CRLF line endings are converted to LF, blank
#      lines are dropped, and the remaining lines are sorted alphabetically
#      into the array SORTED_AUTHORS.
#
#   2. KEY INSIGHT: SORTED RANGES
#      Because SORTED_AUTHORS is sorted, every author that starts with a given
#      prefix P occupies a CONTIGUOUS RANGE of the array.  Two facts follow:
#
#        a) The number of authors matching P equals the size of that range,
#           so no separate count table is required.
#        b) The authors matching a CHILD prefix (P + one character) form a
#           smaller contiguous sub-range inside P's range.
#
#   3. PREFIX-TREE WALK (per level)
#      The walk starts with every unique first character (root prefix) and its
#      range.  Inside a range, authors are grouped by the character that
#      follows the current prefix; each unique character is a child prefix
#      with its own contiguous sub-range.  The walk recurses only into
#      children whose range holds at least MINIMUM_AUTHORS authors, and
#      stops at MAXIMUM_PREFIX_LENGTH.
#
#      A prefix is printed ("mkdir -p ...") only when it is valid but has no
#      valid child, or when it sits at the maximum depth.
#
#   COMPLEXITY
#      Time:  O(N * L)   -- N authors, L = maximum prefix length.  Every level
#                          of the tree touches each author at most once, and
#                          ranges shrink as the walk descends.
#      Space: O(N)       -- the sorted author array plus the recursion stack
#                          (depth is bounded by L, which is small).
#
###############################################################################

# Strict mode: exit on error, undefined variable use, or failed pipeline
# member.  This makes the script fail fast instead of producing a partial,
# silently wrong directory listing.
set -euo pipefail

###############################################################################
# CONFIGURATION
###############################################################################

# Script version, kept in sync with the "# Version:" line in the header.
readonly SCRIPT_VERSION="$(sed -n 's/^# Version:[[:space:]]*//p' "$0" | head -n 1)"

# Root directory under which the author hierarchy is created.  Every generated
# command changes into this directory before running "mkdir -p".
#
# Resolution order (industry standard, highest precedence first):
#   1. -r/--root-dir command-line flag
#   2. ROOT_DIRECTORY environment variable
#   3. built-in default below
DEFAULT_ROOT_DIRECTORY="/mnt/c/Backup_Go7/Empty_Skeleton"
ROOT_DIRECTORY="${ROOT_DIRECTORY:-$DEFAULT_ROOT_DIRECTORY}"

# Defaults for the optional command-line switches (-m, -x, -d, -f, -c).
readonly DEFAULT_MINIMUM_AUTHORS=10
readonly DEFAULT_MAX_PREFIX_LENGTH=5
readonly DEFAULT_DEBUG_MODE="OFF"
readonly DEFAULT_OUTPUT_FORMAT="SHELL"
readonly DEFAULT_CLEAN_RUN="OFF"

###############################################################################
# GLOBAL STATE
###############################################################################
# The sorted, normalized author list.  It is global (instead of being copied
# into every recursive call) so that the walker can slice contiguous ranges
# by index without duplicating the array -- important for memory and speed.
declare -a SORTED_AUTHORS=()
declare -i TOTAL_AUTHORS=0

# Inputs filled in by parse_arguments.
INPUT_FILE=""
MINIMUM_AUTHORS=""
MAX_PREFIX_LENGTH=""
DEBUG_MODE=""
OUTPUT_FORMAT=""
CLEAN_RUN=""

# Track whether -m/-x were given explicitly, so positional arguments do not
# silently override a deliberate command-line choice.
MINIMUM_AUTHORS_SET=false
MAX_PREFIX_LENGTH_SET=false

# SQL-format state: a single running counter for lft/rgt assignment, and the
# collected rows as "path|lft|rgt" strings (see emit_sql_commands).
declare -i SQL_ORDER=0
declare -a SQL_ROWS=()

###############################################################################
# FUNCTIONS
###############################################################################

# -----------------------------------------------------------------------------
# usage
#
# Print the command-line contract to standard error and exit with status 1.
# -----------------------------------------------------------------------------
usage() {
    echo "bin/authors/authors_tree_build.sh v$SCRIPT_VERSION"
    echo ""
    echo "Usage: $0 --input-file=FILE [OPTIONS]"
    echo ""
    echo "Required:"
    echo "  -i, --input-file=FILE  Path to the file containing author names (one per line)"
    echo ""
    echo "Optional:"
    echo "  -m, --min-authors=NUM  Minimum number of authors required for a prefix [default: 10]"
    echo "  -x, --max-prefix=NUM   Maximum length of prefix to consider [default: 5]"
    echo "  -d, --debugger=ON|OFF  Enable or disable debug mode [default: OFF]"
    echo "  -f, --format=TYPE      Output format: SQL or SHELL [default: SHELL]"
    echo "  -r, --root-dir=PATH    Root directory for the hierarchy"
    echo "                         [default: \$ROOT_DIRECTORY env var or built-in]"
    echo "  -c, --clean-run=ON|OFF Delete and rebuild ROOT_DIRECTORY first [default: OFF]"
    echo "  -h, --help             Show this help message"
    exit 1
}

# -----------------------------------------------------------------------------
# assign_option
#
# Store one named-option value into its target variable.  -m and -x are also
# marked as explicitly set so positional arguments never override them.
#
# Arguments:
#   $1 - the flag as written by the user, e.g. "--min-authors"
#   $2 - the value, e.g. "6"
# -----------------------------------------------------------------------------
assign_option() {
    local flag="$1"
    local value="$2"

    case "$flag" in
        -i|--input-file)    INPUT_FILE="$value" ;;
        -m|--min-authors)   MINIMUM_AUTHORS="$value"; MINIMUM_AUTHORS_SET=true ;;
        -x|--max-prefix)    MAX_PREFIX_LENGTH="$value"; MAX_PREFIX_LENGTH_SET=true ;;
        -d|--debugger)      DEBUG_MODE="$value" ;;
        -f|--format)        OUTPUT_FORMAT="$value" ;;
        -r|--root-dir)      ROOT_DIRECTORY="$value" ;;
        -c|--clean-run)     CLEAN_RUN="$value" ;;
    esac
}

# -----------------------------------------------------------------------------
# parse_arguments
#
# Accept command-line arguments in either style (or a mixture of both):
#
#   * Named options: -i/--input-file, -m/--min-authors, -x/--max-prefix,
#     -h/--help.  Values may be attached with '=' (-i=file), isolated
#     (-i file), or spaced out (-i = file).
#   * Positional arguments are collected in order and fill in the input file,
#     minimum authors, and maximum prefix length -- but only where a named
#     option has not already supplied the value.
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
            -i=*|--input-file=*|-m=*|--min-authors=*|-x=*|--max-prefix=*|-d=*|--debugger=*|-f=*|--format=*|-r=*|--root-dir=*|-c=*|--clean-run=*)
                flag="${arg%%=*}"
                value="${arg#*=}"

                if [[ -z "$value" ]]; then
                    echo "Error: $flag requires a value." >&2
                    exit 1
                fi

                assign_option "$flag" "$value"
                ;;

            # Isolated form: flag and value as separate tokens (e.g. -i file).
            -i|--input-file|-m|--min-authors|-x|--max-prefix|-d|--debugger|-f|--format|-r|--root-dir|-c|--clean-run)
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
                # Use "--" to pass filenames that legitimately start with '-'
                # as positional arguments.
                echo "Error: Unexpected option or argument '$arg'." >&2
                usage
                exit 1
                ;;

            *)
                # Anything else is a positional argument.
                positional+=("$arg")
                ;;
        esac

        shift
    done

    # Positional arguments fill the command slots in canonical order
    # (input file, then minimum authors, then maximum prefix length),
    # skipping any slot already supplied via a named option.  A positional
    # value therefore never overrides an explicit -i/-m/-x.
    local -a remaining_positional=("${positional[@]}")

    # Slot 1: input file.
    if [[ -z "$INPUT_FILE" ]] && (( ${#remaining_positional[@]} > 0 )); then
        INPUT_FILE="${remaining_positional[0]}"
        remaining_positional=("${remaining_positional[@]:1}")
    fi

    # Slot 2: minimum authors.
    if [[ "$MINIMUM_AUTHORS_SET" == false ]] && (( ${#remaining_positional[@]} > 0 )); then
        MINIMUM_AUTHORS="${remaining_positional[0]}"
        remaining_positional=("${remaining_positional[@]:1}")
    fi

    # Slot 3: maximum prefix length.
    if [[ "$MAX_PREFIX_LENGTH_SET" == false ]] && (( ${#remaining_positional[@]} > 0 )); then
        MAX_PREFIX_LENGTH="${remaining_positional[0]}"
        remaining_positional=("${remaining_positional[@]:1}")
    fi

    if (( ${#remaining_positional[@]} > 0 )); then
        echo "Error: Too many positional arguments." >&2
        usage
        exit 1
    fi

    # Apply defaults for the optional values.
    [[ -n "$MINIMUM_AUTHORS" ]] || MINIMUM_AUTHORS="$DEFAULT_MINIMUM_AUTHORS"
    [[ -n "$MAX_PREFIX_LENGTH" ]] || MAX_PREFIX_LENGTH="$DEFAULT_MAX_PREFIX_LENGTH"
    [[ -n "$DEBUG_MODE" ]] || DEBUG_MODE="$DEFAULT_DEBUG_MODE"
    [[ -n "$OUTPUT_FORMAT" ]] || OUTPUT_FORMAT="$DEFAULT_OUTPUT_FORMAT"
    [[ -n "$CLEAN_RUN" ]] || CLEAN_RUN="$DEFAULT_CLEAN_RUN"
}

# -----------------------------------------------------------------------------
# read_and_sort_authors
#
# Load INPUT_FILE into SORTED_AUTHORS.
#
# Pipeline stages, in order:
#   1. tr -d '\r'   -- strip Windows CR characters (CRLF -> LF).
#   2. grep -v '^$' -- drop blank lines.
#   3. sort         -- sort alphabetically; identical prefixes become
#                      adjacent, which the range-based walker depends on.
#
# The pipeline writes into a global via "mapfile", which is far faster than
# appending to an array inside a shell loop.
#
# LC_ALL=C (byte order) is deliberate: locale collation is case-insensitive
# in many environments, so "В" and "в" sort adjacent to each other, breaking
# the contiguity of same-prefix runs and producing both duplicate and missing
# directories.  UTF-8 byte order is a strict, deterministic total order, so
# every prefix occupies one contiguous run and the range walker is exact.  A
# pleasant side effect: C-collation sort is faster than locale-aware sort.
# -----------------------------------------------------------------------------
read_and_sort_authors() {
    mapfile -t SORTED_AUTHORS < <(
        tr -d '\r' < "$INPUT_FILE" |
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
# prepare_output_directory
#
# Create ROOT_DIRECTORY if needed and change into it.  The first line of the
# generated script is the "cd" that anchors every following "mkdir -p".
# -----------------------------------------------------------------------------
prepare_output_directory() {
    if [[ "$CLEAN_RUN" == "ON" ]]; then
        # Safety net: never let an empty, absolute-root, or home directory be
        # wiped by a typo in -r or the ROOT_DIRECTORY environment variable.
        case "$ROOT_DIRECTORY" in
            ""|"/"|"//"|"$HOME"|"$HOME"/*)
                echo "Error: refusing to clean dangerous path '$ROOT_DIRECTORY'." >&2
                exit 1
                ;;
        esac

        # Destroy and rebuild: remove the old tree, then recreate the root
        # empty so the emitted "mkdir -p" commands build a pristine hierarchy.
        rm -rf -- "$ROOT_DIRECTORY"

        # The generated script must destroy and rebuild the root too when it
        # is run, so it leads with the same wipe + recreate + cd trio.  The
        # rm must come before the cd: after "rm -rf <root>" the shell's
        # current directory is a deleted inode, so the script recreates the
        # root first and only then changes into it.
        echo "rm -rf $ROOT_DIRECTORY"
        echo "mkdir -p $ROOT_DIRECTORY"
    fi

    mkdir -p "$ROOT_DIRECTORY"

    if ! cd "$ROOT_DIRECTORY"; then
        echo "Error: Unable to change directory to '$ROOT_DIRECTORY'." >&2
        exit 1
    fi

    echo "cd $ROOT_DIRECTORY"
}

# -----------------------------------------------------------------------------
# build_directory_path
#
# Convert a prefix into its slash-joined directory path.
#
# Arguments:
#   $1 - the prefix, e.g. "Абра"
#
# Output:
#   the path, e.g. "А/Аб/Абр/Абра" (every intermediate prefix becomes one
#   directory component, so "mkdir -p" can create the whole chain at once).
#
# The join is done with the array-expansion trick: setting IFS to "/" and
# expanding "${array[*]}" inserts the separator between elements.
# -----------------------------------------------------------------------------
build_directory_path() {
    local current_prefix="$1"
    local -a directory_components=()
    local prefix_length
    local IFS="/"

    for (( prefix_length = 1;
           prefix_length <= ${#current_prefix};
           prefix_length++ ))
    do
        directory_components+=("${current_prefix:0:prefix_length}")
    done

    printf '%s' "${directory_components[*]}"
}

# -----------------------------------------------------------------------------
# process_prefix
#
# Recursively walk one branch of the prefix tree and print the "mkdir -p"
# commands for its deepest valid directories.
#
# Arguments:
#   $1 - current prefix, e.g. "Аб"
#   $2 - range_start: first index (inclusive) of SORTED_AUTHORS whose authors
#        start with the current prefix
#   $3 - range_end:   index just past the last such author (exclusive)
#
# Every author in [range_start, range_end) starts with the current prefix, so:
#   matching_author_count = range_end - range_start
#
# The function either:
#   - returns silently when the prefix has too few authors (branch dies), or
#   - prints the directory when the prefix is at maximum depth, or
#   - scans its range once, splits it into child sub-ranges by next
#     character, recurses into the valid ones (child runs whose next
#     character is a space are word boundaries and are skipped), and prints
#     its own directory only when no child was valid (it is then the
#     deepest valid directory).
# -----------------------------------------------------------------------------
process_prefix() {
    local current_prefix="$1"
    local range_start="$2"
    local range_end="$3"   # exclusive end of the contiguous author range

    local prefix_length=${#current_prefix}
    local matching_author_count=$(( range_end - range_start ))
    local has_valid_child=false

    local i                    # loop cursor over the author range
    local current_author
    local next_character       # the character following the prefix in an author
    local child_start child_end # indices delimiting one child sub-range
    local next_prefix

    # --- Prune invalid branches -------------------------------------------
    # Every descendant of this prefix can only match the same or fewer
    # authors.  Once the count drops below the minimum, no deeper prefix can
    # become valid again, so the branch is dead.
    if (( matching_author_count < MINIMUM_AUTHORS )); then
        return
    fi

    if [[ "$DEBUG_MODE" == "ON" ]]; then
        printf "DEBUG: prefix='%-*s' authors=%4d\n" "$MAX_PREFIX_LENGTH" "$current_prefix" "$matching_author_count" >&2
    fi

    # --- Maximum depth reached ---------------------------------------------
    # The prefix cannot be extended further, so it is the deepest possible
    # valid directory of this branch.  Print it and stop.
    if (( prefix_length >= MAX_PREFIX_LENGTH )); then
        # A prefix may contain an apostrophe (e.g. "О'Брайен"), which is a
        # legal name byte but an awkward directory component.  Substitute it
        # with a caret so the emitted path stays shell- and filesystem-safe
        # ("mkdir -p О/О'" becomes "mkdir -p О/О^").
        echo "mkdir -p $(build_directory_path "${current_prefix//\'/^}")"
        return
    fi

    # --- Discover children in one pass over the range -----------------------
    # The range is sorted, so authors with the same next character are
    # adjacent.  Walk the range once: for each distinct next character, extend
    # the run to its end, then recurse if the resulting sub-range is valid.
    for (( i = range_start; i < range_end; )); do
        current_author="${SORTED_AUTHORS[i]}"

        # An author exactly equal to the prefix has no character after it and
        # therefore starts no child branch.  It still contributes to the
        # prefix's count, which is why the range includes it.
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

        # A space is a word boundary, never a directory level.  Authors like
        # "де Бальзак Оноре" share the prefix "де " (ending in a space); if
        # that child became a directory, build_directory_path would emit it
        # as a component with a trailing space ("д/де/де ").  Skip the
        # space run entirely: never descend past a word boundary, and don't
        # let it suppress the parent ("де") from being the deepest valid
        # directory.  The run was already consumed above, so the range walk
        # stays linear.
        if [[ "$next_character" == " " ]]; then
            continue
        fi

        next_prefix="${current_prefix}${next_character}"

        # Recurse only into valid children.  Invalid children are simply
        # skipped: their branch produces no directories.
        if (( child_end - child_start >= MINIMUM_AUTHORS )); then
            has_valid_child=true
            process_prefix "$next_prefix" "$child_start" "$child_end"
        fi
    done

    # --- Leaf of the branch -------------------------------------------------
    # No valid child means the current prefix is the deepest valid directory
    # here.  "mkdir -p" will create every parent above it automatically, so
    # this single command is sufficient.  Apostrophes are substituted with a
    # caret exactly as in the max-depth emission above.
    if [[ "$has_valid_child" == false ]]; then
        echo "mkdir -p $(build_directory_path "${current_prefix//\'/^}")"
    fi
}

# -----------------------------------------------------------------------------
# emit_mkdir_commands
#
# Drive the tree walk from the root level: split the whole sorted array into
# contiguous ranges by first character, then recurse into each range.
#
# Each root prefix is processed exactly once, even when dozens of authors
# share the same first character.
# -----------------------------------------------------------------------------
emit_mkdir_commands() {
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
# process_prefix_sql
#
# The SQL twin of process_prefix: same range walk, same pruning, same
# space-boundary rule -- but instead of printing "mkdir -p" only for the
# deepest valid directory of a branch, EVERY valid prefix becomes one node
# of the nested-set table.
#
# Arguments:
#   $1 - current prefix
#   $2 - range_start: first index (inclusive) of SORTED_AUTHORS matching it
#   $3 - range_end:   index just past the last such author (exclusive)
#
# Nested-set numbering uses a single depth-first counter (SQL_ORDER):
#   lft = ++SQL_ORDER when the node is entered (before its children)
#   rgt = ++SQL_ORDER when the node is exited  (after its children)
# A node without children therefore gets (lft, rgt) = (k, k+1).  The row is
# recorded as "path|lft|rgt" and emit_sql_commands sorts the rows by lft so
# parents always precede their descendants in the INSERT statement.
# -----------------------------------------------------------------------------
process_prefix_sql() {
    local current_prefix="$1"
    local range_start="$2"
    local range_end="$3"   # exclusive end of the contiguous author range

    local prefix_length=${#current_prefix}
    local matching_author_count=$(( range_end - range_start ))

    local i                    # loop cursor over the author range
    local current_author
    local next_character
    local child_start child_end
    local next_prefix
    local node_lft             # lft assigned on entry; rgt on exit below

    # --- Prune invalid branches -------------------------------------------
    if (( matching_author_count < MINIMUM_AUTHORS )); then
        return
    fi

    if [[ "$DEBUG_MODE" == "ON" ]]; then
        printf "DEBUG: sql prefix='%-*s' authors=%4d\n" "$MAX_PREFIX_LENGTH" "$current_prefix" "$matching_author_count" >&2
    fi

    # --- Enter the node ------------------------------------------------------
    node_lft=$(( ++SQL_ORDER ))

    # --- Discover children in one pass over the range -----------------------
    # At maximum depth the node cannot grow, so it is a leaf; otherwise scan
    # the range exactly like process_prefix does.
    if (( prefix_length < MAX_PREFIX_LENGTH )); then
        for (( i = range_start; i < range_end; )); do
            current_author="${SORTED_AUTHORS[i]}"

            # An author exactly equal to the prefix starts no child branch.
            if (( ${#current_author} <= prefix_length )); then
                (( i += 1 ))
                continue
            fi

            next_character="${current_author:prefix_length:1}"

            # Expand the run of identical next characters.
            child_start=$i
            (( i += 1 ))
            while (( i < range_end )); do
                if [[ "${SORTED_AUTHORS[i]:prefix_length:1}" != "$next_character" ]]; then
                    break
                fi
                (( i += 1 ))
            done
            child_end=$i

            # Space is a word boundary, never a directory level (same rule
            # and reasoning as process_prefix).
            if [[ "$next_character" == " " ]]; then
                continue
            fi

            next_prefix="${current_prefix}${next_character}"

            if (( child_end - child_start >= MINIMUM_AUTHORS )); then
                process_prefix_sql "$next_prefix" "$child_start" "$child_end"
            fi
        done
    fi

    # --- Exit the node -------------------------------------------------------
    # rgt closes the subtree; only now is the row complete.
    SQL_ROWS+=("$(build_directory_path "$current_prefix")|$node_lft|$(( ++SQL_ORDER ))")
}

# -----------------------------------------------------------------------------
# emit_sql_commands
#
# Drive the same prefix-tree walk as emit_mkdir_commands, but render the tree
# as SQL for the dictionary_nested_set table (word, lft, rgt):
#
#   DROP TABLE IF EXISTS ...
#   CREATE TABLE ... ENGINE=MYISAM COLLATE=utf8_general_ci;
#   START TRANSACTION;
#   INSERT INTO ... VALUES
#       ('А', 1, 6),
#       ...
#       ('д/де', 8, 9);
#   COMMIT;
#
# The table definition mirrors the repository's build_sql_nested_set.sh so
# the two tools produce interchangeable output.  Each row's word is the full
# slash-joined directory path of the node; single quotes are escaped by
# doubling.  Rows are sorted by lft so parents always precede children.
# -----------------------------------------------------------------------------
emit_sql_commands() {
    local i=0
    local root_prefix
    local child_start child_end
    local -a sorted_rows=()
    local row word lft rgt clean_word
    local total_rows

    # --- Table header --------------------------------------------------------
    echo 'DROP TABLE IF EXISTS `dictionary_nested_set`;'
    echo 'CREATE TABLE `dictionary_nested_set` ('
    echo '    `id` INT AUTO_INCREMENT PRIMARY KEY,'
    echo '    `word` VARCHAR(255) NOT NULL,'
    echo '    `lft` INT NOT NULL,'
    echo '    `rgt` INT NOT NULL,'
    echo '    INDEX `idx_lft_rgt` (`lft`, `rgt`)'
    echo ') ENGINE=MYISAM COLLATE=utf8_general_ci;'
    echo ''
    echo 'START TRANSACTION;'

    # --- Walk the tree, filling SQL_ROWS -------------------------------------
    SQL_ORDER=0
    SQL_ROWS=()

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
        process_prefix_sql "$root_prefix" "$child_start" "$child_end"
    done

    # --- Rows (parents before children: sort by lft) -------------------------
    mapfile -t sorted_rows < <(printf '%s\n' "${SQL_ROWS[@]}" | sort -t'|' -k2,2n)
    total_rows=${#sorted_rows[@]}

    if (( total_rows > 0 )); then
        echo 'INSERT INTO `dictionary_nested_set` (`word`, `lft`, `rgt`) VALUES'

        for (( i = 0; i < total_rows; i++ )); do
            IFS='|' read -r word lft rgt <<< "${sorted_rows[i]}"

            # Escape single quotes for the SQL string literal.
            clean_word="${word//\'/\'\'}"

            if (( i + 1 == total_rows )); then
                echo "    ('$clean_word', $lft, $rgt);"
            else
                echo "    ('$clean_word', $lft, $rgt),"
            fi
        done
    fi

    echo 'COMMIT;'
}

# -----------------------------------------------------------------------------
# main
#
# Program entry point:
#   1. Parse the arguments (positional, named options, or a mixture).
#   2. Validate the input file and the numeric arguments.
#   3. Load and sort the author list.
#   4. Prepare (and cd into) the output root directory.
#   5. Walk the prefix tree and print the "mkdir -p" commands.
# -----------------------------------------------------------------------------
main() {
    parse_arguments "$@"

    # --- Input file must be given, exist, and be a regular file -------------
    if [[ -z "$INPUT_FILE" ]]; then
        echo "Error: No input file given (use a positional argument or -i/--input-file)." >&2
        usage
        exit 1
    fi

    if [[ ! -f "$INPUT_FILE" ]]; then
        echo "Error: File '$INPUT_FILE' not found." >&2
        exit 1
    fi

    # --- Numeric arguments must be positive integers -------------------------
    # The regex rejects 0, negatives, empty strings, and non-numeric input.
    if [[ ! "$MINIMUM_AUTHORS" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: minimum_authors must be a positive integer, got '$MINIMUM_AUTHORS'." >&2
        exit 1
    fi

    if [[ ! "$MAX_PREFIX_LENGTH" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: maximum_prefix_length must be a positive integer, got '$MAX_PREFIX_LENGTH'." >&2
        exit 1
    fi

    # --- Output format and debug mode must be valid --------------------------
    # Values are accepted case-insensitively and normalized to upper case.
    case "${OUTPUT_FORMAT^^}" in
        SHELL|SQL)
            OUTPUT_FORMAT="${OUTPUT_FORMAT^^}"
            ;;
        *)
            echo "Error: format must be SHELL or SQL, got '$OUTPUT_FORMAT'." >&2
            usage
            ;;
    esac

    case "${DEBUG_MODE^^}" in
        ON|OFF)
            DEBUG_MODE="${DEBUG_MODE^^}"
            ;;
        *)
            echo "Error: debugger must be ON or OFF, got '$DEBUG_MODE'." >&2
            usage
            ;;
    esac

    case "${CLEAN_RUN^^}" in
        ON|OFF)
            CLEAN_RUN="${CLEAN_RUN^^}"
            ;;
        *)
            echo "Error: clean-run must be ON or OFF, got '$CLEAN_RUN'." >&2
            usage
            ;;
    esac

    # --- Root directory must resolve to something sane -----------------------
    if [[ -z "$ROOT_DIRECTORY" ]]; then
        echo "Error: root directory must not be empty." >&2
        usage
        exit 1
    fi

    # --- Run the pipeline ----------------------------------------------------
    read_and_sort_authors

    if [[ "$OUTPUT_FORMAT" == "SHELL" ]]; then
        prepare_output_directory
        emit_mkdir_commands
    else
        emit_sql_commands
    fi

    if [[ "$DEBUG_MODE" == "ON" ]]; then
        printf 'DEBUG: elapsed time: %02d:%02d:%02d (%ds)\n' \
            "$((SECONDS / 3600))" "$(((SECONDS % 3600) / 60))" "$((SECONDS % 60))" "$SECONDS" >&2
    fi
}

###############################################################################
# ENTRY POINT
###############################################################################

main "$@"
