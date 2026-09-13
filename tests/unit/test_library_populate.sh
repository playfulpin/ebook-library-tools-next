#!/usr/bin/env bash

# __ETL_TEST_ENV_GUARD__: a caller with set -x/set -v auto-exports SHELLOPTS;
# every child bash re-applies it (it is readonly when imported), so xtrace
# noise corrupts the suites output captures.  Re-exec clean instead.
if [[ ${SHELLOPTS-} == *xtrace* || ${SHELLOPTS-} == *verbose* ]]; then
    exec env -u SHELLOPTS -u BASHOPTS bash "$0" "$@"
fi
unset SHELLOPTS BASHOPTS 2>/dev/null || true

# -----------------------------------------------------------------------------
# tests/test_library_populate.sh
#
# Regression suite for bin/library/library_populate.sh v1.3.0 (rebuild of the
# app-registered personal library DB from the on-disk Books collection by
# md5-matching against the flibusta catalog, with SOURCE keys copied
# VERBATIM (no synthetic keys) and an AUTO_INCREMENT-free target schema).
# No real MariaDB is needed: the suite installs mock `mysql`, `unzip`,
# `zcat`, `tasklist` and `powershell.exe` earlier in PATH that record their
# argv, serve fixture catalog tables from $MOCK_FIXTURES, and capture the
# generated rebuild SQL (piped via stdin) into $MOCK_SQL_LOG.
#
# Asserts the v1.3.0 contract:
#   - walk: zip-wrapped FB2 hashed by DECOMPRESSED content (unzip -p with
#     zcat fallback), arcname from `unzip -Z1`, loose fb2 hashed directly,
#     desktop.ini / non-book files skipped, unreadable zips marked corrupt
#   - map: one read-only (md5, bookid) pull from flibusta.mlbook with the
#     toolchain connection contract (password via MYSQL_PWD only);
#     duplicate md5s resolve to the lowest bookid and are counted
#   - rebuild: AUTO_INCREMENT STRIP first (schema-driven ALTERs on all 16
#     PK columns, attribute-preserving, verified via information_schema)
#     then TRUNCATE + row-by-row INSERTs carrying the flibusta SOURCE keys
#     VERBATIM - bookid = the md5-resolved catalog bookid, authorid /
#     genreid / seqid and the child PKs (la_id/gn_id/sq_id/rt_id/ci_id)
#     straight from the source rows; NO tool-assigned 1..N counters, NO
#     session-variable remaps (@bid_/... absent), NO LAST_INSERT_ID()
#   - mlbook.filename = the CATALOG value (flibusta.mlbook.filename, the
#     transliterated name the app expects - NOT the on-disk path), while
#     arcname = on-disk zip member name, filesize = on-disk bytes,
#     library='myprivatelib'
#   - reference tables (mlauthorname, mlgenrename, mlseqname) populated
#     for the personal library's books only; mlgenrename includes the
#     used genres' ANCESTOR CATEGORIES (fetched from the catalog) so the
#     genre tree is preserved, with source genreid/parentgenreid copied
#     verbatim (no remap; a fetched ancestor that is also a used genre
#     is deduped by id)
#   - mlrating copied from flibusta.mlrating (per-book aggregate), only
#     for books that have a rating
#   - chunked reads (POP_CHUNK) merge + dedupe to a deterministic script
#   - column-parity mismatch on ANY managed table aborts the run before
#     any TRUNCATE (all-or-nothing; a partial rebuild would leave
#     dangling key references)
#   - report: per-run TSV written only outside --dry-run
#   - FK integrity gate after the reload: 9 reference paths, 0 orphans
#   - guards: target DB missing -> exit 1; source == target -> exit 2
#   - MariaDB lifecycle mocks (already running untouched, down -> start /
#     use / stop, no tasklist disables management, --dry-run reports only)
#   - version header stays in sync with `--version` (1.3.x)
#
# Usage:  bash tests/test_library_populate.sh
# Runs anywhere (pure text processing; the mocks avoid any DB dependency).
# -----------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOL="$REPO_ROOT/bin/library/library_populate.sh"

PASS_COUNT=0
FAIL_COUNT=0
declare -a FAILURE_LINES=()

report() { # label  ok|fail  [detail]
    local label="$1" status="$2" detail="${3:-}"
    if [[ "$status" == "ok" ]]; then
        echo "  PASS  $label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL  $label"
        [[ -n "$detail" ]] && echo "        $detail"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILURE_LINES+=("$label: $detail")
    fi
}

TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/populate_test.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT

# --- fixture library tree ------------------------------------------------------
LIB="$TMPDIR/Books"
mkdir -p "$LIB/A/Author One/Series X" "$LIB/Б/Автор Два" "$LIB/Broken"
printf 'content-%s' '01-Book One.zip'   > "$LIB/A/Author One/Series X/01-Book One.zip"
printf 'content-%s' '02-Book Two.zip'   > "$LIB/A/Author One/Series X/02-Book Two.zip"
printf 'content-%s' '03-No Match.zip'   > "$LIB/A/Author One/Series X/03-No Match.zip"
printf 'hello fb2 content' > "$LIB/Б/Автор Два/Книга Три.fb2"
printf 'win metadata' > "$LIB/A/Author One/desktop.ini"
printf 'notes' > "$LIB/A/Author One/notes.txt"
printf 'not a zip' > "$LIB/Broken/Corrupt.zip"

