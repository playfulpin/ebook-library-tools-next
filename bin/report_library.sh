#!/usr/bin/env bash

###############################################################################
# bin/report_library.sh
#
# Version:       1.1.0
# Last updated:  2026-09-07 02:40
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   End-user reporting for the personal library.  v1 ships the WISH LIST
#   feature: a reading plan - books you own (or intend to collect) that you
#   want to read within some given time period.  The wish list lives in a
#   plain TSV file (default: data/wishlist.tsv), NOT in the database, so it
#   survives the populate TRUNCATE-reload cycle untouched and is
#   versionable/diffable like any project fixture.
#
#   Wish-file format (TAB-separated, one entry per line, #-comments and
#   blank lines allowed):
#       bookid <TAB> added <TAB> target_period <TAB> status <TAB> note
#       882939  2026-09-06  2026-09     wish    Piranha cycle
#   bookid is the catalog bookid (the same key populate copies verbatim);
#   added is the date the entry was made; target_period is free-form
#   (2026-09, 2026-Q4, 2026 ...) so grouping follows whatever period you
#   care about; status is one of: wish | reading | done.
#
#   Subcommands:
#     --add BOOKID [--period P] [--note N]   add an entry (status=wish)
#     --set-status BOOKID STATUS             wish | reading | done
#     --remove BOOKID                        delete the entry
#     --list                                 raw entries, no DB
#     --search SUBSTR                        find bookids by title/author
#     (default)                              render the wish-list VIEW
#
#   The view joins the wish bookids against myprivatelib (read-only:
#   mlbook + mlauthor + mlauthorname + mlseq + mlseqname + mlrating) and
#   renders entries grouped by target_period, then by author, with series
#   position and rating, plus per-period completion counts.  Wish entries
#   whose bookid is not in the library are listed separately ("not in
#   library") so a book can be planned before it is collected.
#   --no-db renders the raw entries without any server; mutations
#   (--add/--set-status/--remove/--list) never touch the DB.
#
#   Exports: --export md|tsv writes a report file into the output dir
#   (report_wishlist_<ts>.md / .tsv).  Reads ONLY from myprivatelib; never
#   writes to the database.  MariaDB lifecycle is shared via
#   lib/mariadb_lifecycle.sh (auto-start when down, graceful stop on exit
#   when this process started it; skipped entirely for --no-db and the
#   mutation subcommands).
#
#   Native wishlists (v1.1): MultiLib.exe stores reading lists itself in
#   mllbr_main.mlgroup / mlgroupname (verified live 2026-09-07: three
#   built-in categories - 1 «Избранное», 2 «К прочтению», 3 «Прочитано»;
#   each mlgroup row carries bookid, the library name and the assignment
#   date_gr).  --native [title|author|series|all] (default: author)
#   renders those app-managed wishlists READ-ONLY, always scoped to
#   g.library = <REPORT_GROUP_LIBRARY, default: the target DB name>, and
#   joined against the same catalog tables as the TSV view (title,
#   aggregated authors, series + #position, rating).  Bookids assigned
#   in-app but missing from the library are listed separately, so a book
#   can be wished before it is collected.  The matching runnable SQL
#   ships as data/sql/qry_wishlist_native.sql.  mllbr_main is NEVER
#   written to - marking happens in MultiLib.exe.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/report_library.sh                          # render the wish-list view
#   ./bin/report_library.sh --search piranha         # find bookids first
#   ./bin/report_library.sh --add 882939 --period 2026-09 --note "Piranha"
#   ./bin/report_library.sh --set-status 882939 reading
#   ./bin/report_library.sh --set-status 882939 done
#   ./bin/report_library.sh --export md              # report_wishlist_<ts>.md
#   ./bin/report_library.sh --list                   # raw entries, offline
#   ./bin/report_library.sh --native                 # app wishlists, by author
#   ./bin/report_library.sh --native title           # app wishlists, by title
#   ./bin/report_library.sh --native series          # app wishlists, series order
#
# Exit codes: 0 success, 1 operational failure, 2 usage error.
###############################################################################

set -uo pipefail

SCRIPT_VERSION="1.1.0"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- shared MariaDB lifecycle (auto-start when down; graceful stop on exit) ----
# shellcheck source=../lib/mariadb_lifecycle.sh
source "$PROJECT_ROOT/lib/mariadb_lifecycle.sh"

# --- defaults (config file may override; env wins over config) -----------------
CONF_FILE="${REPORT_CONF_FILE:-$PROJECT_ROOT/config/report_library.conf}"
[[ -f "$CONF_FILE" ]] && # shellcheck source=../config/report_library.conf
    source "$CONF_FILE"

