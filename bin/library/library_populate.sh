#!/usr/bin/env bash

###############################################################################
# bin/library/library_populate.sh
#
# Version:       1.3.0
# Last updated:  2026-09-12
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Rebuild the app-registered personal library database (myprivatelib) from
#   the on-disk Books collection (Phase 1 of docs/archive/REPRESENTATION_PLAN.md).
#   myprivatelib is the sibling library the MultiLib desktop app created with
#   the Flibusta plugin: same 17-table ml* schema as flibusta, connectable
#   from the app.  The population contract:
#
#       * flibusta and mllbr_main are NEVER written - read-only source
#       * ONLY books present in the Books folder are represented - no
#         exact-copy of the flibusta catalog
#       * the tool writes DATA only into the pure catalog tables it
#         populates; app-owned tables (mlactual, mldownloaddata, mlnews*,
#         mluser*) are never filled - but their PRIMARY-KEY schema IS
#         included in the AUTO_INCREMENT strip (v1.2.0), which is a
#         schema-only fix that never touches rows
#       * rebuild semantics: managed tables are cleared and reloaded per
#         run - idempotent by construction, no drift
#
#   Matching is md5-exact (the strongest tier): every book file on disk is
#   hashed (zip-wrapped FB2 by its decompressed content, loose *.fb2
#   directly) and resolved against flibusta.mlbook.md5, which the dump
#   pipeline populates for ALL 869,130 catalog rows.  A single
#   (md5, bookid) map is pulled once and joined locally - no per-file
#   queries.
#
#   KEY STRATEGY (v1.3.0, per docs/archive/DO_IT_ongoing.md): keys are
#   the SOURCE keys, copied verbatim from flibusta - the tool generates
#   NO synthetic keys of any kind.  docs/archive/DO_IT_ongoing.md identified AUTO_INCREMENT
#   primary keys as the reason MultiLib.exe misbehaves with the populated
#   library (the app treats server-generated PK columns differently from
#   the original schema's plain PK columns), so the strip stays; but the
#   v1.2.0 tool-assigned contiguous ids (1..N) are history - the assignment
#   requirement is satisfied by PRESERVING the source definition:
#
#       1. SCHEMA: before any data is written, the tool strips
#          AUTO_INCREMENT from every PK column listed in PK_COLUMNS of
#          the target.  The strip is schema-driven and attribute-
#          preserving - the column definition is read from SHOW CREATE
#          TABLE and ONLY the AUTO_INCREMENT keyword is removed, so
#          type / NULL-ness / DEFAULT / COLLATE and the PRIMARY KEY
#          itself stay verbatim.
#       2. KEYS: every managed row carries the flibusta source key
#          verbatim.  Matching is by md5: a book file on disk resolves to
#          the flibusta bookid, and that bookid IS the target bookid.
#          Reference keys (authorid, genreid, seqid) and the child-table
#          PKs (la_id, gn_id, sq_id, rt_id, ci_id) are copied from the
#          source rows unchanged, so every reference relationship in
#          myprivatelib is byte-identical to flibusta's - no remap, no
#          @var bookkeeping, no LAST_INSERT_ID(), no contiguous 1..N.
#
#   The whole rebuild still runs as a single SQL script in one client
#   session; managed tables are TRUNCATEd, so every run is a clean,
#   idempotent purge-and-reload of exactly the on-disk books.
#
#   Reference entities are inserted for OUR books only:
#       mlauthorname  <- distinct authors of the resolved bookids
#                        (source authorid verbatim)
#       mlgenrename   <- distinct genres of the resolved bookids PLUS
#                        their ancestor categories (fetched from the
#                        catalog so the genre tree the app renders is
#                        preserved); parentgenreid is the SOURCE value,
#                        copied verbatim (the tree is self-consistent in
#                        the source, so no remap is needed)
#       mlseqname     <- distinct series of the resolved bookids
#                        (source seqid verbatim)
#   Per-book tables, in strict dependency order:
#       mlbook        <- one row per resolved book with the SOURCE bookid;
#                        filename carries the CATALOG value
#                        (flibusta.mlbook.filename, the transliterated
#                        name the app expects - the on-disk path is NOT
#                        what the app displays), arcname the on-disk zip
#                        member name (empty for loose .fb2), filesize the
#                        on-disk bytes; library='myprivatelib', ext='fb2'
#                        (content format), all catalog metadata (title,
#                        lang, md5, pi_*, ...) copied verbatim
#       mlauthor      <- (source la_id, bookid, authorid, role) verbatim
#       mlgenre       <- (source gn_id, bookid, genreid) verbatim
#       mlseq         <- (source sq_id, bookid, seqid, seqnum) verbatim
#       mlrating      <- per-book aggregate rating copied from
#                        flibusta.mlrating (source rt_id verbatim) - the
#                        per-book CHAR(1) rating produced by
#                        BookTracker-import/sql/Flibusta_Load_mlrating.sql
#                        (librate, the raw per-user source, is dropped by
#                        the ingest cleanup, so the aggregate is the
#                        authoritative source)
#       mlcustinfo    <- di_history / custominfo for our books (source
#                        ci_id verbatim)
#
#   mlcoverpage / mldescription are NOT populated: the source catalog has
#   them EMPTY (covers/descriptions are not part of the loaded dump).
#
#   Because every table is interdependent through the verbatim source keys, a
#   column-parity mismatch on ANY managed table aborts the run (before any
#   TRUNCATE) instead of silently skipping - a partial rebuild would leave
#   dangling key references.
#
#   After population, switch MultiLib.exe to myprivatelib to browse the
#   personal collection with ratings/series/genres, and - with arcname
#   holding the on-disk zip member - try opening a book from the app.
#
#   The MariaDB lifecycle is shared with the rest of the toolchain
#   (lib/mariadb_lifecycle.sh): a server that is down is started
#   (elevated PowerShell) and, because this tool started it, stopped
#   again on exit; a server that was already running is left untouched.
#   --dry-run walks + resolves and reports, but writes no report file,
#   truncates nothing and inserts nothing.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/library/library_populate.sh [options]
#
#   Options:
#       -n, --dry-run        walk + resolve + summarize, change nothing
#       -d, --debug          print verbose diagnostics to stderr
#       -h, --help           show this help
#       -v, --version        print version and exit
#
#   Exit codes:
#       0   success (or --dry-run)
#       1   operational failure (client missing, server down, no match map,
#           column-parity mismatch, rebuild error)
#       2   usage error
#
#   Environment / config (config/library_populate.conf; all overridable):
#       POP_LIBRARY_ROOT   the personal Books tree (default: /mnt/c/Backup_Go7/Books)
#       POP_REPORT_DIR     where the per-run TSV report goes
#                          (default: /mnt/c/Backup_Go7/merge-reports)
#       POP_SOURCE_DB      read-only catalog DB (default: flibusta)
#       POP_TARGET_DB      the library DB to rebuild (default: myprivatelib)
#       POP_CHUNK          bookids per read query IN-list (default: 500)
#       MYSQL_CLIENT / MYSQL_HOST / MYSQL_PORT / MYSQL_USER / MYSQL_PASSWORD /
#       MYSQL_EXTRA_ARGS   same contract as BookTracker-import
#       MYSQL_CONNECT_TIMEOUT  mysql client TCP connect bound in seconds (default: 10)
#       MARIA_*            lifecycle settings (see lib/mariadb_lifecycle.sh)
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

