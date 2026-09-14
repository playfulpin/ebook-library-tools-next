#!/usr/bin/env bash
#
# bin/flibusta/extract_series_flibusta.sh
#
# Version:       0.1.1
# Last updated:  2026-09-13
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Stage-1 Flibusta extraction by SERIES NAME: for each name argument,
#   resolve the matching series in the 'flibusta' catalog
#   (mlseqname.seqname LIKE '%name%'), collect the FileNumbers of the
#   series' fb2 books (mlbook JOIN mlseq), and extract every number's
#   member from the f.fb2-* range archives into FB2_OUTPUT_DIR - the
#   whole series shelf in one command.
#
#   fb2-ONLY by design: the resolution join keys on mlbook.filename being
#   a bare number, which is the fb2 filename convention (usr books store
#   "<N>.<ext>" there and are skipped by the REGEXP guard).  usr support
#   lives in extract_bookid_flibusta.sh only.
#
#   Database access goes through lib/database.sh exclusively (Follow-It §8);
#   the query is read-only.  The MariaDB lifecycle follows the house
#   pattern: a stopped server is started and stopped again on exit only
#   when this script started it.  --dry-run resolves and lists what would
#   be extracted but extracts nothing.
#
#   Shared primitives (range index, member resolution, atomic extraction,
#   SQL escaping) come from _flibusta_extract_common.sh; this tool owns
#   its CLI and the resolve-then-extract flow.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/flibusta/extract_series_flibusta.sh [options] NAME...
#   ./bin/flibusta/extract_series_flibusta.sh [options] --from-file LIST
#
#   Options:
#       -f, --from-file LIST    series names from LIST (one per line;
#                               blank lines, CR, BOM and #-comments
#                               tolerated)
#       -s, --source-dir DIR    archive source root
#                               [default: /mnt/x/flibusta]
#       -o, --output-dir DIR    extraction target
#                               [default: /mnt/c/Backup_Go7/ToLoad]
#           --db NAME           catalog database [default: flibusta]
#           --limit N           max books per series (0 = no limit)
#                               [default: 0]
#           --force             re-extract even if the output already exists
#       -n, --dry-run           resolve and list; extract nothing
#       -d, --debug             verbose diagnostics on stderr
#       -h, --help              show this help
#       -v, --version           print version and exit
#
#   Environment (FLIBUSTA_SOURCE_DIR / FB2_OUTPUT_DIR also settable in
#   config/flibusta_extract.conf; FLIBUSTA_DB from the environment; plus the
#   MYSQL_* / MARIA_* contract of lib/database.sh + lib/mariadb_lifecycle.sh).
#
#   Exit codes: 0 every name delivered its books, 1 at least one name or
#   book failed, 2 usage error.
#
# -----------------------------------------------------------------------------
# ALGORITHM
# -----------------------------------------------------------------------------
#   Per name: flb_sql_like_escape -> series query (mlseqname.seqname
#   LIKE '%name%'; no match = per-name failure) -> books query (JOIN
#   mlseq, fb2 bare-number filenames only, ordered by numeric seqnum then
#   bookid, optional --limit) -> per number: validate -> flb_find_archive
#   -> flb_resolve_member -> skip-existing (unless --force) -> atomic
#   extract.  A number whose member is sparse-absent from the archives is
#   a per-book failure; the batch continues.  Names are attempted
#   independently; the run result is 1 when anything failed.
# -----------------------------------------------------------------------------

set -Eeuo pipefail

# common_init resolves symlink-safe SCRIPT_DIR/PROJECT_ROOT at any bin/ depth,
# sources logging/cli/filesystem, and provides die/require_command.
# shellcheck source=../../lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"
common_init

# Shared family primitives (range index / member resolution / extraction /
# SQL escaping).  Intra-group include - allowed by the layer gate for
# bin/<group>/_*.sh.
# shellcheck source=_flibusta_extract_common.sh
source "$SCRIPT_DIR/_flibusta_extract_common.sh"

