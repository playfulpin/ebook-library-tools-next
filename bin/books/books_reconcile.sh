#!/usr/bin/env bash

###############################################################################
# bin/books/books_reconcile.sh
#
# Version:       1.0.3
# Last updated:  2026-09-12
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Collection-progress report for the PERSONAL catalog.  The scope file is
#   the recommended-author list - authors with highly rated books in the
#   chosen genre, presented to the user as a catalog to collect from
#   (default: data/fixtures/authors_list_from_db.txt, regenerable from the
#   MariaDB catalog via bin/authors/authors_export.sh).  The library root
#   (default: /mnt/c/Backup_Go7/Books) is where the user keeps the books
#   (*.fb2 / *.zip) they have collected so far for later reading.
#
#   The report answers, per author:
#     collected        recommended author whose books are on disk (matched)
#     still to collect recommended author with nothing on disk yet - normal:
#                      the list is the target, the collection grows over time
#     empty            recommended author, folder present but zero files
#     beyond-scope     on disk but NOT on the current list - the user's own
#                      picks beyond the recommendation (e.g. gathered under
#                      an earlier scope); known to the catalog or unknown
#   Beyond-scope content is NOT an error: it is counted separately so the
#   headline progress always refers to the recommended list.
#
#   The library may be flat (<letter>/<author>[/series]) OR the nested
#   skeleton the merge pipeline produces
#   (<letter>/<prefix>/.../<author>[/series]); both are handled by
#   recognizing author folders BY NAME: a folder is an author folder iff its
#   basename matches a known author name (scope union catalog), so
#   structural skeleton-prefix dirs are never mistaken for authors and
#   authors at any depth are found.
#
#   When the MariaDB catalog is reachable (default), the mlauthorname
#   snapshot is pulled so each row also carries the catalog book count
#   (TotalCount) next to the on-disk file count; --no-db skips the pull
#   (orphans then classify as unknown, counts show "-").
#   The MariaDB lifecycle is shared with bin/authors/authors_export.sh via
#   lib/mariadb_lifecycle.sh (auto-start when down, graceful stop on exit
#   when this process started it).
#
#   Output: summary on stdout + one TSV report per run in the report dir
#   (processed_at, author, in_scope, on_disk, catalog_known, catalog_books,
#   disk_files, status).  Each run also writes the next-round shopping
#   list (books_reconcile_to_collect_<ts>.txt): the recommended authors with no
#   books on disk yet, one canonical name per line in byte order - the
#   same shape as the author-list fixture, so it can feed the merge
#   pipeline directly.  In DB mode it additionally writes the beyond-books
#   review export (books_reconcile_beyond_books_<ts>.tsv): every on-disk file
#   attributed to a beyond-list author as author<TAB>relative-path, the
#   per-file content behind "books (beyond list authors)", so the user
#   can review whether those books should stay.  Read-only against the
#   library.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/books/books_reconcile.sh [options]
#
#   Options:
#       -l, --library-root DIR   library root to scan
#                                [default: /mnt/c/Backup_Go7/Books]
#       -s, --scope-file FILE    recommended-author list the collection grows toward
#                                [default: data/fixtures/authors_list_from_db.txt]
#       -r, --report-dir DIR     directory for the TSV report
#                                [default: /mnt/c/Backup_Go7/merge-reports]
#           --no-db              skip the mlauthorname snapshot
#       -n, --dry-run            analyze and summarize, write no report file
#       -d, --debug              print verbose diagnostics to stderr
#       -h, --help               show this help
#       -v, --version            print version and exit
#
#   Exit codes:
#       0   success (or --dry-run)
#       1   operational failure
#       2   usage error
#
#   Environment (all optional; also settable in config/books_reconcile.conf):
#       RECON_LIBRARY_ROOT / RECON_SCOPE_FILE / RECON_REPORT_DIR / RECON_DB
#       plus the MYSQL_* and MARIA_* contract from BookTracker-import
#       (defaults in lib/mariadb_lifecycle.sh).
#
###############################################################################

set -euo pipefail

# --- shared infrastructure (refactor Phase 3) ----------------------------------
# common.sh sets set -Eeuo pipefail, resolves SCRIPT_DIR/PROJECT_ROOT at any
# bin/ depth, and provides log/debug/die.
# shellcheck source=../../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"
common_init

