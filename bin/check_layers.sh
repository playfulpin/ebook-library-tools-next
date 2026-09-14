#!/usr/bin/env bash

###############################################################################
# bin/check_layers.sh
#
# Version:       1.2.0
# Last updated:  2026-09-13
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Enforce the Follow-It §4 layer-boundary rule mechanically so it stays
#   a property of the codebase, not an intention:
#
#       application (bin/) -> infrastructure (lib/)   -- always allowed
#       infrastructure (lib/) -> application (bin/)   -- never
#
#   Two checks:
#
#   1. DOMAIN-FREE INFRASTRUCTURE
#      Every lib/*.sh code line (comments stripped) must be free of domain
#      vocabulary (author/book/library/wishlist and the merge_* prefix that
#      once lived in lib/books_functions.sh).  A hit means domain logic is
#      creeping back into the infrastructure layer.
#
#   2. CORRECT DEPENDENCY DIRECTION
#      Every bin/**.sh may source only lib/ files, config files, the
#      underscore-prefixed INCLUDES OF ITS OWN GROUP (bin/<group>/_*.sh),
#      and - for ORCHESTRATORS ONLY (bin/<group>/run_*.sh) - the other
#      tools of ITS OWN GROUP (bin/<group>/<tool>.sh) sourced as LIBRARIES
#      (the *_LIB_ONLY=1 contract).  An orchestrator composing its own
#      family's tools in-process is the sanctioned exception: it is the
#      one place where a tool-to-tool dependency is the architecture, not
#      drift; the composed tools must remain independently runnable, and
#      anything sourcing a sibling from a plain tool (not run_*.sh) is
#      still a violation.  A tool sourcing another tool anywhere else
#      (bin/ -> bin/, non-underscore) would create a hidden application-
#      to-application dependency; anything sourcing outside lib/ from
#      within the repo (docs, data) is likewise a boundary violation.
#      The _*.sh include carve-out exists for shared DOMAIN primitives
#      within one tool family (the Flibusta extractor family shares
#      _flibusta_extract_common.sh; the shared code may not live in lib/
#      because lib/ is domain-free) - it is still intra-application, so
#      the §4 direction rule is untouched.
#
#   Exit codes: 0 = both rules hold, 1 = violation(s) found.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/check_layers.sh            # check the repository (any cwd)
#
#   CI runs this right after the shell-syntax step and before the test
#   battery, so a layer violation fails the build before tests do.
#
# -----------------------------------------------------------------------------
# LIMITATIONS (deliberate)
# -----------------------------------------------------------------------------
#   The domain-term list is a denylist, not a proof: a new domain concept
#   (say "genre") would need adding here.  That is the point -- adding a
#   term to this file is a conscious architectural act, reviewed in a
#   commit, rather than silent drift.  The check also deliberately does
#   NOT try to parse bash; a comment that smuggles a call past the grep
#   is a review failure, not a tool failure.
#
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VIOLATIONS=0

# Domain vocabulary that must never appear in infrastructure CODE lines.
# (Comments are stripped first -- documentation may legitimately discuss
# the domain; the CODE may not depend on it.)
DOMAIN_RE='author|book|library|wishlist|merge_(sanitize|usage|parse_args|find_config|normalize|load|is_skipped|prefix_to_path|walk|build_prefix_index|find_dest|record|should_overwrite|copy_file|process_author|prepare_reports|main)'
fail() {
    echo "check_layers: $*" >&2
    VIOLATIONS=$((VIOLATIONS + 1))
}

# strip comments and quoted strings from a shell line so that grep hits
# reflect CODE, not documentation or incidental strings in comments.
# Deliberately simple: whole-line comments and trailing " #..." comments.
strip_comment() {
    # remove whole-line comments and inline comments (space-hash boundary)
    sed -e 's/^\s*#.*$//' -e 's/\s#.*$//'
}

# -----------------------------------------------------------------------------
# check 1: lib/ is domain-free (code lines)
# -----------------------------------------------------------------------------
echo "== layer check: lib/ domain vocabulary (code lines) =="