# SCRIPT_VERSION is parsed from this file's own header (version-sync contract).
# shellcheck disable=SC2155  # sed+head pipeline cannot fail; masking not a concern
readonly SCRIPT_VERSION="$(sed -n 's/^# Version:[[:space:]]*//p' "${BASH_SOURCE[0]}" | head -n 1)"
readonly CLI_INVOCATION="bin/flibusta/extract_series_flibusta.sh"

# shellcheck disable=SC2034  # read by lib/logging.sh at runtime
DEBUG="${DEBUG:-0}"

# --- shared libs: MariaDB lifecycle + the §8 database boundary ------------------
# shellcheck source=../../lib/mariadb_lifecycle.sh
source "$PROJECT_ROOT/lib/mariadb_lifecycle.sh"
# shellcheck source=../../lib/database.sh
source "$PROJECT_ROOT/lib/database.sh"

# --- configuration (flag > env > config file > built-in default) ----------------
FLIBUSTA_SOURCE_DIR="${FLIBUSTA_SOURCE_DIR:-}"
FB2_OUTPUT_DIR="${FB2_OUTPUT_DIR:-}"
FLIBUSTA_DB="${FLIBUSTA_DB:-flibusta}"
REQ_LIMIT=0
FROM_FILE=""
FORCE=0
DRY_RUN=0

CONF_FILE="${FLIBUSTA_EXTRACT_CONF_FILE:-$PROJECT_ROOT/config/flibusta_extract.conf}"
# shellcheck source=../../config/flibusta_extract.conf
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

# --- help -----------------------------------------------------------------------
print_help() {
    cat >&2 <<'EOF'
Usage: extract_series_flibusta.sh [options] NAME... | --from-file LIST

Stage-1 Flibusta extraction by SERIES NAME: resolve each name against
mlseqname.seqname (substring match), collect the FileNumbers of the
series' fb2 books, and extract every number's member from the f.fb2-*
range archives into FB2_OUTPUT_DIR.

fb2-only: mlbook.filename is a bare number for fb2 books ("<N>.<ext>"
for usr books, which are skipped here).  usr support lives in
extract_bookid_flibusta.sh.

Family: extract_bookid_flibusta.sh (by FileNumber, fb2+usr),
extract_author_flibusta.sh (by author name), extract_series_flibusta.sh
(this tool).

Options:
  -f, --from-file LIST      series names from LIST, one per line (blank
                            lines, CR, BOM, #-comments tolerated)
  -s, --source-dir DIR      archive source root [default: /mnt/x/flibusta]
  -o, --output-dir DIR      extraction target [default: /mnt/c/Backup_Go7/ToLoad]
      --db NAME             catalog database [default: flibusta]
      --limit N             max books per series (0 = no limit) [default: 0]
      --force               re-extract even if the output already exists
  -n, --dry-run             resolve and list; extract nothing
  -d, --debug               verbose diagnostics on stderr
  -h, --help                show this help
  -v, --version             print version and exit

Exit codes: 0 all names ok, 1 any name/book failed, 2 usage error.

Environment (FLIBUSTA_SOURCE_DIR / FB2_OUTPUT_DIR also in
config/flibusta_extract.conf; FLIBUSTA_DB env; MYSQL_* / MARIA_* contract).
EOF
}

# --- arg parsing ----------------------------------------------------------------
positional=()
while (( $# > 0 )); do
    case "$1" in
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
        --db)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a NAME argument" >&2; exit 2; }
            FLIBUSTA_DB="$2"; shift 2 ;;
        --db=*) FLIBUSTA_DB="${1#*=}"; shift ;;
        --limit)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs an N argument" >&2; exit 2; }
            REQ_LIMIT="$2"; shift 2 ;;
        --limit=*) REQ_LIMIT="${1#*=}"; shift ;;
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
declare -a names=()
for n in "${positional[@]}"; do
    names+=("$n")
done
if [[ -n "$FROM_FILE" ]]; then
    mapfile -t file_names < <(flb_read_numbers "$FROM_FILE")
    for n in "${file_names[@]}"; do
        names+=("$n")
    done
