#!/usr/bin/env bash

###############################################################################
# bin/books/books_estimate.sh
#
# Version:       1.0.0
# Last updated:  2026-09-12
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Estimate the download size of the next collecting round BEFORE anything
#   is downloaded.  Given a to-collect author list (one canonical name per
#   line - e.g. the books_reconcile.sh shopping-list export
#   books_reconcile_to_collect_<ts>.txt, or the recommended-author fixture
#   data/fixtures/authors_list_from_db.txt), it sums the real per-book
#   sizes the catalog stores (mlbook.filesize) for those authors and prints
#   two DISTINCT-BOOK totals (a co-authored book counts once even when
#   several list authors wrote it - the honest "how much will I download"):
#
#     qualifying   Russian books rated 4/5 whose genre belongs to the
#                  "Фантастика" family - exactly the list's own criteria
#     full oeuvre  ALL Russian books by those authors, rated or not
#
#   List names are resolved to catalog authorids via an mlauthorname dump
#   with the same trailing-whitespace normalization the exporter applies
#   (so an exported list matches 1:1 - unmatched names are counted and
#   reported), and the aggregates are restricted with the resulting integer
#   IN-list, which the optimizer handles far better than a per-name join.
#
#   Every run also writes a per-author breakdown TSV next to the summary,
#   SORTED TOP-RATED FIRST (5-rated qualifying books desc, then qualifying
#   book count desc): author, qualifying books, qualifying bytes,
#   5-rated qualifying books, average qualifying rating, full-oeuvre books,
#   full-oeuvre bytes.  Per-author rows attribute co-authored books to each
#   author, so their sums exceed the distinct-book totals by exactly the
#   multi-author overlap; the top 10 of that order are printed in the
#   summary so the round can be prioritized author by author.
#
#   Connection settings and the MariaDB lifecycle are shared via
#   lib/mariadb_lifecycle.sh (same MYSQL_* / MARIA_* contract as
#   BookTracker-import): a stopped server is started (elevated PowerShell)
#   and stopped again on exit only when this script started it; an
#   already-running server is left untouched.  --dry-run never starts or
#   stops the server and writes no breakdown file.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/books/books_estimate.sh [options]
#
#   Options:
#       -i, --input-file FILE   to-collect author list (one name per line)
#                               [default: data/fixtures/authors_list_from_db.txt]
#       -o, --output FILE       per-author breakdown TSV (top-rated first)
#                               [default: <report-dir>/books_estimate_<ts>.tsv]
#       -r, --report-dir DIR    directory for the breakdown file
#                               [default: /mnt/c/Backup_Go7/merge-reports]
#       -n, --dry-run           connect, compute, summarize; write nothing
#       -d, --debug             print verbose diagnostics to stderr
#       -h, --help              show this help
#       -v, --version           print version and exit
#
#   Exit codes:
#       0   success (or --dry-run)
#       1   operational failure (client missing, server down, bad query)
#       2   usage error
#
#   Environment (all optional; also settable in config/books_estimate.conf):
#       ESTIMATE_INPUT_FILE / ESTIMATE_REPORT_DIR
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
CONF_FILE="${ESTIMATE_CONF_FILE:-$PROJECT_ROOT/config/books_estimate.conf}"
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
fi

ESTIMATE_INPUT_FILE="${ESTIMATE_INPUT_FILE:-$PROJECT_ROOT/data/fixtures/authors_list_from_db.txt}"
ESTIMATE_REPORT_DIR="${ESTIMATE_REPORT_DIR:-/mnt/c/Backup_Go7/merge-reports}"

OUTPUT_FILE=""
# shellcheck disable=SC2034  # read by lib/mariadb_lifecycle.sh + lib/logging.sh at runtime
DEBUG=0
# shellcheck disable=SC2034  # read by lib/mariadb_lifecycle.sh at runtime
DRY_RUN=0

