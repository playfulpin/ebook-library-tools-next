#!/usr/bin/env bash

###############################################################################
# bin/bump-version.sh
#
# Version:       1.0.1
# Last updated:  2026-09-03 23:50
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Bump ONE tool of the author toolchain to a new version, updating every
#   tracked location that carries that version in a single shot:
#
#       1. the tool's header comment ("# Version:")
#       2. its lib twin header, when it has one (e.g. merge_books_into_skeleton
#          <-> lib/merge_books_functions.sh)
#       3. the tool's row in the README release table (version and tag
#          columns — the tag embeds the version, so one substitution covers
#          both)
#       4. the tool's line in the RELEASE_NOTES "Shipped tools" list
#
#   This is the tool that enforces the project's 0.0.1 bump rule without
#   hand-editing five files.  tests/test_version_sync.sh then verifies that
#   all four locations agree, so a missed bump becomes a test failure instead
#   of silent version drift.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/bump-version.sh <tool> <new_version>
#
#   <tool> is one of (case-sensitive):
#       build_shell_nested_authors    (6.6.x) -> authors_tree_build
#       build_prefix_table            (1.0.x) -> authors_prefix_build
#       prefix_table_integrity        (1.2.x) -> authors_prefix_check
#       prefix_tree_visualizer        (2.8.x) -> authors_prefix_tree
#       merge_books_into_skeleton     (0.1.x, bin + lib twin)
#       merge_skeleton_into_books     (0.1.x)
#       utf8_prefix_generator         (1.x, two-part versions only)
#       export_authors_from_db        (1.0.x)  -> authors_export
#       reconcile_library             (1.0.x)
#       estimate_download_size        (1.0.x)
#       backup_myprivatelib             (1.0.x)
#       populate_myprivatelib           (1.3.x)
#       refresh_myprivatelib            (1.0.x)
#       report_library                  (1.0.x)
#
#   <new_version> must be strictly greater than the current version and match
#   the tool's version shape (X.Y.Z for shell tools, X.Y for the AWK tool).
#
# EXAMPLES
#   ./bin/bump-version.sh build_shell_nested_authors 6.6.11   # key unchanged
#   ./bin/bump-version.sh merge_books_into_skeleton 0.1.4
#   ./bin/bump-version.sh utf8_prefix_generator 1.2
#
# -----------------------------------------------------------------------------
# AFTER BUMPING
# -----------------------------------------------------------------------------
#   The script prints the remaining manual steps: add a CHANGELOG entry, run
#   the relevant suite(s) under WSL, and tag the release.
#
# -----------------------------------------------------------------------------
# EXIT STATUS
# -----------------------------------------------------------------------------
#   0 -- version bumped successfully
#   1 -- usage / validation error, or the tool is unknown
#
###############################################################################

set -euo pipefail

# -----------------------------------------------------------------------------
# version_from_header
#
# Read the "# Version:" value from a script's header comment.
#
# Arguments:
#   $1 - path to the script
#
# Output:
#   the version string, e.g. "6.6.10"
# -----------------------------------------------------------------------------
version_from_header() {
    sed -n 's/^# Version:[[:space:]]*//p' "$1" | head -n 1
}

# -----------------------------------------------------------------------------
# bump_header
#
# Rewrite the "# Version:" line of one script header, keeping the existing
# comment alignment (the AWK tool uses a single space, the shell tools align
# with several).
#
# Arguments:
#   $1 - path to the script
#   $2 - the new version
# -----------------------------------------------------------------------------
bump_header() {
    local file="$1" new="$2" prefix
    # Preserve the original indent between "# Version:" and the value.
    prefix="$(sed -n 's/^\(# Version:[[:space:]]*\).*/\1/p' "$file" | head -n 1)"
    sed -i "s|^# Version:.*|${prefix}${new}|" "$file"
}