for lib in "$REPO_ROOT"/lib/*.sh; do
    [[ -f "$lib" ]] || continue
    rel="lib/$(basename "$lib")"
    hits="$(strip_comment < "$lib" | grep -nEi "$DOMAIN_RE" || true)"
    if [[ -n "$hits" ]]; then
        fail "domain terms in $rel (infrastructure must not know the domain):"
        while IFS= read -r line; do
            [[ -n "$line" ]] && echo "    $rel:$line" >&2
        done <<< "$hits"
    fi
done

# The AWK generator (lib/utf8_prefix_generator.awk) is deliberately NOT
# domain-checked: it is the C7 parity reference for UTF-8 prefix chopping,
# and its variable vocabulary (author = $0) IS the domain by design.  It
# is still covered by check 2's spirit through the suites; exempting it
# here is a conscious, documented exception, not an oversight.

# -----------------------------------------------------------------------------
# check 2: bin/ sources only from lib/
# -----------------------------------------------------------------------------
echo "== layer check: bin/ sources only lib/ =="

while IFS= read -r tool; do
    rel="${tool#"$REPO_ROOT"/}"
    tool_dir="$(dirname "$tool")"
    tool_base="$(basename "$tool")"
    # every "source" or "." line that references a repo-internal path
    # (also keep lines referencing "/_<name>.sh" - intra-group includes
    # sourced via $SCRIPT_DIR, which mention neither lib/ nor bin/)
    hits="$(grep -nE '^\s*(source|\.)\s+' "$tool" \
        | grep -E 'lib/|bin/|docs/|config/|data/|/_[^/]*\.sh' || true)"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        lineno="${line%%:*}"
        src="${line#*:}"
        case "$src" in
            # allowed: a path resolving into lib/ (strip quotes first so
            # "source "$PROJECT_ROOT/lib/x.sh"" matches)
            *lib/*.sh*) ;;
            # allowed: sourcing a config file is data, not a dependency
            *config/*) ;;
            # allowed: an underscore-prefixed include, but ONLY when the
            # file exists in the tool's own directory (intra-group shared
            # domain primitives; sourcing another group's include, or a
            # non-underscore bin/ sibling, stays forbidden).  Basename
            # comparison - immune to variable-prefixed paths.
            *_*.sh*)
                inc_base="$(basename "$(printf '%s' "$src" | tr -d '"' | sed 's|.*/||')")"
                [[ -f "$tool_dir/$inc_base" ]] \
                    || fail "$rel:$lineno sources an include outside its own group: $src"
                ;;
            # allowed (v1.2.0): an ORCHESTRATOR (bin/<group>/run_*.sh) may
            # source the other tools of its OWN group as libraries - the
            # sanctioned tool-to-tool edge.  The sourced file must exist in
            # the orchestrator's directory and must NOT be an orchestrator
            # itself (no run_* chaining).
            *.sh*)
                if [[ "$tool_base" == run_*.sh ]]; then
                    inc_base="$(basename "$(printf '%s' "$src" | tr -d '"' | sed 's|.*/||')")"
                    if [[ -f "$tool_dir/$inc_base" ]]; then
                        [[ "$inc_base" == run_*.sh ]] \
                            && fail "$rel:$lineno orchestrators may not source other orchestrators: $src"
                    else
                        fail "$rel:$lineno orchestrator sources outside its own group: $src"
                    fi
                else
                    fail "$rel:$lineno sources outside lib/: $src"
                fi
                ;;
            *)
                fail "$rel:$lineno sources outside lib/: $src"
                ;;
        esac
    done <<< "$hits"
done < <(find "$REPO_ROOT/bin" -name '*.sh' -type f | LC_ALL=C sort)

# -----------------------------------------------------------------------------
# summary
# -----------------------------------------------------------------------------
echo
if (( VIOLATIONS > 0 )); then
    echo "check_layers: $VIOLATIONS violation(s). Layer rule: application -> infrastructure only."
    exit 1
fi
echo "check_layers: layer boundaries hold (lib/ domain-free, bin/ -> lib/ only)."
exit 0