# --- shared MariaDB lifecycle (lib/mariadb_lifecycle.sh) -----------------------
# shellcheck source=../lib/mariadb_lifecycle.sh
source "$PROJECT_ROOT/lib/mariadb_lifecycle.sh"

# Shared mysql argv assembly (lib/database.sh — Follow-It §8: the DB client
# command line is a hard boundary owned by the lib, not by tools).
# shellcheck source=../lib/database.sh
source "$PROJECT_ROOT/lib/database.sh"

cleanup() {
    [[ -n "${tmp_dir:-}" ]] && rm -rf "$tmp_dir"
    mariadb_stop_if_started
    return 0
}
trap cleanup EXIT

print_help() {
    cat >&2 <<'EOF'
Usage: books_estimate.sh [options]

Estimate the download size of the next collecting round straight from the
catalog, BEFORE anything is downloaded.  The input is a to-collect author
list (one canonical name per line - e.g. the reconcile shopping-list export
books_reconcile_to_collect_<ts>.txt, or data/fixtures/authors_list_from_db.txt).
Two DISTINCT-BOOK totals are computed from real per-book sizes
(mlbook.filesize) - a co-authored book counts once even when several list
authors wrote it, so the totals are the honest "how much will I download":

  qualifying   Russian books rated 4/5 in the "Фантастика" genre family -
               exactly the list's own criteria
  full oeuvre  ALL Russian books by those authors, rated or not

List names are resolved to catalog authorids via an mlauthorname dump with
the same whitespace normalization the exporter applies (unmatched names are
counted and reported), and the aggregates are restricted with the resulting
integer IN-list.  Every run also writes a per-author breakdown TSV sorted
TOP-RATED FIRST (5-rated qualifying books desc, then qualifying count desc)
so the round can be prioritized author by author; per-author rows attribute
co-authored books to each author, so their sums exceed the distinct-book
totals by exactly the multi-author overlap.  The top 10 are printed in the
summary.

The MariaDB lifecycle is shared with the other DB tools
(lib/mariadb_lifecycle.sh): a stopped server is started and stopped again
on exit only when this script started it; an already-running server is
left untouched.  --dry-run never starts or stops the server and writes no
breakdown file.

Options:
  -i, --input-file FILE   to-collect author list (one name per line)
                          [default: data/fixtures/authors_list_from_db.txt]
  -o, --output FILE       per-author breakdown TSV (top-rated first)
                          [default: <report-dir>/books_estimate_<ts>.tsv]
  -r, --report-dir DIR    directory for the breakdown file
                          [default: /mnt/c/Backup_Go7/merge-reports]
  -n, --dry-run           connect, compute, summarize; write nothing
  -d, --debug             verbose diagnostics on stderr
  -h, --help              show this help
  -v, --version           print version and exit

Exit codes: 0 success, 1 operational failure, 2 usage error.
EOF
}

# --- arg parsing --------------------------------------------------------------
while (( $# > 0 )); do
    case "$1" in
        -i|--input-file)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a FILE argument" >&2; exit 2; }
            ESTIMATE_INPUT_FILE="$2"; shift 2 ;;
        --input-file=*) ESTIMATE_INPUT_FILE="${1#*=}"; shift ;;
        -o|--output)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a FILE argument" >&2; exit 2; }
            OUTPUT_FILE="$2"; shift 2 ;;
        --output=*) OUTPUT_FILE="${1#*=}"; shift ;;
        -r|--report-dir)
            [[ $# -ge 2 ]] || { echo "Error: $1 needs a DIR argument" >&2; exit 2; }
            ESTIMATE_REPORT_DIR="$2"; shift 2 ;;
        --report-dir=*) ESTIMATE_REPORT_DIR="${1#*=}"; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -d|--debug)
            # shellcheck disable=SC2034  # read by lib/logging.sh at runtime
            DEBUG=1; shift ;;
        -h|--help)    print_help; exit 0 ;;
        -v|--version) echo "bin/books/books_estimate.sh v$SCRIPT_VERSION"; exit 0 ;;
        *) echo "Error: unknown option '$1'" >&2; echo "Try '$0 --help'." >&2; exit 2 ;;
    esac
