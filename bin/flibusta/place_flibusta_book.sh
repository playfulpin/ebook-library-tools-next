#!/usr/bin/env bash
#
# bin/flibusta/place_flibusta_book.sh
#
# Version:       0.3.2
# Last updated:  2026-09-13
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Stage-2 Flibusta placement utility.  Takes one or more Flibusta
#   FileNumbers (the plain number, no extension), resolves each through the
#   'flibusta' catalog database to its canonical identity, and places the
#   file that stage 1 (extract_bookid_flibusta.sh) left in the input dir into
#   the library tree under the proper folder and file name:
#
#     ROOT_LOAD/<FullName>/<seqname>/<0><seqnum> - <title>.zip
#     (no series:  ROOT_LOAD/<FullName>/<title>.zip)
#
#   Catalog mapping (flibusta schema, ml* tables):
#     mlbook.filename  = FileNumber (no extension)  -> bookid, title
#     mlauthor         (by bookid)                  -> authorid
#                (several authors possible: LOWEST authorid decides,
#                 confirmed 2026-09-13 - deterministic placement)
#     mlauthorname     (by authorid)                -> FullName  (top folder)
#     mlseq            (by bookid)                  -> seqid, seqnum
#                (several series possible: LOWEST seqid decides)
#     mlseqname        (by seqid)                   -> seqname   (2nd folder)
#
#   Naming decisions (confirmed 2026-09-13):
#     seq prefix  two-digit zero-pad: 1 -> "01", 15 -> "15" (100 -> "100")
#     file type   the zip name DROPS the extension: whatever stage 1
#                 extracted (fb2, djvu, pdf.zip ...) becomes <name>.zip
#
#   Final step: the extracted file is compressed to "<name>.zip" IN the
#   target folder (zip stream written to a temp name, then atomic mv).
#   The stage-1 source file is TRASHED by default after a successful
#   placement (v0.2.0, live-test feedback); --keep-source retains it.
#   A failed placement never removes the source.
#
#   Every run writes a timestamped TSV report (one row per number:
#   processed_at, file_number, bookid, status, target_zip, reason) into
#   PLACE_REPORT_DIR - the persistent error/retry log the stderr-only
#   house logging does not provide.  Statuses: placed / skipped / failed;
#   in --dry-run: would-place / would-skip / failed.
#
#   Database access goes through lib/database.sh exclusively (Follow-It §8
#   hard boundary): no mysql command lines are built in this tool.  The
#   MariaDB lifecycle follows the house pattern: a stopped server is
#   started and stopped again on exit only when this script started it.
#   --dry-run still performs the lookups (it must, to resolve paths) but
#   writes nothing.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/flibusta/place_flibusta_book.sh [options] FILE_NUMBER...
#   ./bin/flibusta/place_flibusta_book.sh [options] --from-file LIST
#
#   Options:
#       -t, --type both         accepted for pipeline symmetry with stage 1;
#                               placement resolves through the catalog and
#                               the real file type is the extracted file's,
#                               so the flag only documents intent
#       -f, --from-file LIST    FileNumbers from LIST (one per line; blank
#                               lines, CR, BOM and #-comments tolerated)
#       -i, --input-dir DIR     where stage 1 left the extracted files
#                               [default: /mnt/c/Backup_Go7/ToLoad]
#       -r, --root-load DIR     library root for placed books
#                               [default: /mnt/c/Backup_Go7/ToLoad]
#           --db NAME           catalog database [default: flibusta]
#           --force             re-place even when the target zip exists
#           --keep-source       keep the extracted source file after a
#                               successful placement (default: trashed)
#           --rm-source         accepted for compatibility; removal is
#                               now the default (no-op)
#           --report-dir DIR    per-run TSV report directory
#                               [default: /mnt/c/Backup_Go7/merge-reports]
#       -n, --dry-run           resolve and print targets; write nothing
#       -d, --debug             verbose diagnostics on stderr
#       -h, --help              show this help
#       -v, --version           print version and exit
#
#   Environment (all optional; also settable in config/flibusta_place.conf):
#       ROOT_LOAD, PLACE_INPUT_DIR, FLIBUSTA_DB, PLACE_REPORT_DIR, plus
#       the MYSQL_* / MARIA_* contract of lib/database.sh +
#       lib/mariadb_lifecycle.sh.
#
#   Exit codes: 0 all numbers placed, 1 at least one failed, 2 usage error.
#
# -----------------------------------------------------------------------------
# LIBRARY USE (v0.3.0)
# -----------------------------------------------------------------------------
#   The file doubles as a sourceable library so orchestrators (a future
#   run_round.sh) can call stage 2 in-process:
#
#       PLACE_LIB_ONLY=1 \
#           source "$PROJECT_ROOT/bin/flibusta/place_flibusta_book.sh"
#       PLACE_FORCE=0 PLACE_KEEP_SOURCE=0
#       place_parse_args -n 811194 && place_run
#
#   API:
#       place_print_help            - usage text on stderr
#       place_parse_args ARGS...    - set the PLACE_* run parameters;
#                                     returns 2 on a usage error (prints
#                                     the reason; does NOT exit); -h/-v
#                                     exit 0 (script-mode convenience -
#                                     embedders should not pass them)
#       place_run                   - execute the batch; returns 1 when at
#                                     least one number failed, 0 on full
#                                     success; on hard configuration
#                                     errors it logs "error: ..." and
#                                     returns 1 (it does NOT exit, so an
#                                     embedder keeps control)
#       place_lookup NUMBER         - raw catalog row (TSV) on stdout
#       place_sanitize_name RAW     - Windows-safe path component
#       place_find_source N DIR     - stage-1 file path for number N
#       place_zip SRC DST           - single-file zip, atomic
#
#   Sourcing implications (documented, by design):
#     - the house `set -Eeuo pipefail` regime is enabled (via lib/common.sh);
#     - all run state lives in PLACE_* variables; config/env resolution
#       happens at source time (flag > env > config file);
#     - place_run installs its own EXIT cleanup trap for the MariaDB
#       lifecycle and removes it when done - a caller's pre-existing EXIT
#       trap is not preserved across the call.
#     - PLACE_LIB_ONLY=1 must be set BEFORE sourcing to suppress the
#       automatic script-mode run; the script-mode guard is evaluated once
#       at the bottom of the file.
#
# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
#   config/flibusta_place.conf provides defaults via house
#   VAR="${VAR:-default}" style; the environment and the flags win.
#   A custom config path can be supplied via FLIBUSTA_PLACE_CONF_FILE.
#
# -----------------------------------------------------------------------------
# ALGORITHM
# -----------------------------------------------------------------------------
#   Per number: validate (digits, > 0) -> find the extracted source file
#   (first sorted match of "<N>.*" in the input dir) -> single catalog
#   query (aggregated derived tables guarantee one row: MIN(authorid)
#   per bookid, MIN(seqid) per bookid) -> sanitize the title/FullName/
#   seqname into Windows-safe name components (\/:*?"<>| and control
#   characters become "_", trailing dots/spaces trimmed - the target
#   lives on NTFS via /mnt/c) -> build the target path -> skip when the
#   target zip already exists (unless --force) -> zip the source into a
#   temp file next to the target and mv.
#
#   Batch semantics: every number is attempted independently; failures
#   are collected and summarized; the run result is 1 when anything
#   failed.  Titles are expected tab-free (the TSV parse would shift on
#   an embedded tab); the catalog data has none - noted as a known
#   constraint.
# -----------------------------------------------------------------------------

