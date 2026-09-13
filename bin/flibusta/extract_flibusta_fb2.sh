#!/usr/bin/env bash
#
# bin/flibusta/extract_flibusta_fb2.sh
#
# Version:       0.1.0
# Last updated:  2026-09-13
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Stage-1 Flibusta extraction utility: given a Flibusta FileNumber, locate
#   the range archive f.fb2-START-END.zip under FLIBUSTA_SOURCE_DIR whose
#   START..END window contains the number, extract ONLY the member
#   "<FileNumber>.fb2" from it, and write it atomically into FB2_OUTPUT_DIR.
#   The archive itself is never copied or unpacked wholesale.
#
#   Naming convention handled:
#     archive  f.fb2-<START>-<END>.zip   (numeric ranges, inclusive)
#     member   <FileNumber>.fb2
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
#   ./bin/flibusta/extract_flibusta_fb2.sh [options] FILE_NUMBER
#
#   Options:
#       -s, --source-dir DIR    archive source root
#                               [default: /mnt/x/flibusta]
#       -o, --output-dir DIR    where the extracted .fb2 is written
#                               [default: /mnt/c/Backup_Go7/ToLoad]
#       -n, --dry-run           resolve the archive and member, extract nothing
#       -d, --debug             verbose diagnostics on stderr
#       -h, --help              show this help
#       -v, --version           print version and exit
#
#   Environment (all optional; also settable in config/flibusta_fb2.conf):
#       FLIBUSTA_SOURCE_DIR     archive source root (as above)
#       FB2_OUTPUT_DIR          extraction target (as above)
#
#   Exit codes: 0 success, 1 operational failure, 2 usage error.
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
#   Range match: every f.fb2-*.zip in the source dir is matched against
#   ^f\.fb2-([0-9]+)-([0-9]+)\.zip$ and the first archive whose inclusive
#   [START, END] window contains FileNumber (10#-normalized decimal) wins.
#   Ranges are expected to be disjoint; on ambiguity the lowest START wins
#   (files are iterated in glob order).
#
#   Extraction: `unzip -p` streams the single member to a temp file next to
#   the output (atomic mv); an empty member is treated as an error, not a
#   success.
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

# --- configuration (env > config file > built-in default) ----------------------
FLIBUSTA_SOURCE_DIR="${FLIBUSTA_SOURCE_DIR:-}"
FB2_OUTPUT_DIR="${FB2_OUTPUT_DIR:-}"
DRY_RUN=0

CONF_FILE="${FLIBUSTA_FB2_CONF_FILE:-$PROJECT_ROOT/config/flibusta_fb2.conf}"
# shellcheck source=../../config/flibusta_fb2.conf
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

# --- help -----------------------------------------------------------------------
print_help() {
    cat >&2 <<'EOF'
Usage: extract_flibusta_fb2.sh [options] FILE_NUMBER

Stage-1 Flibusta extraction: find the range archive
f.fb2-START-END.zip whose window contains FILE_NUMBER under
FLIBUSTA_SOURCE_DIR and extract only the member FILE_NUMBER.fb2 into
FB2_OUTPUT_DIR (atomic write; the archive is never copied).

Options:
  -s, --source-dir DIR    archive source root [default: /mnt/x/flibusta]
  -o, --output-dir DIR    extraction target [default: /mnt/c/Backup_Go7/ToLoad]
  -n, --dry-run           resolve archive + member; extract nothing
  -d, --debug             verbose diagnostics on stderr
  -h, --help              show this help
  -v, --version           print version and exit

Exit codes: 0 success, 1 operational failure, 2 usage error.

Environment (also settable in config/flibusta_fb2.conf):
  FLIBUSTA_SOURCE_DIR     archive source root
  FB2_OUTPUT_DIR          extraction target
EOF
}