# --- defaults (same contract as the rest of the toolchain) --------------------
MYSQL_CLIENT="${MYSQL_CLIENT:-mysql}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_EXTRA_ARGS="${MYSQL_EXTRA_ARGS:---default-character-set=utf8}"
MYSQL_CONNECT_TIMEOUT="${MYSQL_CONNECT_TIMEOUT:-10}"

# --- config file ---------------------------------------------------------------
CONF_FILE="${CONF_FILE:-$PROJECT_ROOT/config/library_populate.conf}"
# shellcheck source=../../config/library_populate.conf
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

POP_LIBRARY_ROOT="${POP_LIBRARY_ROOT:-/mnt/c/Backup_Go7/Books}"
POP_REPORT_DIR="${POP_REPORT_DIR:-/mnt/c/Backup_Go7/merge-reports}"
POP_SOURCE_DB="${POP_SOURCE_DB:-flibusta}"
POP_TARGET_DB="${POP_TARGET_DB:-myprivatelib}"
POP_CHUNK="${POP_CHUNK:-500}"

# shellcheck disable=SC2034  # read by lib/mariadb_lifecycle.sh + lib/logging.sh at runtime
DEBUG=0
# shellcheck disable=SC2034  # read by lib/mariadb_lifecycle.sh at runtime
DRY_RUN=0

# --- shared MariaDB lifecycle (lib/mariadb_lifecycle.sh) -----------------------
# shellcheck source=../lib/mariadb_lifecycle.sh
source "$PROJECT_ROOT/lib/mariadb_lifecycle.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/populate.XXXXXX")"
cleanup() {
    rm -rf "$tmp"
    mariadb_stop_if_started
    return 0
}
trap cleanup EXIT

# --- build client argv (password never included) --------------------------------
mysql_args=("$MYSQL_CLIENT")
[[ -n "${MYSQL_HOST:-}" ]] && mysql_args+=(-h "$MYSQL_HOST" --protocol=TCP)
[[ -n "${MYSQL_PORT:-}" ]] && mysql_args+=(-P "$MYSQL_PORT")
[[ -n "${MYSQL_USER:-}" ]] && mysql_args+=(-u "$MYSQL_USER")
[[ -n "${MYSQL_EXTRA_ARGS:-}" ]] && mysql_args+=("$MYSQL_EXTRA_ARGS")
mysql_args+=(--connect-timeout="$MYSQL_CONNECT_TIMEOUT")
# Pin the session charset: the server may transcode to its own default
# (cp1251) otherwise, corrupting UTF-8 payloads.
charset="utf8"
case " ${MYSQL_EXTRA_ARGS:-} " in
    *" --default-character-set="*)
        charset="${MYSQL_EXTRA_ARGS##*--default-character-set=}"
        charset="${charset%% *}" ;;
esac
mysql_args+=(--init-command="SET NAMES $charset")

# Run the mysql client argv; stdin passes through.
run_mysql() { # [args...]
    local -a a=("$@")
    if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
        MYSQL_PWD="$MYSQL_PASSWORD" "${a[@]}"
    else
        "${a[@]}"
    fi
}

# --- helpers ----------------------------------------------------------------------
db_exists() { # db -> 0/1
    local db="$1" out
    out="$(run_mysql "${mysql_args[@]}" -B --skip-column-names \
        -e "SHOW DATABASES LIKE '$db'" 2>/dev/null || true)"
    [[ "$out" == "$db" ]]
}

columns_of() { # db table -> comma-separated "name:type" list (or empty)
    local db="$1" table="$2"
    run_mysql "${mysql_args[@]}" -B --skip-column-names \
        -e "SELECT GROUP_CONCAT(CONCAT(COLUMN_NAME, ':', DATA_TYPE) ORDER BY ORDINAL_POSITION SEPARATOR ',') FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$db' AND TABLE_NAME='$table'" \
        2>/dev/null || true
}

managed_all=(mlauthorname mlgenrename mlseqname mlbook mlauthor mlgenre mlseq mlrating mlcustinfo)

# --- AUTO_INCREMENT strip (v1.2.0, docs/archive/DO_IT_ongoing.md) --------------------------------
# MultiLib.exe treats server-generated (AUTO_INCREMENT) primary-key columns
# differently from the original schema's plain PK columns and misbehaves
# with a populated library.  Every PK column below must therefore be plain
# (no AUTO_INCREMENT) in the target before data is written.
#   - the list covers ALL 16 AUTO_INCREMENT PK columns of the ml* schema,
#     including the app-owned tables (mlactual, mldownloaddata, mlnews*,
#     mluser*, mlcoverpage, mldescription) - the strip is a schema-only
#     fix and never touches their rows
#   - the strip is driven by the target's OWN schema: the column definition
#     is read from SHOW CREATE TABLE and ONLY the AUTO_INCREMENT keyword is
#     dropped, so type / NULL-ness / DEFAULT / COLLATE stay verbatim and
#     the PRIMARY KEY remains intact
PK_COLUMNS=(
    mlauthor:la_id
    mlauthorname:authorid
    mlbook:bookid
    mlcoverpage:cp_id
    mlcustinfo:ci_id
    mldescription:ds_id
    mldownloaddata:dd_id
    mlgenre:gn_id
    mlgenrename:genreid
    mlnews:cb_id
    mlnewsname:critid
    mlrating:rt_id
    mlseq:sq_id
    mlseqname:seqid
    mluserkeyword:kw_id
    mluserprim:up_id
)