# Source guard: a file sourced twice must not re-declare readonly globals.
if [[ -n "${_ETL_PLACE_FLIBUSTA_SH:-}" ]]; then
    return 0
fi
_ETL_PLACE_FLIBUSTA_SH=1

set -Eeuo pipefail

# common_init resolves symlink-safe SCRIPT_DIR/PROJECT_ROOT at any bin/ depth,
# sources logging/cli/filesystem, and provides die/require_command.
# shellcheck source=../../lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"
common_init

# SCRIPT_VERSION is parsed from this file's own header (version-sync contract).
# The constant is PREFIXED (PLACE_): run_round sources BOTH stage libraries in
# one process, and a bare readonly SCRIPT_VERSION would collide with stage 1's
# declaration (readonly re-assignment aborts the shell).  The unprefixed names
# stay as non-readonly ALIASES for lib/cli.sh (first writer wins; harmless
# because every library parses its own identical header contract).
# shellcheck disable=SC2155  # sed+head pipeline cannot fail; masking not a concern
readonly PLACE_SCRIPT_VERSION="$(sed -n 's/^# Version:[[:space:]]*//p' "${BASH_SOURCE[0]}" | head -n 1)"
readonly PLACE_CLI_INVOCATION="bin/flibusta/place_flibusta_book.sh"
[[ -n "${SCRIPT_VERSION:-}" ]] || SCRIPT_VERSION="$PLACE_SCRIPT_VERSION"
[[ -n "${CLI_INVOCATION:-}" ]] || CLI_INVOCATION="$PLACE_CLI_INVOCATION"