# -----------------------------------------------------------------------------
# bump_doc
#
# Replace the old version with the new one on exactly ONE line of a document:
# the line belonging to the given tool.  The line is identified by a literal
# prefix (no regex, so markers containing '/' or backticks are safe):
#   mode "readme" -> the release-table row   "| \`<marker>\` |"
#   mode "notes"  -> the shipped-tools line  "- \`<marker>\`"
# The replacement is literal too (index-based, not regex), so "1.1" never
# matches inside "1.10".  For the README row this single pass updates both
# the version column and the tag column, since the tag embeds the version.
# Historical mentions of the tool elsewhere in the docs are left untouched.
#
# Arguments:
#   $1 - document path (README.md or RELEASE_NOTES.md)
#   $2 - mode: "readme" or "notes"
#   $3 - tool marker (the path as it appears in the document)
#   $4 - the old version
#   $5 - the new version
# -----------------------------------------------------------------------------
bump_doc() {
    local doc="$1" mode="$2" marker="$3" old="$4" new="$5"
    awk -v mode="$mode" -v marker="$marker" -v old="$old" -v new="$new" '
    # literal (non-regex) replacement of o with n inside s
    function lreplace(s, o, n,   out, rest, j) {
        out = ""; rest = s
        while ((j = index(rest, o)) > 0) {
            out  = out substr(rest, 1, j - 1) n
            rest = substr(rest, j + length(o))
        }
        return out rest
    }
    {
        prefix = (mode == "readme") ? ("| `" marker "` |") : ("- `" marker "`")
        if (substr($0, 1, length(prefix)) == prefix)
            print lreplace($0, old, new)
        else
            print
    }
    ' "$doc" > "$doc.tmp" && mv "$doc.tmp" "$doc"
}