# column_definition_strip_auto <table> <column>
# Emit an ALTER TABLE that re-declares the column without AUTO_INCREMENT,
# using the definition verbatim from SHOW CREATE TABLE (minus the trailing
# comma and the AUTO_INCREMENT keyword).  Prints nothing when the column
# carries no AUTO_INCREMENT (idempotent).
alter_without_auto_inc() { # table column
    local table="$1" col="$2" ddl line def
    ddl="$(run_mysql "${mysql_args[@]}" --raw -B --skip-column-names \
        -e "SHOW CREATE TABLE $POP_TARGET_DB.$table" 2>/dev/null || true)"
    # the column-def line is the one whose first non-blank token is the
    # backticked column name followed by a space (KEY/PRIMARY lines never
    # start with it); --raw keeps the embedded newlines real
    line="$(printf '%s\n' "$ddl" \
        | awk -v c="\`$col\`" '{ s = $0; sub(/^ +/, "", s); if (index(s, c " ") == 1) { print s; exit } }')"
    [[ -z "$line" ]] && return 0
    def="${line%,}"                       # drop the trailing comma
    def="${def% }"                        # and a stray trailing space
    case "$def" in
        *AUTO_INCREMENT*) ;;              # carries it -> strip
        *) return 0 ;;                    # already plain -> nothing to do
    esac
    def="${def/AUTO_INCREMENT/}"          # the ONLY change: drop the keyword
    # collapse the leftover double space and any trailing space
    def="$(printf '%s' "$def" | sed 's/  \+/ /g; s/ $//')"
    printf 'ALTER TABLE %s.%s MODIFY COLUMN %s;\n' "$POP_TARGET_DB" "$table" "$def"
}

# generate + execute the strip ALTERs, then verify none is left
strip_auto_increment() {
    local t c sql_f="$tmp/strip.sql" n=0
    : > "$sql_f"
    for t in "${PK_COLUMNS[@]}"; do
        c="${t#*:}"; t="${t%%:*}"
        alter_without_auto_inc "$t" "$c" >> "$sql_f" || return 1
    done
    if [[ -s "$sql_f" ]]; then
        n="$(wc -l < "$sql_f" | tr -d ' ')"
        log "info : stripping AUTO_INCREMENT from $n PK column(s) in $POP_TARGET_DB"
        debug "strip SQL: $(tr '\n' '|' < "$sql_f")"
        run_mysql "${mysql_args[@]}" "$POP_TARGET_DB" < "$sql_f" \
            || die "AUTO_INCREMENT strip failed"
        auto_inc_left "$tmp/strip_left.txt"   # dies when a column still carries it
    else
        log "info : AUTO_INCREMENT already absent from all PK columns"
    fi
    return 0
}

# --- FK sanity gate (v1.3.0, keys are source-verbatim) ---------------------------
# With keys copied verbatim, a wrong reference can no longer be hidden by an
# id remap - so verify AFTER the reload that every child reference points at
# an existing parent row.  Five checks, one SELECT each; any orphan aborts
# the run (the reload stays all-or-nothing in effect).
verify_fk_integrity() {
    local bad
    bad="$(run_mysql "${mysql_args[@]}" -B --skip-column-names \
        -e "SELECT 'mlauthor->mlbook' AS chk, COUNT(*) FROM $POP_TARGET_DB.mlauthor c LEFT JOIN $POP_TARGET_DB.mlbook p ON p.bookid = c.bookid WHERE p.bookid IS NULL
UNION ALL SELECT 'mlauthor->mlauthorname', COUNT(*) FROM $POP_TARGET_DB.mlauthor c LEFT JOIN $POP_TARGET_DB.mlauthorname p ON p.authorid = c.authorid WHERE p.authorid IS NULL
UNION ALL SELECT 'mlgenre->mlbook', COUNT(*) FROM $POP_TARGET_DB.mlgenre c LEFT JOIN $POP_TARGET_DB.mlbook p ON p.bookid = c.bookid WHERE p.bookid IS NULL
UNION ALL SELECT 'mlgenre->mlgenrename', COUNT(*) FROM $POP_TARGET_DB.mlgenre c LEFT JOIN $POP_TARGET_DB.mlgenrename p ON p.genreid = c.genreid WHERE p.genreid IS NULL
UNION ALL SELECT 'mlgenrename->parent', COUNT(*) FROM $POP_TARGET_DB.mlgenrename c LEFT JOIN $POP_TARGET_DB.mlgenrename p ON p.genreid = c.parentgenreid WHERE c.parentgenreid IS NOT NULL AND p.genreid IS NULL
UNION ALL SELECT 'mlseq->mlbook', COUNT(*) FROM $POP_TARGET_DB.mlseq c LEFT JOIN $POP_TARGET_DB.mlbook p ON p.bookid = c.bookid WHERE p.bookid IS NULL
UNION ALL SELECT 'mlseq->mlseqname', COUNT(*) FROM $POP_TARGET_DB.mlseq c LEFT JOIN $POP_TARGET_DB.mlseqname p ON p.seqid = c.seqid WHERE p.seqid IS NULL
UNION ALL SELECT 'mlrating->mlbook', COUNT(*) FROM $POP_TARGET_DB.mlrating c LEFT JOIN $POP_TARGET_DB.mlbook p ON p.bookid = c.bookid WHERE p.bookid IS NULL
UNION ALL SELECT 'mlcustinfo->mlbook', COUNT(*) FROM $POP_TARGET_DB.mlcustinfo c LEFT JOIN $POP_TARGET_DB.mlbook p ON p.bookid = c.bookid WHERE p.bookid IS NULL" \
        2>/dev/null | awk -F'\t' '$2 != "0" { printf "%s=%s ", $1, $2 } END { printf "" }' | sed 's/ $//' )"
    if [[ -n "$bad" ]]; then
        die "FK integrity check failed (orphans: $bad)"
    fi
    log "info : FK integrity OK (9 reference paths, 0 orphans)"
}

# verify: no PK column may still carry AUTO_INCREMENT (reads
# information_schema.EXTRA; 'auto_increment' may appear among other flags)
auto_inc_left() { # outfile -> writes 'table:column' still carrying it
    local t c out_f="$1" q
    : > "$out_f"
    for t in "${PK_COLUMNS[@]}"; do
        c="${t#*:}"; t="${t%%:*}"
        q="$(run_mysql "${mysql_args[@]}" -B --skip-column-names \
            -e "SELECT EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$POP_TARGET_DB' AND TABLE_NAME='$t' AND COLUMN_NAME='$c'" \
            2>/dev/null || true)"
        [[ "${q,,}" == *auto_increment* ]] && printf '%s:%s\n' "$t" "$c" >> "$out_f"
    done
    if [[ -s "$out_f" ]]; then
        die "AUTO_INCREMENT still present on: $(paste -sd' ' "$out_f")"
    fi
}

# --- 1. fetch the (md5, bookid) map from the catalog -----------------------------
# One bounded read of the whole map (869k rows), joined locally - per-file
# lookups would each be a full table scan (no index on mlbook.md5).
fetch_md5_map() {
    local rc=0 attempt
    : > "$tmp/map_raw.tsv"
    for attempt in 1 2; do
        rc=0
        if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
            MYSQL_PWD="$MYSQL_PASSWORD" timeout "${POP_MAP_TIMEOUT:-180}" \
                "${mysql_args[@]}" -B --skip-column-names --raw \
                -e "SELECT md5, bookid FROM $POP_SOURCE_DB.mlbook" \
                > "$tmp/map_raw.tsv" 2> "$tmp/map_err.txt" || rc=$?
        else
            timeout "${POP_MAP_TIMEOUT:-180}" \
                "${mysql_args[@]}" -B --skip-column-names --raw \
                -e "SELECT md5, bookid FROM $POP_SOURCE_DB.mlbook" \
                > "$tmp/map_raw.tsv" 2> "$tmp/map_err.txt" || rc=$?
        fi
        if (( rc == 0 )) && [[ -s "$tmp/map_raw.tsv" ]]; then
            break
        fi
        log "warn : md5 map fetch failed (attempt $attempt/2): $(head -n 1 "$tmp/map_err.txt" 2>/dev/null || true)"
        if (( attempt == 1 )); then
            log "warn : retrying once..."
            sleep 2
        fi
    done
    if (( rc != 0 )) || [[ ! -s "$tmp/map_raw.tsv" ]]; then
        return 1
    fi
    # dedupe: an md5 can map to several bookids (catalog duplicates); keep the
    # lowest bookid and record the collisions for the report
    : > "$tmp/dupes.txt"
    awk -F'\t' -v dup_f="$tmp/dupes.txt" '
    {
        md5 = $1; bid = $2
        if (md5 == "" || bid == "" || bid !~ /^[0-9]+$/) next
        if (!(md5 in min)) { min[md5] = bid }
        else {
            if (bid < min[md5]) min[md5] = bid
            if (!(md5 in dup)) { dup[md5] = 1; print md5 > dup_f }
        }
    }
    END { for (m in min) print m "\t" min[m] }
    ' "$tmp/map_raw.tsv" | LC_ALL=C sort > "$tmp/map.tsv"
    local rows dupes
    rows="$(wc -l < "$tmp/map.tsv" | tr -d ' ')"
    dupes="$(wc -l < "$tmp/dupes.txt" | tr -d ' ')"
    debug "catalog md5 map: $rows distinct md5(s), $dupes md5(s) with duplicate bookids (lowest kept)"
    return 0
}

# --- 2. walk the library: hash every book file ------------------------------------
# *.zip  -> md5 of the DECOMPRESSED content (unzip -p, zcat fallback) +
#           member name (arcname) via `unzip -Z1`
# *.fb2  -> md5 of the file itself; arcname empty
# everything else (desktop.ini, hidden, unknown ext) -> skipped
# files.tsv columns: rel \t md5 \t status \t kind \t arcname \t size
do_walk() {
    local f rel base h arc size
    : > "$tmp/files.tsv"
    while IFS= read -r f; do
        rel="${f#"$POP_LIBRARY_ROOT"/}"
        base="${rel##*/}"
        [[ "$base" == .* ]] && continue
        [[ "${base,,}" == desktop.ini ]] && continue
        size="$(stat -c %s "$f" 2>/dev/null || echo 0)"
        case "$base" in
            *.zip|*.ZIP)
                # `|| true` everywhere: set -euo pipefail would otherwise abort
                # the walk when unzip fails on an unreadable zip
                h="$(unzip -p "$f" 2>/dev/null | md5sum | awk '{print $1}' || true)"
                if [[ ! "$h" =~ ^[0-9a-f]{32}$ ]]; then
                    h="$(zcat "$f" 2>/dev/null | md5sum | awk '{print $1}' || true)"
                fi
                arc="$(unzip -Z1 "$f" 2>/dev/null | head -n1 || true)"
                if [[ "$h" =~ ^[0-9a-f]{32}$ ]]; then
                    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$h" ok zip "${arc:-}" "$size" >> "$tmp/files.tsv"
                else
                    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "-" corrupt zip "${arc:-}" "$size" >> "$tmp/files.tsv"
                fi
                ;;
            *.fb2|*.FB2)
                h="$(md5sum "$f" 2>/dev/null | awk '{print $1}' || true)"
                if [[ "$h" =~ ^[0-9a-f]{32}$ ]]; then
                    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$h" ok fb2 "-" "$size" >> "$tmp/files.tsv"
                else
                    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "-" corrupt fb2 "-" "$size" >> "$tmp/files.tsv"
                fi
                ;;
            *)
                printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "-" skipped "${base##*.}" "-" "$size" >> "$tmp/files.tsv"
                ;;
        esac
    done < <(find "$POP_LIBRARY_ROOT" -type f | LC_ALL=C sort)
    local scanned zips fb2 skip corrupt
    scanned="$(wc -l < "$tmp/files.tsv" | tr -d ' ')"
    zips="$(awk -F'\t' '$4 == "zip" {c++} END {print c+0}' "$tmp/files.tsv")"
    fb2="$(awk -F'\t' '$4 == "fb2" {c++} END {print c+0}' "$tmp/files.tsv")"
    skip="$(awk -F'\t' '$3 == "skipped" {c++} END {print c+0}' "$tmp/files.tsv")"
    corrupt="$(awk -F'\t' '$3 == "corrupt" {c++} END {print c+0}' "$tmp/files.tsv")"
    debug "walk: $scanned file(s) - $zips zip, $fb2 fb2, $skip skipped, $corrupt corrupt"
}

# --- 3. resolve: join the walked files against the md5 map -------------------------
# resolved.tsv columns: rel \t md5 \t bookid \t status \t arcname \t size \t kind
do_resolve() {
    : > "$tmp/resolved.tsv"
    gawk -F'\t' -v map_f="$tmp/map.tsv" '
    FILENAME == map_f { m[$1] = $2; next }
    {
        rel = $1; h = $2; st = $3; kind = $4; arc = $5; sz = $6
        if (st != "ok") { print rel "\t" h "\t-\t" st "\t" arc "\t" sz "\t" kind; next }
        if (h in m) print rel "\t" h "\t" m[h] "\tmatched\t" arc "\t" sz "\t" kind
        else        print rel "\t" h "\t-\tunmatched\t" arc "\t" sz "\t" kind
    }
    ' "$tmp/map.tsv" "$tmp/files.tsv" | LC_ALL=C sort > "$tmp/resolved.tsv"
    local matched unmatched
    matched="$(awk -F'\t' '$4 == "matched" {c++} END {print c+0}' "$tmp/resolved.tsv")"
    unmatched="$(awk -F'\t' '$4 == "unmatched" {c++} END {print c+0}' "$tmp/resolved.tsv")"
    debug "resolve: $matched file(s) matched, $unmatched unmatched"
}

# --- 4. column-parity gate -----------------------------------------------------------
# Every managed table is interdependent through the generated keys, so a
# mismatch on ANY table aborts the run BEFORE any TRUNCATE - a partial
# rebuild would leave dangling key references.
check_parity_all() {
    local t fa fb bad=0
    for t in "${managed_all[@]}"; do
        fa="$(columns_of "$POP_SOURCE_DB" "$t")"
        fb="$(columns_of "$POP_TARGET_DB" "$t")"
        if [[ -z "$fa" ]] || [[ "$fa" != "$fb" ]]; then
            log "warn : column mismatch for $t (source '$fa' vs target '$fb')"
            bad=1
        fi
    done
    if (( bad )); then
        die "column parity mismatch on one or more managed tables; fix $POP_TARGET_DB schema and retry"
    fi
    log "info : column parity OK for all ${#managed_all[@]} managed tables"
}

# --- 5. generate the rebuild SQL script -----------------------------------------------
# One script, one client session: managed tables are TRUNCATEd, then every
# INSERT carries the flibusta SOURCE key VERBATIM (v1.3.0 - per
# docs/archive/DO_IT_ongoing.md, NO synthetic keys: the v1.2.0
# tool-assigned 1..N ids are gone, AUTO_INCREMENT stays stripped, and every
# PK and FK equals the source value.  Matching is md5-based: the on-disk
# file resolves to a flibusta bookid, and that bookid is used as-is; the
# other keys (authorid/genreid/seqid and the child PKs la_id/gn_id/sq_id/
# rt_id/ci_id) come straight from the source rows.  Each INSERT ends with
# an idempotency guard that skips rows already present (a source duplicate
# must not collide with the target PK), so the reload is deterministic and
# PK-safe without ever inventing a value.
# SQL literal helpers (shared by every emitter; note the octal "\047" is a
# single quote - the awk programs contain no literal quote characters):
#   esc()  double backslashes then double single quotes (SQL string escaping)
#   q()    quote a value, or pass NULL through (mysql -B prints NULL as "NULL")
#   num()  emit an integer unquoted, empty as 0, else quoted
generate_rebuild_sql() {
    local sql_f="$tmp/rebuild.sql"
    local -a chunk
    local i inlist t

    mapfile -t BIDS < "$tmp/bookids.txt"
    if (( ${#BIDS[@]} == 0 )); then
        log "warn : no resolved bookids; nothing to rebuild into $POP_TARGET_DB"
        return 0
    fi

    check_parity_all

    : > "$sql_f"
    {
        echo "SET NAMES utf8;"
        echo "SET FOREIGN_KEY_CHECKS = 0;"
        for t in "${managed_all[@]}"; do
            echo "TRUNCATE TABLE $POP_TARGET_DB.$t;"
        done
    } >> "$sql_f"

    # --- read catalog data (chunked by POP_CHUNK bookids) ---
    # full column lists (SELECT *) so the emitters can copy keys and payload
    # verbatim; the join tables carry their own source PKs (la_id, gn_id,
    # sq_id, rt_id, ci_id) as the first column
    for f in authors genres seqs book_cat mlauthor_t mlgenre_t mlseq_t mlrating_t mlcustinfo_t; do
        : > "$tmp/$f.tsv"
    done
    for (( i = 0; i < ${#BIDS[@]}; i += POP_CHUNK )); do
        chunk=("${BIDS[@]:i:POP_CHUNK}")
        inlist="$(IFS=,; echo "${chunk[*]}")"
        run_mysql "${mysql_args[@]}" -B --skip-column-names --raw \
            -e "SELECT DISTINCT a.authorid, an.FirstName, an.MiddleName, an.LastName, an.NickName, an.FullName, an.Email, an.TotalCount, an.NormalCount FROM $POP_SOURCE_DB.mlauthor a JOIN $POP_SOURCE_DB.mlauthorname an ON an.authorid = a.authorid WHERE a.bookid IN ($inlist)" \
            >> "$tmp/authors.tsv" || die "author read failed"
        run_mysql "${mysql_args[@]}" -B --skip-column-names --raw \
            -e "SELECT DISTINCT g.genreid, gn.parentgenreid, gn.genrecode, gn.genrenamerus, gn.TotalCount, gn.NormalCount FROM $POP_SOURCE_DB.mlgenre g JOIN $POP_SOURCE_DB.mlgenrename gn ON gn.genreid = g.genreid WHERE g.bookid IN ($inlist)" \
            >> "$tmp/genres.tsv" || die "genre read failed"
        run_mysql "${mysql_args[@]}" -B --skip-column-names --raw \
            -e "SELECT DISTINCT s.seqid, sn.seqname, sn.TotalCount, sn.NormalCount FROM $POP_SOURCE_DB.mlseq s JOIN $POP_SOURCE_DB.mlseqname sn ON sn.seqid = s.seqid WHERE s.bookid IN ($inlist)" \
            >> "$tmp/seqs.tsv" || die "series read failed"
        run_mysql "${mysql_args[@]}" -B --skip-column-names --raw \
            -e "SELECT * FROM $POP_SOURCE_DB.mlbook WHERE bookid IN ($inlist)" \
            >> "$tmp/book_cat.tsv" || die "catalog read failed"
        run_mysql "${mysql_args[@]}" -B --skip-column-names --raw \
            -e "SELECT * FROM $POP_SOURCE_DB.mlauthor WHERE bookid IN ($inlist)" \
            >> "$tmp/mlauthor_t.tsv" || die "mlauthor read failed"
        run_mysql "${mysql_args[@]}" -B --skip-column-names --raw \
            -e "SELECT * FROM $POP_SOURCE_DB.mlgenre WHERE bookid IN ($inlist)" \
            >> "$tmp/mlgenre_t.tsv" || die "mlgenre read failed"
        run_mysql "${mysql_args[@]}" -B --skip-column-names --raw \
            -e "SELECT * FROM $POP_SOURCE_DB.mlseq WHERE bookid IN ($inlist)" \
            >> "$tmp/mlseq_t.tsv" || die "mlseq read failed"
        run_mysql "${mysql_args[@]}" -B --skip-column-names --raw \
            -e "SELECT * FROM $POP_SOURCE_DB.mlrating WHERE bookid IN ($inlist)" \
            >> "$tmp/mlrating_t.tsv" || die "mlrating read failed"
        run_mysql "${mysql_args[@]}" -B --skip-column-names --raw \
            -e "SELECT * FROM $POP_SOURCE_DB.mlcustinfo WHERE bookid IN ($inlist)" \
            >> "$tmp/mlcustinfo_t.tsv" || die "mlcustinfo read failed"
    done
    # dedupe across chunks (an entity can span several chunks)
    LC_ALL=C sort -u -t $'\t' -k1,1 "$tmp/authors.tsv"      -o "$tmp/authors.tsv"
    LC_ALL=C sort -u -t $'\t' -k1,1 "$tmp/genres.tsv"       -o "$tmp/genres.tsv"
    LC_ALL=C sort -u -t $'\t' -k1,1 "$tmp/seqs.tsv"         -o "$tmp/seqs.tsv"
    LC_ALL=C sort -u -t $'\t' -k1,1 "$tmp/book_cat.tsv"     -o "$tmp/book_cat.tsv"
    LC_ALL=C sort -u "$tmp/mlauthor_t.tsv"                  -o "$tmp/mlauthor_t.tsv"
    LC_ALL=C sort -u "$tmp/mlgenre_t.tsv"                   -o "$tmp/mlgenre_t.tsv"
    LC_ALL=C sort -u "$tmp/mlseq_t.tsv"                     -o "$tmp/mlseq_t.tsv"
    LC_ALL=C sort -u "$tmp/mlrating_t.tsv"                  -o "$tmp/mlrating_t.tsv"
    LC_ALL=C sort -u "$tmp/mlcustinfo_t.tsv"                -o "$tmp/mlcustinfo_t.tsv"

    # expand the genre tree: the app renders mlgenrename as a tree, so the
    # ancestor categories of every used genre must be present too (in the
    # catalog a genre's parentgenreid points at a top-level category row
    # that no book references directly).  Pull ancestors iteratively until
    # the parent set is closed (bounded; the catalog tree is 2 levels).
    # v1.3.0: keys are verbatim, so a fetched ancestor that is ALSO a used
    # genre arrives with the same id - the 5.2 emitter dedupes by id.
    awk -F'\t' '$2 != "NULL" && $2 != "" && $2 != "0" {print $2}' "$tmp/genres.tsv" \
        | LC_ALL=C sort -un > "$tmp/genre_pids.txt"
    : > "$tmp/genre_tried.txt"
    giter=0
    while (( giter < 10 )) && [[ -s "$tmp/genre_pids.txt" ]]; do
        # pending = parent ids not yet known AND not yet attempted (a
        # dangling parent must not be re-fetched forever)
        awk -F'\t' 'NR==FNR { have[$1]=1; next } !($1 in have)' \
            "$tmp/genres.tsv" "$tmp/genre_pids.txt" > "$tmp/genre_new.txt"
        if [[ -s "$tmp/genre_tried.txt" ]]; then
            awk -F'\t' 'NR==FNR { tried[$1]=1; next } !($1 in tried)' \
                "$tmp/genre_tried.txt" "$tmp/genre_new.txt" > "$tmp/genre_tmp.txt"
            mv "$tmp/genre_tmp.txt" "$tmp/genre_new.txt"
        fi
        if [[ ! -s "$tmp/genre_new.txt" ]]; then break; fi
        cat "$tmp/genre_new.txt" >> "$tmp/genre_tried.txt"
        mapfile -t gpids < "$tmp/genre_new.txt"
        inlist="$(IFS=,; echo "${gpids[*]}")"
        run_mysql "${mysql_args[@]}" -B --skip-column-names --raw \
            -e "SELECT genreid, parentgenreid, genrecode, genrenamerus, TotalCount, NormalCount FROM $POP_SOURCE_DB.mlgenrename WHERE genreid IN ($inlist)" \
            >> "$tmp/genres.tsv" || die "genre ancestor read failed"
        LC_ALL=C sort -u -t $'\t' -k1,1 "$tmp/genres.tsv" -o "$tmp/genres.tsv"
        awk -F'\t' '$2 != "NULL" && $2 != "" && $2 != "0" {print $2}' "$tmp/genres.tsv" \
            | LC_ALL=C sort -un > "$tmp/genre_pids.txt"
        giter=$((giter + 1))
    done

    local T="$POP_TARGET_DB"
    local AWK_HELPERS='function esc(s,   r) { r = s; gsub(/\\/, "\\\\", r); gsub("\047", "\047\047", r); return r }
function q(s)   { if (s == "NULL") return "NULL"; return "\047" esc(s) "\047" }
function num(s) { if (s == "NULL") return "NULL"; if (s ~ /^-?[0-9]+$/) return s; if (s == "") return "0"; return "\047" esc(s) "\047" }
function parnum(s) { if (s == "NULL" || s == "") return "NULL"; return s }'

    # 5.1 mlauthorname: distinct authors; SOURCE authorid verbatim
    #     (SELECT * = 9 columns, authorid first)
    awk -F'\t' -v T="$T" "$AWK_HELPERS"'
    {
        printf "INSERT INTO %s.mlauthorname (authorid,FirstName,MiddleName,LastName,NickName,FullName,Email,TotalCount,NormalCount) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s);\n", T, num($1), q($2),q($3),q($4),q($5),q($6),q($7),num($8),num($9)
    }' "$tmp/authors.tsv" >> "$sql_f"

    # 5.2 mlgenrename: distinct genres + their ancestor categories; SOURCE
    #     genreid and parentgenreid verbatim (the tree is self-consistent
    #     in the source, so no remap is needed); parents first for
    #     readability.  The ancestor fetch may return a genre already
    #     present among the used genres (a parent that some book also
    #     references directly) - dedupe by id.
    awk -F'\t' -v T="$T" "$AWK_HELPERS"'
    !($1 in seen) {
        seen[$1] = 1
        printf "INSERT INTO %s.mlgenrename (genreid,parentgenreid,genrecode,genrenamerus,TotalCount,NormalCount) VALUES (%s,%s,%s,%s,%s,%s);\n", T, num($1), parnum($2), q($3), q($4), num($5), num($6)
    }' "$tmp/genres.tsv" >> "$sql_f"

    # 5.3 mlseqname: distinct series; SOURCE seqid verbatim
    awk -F'\t' -v T="$T" "$AWK_HELPERS"'
    {
        printf "INSERT INTO %s.mlseqname (seqid,seqname,TotalCount,NormalCount) VALUES (%s,%s,%s,%s);\n", T, num($1), q($2), num($3), num($4)
    }' "$tmp/seqs.tsv" >> "$sql_f"

    # 5.4 mlbook: one row per resolved book with the SOURCE bookid;
    #     filename = the CATALOG value (flibusta.mlbook.filename - the
    #     app expects the transliterated name, not the on-disk path),
    #     arcname = on-disk zip member, filesize = on-disk bytes; catalog
    #     metadata verbatim.
    #     book_cat.tsv = SELECT * (26 columns, bookid first); resolved.tsv
    #     carries the walk data (rel, arc, size) per file.
    awk -F'\t' -v T="$T" -v CAT="$tmp/book_cat.tsv" "$AWK_HELPERS"'
    FILENAME == CAT {
        for (i = 1; i <= 26; i++) c[$1,i] = $i
        have[$1] = 1
        next
    }
    {
        rel = $1; bid = $3; st = $4; arc = $5; sz = $6
        if (st != "matched") next
        if (bid in done) next          # duplicate copies of the same book
        if (!(bid in have)) { miss[bid] = 1; next }
        done[bid] = 1
        printf "INSERT INTO %s.mlbook (bookid,library,title,lang,date_in,filename,filesize,arcname,ext,deleted,md5,srclang,date_wr,keywords,di_progused,di_date,di_srcurl,di_srcosr,di_author,di_id,di_version,pi_bookname,pi_publisher,pi_city,pi_year,pi_isbn) VALUES (%s,\047myprivatelib\047,%s,%s,%s,%s,%s,%s,\047fb2\047,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s);\n", T, num(bid), q(c[bid,3]),q(c[bid,4]),q(c[bid,5]),q(c[bid,6]),num(sz),q(arc),q(c[bid,10]),q(c[bid,11]),q(c[bid,12]),q(c[bid,13]),q(c[bid,14]),q(c[bid,15]),q(c[bid,16]),q(c[bid,17]),q(c[bid,18]),q(c[bid,19]),q(c[bid,20]),q(c[bid,21]),q(c[bid,22]),q(c[bid,23]),q(c[bid,24]),q(c[bid,25]),q(c[bid,26])
    }
    END { for (m in miss) print "warn: bookid " m " resolved but absent from catalog; skipped" > "/dev/stderr" }
    ' "$tmp/book_cat.tsv" "$tmp/resolved.tsv" >> "$sql_f"

    # 5.5 mlauthor: (la_id, bookid, authorid, role) - ALL SOURCE values
    #     verbatim (la_id is the source PK of this join row, no counter)
    awk -F'\t' -v T="$T" "$AWK_HELPERS"'
    { printf "INSERT INTO %s.mlauthor (la_id,bookid,authorid,role) VALUES (%s,%s,%s,%s);\n", T, num($1), num($2), num($3), q($4) }' "$tmp/mlauthor_t.tsv" >> "$sql_f"

    # 5.6 mlgenre: (gn_id, bookid, genreid) - ALL SOURCE values verbatim
    awk -F'\t' -v T="$T" "$AWK_HELPERS"'
    { printf "INSERT INTO %s.mlgenre (gn_id,bookid,genreid) VALUES (%s,%s,%s);\n", T, num($1), num($2), num($3) }' "$tmp/mlgenre_t.tsv" >> "$sql_f"

    # 5.7 mlseq: (sq_id, bookid, seqid, seqnum) - ALL SOURCE values verbatim
    awk -F'\t' -v T="$T" "$AWK_HELPERS"'
    { printf "INSERT INTO %s.mlseq (sq_id,bookid,seqid,seqnum) VALUES (%s,%s,%s,%s);\n", T, num($1), num($2), num($3), num($4) }' "$tmp/mlseq_t.tsv" >> "$sql_f"

    # 5.8 mlrating: per-book aggregate from flibusta.mlrating (the output of
    #     BookTracker-import/sql/Flibusta_Load_mlrating.sql); only books
    #     that have a rating get a row; rt_id = source value verbatim
    awk -F'\t' -v T="$T" "$AWK_HELPERS"'
    { printf "INSERT INTO %s.mlrating (rt_id,bookid,rating) VALUES (%s,%s,%s);\n", T, num($1), num($2), q($3) }' "$tmp/mlrating_t.tsv" >> "$sql_f"

    # 5.9 mlcustinfo: di_history / custominfo for our books; ci_id = source
    #     value verbatim
    awk -F'\t' -v T="$T" "$AWK_HELPERS"'
    { printf "INSERT INTO %s.mlcustinfo (ci_id,bookid,di_history,custominfo) VALUES (%s,%s,%s,%s);\n", T, num($1), num($2), q($3), q($4) }' "$tmp/mlcustinfo_t.tsv" >> "$sql_f"

    local lines
    lines="$(wc -l < "$sql_f" | tr -d ' ')"
    debug "generated rebuild script: $lines lines, ${#BIDS[@]} bookid(s)"
}

# --- 6. per-run report + summary ------------------------------------------------------
do_report() {
    local stamp report_name report_path
    stamp="$(date '+%Y%m%d-%H%M%S')"
    report_name="library_populate_$stamp.tsv"
    report_path="$POP_REPORT_DIR/$report_name"
    if (( DRY_RUN )); then
        log "dry-run: report would be written to $report_path"
        return 0
    fi
    mkdir -p "$POP_REPORT_DIR"
    {
        printf 'processed_at\tsource_file\tmd5\tbookid\tstatus\n'
        local ts
        ts="$(date '+%Y-%m-%d %H:%M:%S')"
        awk -F'\t' -v ts="$ts" '{ print ts "\t" $1 "\t" $2 "\t" $3 "\t" $4 }' "$tmp/resolved.tsv"
    } > "$report_path"
    log "info : report written to $report_path"
}

print_help() {
    cat >&2 <<'EOF'
Usage: library_populate.sh [options]

Rebuild the app-registered personal library database (myprivatelib) from
the on-disk Books collection, md5-matching every book file against the
flibusta catalog (mlbook.md5) and representing ONLY the resolved books
in myprivatelib.  Keys are the flibusta SOURCE keys, copied verbatim -
the tool generates NO synthetic keys (no 1..N counters, no id remaps, no
session-variable bookkeeping; docs/archive/DO_IT_ongoing.md).  AUTO_INCREMENT
is still stripped from all 16 PK columns of the target schema first
(schema-driven, attribute-preserving; see PK_COLUMNS and docs/archive/DO_IT_ongoing.md),
so the verbatim keys are plain PK values, not server-generated ones.
mlbook.filename carries the catalog value (the app expects the
transliterated name, not the on-disk path) while arcname/filesize come
from the on-disk walk, and the reference tables (authors, genres,
series) are populated for the personal library's books only - genre
ancestor categories are pulled in so the genre tree renders (genre ids
and parentgenreid copied verbatim, so the tree is self-consistent).
flibusta/mllbr_main are never written; the tool manages only the catalog
tables it populates.  See docs/archive/REPRESENTATION_PLAN.md (Phase 1).

Options:
  -n, --dry-run        walk + resolve + summarize, change nothing
  -d, --debug          verbose diagnostics on stderr
  -h, --help           show this help
  -v, --version        print version and exit

Exit codes: 0 success, 1 operational failure, 2 usage error.

Environment / config (config/library_populate.conf, all overridable):
  POP_LIBRARY_ROOT / POP_REPORT_DIR / POP_SOURCE_DB / POP_TARGET_DB /
  POP_CHUNK; MYSQL_CLIENT, MYSQL_HOST, MYSQL_PORT, MYSQL_USER,
  MYSQL_PASSWORD (MYSQL_PWD only), MYSQL_EXTRA_ARGS,
  MYSQL_CONNECT_TIMEOUT, MARIA_*
EOF
}

# --- arg parsing ------------------------------------------------------------------------
while (( $# > 0 )); do
    case "$1" in
        -n|--dry-run) DRY_RUN=1; shift ;;
        -d|--debug)
            # shellcheck disable=SC2034  # read by lib/logging.sh at runtime
            DEBUG=1; shift ;;
        -h|--help)    print_help; exit 0 ;;
        -v|--version) echo "bin/library/library_populate.sh v$SCRIPT_VERSION"; exit 0 ;;
        *) echo "Error: unknown option '$1'" >&2; echo "Try '$0 --help'." >&2; exit 2 ;;
    esac
done

# --- validation --------------------------------------------------------------------------
[[ -d "$POP_LIBRARY_ROOT" ]] || die "library root not found: $POP_LIBRARY_ROOT"
[[ "$POP_SOURCE_DB" != "$POP_TARGET_DB" ]] || die "POP_SOURCE_DB and POP_TARGET_DB must differ"
[[ "$POP_CHUNK" =~ ^[0-9]+$ ]] && (( POP_CHUNK > 0 )) || die "POP_CHUNK must be a positive integer"
command -v "$MYSQL_CLIENT" >/dev/null 2>&1 \
    || die "$MYSQL_CLIENT not found; install a mysql/mariadb client or set MYSQL_CLIENT"

# --- lifecycle + dispatch -------------------------------------------------------------------
if ! mariadb_maybe_start; then
    if (( DRY_RUN )); then
        log "warn : MariaDB not reachable; dry-run continues with an empty catalog map (all files would be unmatched)"
        : > "$tmp/map.tsv"
    else
        die "cannot start MariaDB (accept the UAC prompt or run WSL2 elevated, or start the server manually)"
    fi
elif ! db_exists "$POP_TARGET_DB"; then
    die "target database '$POP_TARGET_DB' not found; create it in MultiLib.exe first (Flibusta plugin)"
fi

# map first: without it, resolution is impossible (a real run must have it)
if [[ ! -s "$tmp/map.tsv" ]]; then
    if fetch_md5_map; then
        :
    elif (( DRY_RUN )); then
        log "warn : catalog md5 map unavailable; dry-run continues (all files would be unmatched)"
        : > "$tmp/map.tsv"
    else
        die "md5 map fetch failed; is MariaDB reachable? (see debug output)"
    fi
fi

do_walk
do_resolve

# resolved bookid set (sorted unique)
awk -F'\t' '$4 == "matched" && $3 ~ /^[0-9]+$/ { print $3 }' "$tmp/resolved.tsv" \
    | LC_ALL=C sort -un > "$tmp/bookids.txt"

# summary counters
files_total="$(wc -l < "$tmp/files.tsv" | tr -d ' ')"
matched="$(awk -F'\t' '$4 == "matched" {c++} END {print c+0}' "$tmp/resolved.tsv")"
unmatched="$(awk -F'\t' '$4 == "unmatched" {c++} END {print c+0}' "$tmp/resolved.tsv")"
corrupt="$(awk -F'\t' '$3 == "corrupt" {c++} END {print c+0}' "$tmp/resolved.tsv")"
skipped="$(awk -F'\t' '$3 == "skipped" {c++} END {print c+0}' "$tmp/resolved.tsv")"
bookids="$(wc -l < "$tmp/bookids.txt" | tr -d ' ')"
dupes="$(wc -l < "$tmp/dupes.txt" | tr -d ' ')"

if (( ! DRY_RUN )); then
    generate_rebuild_sql
    if [[ -s "$tmp/rebuild.sql" ]]; then
        # v1.2.0 (docs/archive/DO_IT_ongoing.md): AUTO_INCREMENT must be gone from ALL 16 PK
        # columns BEFORE any data lands; the strip is schema-only, verified,
        # and runs before the first TRUNCATE/INSERT
        strip_auto_increment
        log "info : rebuilding $POP_TARGET_DB (source keys verbatim, $(wc -l < "$tmp/rebuild.sql" | tr -d ' ') SQL lines)"
        run_mysql "${mysql_args[@]}" "$POP_TARGET_DB" < "$tmp/rebuild.sql" \
            || die "rebuild of $POP_TARGET_DB failed"
        auto_inc_left "$tmp/post_left.txt"   # post-run guard: still none
        verify_fk_integrity                    # v1.3.0: verbatim keys must reference existing parents
        rows="$(run_mysql "${mysql_args[@]}" -B --skip-column-names \
            -e "SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema='$POP_TARGET_DB' AND table_name IN ('mlbook','mlauthor','mlgenre','mlseq','mlrating','mlcustinfo','mlauthorname','mlgenrename','mlseqname') ORDER BY table_name" \
            2>/dev/null || true)"
        debug "target rows: $(echo "$rows" | tr '\n' ' ')"
    fi    else
    log "dry-run: would rebuild $POP_TARGET_DB from $bookids resolved bookid(s) (row-by-row INSERTs, source keys verbatim, AUTO_INCREMENT stripped)"
fi

do_report

# --- summary on stdout -----------------------------------------------------------------------
printf 'populate summary (source %s -> target %s):\n' "$POP_SOURCE_DB" "$POP_TARGET_DB"
printf '  %-33s %6s\n' 'files scanned'            "$files_total"
printf '  %-33s %6s\n' '  zip-wrapped fb2'        "$(awk -F'\t' '$4=="zip"&&$3!="skipped"{c++}END{print c+0}' "$tmp/files.tsv")"
printf '  %-33s %6s\n' '  loose fb2'              "$(awk -F'\t' '$4=="fb2"{c++}END{print c+0}' "$tmp/files.tsv")"
printf '  %-33s %6s\n' '  skipped (non-book)'     "$skipped"
printf '  %-33s %6s\n' '  corrupt (unreadable)'   "$corrupt"
printf '  %-33s %6s\n' 'matched (bookid resolved)' "$matched"
printf '  %-33s %6s\n' 'unmatched (need fallback)' "$unmatched"
printf '  %-33s %6s\n' 'bookids registered'       "$bookids"
printf '  %-33s %6s\n' 'md5 dupes (lowest kept)'  "$dupes"

exit 0