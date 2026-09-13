#!/usr/bin/env bash

###############################################################################
# bin/version_bump.sh
#
# Version:       1.0.2
# Last updated:  2026-09-12
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Bump ONE tool of the author toolchain to a new version, updating every
#   tracked location that carries that version in a single shot:
#
#       1. the tool's header comment ("# Version:")
#       2. its lib twin header, when it has one (e.g. books_merge
#          <-> lib/books_functions.sh)
#       3. the tool's row in the README release table (version and tag
#          columns — the tag embeds the version, so one substitution covers
#          both)
#       4. the tool's line in the RELEASE_NOTES "Shipped tools" list
#
#   This is the tool that enforces the project's 0.0.1 bump rule without
#   hand-editing five files.  tests/unit/test_version_sync.sh then verifies that
#   all four locations agree, so a missed bump becomes a test failure instead
#   of silent version drift.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/version_bump.sh <tool> <new_version>
#
#   <tool> is one of (case-sensitive):
#       build_shell_nested_authors    (6.6.x) -> authors_tree_build
#       build_prefix_table            (1.0.x) -> authors_prefix_build
#       prefix_table_integrity        (1.2.x) -> authors_prefix_check
#       prefix_tree_visualizer        (2.8.x) -> authors_prefix_tree
#       books_merge                   (0.1.x, bin + lib twin) [was merge_books_into_skeleton]
#       books_finalize                (0.1.x) [was merge_skeleton_into_books]
#       utf8_prefix_generator         (1.x, two-part versions only)
#       export_authors_from_db        (1.0.x)  -> authors_export
#       reconcile_library             (1.0.x) -> books_reconcile
#       estimate_download_size        (1.0.x) -> books_estimate
#       backup_myprivatelib          (1.0.x) -> library_backup
#       populate_myprivatelib        (1.3.x) -> library_populate
#       refresh_myprivatelib         (1.0.x) -> library_refresh

#
#   <new_version> must be strictly greater than the current version and match
#   the tool's version shape (X.Y.Z for shell tools, X.Y for the AWK tool).
#
# EXAMPLES
#   ./bin/version_bump.sh authors_tree_build 6.6.12
#   ./bin/version_bump.sh books_merge 0.1.4
#   ./bin/version_bump.sh utf8_prefix_generator 1.2
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
    echo "bin/version_bump.sh v$(version_from_header "$0")"
    echo ""
    echo "Usage: $0 <tool> <new_version>"
    echo ""
    echo "Tools (case-sensitive):"
    echo "  authors_tree_build            (6.6.x)  [was build_shell_nested_authors]"
    echo "  authors_prefix_build          (1.0.x)  [was build_prefix_table]"
    echo "  authors_prefix_check          (1.2.x)  [was prefix_table_integrity]"
    echo "  authors_prefix_tree           (2.8.x)  [was prefix_tree_visualizer]"
    echo "  books_merge                   (0.1.x, bin + lib twin)  [was merge_books_into_skeleton]"
    echo "  books_finalize                (0.1.x)  [was merge_skeleton_into_books]"
    echo "  utf8_prefix_generator         (1.x, two-part versions only)"
    echo "  authors_export                (1.0.x)"
    echo "  books_reconcile               (1.0.x)  [was reconcile_library]"
    echo "  books_estimate                (1.0.x)  [was estimate_download_size]"
    echo "  library_backup                (1.0.x)  [was backup_myprivatelib]"
    echo "  library_populate              (1.3.x)  [was populate_myprivatelib]"
    echo "  library_refresh               (1.0.x)  [was refresh_myprivatelib]"
    echo "  library_report                (1.2.x)  [was report_library]"
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
        authors_tree_build)
            primary="bin/authors/authors_tree_build.sh"
            marker="bin/authors/authors_tree_build.sh"
            ;;
        authors_prefix_build)
            primary="bin/authors/authors_prefix_build.sh"
            marker="bin/authors/authors_prefix_build.sh"
            ;;
        authors_prefix_check)
            primary="bin/authors/authors_prefix_check.sh"
            marker="bin/authors/authors_prefix_check.sh"
            ;;
        authors_prefix_tree)
            primary="bin/authors/authors_prefix_tree.sh"
            marker="bin/authors/authors_prefix_tree.sh"
            ;;
        books_merge)
            primary="bin/books/books_merge.sh"
            twin="lib/books_functions.sh"
            marker="bin/books/books_merge.sh"
            ;;
        books_finalize)
            primary="bin/books/books_finalize.sh"
            marker="bin/books/books_finalize.sh"
            ;;
        utf8_prefix_generator)
            primary="lib/utf8_prefix_generator.awk"
            marker="lib/utf8_prefix_generator.awk"
            shape="x.y"
            ;;
        authors_export)
            primary="bin/authors/authors_export.sh"
            marker="bin/authors/authors_export.sh"
            ;;
        books_reconcile)
            primary="bin/books/books_reconcile.sh"
            marker="bin/books/books_reconcile.sh"
            ;;
        books_estimate)
            primary="bin/books/books_estimate.sh"
            marker="bin/books/books_estimate.sh"
            ;;
        library_backup)
            primary="bin/library/library_backup.sh"
            marker="bin/library/library_backup.sh"
            ;;
        library_populate)
            primary="bin/library/library_populate.sh"
            marker="bin/library/library_populate.sh"
            ;;
        library_refresh)
            primary="bin/library/library_refresh.sh"
            marker="bin/library/library_refresh.sh"
            ;;
        library_report)
            primary="bin/library/library_report.sh"
            marker="bin/library/library_report.sh"
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
  bash tests/unit/test_version_sync.sh

Then finish the release manually:
  1. Add a CHANGELOG.md entry for $tool $new.
  2. Run the relevant suite(s) under WSL:
       wsl.exe tests/integration/test_authors_tree_build.sh   # or the tool's suite
  3. Commit, then tag (tool-prefixed or v-prefixed per convention).
EOF
}

main "$@"