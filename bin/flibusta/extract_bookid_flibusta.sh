#!/usr/bin/env bash
#
# bin/flibusta/extract_bookid_flibusta.sh
#
# Version:       0.4.0
# Last updated:  2026-09-13
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Stage-1 Flibusta extraction by BOOKID FILENUMBER.  For each FileNumber:
#   find the range archive f.<TYPE>-START-END.zip whose inclusive window
#   contains the number under FLIBUSTA_SOURCE_DIR, resolve the member, and
#   extract only that member into FB2_OUTPUT_DIR (atomic write; the archives
#   are never copied).  Type chain: fb2 | usr | both (fb2 first, usr falls
#   back).  This is the only family tool that handles usr.
#
#   Dual-mode (v0.4.0, mirroring place_flibusta_book.sh 0.3.0):
#     - script mode: run the file directly - identical CLI/behavior to 0.3.x;
#     - library mode: source with FB2_LIB_ONLY=1 and drive the batch through
#       fb2_parse_args / fb2_run (both RETURN codes, never exit), so an
#       orchestrator (run_round.sh) can embed stage 1 in-process.  fb2_run
#       delivers per-number results through the FB2_DELIVERED[] array:
#       "number<TAB>status<TAB>detail" with status delivered|skipped|failed.
#
#   Rename history: was extract_flibusta_fb2.sh (v0.2.1); renamed when the
#   author/series siblings joined (the name no longer described the scope).
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/flibusta/extract_bookid_flibusta.sh [options] FILE_NUMBER... | --from-file LIST
#
#   Options:
#     -t, --type fb2|usr|both   archive family [default: fb2]
#     -f, --from-file LIST      numbers from LIST (one per line; blanks,
#                               CR, BOM, #-comments tolerated)
#     -s, --source-dir DIR      archive source root [default: /mnt/x/flibusta]
#     -o, --output-dir DIR      extraction target [default: /mnt/c/Backup_Go7/ToLoad]
#         --force               re-extract even if the output exists
#     -n, --dry-run             resolve every item; extract nothing
#     -d, --debug               verbose diagnostics on stderr
#     -h, --help                show this help
#     -v, --version             print version and exit
#
#   Environment (all optional; also settable in config/flibusta_extract.conf):
#     FLIBUSTA_SOURCE_DIR       archive source root
#     FB2_OUTPUT_DIR            extraction target
#   A custom config path can be supplied via FLIBUSTA_EXTRACT_CONF_FILE.
#
# -----------------------------------------------------------------------------
# ALGORITHM
# -----------------------------------------------------------------------------
#   Build a per-type range index once per run (f.<TYPE>-*.zip parsed from
#   their names, overlapping ranges resolve to the lowest START) -> per
#   number: validate -> find the archive whose window contains it ->
#   resolve the member (fb2: exact "<N>.fb2"; usr: prefix "<N>.") ->
#   skip when the output exists (unless --force) -> extract atomically.
#   In --type both the fb2 miss falls back to usr; a number counts as
#   delivered when ANY type in the chain delivers.
# -----------------------------------------------------------------------------

# Source guard: a file sourced twice (script + library round-trip, or a
# re-source) must not redeclare readonly globals.
if [[ -n "${_ETL_EXTRACT_FLIBUSTA_SH:-}" ]]; then
    return 0
fi
_ETL_EXTRACT_FLIBUSTA_SH=1

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
# The constant is PREFIXED (FB2_): an orchestrator sources several stage
# libraries in one process, and a bare readonly SCRIPT_VERSION would collide
# with the second tool's declaration (readonly re-assignment aborts the
# shell).  cli_try_global's -v/-h path still reports correctly because the
# lib contract "a SCRIPT_VERSION variable" is satisfied through the alias
# below (lib/cli.sh reads SCRIPT_VERSION_ALIAS when SCRIPT_VERSION is unset).
# shellcheck disable=SC2155  # sed+head pipeline cannot fail; masking not a concern
readonly FB2_SCRIPT_VERSION="$(sed -n 's/^# Version:[[:space:]]*//p' "${BASH_SOURCE[0]}" | head -n 1)"
readonly FB2_CLI_INVOCATION="bin/flibusta/extract_bookid_flibusta.sh"
# shellcheck disable=SC2034  # lib/cli.sh aliases, consumed there
SCRIPT_VERSION="$FB2_SCRIPT_VERSION"        # lib/cli.sh alias (NOT readonly)
# shellcheck disable=SC2034  # lib/cli.sh -v fallback, read before the alias lands
SCRIPT_VERSION_ALIAS="$FB2_SCRIPT_VERSION"  # consumed when -v runs pre-alias
# shellcheck disable=SC2034  # lib/cli.sh aliases, consumed there
CLI_INVOCATION="$FB2_CLI_INVOCATION"        # lib/cli.sh alias (NOT readonly)