# SCRIPT_VERSION is parsed from this file's own header (version-sync contract).
# shellcheck disable=SC2155  # sed+head pipeline cannot fail; masking not a concern
readonly SCRIPT_VERSION="$(sed -n 's/^# Version:[[:space:]]*//p' "$0" | head -n 1)"

# --- config file (flag > env > config > built-in default) --------------------
CONF_FILE="${RECON_CONF_FILE:-$PROJECT_ROOT/config/books_reconcile.conf}"
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
fi

RECON_LIBRARY_ROOT="${RECON_LIBRARY_ROOT:-/mnt/c/Backup_Go7/Books}"
RECON_SCOPE_FILE="${RECON_SCOPE_FILE:-$PROJECT_ROOT/data/fixtures/authors_list_from_db.txt}"
RECON_REPORT_DIR="${RECON_REPORT_DIR:-/mnt/c/Backup_Go7/merge-reports}"
RECON_DB="${RECON_DB:-1}"

# shellcheck disable=SC2034  # read by lib/mariadb_lifecycle.sh + lib/logging.sh at runtime
DEBUG=0
# shellcheck disable=SC2034  # read by lib/mariadb_lifecycle.sh at runtime
DRY_RUN=0

# --- shared MariaDB lifecycle (lib/mariadb_lifecycle.sh) -----------------------
# shellcheck source=../lib/mariadb_lifecycle.sh
source "$PROJECT_ROOT/lib/mariadb_lifecycle.sh"

cleanup() {
    [[ -n "${tmp_dir:-}" ]] && rm -rf "$tmp_dir"
    mariadb_stop_if_started
    return 0
}
trap cleanup EXIT

print_help() {
    cat >&2 <<'EOF'
Usage: books_reconcile.sh [options]

Track the PERSONAL catalog's collection progress against the
recommended-author list (the scope file, e.g.
data/fixtures/authors_list_from_db.txt): how many recommended authors'
books are collected on disk, how many are still to collect, and what
extra content sits beyond the list (the user's own picks, known or
unknown to the catalog), with catalog book counts vs on-disk file
counts.  The library may be flat (<letter>/<author>[/series]) or the
nested skeleton the merge pipeline produces
(<letter>/<prefix>/.../<author>[/series]); a folder is an author folder
when its basename matches a known author name (scope union catalog), so  authors at any depth are found and structural prefix dirs are ignored.
  Each run also writes a next-round shopping list next to the TSV report:
  the recommended authors with no books on disk yet, one canonical name
  per line (byte order), ready to feed the merge pipeline.  In DB mode it
  additionally writes the beyond-books review export - every on-disk file
  attributed to a beyond-list author, author + relative path per line, to
  review whether those books should stay.

Options:
  -l, --library-root DIR   library root to scan
                           [default: /mnt/c/Backup_Go7/Books]
  -s, --scope-file FILE    recommended-author list the collection grows toward
                           [default: data/fixtures/authors_list_from_db.txt]
  -r, --report-dir DIR     directory for the TSV report
                           [default: /mnt/c/Backup_Go7/merge-reports]
      --no-db              skip the mlauthorname snapshot
  -n, --dry-run            analyze and summarize, write no report file
  -d, --debug              verbose diagnostics on stderr
  -h, --help               show this help
  -v, --version            print version and exit

Exit codes: 0 success, 1 operational failure, 2 usage error.
EOF
}

# --- arg parsing --------------------------------------------------------------
while (( $# > 0 )); do
    case "$1" in
        -l|--library-root)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a DIR argument" >&2; exit 2; }
            RECON_LIBRARY_ROOT="$2"; shift 2 ;;
        --library-root=*) RECON_LIBRARY_ROOT="${1#*=}"; shift ;;
        -s|--scope-file)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a FILE argument" >&2; exit 2; }
            RECON_SCOPE_FILE="$2"; shift 2 ;;
        --scope-file=*) RECON_SCOPE_FILE="${1#*=}"; shift ;;
        -r|--report-dir)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a DIR argument" >&2; exit 2; }
            RECON_REPORT_DIR="$2"; shift 2 ;;
        --report-dir=*) RECON_REPORT_DIR="${1#*=}"; shift ;;
        --no-db) RECON_DB=0; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -d|--debug)
            # shellcheck disable=SC2034  # read by lib/logging.sh at runtime
            DEBUG=1; shift ;;
        -h|--help)    print_help; exit 0 ;;
        -v|--version) echo "bin/books/books_reconcile.sh v$SCRIPT_VERSION"; exit 0 ;;
        *) echo "Error: unknown option '$1'" >&2; echo "Try '$0 --help'." >&2; exit 2 ;;
    esac
