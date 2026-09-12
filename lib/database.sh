#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# lib/database.sh
#
# Thin MySQL client helpers for the ebook-library-tools toolchain
# (Phase 3, plan §7 + Blueprint §22).
#
# Version:       1.0.0
# Last updated:  2026-09-07
#
# Provides (seeded verbatim from the argv block repeated in
# reconcile_library.sh / report_library.sh / authors_export.sh):
#   db_mysql_argv      - assemble the shared mysql argv from MYSQL_* env
#   db_run_query       - execute a query file, stdout only
#   db_run_sql         - execute an inline SQL string, stdout only
#   db_require_server  - probe 'SELECT 1' (start/readiness gate used by ingest)
#
# NOT here (Blueprint §22/§23): server start/stop/upgrade.  That stays in
# lib/mariadb_lifecycle.sh, which this library deliberately does not source —
# tools source both and compose them.
#
# Environment consumed (all optional):
#   MYSQL_CLIENT (default mysql), MYSQL_HOST, MYSQL_PORT, MYSQL_USER,
#   MYSQL_PASSWORD (passed via MYSQL_PWD), MYSQL_DATABASE, MYSQL_EXTRA_ARGS,
#   MYSQL_CHARSET (default utf8)
# -----------------------------------------------------------------------------
# shellcheck shell=bash

[[ -n "${_ETL_DATABASE_SH:-}" ]] && return 0
_ETL_DATABASE_SH=1

# shellcheck source=mariadb_lifecycle.sh
[[ -n "${_ETL_MARIADB_LIFECYCLE_SH:-}" ]] || true   # compose, don't force

db_mysql_argv() { # [$1 = database] -> argv on stdout (space-safe: array)
    local db="${1:-${MYSQL_DATABASE:-}}"
    local args=("${MYSQL_CLIENT:-mysql}")
    [[ -n "${MYSQL_HOST:-}"     ]] && args+=(-h "$MYSQL_HOST" --protocol=TCP)
    [[ -n "${MYSQL_PORT:-}"     ]] && args+=(-P "$MYSQL_PORT")
    [[ -n "${MYSQL_USER:-}"     ]] && args+=(-u "$MYSQL_USER")
    [[ -n "${MYSQL_EXTRA_ARGS:-}" ]] && args+=("$MYSQL_EXTRA_ARGS")
    args+=(--default-character-set="${MYSQL_CHARSET:-utf8}")
    args+=(--init-command="SET NAMES ${MYSQL_CHARSET:-utf8}")
    [[ -n "$db" ]] && args+=("$db")
    args+=(-B --skip-column-names --raw)
    printf '%s\n' "${args[@]}"
}

db_run_query() { # $1 = query-file, [$2 = database] -> query result on stdout
    local qfile="$1" db="${2:-}"
    [[ -f "$qfile" ]] || die "query file not found: $qfile"
    local -a argv
    mapfile -t argv < <(db_mysql_argv "$db")
    if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
        MYSQL_PWD="$MYSQL_PASSWORD" "${argv[@]}" < "$qfile"
    else
        "${argv[@]}" < "$qfile"
    fi
}

db_run_sql() { # $1 = sql-string, [$2 = database] -> result on stdout
    local sql="$1" db="${2:-}"
    local -a argv
    mapfile -t argv < <(db_mysql_argv "$db")
    if [[ -n "${MYSQL_PASSWORD:-}" ]]; then
        MYSQL_PWD="$MYSQL_PASSWORD" "${argv[@]}" -e "$sql"
    else
        "${argv[@]}" -e "$sql"
    fi
}

db_require_server() { # [$2 = database] -> dies unless 'SELECT 1' answers
    local db="${1:-}"
    local out
    out="$(db_run_sql 'SELECT 1;' "$db" 2>/dev/null)" || \
        die "cannot reach MariaDB (is the server running? see bin/backup_myprivatelib.sh)"
    [[ "$out" == *"1"* ]] || die "MariaDB answered unexpectedly: $out"
    return 0
}