zip1_md5="$(printf 'content-%s' '01-Book One.zip' | md5sum | awk '{print $1}')"
zip2_md5="$(printf 'content-%s' '02-Book Two.zip' | md5sum | awk '{print $1}')"
nomatch_md5="$(printf 'content-%s' '03-No Match.zip' | md5sum | awk '{print $1}')"
fb2_md5="$(md5sum "$LIB/Б/Автор Два/Книга Три.fb2" | awk '{print $1}')"

# --- mock catalog fixtures (tab-separated, exactly as mysql -B --raw emits) ----
FIX="$TMPDIR/fixtures"
mkdir -p "$FIX"

# mlbook: 26 columns - bookid, library, title, lang, date_in, filename,
# filesize, arcname, ext, deleted, md5, srclang, date_wr, keywords,
# di_progused, di_date, di_srcurl, di_srcosr, di_author, di_id, di_version,
# pi_bookname, pi_publisher, pi_city, pi_year, pi_isbn
{
    printf '111\tflibusta\tTitle One\tru\t2024-01-14 16:55:25\tTitle_One_FB2\t890489\t\tfb2\t0\t%s\t\t\t\t\t\t\t\t\t\t1.1\t\t\t\t2022\t\n' "$zip1_md5"
    printf '222\tflibusta\tTitle Two\tru\t2024-02-14 16:55:25\tTitle_Two_FB2\t890490\t\tfb2\t0\t%s\t\t\t\t\t\t\t\t\t\t1.1\t\t\t\t2021\t\n' "$zip2_md5"
    printf '333\tflibusta\tКнига Три\tru\t2024-03-14 16:55:25\tKniga_Tri_FB2\t890491\t\tfb2\t0\t%s\t\t\t\t\t\t\t\t\t\t1.1\t\t\t\t2020\t\n' "$fb2_md5"
} > "$FIX/mlbook.tsv"

# authors: authorid, FirstName, MiddleName, LastName, NickName, FullName,
# Email, TotalCount, NormalCount
{
    printf '5001\tA\t\tOne\t\tA One\t\t60\t49\n'
    printf '5002\tB\t\tTwo\t\tB Two\t\t30\t25\n'
    printf '5003\tC\t\tThree\t\tC Three\t\t10\t8\n'
} > "$FIX/authors.tsv"

# genres: genreid, parentgenreid, genrecode, genrenamerus, TotalCount,
# NormalCount (the JOIN fetch = genres used by our books).
#   9002's parent (9001) IS used by a book too;
#   9003's parent (7777) exists NOWHERE -> dangling -> NULL;
#   9004's parent (9100) is a CATEGORY no book references -> must be
#   pulled in by the ancestor fetch (served from genres_ancestors.tsv)
{
    printf '9001\tNULL\tsf\tScience Fiction\t10\t8\n'
    printf '9002\t9001\tsf_hard\tHard SF\t5\t4\n'
    printf '9003\t7777\tfantasy\tFantasy\t7\t5\n'
    printf '9004\t9100\tsf_city\tCity SF\t3\t3\n'
} > "$FIX/genres.tsv"
# ancestor-category fixture (served for the mlgenrename ancestor fetch):
# 9100 is a top-level category (parentgenreid NULL, no genrecode, no
# TotalCount) exactly like the catalog's 1000001+ rows
printf '9100\tNULL\t\tCategory Name\t0\t0\n' > "$FIX/genres_ancestors.tsv"

# seqs: seqid, seqname, TotalCount, NormalCount
printf '7001\tSeries One\t3\t3\n' > "$FIX/seqs.tsv"

# joins / attached data
{
    printf '901146\t111\t5001\ta\n'
    printf '901147\t222\t5001\ta\n'
    printf '901148\t222\t5002\ta\n'
    printf '901149\t333\t5003\ta\n'
} > "$FIX/mlauthor.tsv"
{
    printf '1127730\t111\t9001\n'
    printf '1127731\t111\t9002\n'
    printf '1127732\t222\t9003\n'
    printf '1127733\t222\t9004\n'
    printf '1127734\t333\t9001\n'
} > "$FIX/mlgenre.tsv"
{
    printf '359598\t111\t7001\t1\n'
    printf '359599\t222\t7001\t2\n'
} > "$FIX/mlseq.tsv"
{
    printf '309521\t111\t5\n'
    printf '309522\t222\t4\n'
} > "$FIX/mlrating.tsv"     # 333 has NO rating -> no row
printf '130083\t111\t\tcustom info\n' > "$FIX/mlcustinfo.tsv"

# --- mocks ---------------------------------------------------------------------
MOCK_BIN="$TMPDIR/mockbin"
MOCK_LOG="$TMPDIR/mysql-argv.log"
MOCK_SQL_LOG="$TMPDIR/mysql-stdin.sql"
MOCK_MAP="$TMPDIR/mock-map.tsv"
mkdir -p "$MOCK_BIN"

# catalog map: zip1 is duplicated in the catalog (111 and 999) - lowest wins;
# 0000... exists in the catalog but is not on disk (03-No Match.zip stays unmatched)
printf '%s\t111\n%s\t222\n%s\t333\n%s\t999\n%s\t777\n' \
    "$zip1_md5" "$zip2_md5" "$fb2_md5" "$zip1_md5" "00000000000000000000000000000000" > "$MOCK_MAP"

