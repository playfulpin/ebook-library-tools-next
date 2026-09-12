#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# lib/common.sh
#
# Common initialization and helpers for the ebook-library-tools toolchain.
#
# Version:       1.0.0
# Last updated:  2026-09-12
#
# Provides (Phase 3 of the refactoring plan, Updated Plan §7.1–7.2):
#   common_init        - standard initialization: set -Eeuo pipefail, project
#                        root detection at ANY bin/ depth (bin/x.sh today,
#                        bin/<group>/x.sh after the Phase 4 renames), and
#                        sourcing of the sibling libraries.
#   die                - log "error: ..." and exit 1
#   require_command    - die unless a command is on PATH
#   timestamp_now      - canonical 'YYYY-MM-DD HH:MM:SS' stamp
#
# Seeded from the byte-identical code found in 8+ tools by the Phase 1
# inventory (§11.1); no new behavior is invented here.
#
# Usage from a bin/ script:
#
#     source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"   # bin/ today
#     source "$PROJECT_ROOT/lib/common.sh"                        # after renames
#     common_init "$@"
#
# common_init sets:  SCRIPT_DIR, PROJECT_ROOT, DEBUG (0/1)
# and sources:       lib/logging.sh, lib/cli.sh, lib/filesystem.sh
#                    (lib/database.sh and lib/mariadb_lifecycle.sh stay
#                     opt-in — only DB tools pay for them).
#
# NOTE: common_init sets `set -Eeuo pipefail`.  Known compatibility
# exception, documented per plan §7.1: bin/library/library_report.sh runs under
# `set -uo pipefail` (no -e) because its view pipeline relies on
# non-zero command substitutions; when that tool converts (Phase 4) it
# must call `common_init --no-errexit` or keep its own mode explicitly.
# -----------------------------------------------------------------------------
# shellcheck shell=bash

# Idempotent: a tool that sources common.sh twice must not double-define.
[[ -n "${_ETL_COMMON_SH:-}" ]] && return 0
_ETL_COMMON_SH=1

# --- 1. standard initialization (plan §7.1) -----------------------------------
# set -E (ERR trap inheritable) + -e + -u + -o pipefail.
# Documented exception (plan §7.1): a tool that must run WITHOUT -e (today
# only bin/library/library_report.sh, `set -uo pipefail`) calls `common_init
# --no-errexit` immediately after sourcing — never silently.
set -Eeuo pipefail

# --- 2. script location handling (plan §7.2) -----------------------------------
# Works from any directory and any bin/ depth: resolves symlinks, never
# depends on $PWD, never depends on $0.
_etl_resolve_source() { # $1 = ${BASH_SOURCE[1]} from the caller's frame
    local src="$1"
    while [[ -L "$src" ]]; do
        local dir
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ $src == /* ]] || src="$dir/$src"
    done
    printf '%s\n' "$(cd -P "$(dirname "$src")" && pwd)"
}
SCRIPT_DIR="$(_etl_resolve_source "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")"

# Climb until we find the project root (marked by lib/common.sh itself).
# Today: bin/x.sh        -> 1 level up
# After renames: bin/<group>/x.sh -> 2 levels up.  Both just work.
PROJECT_ROOT="${_ETL_PROJECT_ROOT:-}"
if [[ -z "$PROJECT_ROOT" ]]; then
    PROJECT_ROOT="$SCRIPT_DIR"
    _etl_guard=0
    while (( _etl_guard < 6 )) && [[ ! -f "$PROJECT_ROOT/lib/common.sh" ]]; do
        PROJECT_ROOT="$(dirname "$PROJECT_ROOT")"
        _etl_guard=$(( _etl_guard + 1 ))
    done
    if [[ ! -f "$PROJECT_ROOT/lib/common.sh" ]]; then
        printf 'error: cannot locate project root (no lib/common.sh above %s)\n' \
            "$SCRIPT_DIR" >&2
        exit 1
    fi
    export PROJECT_ROOT
fi

# --- 3. sibling libraries (sourced once, guarded by their own sentinels) ------
# shellcheck source=logging.sh
source "$PROJECT_ROOT/lib/logging.sh"
# shellcheck source=cli.sh
source "$PROJECT_ROOT/lib/cli.sh"
# shellcheck source=filesystem.sh
source "$PROJECT_ROOT/lib/filesystem.sh"

# --- 4. shared helpers ---------------------------------------------------------
# die: exactly the house behavior (log "error: ...", exit 1) found in 8 tools.
die() { log "error: $*"; exit 1; }

# require_command: fail fast with a clear message when a dependency is missing.
require_command() { # $1 = command name, [$2 = hint]
    local cmd="$1" hint="${2:-}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "required command '$cmd' not found on PATH${hint:+ ($hint)}"
    fi
}

# timestamp_now: the canonical stamp format used by log() and report rows.
timestamp_now() { date '+%Y-%m-%d %H:%M:%S'; }

# --- 5. common_init: one call for bin/ scripts ---------------------------------
#   common_init [--no-errexit] [--debug]
#     --no-errexit   run under `set -uo pipefail` (documented exception mode)
#     --debug        force DEBUG=1 regardless of the environment
# Sets DEBUG from --debug / ETL_DEBUG / DEBUG env, default 0.
common_init() {
    local no_errexit=0
    while (( $# )); do
        case "$1" in
            --no-errexit) no_errexit=1 ;;
            --debug)      DEBUG=1 ;;
            *) break ;;            # stop at the first non-init argument
        esac
        shift
    done
    if (( no_errexit )); then
        set +e                     # documented exception (see header note):
        set +E                     # explicitly REMOVE -e/-E, then fix -u/-o
        set -uo pipefail
    fi
    DEBUG="${DEBUG:-${ETL_DEBUG:-0}}"
    [[ "$DEBUG" == "1" || "$DEBUG" == "true" ]] && DEBUG=1 || DEBUG=0
    export DEBUG
    return 0
}
