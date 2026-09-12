#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# lib/filesystem.sh
#
# Shared filesystem operations for the ebook-library-tools toolchain
# (Phase 3, plan §7 + Blueprint §18).
#
# Version:       1.0.0
# Last updated:  2026-09-07
#
# Provides (each seeded from one real implementation — noted per function):
#   fs_require_dir      - die unless a directory exists
#   fs_require_file     - die unless a file exists
#   fs_mktmp            - safe mktemp dir with house naming + trap cleanup
#   fs_tree_fingerprint - Books-tree fingerprint (rel path, size, mtime),
#                         byte-stable; verbatim from bin/refresh_myprivatelib.sh
#   fs_prune_empty_dirs - the house prune one-liner with dry-run support;
#                         verbatim from bin/merge_skeleton_into_books.sh
#
# Archive/merge-specific logic stays in lib/merge_books_functions.sh and the
# future lib/books.sh (Blueprint §18: "Keep archive-specific logic in
# books.sh").
#
# Sourced by lib/common.sh; also safe to source directly.
# -----------------------------------------------------------------------------
# shellcheck shell=bash

[[ -n "${_ETL_FILESYSTEM_SH:-}" ]] && return 0
_ETL_FILESYSTEM_SH=1

# --- existence guards ----------------------------------------------------------
fs_require_dir() {  # $1 = path, [$2 = what it is (for the error message)]
    local path="$1" what="${2:-directory}"
    [[ -d "$path" ]] || die "$what not found: $path"
}
# shellcheck disable=SC2120
fs_require_file() { # $1 = path, [$2 = what it is]
    local path="$1" what="${2:-file}"
    [[ -f "$path" ]] || die "$what not found: $path"
}

# --- safe temporary directory ---------------------------------------------------
# fs_mktmp PREFIX  -> prints the created directory path.
# The caller (or fs_cleanup_register) owns removal; typical use:
#     tmp="$(fs_mktmp reconcile)"
#     trap 'rm -rf "$tmp"' EXIT          # house trap pattern (7 tools)
fs_mktmp() { # $1 = prefix
    local prefix="${1:-etl}"
    mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX"
}

# --- tree fingerprint (verbatim from refresh_myprivatelib.sh v1.0.0) -----------
# Why not a root-only stat: mtimes of parent directories do not reliably
# propagate on the Windows/9P mount when files are added to subfolders.
# LC_ALL=C keeps the sort byte-stable so identical trees produce
# byte-identical fingerprints.
fs_tree_fingerprint() { # $1 = root -> one TSV line per file on stdout
    local root="$1"
    ( cd "$root" && find . -type f ! -name '.*' \
        -printf '%P\t%s\t%T@\n' | LC_ALL=C sort )
}

# --- empty-dir prune (verbatim policy from merge_skeleton_into_books.sh) -------
# fs_prune_empty_dirs ROOT [dry-run-flag]
#   Removes empty directories under ROOT (depth-first, root itself kept).
#   With DRY_RUN=true (or any second arg), only counts and prints what
#   would be removed; returns the removed/would-remove count on stdout.
fs_prune_empty_dirs() { # $1 = root, [$2 = dry-run true/false]
    local root="$1" dry="${2:-${DRY_RUN:-false}}"
    local empties
    if [[ "$dry" == true ]]; then
        empties="$(find "$root" -depth -mindepth 1 -type d -empty -print | wc -l | tr -d ' ')"
        echo "prune (dry run): $empties empty director(ies) would be removed from '$root'"
    else
        empties="$(find "$root" -depth -mindepth 1 -type d -empty -print -delete | wc -l | tr -d ' ')"
        echo "prune: removed $empties empty director(ies) from '$root'"
    fi
    printf '%s' "$empties"
}