cat > "$MOCK_BIN/mysql" <<'MOCK_EOF'
#!/usr/bin/env bash
printf 'MYSQL %s\n' "$*" >> "${MOCK_LOG:-/dev/null}"
if [ ! -t 0 ]; then cat >> "${MOCK_SQL_LOG:-/dev/null}"; fi
args="$*"
F="${MOCK_FIXTURES:-}"
if [[ "$args" == *"SHOW DATABASES LIKE"* ]]; then
    if [[ "${MOCK_DB_EXISTS:-myprivatelib}" == "__none__" ]]; then
        :
    else
        echo "${MOCK_DB_EXISTS:-myprivatelib}"
    fi
elif [[ "$args" == *"information_schema.COLUMNS"* ]]; then
    table="$(printf '%s' "$args" | sed -n "s/.*TABLE_NAME='\([^']*\)'.*/\1/p")"
    # parity corruption only for the TARGET db, so source vs target mismatch
    if [[ -n "${MOCK_PARITY_BAD:-}" ]] && [[ "$table" == "$MOCK_PARITY_BAD" ]] \
       && [[ "$args" == *"TABLE_SCHEMA='myprivatelib'"* ]]; then
        echo "DIFFERENT:int"
    else
        echo "${MOCK_PARITY:-bookid:int,title:varchar}"
    fi
elif [[ "$args" == *"SELECT md5, bookid FROM"* ]]; then
    cat "${MOCK_MAP:-/dev/null}"
elif [[ "$args" == *"JOIN flibusta.mlauthorname"* ]]; then
    cat "$F/authors.tsv" 2>/dev/null
elif [[ "$args" == *"JOIN flibusta.mlgenrename"* ]]; then
    cat "$F/genres.tsv" 2>/dev/null
elif [[ "$args" == *"FROM flibusta.mlgenrename WHERE"* ]]; then
    cat "$F/genres_ancestors.tsv" 2>/dev/null
elif [[ "$args" == *"JOIN flibusta.mlseqname"* ]]; then
    cat "$F/seqs.tsv" 2>/dev/null
elif [[ "$args" == *"FROM flibusta.mlbook WHERE"* ]]; then
    cat "$F/mlbook.tsv" 2>/dev/null
elif [[ "$args" == *"FROM flibusta.mlauthor WHERE"* ]]; then
    cat "$F/mlauthor.tsv" 2>/dev/null
elif [[ "$args" == *"FROM flibusta.mlgenre WHERE"* ]]; then
    cat "$F/mlgenre.tsv" 2>/dev/null
elif [[ "$args" == *"FROM flibusta.mlseq WHERE"* ]]; then
    cat "$F/mlseq.tsv" 2>/dev/null
elif [[ "$args" == *"FROM flibusta.mlrating WHERE"* ]]; then
    cat "$F/mlrating.tsv" 2>/dev/null
elif [[ "$args" == *"FROM flibusta.mlcustinfo WHERE"* ]]; then
    cat "$F/mlcustinfo.tsv" 2>/dev/null
elif [[ "$args" == *"SELECT EXTRA FROM information_schema.COLUMNS"* ]]; then
    # empty = no AUTO_INCREMENT left on any PK column (post-strip verify)
    echo "${MOCK_EXTRA:-}"
elif [[ "$args" == *"SHOW CREATE TABLE myprivatelib."* ]]; then
    # DDL fixtures: the 9 managed tables carry AUTO_INCREMENT PK columns
    # (so the strip emits 9 ALTERs); app-owned tables are not served, so
    # their SHOW CREATE returns nothing -> no ALTER (mock would fail them
    # on a real server only if the table were missing, which it is not)
    table="$(printf '%s' "$args" | sed -n "s/.*SHOW CREATE TABLE myprivatelib\.\([^ ]*\).*/\1/p")"
    case "$table" in
        mlbook)       printf 'CREATE TABLE `mlbook` (\n  `bookid` int(11) NOT NULL AUTO_INCREMENT,\n  `title` varchar(255) NOT NULL,\n  PRIMARY KEY (`bookid`)\n) ENGINE=MyISAM\n' ;;
        mlauthorname) printf 'CREATE TABLE `mlauthorname` (\n  `authorid` int(11) NOT NULL AUTO_INCREMENT,\n  `FullName` varchar(255) NOT NULL,\n  PRIMARY KEY (`authorid`)\n) ENGINE=MyISAM\n' ;;
        mlgenrename)  printf 'CREATE TABLE `mlgenrename` (\n  `genreid` int(11) NOT NULL AUTO_INCREMENT,\n  `genrecode` varchar(25) NOT NULL,\n  PRIMARY KEY (`genreid`)\n) ENGINE=MyISAM\n' ;;
        mlseqname)    printf 'CREATE TABLE `mlseqname` (\n  `seqid` int(11) NOT NULL AUTO_INCREMENT,\n  `seqname` varchar(255) NOT NULL,\n  PRIMARY KEY (`seqid`)\n) ENGINE=MyISAM\n' ;;
        mlauthor)     printf 'CREATE TABLE `mlauthor` (\n  `la_id` int(11) NOT NULL AUTO_INCREMENT,\n  `bookid` int(11) NOT NULL,\n  PRIMARY KEY (`la_id`)\n) ENGINE=MyISAM\n' ;;
        mlgenre)      printf 'CREATE TABLE `mlgenre` (\n  `gn_id` int(11) NOT NULL AUTO_INCREMENT,\n  `bookid` int(11) NOT NULL,\n  PRIMARY KEY (`gn_id`)\n) ENGINE=MyISAM\n' ;;
        mlseq)        printf 'CREATE TABLE `mlseq` (\n  `sq_id` int(11) NOT NULL AUTO_INCREMENT,\n  `bookid` int(11) NOT NULL,\n  PRIMARY KEY (`sq_id`)\n) ENGINE=MyISAM\n' ;;
        mlrating)     printf 'CREATE TABLE `mlrating` (\n  `rt_id` int(11) NOT NULL AUTO_INCREMENT,\n  `bookid` int(11) NOT NULL,\n  PRIMARY KEY (`rt_id`)\n) ENGINE=MyISAM\n' ;;
        mlcustinfo)   printf 'CREATE TABLE `mlcustinfo` (\n  `ci_id` int(11) NOT NULL AUTO_INCREMENT,\n  `bookid` int(11) NOT NULL,\n  PRIMARY KEY (`ci_id`)\n) ENGINE=MyISAM\n' ;;
        *) : ;;
    esac