done

# --- validation ----------------------------------------------------------------
[[ -d "$RECON_LIBRARY_ROOT" ]] || die "library root not found: $RECON_LIBRARY_ROOT"
[[ -f "$RECON_SCOPE_FILE" ]] || die "scope file not found: $RECON_SCOPE_FILE"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/reconcile.XXXXXX")"

# --- 1. scope: normalize the author list (BOM/CR, trim, blanks) ---------------
sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -e 's/[[:space:]]*$//' "$RECON_SCOPE_FILE" \
    | grep -v '^$' | LC_ALL=C sort -u > "$tmp_dir/scope.txt"
debug "scope: $(wc -l < "$tmp_dir/scope.txt" | tr -d ' ') author(s) from $RECON_SCOPE_FILE"

# --- 2. catalog snapshot (mlauthorname.FullName / TotalCount) ------------------
# Fetched BEFORE the disk walk: the catalog name set tells the disk walk which
# folders are author folders (structural skeleton-prefix dirs share the tree
# with them in the nested layout).
catalog_have=0
: > "$tmp_dir/catalog.txt"
if (( RECON_DB )); then
    if ! command -v "${MYSQL_CLIENT:-mysql}" >/dev/null 2>&1; then
        die "${MYSQL_CLIENT:-mysql} not found; install a mysql/mariadb client or use --no-db"
    fi
    mariadb_maybe_start \
        || die "cannot start MariaDB (accept the UAC prompt or run WSL2 elevated, or start the server manually)"

    mysql_args=("${MYSQL_CLIENT:-mysql}")
    [[ -n "${MYSQL_HOST:-}" ]] && mysql_args+=(-h "$MYSQL_HOST" --protocol=TCP)
    [[ -n "${MYSQL_PORT:-}" ]] && mysql_args+=(-P "$MYSQL_PORT")
    [[ -n "${MYSQL_USER:-}" ]] && mysql_args+=(-u "$MYSQL_USER")
    [[ -n "${MYSQL_EXTRA_ARGS:-}" ]] && mysql_args+=("$MYSQL_EXTRA_ARGS")
    charset="utf8"
    case " ${MYSQL_EXTRA_ARGS:-} " in
        *" --default-character-set="*)
            charset="${MYSQL_EXTRA_ARGS##*--default-character-set=}"
            charset="${charset%% *}" ;;
    esac
    mysql_args+=(--init-command="SET NAMES $charset")
    [[ -n "${MYSQL_DATABASE:-}" ]] && mysql_args+=("$MYSQL_DATABASE")
    mysql_args+=(-B --skip-column-names --raw)

    debug "catalog snapshot: SELECT FullName, TotalCount FROM mlauthorname"
    if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
        MYSQL_PWD="$MYSQL_PASSWORD" "${mysql_args[@]}" \
            -e "SELECT FullName, TotalCount FROM mlauthorname" > "$tmp_dir/catalog_raw.tsv" 2> "$tmp_dir/catalog_err.txt" || true
    else
        "${mysql_args[@]}" \
            -e "SELECT FullName, TotalCount FROM mlauthorname" > "$tmp_dir/catalog_raw.tsv" 2> "$tmp_dir/catalog_err.txt" || true
    fi
    if [[ ! -s "$tmp_dir/catalog_raw.tsv" ]]; then
        sed 's/^/  /' "$tmp_dir/catalog_err.txt" >&2 || true
        die "mlauthorname snapshot failed; is MariaDB reachable? (rerun with --no-db to skip)"
    fi
    # FullName can repeat (homonyms): keep the highest TotalCount; trim legacy
    # trailing whitespace before using the name as a lookup key.
    awk -F'\t' '{
        sub(/[[:space:]]+$/, "", $1)
        if ($1 == "" || $1 == "NULL") next
        tc = ($2+0 > 0) ? $2+0 : 0
        if (tc > max[$1]) max[$1] = tc
    } END { for (n in max) print n "\t" max[n] }' "$tmp_dir/catalog_raw.tsv" \
        | LC_ALL=C sort -u > "$tmp_dir/catalog.txt"
    catalog_have=1
    debug "catalog snapshot: $(wc -l < "$tmp_dir/catalog.txt" | tr -d ' ') distinct FullName(s)"