done

# --- validation ----------------------------------------------------------------
[[ -f "$ESTIMATE_INPUT_FILE" ]] || die "input file not found: $ESTIMATE_INPUT_FILE"
if ! command -v "${MYSQL_CLIENT:-mysql}" >/dev/null 2>&1; then
    die "${MYSQL_CLIENT:-mysql} not found; install a mysql/mariadb client or set MYSQL_CLIENT"
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/estimate.XXXXXX")"

# --- 1. normalize the to-collect list (BOM/CR, trim, blanks, byte order) ------
sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -e 's/[[:space:]]*$//' "$ESTIMATE_INPUT_FILE" \
    | grep -v '^$' | LC_ALL=C sort -u > "$tmp_dir/list.txt"
list_count="$(wc -l < "$tmp_dir/list.txt" | tr -d ' ')"
debug "list: $list_count author(s) from $ESTIMATE_INPUT_FILE"

# --- 2. MariaDB lifecycle + client argv (password never included) --------------
mariadb_maybe_start \
    || die "cannot start MariaDB (accept the UAC prompt or run WSL2 elevated, or start the server manually)"

mysql_args=()
while IFS= read -r arg; do mysql_args+=("$arg"); done < <(db_mysql_argv "${MYSQL_DATABASE:-}")
# (mapfile not used: this block runs under `set -e` after a subshell probe;
#  both forms are equivalent, kept explicit for the mock-suite argv contract.)
debug "mysql argv (password omitted): ${mysql_args[*]}"

run_query() { # $1 = sql file, $2 = output file, $3 = label
    local rc=0
    sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' < "$1" \
        | { if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
                MYSQL_PWD="$MYSQL_PASSWORD" "${mysql_args[@]}" > "$2" 2> "$tmp_dir/q.err"
            else
                "${mysql_args[@]}" > "$2" 2> "$tmp_dir/q.err"
            fi
          } || rc=$?
    if (( rc != 0 )); then
        log "error: mysql $3 query failed (exit $rc)"
        sed 's/^/  /' "$tmp_dir/q.err" >&2
        die "query failed; is MariaDB running? (start it first)"
    fi
    debug "$3: $(wc -l < "$2" | tr -d ' ') row(s)"
}

# --- 3. resolve list names to catalog authorids --------------------------------
# One dump of (authorid, trimmed CONCAT name) covers the whole catalog; the
# list is then matched in bash with the exporter's own trim, and the
# aggregates below restrict with the resulting integer IN-list (fast, and
# no SQL-escaping of names ever happens).
cat > "$tmp_dir/dump.sql" <<'SQL_EOF'
SELECT authorid, TRIM(CONCAT(LastName, ' ', FirstName, ' ', MiddleName))
FROM mlauthorname;
SQL_EOF
run_query "$tmp_dir/dump.sql" "$tmp_dir/idname.raw" "authorid dump"

awk -F '\t' '
    NR==FNR { list[$0]=1; next }
    $2 in list { ids[$1]=1 }
    END { for (i in ids) print i }
' "$tmp_dir/list.txt" "$tmp_dir/idname.raw" | LC_ALL=C sort -n > "$tmp_dir/ids.txt"

id_count="$(wc -l < "$tmp_dir/ids.txt" | tr -d ' ')"
[[ "$id_count" -gt 0 ]] || die "no list author matched the catalog (name drift?)"
in_list="$(paste -sd, "$tmp_dir/ids.txt")"
debug "resolved $id_count catalog authorid(s) for $list_count list author(s)"