# shellcheck disable=SC2034  # read by lib/logging.sh at runtime
DEBUG="${DEBUG:-0}"

# --- configuration (flag > env > config file > built-in default) ----------------
FLIBUSTA_SOURCE_DIR="${FLIBUSTA_SOURCE_DIR:-}"
FB2_OUTPUT_DIR="${FB2_OUTPUT_DIR:-}"
FB2_REQ_TYPE="fb2"
FB2_FROM_FILE=""
FB2_FORCE=0
DRY_RUN=0

CONF_FILE="${FLIBUSTA_EXTRACT_CONF_FILE:-$PROJECT_ROOT/config/flibusta_extract.conf}"
# shellcheck source=../../config/flibusta_extract.conf
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

# --- run parameters (set by fb2_parse_args, consumed by fb2_run) -----------------
FB2_POSITIONAL=()
FB2_DELIVERED=()          # per-number result rows: "number<TAB>status<TAB>detail"

# --- help -------------------------------------------------------------------------
fb2_print_help() {
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

# print_help: the name lib/cli.sh's cli_try_global looks up for -h/--help
# (house hook - must keep this exact name).
print_help() { fb2_print_help; }

# --- arg parsing ------------------------------------------------------------------
# Sets FB2_POSITIONAL / FB2_FROM_FILE / FB2_REQ_TYPE / FB2_FORCE / DRY_RUN.
# Returns 2 on a usage error (reason already on stderr); does NOT exit, so
# library callers keep control.  -h/-v exit 0 (script-mode flags).
fb2_parse_args() {
    FB2_POSITIONAL=()
    FB2_FROM_FILE=""
    FB2_REQ_TYPE="fb2"
    FB2_FORCE=0
    DRY_RUN=0
    while (( $# > 0 )); do
        case "$1" in
            -t|--type)
                [[ $# -ge 2 ]] || { echo "Error: $1 needs a TYPE argument" >&2; return 2; }
                FB2_REQ_TYPE="$2"; shift 2 ;;
            --type=*) FB2_REQ_TYPE="${1#*=}"; shift ;;
            -f|--from-file)
                [[ $# -ge 2 ]] || { echo "Error: $1 needs a FILE argument" >&2; return 2; }
                FB2_FROM_FILE="$2"; shift 2 ;;
            --from-file=*) FB2_FROM_FILE="${1#*=}"; shift ;;
            -s|--source-dir)
                [[ $# -ge 2 ]] || { echo "Error: $1 needs a DIR argument" >&2; return 2; }
                FLIBUSTA_SOURCE_DIR="$2"; shift 2 ;;
            --source-dir=*) FLIBUSTA_SOURCE_DIR="${1#*=}"; shift ;;
            -o|--output-dir)
                [[ $# -ge 2 ]] || { echo "Error: $1 needs a DIR argument" >&2; return 2; }
                FB2_OUTPUT_DIR="$2"; shift 2 ;;
            --output-dir=*) FB2_OUTPUT_DIR="${1#*=}"; shift ;;
            --force) FB2_FORCE=1; shift ;;
            -n|--dry-run) DRY_RUN=1; shift ;;
            -d|--debug)
                # shellcheck disable=SC2034  # read by lib/logging.sh at runtime
                DEBUG=1; shift ;;
            -h|--help)    print_help; exit 0 ;;
            -v|--version) cli_print_version "$FB2_CLI_INVOCATION" "$FB2_SCRIPT_VERSION"; exit 0 ;;
            -*) echo "Error: unknown option '$1'" >&2; echo "Try '$FB2_CLI_INVOCATION --help'." >&2; return 2 ;;
            *)
                FB2_POSITIONAL+=("$1"); shift ;;
        esac
    done
    return 0
}

