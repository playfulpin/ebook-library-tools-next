#!/usr/bin/env bash
#
# bin/flibusta/extract_bookid_flibusta.sh
#
# Version:       0.3.1
# Last updated:  2026-09-13
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Stage-1 Flibusta extraction by BOOKID FILENUMBER: given one or more
#   Flibusta FileNumbers (the plain number, no extension), locate the range
#   archive f.<TYPE>-START-END.zip whose inclusive window contains the
#   number under FLIBUSTA_SOURCE_DIR and extract only that number's member
#   into FB2_OUTPUT_DIR (atomic write; archives are never copied).
#
#   Members: fb2 archives hold <N>.fb2.  usr archives hold <N>.<realext>
#   (pdf/djvu/epub, sometimes .pdf.zip); the output keeps the member's real
#   basename.  A number inside a range may be absent from the archive
#   (sparse members) - reported per item, never fatal to the batch.
#
#   Rename history: was extract_flibusta_fb2.sh (v0.2.1); renamed when the
#   extractor family grew to three members sharing the same primitives
#   (bin/flibusta/_flibusta_extract_common.sh) - this is the by-FileNumber
#   member of the family and the only one with usr support.
#
#   All primitives (range index, member resolution, atomic extraction)
#   come from _flibusta_extract_common.sh; this tool owns only its CLI
#   (parsing, help, version) and the batch loop with its summary.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/flibusta/extract_bookid_flibusta.sh [options] FILE_NUMBER...
#   ./bin/flibusta/extract_bookid_flibusta.sh [options] --from-file LIST
#
#   Options:
#       -t, --type TYPE         fb2 | usr | both          [default: fb2]
#       -f, --from-file LIST    FileNumbers from LIST (one per line; blank
#                               lines, CR, BOM and #-comments tolerated)
#       -s, --source-dir DIR    archive source root
#                               [default: /mnt/x/flibusta]
#       -o, --output-dir DIR    extraction target
#                               [default: /mnt/c/Backup_Go7/ToLoad]
#           --force             re-extract even if the output already exists
#       -n, --dry-run           resolve every item; extract nothing
#       -d, --debug             verbose diagnostics on stderr
#       -h, --help              show this help
#       -v, --version           print version and exit
#
#   Environment (all optional; also settable in config/flibusta_extract.conf):
#       FLIBUSTA_SOURCE_DIR, FB2_OUTPUT_DIR
#
#   Exit codes: 0 all items delivered, 1 at least one failed, 2 usage error.
#
# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
#   config/flibusta_extract.conf provides defaults via house
#   VAR="${VAR:-default}" style; the environment and the flags win.
#   A custom config path can be supplied via FLIBUSTA_EXTRACT_CONF_FILE.
#
# -----------------------------------------------------------------------------
# ALGORITHM
# -----------------------------------------------------------------------------
#   Build a per-type range index once per run (f.<TYPE>-*.zip parsed from
#   their names, overlapping ranges resolve to the lowest START) -> per
#   number: validate -> find the archive whose window contains it ->
#   resolve the member (fb2: exact "<N>.fb2"; usr: prefix "<N>.", whole
#   listing consumed in bash - see _flibusta_extract_common.sh for the
#   SIGPIPE note) -> skip when the output exists (unless --force) ->
#   extract atomically.  In --type both the fb2 miss falls back to usr;
#   a number counts as delivered when ANY type in the chain delivers.
# -----------------------------------------------------------------------------

set -Eeuo pipefail

# common_init resolves symlink-safe SCRIPT_DIR/PROJECT_ROOT at any bin/ depth,
# sources logging/cli/filesystem, and provides die/require_command.
# shellcheck source=../../lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"
common_init

# Shared family primitives (range index / member resolution / extraction).
# Intra-group include - allowed by the layer gate for bin/<group>/_*.sh.
# shellcheck source=_flibusta_extract_common.sh
source "$SCRIPT_DIR/_flibusta_extract_common.sh"

# SCRIPT_VERSION is parsed from this file's own header (version-sync contract).
# shellcheck disable=SC2155  # sed+head pipeline cannot fail; masking not a concern
readonly SCRIPT_VERSION="$(sed -n 's/^# Version:[[:space:]]*//p' "${BASH_SOURCE[0]}" | head -n 1)"
readonly CLI_INVOCATION="bin/flibusta/extract_bookid_flibusta.sh"

# shellcheck disable=SC2034  # read by lib/logging.sh at runtime
DEBUG="${DEBUG:-0}"

# --- configuration (flag > env > config file > built-in default) ----------------
FLIBUSTA_SOURCE_DIR="${FLIBUSTA_SOURCE_DIR:-}"
FB2_OUTPUT_DIR="${FB2_OUTPUT_DIR:-}"
REQ_TYPE="fb2"
FROM_FILE=""
FORCE=0
DRY_RUN=0

CONF_FILE="${FLIBUSTA_EXTRACT_CONF_FILE:-$PROJECT_ROOT/config/flibusta_extract.conf}"
# shellcheck source=../../config/flibusta_extract.conf
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

# --- help -----------------------------------------------------------------------
print_help() {
    cat >&2 <<'EOF'
Usage: extract_bookid_flibusta.sh [options] FILE_NUMBER... | --from-file LIST

Stage-1 Flibusta extraction by BOOKID FILENUMBER: for each FileNumber,
find the range archive f.<TYPE>-START-END.zip whose window contains the
number under FLIBUSTA_SOURCE_DIR and extract only that number's member
into FB2_OUTPUT_DIR (atomic write; archives are never copied).

Members: fb2 archives hold <N>.fb2.  usr archives hold <N>.<realext>
(pdf/djvu/epub, sometimes .pdf.zip); the output keeps the member's real
basename.  A number inside a range may be absent from the archive
(sparse members) - reported per item, never fatal to the batch.

Family: extract_bookid_flibusta.sh (this tool, by FileNumber, fb2+usr),
extract_author_flibusta.sh (by author name), extract_series_flibusta.sh
(by series name); the last two are fb2-only.

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

Environment (also settable in config/flibusta_extract.conf):
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
        -v|--version) echo "$CLI_INVOCATION v$SCRIPT_VERSION"; exit 0 ;;
        -*) echo "Error: unknown option '$1'" >&2; echo "Try '$0 --help'." >&2; exit 2 ;;
        *)
            positional+=("$1"); shift ;;
    esac
done

# --- assemble the work list: positionals + --from-file --------------------------
declare -a numbers=()
for n in "${positional[@]}"; do
    numbers+=("$n")
done
if [[ -n "$FROM_FILE" ]]; then
    mapfile -t file_numbers < <(flb_read_numbers "$FROM_FILE")
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
    flb_index_load "$type" \
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
    if ! flb_validate_number "$file_number"; then
        failures+=("$file_number: invalid FileNumber (expected digits, greater than zero)")
        log_warn "$file_number: invalid FileNumber (expected digits, greater than zero)"
        fail_count=$((fail_count + 1))
        continue
    fi

    delivered=0
    declare -a attempts=()

    for type in "${types[@]}"; do
        archive=""
        if flb_find_archive "$file_number" "$type"; then
            archive="$FLB_ARCHIVE"
        else
            attempts+=("$type: no archive contains the number")
            debug "$file_number [$type]: no archive contains the number"
            continue
        fi

        member=""
        if flb_resolve_member "$archive" "$file_number" "$type"; then
            member="$FLB_MEMBER"
        else
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

        if flb_extract "$archive" "$member" "$output_file"; then
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