# --- 4. aggregates: per-author (prioritization) + DISTINCT-overall (totals) ----
# A co-authored book is attributed to each author in the per-author rows but
# counted once in the overall DISTINCT totals.  The FAMILY filter reproduces
# the list's own criteria (Фантастика genre family, rating 4/5, lang ru).
cat > "$tmp_dir/qual_per.sql" <<'SQL_EOF'
SELECT TRIM(CONCAT(n.LastName, ' ', n.FirstName, ' ', n.MiddleName)) AS author_name,
       COUNT(*)                        AS q_books,
       COALESCE(SUM(q.filesize), 0)    AS q_bytes,
       COALESCE(SUM(q.rating5), 0)     AS q_rating5,
       COALESCE(ROUND(AVG(q.rating), 1), 0) AS q_avg_rating
FROM mlauthorname n
JOIN mlauthor a ON a.authorid = n.authorid
JOIN (
    SELECT DISTINCT b.bookid, b.filesize, r.rating,
           CASE WHEN r.rating = '5' THEN 1 ELSE 0 END AS rating5
    FROM mlbook b
    JOIN mlgenre g      ON g.bookid = b.bookid
    JOIN mlgenrename gn ON gn.genreid = g.genreid
    JOIN mlrating r     ON r.bookid = b.bookid
    WHERE b.lang = 'ru'
      AND r.rating IN ('4', '5')
      AND gn.parentgenreid =
          (SELECT genreid FROM mlgenrename
            WHERE genrenamerus = 'Фантастика' AND parentgenreid IS NULL)
) q ON q.bookid = a.bookid
WHERE a.authorid IN (__IDS__)
GROUP BY author_name;
SQL_EOF

cat > "$tmp_dir/qual_overall.sql" <<'SQL_EOF'
SELECT COUNT(*) AS overall_books, COALESCE(SUM(filesize), 0) AS overall_bytes
FROM (
    SELECT DISTINCT b.bookid, b.filesize
    FROM mlbook b
    JOIN mlauthor a      ON a.bookid = b.bookid
    JOIN mlgenre g       ON g.bookid = b.bookid
    JOIN mlgenrename gn  ON gn.genreid = g.genreid
    JOIN mlrating r      ON r.bookid = b.bookid
    WHERE a.authorid IN (__IDS__)
      AND b.lang = 'ru'
      AND r.rating IN ('4', '5')
      AND gn.parentgenreid =
          (SELECT genreid FROM mlgenrename
            WHERE genrenamerus = 'Фантастика' AND parentgenreid IS NULL)
) x;
SQL_EOF

cat > "$tmp_dir/full_per.sql" <<'SQL_EOF'
SELECT TRIM(CONCAT(n.LastName, ' ', n.FirstName, ' ', n.MiddleName)) AS author_name,
       COUNT(*)                     AS f_books,
       COALESCE(SUM(b.filesize), 0) AS f_bytes
FROM mlauthorname n
JOIN mlauthor a ON a.authorid = n.authorid
JOIN mlbook b   ON b.bookid = a.bookid
WHERE a.authorid IN (__IDS__)
  AND b.lang = 'ru'
GROUP BY author_name;
SQL_EOF

cat > "$tmp_dir/full_overall.sql" <<'SQL_EOF'
SELECT COUNT(*) AS overall_books, COALESCE(SUM(filesize), 0) AS overall_bytes
FROM (
    SELECT DISTINCT b.bookid, b.filesize
    FROM mlbook b
    JOIN mlauthor a     ON a.bookid = b.bookid
    WHERE a.authorid IN (__IDS__)
      AND b.lang = 'ru'
) x;
SQL_EOF

for f in qual_per qual_overall full_per full_overall; do
    sed -i "s/__IDS__/$in_list/g" "$tmp_dir/$f.sql"
done

run_query "$tmp_dir/qual_per.sql"    "$tmp_dir/qual_per.raw"    "qualifying per-author"
run_query "$tmp_dir/qual_overall.sql" "$tmp_dir/qual_overall.raw" "qualifying distinct"
run_query "$tmp_dir/full_per.sql"    "$tmp_dir/full_per.raw"    "full-oeuvre per-author"
run_query "$tmp_dir/full_overall.sql" "$tmp_dir/full_overall.raw" "full-oeuvre distinct"