WISHLIST_FILE="${REPORT_WISHLIST_FILE:-$PROJECT_ROOT/data/wishlist.tsv}"
OUTPUT_DIR="${REPORT_OUTPUT_DIR:-/mnt/c/Backup_Go7/merge-reports}"
TARGET_DB="${REPORT_TARGET_DB:-myprivatelib}"
STATUSES="${REPORT_STATUSES:-wish reading done}"
# library name for the mllbr_main.mlgroup.library filter (native wishlists,
# v1.1); defaults to the target DB name, which is how MultiLib registers
# its libraries
GROUP_LIBRARY="${REPORT_GROUP_LIBRARY:-$TARGET_DB}"

DEBUG=0
DRY_RUN=0            # the lifecycle lib reads this; reporting has no dry-run
MODE="view"          # view | add | set-status | remove | list | search | native
ARG_ID=""
ARG_STATUS=""
ARG_PERIOD=""
ARG_NOTE=""
ARG_SEARCH=""
ARG_NATIVE="author"  # native view: title | author | series | all
ARG_EXPORT=""
NO_DB=0

log()   { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
debug() { if (( DEBUG )); then log "debug: $*"; fi; }
die()   { log "error: $*"; exit 1; }
usage2(){ echo "Try '$0 --help'." >&2; }

_STARTED_MARIADB=0
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/report_library.XXXXXX")"
cleanup() {
    rm -rf "$tmp_dir"
    if (( _STARTED_MARIADB )); then mariadb_stop_if_started; fi
}
trap cleanup EXIT

print_help() {
    cat >&2 <<EOF
Usage: report_library.sh [options]

Wish list (reading plan) for the personal library: the books you want to
read within a given time period.  State lives in a TSV file
(default: data/wishlist.tsv; bookid, added, target_period, status, note)
so it survives the populate reload cycle untouched.  The default view
joins the wish bookids against $TARGET_DB (read-only) and renders
entries grouped by target_period, then by author, with series position,
rating and per-period completion counts; bookids not yet in the library
are listed separately so a book can be planned before it is collected.

Commands:
  (default)                  render the wish-list view (DB join)
  --add BOOKID               add an entry (status=wish; today as added);
                             use --search to find bookids
  --set-status BOOKID ST     set status: wish | reading | done
  --remove BOOKID            delete the entry
  --list                     print the raw entries, no DB
  --search SUBSTR            search the catalog by title/author substring
                             and print bookid candidates
  --native [t|a|s|all]       render the NATIVE wishlists managed by
                             MultiLib.exe in mllbr_main.mlgroup/mlgroupname
                             (view: title|author|series|all, default author);
                             read-only, scoped to the library name
                             (REPORT_GROUP_LIBRARY, default: target DB name)

Options:
      --period PERIOD        target period for --add (free-form, e.g. 2026-09)
      --note TEXT            note for --add
      --file FILE            wish-list file to operate on
      --export md|tsv        write report_wishlist_<ts>.md/.tsv into the
                             output dir (view mode only)
  -o, --output-dir DIR       output directory for exports
                             [default: /mnt/c/Backup_Go7/merge-reports]
      --no-db                render raw entries without touching the server
  -d, --debug                verbose diagnostics on stderr
  -h, --help                 show this help
  -v, --version              print version and exit

Environment: MYSQL_HOST/PORT/USER/PASSWORD/DATABASE via
lib/mariadb_lifecycle.sh (same contract as BookTracker-import).
REPORT_GROUP_LIBRARY overrides the mllbr_main.mlgroup.library filter
used by --native (default: the target database name).

Exit codes: 0 success, 1 operational failure, 2 usage error.
EOF
}

# --- arg parsing ----------------------------------------------------------------
while (( $# > 0 )); do
    case "$1" in
        --add)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a BOOKID argument" >&2; usage2; exit 2; }
            MODE="add"; ARG_ID="$2"; shift 2 ;;
        --set-status)
            [[ $# -ge 3 ]] || { echo "Error: $1 needs BOOKID and STATUS arguments" >&2; usage2; exit 2; }
            MODE="set-status"; ARG_ID="$2"; ARG_STATUS="$3"; shift 3 ;;
        --remove)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a BOOKID argument" >&2; usage2; exit 2; }
            MODE="remove"; ARG_ID="$2"; shift 2 ;;
        --list)     MODE="list"; shift ;;
        --search)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a SUBSTR argument" >&2; usage2; exit 2; }
            MODE="search"; ARG_SEARCH="$2"; shift 2 ;;
        --native)
            MODE="native"
            if [[ $# -ge 2 && "$2" != -* ]]; then ARG_NATIVE="$2"; shift 2; else shift; fi ;;
        --period)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a PERIOD argument" >&2; usage2; exit 2; }
            ARG_PERIOD="$2"; shift 2 ;;
        --note)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a TEXT argument" >&2; usage2; exit 2; }
            ARG_NOTE="$2"; shift 2 ;;
        --file)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a FILE argument" >&2; usage2; exit 2; }
            WISHLIST_FILE="$2"; shift 2 ;;
        --export)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs md|tsv" >&2; usage2; exit 2; }
            ARG_EXPORT="$2"; shift 2 ;;
        -o|--output-dir)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a DIR argument" >&2; usage2; exit 2; }
            OUTPUT_DIR="$2"; shift 2 ;;
        --output-dir=*) OUTPUT_DIR="${1#*=}"; shift ;;
        --no-db) NO_DB=1; shift ;;
        -d|--debug)   DEBUG=1; shift ;;
        -h|--help)    print_help; exit 0 ;;
        -v|--version) echo "bin/report_library.sh v$SCRIPT_VERSION"; exit 0 ;;
        *) echo "Error: unknown option '$1'" >&2; usage2; exit 2 ;;
    esac