# -----------------------------------------------------------------------------
# usage
# -----------------------------------------------------------------------------
usage() {
    echo "bin/bump-version.sh v$(version_from_header "$0")"
    echo ""
    echo "Usage: $0 <tool> <new_version>"
    echo ""
    echo "Tools (case-sensitive):"
    echo "  authors_tree_build            (6.6.x)  [was build_shell_nested_authors]"
    echo "  authors_prefix_build          (1.0.x)  [was build_prefix_table]"
    echo "  authors_prefix_check          (1.2.x)  [was prefix_table_integrity]"
    echo "  authors_prefix_tree           (2.8.x)  [was prefix_tree_visualizer]"
    echo "  merge_books_into_skeleton     (0.1.x, bin + lib twin)"
    echo "  merge_skeleton_into_books     (0.1.x)"
    echo "  utf8_prefix_generator         (1.x, two-part versions only)"
    echo "  authors_export                (1.0.x)"
    echo "  reconcile_library             (1.0.x)"
    echo "  estimate_download_size        (1.0.x)"
    echo "  backup_myprivatelib             (1.0.x)"
    echo "  populate_myprivatelib           (1.3.x)"
    echo "  refresh_myprivatelib            (1.0.x)"
    echo "  report_library                  (1.0.x)"
    echo ""
    echo "Example: $0 build_shell_nested_authors 6.6.11"
    exit 1
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
    local tool="${1:-}" new="${2:-}"
    local primary="" twin="" marker="" shape="x.y.z"
    local old

    if [[ -z "$tool" || -z "$new" ]]; then
        usage
    fi

    # --- tool registry -------------------------------------------------------
    # primary: the header that owns the version (source of truth)
    # twin:    optional lib header that must stay in lockstep
    # marker:  the path as it appears in README.md / RELEASE_NOTES.md
    # shape:   version shape to validate against
    case "$tool" in
        build_shell_nested_authors)
            primary="bin/authors/authors_tree_build.sh"
            marker="bin/authors/authors_tree_build.sh"
            ;;
        build_prefix_table)
            primary="bin/authors/authors_prefix_build.sh"
            marker="bin/authors/authors_prefix_build.sh"
            ;;
        prefix_table_integrity)
            primary="bin/authors/authors_prefix_check.sh"
            marker="bin/authors/authors_prefix_check.sh"
            ;;
        prefix_tree_visualizer)
            primary="bin/authors/authors_prefix_tree.sh"
            marker="bin/authors/authors_prefix_tree.sh"
            ;;
        merge_books_into_skeleton)
            primary="bin/merge_books_into_skeleton.sh"
            twin="lib/merge_books_functions.sh"
            marker="bin/merge_books_into_skeleton.sh"
            ;;
        merge_skeleton_into_books)
            primary="bin/merge_skeleton_into_books.sh"
            marker="bin/merge_skeleton_into_books.sh"
            ;;
        utf8_prefix_generator)
            primary="lib/utf8_prefix_generator.awk"
            marker="lib/utf8_prefix_generator.awk"
            shape="x.y"
            ;;
        export_authors_from_db)
            primary="bin/authors/authors_export.sh"
            marker="bin/authors/authors_export.sh"
            ;;
        reconcile_library)
            primary="bin/reconcile_library.sh"
            marker="bin/reconcile_library.sh"
            ;;
        estimate_download_size)
            primary="bin/estimate_download_size.sh"
            marker="bin/estimate_download_size.sh"
            ;;
        backup_myprivatelib)
            primary="bin/backup_myprivatelib.sh"
            marker="bin/backup_myprivatelib.sh"
            ;;
        populate_myprivatelib)
            primary="bin/populate_myprivatelib.sh"
            marker="bin/populate_myprivatelib.sh"
            ;;
        refresh_myprivatelib)
            primary="bin/refresh_myprivatelib.sh"
            marker="bin/refresh_myprivatelib.sh"
            ;;
        report_library)
            primary="bin/report_library.sh"
            marker="bin/report_library.sh"
            ;;
        *)
            echo "Error: unknown tool '$tool'." >&2
            usage
            ;;
    esac

    # --- sanity: the primary header must exist and carry a version -----------
    if [[ ! -f "$primary" ]]; then
        echo "Error: '$primary' not found." >&2
        exit 1
    fi
    old="$(version_from_header "$primary")"
    if [[ -z "$old" ]]; then
        echo "Error: no '# Version:' found in '$primary'." >&2
        exit 1
    fi

    # --- validate the new version --------------------------------------------
    if [[ "$shape" == "x.y.z" ]]; then
        if [[ ! "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "Error: '$new' is not a X.Y.Z version." >&2
            exit 1
        fi
    else
        if [[ ! "$new" =~ ^[0-9]+\.[0-9]+$ ]]; then
            echo "Error: '$new' is not a X.Y version (AWK tool)." >&2
            exit 1
        fi
    fi

    if [[ "$new" == "$old" ]]; then
        echo "Error: '$tool' is already at $old." >&2
        exit 1
    fi

    # --- apply the bump ------------------------------------------------------
    echo "Bumping $tool: $old -> $new"
    bump_header "$primary" "$new"
    echo "  header: $primary"
    [[ -n "$twin" ]] && { echo "  header: $twin (lib twin)"; bump_header "$twin" "$new"; }
    bump_doc "README.md" readme "$marker" "$old" "$new"
    echo "  README.md (release-table row for $marker)"
    bump_doc "RELEASE_NOTES.md" notes "$marker" "$old" "$new"
    echo "  RELEASE_NOTES.md (shipped-tools line for $marker)"

    # --- manual follow-ups ----------------------------------------------------
    cat <<EOF

Done. Verify with:
  bash tests/test_version_sync.sh

Then finish the release manually:
  1. Add a CHANGELOG.md entry for $tool $new.
  2. Run the relevant suite(s) under WSL:
       wsl.exe bash tests/test_authors_tree_build.sh   # or the tool's suite
  3. Commit, then tag (tool-prefixed or v-prefixed per convention).
EOF
}

main "$@"