# shellcheck disable=SC2034  # read by lib/logging.sh at runtime
DEBUG="${DEBUG:-0}"

# --- shared libs: MariaDB lifecycle + the §8 database boundary ------------------
# shellcheck source=../../lib/mariadb_lifecycle.sh
source "$PROJECT_ROOT/lib/mariadb_lifecycle.sh"
# shellcheck source=../../lib/database.sh
source "$PROJECT_ROOT/lib/database.sh"

# --- configuration (flag > env > config file > built-in default) ----------------
# NOTE: initializers must be "${VAR:-}" (env-or-empty), NEVER "" — an empty
# assignment here would clobber the environment before the config's
# ${VAR:-default} fallback gets a chance to see it.
ROOT_LOAD="${ROOT_LOAD:-}"
PLACE_INPUT_DIR="${PLACE_INPUT_DIR:-}"
FLIBUSTA_DB="${FLIBUSTA_DB:-}"
PLACE_REPORT_DIR="${PLACE_REPORT_DIR:-}"

CONF_FILE="${FLIBUSTA_PLACE_CONF_FILE:-$PROJECT_ROOT/config/flibusta_place.conf}"
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=../../config/flibusta_place.conf
    source "$CONF_FILE"
fi

# --- run parameters (set by place_parse_args, consumed by place_run) ------------
PLACE_FROM_FILE=""
PLACE_FORCE=0
PLACE_KEEP_SOURCE=0
DRY_RUN=0                     # lifecycle-contract variable (read by mariadb_lifecycle)
PLACE_POSITIONAL=()