done

case "$MODE" in
    add|set-status|remove)
        [[ "$ARG_ID" =~ ^[1-9][0-9]*$ ]] || die "--$MODE needs a numeric BOOKID (got '$ARG_ID')";;
esac
if [[ -n "$ARG_EXPORT" && "$ARG_EXPORT" != "md" && "$ARG_EXPORT" != "tsv" ]]; then
    die "--export understands md|tsv (got '$ARG_EXPORT')"
fi
if [[ -n "$ARG_EXPORT" && "$MODE" != "view" ]]; then
    die "--export works with the (TSV) view mode only"
fi
case "$MODE" in
    native)
        case "$ARG_NATIVE" in
            title|author|series|all) ;;
            *) die "--native understands title|author|series|all (got '$ARG_NATIVE')" ;;
        esac ;;
esac
# note/period must not carry tabs or CR (they would break the TSV shape)
for v in "$ARG_PERIOD" "$ARG_NOTE"; do
    if [[ "$v" == *$'\t'* || "$v" == *$'\r'* || "$v" == *$'\n'* ]]; then
        die "period/note must not contain tabs or newlines"
    fi
done

# -----------------------------------------------------------------------------
# wish-file helpers
# -----------------------------------------------------------------------------
# load_wishlist OUT_CLEAN OUT_REJECT
#   Normalize (BOM/CR, trim, skip blanks/comments), validate the shape, and
#   split good rows (OUT_CLEAN) from rejected ones (OUT_REJECT).  Never dies:
#   a malformed line is reported and skipped so one bad paste cannot take the
#   whole list down.
load_wishlist() { # out_clean out_reject
    local out="$1" rej="$2"
    : > "$out"; : > "$rej"
    [[ -f "$WISHLIST_FILE" ]] || return 0
    # CR + trailing SPACES are stripped; trailing TABs are NOT - a tab closes
    # the last (possibly empty) field, and trimming it would collapse a
    # 5-field row with an empty note into a malformed 4-field one.
    sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -e 's/ *$//' "$WISHLIST_FILE" \
        | while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            printf '%s\n' "$line"
          done > "$WISHLIST_FILE.work"
    local nfields id st
    while IFS= read -r line; do
        nfields="$(awk -F'\t' 'BEGIN{nf=0} {nf=NF} END{print nf}' <<< "$line")"
        id="$(cut -f1 <<< "$line")"
        st="$(cut -f4 <<< "$line")"
        if [[ "$nfields" -ge 5 && "$id" =~ ^[1-9][0-9]*$ ]]; then
            local st_ok=0
            local s
            for s in $STATUSES; do [[ "$st" == "$s" ]] && st_ok=1; done
            if (( st_ok )); then
                printf '%s\n' "$line" >> "$out"
                continue
            fi
        fi
        printf '%s\n' "$line" >> "$rej"
    done < "$WISHLIST_FILE.work"
    rm -f "$WISHLIST_FILE.work"
}

wishlist_count() { # clean_file -> stdout count
    [[ -s "$1" ]] && wc -l < "$1" | tr -d ' ' || echo 0
}

wish_has() { # clean_file bookid
    cut -f1 "$1" | grep -qx -- "$2"
}

# write_wishlist clean_file
#   Atomically replace the wish file with the (validated) rows.  Comments and
#   blank lines from the original are preserved on top.
write_wishlist() { # clean_file
    local clean="$1"
    local header=""
    if [[ -f "$WISHLIST_FILE" ]]; then
        header="$(grep -E '^($|#)' "$WISHLIST_FILE" | head -20 || true)"
    fi
    local tmp="$WISHLIST_FILE.new"
    if [[ -n "$header" ]]; then printf '%s\n' "$header" > "$tmp"; else : > "$tmp"; fi
    cat "$clean" >> "$tmp"
    mkdir -p "$(dirname "$WISHLIST_FILE")"
    mv -f "$tmp" "$WISHLIST_FILE"
}