fi

if (( ${#names[@]} == 0 )); then
    print_help
    exit 2
fi

# --- validation -----------------------------------------------------------------
require_command unzip
[[ -n "$FLIBUSTA_SOURCE_DIR" ]] || die "FLIBUSTA_SOURCE_DIR is empty (set it or use --source-dir)"
[[ -n "$FB2_OUTPUT_DIR" ]] || die "FB2_OUTPUT_DIR is empty (set it or use --output-dir)"
[[ "$REQ_LIMIT" =~ ^[0-9]+$ ]] || die "--limit must be a non-negative integer (got '$REQ_LIMIT')"
fs_require_dir "$FLIBUSTA_SOURCE_DIR" "source directory"
if ! command -v "${MYSQL_CLIENT:-mysql}" >/dev/null 2>&1; then
    die "${MYSQL_CLIENT:-mysql} not found; install a mysql/mariadb client or set MYSQL_CLIENT"
fi

flb_index_load fb2 || die "no f.fb2-*.zip archives under $FLIBUSTA_SOURCE_DIR"

# --- MariaDB lifecycle: start when down, stop on exit when we started it --------
cleanup() {
    mariadb_stop_if_started
    return 0
}
trap cleanup EXIT

mariadb_maybe_start \
    || die "cannot start MariaDB (accept the UAC prompt or start the server manually)"

# --- resolution: name -> series rows / book numbers -------------------------------
# series_for_name NAME -> "seqid<TAB>seqname" rows on stdout.
# The pattern is escaped by flb_sql_like_escape (quotes/backslash/wildcards).
series_for_name() { # $1 = raw series name
    local raw="$1" esc
    esc="$(flb_sql_like_escape "$raw")"
    local sql
    sql="SELECT sn.seqid, sn.seqname
FROM mlseqname sn
WHERE sn.seqname LIKE '%${esc}%'
ORDER BY sn.seqid;"
    db_run_sql "$sql" "$FLIBUSTA_DB" 2>/dev/null || return 1
}

# numbers_for_series SEQ_IDS... -> "filename<TAB>seqid<TAB>seqname<TAB>seqnum"
# rows on stdout, fb2 bare-number filenames only, in series order
# (numeric seqnum, then bookid as tiebreak).
numbers_for_series() { # $@ = seqids
    local esc_ids="" id
    for id in "$@"; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue     # defense in depth: ids come from our own query
        esc_ids+="${esc_ids:+,}${id}"
    done
    [[ -n "$esc_ids" ]] || return 0
    local limit_clause=""
    (( REQ_LIMIT > 0 )) && limit_clause="LIMIT $REQ_LIMIT"
    local sql
    sql="SELECT b.filename, s.seqid, sn.seqname, COALESCE(s.seqnum, '')
FROM mlbook b
JOIN mlseq s ON s.bookid = b.bookid
JOIN mlseqname sn ON sn.seqid = s.seqid
WHERE s.seqid IN ($esc_ids) AND b.filename REGEXP '^[0-9]+[[:space:]]*$'
ORDER BY sn.seqname, CAST(s.seqnum AS UNSIGNED), b.bookid
$limit_clause;"
    db_run_sql "$sql" "$FLIBUSTA_DB" 2>/dev/null || return 1
}

# --- batch execution --------------------------------------------------------------
fail_count=0
ok_count=0
skip_count=0
declare -a failures=()

is_batch=0
total_names=${#names[@]}
(( total_names > 1 )) && is_batch=1

mkdir -p "$FB2_OUTPUT_DIR"

declare -A seen_number=()   # global dedupe: the same book in two matched series

for name in "${names[@]}"; do
    series_rows="$(series_for_name "$name")" || {
        failures+=("$name: catalog query failed")
        log_warn "$name: catalog query failed"
        fail_count=$((fail_count + 1))
        continue
    }
    if [[ -z "$series_rows" ]]; then
        failures+=("$name: no series matched (mlseqname.seqname)")
        log_warn "$name: no series matched"
        fail_count=$((fail_count + 1))
        continue
    fi

    # collect series ids + log the matches
    declare -a seq_ids=()
    while IFS=$'\t' read -r sid sname; do
        seq_ids+=("$sid")
        debug "$name: series $sid = $sname"
    done <<< "$series_rows"
    log_info "$name: matched ${#seq_ids[@]} series"

    book_rows="$(numbers_for_series "${seq_ids[@]}")" || {
        failures+=("$name: books query failed")
        log_warn "$name: books query failed"
        fail_count=$((fail_count + 1))
        continue
    }
    if [[ -z "$book_rows" ]]; then
        failures+=("$name: matched series have no fb2 books on file")
        log_warn "$name: matched series have no fb2 books on file"
        fail_count=$((fail_count + 1))
        continue
    fi

    # extract per number (fb2-only chain)
    name_failed=0
    while IFS=$'\t' read -r file_number sid sname seqnum; do
        [[ -n "${seen_number[$file_number]:-}" ]] && continue
        seen_number["$file_number"]=1

        if ! flb_validate_number "$file_number"; then
            failures+=("$file_number: invalid FileNumber in series '$sname'")
            log_warn "$file_number: invalid FileNumber in series '$sname'"
            name_failed=1
            continue
        fi

        # fast path (fb2 member is exactly "<N>.fb2"): an already-extracted
        # output is known without touching the archive, so skip BEFORE the
        # (expensive, first-touch-per-archive) member resolution.
        output_file="$FB2_OUTPUT_DIR/${file_number}.fb2"
        if [[ -s "$output_file" ]] && (( ! FORCE )); then
            debug "$file_number [$sname]: output exists, skipping ($output_file)"
            ok_count=$((ok_count + 1))
            skip_count=$((skip_count + 1))
            continue
        fi

        archive=""
        if flb_find_archive "$file_number" fb2; then
            archive="$FLB_ARCHIVE"
        else
            failures+=("$file_number: no fb2 archive contains the number ($sname)")
            log_warn "$file_number: no fb2 archive contains the number ($sname)"
            name_failed=1
            continue
        fi

        member=""
        if flb_resolve_member "$archive" "$file_number" fb2; then
            member="$FLB_MEMBER"
        else
            failures+=("$file_number: member not present in $(basename "$archive") ($sname)")
            log_warn "$file_number: member not present in $(basename "$archive") ($sname)"
            name_failed=1
            continue
        fi

        output_file="$FB2_OUTPUT_DIR/$member"

        if (( is_batch )); then
            log_info "$file_number [$sname$( [[ -n "$seqnum" ]] && printf ' #%s' "$seqnum")]: $(basename "$archive") -> $member"
        else
            log_info "series : $sname (seqid $sid$( [[ -n "$seqnum" ]] && printf ', #%s' "$seqnum"))"
            log_info "archive: $archive"
            log_info "member : $member"
            log_info "output : $output_file"
        fi

        if (( DRY_RUN )); then
            ok_count=$((ok_count + 1))
            continue
        fi

        if flb_extract "$archive" "$member" "$output_file"; then
            ok_count=$((ok_count + 1))
            (( is_batch )) && log_info "$file_number [$sname]: done -> $output_file"
        else
            failures+=("$file_number: extraction failed from $(basename "$archive")")
            name_failed=1
        fi
    done <<< "$book_rows"

    (( name_failed )) && fail_count=$((fail_count + 1))
done

# --- summary ---------------------------------------------------------------------
if (( DRY_RUN )); then
    log_info "dry-run: $ok_count book(s) resolvable, $fail_count name(s) failed, $skip_count existing; no files were written"
else
    log_info "summary: $ok_count book(s) delivered, $skip_count of them skipped (exist), $fail_count name(s) failed"
fi

if (( fail_count > 0 )); then
    for f in "${failures[@]}"; do
        log_error "$f"
    done
    exit 1
fi
exit 0