# --- arg parsing ----------------------------------------------------------------
positional=()
while (( $# > 0 )); do
    case "$1" in
        -s|--source-dir)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a DIR argument" >&2; exit 2; }
            FLIBUSTA_SOURCE_DIR="$2"; shift 2 ;;
        --source-dir=*) FLIBUSTA_SOURCE_DIR="${1#*=}"; shift ;;
        -o|--output-dir)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a DIR argument" >&2; exit 2; }
            FB2_OUTPUT_DIR="$2"; shift 2 ;;
        --output-dir=*) FB2_OUTPUT_DIR="${1#*=}"; shift ;;
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

# fb2_find_archive NUMBER -> archive path on stdout; rc 1 when none matches.
fb2_find_archive() { # $1 = FileNumber
    local file_number="$1"
    local archive base_name start_number end_number
    local -a candidates=()

    shopt -s nullglob
    local -a matches=("$FLIBUSTA_SOURCE_DIR"/f.fb2-*.zip)
    shopt -u nullglob

    for archive in "${matches[@]}"; do
        base_name="$(basename "$archive")"
        if [[ "$base_name" =~ ^f\.fb2-([0-9]+)-([0-9]+)\.zip$ ]]; then
            start_number="${BASH_REMATCH[1]}"
            end_number="${BASH_REMATCH[2]}"
            if (( 10#$start_number <= 10#$file_number && 10#$file_number <= 10#$end_number )); then
                candidates+=("$archive")
            fi
        fi
    done

    # Disjoint ranges -> one candidate; overlapping ranges -> lowest START
    # wins (deterministic), the ambiguity is reported in debug output.
    (( ${#candidates[@]} == 0 )) && return 1
    if (( ${#candidates[@]} > 1 )); then
        debug "ambiguous range match (${#candidates[@]} archives); lowest START wins"
    fi
    printf '%s\n' "${candidates[0]}"
    return 0
}

# fb2_extract ARCHIVE FILE_NUMBER OUTPUT_FILE -> atomic member extraction.
# Streams the single member via `unzip -p` into a temp file next to the
# output, then mv; an empty member is an error.
fb2_extract() { # $1 = archive, $2 = FileNumber, $3 = output file
    local archive="$1" file_number="$2" output_file="$3"
    local member="${file_number}.fb2"
    local temp_file="${output_file}.tmp.$$"

    if ! unzip -p "$archive" "$member" > "$temp_file"; then
        rm -f -- "$temp_file"
        die "failed to extract '$member' from '$archive'"
    fi

    if [[ ! -s "$temp_file" ]]; then
        rm -f -- "$temp_file"
        die "extracted file is empty: '$member'"
    fi

    mv -- "$temp_file" "$output_file"
}

# --- main -----------------------------------------------------------------------
file_number=""
output_file=""

if (( ${#positional[@]} > 1 )); then
    echo "Error: expected exactly one FILE_NUMBER, got ${#positional[@]}" >&2
    exit 2
fi
(( ${#positional[@]} == 1 )) || { print_help; exit 2; }
file_number="${positional[0]}"

# --- validation -----------------------------------------------------------------
if ! fb2_validate_number "$file_number"; then
    die "invalid FileNumber: '$file_number' (expected digits, greater than zero)"
fi
require_command unzip
[[ -n "$FLIBUSTA_SOURCE_DIR" ]] || die "FLIBUSTA_SOURCE_DIR is empty (set it or use --source-dir)"
[[ -n "$FB2_OUTPUT_DIR" ]] || die "FB2_OUTPUT_DIR is empty (set it or use --output-dir)"
fs_require_dir "$FLIBUSTA_SOURCE_DIR" "source directory"

# --- resolve --------------------------------------------------------------------
archive="$(fb2_find_archive "$file_number")" || die "no FB2 archive contains FileNumber $file_number"
output_file="$FB2_OUTPUT_DIR/${file_number}.fb2"

log_info "archive: $archive"
log_info "member : ${file_number}.fb2"
log_info "output : $output_file"

if (( DRY_RUN )); then
    log_info "dry-run: no files were written"
    exit 0
fi

# --- extract --------------------------------------------------------------------
mkdir -p "$FB2_OUTPUT_DIR"
fb2_extract "$archive" "$file_number" "$output_file"

log_info "done: $output_file"
exit 0