fi

# --- 3. disk walk ----------------------------------------------------------------
# desktop.ini is Windows metadata and never counts as a book file.
#
# DB mode (catalog_have=1): the library may be flat (<letter>/<author>[/series])
# or the nested skeleton the merge pipeline produces
# (<letter>/<prefix>/.../<author>[/series]).  The catalog name set tells the
# two apart: a folder is an AUTHOR folder iff its basename matches a known
# author name (scope union catalog); structural prefix dirs never match a
# full author name.  Every FILE is attributed to its NEAREST ancestor author
# folder, so nested prefix dirs never steal files from the author folders
# below them.  Files whose ancestor chain contains no author folder are stray
# content (orphan), attributed to the folder directly holding them.
#
# --no-db mode (catalog_have=0): without the name set a nested skeleton
# cannot be told from series dirs, so the tool assumes the flat layout:
# author folders = dirs directly under a letter dir (depth 2), whole-subtree
# file counts (the historical behavior).
if (( catalog_have )); then
    : > "$tmp_dir/names.txt"
    cat "$tmp_dir/scope.txt" >> "$tmp_dir/names.txt"
    cut -f1 "$tmp_dir/catalog.txt" >> "$tmp_dir/names.txt"
    LC_ALL=C sort -u "$tmp_dir/names.txt" -o "$tmp_dir/names.txt"
    gawk '{ print tolower($0) }' "$tmp_dir/names.txt" \
        | LC_ALL=C sort -u > "$tmp_dir/names_lower.txt"

    find "$RECON_LIBRARY_ROOT" -mindepth 2 -type d \
        | sed "s|^$RECON_LIBRARY_ROOT/||" \
        | LC_ALL=C sort > "$tmp_dir/all_dirs.txt"

    # tag author folders (exact or ASCII-casefold name match) in one pass:
    # hold the name sets in memory instead of grep-ing 200k+ names per dir
    : > "$tmp_dir/author_dirs.txt"
    gawk -v names_f="$tmp_dir/names.txt" -v lower_f="$tmp_dir/names_lower.txt" '
