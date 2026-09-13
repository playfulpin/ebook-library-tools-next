#!/usr/bin/env bash
#
# bin/flibusta/extract_flibusta_fb2.sh
#
# Version:       0.2.0
# Last updated:  2026-09-13
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Stage-1 Flibusta extraction utility: given one or more Flibusta
#   FileNumbers, locate the range archive whose inclusive START..END window
#   contains each number, extract ONLY that number's member, and write it
#   atomically into the output directory.  The archives themselves are never
#   copied or unpacked wholesale.
#
#   Naming conventions handled (verified against /mnt/x/flibusta, 2026-09-13):
#     archive  f.fb2-<START>-<END>.zip   members <N>.fb2
#     archive  f.usr-<START>-<END>.zip   members <N>.<realext> (pdf, djvu,
#              epub, and double-suffixed .pdf.zip / .pdf.rar / .djvu.zip);
#              the OLDEST usr archives are fully title-named, so a given
#              number may legitimately have no member there
#     sparse   a number inside an archive's range may be absent from it
#              (members are not contiguous) - reported, never fatal to
#              the rest of a batch
#
#   For f.fb2 the member name is exactly <N>.fb2.  For f.usr the member is
#   resolved by listing the archive and prefix-matching "<N>." - the output
#   file keeps the member's real basename (a pdf stays .pdf; renaming would
#   mislabel the format).
#
#   No database access by design (stage 1): the future flow is
#   FileNumber -> DB lookup -> archive lookup -> extraction -> placement,
#   and only the middle steps exist today.  When the DB stage lands it must
#   go through lib/database.sh (Follow-It §8 hard boundary), never inline
#   mysql command lines.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/flibusta/extract_flibusta_fb2.sh [options] FILE_NUMBER...
#   ./bin/flibusta/extract_flibusta_fb2.sh [options] --from-file LIST
#
#   Options:
#       -t, --type TYPE         fb2 | usr | both          [default: fb2]
#                               both tries f.fb2-*, then f.usr-*
#       -f, --from-file LIST    read FileNumbers from LIST (one per line;
#                               blank lines, CR, BOM and #-comments are
#                               tolerated); usable alongside positionals
#       -s, --source-dir DIR    archive source root
#                               [default: /mnt/x/flibusta]
#       -o, --output-dir DIR    where extracted members are written
#                               [default: /mnt/c/Backup_Go7/ToLoad]
#           --force             re-extract even when the output file exists
#                               (default: existing non-empty outputs are
#                               skipped and reported)
#       -n, --dry-run           resolve every item, extract nothing
#       -d, --debug             verbose diagnostics on stderr
#       -h, --help              show this help
#       -v, --version           print version and exit
#
#   Environment (all optional; also settable in config/flibusta_fb2.conf):
#       FLIBUSTA_SOURCE_DIR     archive source root (as above)
#       FB2_OUTPUT_DIR          extraction target (as above)
#
#   Exit codes: 0 all items succeeded (or nothing to fail in dry-run),
#               1 at least one item failed (or single-item failure),
#               2 usage error.
#
# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
#   config/flibusta_fb2.conf provides defaults via house
#   VAR="${VAR:-default}" style; the environment and the -s/-o flags win.
#   A custom config path can be supplied via FLIBUSTA_FB2_CONF_FILE.
#
# -----------------------------------------------------------------------------
# ALGORITHM
# -----------------------------------------------------------------------------
#   Index: per requested type, the source dir is scanned ONCE into
#   parallel arrays (START/END/PATH) matching ^f\.<TYPE>-([0-9]+)-([0-9]+)\.zip$;
#   malformed names are ignored.  Lookup is a linear scan keeping the
#   lowest-START hit (deterministic under overlapping ranges; ambiguity
#   is reported in debug output).  Numbers compare 10#-normalized, so
#   zero-padded names never trigger octal.
#
#   Member resolution: `unzip -Z1` lists member names; fb2 requires the
#   exact "<N>.fb2", usr prefix-matches "<N>." and takes the first sorted
#   hit (extensions vary).  Extraction streams the single member via
#   `unzip -p` into a temp file next to the output (atomic mv); an empty
#   member is an error.
#
#   Batch semantics: every item is attempted independently; failures are
#   collected (status + reason) and summarized.  Exit 1 when anything
#   failed so orchestrators can react, even if most items succeeded.
# -----------------------------------------------------------------------------

set -Eeuo pipefail

# common_init resolves symlink-safe SCRIPT_DIR/PROJECT_ROOT at any bin/ depth,
# sources logging/cli/filesystem, and provides die/require_command.
# shellcheck source=../../lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"
common_init