elif [[ "$args" == *"SELECT table_name, table_rows FROM"* ]]; then
    echo "${MOCK_TABLE_ROWS:-mlbook 3
mlauthor 3}"
elif [[ "$args" == *"LEFT JOIN myprivatelib.mlbook p ON p.bookid = c.bookid"* ]]; then
    # FK integrity gate: mock all reference paths as clean (0 orphans);
    # MOCK_FK_ORPHANS='path count' makes the gate fail (test-only hook)
    if [[ -n "${MOCK_FK_ORPHANS:-}" ]]; then
        printf '%s\n' "$MOCK_FK_ORPHANS"
    else
        printf 'chk\t0\n'
    fi
else
    echo "Query OK, 0 rows affected"
fi
exit "${MOCK_RC:-0}"
MOCK_EOF
chmod +x "$MOCK_BIN/mysql"

# unzip -p: content derived from the member filename (deterministic per file);
# a member named Corrupt* fails (drives the zcat fallback -> also fails).
# unzip -Z1: the zip member name (basename with .fb2).
cat > "$MOCK_BIN/unzip" <<'UNZIP_EOF'
#!/usr/bin/env bash
case "$*" in
    *Corrupt*) exit 1 ;;
esac
if [[ "$*" == *-Z1* ]]; then
    printf '%s\n' "$(basename "$2" .zip).fb2"
    exit 0
fi
printf 'content-%s' "$(basename "$2")"
UNZIP_EOF
chmod +x "$MOCK_BIN/unzip"

cat > "$MOCK_BIN/zcat" <<'ZCAT_EOF'
#!/usr/bin/env bash
case "$*" in
    *Corrupt*) exit 1 ;;
esac
printf 'zcat-fallback-content'
ZCAT_EOF
chmod +x "$MOCK_BIN/zcat"

cat > "$MOCK_BIN/tasklist" <<'TASKLIST_EOF'
#!/usr/bin/env bash
if [[ "${MARIA_MOCK_RUNNING:-0}" == "1" ]]; then
    printf 'mysqld.exe                   26464 Console                    1    123,456 K\n'
fi
exit 0
TASKLIST_EOF
cat > "$MOCK_BIN/powershell.exe" <<'PS_EOF'
#!/usr/bin/env bash
printf 'PS %s\n' "$*" >> "${MOCK_LOG:-/dev/null}"
exit 0
PS_EOF
chmod +x "$MOCK_BIN/tasklist" "$MOCK_BIN/powershell.exe"

REPORT_DIR="$TMPDIR/reports"

run_tool() { # [args...] ; stdout->$OUT, stderr->$ERR ; rc->$RC
    OUT="$TMPDIR/stdout.txt" ERR="$TMPDIR/stderr.txt"
    rm -f "$MOCK_SQL_LOG"
    env PATH="$MOCK_BIN:$PATH" \
        MOCK_LOG="$MOCK_LOG" MOCK_SQL_LOG="$MOCK_SQL_LOG" \
        MOCK_FIXTURES="$FIX" MOCK_MAP="$MOCK_MAP" \
        MOCK_DB_EXISTS="${MOCK_DB_EXISTS:-myprivatelib}" \
        MOCK_PARITY="${MOCK_PARITY:-bookid:int,title:varchar}" \
        MOCK_PARITY_BAD="${MOCK_PARITY_BAD:-}" \
        MOCK_TABLE_ROWS="${MOCK_TABLE_ROWS:-mlbook 3
mlauthor 3}" \
        MOCK_RC="${MOCK_RC:-0}" \
        MYSQL_PASSWORD="${MOCK_PASSWORD:-}" \
        MARIA_TASKLIST="${MARIA_TASKLIST_OVERRIDE:-$TMPDIR/no-such-tasklist}" \
        MARIA_MOCK_RUNNING="${MARIA_MOCK_RUNNING:-0}" \
        CONF_FILE="$TMPDIR/no-such.conf" \
        POP_LIBRARY_ROOT="$LIB" POP_REPORT_DIR="$REPORT_DIR" \
        POP_SOURCE_DB="${POP_SOURCE_DB:-flibusta}" \
        POP_TARGET_DB="${POP_TARGET_DB:-myprivatelib}" \
        POP_CHUNK="${POP_CHUNK:-2}" \
        bash "$TOOL" "$@" >"$OUT" 2>"$ERR" < /dev/null
    RC=$?
}

sql()  { grep -c "$1" "$MOCK_SQL_LOG" 2>/dev/null || echo 0; }
argv() { grep -c "$1" "$MOCK_LOG" 2>/dev/null || echo 0; }

echo "== library_populate (source keys verbatim) =="

