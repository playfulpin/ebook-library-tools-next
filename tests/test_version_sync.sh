#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# tests/test_version_sync.sh
#
# Version-sync regression suite for the author toolchain.
#
# Every tool carries its version in up to four places, and they must agree:
#   1. the tool's "# Version:" header comment (source of truth)
#   2. its lib twin header, when it has one (merge_books_into_skeleton
#      <-> lib/merge_books_functions.sh)
#   3. its row in the README release table (both the version column and the
#      tag column, which embeds the version)
#   4. its line in the RELEASE_NOTES "Shipped tools" list
#
# This suite exists because hand-editing five files drifts: the merge tools
# shipped with docs at 0.1.1 while the header said 0.1.2, and the lib twin
# was once forgotten entirely.  bin/bump-version.sh edits all locations in
# one shot; this suite is the safety net that proves it (or catches a manual
# bump that missed a file).
#
# Usage:
#   bash tests/test_version_sync.sh          # check all tools  (runs anywhere)
#
# Pure text processing (grep/sed + a per-tool awk to fetch versions from the
# README), so no multibyte bash or WSL is required.
# -----------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- tool registry ------------------------------------------------------------
# primary: header file that owns the version (relative to repo root)
# twin:    optional lib header that must match the primary
# marker:  the path string that identifies the tool's row/line in the docs
#          (matches README.md table rows and RELEASE_NOTES shipped lines)
# The registry mirrors bin/bump-version.sh; keep them in lockstep.
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

# --- helpers ------------------------------------------------------------------
header_version() { # file
    sed -n 's/^# Version:[[:space:]]*//p' "$REPO_ROOT/$1" | head -n 1
}

# README table row version: the row "| \`bin/tool.sh\` | 1.2.3 | \`tag\` |"
# -> awk picks the second |-separated field.
readme_row_version() { # marker
    grep -E "^\| \`$1\` \|" "$REPO_ROOT/README.md" \
        | head -n 1 \
        | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3}'
}

# README table row tag: the third |-separated field.
readme_row_tag() { # marker
    grep -E "^\| \`$1\` \|" "$REPO_ROOT/README.md" \
        | head -n 1 \
        | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $4); print $4}'
}

# RELEASE_NOTES shipped line version: "**1.2.3**" inside the tool's line.
releasenotes_version() { # marker
    grep -E "^- \`$1\`" "$REPO_ROOT/RELEASE_NOTES.md" \
        | head -n 1 \
        | sed -n 's/.*\*\*\([0-9][0-9.]*\)\*\*.*/\1/p'
}

check_tool() { # tool  primary  [twin]  marker
    local tool="$1" primary="$2" twin="${3:-}" marker="$4"
    local hv rv rtag nv tvinfo=""

    hv="$(header_version "$primary")"
    if [[ -z "$hv" ]]; then
        report "version_$tool" fail "no '# Version:' in $primary"
        return
    fi

    # lib twin (if any)
    if [[ -n "$twin" ]]; then
        local tv
        tv="$(header_version "$twin")"
        if [[ "$tv" != "$hv" ]]; then
            report "version_$tool" fail "header $hv != lib twin $twin ($tv)"
            return
        fi
        tvinfo="+twin $tv"
    fi

    # README row (version column and tag column)
    rv="$(readme_row_version "$marker")"
    rtag="$(readme_row_tag "$marker")"
    if [[ "$rv" != "$hv" ]]; then
        report "version_$tool" fail "header $hv != README row version $rv"
        return
    fi
    if [[ "$rtag" != *"$hv"* ]]; then
        report "version_$tool" fail "header $hv not embedded in README tag '$rtag'"
        return
    fi

    # RELEASE_NOTES shipped line
    nv="$(releasenotes_version "$marker")"
    if [[ "$nv" != "$hv" ]]; then
        report "version_$tool" fail "header $hv != RELEASE_NOTES version $nv"
        return
    fi

    report "version_$tool" ok "header $hv $tvinfo = README ($rv / $rtag) = notes $nv"
}

# -----------------------------------------------------------------------------
# run the checks
# -----------------------------------------------------------------------------
echo "== version sync =="

check_tool build_shell_nested_authors \
    "bin/build_shell_nested_authors.sh" "" "bin/build_shell_nested_authors.sh"

check_tool build_prefix_table \
    "bin/build_prefix_table.sh" "" "bin/build_prefix_table.sh"

check_tool prefix_table_integrity \
    "bin/prefix_table_integrity.sh" "" "bin/prefix_table_integrity.sh"

check_tool prefix_tree_visualizer \
    "bin/prefix_tree_visualizer.sh" "" "bin/prefix_tree_visualizer.sh"

check_tool merge_books_into_skeleton \
    "bin/merge_books_into_skeleton.sh" "lib/merge_books_functions.sh" \
    "bin/merge_books_into_skeleton.sh"

check_tool merge_skeleton_into_books \
    "bin/merge_skeleton_into_books.sh" "" "bin/merge_skeleton_into_books.sh"

check_tool utf8_prefix_generator \
    "lib/utf8_prefix_generator.awk" "" "lib/utf8_prefix_generator.awk"

check_tool export_authors_from_db \
    "bin/export_authors_from_db.sh" "" "bin/export_authors_from_db.sh"

check_tool reconcile_library \
    "bin/reconcile_library.sh" "" "bin/reconcile_library.sh"

check_tool estimate_download_size \
    "bin/estimate_download_size.sh" "" "bin/estimate_download_size.sh"

check_tool backup_myprivatelib \
    "bin/backup_myprivatelib.sh" "" "bin/backup_myprivatelib.sh"

check_tool populate_myprivatelib \
    "bin/populate_myprivatelib.sh" "" "bin/populate_myprivatelib.sh"

# --- summary --------------------------------------------------------------------
echo
echo "=============================="
echo "PASS: $PASS_COUNT   FAIL: $FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then
    printf '  - %s\n' "${FAILURE_LINES[@]}"
    exit 1
fi
echo "All versions in sync."
exit 0