# --- 5. join the per-author rows by name (trimmed) ------------------------------
awk -F '\t' '
    BEGIN { OFS = "\t" }
    FNR == 1 { phase++ }
    phase == 1 {
        n = $1; sub(/[[:space:]]+$/, "", n)
        q[n] = $2 "\t" $3 "\t" $4 "\t" $5
        next
    }
    phase == 2 {
        n = $1; sub(/[[:space:]]+$/, "", n)
        f[n] = $2 "\t" $3
        next
    }
    END {
        for (name in q)
            print name, q[name], (name in f ? f[name] : "0\t0")
        for (name in f)
            if (!(name in q))
                print name, "0\t0\t0\t0", f[name]
    }
' "$tmp_dir/qual_per.raw" "$tmp_dir/full_per.raw" > "$tmp_dir/breakdown.raw"

# top-rated first: 5-rated qualifying books desc, qualifying count desc, name
LC_ALL=C sort -t $'\t' -k4,4nr -k2,2nr -k1,1 "$tmp_dir/breakdown.raw" > "$tmp_dir/breakdown.tsv"

matched="$(wc -l < "$tmp_dir/breakdown.raw" | tr -d ' ')"
unmatched=$(( list_count - matched ))

# distinct-overall totals (single-row result of the *_overall queries).
# The unquoted cat is deliberate: the raw row is exactly four numeric
# fields, and word-splitting is how they land in $1..$4.
# shellcheck disable=SC2046  # intentional split of a 4-numeric-field row
set -- $(cat "$tmp_dir/qual_overall.raw" "$tmp_dir/full_overall.raw")
q_books="${1:-0}" q_bytes="${2:-0}" f_books="${3:-0}" f_bytes="${4:-0}"

gb() { # bytes -> decimal GB, one decimal
    awk -v b="$1" 'BEGIN { printf "%.1f", b / 1000000000 }'
}

# --- 6. summary ----------------------------------------------------------------
{
    echo "download-size estimate (recommended-author list: $list_count author(s)):"
    echo "  authors matched in catalog             $matched"
    echo "  authors unmatched (name drift)         $unmatched"
    echo "  qualifying books (rated 4/5, Фантастика, ru)    $q_books   ~$(gb "$q_bytes") GB"
    echo "  full oeuvre (all ru books)            $f_books   ~$(gb "$f_bytes") GB"
    echo "  top-rated qualifying authors (5-rated books first):"
    head -n 10 "$tmp_dir/breakdown.tsv" \
        | awk -F '\t' '{
              printf "    %2d. %s    %s books   %s GB   %s five-rated\n",
                  NR, $1, $2, sprintf("%.1f", $3 / 1000000000), $4
          }'
}

# --- 7. per-author breakdown artifact (top-rated first) ------------------------
if (( DRY_RUN )); then
    if [[ -n "$OUTPUT_FILE" ]]; then
        log "dry-run: would write breakdown to $OUTPUT_FILE"
    else
        log "dry-run: would write breakdown to $ESTIMATE_REPORT_DIR/books_estimate_<ts>.tsv"
    fi
    exit 0
fi

if [[ -z "$OUTPUT_FILE" ]]; then
    [[ -d "$ESTIMATE_REPORT_DIR" ]] || die "report directory does not exist: $ESTIMATE_REPORT_DIR"
    OUTPUT_FILE="$ESTIMATE_REPORT_DIR/books_estimate_$(date '+%Y%m%d-%H%M%S').tsv"
fi
out_dir="$(dirname "$OUTPUT_FILE")"
[[ -d "$out_dir" ]] || die "output directory does not exist: $out_dir"
mv "$tmp_dir/breakdown.tsv" "$OUTPUT_FILE"
log "info : prioritized breakdown ($matched author(s)) written to $OUTPUT_FILE"

exit 0