# --- version / usage -----------------------------------------------------------
version="$(sed -n 's/^# Version:[[:space:]]*//p' "$TOOL" | head -n 1)"
case "$version" in
    1.3.*) report "version_header" ok "header $version" ;;
    *)     report "version_header" fail "got '$version', expected 1.3.x" ;;
esac

bash "$TOOL" --version >"$TMPDIR/v.txt" 2>&1
if [[ "$(cat "$TMPDIR/v.txt")" == "bin/library/library_populate.sh v$version" ]]; then
    report "version_flag" ok
else
    report "version_flag" fail "got '$(cat "$TMPDIR/v.txt")'"
fi

bash "$TOOL" --help >"$TMPDIR/h.txt" 2>&1
if (( $? == 0 )) && grep -q -- "--dry-run" "$TMPDIR/h.txt" && grep -q "myprivatelib" "$TMPDIR/h.txt"; then
    report "help_exit0" ok
else
    report "help_exit0" fail "help must exit 0 and describe the tool"
fi

bash "$TOOL" --bogus >"$TMPDIR/u.txt" 2>&1
if (( $? == 2 )); then
    report "unknown_option_exit2" ok
else
    report "unknown_option_exit2" fail "expected exit 2"
fi

# --- source == target guard ------------------------------------------------------
POP_SOURCE_DB=myprivatelib POP_TARGET_DB=myprivatelib POP_LIBRARY_ROOT="$LIB" bash "$TOOL" >"$TMPDIR/g.txt" 2>&1
if (( $? == 1 )) && grep -q "must differ" "$TMPDIR/g.txt"; then
    report "source_target_must_differ" ok
else
    report "source_target_must_differ" fail "got rc=$? stderr=$(head -2 "$TMPDIR/g.txt")"
fi

# --- dry-run: walk + resolve + report, NO database writes -------------------------
rm -f "$MOCK_LOG"; rm -rf "$REPORT_DIR"
MOCK_RC=0 run_tool --dry-run
argv_log="$(cat "$MOCK_LOG" 2>/dev/null || true)"
if (( RC == 0 )) \
   && grep -q "matched (bookid resolved)" "$OUT" \
   && grep -q "3" "$OUT" <<<"$(grep 'matched (bookid resolved)' "$OUT")" \
   && grep -q "unmatched (need fallback)" "$OUT" \
   && grep -q "1" "$OUT" <<<"$(grep 'unmatched (need fallback)' "$OUT")" \
   && grep -q "md5 dupes (lowest kept)" "$OUT" \
   && grep -q "1" "$OUT" <<<"$(grep 'md5 dupes (lowest kept)' "$OUT")"; then
    report "dryrun_summary_counts" ok
else
    report "dryrun_summary_counts" fail "rc=$RC out=$(head -12 "$OUT" | tr '\n' '|')"
fi
if (( RC == 0 )) && [[ "$argv_log" != *"TRUNCATE"* ]] \
   && [[ ! -d "$REPORT_DIR" ]] \
   && [[ ! -s "$MOCK_SQL_LOG" ]] \
   && grep -q "would be written" "$ERR" \
   && grep -q "would rebuild" "$ERR"; then
    report "dryrun_no_writes" ok
else
    report "dryrun_no_writes" fail "rc=$RC log=$argv_log sql=${MOCK_SQL_LOG:-absent} err=$(head -3 "$ERR" | tr '\n' '|')"
fi
if [[ "$argv_log" == *"SELECT md5, bookid FROM flibusta.mlbook"* ]] \
   && [[ "$argv_log" == *"--skip-column-names --raw"* ]] \
   && [[ "$argv_log" == *"--connect-timeout="* ]]; then
    report "map_query_contract" ok
else
    report "map_query_contract" fail "got: $argv_log"
fi
if grep -q "corrupt" "$OUT" && grep -q "skipped (non-book)" "$OUT"; then
    report "walk_corrupt_and_skipped" ok
else
    report "walk_corrupt_and_skipped" fail "out=$(grep -E 'corrupt|skipped' "$OUT" | tr '\n' '|')"
fi

# --- password never on the command line ------------------------------------------
rm -f "$MOCK_LOG"
MOCK_RC=0 MOCK_PASSWORD=s3cret run_tool --dry-run
argv_log="$(cat "$MOCK_LOG" 2>/dev/null || true)"
if [[ "$argv_log" == *"s3cret"* ]]; then
    report "password_never_on_cmdline" fail "password leaked into argv"
else
    report "password_never_on_cmdline" ok
fi

# --- real run: TRUNCATE + row-by-row INSERTs with SOURCE keys verbatim ---------------
rm -f "$MOCK_LOG"; rm -rf "$REPORT_DIR"
MOCK_RC=0 run_tool
argv_log="$(cat "$MOCK_LOG" 2>/dev/null || true)"
if (( RC == 0 )); then
    report "run_exit0" ok
else
    report "run_exit0" fail "rc=$RC stderr=$(head -4 "$ERR")"
fi
all9="mlauthorname mlgenrename mlseqname mlbook mlauthor mlgenre mlseq mlrating mlcustinfo"
ok9=1
for t in $all9; do
    if ! grep -q "TRUNCATE TABLE myprivatelib.$t;" "$MOCK_SQL_LOG"; then
        ok9=0
        break
    fi
done
if (( ok9 )); then
    report "truncates_all_9" ok
else
    report "truncates_all_9" fail "missing TRUNCATE; sql=$(grep TRUNCATE "$MOCK_SQL_LOG" 2>/dev/null | tr '\n' '|')"
fi

