#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# lib/logging.sh
#
# Common logging for the ebook-library-tools toolchain (Phase 3, plan §7.3).
#
# Version:       1.0.0
# Last updated:  2026-09-07
#
# Provides the exact house triplet found byte-identical in 8 tools by the
# Phase 1 inventory, plus an explicit level API on top of it:
#
#   log            - printf '[<ts>] <msg>' to stderr   (house primitive)
#   debug          - log "debug: ..." when DEBUG=1
#   log_debug      - alias of debug (explicit-level naming)
#   log_info       - log "info : ..." (level-tagged form, optional)
#   log_warn       - log "warn : ..."
#   log_error      - log "error: ..."
#
# Nothing here writes to stdout; tool output on stdout stays clean for
# piping.  Log-file handling is deliberately NOT centralized yet: no tool
# writes a log file today, and inventing one now would be speculative
# (plan principle: seed from real code only).
#
# Sourced by lib/common.sh; also safe to source directly.
# -----------------------------------------------------------------------------
# shellcheck shell=bash

[[ -n "${_ETL_LOGGING_SH:-}" ]] && return 0
_ETL_LOGGING_SH=1

# The house primitive (unchanged from the 8 identical definitions).
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# DEBUG guard: tools set DEBUG via common_init (or their own logic);
# this library deliberately does NOT assign DEBUG (an assignment here would
# defeat common_init's env fallback chain), it only reads it defensively.
# debug() { if [[ "${DEBUG:-0}" == 1 ]]; then log "debug: $*"; fi; }

debug()     { if [[ "${DEBUG:-0}" == 1 ]]; then log "debug: $*"; fi; }
# log_debug/log_warn/log_error: explicit-level aliases over the same
# primitives — converted tools may choose tagged levels without breaking
# the house format.  log_debug delegates to debug() so DEBUG gating stays
# in exactly one place.
log_debug() { debug "$@"; }

# Explicit-level helpers — new convenience wrappers over the same primitive,
# so converted tools can choose tagged levels without breaking the format.
log_info()  { log "info : $*"; }
log_warn()  { log "warn : $*"; }
# log_error: same output as die()'s message line, but returns normally —
# for callers that log the failure and then decide their own exit path.
log_error() { log "error: $*"; }
