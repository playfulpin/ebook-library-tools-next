#!/usr/bin/env bash
# shellcheck disable=SC2034  # run parameters are consumed inside the SOURCED
# stage libraries (fb2_parse_args/fb2_run, place_run); shellcheck cannot see
# cross-file usage, so every RR_/FB2_/PLACE_ assignment false-positives here.
#
# bin/flibusta/run_round.sh
#
# Version:       0.1.0
# Last updated:  2026-09-13
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   One-command Flibusta round: given a list of FileNumbers (or explicit
#   numbers), run stage 1 (extract the members from the range archives) and
#   stage 2 (resolve each number through the catalog and place it as
#   ROOT_LOAD/<Author>[/<Series>]/<NN - Title>.zip) in a SINGLE process -
#   both stage tools are sourced as libraries (the *_LIB_ONLY=1 contract,
#   sanctioned for run_*.sh orchestrators by check_layers v1.2.0).
#
#   Why one process: no env-var plumbing between tools, one MariaDB
#   lifecycle (place_run manages its own), one summary, and a per-number
#   TSV round report that joins BOTH stages' outcomes - the retry workflow
#   is "grep the failed rows, re-run with --from-file".
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/flibusta/run_round.sh [options] FILE_NUMBER... | --from-file LIST
#
#   Options:
#     -f, --from-file LIST      FileNumbers from LIST, one per line (blank
#                               lines, CR, BOM, #-comments tolerated)
#     -t, --type fb2|usr|both   stage-1 archive family [default: both;
#                               fb2 first, usr fallback]
#     -s, --source-dir DIR      stage-1 archive root [default: /mnt/x/flibusta]
#     -i, --input-dir DIR       stage-1 output / stage-2 input
#                               [default: /mnt/c/Backup_Go7/ToLoad]
#     -r, --root-load DIR       stage-2 placement root [default: /mnt/c/Backup_Go7/ToLoad]
#         --report-dir DIR      round TSV report directory
#                               [default: /mnt/c/Backup_Go7/merge-reports]
#     -n, --dry-run             both stages resolve; nothing is written
#         --extract-only        stop after stage 1 (no placement)
#     -d, --debug               verbose diagnostics on stderr
#     -h, --help                show this help
#     -v, --version             print version and exit
#
#   Exit codes: 0 every number placed (or extracted, with --extract-only),
#               1 at least one number failed or was not placed,
#               2 usage error.
#
# -----------------------------------------------------------------------------
# ROUND REPORT
# -----------------------------------------------------------------------------
#   One TSV per run under --report-dir:
#     run_round_<ts>.tsv
#   Header: processed_at  file_number  status  stage1_output  target_zip  reason
#   Status semantics (a number's round status is the WORST of its stages):
#     extracted      stage 1 delivered, --extract-only ended the round
#     placed         both stages delivered (the file the app will see)
#     skipped        stage 2 found the target already present
#     failed-stage1  stage 1 could not deliver (reason from stage 1)
#     failed-stage2  stage 1 delivered but placement failed (reason from stage 2)
#
#   Retry workflow: pull the file_number column of failed-* rows into a
#   list and re-run with --from-file (stage 2 skips existing targets, so
#   re-running a whole round is safe and cheap).
# -----------------------------------------------------------------------------

set -Eeuo pipefail

# common_init resolves symlink-safe SCRIPT_DIR/PROJECT_ROOT at any bin/ depth,
# sources logging/cli/filesystem, and provides die/require_command.
# shellcheck source=../../lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"
common_init

# --- stage tools, sourced as libraries (layer-gate v1.2.0 orchestrator rule) ---
# Order matters: both set run-parameter globals; there is no overlap except
# DRY_RUN, which is deliberately SHARED so one flag drives both stages.
# shellcheck disable=SC2034  # *_LIB_ONLY is consumed by the sourced file's guard
FB2_LIB_ONLY=1
# shellcheck source=extract_bookid_flibusta.sh
source "$SCRIPT_DIR/extract_bookid_flibusta.sh"
# shellcheck disable=SC2034
PLACE_LIB_ONLY=1
# shellcheck source=place_flibusta_book.sh
source "$SCRIPT_DIR/place_flibusta_book.sh"

# SCRIPT_VERSION is parsed from this file's own header (version-sync contract).
# shellcheck disable=SC2155  # sed+head pipeline cannot fail; masking not a concern
readonly SCRIPT_VERSION="$(sed -n 's/^# Version:[[:space:]]*//p' "${BASH_SOURCE[0]}" | head -n 1)"
readonly CLI_INVOCATION="bin/flibusta/run_round.sh"

# shellcheck disable=SC2034  # read by lib/logging.sh at runtime
DEBUG="${DEBUG:-0}"

# --- configuration ---------------------------------------------------------------
# Stage configs (flibusta_extract.conf / flibusta_place.conf) were already
# sourced by the stage tools; this file adds only the round-level default.
ROUND_REPORT_DIR="${ROUND_REPORT_DIR:-}"

# --- run parameters ----------------------------------------------------------------
RR_FROM_FILE=""
RR_REQ_TYPE="both"
RR_EXTRACT_ONLY=0
RR_POSITIONAL=()

# --- help ----------------------------------------------------------------------------
rr_print_help() {
    cat >&2 <<'EOF'
Usage: run_round.sh [options] FILE_NUMBER... | --from-file LIST

One-command Flibusta round: stage 1 (extract_bookid) pulls each number's
member out of the range archives, stage 2 (place_flibusta_book) resolves
it through the flibusta catalog and places it as
ROOT_LOAD/<FullName>[/<Series>]/<NN - Title>.zip - both stages in one
process, one summary, one joined TSV round report.

Options:
  -f, --from-file LIST      FileNumbers from LIST, one per line (blank
                            lines, CR, BOM, #-comments tolerated)
  -t, --type fb2|usr|both   stage-1 archive family [default: both]
  -s, --source-dir DIR      stage-1 archive root [default: /mnt/x/flibusta]
  -i, --input-dir DIR       stage-1 output / stage-2 input
                            [default: /mnt/c/Backup_Go7/ToLoad]
  -r, --root-load DIR       stage-2 placement root
                            [default: /mnt/c/Backup_Go7/ToLoad]
      --report-dir DIR      round TSV report directory
                            [default: /mnt/c/Backup_Go7/merge-reports]
  -n, --dry-run             both stages resolve; nothing is written
      --extract-only        stop after stage 1 (no placement)
  -d, --debug               verbose diagnostics on stderr
  -h, --help                show this help
  -v, --version             print version and exit

Exit codes: 0 every number placed (or extracted, with --extract-only),
1 at least one failed, 2 usage error.

Round report (run_round_<ts>.tsv): processed_at, file_number, status
(extracted | placed | skipped | failed-stage1 | failed-stage2),
stage1_output, target_zip, reason.  Retry = failed-* rows -> --from-file.
EOF
}

# print_help: the name lib/cli.sh's cli_try_global looks up for -h/--help
# (house hook - must keep this exact name).
print_help() { rr_print_help; }

# --- arg parsing -----------------------------------------------------------------------
# Sets RR_* run parameters; returns 2 on usage error; -h/-v exit 0 (script flags).
rr_parse_args() {
    RR_POSITIONAL=()
    RR_FROM_FILE=""
    RR_REQ_TYPE="both"
    RR_EXTRACT_ONLY=0
    while (( $# > 0 )); do
        case "$1" in
            -t|--type)
                [[ $# -ge 2 ]] || { echo "Error: $1 needs a TYPE argument" >&2; return 2; }
                RR_REQ_TYPE="$2"; shift 2 ;;
            --type=*) RR_REQ_TYPE="${1#*=}"; shift ;;
            -f|--from-file)
                [[ $# -ge 2 ]] || { echo "Error: $1 needs a FILE argument" >&2; return 2; }
                RR_FROM_FILE="$2"; shift 2 ;;
            --from-file=*) RR_FROM_FILE="${1#*=}"; shift ;;
            -s|--source-dir)
                [[ $# -ge 2 ]] || { echo "Error: $1 needs a DIR argument" >&2; return 2; }
                FLIBUSTA_SOURCE_DIR="$2"; shift 2 ;;
            --source-dir=*) FLIBUSTA_SOURCE_DIR="${1#*=}"; shift ;;
            -i|--input-dir)
                [[ $# -ge 2 ]] || { echo "Error: $1 needs a DIR argument" >&2; return 2; }
                FB2_OUTPUT_DIR="$2"; PLACE_INPUT_DIR="$2"; shift 2 ;;
            --input-dir=*) FB2_OUTPUT_DIR="${1#*=}"; PLACE_INPUT_DIR="${1#*=}"; shift ;;
            -r|--root-load)
                [[ $# -ge 2 ]] || { echo "Error: $1 needs a DIR argument" >&2; return 2; }
                ROOT_LOAD="$2"; shift 2 ;;
            --root-load=*) ROOT_LOAD="${1#*=}"; shift ;;
            --report-dir)
                [[ $# -ge 2 ]] || { echo "Error: $1 needs a DIR argument" >&2; return 2; }
                ROUND_REPORT_DIR="$2"; PLACE_REPORT_DIR="$2"; shift 2 ;;
            --report-dir=*) ROUND_REPORT_DIR="${1#*=}"; PLACE_REPORT_DIR="${1#*=}"; shift ;;
            -n|--dry-run) DRY_RUN=1; shift ;;
            --extract-only) RR_EXTRACT_ONLY=1; shift ;;
            -d|--debug)
                # shellcheck disable=SC2034  # read by lib/logging.sh at runtime
                DEBUG=1; shift ;;
            -h|--help)    print_help; exit 0 ;;
            -v|--version) echo "$CLI_INVOCATION v$SCRIPT_VERSION"; exit 0 ;;
            -*) echo "Error: unknown option '$1'" >&2; echo "Try '$CLI_INVOCATION --help'." >&2; return 2 ;;
            *)
                RR_POSITIONAL+=("$1"); shift ;;
        esac
    done
    return 0
}