# AUTO_INCREMENT strip: schema-driven ALTERs for the columns the mock
# schema declares with AUTO_INCREMENT; already-plain columns emit nothing
strip_n="$(grep -c '^ALTER TABLE myprivatelib\.' "$MOCK_SQL_LOG" 2>/dev/null || echo 0)"
if grep -q '^ALTER TABLE myprivatelib\.mlbook MODIFY COLUMN `bookid` int(11) NOT NULL;$' "$MOCK_SQL_LOG" \
   && grep -q '^ALTER TABLE myprivatelib\.mlauthorname MODIFY COLUMN `authorid` int(11) NOT NULL;$' "$MOCK_SQL_LOG" \
   && grep -q '^ALTER TABLE myprivatelib\.mlseqname MODIFY COLUMN `seqid` int(11) NOT NULL;$' "$MOCK_SQL_LOG" \
   && grep -q '^ALTER TABLE myprivatelib\.mlgenrename MODIFY COLUMN `genreid` int(11) NOT NULL;$' "$MOCK_SQL_LOG" \
   && grep -q '^ALTER TABLE myprivatelib\.mlauthor MODIFY COLUMN `la_id` int(11) NOT NULL;$' "$MOCK_SQL_LOG" \
   && grep -q '^ALTER TABLE myprivatelib\.mlgenre MODIFY COLUMN `gn_id` int(11) NOT NULL;$' "$MOCK_SQL_LOG" \
   && grep -q '^ALTER TABLE myprivatelib\.mlseq MODIFY COLUMN `sq_id` int(11) NOT NULL;$' "$MOCK_SQL_LOG" \
   && grep -q '^ALTER TABLE myprivatelib\.mlrating MODIFY COLUMN `rt_id` int(11) NOT NULL;$' "$MOCK_SQL_LOG" \
   && grep -q '^ALTER TABLE myprivatelib\.mlcustinfo MODIFY COLUMN `ci_id` int(11) NOT NULL;$' "$MOCK_SQL_LOG" \
   && [[ "$strip_n" == "9" ]]; then
    report "autoinc_strip_alters" ok "9 ALTERs"
else
    report "autoinc_strip_alters" fail "count=$strip_n sql=$(grep '^ALTER TABLE' "$MOCK_SQL_LOG" 2>/dev/null | tr '\n' '|')"
fi
if ! grep -q '^ALTER TABLE myprivatelib\.mlbook .*AUTO_INCREMENT' "$MOCK_SQL_LOG" \
   && grep -q "SELECT EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='myprivatelib'" "$MOCK_LOG"; then
    report "autoinc_strip_verified" ok
else
    report "autoinc_strip_verified" fail "argv=$(grep 'EXTRA FROM' "$MOCK_LOG" | head -1)"
fi

# reference tables: authors, genres (tree + ancestors), series - keys are the
# SOURCE values verbatim, no SET @var bookkeeping anywhere
if grep -q "INSERT INTO myprivatelib.mlauthorname (authorid,FirstName,MiddleName,LastName,NickName,FullName,Email,TotalCount,NormalCount) VALUES (5001,'A','','One','','A One','',60,49);" "$MOCK_SQL_LOG" \
   && grep -q "VALUES (5002,'B','','Two','','B Two','',30,25);" "$MOCK_SQL_LOG" \
   && grep -q "VALUES (5003,'C','','Three','','C Three','',10,8);" "$MOCK_SQL_LOG"; then
    report "authors_source_keys" ok
else
    report "authors_source_keys" fail "sql=$(grep mlauthorname "$MOCK_SQL_LOG" 2>/dev/null | tr '\n' '|')"
fi
if grep -q "VALUES (9001,NULL,'sf','Science Fiction',10,8);" "$MOCK_SQL_LOG" \
   && grep -q "VALUES (9002,9001,'sf_hard','Hard SF',5,4);" "$MOCK_SQL_LOG" \
   && grep -q "VALUES (9004,9100,'sf_city','City SF',3,3);" "$MOCK_SQL_LOG" \
   && grep -q "VALUES (9100,NULL,'','Category Name',0,0);" "$MOCK_SQL_LOG" \
   && grep -q "VALUES (9003,7777,'fantasy','Fantasy',7,5);" "$MOCK_SQL_LOG"; then
    report "genres_tree_source_keys" ok
else
    report "genres_tree_source_keys" fail "sql=$(grep mlgenrename "$MOCK_SQL_LOG" 2>/dev/null | tr '\n' '|')"
fi
if grep -q "INSERT INTO myprivatelib.mlseqname (seqid,seqname,TotalCount,NormalCount) VALUES (7001,'Series One',3,3);" "$MOCK_SQL_LOG"; then
    report "series_source_keys" ok
else
    report "series_source_keys" fail "sql=$(grep mlseqname "$MOCK_SQL_LOG" 2>/dev/null | tr '\n' '|')"
fi
# no synthetic-key machinery at all: no session-variable remaps, no counters
if ! grep -qE "SET @(bid|aid|gid|sid)_" "$MOCK_SQL_LOG"; then
    report "no_session_var_remapping" ok
else
    report "no_session_var_remapping" fail "found: $(grep -E 'SET @' "$MOCK_SQL_LOG" 2>/dev/null | tr '\n' '|')"
fi

