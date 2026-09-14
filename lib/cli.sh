#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# lib/cli.sh
#
# Common CLI conventions for the ebook-library-tools toolchain
# (Phase 3, plan §7.4).
#
# Version:       1.0.0
# Last updated:  2026-09-12
#
# Provides:
#   cli_print_version  - canonical '-v, --version' output line
#   cli_try_global     - shared parse of the global flags every tool accepts
#                        (-h/--help, -v/--version, --debug) before a tool's
#                        own case block handles tool-specific options
#   CLI_EXIT_OK / CLI_EXIT_FAIL / CLI_EXIT_USAGE - house exit-code contract
#                        (0 success / 1 operational failure / 2 usage error)
#
# Conventions documented for Phase 4 conversion (already house practice):
#   -h, --help     print usage, exit 0
#   -v, --version  print "<invocation> v<version>", exit 0
#   --debug        enable debug logging (DEBUG=1)
#   --dry-run      print what would happen, change nothing (where applicable)
#   -n             short form of --dry-run (where a tool supports it)
#
# Sourced by lib/common.sh; also safe to source directly.
# -----------------------------------------------------------------------------
# shellcheck shell=bash

[[ -n "${_ETL_CLI_SH:-}" ]] && return 0
_ETL_CLI_SH=1

# Exit-code contract (house style, already used by the DB and merge tools).
# ShellCheck flags these as "unused" because consumers read them in their own
# file after sourcing this one — that cross-file read is the point of the API.
# shellcheck disable=SC2034  # cross-file API: consumed by the sourcing tool
CLI_EXIT_OK=0
# shellcheck disable=SC2034  # cross-file API: consumed by the sourcing tool
CLI_EXIT_FAIL=1
# shellcheck disable=SC2034  # cross-file API: consumed by the sourcing tool
CLI_EXIT_USAGE=2
# shellcheck disable=SC2034  # set here, consumed by the sourcing tool
CLI_REMAINING_COUNT=0    # set by cli_try_global

# cli_print_version NAME VERSION
#   Prints the canonical line, e.g.:  bin/library_report.sh v1.2.0
#   NAME should be the repo-relative invocation path (tools pass "$0" today;
#   after the renames it becomes the bin/<group>/ path).
cli_print_version() { # $1 = name, $2 = version
    printf '%s v%s\n' "$1" "$2"
}

# cli_try_global [ARGS...]
#   Scans the leading global flags in ARGS; leaves positional/tool arguments
#   alone.  Recognized:
#     -h | --help    -> calls the caller's print_help, exit 0
#     -v | --version -> prints the version line, exit 0
#     --debug        -> DEBUG=1, continue scanning
#   Sets CLI_REMAINING_COUNT = number of arguments left after the global
#   flags (a global rather than stdout: safe under set -e in any context,
#   including command substitutions).  Returns 0.
cli_try_global() {
    local -a args=("$@")
    local i=0
    while (( i < ${#args[@]} )); do
        case "${args[i]}" in
            -h|--help)
                if declare -F print_help >/dev/null; then
                    print_help
                fi
                exit "$CLI_EXIT_OK"
                ;;
            -v|--version)
                # Prefixed tools (the flibusta family declares FB2_/PLACE_/RR_
                # constants so several stage libraries coexist inside one
                # orchestrator process) declare an ALIAS instead: SCRIPT_VERSION
                # stays the lib contract; the tool sets it to its prefixed
                # constant when that exists.  Bare declarations keep working.
                local _cli_ver="${SCRIPT_VERSION:-}"
                [[ -n "$_cli_ver" ]] || _cli_ver="${SCRIPT_VERSION_ALIAS:-0.0.0}"
                cli_print_version "${CLI_INVOCATION:-$0}" "$_cli_ver"
                exit "$CLI_EXIT_OK"
                ;;
            --debug)
                # shellcheck disable=SC2034  # read by lib/logging.sh at runtime
                DEBUG=1
                ;;
            *)
                break ;;    # first tool-specific flag: stop
        esac
        i=$(( i + 1 ))
    done
    # CLI_REMAINING_COUNT is the subshell-safe way for callers to learn how
    # many args cli_try_global left in "$@" (command substitutions lose globals,
    # so printing a count to stdout was not viable).
    # shellcheck disable=SC2034  # consumed by the sourcing tool
    CLI_REMAINING_COUNT=$(( ${#args[@]} - i ))
    return 0
}
