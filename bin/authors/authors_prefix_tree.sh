#!/usr/bin/env bash

###############################################################################
# bin/authors/authors_prefix_tree.sh
#
# Version:       2.8.1
# Last updated:  2026-09-12
#
# PURPOSE:
#   FAST UTF‑8‑safe prefix tree visualizer using AWK.
#   Pretty Unicode branches (├──, └──, │).
#   Unified grouping (ASCII, Cyrillic, Symbols, Digits).
#   TRUE Russian alphabetical sorting.
#   Depth limiting (--depth N).
#   Counts + ranges.
#   Filtering (--filter CATEGORY).
#
#   Consumes the toolchain's prefix table (prefix<TAB>count<TAB>start<TAB>end,
#   e.g. tmp_SORTED_AUTHORS as produced by bin/authors/authors_prefix_build.sh) and renders
#   the hierarchical prefix tree it encodes.
###############################################################################

# Script version, kept in sync with the "# Version:" line in the header.
# SCRIPT_VERSION is parsed from this file's own header (version-sync contract).
# shellcheck disable=SC2155  # sed+head pipeline cannot fail; masking not a concern
readonly SCRIPT_VERSION="$(sed -n 's/^# Version:[[:space:]]*//p' "$0" | head -n 1)"

# Parse arguments
file="$1"
depth_limit=0
filter_category=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --depth)
            depth_limit="$2"
            shift 2
            ;;
        --filter)
            filter_category="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [[ -z "$file" || ! -f "$file" ]]; then
    echo "bin/authors/authors_prefix_tree.sh v$SCRIPT_VERSION"
    echo ""
    echo "Usage: $0 tmp_SORTED_AUTHORS [--depth N] [--filter CATEGORY]"
    echo "Categories: ASCII, Cyrillic, Symbols, Digits, Other"
    exit 1
fi

gawk -v MAX_DEPTH="$depth_limit" -v FILTER="$filter_category" -F'\t' '
# UTF‑8‑safe: return everything EXCEPT the last character (the parent
# prefix).  The historical implementation iterated from the end and returned
# a[n] a[n-1] ... a[2] -- the reversed tail -- so every child was attached to
# a nonexistent parent and the tree never descended below the roots.
function utf8_chop(s,    rev, a, n, i) {
    rev = ""
    n = split(s, a, "")
    for (i = 1; i < n; i++) rev = rev a[i]
    return rev
}

# Determine unified category
function category(ch) {
    if (ch ~ /^[[:punct:]]$/) return "Symbols"
    if (ch ~ /^[0-9]$/) return "Digits"
    if (ch ~ /^[A-Za-z]$/) return "ASCII"
    if (ch ~ /^[А-Яа-яЁё]$/) return "Cyrillic"
    return "Other"
}

BEGIN {
    rus_alpha = "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ"

    for (i = 1; i <= length(rus_alpha); i++) {
        ch = substr(rus_alpha, i, 1)
        rus_pos[ch] = i
    }

    if (MAX_DEPTH == "" || MAX_DEPTH < 1)
        MAX_DEPTH = 9999
}

{
    prefix = $1
    count[prefix] = $2
    start[prefix] = $3
    end[prefix]   = $4

    if (length(prefix) > 1) {
        parent = utf8_chop(prefix)
        children[parent] = children[parent] prefix "\n"
    }

    if (length(prefix) == 1) {
        roots[prefix] = 1
        cat = category(prefix)
        categories[cat] = categories[cat] prefix "\n"
    }
}

function sort_cyrillic(list, out, sorted,    n, arr, i, ch, pos, idx) {
    n = split(list, arr, "\n")

    for (i = 1; i <= n; i++) {
        ch = arr[i]
        if (ch != "") {
            pos = rus_pos[ch]
            out[pos] = ch
        }
    }

    idx = 0
    for (i = 1; i <= length(rus_alpha); i++) {
        if (out[i] != "") {
            idx++
            sorted[idx] = out[i]
        }
    }
    return idx
}

function print_tree(prefix, indent, is_last, depth,    kidlist, n, arr, i, kid, branch, next_indent, label) {

    if (depth > MAX_DEPTH)
        return

    label = prefix " (count: " count[prefix] ", range: " start[prefix] "–" end[prefix] ")"

    if (indent == "")
        print label
    else {
        branch = (is_last ? "└── " : "├── ")
        print indent branch label
    }

    kidlist = children[prefix]
    if (kidlist == "" || depth == MAX_DEPTH)
        return

    n = split(kidlist, arr, "\n")
    asort(arr)

    next_indent = indent (is_last ? "    " : "│   ")

    for (i = 1; i <= n; i++) {
        kid = arr[i]
        if (kid != "")
            print_tree(kid, next_indent, (i == n), depth + 1)
    }
}

BEGIN {
    print "Prefix Tree Visualization"
    print "----------------------------------------"
}

END {
    ordered[1] = "Symbols"
    ordered[2] = "Digits"
    ordered[3] = "ASCII"
    ordered[4] = "Cyrillic"
    ordered[5] = "Other"

    for (ci = 1; ci <= 5; ci++) {
        cat = ordered[ci]

        # Filtering
        if (FILTER != "" && FILTER != cat)
            continue

        if (categories[cat] == "")
            continue

        print ""
        print cat
        print "----------------------------------------"

        if (cat == "Cyrillic") {
            n = sort_cyrillic(categories[cat], out, sorted)
            for (i = 1; i <= n; i++)
                print_tree(sorted[i], "", (i == n), 1)
        }
        else {
            n = split(categories[cat], arr, "\n")
            asort(arr)
            for (i = 1; i <= n; i++) {
                root = arr[i]
                if (root != "")
                    print_tree(root, "", (i == n), 1)
            }
        }
    }
}
' "$file"