# mlbook: one row per resolved book; filename = CATALOG value
# (flibusta.mlbook.filename), arcname = on-disk zip member, SOURCE bookid
if grep -q "INSERT INTO myprivatelib.mlbook (bookid,library,title,lang,date_in,filename,filesize,arcname,ext,deleted,md5" "$MOCK_SQL_LOG" \
   && grep -q "VALUES (111,'myprivatelib','Title One','ru','2024-01-14 16:55:25','Title_One_FB2'," "$MOCK_SQL_LOG" \
   && grep -q "VALUES (222,'myprivatelib','Title Two" "$MOCK_SQL_LOG" \
   && grep -q "VALUES (333,'myprivatelib','Книга Три" "$MOCK_SQL_LOG" \
   && grep -q "'01-Book One.fb2','fb2'" "$MOCK_SQL_LOG"; then
    report "mlbook_catalog_filename_source_bookid" ok
else
    report "mlbook_catalog_filename_source_bookid" fail "sql=$(grep 'INSERT INTO myprivatelib.mlbook' "$MOCK_SQL_LOG" 2>/dev/null | tr '\n' '|')"
fi

# joins reference ONLY the SOURCE keys verbatim
if grep -q "INSERT INTO myprivatelib.mlauthor (la_id,bookid,authorid,role) VALUES (901146,111,5001,'a');" "$MOCK_SQL_LOG" \
   && grep -q "VALUES (901147,222,5001,'a');" "$MOCK_SQL_LOG" \
   && grep -q "VALUES (901149,333,5003,'a');" "$MOCK_SQL_LOG" \
   && grep -q "INSERT INTO myprivatelib.mlgenre (gn_id,bookid,genreid) VALUES (1127730,111,9001);" "$MOCK_SQL_LOG" \
   && grep -q "INSERT INTO myprivatelib.mlgenre (gn_id,bookid,genreid) VALUES (1127733,222,9004);" "$MOCK_SQL_LOG" \
   && grep -q "INSERT INTO myprivatelib.mlseq (sq_id,bookid,seqid,seqnum) VALUES (359598,111,7001,1);" "$MOCK_SQL_LOG"; then
    report "joins_use_source_keys" ok
else
    report "joins_use_source_keys" fail "sql=$(grep -E 'mlauthor|mlgenre|mlseq ' "$MOCK_SQL_LOG" 2>/dev/null | tr '\n' '|')"
fi

# mlrating: only books WITH a rating (111, 222); 333 has none
rating_count="$(sql 'INSERT INTO myprivatelib.mlrating')"
if grep -q "INSERT INTO myprivatelib.mlrating (rt_id,bookid,rating) VALUES (309521,111,'5');" "$MOCK_SQL_LOG" \
   && grep -q "VALUES (309522,222,'4');" "$MOCK_SQL_LOG" \
   && [[ "$rating_count" == "2" ]]; then
    report "mlrating_aggregate_only" ok
else
    report "mlrating_aggregate_only" fail "count=$rating_count sql=$(grep mlrating "$MOCK_SQL_LOG" 2>/dev/null | tr '\n' '|')"
fi
if grep -q "INSERT INTO myprivatelib.mlcustinfo (ci_id,bookid,di_history,custominfo) VALUES (130083,111,'','custom info');" "$MOCK_SQL_LOG"; then
    report "mlcustinfo_source_key" ok
else
    report "mlcustinfo_source_key" fail "sql=$(grep mlcustinfo "$MOCK_SQL_LOG" 2>/dev/null | tr '\n' '|')"
fi

# the old synthetic-key patterns must be GONE: no INSERT..SELECT copies, no
# LAST_INSERT_ID, no @var captures (keys are source-verbatim now)
if ! grep -q "INSERT INTO myprivatelib.mlbook SELECT" "$MOCK_SQL_LOG" \
   && ! grep -q "INSERT INTO myprivatelib.mlauthorname SELECT" "$MOCK_SQL_LOG" \
   && ! grep -q "LAST_INSERT_ID" "$MOCK_SQL_LOG" \
   && ! grep -qE "SET @[a-z]+_" "$MOCK_SQL_LOG"; then
    report "no_exact_copy_no_synthetic_keys" ok
else
    report "no_exact_copy_no_synthetic_keys" fail "sql=$(grep -E 'SELECT \*|LAST_INSERT_ID|SET @' "$MOCK_SQL_LOG" 2>/dev/null | tr '\n' '|')"
fi

# FK integrity gate: after the reload, the tool must verify 9 reference paths
fk="$(grep -c "LEFT JOIN myprivatelib." "$MOCK_LOG" 2>/dev/null || echo 0)"
if [[ "$fk" -ge 9 ]] && grep -q "FK integrity OK" "$ERR"; then
    report "fk_integrity_gate" ok "9 paths"
else
    report "fk_integrity_gate" fail "paths=$fk err=$(grep -i 'fk' "$ERR" | tr '\n' '|')"
fi

# chunked reads: POP_CHUNK=2 -> two IN-lists; merged + deduped deterministically
if [[ "$argv_log" == *"bookid IN (111,222)"* ]] && [[ "$argv_log" == *"bookid IN (333)"* ]]; then
    report "chunked_reads" ok
else
    report "chunked_reads" fail "argv=$(echo "$argv_log" | grep -o "IN ([0-9,]*)" | tr '\n' '|')"
fi

if grep -q "bookids registered" "$OUT" && grep -q "3" "$OUT" <<<"$(grep 'bookids registered' "$OUT")"; then
    report "bookids_registered" ok
else
    report "bookids_registered" fail "out=$(grep 'bookids' "$OUT" | tr '\n' '|')"