# --- work-list assembly -------------------------------------------------------------
# fb2_assemble_numbers -> fills FB2_NUMBERS[] from positionals + --from-file.
# Returns 1 when the list ends up empty (caller decides how to report).
fb2_assemble_numbers() {
    FB2_NUMBERS=()
    local n
    for n in "${FB2_POSITIONAL[@]}"; do
        FB2_NUMBERS+=("$n")
    done
    if [[ -n "$FB2_FROM_FILE" ]]; then
        local -a file_numbers=()
        mapfile -t file_numbers < <(flb_read_numbers "$FB2_FROM_FILE")
        for n in "${file_numbers[@]}"; do
            FB2_NUMBERS+=("$n")
        done
    fi
    (( ${#FB2_NUMBERS[@]} > 0 )) || return 1
    return 0
}

# --- validation ----------------------------------------------------------------------
# fb2_validate_run -> 0 ok; 1 with the reason already logged (library callers
# keep control; script mode surfaces it as a run failure).
fb2_validate_run() {
    require_command unzip
    if [[ -z "$FLIBUSTA_SOURCE_DIR" ]]; then
        log "error: FLIBUSTA_SOURCE_DIR is empty (set it or use --source-dir)"; return 1
    fi
    if [[ -z "$FB2_OUTPUT_DIR" ]]; then
        log "error: FB2_OUTPUT_DIR is empty (set it or use --output-dir)"; return 1
    fi
    if [[ ! -d "$FLIBUSTA_SOURCE_DIR" ]]; then
        log "error: source directory does not exist: $FLIBUSTA_SOURCE_DIR"; return 1
    fi
    local type
    for type in "${FB2_TYPES[@]}"; do
        flb_index_load "$type" \
            || { log "error: no f.$type-*.zip archives under $FLIBUSTA_SOURCE_DIR"; return 1; }
    done
    return 0
}

# --- batch execution ------------------------------------------------------------------
# fb2_run -> 0 all delivered/skipped; 1 when anything failed.  Never exits
# (library contract): script mode maps the return to the process exit code.
# Per-number results land in FB2_DELIVERED[] as "number<TAB>status<TAB>detail"
# (status: delivered | skipped | failed; detail: the output path or the reason).
fb2_run() {
    case "$FB2_REQ_TYPE" in
        fb2)  FB2_TYPES=(fb2) ;;
        usr)  FB2_TYPES=(usr) ;;
        both) FB2_TYPES=(fb2 usr) ;;
        *) echo "Error: --type must be fb2, usr or both (got '$FB2_REQ_TYPE')" >&2; return 2 ;;
    esac

    fb2_validate_run || return 1
    fb2_assemble_numbers || { print_help; return 2; }

    FB2_DELIVERED=()
    local fail_count=0 ok_count=0 skip_count=0
    local file_number type archive member output_file reason
    declare -a failures=()

    local is_batch=0
    (( ${#FB2_NUMBERS[@]} > 1 )) && is_batch=1

    mkdir -p "$FB2_OUTPUT_DIR"

    for file_number in "${FB2_NUMBERS[@]}"; do
        if ! flb_validate_number "$file_number"; then
            reason="invalid FileNumber (expected digits, greater than zero)"
            failures+=("$file_number: $reason")
            log_warn "$file_number: invalid FileNumber (expected digits, greater than zero)"
            FB2_DELIVERED+=("$(printf '%s\t%s\t%s' "$file_number" failed "$reason")")
            fail_count=$((fail_count + 1))
            continue
        fi

        local delivered=0
        local -a attempts=()

        for type in "${FB2_TYPES[@]}"; do
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

            if [[ -s "$output_file" ]] && (( ! FB2_FORCE )); then
                log_info "$file_number [$type]: output exists, skipping ($output_file)"
                ok_count=$((ok_count + 1))
                skip_count=$((skip_count + 1))
                FB2_DELIVERED+=("$(printf '%s\t%s\t%s' "$file_number" skipped "$output_file")")
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
                FB2_DELIVERED+=("$(printf '%s\t%s\t%s' "$file_number" delivered "$output_file")")
                delivered=1
                break
            fi

            if flb_extract "$archive" "$member" "$output_file"; then
                ok_count=$((ok_count + 1))
                FB2_DELIVERED+=("$(printf '%s\t%s\t%s' "$file_number" delivered "$output_file")")
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
            FB2_DELIVERED+=("$(printf '%s\t%s\t%s' "$file_number" failed "$reason")")
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
            local f
            for f in "${failures[@]}"; do
                log_error "$f"
            done
        fi
        return 1
    fi
    return 0
}

# --- script-mode entry point -----------------------------------------------------------
# fb2_main is the script-mode main(): leading global flags (-h/-v/--debug) go
# through lib/cli.sh, the rest through fb2_parse_args, then fb2_run.
# Exit codes: 0 ok, 1 run failure, 2 usage error (house CLI contract).
fb2_main() {
    cli_try_global "$@"
    local -a rest=()
    if (( CLI_REMAINING_COUNT > 0 )); then
        rest=("${@: $(( $# - CLI_REMAINING_COUNT + 1 ))}")
    fi
    fb2_parse_args "${rest[@]}" || return $?
    fb2_run || return $?
    return 0
}

# Script mode runs automatically UNLESS the file was sourced as a library
# (FB2_LIB_ONLY=1 before sourcing).  Evaluated once, at the bottom.
if [[ -z "${FB2_LIB_ONLY:-}" ]]; then
    fb2_main "$@" || exit $?
fi