# SCRIPT_VERSION is parsed from this file's own header (version-sync contract).
# shellcheck disable=SC2155  # sed+head pipeline cannot fail; masking not a concern
readonly SCRIPT_VERSION="$(sed -n 's/^# Version:[[:space:]]*//p' "$0" | head -n 1)"

# shellcheck disable=SC2034  # read by lib/logging.sh at runtime
DEBUG="${DEBUG:-0}"

# --- configuration (flag > env > config file > built-in default) ---------------
FLIBUSTA_SOURCE_DIR="${FLIBUSTA_SOURCE_DIR:-}"
FB2_OUTPUT_DIR="${FB2_OUTPUT_DIR:-}"
REQ_TYPE="fb2"
FROM_FILE=""
FORCE=0
DRY_RUN=0

CONF_FILE="${FLIBUSTA_FB2_CONF_FILE:-$PROJECT_ROOT/config/flibusta_fb2.conf}"
# shellcheck source=../../config/flibusta_fb2.conf
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

# --- help -----------------------------------------------------------------------
print_help() {
    cat >&2 <<'EOF'
Usage: extract_flibusta_fb2.sh [options] FILE_NUMBER... | --from-file LIST

Stage-1 Flibusta extraction: for each FileNumber, find the range archive
f.<TYPE>-START-END.zip whose window contains the number under
FLIBUSTA_SOURCE_DIR and extract only that number's member into
FB2_OUTPUT_DIR (atomic write; archives are never copied).

Members: fb2 archives hold <N>.fb2.  usr archives hold <N>.<realext>
(pdf/djvu/epub, sometimes .pdf.zip); the output keeps the member's real
basename.  A number inside a range may be absent from the archive
(sparse members) - reported per item, never fatal to the batch.

Options:
  -t, --type fb2|usr|both   archive family [default: fb2]; both tries
                            fb2 first, then usr
  -f, --from-file LIST      FileNumbers from LIST, one per line (blank
                            lines, CR, BOM, #-comments tolerated)
  -s, --source-dir DIR      archive source root [default: /mnt/x/flibusta]
  -o, --output-dir DIR      extraction target [default: /mnt/c/Backup_Go7/ToLoad]
      --force               re-extract even if the output already exists
  -n, --dry-run             resolve every item; extract nothing
  -d, --debug               verbose diagnostics on stderr
  -h, --help                show this help
  -v, --version             print version and exit

Exit codes: 0 all items ok, 1 any item failed, 2 usage error.

Environment (also settable in config/flibusta_fb2.conf):
  FLIBUSTA_SOURCE_DIR       archive source root
  FB2_OUTPUT_DIR            extraction target
EOF
}

# --- arg parsing ----------------------------------------------------------------
positional=()
while (( $# > 0 )); do
    case "$1" in
        -t|--type)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a TYPE argument" >&2; exit 2; }
            REQ_TYPE="$2"; shift 2 ;;
        --type=*) REQ_TYPE="${1#*=}"; shift ;;
        -f|--from-file)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a FILE argument" >&2; exit 2; }
            FROM_FILE="$2"; shift 2 ;;
        --from-file=*) FROM_FILE="${1#*=}"; shift ;;
        -s|--source-dir)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a DIR argument" >&2; exit 2; }
            FLIBUSTA_SOURCE_DIR="$2"; shift 2 ;;
        --source-dir=*) FLIBUSTA_SOURCE_DIR="${1#*=}"; shift ;;
        -o|--output-dir)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a DIR argument" >&2; exit 2; }
            FB2_OUTPUT_DIR="$2"; shift 2 ;;
        --output-dir=*) FB2_OUTPUT_DIR="${1#*=}"; shift ;;
        --force) FORCE=1; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -d|--debug)
            # shellcheck disable=SC2034  # read by lib/logging.sh at runtime
            DEBUG=1; shift ;;
        -h|--help)    print_help; exit 0 ;;
        -v|--version) echo "bin/flibusta/extract_flibusta_fb2.sh v$SCRIPT_VERSION"; exit 0 ;;
        -*) echo "Error: unknown option '$1'" >&2; echo "Try '$0 --help'." >&2; exit 2 ;;
        *)
            positional+=("$1"); shift ;;
    esac
done

# --- lib: extraction primitives (inlined; lib/ stays domain-free per §4) --------
# House rule (Follow-It §4, books_merge precedent): domain logic lives with
# its only consumer, not in lib/.  Extract these back out only when a second
# consumer appears.