fi
report_f="$(ls -1 "$REPORT_DIR"/library_populate_*.tsv 2>/dev/null | head -n 1 || true)"
if [[ -n "$report_f" ]] && grep -q "^processed_at" "$report_f" \
   && grep -q "$zip1_md5" "$report_f" \
   && grep -q "$fb2_md5" "$report_f"; then
    report "report_written" ok
else
    report "report_written" fail "file=${report_f:-none}"
fi
if [[ -n "$report_f" ]] && grep -q "111" "$report_f" \
   && ! grep -q "999" "$report_f"; then
    report "dupe_lowest_bookid" ok
else
    report "dupe_lowest_bookid" fail "report=$(head -8 "$report_f" | tr '\n' '|')"
fi

# --- determinism: POP_CHUNK=1 produces byte-identical rebuild SQL ------------------
sql_chunk1="$TMPDIR/sql_chunk1.sql"
rm -f "$MOCK_LOG"
MOCK_RC=0 POP_CHUNK=1 run_tool   # 3 chunks instead of 2
if (( RC != 0 )); then
    report "rebuild_deterministic" fail "POP_CHUNK=1 run failed rc=$RC"
else
    cp "$MOCK_SQL_LOG" "$sql_chunk1"
    rm -f "$MOCK_LOG"
    MOCK_RC=0 run_tool             # POP_CHUNK=2 (default)
    if (( RC == 0 )) && cmp -s "$sql_chunk1" "$MOCK_SQL_LOG"; then
        report "rebuild_deterministic" ok
    else
        report "rebuild_deterministic" fail "chunked and unchunked scripts differ (rc=$RC)"
    fi
fi

# --- parity mismatch: ANY managed table mismatch aborts BEFORE truncate ---------------
rm -f "$MOCK_LOG"; rm -rf "$REPORT_DIR"
MOCK_RC=0 MOCK_PARITY_BAD=mlbook run_tool
if (( RC == 1 )) && grep -q "column mismatch for mlbook" "$ERR" \
   && grep -q "column parity mismatch" "$ERR" \
   && [[ ! -s "$MOCK_SQL_LOG" ]]; then
    report "parity_mismatch_aborts" ok
else
    report "parity_mismatch_aborts" fail "rc=$RC stderr=$(head -5 "$ERR" | tr '\n' '|') sql=${MOCK_SQL_LOG:-absent}"
fi

# --- guard: target DB missing ----------------------------------------------------------
rm -f "$MOCK_LOG"
MOCK_DB_EXISTS=__none__ MOCK_RC=0 run_tool
if (( RC == 1 )) && grep -q "target database 'myprivatelib' not found" "$ERR"; then
    report "missing_target_db" ok
else
    report "missing_target_db" fail "rc=$RC stderr=$(head -2 "$ERR")"
fi

# --- MariaDB lifecycle -------------------------------------------------------------
echo "== MariaDB lifecycle =="

# 1) server already running -> left untouched
rm -f "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$MOCK_BIN/tasklist" MARIA_MOCK_RUNNING=1 MOCK_RC=0 run_tool
if (( RC == 0 )) && grep -q "already running" "$ERR" && ! grep -q "stopping MariaDB" "$ERR"; then
    report "lifecycle_already_running_untouched" ok
else
    report "lifecycle_already_running_untouched" fail "rc=$RC stderr=$(head -3 "$ERR")"
fi

# 2) server down -> started (elevated PS), used, stopped gracefully on exit
rm -f "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$MOCK_BIN/tasklist" MARIA_MOCK_RUNNING=0 MOCK_RC=0 run_tool
if (( RC == 0 )) \
   && grep -q "starting MariaDB" "$ERR" \
   && grep -q "MariaDB ready" "$ERR" \
   && grep -q "stopping MariaDB (graceful shutdown)" "$ERR" \
   && grep -q "MariaDB stopped" "$ERR" \
   && grep -q "Start-Process" "$MOCK_LOG"; then
    report "lifecycle_start_use_stop" ok
else
    report "lifecycle_start_use_stop" fail "rc=$RC stderr=$(head -4 "$ERR") pslog=$(cat "$MOCK_LOG")"
fi

# 3) no tasklist interop -> management disabled, tool connects directly
rm -f "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$TMPDIR/no-such-tasklist" MOCK_RC=0 run_tool
if (( RC == 0 )) && grep -q "tasklist not available" "$ERR" && ! grep -q "starting MariaDB" "$ERR"; then
    report "lifecycle_no_tasklist_disables_mgmt" ok
else
    report "lifecycle_no_tasklist_disables_mgmt" fail "rc=$RC stderr=$(head -3 "$ERR")"
fi

# 4) dry-run reports would-start / would-stop, never touches the server
rm -f "$MOCK_LOG"
MARIA_TASKLIST_OVERRIDE="$MOCK_BIN/tasklist" MARIA_MOCK_RUNNING=0 MOCK_RC=0 run_tool --dry-run
if (( RC == 0 )) && grep -q "\[dry-run\] would start MariaDB" "$ERR" \
   && grep -q "\[dry-run\] would stop MariaDB" "$ERR" \
   && ! grep -q "Start-Process" "$MOCK_LOG"; then
    report "lifecycle_dryrun_reports_only" ok
else
    report "lifecycle_dryrun_reports_only" fail "rc=$RC stderr=$(head -4 "$ERR") pslog=$(cat "$MOCK_LOG")"
fi

echo ""
echo "=============================="
echo "PASS: $PASS_COUNT   FAIL: $FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then
    printf '  - %s\n' "${FAILURE_LINES[@]}"
    exit 1
fi
echo "All tests passed."
exit 0