# --- work-list assembly ------------------------------------------------------------------
rr_assemble_numbers() {
    RR_NUMBERS=()
    local n
    for n in "${RR_POSITIONAL[@]}"; do
        RR_NUMBERS+=("$n")
    done
    if [[ -n "$RR_FROM_FILE" ]]; then
        local -a file_numbers=()
        mapfile -t file_numbers < <(flb_read_numbers "$RR_FROM_FILE")
        for n in "${file_numbers[@]}"; do
            RR_NUMBERS+=("$n")
        done
    fi
    (( ${#RR_NUMBERS[@]} > 0 )) || return 1
    return 0
}

# --- round report ------------------------------------------------------------------------
declare -a RR_REPORT_ROWS=()
rr_push_report() { # number status stage1_output target_zip reason
    RR_REPORT_ROWS+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s' \
        "$(timestamp_now)" "$1" "$2" "$3" "$4" "$5")")
}

rr_write_report() { # $1 = report directory
    local dir="$1" ts file
    ts="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$dir"
    file="$dir/run_round_$ts.tsv"
    {
        printf 'processed_at\tfile_number\tstatus\tstage1_output\ttarget_zip\treason\n'
        printf '%s\n' "${RR_REPORT_ROWS[@]}"
    } > "$file"
    printf '%s\n' "$file"
}

# --- stage-1 row parsing -------------------------------------------------------------------
# FB2_DELIVERED rows are "number<TAB>status<TAB>detail".
rr_stage1_lookup() { # $1 = number; sets RR_S1_STATUS / RR_S1_DETAIL
    local n="$1" row
    RR_S1_STATUS="missing" RR_S1_DETAIL="-"
    for row in "${FB2_DELIVERED[@]}"; do
        if [[ "${row%%$'\t'*}" == "$n" ]]; then
            RR_S1_STATUS="$(printf '%s' "$row" | cut -f2)"
            RR_S1_DETAIL="$(printf '%s' "$row" | cut -f3)"
            return 0
        fi
    done
    return 0
}

# --- round execution -------------------------------------------------------------------------
# rr_run -> 0 when every number ended placed/skipped (or extracted, with
# --extract-only); 1 otherwise.  Never exits (library-style for symmetry).
rr_run() {
    if (( RR_EXTRACT_ONLY )); then
        PLACE_INPUT_DIR="/nonexistent-extract-only"   # stage 2 must not run
    fi

    # ---- stage 1: extract ---------------------------------------------------------------
    log_info "round: stage 1 (extract) - ${#RR_NUMBERS[@]} number(s), type=$RR_REQ_TYPE"
    if (( DRY_RUN )); then
        log_info "round: dry-run - no files will be written in either stage"
    fi

    FB2_REQ_TYPE="$RR_REQ_TYPE"
    FB2_FORCE=0   # a round never re-extracts over existing stage-1 outputs
    FB2_POSITIONAL=("${RR_NUMBERS[@]}")
    FB2_FROM_FILE=""
    # DRY_RUN is shared by contract (rr_parse_args sets it once); the stage
    # libs' parse functions would reset it to 0, but they never run here -
    # the orchestrator feeds the parameter globals directly.
    fb2_run || true   # per-number failures are joined into the round report below
    fb2_rc=$?

    if (( RR_EXTRACT_ONLY )); then
        local n status detail placed_total=0 failed_total=0
        for n in "${RR_NUMBERS[@]}"; do
            rr_stage1_lookup "$n"
            case "$RR_S1_STATUS" in
                delivered|skipped)
                    rr_push_report "$n" extracted "$RR_S1_DETAIL" "-" "-"
                    placed_total=$((placed_total + 1)) ;;
                *)
                    rr_push_report "$n" failed-stage1 "-" "-" "$RR_S1_DETAIL"
                    failed_total=$((failed_total + 1)) ;;
            esac
        done
        local report_file
        report_file="$(rr_write_report "${ROUND_REPORT_DIR:-$PLACE_REPORT_DIR}")"
        log_info "round summary (extract-only): $placed_total extracted, $failed_total failed"
        log_info "report: $report_file"
        return $(( failed_total > 0 ? 1 : 0 ))
    fi

    # ---- stage 2: place ------------------------------------------------------------------
    # Stage-2 input = stage-1 output dir (already aligned via --input-dir).
    # The stage gets the same numbers via its own parameter globals, its own
    # MariaDB lifecycle (place_run's EXIT trap is installed and removed
    # inside the call), and its per-number outcomes come from
    # PLACE_REPORT_ROWS (processed_at, number, bookid, status, target, reason).
    log_info "round: stage 2 (place)"
    PLACE_POSITIONAL=("${RR_NUMBERS[@]}")
    PLACE_FROM_FILE=""
    PLACE_FORCE=0
    place_run || true
    place_rc=$?

    # ---- join the two stages into the round report -----------------------------------------
    local n status detail target_zip reason placed_total=0 skipped_total=0 failed_total=0
    local prow p_status p_detail p_target
    for n in "${RR_NUMBERS[@]}"; do
        rr_stage1_lookup "$n"
        p_status="missing"; p_detail="-"; p_target="-"
        # PLACE_REPORT_ROWS layout: processed_at, file_number, bookid, status,
        # target, reason -> match on FIELD 2 (field 1 is the timestamp).
        for prow in "${PLACE_REPORT_ROWS[@]:-}"; do
            if [[ "$(printf '%s' "$prow" | cut -f2)" == "$n" ]]; then
                p_status="$(printf '%s' "$prow" | cut -f4)"
                p_target="$(printf '%s' "$prow" | cut -f5)"
                p_detail="$(printf '%s' "$prow" | cut -f6)"
                break
            fi
        done
        # stage-1 deliverable = the file stage 2 consumed
        detail="$RR_S1_DETAIL"
        case "$RR_S1_STATUS" in
            missing|failed)
                rr_push_report "$n" failed-stage1 "-" "$p_target" "$RR_S1_DETAIL"
                failed_total=$((failed_total + 1))
                ;;
            skipped)
                # delivered before but target absent -> stage 2 tells the truth
                case "$p_status" in
                    placed)   rr_push_report "$n" placed "$detail" "$p_target" "-"
                              placed_total=$((placed_total + 1)) ;;
                    skipped)  rr_push_report "$n" skipped "$detail" "$p_target" "already placed"
                              skipped_total=$((skipped_total + 1)) ;;
                    would-place) rr_push_report "$n" placed "$detail" "$p_target" "dry run: nothing was written"
                              placed_total=$((placed_total + 1)) ;;
                    would-skip)  rr_push_report "$n" skipped "$detail" "$p_target" "already placed (dry run)"
                              skipped_total=$((skipped_total + 1)) ;;
                    *)        rr_push_report "$n" failed-stage2 "$detail" "$p_target" "$p_detail"
                              failed_total=$((failed_total + 1)) ;;
                esac
                ;;
            delivered)
                case "$p_status" in
                    placed)      rr_push_report "$n" placed "$detail" "$p_target" "-"
                                 placed_total=$((placed_total + 1)) ;;
                    would-place) rr_push_report "$n" placed "$detail" "$p_target" "dry run: nothing was written"
                                 placed_total=$((placed_total + 1)) ;;
                    skipped)     rr_push_report "$n" skipped "$detail" "$p_target" "already placed"
                                 skipped_total=$((skipped_total + 1)) ;;
                    would-skip)  rr_push_report "$n" skipped "$detail" "$p_target" "already placed (dry run)"
                                 skipped_total=$((skipped_total + 1)) ;;
                    *)           rr_push_report "$n" failed-stage2 "$detail" "$p_target" "$p_detail"
                                 failed_total=$((failed_total + 1)) ;;
                esac
                ;;
        esac
    done

    # ---- summary ------------------------------------------------------------------------------
    local report_file
    report_file="$(rr_write_report "$ROUND_REPORT_DIR")"
    if (( DRY_RUN )); then
        log_info "round summary (dry-run): $placed_total would-place, $skipped_total would-skip, $failed_total failed; nothing was written"
    else
        log_info "round summary: $placed_total placed, $skipped_total skipped (exist), $failed_total failed"
    fi
    log_info "report: $report_file"

    (( failed_total > 0 )) && return 1
    return 0
}

# --- script-mode entry point ------------------------------------------------------------------
rr_main() {
    cli_try_global "$@"
    local -a rest=()
    if (( CLI_REMAINING_COUNT > 0 )); then
        rest=("${@: $(( $# - CLI_REMAINING_COUNT + 1 ))}")
    fi
    rr_parse_args "${rest[@]}" || return $?

    rr_assemble_numbers || { print_help; return 2; }

    if [[ -z "$ROUND_REPORT_DIR" ]]; then
        log "error: report directory is empty (set it or use --report-dir)"; return 2
    fi
    require_command unzip
    require_command zip

    rr_run || return $?
    return 0
}

# Script mode runs automatically UNLESS sourced as a library (RR_LIB_ONLY=1).
if [[ -z "${RR_LIB_ONLY:-}" ]]; then
    rr_main "$@" || exit $?
fi