# --- help -----------------------------------------------------------------------
place_print_help() {
    cat >&2 <<'EOF'
Usage: place_flibusta_book.sh [options] FILE_NUMBER... | --from-file LIST

Stage-2 Flibusta placement: resolve each FileNumber through the catalog
(mlbook.filename -> bookid -> author/series), then zip the file stage 1
extracted into the library tree:

    ROOT_LOAD/<FullName>/<seqname>/<0><seqnum> - <title>.zip
    (no series: ROOT_LOAD/<FullName>/<title>.zip)

Folders come from mlauthorname.FullName (top) and mlseqname.seqname
(second).  The seq prefix is two-digit zero-padded (1 -> "01").  The
zip name drops the file extension (fb2/djvu/pdf.zip all become .zip).
Several authors/series resolve to the LOWEST authorid/seqid.

Options:
  -f, --from-file LIST    FileNumbers from LIST, one per line (blank
                          lines, CR, BOM, #-comments tolerated)
  -i, --input-dir DIR     stage-1 extraction output [default: /mnt/c/Backup_Go7/ToLoad]
  -r, --root-load DIR     library root [default: /mnt/c/Backup_Go7/ToLoad]
      --db NAME           catalog database [default: flibusta]
      --force             re-place even if the target zip exists
      --keep-source       keep the extracted source after placement
                          (default: it is trashed on success)
      --rm-source         accepted for compatibility; removal is now
                          the default (no-op)
      --report-dir DIR    per-run TSV report directory
                          [default: /mnt/c/Backup_Go7/merge-reports]
  -n, --dry-run           resolve and print targets; write nothing
                          (the lookups still hit the database)
  -d, --debug             verbose diagnostics on stderr
  -h, --help              show this help
  -v, --version           print version and exit

Exit codes: 0 all numbers placed, 1 any failed, 2 usage error.

Library use (v0.3.0):  PLACE_LIB_ONLY=1 source <this file>, then
place_parse_args ARGS... && place_run.  See the LIBRARY USE header section.

Environment (also settable in config/flibusta_place.conf):
  ROOT_LOAD               library root
  PLACE_INPUT_DIR         stage-1 extraction output
  FLIBUSTA_DB             catalog database
  PLACE_REPORT_DIR        per-run TSV report directory
  MYSQL_* / MARIA_*       database connection + lifecycle contract
EOF
}

# print_help: the name lib/cli.sh's cli_try_global looks up for -h/--help
# (house hook - must keep this exact name).
print_help() { place_print_help; }

# --- arg parsing ------------------------------------------------------------------
# Sets PLACE_POSITIONAL / PLACE_FROM_FILE / PLACE_FORCE / PLACE_KEEP_SOURCE /
# DRY_RUN.  Returns 2 on a usage error (reason already on stderr); does NOT
# exit, so library callers keep control.  -h/-v exit 0 (script-mode flags).
place_parse_args() {
    PLACE_POSITIONAL=()
    PLACE_FROM_FILE=""
    PLACE_FORCE=0
    PLACE_KEEP_SOURCE=0
    DRY_RUN=0
    while (( $# > 0 )); do
        case "$1" in
            -t|--type)                      # accepted, documented no-op (pipeline symmetry)
                [[ $# -ge 2 ]] || { echo "Error: $1 needs a TYPE argument" >&2; return 2; }
                shift 2 ;;
            --type=*) shift ;;
            -f|--from-file)
                [[ $# -ge 2 ]] || { echo "Error: $1 needs a FILE argument" >&2; return 2; }
                PLACE_FROM_FILE="$2"; shift 2 ;;
            --from-file=*) PLACE_FROM_FILE="${1#*=}"; shift ;;
            -i|--input-dir)
                [[ $# -ge 2 ]] || { echo "Error: $1 needs a DIR argument" >&2; return 2; }
                PLACE_INPUT_DIR="$2"; shift 2 ;;
            --input-dir=*) PLACE_INPUT_DIR="${1#*=}"; shift ;;
            -r|--root-load)
                [[ $# -ge 2 ]] || { echo "Error: $1 needs a DIR argument" >&2; return 2; }
                ROOT_LOAD="$2"; shift 2 ;;
            --root-load=*) ROOT_LOAD="${1#*=}"; shift ;;
            --db)
                [[ $# -ge 2 ]] || { echo "Error: $1 needs a NAME argument" >&2; return 2; }
                FLIBUSTA_DB="$2"; shift 2 ;;
            --db=*) FLIBUSTA_DB="${1#*=}"; shift ;;
            --force) PLACE_FORCE=1; shift ;;
            --keep-source) PLACE_KEEP_SOURCE=1; shift ;;
            --rm-source) : ;;   # compat: removal is the default since v0.2.0
            --report-dir)
                [[ $# -ge 2 ]] || { echo "Error: $1 needs a DIR argument" >&2; return 2; }
                PLACE_REPORT_DIR="$2"; shift 2 ;;
            --report-dir=*) PLACE_REPORT_DIR="${1#*=}"; shift ;;
            -n|--dry-run) DRY_RUN=1; shift ;;
            -d|--debug)
                # shellcheck disable=SC2034  # read by lib/logging.sh at runtime
                DEBUG=1; shift ;;
            -h|--help)    print_help; exit 0 ;;
            -v|--version) cli_print_version "$PLACE_CLI_INVOCATION" "$PLACE_SCRIPT_VERSION"; exit 0 ;;
            -*) echo "Error: unknown option '$1'" >&2; echo "Try '$CLI_INVOCATION --help'." >&2; return 2 ;;
            *)
                PLACE_POSITIONAL+=("$1"); shift ;;
        esac
    done
    return 0
}

