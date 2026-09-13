#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# lib/database.sh
#
# Thin MySQL client helpers for the ebook-library-tools toolchain
# (Phase 3, plan §7 + Blueprint §22; Follow-It §8 canonical contract).
#
# Version:       1.2.0
# Last updated:  2026-09-13
#
# Provides (seeded verbatim from the argv block repeated in
# books_reconcile.sh / library_report.sh / authors_export.sh):
#   db_mysql_argv      - assemble the shared mysql argv from MYSQL_* env
#   db_mysqldump_argv  - assemble the mysqldump argv (library_backup)
#   db_run_query       - execute a query file, stdout only
#   db_run_sql         - execute an inline SQL string, stdout only
#   db_require_server  - probe 'SELECT 1' (start/readiness gate used by ingest)
#
# NOT here (Blueprint §22/§23): server start/stop/upgrade.  That stays in
# lib/mariadb_lifecycle.sh, which this library deliberately does not source —
# tools source both and compose them.
#
# Canonical argv contract (v1.1.0, Follow-It §8 — the shape the five DB
# tools already emit, adopted verbatim so migration is byte-identical):
#   mysql [-h HOST --protocol=TCP] [-P PORT] [-u USER] [MYSQL_EXTRA_ARGS...]
#         --init-command="SET NAMES <charset>" [DB] -B --skip-column-names --raw
#
#   Charset resolution: the session charset comes from
#   MYSQL_EXTRA_ARGS --default-character-set=<c> when present (the server
#   may ignore the handshake charset — e.g. configured with
#   skip-character-set-client-handshake — and transcode results to its
#   own default such as cp1251, corrupting UTF-8 payloads; --init-command
#   is always applied by the server), falling back to MYSQL_CHARSET,
#   then utf8.  This is why the flag is init-command-only.
#
#   Password handling: MYSQL_PASSWORD is NEVER placed on the argv; callers
#   (db_run_query/db_run_sql and the tools) pass it via the MYSQL_PWD
#   environment variable per invocation.
#
#   Connect timeout: --connect-timeout is NOT emitted by default (the
#   tools that need the WSL2 hung-connect guard add it themselves —
#   currently library_populate and library_backup; it is mysql-only and
#   its mysqldump sibling does not accept the flag).
#
#   mysqldump (db_mysqldump_argv, v1.2.0): same host/port/user/EXTRA_ARGS
#   handling, but NO batch flags (-B/--skip-column-names/--raw), NO
#   --init-command and NO --connect-timeout — mysqldump rejects them; the
#   dump call is bounded with `timeout` by the caller instead.  Database
#   name is appended last (mysqldump takes it positionally).
#
# Environment consumed (all optional):
#   MYSQL_CLIENT (default mysql), MYSQL_HOST, MYSQL_PORT, MYSQL_USER,
#   MYSQL_PASSWORD (passed via MYSQL_PWD), MYSQL_DATABASE, MYSQL_EXTRA_ARGS,
#   MYSQL_CHARSET (fallback for the session charset; default utf8)
# -----------------------------------------------------------------------------
# shellcheck shell=bash

[[ -n "${_ETL_DATABASE_SH:-}" ]] && return 0
_ETL_DATABASE_SH=1

# shellcheck source=mariadb_lifecycle.sh
[[ -n "${_ETL_MARIADB_LIFECYCLE_SH:-}" ]] || true   # compose, don't force

# db_session_charset -> the effective session charset on stdout.
# Resolution order: MYSQL_EXTRA_ARGS --default-character-set=<c>
# (highest — the operator's explicit client flag), then MYSQL_CHARSET,
# then utf8.
db_session_charset() {
    local charset="${MYSQL_CHARSET:-utf8}"
    case " ${MYSQL_EXTRA_ARGS:-} " in
        *" --default-character-set="*)
            charset="${MYSQL_EXTRA_ARGS##*--default-character-set=}"
            charset="${charset%% *}"
            ;;
    esac
    printf '%s' "$charset"
}

db_mysql_argv() { # [$1 = database] -> argv on stdout (space-safe: array)
    # Callers pass "" explicitly to omit the DB (they append it per-call);
    # an omitted argument falls back to MYSQL_DATABASE.
    local db="${MYSQL_DATABASE:-}"
    (( $# )) && db="$1"
    local charset
    charset="$(db_session_charset)"
    local args=("${MYSQL_CLIENT:-mysql}")
    [[ -n "${MYSQL_HOST:-}"     ]] && args+=(-h "$MYSQL_HOST" --protocol=TCP)
    [[ -n "${MYSQL_PORT:-}"     ]] && args+=(-P "$MYSQL_PORT")
    [[ -n "${MYSQL_USER:-}"     ]] && args+=(-u "$MYSQL_USER")
    [[ -n "${MYSQL_EXTRA_ARGS:-}" ]] && args+=("$MYSQL_EXTRA_ARGS")
    args+=(--init-command="SET NAMES $charset")
    [[ -n "$db" ]] && args+=("$db")
    args+=(-B --skip-column-names --raw)
    printf '%s\n' "${args[@]}"
}

db_mysqldump_argv() { # [$1 = database] -> argv on stdout (space-safe: array)
    # Callers pass "" explicitly to omit the DB (it is appended positionally
    # by the caller, e.g. before the dump file argument); "" is distinct from
    # an omitted argument, which falls back to MYSQL_DATABASE.
    local db="${MYSQL_DATABASE:-}"
    (( $# )) && db="$1"
    local args=("${MYSQLDUMP_CLIENT:-mysqldump}")
    [[ -n "${MYSQL_HOST:-}"     ]] && args+=(-h "$MYSQL_HOST" --protocol=TCP)
    [[ -n "${MYSQL_PORT:-}"     ]] && args+=(-P "$MYSQL_PORT")
    [[ -n "${MYSQL_USER:-}"     ]] && args+=(-u "$MYSQL_USER")
    [[ -n "${MYSQL_EXTRA_ARGS:-}" ]] && args+=("$MYSQL_EXTRA_ARGS")
    [[ -n "$db" ]] && args+=("$db")
    printf '%s\n' "${args[@]}"
}

db_run_query() { # $1 = query-file, [$2 = database] -> query result on stdout
    local qfile="$1" db="${2:-${MYSQL_DATABASE:-}}"
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
    local sql="$1" db="${2:-${MYSQL_DATABASE:-}}"
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
        die "cannot reach MariaDB (is the server running? check the MYSQL_* connection settings)"
    [[ "$out" == *"1"* ]] || die "MariaDB answered unexpectedly: $out"
    return 0
}