# -----------------------------------------------------------------------------
# DB helpers (read-only; lifecycle only when a query actually needs it)
# -----------------------------------------------------------------------------
db_query() { # sql -> stdout   (caller must have called db_start when needed)
    local sql="$1"
    local args=("${MYSQL_CLIENT:-mysql}")
    [[ -n "${MYSQL_HOST:-}" ]] && args+=(-h "$MYSQL_HOST" --protocol=TCP)
    [[ -n "${MYSQL_PORT:-}" ]] && args+=(-P "$MYSQL_PORT")
    [[ -n "${MYSQL_USER:-}" ]] && args+=(-u "$MYSQL_USER")
    [[ -n "${MYSQL_EXTRA_ARGS:-}" ]] && args+=("$MYSQL_EXTRA_ARGS")
    args+=(--init-command="SET NAMES utf8")
    args+=("$TARGET_DB")
    args+=(-B --skip-column-names --raw)
    if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
        MYSQL_PWD="$MYSQL_PASSWORD" "${args[@]}" -e "$sql"
    else
        "${args[@]}" -e "$sql"
    fi
}

db_start() {
    command -v "${MYSQL_CLIENT:-mysql}" >/dev/null 2>&1 \
        || die "${MYSQL_CLIENT:-mysql} not found; install a mysql/mariadb client or use --no-db"
    mariadb_maybe_start \
        || die "cannot start MariaDB (accept the UAC prompt or start the server manually)"
    _STARTED_MARIADB=1
}