# --- report infra: one TSV row per attempted number, written at run end ----------
PLACE_REPORT_ROWS=()

place_push_report() { # $1=file_number $2=bookid $3=status $4=target $5=reason
    PLACE_REPORT_ROWS+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s' \
        "$(timestamp_now)" "$1" "$2" "$3" "$4" "$5")")
}

# place_write_report DIR -> report file path on stdout (header + rows).
place_write_report() { # $1 = report directory
    local dir="$1" ts file
    ts="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$dir"
    file="$dir/place_flibusta_$ts.tsv"
    {
        printf 'processed_at\tfile_number\tbookid\tstatus\ttarget_zip\treason\n'
        printf '%s\n' "${PLACE_REPORT_ROWS[@]}"
    } > "$file"
    printf '%s\n' "$file"
}

# --- lib: placement primitives (inlined; lib/ stays domain-free per §4) -----------
# House rule (Follow-It §4, books_merge precedent): domain logic lives with
# its only consumer.  Extract back out only when a second consumer appears.

# place_validate_number NUMBER -> 0/1; digits only, greater than zero.
place_validate_number() { # $1 = candidate FileNumber
    local file_number="$1"
    [[ "$file_number" =~ ^[0-9]+$ ]] || return 1
    (( 10#$file_number > 0 ))
}

# place_read_numbers FILE -> numbers on stdout (BOM/CR/blank/#-comment safe).
place_read_numbers() { # $1 = list file
    local file="$1"
    sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -e 's/#.*//' "$file" \
        | grep -v '^[[:space:]]*$' || true
}

# place_sanitize_name RAW -> a Windows-safe path component on stdout.
# The target tree lives on NTFS (/mnt/c): replace \/:*?"<>| and control
# characters with "_", collapse whitespace runs, trim trailing dots/spaces.
place_sanitize_name() { # $1 = raw name
    local name="$1"
    name="${name//$'\r'/ }"
    name="${name//$'\n'/ }"
    name="${name//$'\t'/ }"
    name="${name//\\/_}"
    name="${name//\//_}"
    name="${name//:/_}"
    name="${name//\*/_}"
    name="${name//\?/_}"
    name="${name//\"/_}"
    name="${name//</_}"
    name="${name//>/_}"
    name="${name//|/_}"
    printf '%s' "$name" | sed -e 's/  */ /g' -e 's/[ .]*$//'
}

# place_lookup NUMBER -> one TSV row (bookid, title, fullname, seqname,
# seqnum) on stdout via lib/database.sh; rc 1 when the number is unknown.
# Aggregated derived tables guarantee one row: MIN(authorid) and MIN(seqid)
# per bookid (both decisions confirmed 2026-09-13).  The number is validated
# digits-only before interpolation, so the inline literals are injection-safe.
# Filename convention (live-tested 2026-09-13): fb2 books store a bare
# number in mlbook.filename, non-fb2 (usr) books store "<N>.<ext>"
# (811215.djvu, 811226.pdf) - so match both forms, exact bare match first.
place_lookup() { # $1 = FileNumber
    local n="$1"
    local sql row
    sql="SELECT b.bookid, b.title, COALESCE(an.FullName,'') AS fullname, COALESCE(sn.seqname,'') AS seqname, COALESCE(s.seqnum,'') AS seqnum
FROM mlbook b
LEFT JOIN (SELECT bookid, MIN(authorid) AS authorid FROM mlauthor GROUP BY bookid) a ON a.bookid = b.bookid
LEFT JOIN mlauthorname an ON an.authorid = a.authorid
LEFT JOIN (SELECT bookid, MIN(seqid) AS seqid FROM mlseq GROUP BY bookid) ms ON ms.bookid = b.bookid
LEFT JOIN mlseq s ON s.bookid = b.bookid AND s.seqid = ms.seqid
LEFT JOIN mlseqname sn ON sn.seqid = s.seqid
WHERE b.filename = '$n' OR b.filename LIKE '$n.%'
ORDER BY (b.filename = '$n') DESC, b.bookid
LIMIT 1;"
    row="$(db_run_sql "$sql" "$FLIBUSTA_DB" 2>/dev/null)" || return 1
    [[ -n "$row" ]] || return 1
    printf '%s\n' "$row"
}

# place_find_source NUMBER DIR -> path of the stage-1 extracted file on
# stdout; rc 1 when nothing matches.  First sorted "<N>.*" wins.
place_find_source() { # $1 = FileNumber, $2 = input dir
    local n="$1" dir="$2"
    local -a matches=()
    shopt -s nullglob
    matches=("$dir/$n".*)
    shopt -u nullglob
    (( ${#matches[@]} > 0 )) || return 1
    printf '%s\n' "${matches[0]}"
    return 0
}

# place_zip SOURCE TARGET_ZIP -> compress the single source file into the
# target zip (basename only - no directory paths stored), atomically:
# stream to "<target>.tmp.$$" next to the target, then mv.  An empty zip
# is an error.  Returns 1 on failure with the temp already cleaned.
# (No `--` guard: Info-ZIP rejects "--" before the archive name; the target
# is tool-generated and never dash-leading, so the guard is unnecessary.)
place_zip() { # $1 = source file, $2 = target zip path
    local src="$1" dst="$2"
    local tmp_dst="${dst}.tmp.$$"

    if ! zip -j -q "$tmp_dst" "$src"; then
        rm -f -- "$tmp_dst"
        return 1
    fi
    if [[ ! -s "$tmp_dst" ]]; then
        rm -f -- "$tmp_dst"
        return 1
    fi
    mv -- "$tmp_dst" "$dst"
}

# --- the run: validations -> lifecycle -> batch loop -> report -> summary -------
# Returns 1 when at least one number failed (or on a hard configuration
# error); never exits, so library callers keep control.

place_cleanup() {
    mariadb_stop_if_started
    return 0
}

place_run() {
    local fail_count=0 ok_count=0 skip_count=0 is_batch=0
    local row bookid title fullname seqname seqnum
    local safe_title safe_author target_dir base_name target_zip source_file
    local file_number report_file
    declare -a PLACE_FAILURES=() numbers=() file_numbers=()

    # --- validation (return-based: library callers keep control) ---------------
    if [[ -z "$ROOT_LOAD" ]]; then
        log "error: ROOT_LOAD is empty (set it or use --root-load)"; return 1
    fi
    if [[ -z "$PLACE_INPUT_DIR" ]]; then
        log "error: PLACE_INPUT_DIR is empty (set it or use --input-dir)"; return 1
    fi
    if [[ -z "$FLIBUSTA_DB" ]]; then
        log "error: FLIBUSTA_DB is empty (set it or use --db)"; return 1
    fi
    if [[ -z "$PLACE_REPORT_DIR" ]]; then
        log "error: PLACE_REPORT_DIR is empty (set it or use --report-dir)"; return 1
    fi
    if [[ ! -d "$PLACE_INPUT_DIR" ]]; then
        log "error: input directory (stage-1 output) does not exist: $PLACE_INPUT_DIR"; return 1
    fi
    if ! command -v zip >/dev/null 2>&1; then
        log "error: required command 'zip' not found on PATH"; return 1
    fi
    if ! command -v "${MYSQL_CLIENT:-mysql}" >/dev/null 2>&1; then
        log "error: ${MYSQL_CLIENT:-mysql} not found; install a mysql/mariadb client or set MYSQL_CLIENT"
        return 1
    fi

    # --- assemble the work list: positionals + --from-file ----------------------
    for file_number in "${PLACE_POSITIONAL[@]}"; do
        numbers+=("$file_number")
    done
    if [[ -n "$PLACE_FROM_FILE" ]]; then
        mapfile -t file_numbers < <(place_read_numbers "$PLACE_FROM_FILE")
        for file_number in "${file_numbers[@]}"; do
            numbers+=("$file_number")
        done
    fi
    if (( ${#numbers[@]} == 0 )); then
        place_print_help
        return 2
    fi

    # --- MariaDB lifecycle: start when down, stop on exit when we started it ----
    trap place_cleanup EXIT
    if ! mariadb_maybe_start; then
        log "error: cannot start MariaDB (accept the UAC prompt or start the server manually)"
        trap - EXIT
        return 1
    fi

    (( ${#numbers[@]} > 1 )) && is_batch=1

    for file_number in "${numbers[@]}"; do
        if ! place_validate_number "$file_number"; then
            PLACE_FAILURES+=("$file_number: invalid FileNumber (expected digits, greater than zero)")
            log_warn "$file_number: invalid FileNumber (expected digits, greater than zero)"
            place_push_report "$file_number" "-" "failed" "-" "invalid FileNumber (expected digits, greater than zero)"
            fail_count=$((fail_count + 1))
            continue
        fi

        # catalog lookup ----------------------------------------------------------
        row="$(place_lookup "$file_number")" || {
            PLACE_FAILURES+=("$file_number: not found in the catalog (mlbook.filename)")
            log_warn "$file_number: not found in the catalog"
            place_push_report "$file_number" "-" "failed" "-" "not found in the catalog (mlbook.filename)"
            fail_count=$((fail_count + 1))
            continue
        }
        IFS=$'\t' read -r bookid title fullname seqname seqnum <<< "$row"

        if [[ -z "$fullname" ]]; then
            PLACE_FAILURES+=("$file_number: bookid $bookid has no author (mlauthor/mlauthorname)")
            log_warn "$file_number: bookid $bookid has no author"
            place_push_report "$file_number" "$bookid" "failed" "-" "bookid $bookid has no author (mlauthor/mlauthorname)"
            fail_count=$((fail_count + 1))
            continue
        fi

        # target path --------------------------------------------------------------
        safe_title="$(place_sanitize_name "$title")"
        safe_author="$(place_sanitize_name "$fullname")"
        target_dir="$ROOT_LOAD/$safe_author"
        if [[ -n "$seqname" ]]; then
            target_dir="$target_dir/$(place_sanitize_name "$seqname")"
            base_name="$(printf '%02d' "$(( 10#$seqnum ))") - $safe_title"
        else
            base_name="$safe_title"
        fi
        target_zip="$target_dir/$base_name.zip"

        # source file ---------------------------------------------------------------
        source_file="$(place_find_source "$file_number" "$PLACE_INPUT_DIR")" || {
            if (( DRY_RUN )); then
                # dry-run resolves as far as possible: no source only means
                # stage 1 has not run yet (e.g. a --dry-run round where stage
                # 1 wrote nothing) - that is still a would-place outcome.
                place_push_report "$file_number" "$bookid" "would-place" "$target_zip" "source not extracted yet (dry run: stage 1 would deliver it)"
                ok_count=$((ok_count + 1))
                continue
            fi
            PLACE_FAILURES+=("$file_number: extracted file not found in $PLACE_INPUT_DIR (run stage 1 first)")
            log_warn "$file_number: extracted file not found in $PLACE_INPUT_DIR"
            place_push_report "$file_number" "$bookid" "failed" "$target_zip" "extracted file not found in $PLACE_INPUT_DIR (run stage 1 first)"
            fail_count=$((fail_count + 1))
            continue
        }

        # report + skip/force ---------------------------------------------------------
        if (( is_batch )); then
            log_info "$file_number (bookid $bookid): $source_file -> $target_zip"
        else
            log_info "bookid : $bookid"
            log_info "author : $fullname"
            [[ -n "$seqname" ]] && log_info "series : $seqname ($seqnum)"
            log_info "source : $source_file"
            log_info "target : $target_zip"
        fi

        if [[ -s "$target_zip" ]] && (( ! PLACE_FORCE )); then
            log_info "$file_number: target exists, skipping ($target_zip)"
            if (( DRY_RUN )); then
                place_push_report "$file_number" "$bookid" "would-skip" "$target_zip" "target exists (dry run: nothing was written)"
            else
                place_push_report "$file_number" "$bookid" "skipped" "$target_zip" "target exists"
            fi
            ok_count=$((ok_count + 1))
            skip_count=$((skip_count + 1))
            continue
        fi

        if (( DRY_RUN )); then
            place_push_report "$file_number" "$bookid" "would-place" "$target_zip" "dry run: nothing was written"
            ok_count=$((ok_count + 1))
            continue
        fi

        # place ------------------------------------------------------------------------
        mkdir -p "$target_dir"
        if place_zip "$source_file" "$target_zip"; then
            ok_count=$((ok_count + 1))
            if (( is_batch )); then
                log_info "$file_number: placed -> $target_zip"
            fi
            place_push_report "$file_number" "$bookid" "placed" "$target_zip" "-"
            if (( ! PLACE_KEEP_SOURCE )); then
                rm -f -- "$source_file"
                debug "$file_number: source trashed (default; --keep-source retains)"
            fi
        else
            PLACE_FAILURES+=("$file_number: zip failed for $source_file -> $target_zip")
            log_warn "$file_number: zip failed"
            place_push_report "$file_number" "$bookid" "failed" "$target_zip" "zip failed (source kept)"
            fail_count=$((fail_count + 1))
        fi
    done

    # --- report file (the persistent error/retry log) --------------------------------
    report_file="$(place_write_report "$PLACE_REPORT_DIR")"

    # --- summary -----------------------------------------------------------------------
    if (( DRY_RUN )); then
        log_info "dry-run: $ok_count number(s) resolvable, $fail_count failed, $skip_count existing; nothing was written"
    else
        log_info "summary: $ok_count placed, $skip_count of them skipped (exist), $fail_count failed"
    fi
    log_info "report: $report_file"

    if (( fail_count > 0 )); then
        if (( is_batch )); then
            for file_number in "${PLACE_FAILURES[@]}"; do
                log_error "$file_number"
            done
        fi
        mariadb_stop_if_started
        trap - EXIT
        return 1
    fi
    mariadb_stop_if_started
    trap - EXIT
    return 0
}

# --- script-mode entry point -------------------------------------------------------
# place_main is the script-mode main(): leading global flags (-h/-v/--debug)
# go through lib/cli.sh, the rest through place_parse_args, then place_run.
# Exit codes: 0 ok, 1 run failure, 2 usage error (house CLI contract).
place_main() {
    cli_try_global "$@"
    local -a rest=()
    if (( CLI_REMAINING_COUNT > 0 )); then
        rest=("${@: $(( $# - CLI_REMAINING_COUNT + 1 ))}")
    fi
    place_parse_args "${rest[@]}" || return $?
    place_run || return $?
    return 0
}

# Script mode runs automatically UNLESS the file was sourced as a library
# (PLACE_LIB_ONLY=1 before sourcing).  Evaluated once, at the bottom.
if [[ -z "${PLACE_LIB_ONLY:-}" ]]; then
    place_main "$@" || exit $?
fi