FILENAME == names_f {
    names[$0] = 1
    next
}
FILENAME == lower_f {
    lower[tolower($0)] = 1
    next
}
{
    rel = $0
    base = rel
    sub(/.*\//, "", base)
    if (base in names || tolower(base) in lower) print rel
}
' "$tmp_dir/names.txt" "$tmp_dir/names_lower.txt" "$tmp_dir/all_dirs.txt" > "$tmp_dir/author_dirs.txt"

    declare -A author_set=()
    while IFS= read -r rel; do
        author_set["$rel"]=1
    done < "$tmp_dir/author_dirs.txt"

    # emit one row per author folder (possibly 0 files -> "empty" later)
    : > "$tmp_dir/disk_raw.txt"
    while IFS= read -r rel; do
        printf 'A\t%s\t0\n' "${rel##*/}" >> "$tmp_dir/disk_raw.txt"
    done < "$tmp_dir/author_dirs.txt"

    # nearest-author-ancestor lookup: walk up from the file's parent dir; the
    # deepest ancestor present in author_set wins.
    nearest_author() { # relpath -> author relpath (or empty when none)
        local rel="$1"
        while [[ "$rel" == */* ]]; do
            rel="${rel%/*}"
            if [[ -n "${author_set[$rel]+x}" ]]; then
                echo "$rel"
                return 0
            fi
        done
        return 1
    }

    # per-file attribution capture (author-or-folder name + relative path),
    # later filtered to the beyond-list authors for the review export
    : > "$tmp_dir/attrib.txt"
    while IFS= read -r file; do
        rel="${file#"$RECON_LIBRARY_ROOT"/}"
        base="${rel##*/}"
        [[ "$base" == desktop.ini || "$base" == .* ]] && continue
        if owner="$(nearest_author "$rel")"; then
            printf 'A\t%s\t1\n' "${owner##*/}" >> "$tmp_dir/disk_raw.txt"
            printf '%s\t%s\n' "${owner##*/}" "$rel" >> "$tmp_dir/attrib.txt"
        else
            # stray: no author folder above it; attribute to the folder that
            # directly holds the file (its parent relpath)
            parent="${rel%/*}"
            printf 'O\t%s\t1\n' "${parent##*/}" >> "$tmp_dir/disk_raw.txt"
            printf '%s\t%s\n' "${parent##*/}" "$rel" >> "$tmp_dir/attrib.txt"
        fi
    done < <(find "$RECON_LIBRARY_ROOT" -type f | LC_ALL=C sort)
    unset author_set

    awk -F'\t' '{ sum[$2] += $3 } END { for (n in sum) print n "\t" sum[n] }' \
        "$tmp_dir/disk_raw.txt" | LC_ALL=C sort -u > "$tmp_dir/disk.txt"
else
    # no-DB / flat-layout fallback: author = depth-2 dir under a letter
    : > "$tmp_dir/disk.txt"
    while IFS= read -r dir; do
        name="$(basename "$dir")"
        [[ "$name" == .* ]] && continue
        files="$(find "$dir" -type f ! -iname desktop.ini 2>/dev/null | wc -l | tr -d ' ')"
        printf '%s\t%s\n' "$name" "$files" >> "$tmp_dir/disk.txt"
    done < <(find "$RECON_LIBRARY_ROOT" -mindepth 2 -maxdepth 2 -type d | LC_ALL=C sort)
    LC_ALL=C sort -u "$tmp_dir/disk.txt" -o "$tmp_dir/disk.txt"
fi
# Drop book-less folders that are not recommended authors: a zero-file dir
# whose name is not on the list is not an author-with-books (structural
# skeleton-prefix dirs that happen to match a catalog name, or folders left
# with only desktop.ini metadata).  Recommended authors keep their row, so
# an in-scope empty folder is still reported as "empty".
awk -F'\t' 'NR == FNR { sc[$0] = 1; next } ($2 + 0 > 0) || ($1 in sc) { print }' \
    "$tmp_dir/scope.txt" "$tmp_dir/disk.txt" > "$tmp_dir/disk.filtered"
mv "$tmp_dir/disk.filtered" "$tmp_dir/disk.txt"
debug "disk: $(wc -l < "$tmp_dir/disk.txt" | tr -d ' ') author/beyond-scope folder(s), "\
     "$(awk -F'\t' '{s+=$2} END{print s+0}' "$tmp_dir/disk.txt") file(s)"

# --- 4. classify in a single awk pass -------------------------------------------
# exact byte match first; ASCII-casefold is the fallback (folder names were
# created from the scope list, so case differences mean hand-added folders).
# shellcheck disable=SC2016
gawk -F'\t' -v OFS='\t' -v ts="$(date '+%Y-%m-%d %H:%M:%S')" \
     -v scope_f="$tmp_dir/scope.txt" -v disk_f="$tmp_dir/disk.txt" \
     -v cat_f="$tmp_dir/catalog.txt" -v have_cat="$catalog_have" '
FILENAME == scope_f {
    s[$0] = 1
    sci[tolower($0)] = $0
    next
}
FILENAME == disk_f {
    d[$1] = $2
    dci[tolower($1)] = $1
    next
}
FILENAME == cat_f {
    c[$1] = $2
    cci[tolower($1)] = 1
    next
}
END {
    delete ARGV
    PROCINFO["sorted_in"] = "@ind_str_asc"
    # union of all names to report (scope names + disk folder names)
    for (n in s) u[n] = 1
    for (n in d) u[n] = 1
    for (n in u) {
        in_scope = (n in s) ? 1 : 0
        on_disk  = (n in d) ? 1 : 0
        files    = on_disk ? d[n] : "-"
        # casefold fallback: a disk folder that is a case variant of a scope
        # name, or a scope name whose disk folder is a case variant
        matched_ci = 0
        if (!in_scope && on_disk && (tolower(n) in sci)) matched_ci = 1
        if (in_scope && !on_disk && (tolower(n) in dci)) matched_ci = 1
        known = 0
        books = "-"
        if (have_cat) {
            if (n in c) { known = 1; books = c[n] }
            else if (tolower(n) in cci) known = 1
        }
        if (matched_ci) { status = "matched" }
        else if (in_scope && on_disk && files == 0) { status = "empty" }
        else if (in_scope && on_disk)               { status = "matched" }
        else if (in_scope)                          { status = "missing" }
        else if (known == 1)                        { status = "orphan-known" }
        else                                        { status = "orphan-unknown" }
        cnt[status]++
        print ts "\t" n "\t" in_scope "\t" on_disk "\t" known "\t" books "\t" files "\t" status
    }
    # status counts go to stderr (captured by the shell into summary.txt)
    for (st in cnt) print st, cnt[st] > "/dev/stderr"
}
' "$tmp_dir/scope.txt" "$tmp_dir/disk.txt" "$tmp_dir/catalog.txt" \
    > "$tmp_dir/report.tsv" 2> "$tmp_dir/summary.txt" || die "classification failed"

LC_ALL=C sort -t $'\t' -k8,8 -k2,2 "$tmp_dir/report.tsv" -o "$tmp_dir/report.tsv"

# --- 5. summary + report ---------------------------------------------------------
declare -A counts
while read -r st n; do
    counts[$st]=$n
done < "$tmp_dir/summary.txt"
scope_total="$(wc -l < "$tmp_dir/scope.txt" | tr -d ' ')"
# Distinct RECOMMENDED authors with books on disk: only rows that are in
# scope and matched.  A case-variant disk folder of a list author (matched
# via the ASCII-casefold fallback) yields TWO matched rows - the canonical
# scope row and the variant disk row - so counting rows would overstate
# the number of collected authors; counting in-scope rows keeps the scope
# partition exact (collected + still-to-collect + empty == scope_total).
collected="$(awk -F'\t' '$3 == 1 && $8 == "matched" {c++} END {print c+0}' "$tmp_dir/report.tsv")"
# Split the on-disk book count by attribution.  The report has NO header
# row (first line is a data row), so no line is skipped: every row with a
# numeric file count contributes to the total, and the file count of each
# collected (matched) / beyond-scope (orphan-*) author lands in its bucket.
read -r files_collected files_extra files_total < <(awk -F'\t' '
    $7 != "-" {
        total += $7
        if ($8 == "matched") collected += $7
        else if ($8 == "orphan-known" || $8 == "orphan-unknown") extra += $7
    }
    END { printf "%d %d %d\n", collected+0, extra+0, total+0 }' "$tmp_dir/report.tsv")
pct="$(awk -v a="$collected" -v b="$scope_total" 'BEGIN{ if (b+0 > 0) printf "%.1f", a*100/b; else printf "0.0" }')"
beyond_total="$(( ${counts[orphan-known]:-0} + ${counts[orphan-unknown]:-0} ))"
loaded_total="$(( collected + beyond_total ))"
# "remaining to collect" = recommended authors with no books on disk yet:
# the missing rows plus the empty-folder rows (an empty folder holds no
# books, so that author still needs collecting too); with no empty folders
# it is simply scope_total - collected.
remaining="$(( ${counts[missing]:-0} + ${counts[empty]:-0} ))"
# Percentage bases: the from-list share refers to the recommended list
# (coverage); the beyond-list share refers to what is actually loaded
# (composition of the loaded set).  The two "listed / unlisted ratio" lines
# express the listed side as a share of its combined total (listed /
# (listed + unlisted)), i.e. the complement of the beyond-list share.
pct_listed_of_loaded="$(awk -v a="$collected" -v b="$loaded_total" 'BEGIN{ if (b+0 > 0) printf "%.1f", a*100/b; else printf "0.0" }')"
beyond_pct="$(awk -v a="$beyond_total" -v b="$loaded_total" 'BEGIN{ if (b+0 > 0) printf "%.1f", a*100/b; else printf "0.0" }')"
pct_listed_books="$(awk -v a="$files_collected" -v b="$files_total" 'BEGIN{ if (b+0 > 0) printf "%.1f", a*100/b; else printf "0.0" }')"
pct_beyond_books="$(awk -v a="$files_extra" -v b="$files_total" 'BEGIN{ if (b+0 > 0) printf "%.1f", a*100/b; else printf "0.0" }')"
printf 'collection progress (recommended-author list: %s author(s)):\n' "$scope_total"
printf '  %-33s %6s  %s\n' 'authors (from list)'              "$collected"    "$pct% of the list"
printf '  %-33s %6s  %s\n' 'authors (beyond list)'            "$beyond_total" "$beyond_pct% of all loaded authors"
printf '  %-33s %6s%%\n'   'listed / unlisted author ratio'   "$pct_listed_of_loaded"
printf '  %-33s %6s\n'     'authors (remaining to collect)'   "$remaining"
printf '  %-33s %6s\n'     'books on disk'                    "$files_total"
printf '  %-33s %6s  %s\n' 'books (from listed authors)'      "$files_collected" "$pct_listed_books% of books on disk"
printf '  %-33s %6s  %s\n' 'books (beyond list authors)'      "$files_extra"     "$pct_beyond_books% of books on disk"
printf '  %-33s %6s%%\n'   'listed / unlisted books ratio'    "$pct_listed_books"
printf '  %-33s %6s\n'     'empty (folder, no books)'         "${counts[empty]:-0}"

stamp="$(date '+%Y%m%d-%H%M%S')"
report_name="books_reconcile_$stamp.tsv"
to_collect_name="books_reconcile_to_collect_$stamp.txt"
# Next-round shopping list: every recommended author with no books on disk
# yet (missing rows + empty-folder rows), one canonical name per line in
# byte order - the same shape as the author-list fixture.
awk -F'\t' '$3 == 1 && ($8 == "missing" || $8 == "empty") { print $2 }' \
    "$tmp_dir/report.tsv" | LC_ALL=C sort -u > "$tmp_dir/to_collect.txt"
to_collect_total="$(wc -l < "$tmp_dir/to_collect.txt" | tr -d ' ')"
if (( DRY_RUN )); then
    log "dry-run: report would be written to $RECON_REPORT_DIR/$report_name"
    log "dry-run: to-collect list ($to_collect_total author(s)) would be written to $RECON_REPORT_DIR/$to_collect_name"
else
    mkdir -p "$RECON_REPORT_DIR"
    cp "$tmp_dir/report.tsv" "$RECON_REPORT_DIR/$report_name"
    log "info : report written to $RECON_REPORT_DIR/$report_name"
    cp "$tmp_dir/to_collect.txt" "$RECON_REPORT_DIR/$to_collect_name"
    log "info : to-collect list ($to_collect_total author(s)) written to $RECON_REPORT_DIR/$to_collect_name"
fi

# Beyond-books review export: every on-disk file attributed to a
# beyond-list author (orphan-known / orphan-unknown rows), as
# author<TAB>relative-path lines sorted by author then path - the content
# the summary reports as "books (beyond list authors)", listed per file so
# the user can review whether those books should stay.  Requires DB mode:
# per-file attribution is only available when the catalog name set tells
# the walk which folders are author folders.
if (( catalog_have )); then
    awk -F'\t' '$8 == "orphan-known" || $8 == "orphan-unknown" { print $2 }' \
        "$tmp_dir/report.tsv" | LC_ALL=C sort -u > "$tmp_dir/orphan_names.txt"
    awk -F'\t' 'NR == FNR { keep[$1] = 1; next } keep[$1] { print }' \
        "$tmp_dir/orphan_names.txt" "$tmp_dir/attrib.txt" \
        | LC_ALL=C sort -t $'\t' -k1,1 -k2,2 > "$tmp_dir/beyond_books.tsv"
    beyond_books_name="books_reconcile_beyond_books_$stamp.tsv"
    beyond_files="$(wc -l < "$tmp_dir/beyond_books.tsv" | tr -d ' ')"
    beyond_authors="$(cut -f1 "$tmp_dir/beyond_books.tsv" | sort -u | wc -l | tr -d ' ')"
    if (( DRY_RUN )); then
        log "dry-run: beyond-books export ($beyond_files file(s) under $beyond_authors author(s)) would be written to $RECON_REPORT_DIR/$beyond_books_name"
    else
        cp "$tmp_dir/beyond_books.tsv" "$RECON_REPORT_DIR/$beyond_books_name"
        log "info : beyond-books export ($beyond_files file(s) under $beyond_authors author(s)) written to $RECON_REPORT_DIR/$beyond_books_name"
    fi
else
    log "warn : beyond-books export skipped (needs DB mode for per-file attribution; rerun without --no-db to review beyond-list books)"
fi