# join_catalog bookids_file -> stdout
#   One row per bookid found in the catalog:
#     bookid TAB title TAB authors TAB series TAB seqnum TAB rating
#   Multi-author books are aggregated (authors joined with ', ').
join_catalog() { # bookids_file
    local ids_file="$1"
    local total chunk chunk_sql
    total="$(wishlist_count "$ids_file")"
    (( total == 0 )) && return 0
    local batch=()
    local id
    while IFS= read -r id; do
        batch+=("$id")
        if (( ${#batch[@]} == 500 )); then
            chunk_sql="$(IFS=,; echo "${batch[*]}")"
            emit_join "$chunk_sql"
            batch=()
        fi
    done < "$ids_file"
    if (( ${#batch[@]} > 0 )); then
        chunk_sql="$(IFS=,; echo "${batch[*]}")"
        emit_join "$chunk_sql"
    fi
}

emit_join() { # id_list (comma-joined)
    local id_list="$1"
    local sql="SELECT b.bookid, b.title, an.FullName, sn.seqname, sq.seqnum, r.rating
FROM mlbook b
LEFT JOIN mlauthor a   ON a.bookid = b.bookid
LEFT JOIN mlauthorname an ON an.authorid = a.authorid
LEFT JOIN mlseq sq     ON sq.bookid = b.bookid
LEFT JOIN mlseqname sn ON sn.seqid = sq.seqid
LEFT JOIN mlrating r   ON r.bookid = b.bookid
WHERE b.bookid IN ($id_list)
ORDER BY b.bookid"
    db_query "$sql" \
        | awk -F'\t' '
        {   id = $1
            title = ($2 == "NULL" ? "" : $2)
            auth  = ($3 == "NULL" ? "" : $3)
            ser   = ($4 == "NULL" ? "" : $4)
            num   = ($5 == "NULL" ? "" : $5)
            rat   = ($6 == "NULL" ? "" : $6)
            if (!(id in seen)) { seen[id] = 1; ids[++n] = id }
            t[id] = title
            if (auth != "" && !((id SUBSEP auth) in seen_auth)) {
                seen_auth[id, auth] = 1
                a[id] = ((id in a && a[id] != "") ? a[id] ", " auth : auth)
            }
            if (ser != "" && !(id in s)) { s[id] = ser; numv[id] = num }
            if (rat != "" && !(id in r)) { r[id] = rat }
        }
        END {
            for (i = 1; i <= n; i++) {
                id = ids[i]
                printf "%s\t%s\t%s\t%s\t%s\t%s\n", id, t[id], (id in a ? a[id] : ""),
                       (id in s ? s[id] : ""), (id in numv ? numv[id] : ""), (id in r ? r[id] : "")
            }
        }'
}

# search_catalog SUBSTR -> stdout  (bookid TAB title TAB author)
search_catalog() {
    local substr="$1"
    local esc
    esc="$(printf '%s' "$substr" | sed -e 's/[\\%_]/\\&/g' -e "s/'/\\\\'/g")"
    local sql="SELECT b.bookid, b.title, an.FullName
FROM mlbook b
LEFT JOIN mlauthor a   ON a.bookid = b.bookid
LEFT JOIN mlauthorname an ON an.authorid = a.authorid
WHERE b.title LIKE '%$esc%' OR an.FullName LIKE '%$esc%'
ORDER BY b.bookid"
    db_query "$sql"
}

# -----------------------------------------------------------------------------
# native wishlists (mllbr_main.mlgroup / mlgroupname) -- READ-ONLY (v1.1)
# MultiLib.exe owns these tables: it creates the groups and assigns books
# in-app.  We only ever SELECT, always filtered by the library name.
# -----------------------------------------------------------------------------

# native_groups -> stdout  (groupid TAB groupname TAB bookcount)
#   All groups that have at least one book assigned for our library.
native_groups() {
    local esc_lib
    esc_lib="$(printf '%s' "$GROUP_LIBRARY" | sed -e 's/[\\]/\\\\/g' -e "s/'/\\\\'/g")"
    local sql="SELECT gn.groupid, gn.groupname, COUNT(g.bookid)
FROM mllbr_main.mlgroupname gn
LEFT JOIN mllbr_main.mlgroup g ON g.groupid = gn.groupid AND g.library = '$esc_lib'
GROUP BY gn.groupid, gn.groupname
HAVING COUNT(g.bookid) > 0
ORDER BY gn.groupid"
    db_query "$sql"
}

# native_join bookids_file -> stdout
#   Same row shape as join_catalog (bookid title authors series seqnum rating)
#   for the bookids assigned to native wishlist groups.  Runs against the
#   target DB (the catalog), so it reuses the batching + emit_join machinery.
native_join() { # bookids_file
    join_catalog "$1"
}

# native_missing bookids_file -> stdout  (bookid TAB groupid TAB date_gr)
#   Assigned bookids that the catalog does not know (join produced no row).
#   Needs the group/date info alongside, so it queries mllbr_main directly
#   for the (bookid, groupid, date) triples of our library.
native_assignments() { # -> stdout: bookid TAB groupid TAB date_gr
    local esc_lib
    esc_lib="$(printf '%s' "$GROUP_LIBRARY" | sed -e 's/[\\]/\\\\/g' -e "s/'/\\\\'/g")"
    local sql="SELECT g.bookid, g.groupid, g.date_gr
FROM mllbr_main.mlgroup g
WHERE g.library = '$esc_lib'
ORDER BY g.bookid"
    db_query "$sql"
}

# -----------------------------------------------------------------------------
# rendering
# -----------------------------------------------------------------------------
# render_view clean inlib_sorted notinlib
#   merged row: bookid status period added note title author series seqnum rating
render_view() { # clean inlib_sorted notinlib
    local clean="$1" inlib="$2" notin="$3"
    local total
    total="$(wishlist_count "$clean")"
    if (( total == 0 )); then
        echo "wish list is empty (add entries with --add BOOKID)"
        return 0
    fi
    # status tallies
    local sw sr sd
    sw="$(awk -F'\t' '$4=="wish"{c++} END{print c+0}' "$clean")"
    sr="$(awk -F'\t' '$4=="reading"{c++} END{print c+0}' "$clean")"
    sd="$(awk -F'\t' '$4=="done"{c++} END{print c+0}' "$clean")"
    local plural="ies"; [[ "$total" == 1 ]] && plural="y"
    echo "wish list: $total entr$plural  (wish $sw, reading $sr, done $sd)"
    echo
    awk -F'\t' -v NOTIN="$notin" '
    function statusmark(s) {
        if (s == "done")    return "[x]"
        if (s == "reading") return "[~]"
        return "[ ]"
    }
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    BEGIN {
        while ((getline line < NOTIN) > 0) { notin[++nn] = line }
        close(NOTIN)
        first_period = 1
    }
    {
        period = $3
        if (first_period || period != cur_period) {
            cur_period = period
            label = (period == "" ? "(no period)" : period)
            printf "== %s ==\n", label
            first_period = 0
            cur_author = ""
        }
        author = trim($7)
        if (author == "") author = "(unknown author)"
        if (author != cur_author) {
            printf "  %s\n", author
            cur_author = author
        }
        line = "    " statusmark($2) " " $1 "  " $6
        extra = ""
        if ($8 != "") extra = $8 (($9 != "" && $9+0 > 0) ? " #" $9 : "")
        if ($10 != "") extra = extra (extra == "" ? "" : ", ") "rating " $10
        if (extra != "") line = line "  (" extra ")"
        if ($5 != "") line = line "  -- " $5
        print line
    }
    END {
        if (nn > 0) {
            print ""
            print "not in library (plan now, collect later):"
            for (i = 1; i <= nn; i++) {
                # notin rows: bookid status period added note
                split(notin[i], f, "\t")
                line = "  [?] " f[1]
                if (f[3] != "") line = line " (" f[3] ")"
                if (f[5] != "") line = line "  -- " f[5]
                print line
            }
        }
    }' "$inlib"
}

# export_view fmt clean inlib notin  -> writes the export file, prints the path
export_view() { # fmt clean inlib notin
    local fmt="$1" clean="$2" inlib="$3" notin="$4"
    local ts stamp path
    ts="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$OUTPUT_DIR" || die "cannot create output dir: $OUTPUT_DIR"
    stamp="report_wishlist_$ts"
    if [[ "$fmt" == "md" ]]; then
        path="$OUTPUT_DIR/$stamp.md"
        {
            echo "# Wish list report"
            echo
            echo "Generated: $(date '+%Y-%m-%d %H:%M:%S'); source: $WISHLIST_FILE"
            echo
            awk -F'\t' '
            {
                period = $3
                if (first || period != cur) {
                    cur = period; first = 0
                    print ""
                    print "## " (period == "" ? "(no period)" : period)
                    cur_author = ""
                }
                author = $7; gsub(/^[[:space:]]+|[[:space:]]+$/, "", author)
                if (author == "") author = "(unknown author)"
                if (author != cur_author) { print ""; print "### " author; cur_author = author }
                mark = ($2 == "done" ? "x" : ($2 == "reading" ? "~" : " "))
                item = "- [" mark "] **" $6 "**"
                extra = ""
                if ($8 != "") extra = $8 (($9 != "" && $9+0 > 0) ? " #" $9 : "")
                if ($10 != "") extra = extra (extra == "" ? "" : ", ") "rating " $10
                if (extra != "") item = item " (" extra ")"
                if ($5 != "") item = item " -- " $5
                print item
            }
            BEGIN { first = 1 }' "$inlib"
            if [[ -s "$notin" ]]; then
                echo
                echo "## not in library (plan now, collect later)"
                echo
                while IFS= read -r line; do
                    IFS=$'\t' read -r nid nst nper nad nnote <<< "$line"
                    item="- [?] **$nid**"
                    [[ -n "$nper" ]] && item="$item ($nper)"
                    [[ -n "$nnote" ]] && item="$item -- $nnote"
                    echo "$item"
                done < "$notin"
            fi
        } > "$path"
    else
        path="$OUTPUT_DIR/$stamp.tsv"
        {
            printf 'bookid\tstatus\tperiod\tadded\ttitle\tauthor\tseries\tseqnum\trating\tnote\n'
            # inlib order (bookid status period added note title author series
            # seqnum rating) -> export header order (note last)
            awk -F'\t' -v OFS='\t' \
                '{ print $1, $2, $3, $4, $6, $7, $8, $9, $10, $5 }' "$inlib"
            # notin rows: bookid status period added note -> map into the
            # 10-column shape; title/author/series/seqnum/rating stay empty
            awk -F'\t' -v OFS='\t' \
                '{ print $1, "notinlib", $3, $4, "", "", "", "", "", $5 }' "$notin"
        } > "$path"
    fi
    log "export written: $path"
}

# -----------------------------------------------------------------------------
# native rendering
# -----------------------------------------------------------------------------
# render_native view inlib notin groups_file
#   inlib rows: bookid TAB groupid TAB date TAB title TAB author TAB
#               series TAB seqnum TAB rating
#   notin rows: bookid TAB groupid TAB date
#   groups_file: groupid TAB groupname TAB bookcount per line
render_native() { # view inlib notin groups_file
    local view="$1" inlib="$2" notin="$3" groups="$4"
    local nnin plural sorted sect
    nnin="$(wc -l < "$inlib" | tr -d ' ')"
    plural="ies"; [[ "$nnin" == 1 ]] && plural="y"
    echo "native wishlists (library '$GROUP_LIBRARY'): $nnin entr$plural"
    echo
    case "$view" in
        title)  sect="title" ;;
        author) sect="author" ;;
        series) sect="series" ;;
        all)    sect="author title series" ;;
    esac
    for sect in $sect; do
        case "$sect" in
            title)  sorted="$tmp_dir/native.bytitle";  LC_ALL=C sort -t$'\t' -k2,2n -k4,4 "$inlib" > "$sorted" ;;
            author) sorted="$tmp_dir/native.byauthor"; LC_ALL=C sort -t$'\t' -k2,2n -k5,5 -k4,4 "$inlib" > "$sorted" ;;
            series) sorted="$tmp_dir/native.byseries"; LC_ALL=C sort -t$'\t' -k2,2n -k6,6 -k7,7n -k4,4 "$inlib" > "$sorted" ;;
        esac
        if [[ "$view" == "all" ]]; then
            echo "===== by $sect ====="
            echo
        fi
        awk -F'\t' -v GROUPS="$groups" -v SECT="$sect" '
        function gname(g)  { return (g in names ? names[g] : "group " g) }
        function gcount(g) { return (g in cnt ? cnt[g] : "?") }
        function trim(s)   { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        function extras(title_i, ser_i, num_i, rat_i,   e) {
            e = ""
            if (ser_i != "") e = ser_i ((num_i != "" && num_i + 0 > 0) ? " #" num_i : "")
            if (rat_i != "") e = e (e == "" ? "" : ", ") "rating " rat_i
            return e
        }
        BEGIN {
            while ((getline line < GROUPS) > 0) {
                split(line, f, "\t"); names[f[1]] = f[2]; cnt[f[1]] = f[3]
            }
            close(GROUPS)
            first = 1
        }
        {
            id = $1; grp = $2; dt = trim($3)
            title = $4; auth = trim($5); ser = trim($6); num = $7; rat = $8
            if (first || grp != cur) {
                cur = grp
                printf "== %s (%s) ==\n", gname(grp), gcount(grp)
                first = 0; cur_sub = ""
            }
            if (SECT == "author") {
                sublabel = (auth == "" ? "(unknown author)" : auth)
                if (sublabel != cur_sub) { printf "  %s\n", sublabel; cur_sub = sublabel }
                line = "    " id "  " title
                e = extras(0, ser, num, rat)
                if (e != "") line = line "  (" e ")"
                if (dt != "") line = line "  -- added " dt
                print line
            } else if (SECT == "series") {
                sublabel = (ser == "" ? "(no series)" : ser)
                if (sublabel != cur_sub) { printf "  %s\n", sublabel; cur_sub = sublabel }
                line = "    " ((num != "" && num + 0 > 0) ? "#" num "  " : "") title "  [" id "]"
                e = extras(0, "", "", rat)
                if (e != "") line = line "  (" e ")"
                if (dt != "") line = line "  -- added " dt
                print line
            } else {
                line = "    " title "  [" id "]"
                e = extras(0, ser, num, rat)
                if (e != "") line = line "  (" e ")"
                if (dt != "") line = line "  -- added " dt
                print line
            }
        }' "$sorted"
        [[ "$view" == "all" ]] && echo
    done
    if [[ -s "$notin" ]]; then
        echo "not in library (assigned in-app, absent from the catalog):"
        awk -F'\t' -v GROUPS="$groups" '
        function gname(g) { return (g in names ? names[g] : "group " g) }
        BEGIN {
            while ((getline line < GROUPS) > 0) { split(line, f, "\t"); names[f[1]] = f[2] }
            close(GROUPS)
        }
        {
            line = "  [?] " $1 " (" gname($2) ")"
            if ($3 != "" && $3 != "NULL") line = line "  -- added " $3
            print line
        }' "$notin"
    fi
}