# fb2_validate_number NUMBER -> 0/1; digits only, greater than zero.
fb2_validate_number() { # $1 = candidate FileNumber
    local file_number="$1"
    [[ "$file_number" =~ ^[0-9]+$ ]] || return 1
    (( 10#$file_number > 0 ))
}

# --- per-type range index (built once per run, scanned per number) ---------------
# Fixed two-family design: no dynamic arrays needed.  FB2_* for f.fb2-*,
# USR_* for f.usr-*; *_INDEXED guards one-time construction.
FB2_INDEXED=0 USR_INDEXED=0
FB2_STARTS=() FB2_ENDS=() FB2_PATHS=()
USR_STARTS=() USR_ENDS=() USR_PATHS=()

# fb2_index_load TYPE -> fills the type's parallel arrays; rc 1 when the
# source dir holds no archives of that type at all.
fb2_index_load() { # $1 = fb2|usr
    local type="$1"
    local indexed_var="${type^^}_INDEXED"
    (( ${!indexed_var} == 1 )) && return 0

    local -a starts=() ends=() paths=()
    local archive base_name
    shopt -s nullglob
    local -a matches=("$FLIBUSTA_SOURCE_DIR"/f."$type"-*.zip)
    shopt -u nullglob

    for archive in "${matches[@]}"; do
        base_name="$(basename "$archive")"
        if [[ "$base_name" =~ ^f\.$type-([0-9]+)-([0-9]+)\.zip$ ]]; then
            starts+=("${BASH_REMATCH[1]}")
            ends+=("${BASH_REMATCH[2]}")
            paths+=("$archive")
        else
            debug "ignored malformed archive name: $base_name"
        fi
    done

    if (( ${#paths[@]} == 0 )); then
        return 1
    fi

    case "$type" in
        fb2) FB2_STARTS=("${starts[@]}") FB2_ENDS=("${ends[@]}") FB2_PATHS=("${paths[@]}") FB2_INDEXED=1 ;;
        usr) USR_STARTS=("${starts[@]}") USR_ENDS=("${ends[@]}") USR_PATHS=("${paths[@]}") USR_INDEXED=1 ;;
    esac
    debug "index $type: ${#paths[@]} archive(s)"
    return 0
}

# fb2_find_archive NUMBER TYPE -> archive path on stdout; rc 1 when none
# matches.  Overlapping ranges resolve to the lowest START (deterministic).
fb2_find_archive() { # $1 = FileNumber, $2 = fb2|usr
    local file_number="$1" type="$2"
    fb2_index_load "$type" || return 1

    local -n _starts="${type^^}_STARTS"
    local -n _ends="${type^^}_ENDS"
    local -n _paths="${type^^}_PATHS"

    local i best=-1 best_start=""
    for (( i = 0; i < ${#_paths[@]}; i++ )); do
        if (( 10#${_starts[i]} <= 10#$file_number && 10#$file_number <= 10#${_ends[i]} )); then
            if [[ -z "$best_start" ]] || (( 10#${_starts[i]} < 10#$best_start )); then
                best=$i
                best_start="${_starts[i]}"
            fi
        fi
    done
    (( best >= 0 )) || return 1
    printf '%s\n' "${_paths[best]}"
    return 0
}

# fb2_resolve_member ARCHIVE NUMBER TYPE -> member name on stdout; rc 1 when
# the archive holds no member for the number.  fb2: exact "<N>.fb2".
# usr: prefix "<N>." with any real extension (pdf, djvu, .pdf.zip, ...).
fb2_resolve_member() { # $1 = archive, $2 = FileNumber, $3 = fb2|usr
    local archive="$1" file_number="$2" type="$3"
    local member
    member="$(unzip -Z1 -- "$archive" 2>/dev/null | tr -d '\r' \
        | { if [[ "$type" == fb2 ]]; then
                grep -Fx "${file_number}.fb2"
            else
                grep -m1 -E "^${file_number}\."
            fi; })" || return 1
    [[ -n "$member" ]] || return 1
    printf '%s\n' "$member"
    return 0
}

# fb2_extract ARCHIVE MEMBER OUTPUT_FILE -> atomic member extraction.
# Streams the single member via `unzip -p` into a temp file next to the
# output, then mv; an empty member is an error.
fb2_extract() { # $1 = archive, $2 = member name, $3 = output file
    local archive="$1" member="$2" output_file="$3"
    local temp_file="${output_file}.tmp.$$"

    if ! unzip -p -q -- "$archive" "$member" > "$temp_file"; then
        rm -f -- "$temp_file"
        die "failed to extract '$member' from '$archive'"
    fi

    if [[ ! -s "$temp_file" ]]; then
        rm -f -- "$temp_file"
        die "extracted file is empty: '$member'"
    fi

    mv -- "$temp_file" "$output_file"
}

# fb2_read_numbers FILE -> numbers on stdout (BOM/CR/blank/#-comment safe).
fb2_read_numbers() { # $1 = list file
    local file="$1"
    sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -e 's/#.*//' "$file" \
        | grep -v '^[[:space:]]*$' || true
}

# --- main -----------------------------------------------------------------------
# assemble the work list: positionals + --from-file
declare -a numbers=()
for n in "${positional[@]}"; do
    numbers+=("$n")
done
if [[ -n "$FROM_FILE" ]]; then
    mapfile -t file_numbers < <(fb2_read_numbers "$FROM_FILE")
    for n in "${file_numbers[@]}"; do
        numbers+=("$n")
    done
fi

if (( ${#numbers[@]} == 0 )); then
    print_help
    exit 2
fi

# types to attempt per number, in order
case "$REQ_TYPE" in
    fb2)  types=(fb2) ;;
    usr)  types=(usr) ;;
    both) types=(fb2 usr) ;;
    *) echo "Error: --type must be fb2, usr or both (got '$REQ_TYPE')" >&2; exit 2 ;;
esac

# --- validation -----------------------------------------------------------------
require_command unzip
[[ -n "$FLIBUSTA_SOURCE_DIR" ]] || die "FLIBUSTA_SOURCE_DIR is empty (set it or use --source-dir)"
[[ -n "$FB2_OUTPUT_DIR" ]] || die "FB2_OUTPUT_DIR is empty (set it or use --output-dir)"
fs_require_dir "$FLIBUSTA_SOURCE_DIR" "source directory"

for type in "${types[@]}"; do
    fb2_index_load "$type" \
        || die "no f.$type-*.zip archives under $FLIBUSTA_SOURCE_DIR"
done

# --- batch execution -------------------------------------------------------------
# Each number is attempted through the requested type chain (fb2 / usr /
# fb2-then-usr).  A number counts as delivered when ANY type in the chain
# resolves and extracts (or finds the output already present); a type miss
# inside the chain is debug-noted, not a failure.  A failure is recorded only
# when NO type delivered the number - so 'both' behaves as a fallback, and a
# usr hit after a sparse fb2 member still exits 0.
fail_count=0
ok_count=0
skip_count=0
declare -a failures=()

is_batch=0
total_numbers=${#numbers[@]}
(( total_numbers > 1 )) && is_batch=1

mkdir -p "$FB2_OUTPUT_DIR"

for file_number in "${numbers[@]}"; do
    if ! fb2_validate_number "$file_number"; then
        failures+=("$file_number: invalid FileNumber (expected digits, greater than zero)")
        log_warn "$file_number: invalid FileNumber (expected digits, greater than zero)"
        fail_count=$((fail_count + 1))
        continue
    fi

    delivered=0
    declare -a attempts=()

    for type in "${types[@]}"; do
        if ! archive="$(fb2_find_archive "$file_number" "$type")"; then
            attempts+=("$type: no archive contains the number")
            debug "$file_number [$type]: no archive contains the number"
            continue
        fi

        if ! member="$(fb2_resolve_member "$archive" "$file_number" "$type")"; then
            attempts+=("$type: member not present in $(basename "$archive")")
            debug "$file_number [$type]: member $file_number.* not present in $(basename "$archive") (sparse members)"
            continue
        fi

        output_file="$FB2_OUTPUT_DIR/$member"

        if [[ -s "$output_file" ]] && (( ! FORCE )); then
            log_info "$file_number [$type]: output exists, skipping ($output_file)"
            ok_count=$((ok_count + 1))
            skip_count=$((skip_count + 1))
            delivered=1
            break
        fi

        if (( is_batch )); then
            log_info "$file_number [$type]: $archive -> $member"
        else
            log_info "archive: $archive"
            log_info "member : $member"
            log_info "output : $output_file"
        fi

        if (( DRY_RUN )); then
            ok_count=$((ok_count + 1))
            delivered=1
            break
        fi

        if fb2_extract "$archive" "$member" "$output_file"; then
            ok_count=$((ok_count + 1))
            delivered=1
            (( is_batch )) && log_info "$file_number [$type]: done -> $output_file"
            break
        else
            attempts+=("$type: extraction failed from $(basename "$archive")")
        fi
    done

    if (( ! delivered )); then
        reason="${attempts[*]:-no source matched}"
        failures+=("$file_number: $reason")
        log_warn "$file_number: not delivered ($reason)"
        fail_count=$((fail_count + 1))
    fi
done

# --- summary ---------------------------------------------------------------------
if (( DRY_RUN )); then
    log_info "dry-run: $ok_count item(s) resolvable, $fail_count failed, $skip_count existing; no files were written"
else
    log_info "summary: $ok_count delivered, $skip_count of them skipped (exist), $fail_count failed"
fi

if (( fail_count > 0 )); then
    if (( is_batch )); then
        for f in "${failures[@]}"; do
            log_error "$f"
        done
    fi
    exit 1
fi
exit 0