# -----------------------------------------------------------------------------
# modes
# -----------------------------------------------------------------------------
clean="$tmp_dir/clean.tsv"
reject="$tmp_dir/reject.txt"
load_wishlist "$clean" "$reject"
if [[ -s "$reject" ]]; then
    while IFS= read -r line; do
        log "warn: skipping malformed wish entry: $line"
    done < "$reject"
fi

case "$MODE" in
    list)
        if (( $(wishlist_count "$clean") == 0 )); then
            echo "wish list is empty ($WISHLIST_FILE)"
            exit 0
        fi
        echo -e "bookid\tadded\tperiod\tstatus\tnote"
        cat "$clean"
        ;;

    add)
        if wish_has "$clean" "$ARG_ID"; then
            die "bookid $ARG_ID is already on the wish list"
        fi
        today="$(date +%Y-%m-%d)"
        row="$(printf '%s\t%s\t%s\t%s\t%s' "$ARG_ID" "$today" "$ARG_PERIOD" "wish" "$ARG_NOTE")"
        printf '%s\n' "$row" >> "$clean"
        write_wishlist "$clean"
        log "added: bookid=$ARG_ID period=${ARG_PERIOD:-(none)} note=${ARG_NOTE:-(none)}"
        ;;

    set-status)
        if ! wish_has "$clean" "$ARG_ID"; then
            die "bookid $ARG_ID is not on the wish list"
        fi
        ok=0
        for s in $STATUSES; do [[ "$ARG_STATUS" == "$s" ]] && ok=1; done
        (( ok )) || die "invalid status '$ARG_STATUS' (expected one of: $STATUSES)"
        awk -F'\t' -v id="$ARG_ID" -v st="$ARG_STATUS" \
            -v OFS='\t' 'BEGIN{found=0}
            $1==id { $4 = st; found=1 }
            { print }
            END { exit (found ? 0 : 1) }' "$clean" > "$clean.new" \
            && mv -f "$clean.new" "$clean" \
            || die "bookid $ARG_ID is not on the wish list"
        write_wishlist "$clean"
        log "status: bookid=$ARG_ID -> $ARG_STATUS"
        ;;

    remove)
        if ! wish_has "$clean" "$ARG_ID"; then
            die "bookid $ARG_ID is not on the wish list"
        fi
        awk -F'\t' -v id="$ARG_ID" '$1 != id' "$clean" > "$clean.new"
        mv -f "$clean.new" "$clean"
        write_wishlist "$clean"
        log "removed: bookid=$ARG_ID"
        ;;

    search)
        db_start
        rows="$(search_catalog "$ARG_SEARCH")" || die "catalog search failed; is MariaDB reachable?"
        if [[ -z "$rows" ]]; then
            log "no catalog matches for '$ARG_SEARCH'"
            exit 1
        fi
        echo -e "bookid\ttitle\tauthor"
        printf '%s\n' "$rows"
        ;;

    native)
        db_start
        groups="$(native_groups)" || die "native wishlist query failed; is MariaDB reachable?"
        if [[ -z "$groups" ]]; then
            log "no native wishlist entries for library '$GROUP_LIBRARY' (mark books in MultiLib.exe first)"
            exit 1
        fi
        # all assigned bookids + the (bookid, groupid, date) triples
        native_assignments > "$tmp_dir/native_assign.tsv" \
            || die "native assignment query failed"
        cut -f1 "$tmp_dir/native_assign.tsv" | sort -u -n > "$tmp_dir/native_ids.txt"
        native_join "$tmp_dir/native_ids.txt" > "$tmp_dir/native_catalog.tsv" \
            || die "native catalog join failed"
        : > "$tmp_dir/native_inlib.tsv"; : > "$tmp_dir/native_notin.tsv"
        printf '%s\n' "$groups" > "$tmp_dir/native_groups.tsv"
        # join assignments x catalog: in-library rows get the full row shape
        # (bookid groupid title author series seqnum rating), not-in rows
        # keep bookid + groupid for the separate listing
        awk -F'\t' -v OFS='\t' \
            -v CAT="$tmp_dir/native_catalog.tsv" \
            -v INLIB="$tmp_dir/native_inlib.tsv" \
            -v NOTIN="$tmp_dir/native_notin.tsv" '
        BEGIN { while ((getline line < CAT) > 0) { split(line, f, "\t"); cat[f[1]] = line } close(CAT) }
        {
            id = $1; grp = $2; dt = ($3 == "NULL" ? "" : $3)
            if (id in cat) {
                split(cat[id], c, "\t")
                print id, grp, dt, (c[2]=="" ? "(title unknown)" : c[2]), c[3], c[4], c[5], c[6] > INLIB
            } else {
                print id, grp, dt > NOTIN
            }
        }' "$tmp_dir/native_assign.tsv"
        render_native "$ARG_NATIVE" \
            "$tmp_dir/native_inlib.tsv" "$tmp_dir/native_notin.tsv" \
            "$tmp_dir/native_groups.tsv"
        ;;

    view)
        if (( $(wishlist_count "$clean") == 0 )); then
            echo "wish list is empty (add entries with --add BOOKID)"
            exit 0
        fi
        inlib="$tmp_dir/inlib.sorted"
        notin="$tmp_dir/notin.txt"
        catalog="$tmp_dir/catalog.tsv"
        if (( NO_DB )); then
            # offline: entries only, no join; titles are unknown without the DB
            awk -F'\t' -v OFS='\t' '{print $1, $4, $3, $2, $5, "(title unknown)", "", "", "", ""}' "$clean" > "$tmp_dir/inlib.tsv"
            : > "$notin"
            LC_ALL=C sort -t$'\t' -k3,3 -k7,7 "$tmp_dir/inlib.tsv" > "$inlib"
            render_view "$clean" "$inlib" "$notin"
            exit 0
        fi
        db_start
        cut -f1 "$clean" > "$tmp_dir/ids.txt"
        join_catalog "$tmp_dir/ids.txt" > "$catalog" || die "catalog join failed; is MariaDB reachable?"
        : > "$tmp_dir/inlib.tsv"; : > "$notin"   # awk only writes rows that exist
        # hash-join wish rows with catalog rows; split in/out of library
        awk -F'\t' -v OFS='\t' -v CATALOG="$catalog" -v INLIB="$tmp_dir/inlib.tsv" -v NOTIN="$notin" '
        BEGIN { while ((getline line < CATALOG) > 0) { split(line, f, "\t"); cat[f[1]] = line } close(CATALOG) }
        {
            id = $1
            if (id in cat) {
                split(cat[id], c, "\t")
                print id, $4, $3, $2, $5, (c[2]=="" ? "(title unknown)" : c[2]), c[3], c[4], c[5], c[6] > INLIB
            } else {
                print id, $4, $3, $2, $5 > NOTIN
            }
        }' "$clean"
        LC_ALL=C sort -t$'\t' -k3,3 -k7,7 -k8,8 -k9,9n -k6,6 "$tmp_dir/inlib.tsv" > "$inlib"
        LC_ALL=C sort -t$'\t' -k3,3 -k1,1n "$notin" -o "$notin"
        render_view "$clean" "$inlib" "$notin"
        if [[ -n "$ARG_EXPORT" ]]; then
            export_view "$ARG_EXPORT" "$clean" "$inlib" "$notin"
        fi
        ;;
esac

exit 0
