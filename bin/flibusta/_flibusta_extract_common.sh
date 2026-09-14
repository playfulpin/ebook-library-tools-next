#!/usr/bin/env bash
#
# bin/flibusta/_flibusta_extract_common.sh
#
# Version:       1.2.0
# Last updated:  2026-09-13
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Shared extraction primitives for the Flibusta extractor family:
#
#     bin/flibusta/extract_bookid_flibusta.sh    (FileNumber -> file)
#     bin/flibusta/extract_author_flibusta.sh    (author name -> their books)
#     bin/flibusta/extract_series_flibusta.sh    (series name -> its books)
#
#   The underscore prefix marks this file as an intra-group include: the
#   layer gate (bin/check_layers.sh, v1.1.0) explicitly allows bin/ tools
#   to source bin/<group>/_*.sh of their own group, so this code does NOT
#   belong in lib/ (lib/ is domain-free per Follow-It §4) and does NOT
#   need three private copies (the second/third-consumer rule triggered
#   the extraction).
#
#   What lives here: the mechanics of locating a Flibusta FileNumber in
#   the range archives and pulling its member out.  What does NOT live
#   here: any CLI (arg parsing, help, version), any batch loop with its
#   counters/summary, and any database access - each tool owns those.
#
#   Contract for consumers:
#     - source lib/common.sh + common_init FIRST (this file uses debug/
#       log_warn/die/fs_require_dir and expects set -Eeuo pipefail);
#     - set FLIBUSTA_SOURCE_DIR before the index calls;
#     - the type argument is fb2|usr; fb2 members are exactly "<N>.fb2",
#       usr members are "<N>.<realext>" (pdf/djvu/epub, sometimes
#       .pdf.zip) and resolve by prefix.
#
# Version: kept in sync manually with the family; bumped on any
# primitive change (the suites assert the tool headers, not this one).
#
# -----------------------------------------------------------------------------
# API
# -----------------------------------------------------------------------------
#   flb_validate_number NUMBER          -> 0/1 (digits, > 0)
#   flb_index_load TYPE                 -> fills FB2_*/USR_* arrays; rc 1
#                                          when no archives of that type
#   flb_find_archive NUMBER TYPE        -> sets FLB_ARCHIVE; rc 1 when none
#   flb_resolve_member ARCHIVE N TYPE   -> sets FLB_MEMBER; rc 1 when absent
#   flb_extract ARCHIVE MEMBER OUT      -> atomic member extraction
#   flb_read_numbers FILE               -> numbers on stdout (BOM/CR/#
#                                          -comment safe)
#   flb_sql_like_escape STRING          -> safe inside a LIKE '...' pattern
#                                          (backslash doubled, quote doubled,
#                                          % and _ backslash-escaped)
#   flb_sql_literal_escape STRING       -> safe inside an equality '...'
#                                          literal (backslash + quote only;
#                                          % and _ stay literal)
#
# Result-delivery contract (live-tested 2026-09-13): flb_find_archive and
# flb_resolve_member deliver through the FLB_ARCHIVE / FLB_MEMBER globals
# and a return code - NOT stdout.  Call sites must invoke them directly
# (`if flb_find_archive ...; then`), never as $(...) command substitutions:
# a substitution runs in a subshell, where the range index, the listing
# cache and every other global die at call end - measured effect on live
# data was a full re-glob + re-list per number (minutes per author batch).
#
# -----------------------------------------------------------------------------

# Source guard: a file sourced by three tools (or twice by accident) must
# not re-declare readonly state.
if [[ -n "${_ETL_FLIBUSTA_EXTRACT_COMMON_SH:-}" ]]; then
    return 0
fi
_ETL_FLIBUSTA_EXTRACT_COMMON_SH=1

# flb_validate_number NUMBER -> 0/1; digits only, greater than zero.
flb_validate_number() { # $1 = candidate FileNumber
    local file_number="$1"
    [[ "$file_number" =~ ^[0-9]+$ ]] || return 1
    (( 10#$file_number > 0 ))
}

# --- per-type range index (built once per run, scanned per number) ---------------
# Fixed two-family design: FB2_* for f.fb2-*, USR_* for f.usr-*;
# *_INDEXED guards one-time construction.
FB2_INDEXED=0 USR_INDEXED=0
FB2_STARTS=() FB2_ENDS=() FB2_PATHS=()
USR_STARTS=() USR_ENDS=() USR_PATHS=()

# flb_index_load TYPE -> fills the type's parallel arrays; rc 1 when the
# source dir holds no archives of that type at all.
flb_index_load() { # $1 = fb2|usr
    local type="$1"
    local indexed_var="${type^^}_INDEXED"
    (( ${!indexed_var} == 1 )) && return 0

    local -a starts=() ends=() paths=()
    local archive base_name
    shopt -s nullglob
    local -a matches=("$FLIBUSTA_SOURCE_DIR"/f."$type"-*.zip)
    shopt -u nullglob

    for archive in "${matches[@]}"; do
        base_name="$(basename "$archive")"
        if [[ "$base_name" =~ ^f\.$type-([0-9]+)-([0-9]+)\.zip$ ]]; then
            starts+=("${BASH_REMATCH[1]}")
            ends+=("${BASH_REMATCH[2]}")
            paths+=("$archive")
        else
            debug "ignored malformed archive name: $base_name"
        fi
    done

    if (( ${#paths[@]} == 0 )); then
        return 1
    fi

    # shellcheck disable=SC2034  # FB2_*/USR_* arrays are read via namerefs
    # in flb_find_archive, which shellcheck cannot see across the indirection
    case "$type" in
        fb2) FB2_STARTS=("${starts[@]}") FB2_ENDS=("${ends[@]}") FB2_PATHS=("${paths[@]}") FB2_INDEXED=1 ;;
        usr) USR_STARTS=("${starts[@]}") USR_ENDS=("${ends[@]}") USR_PATHS=("${paths[@]}") USR_INDEXED=1 ;;
    esac
    debug "index $type: ${#paths[@]} archive(s)"
    return 0
}

# flb_find_archive NUMBER TYPE -> sets FLB_ARCHIVE; rc 1 when none matches.
# Overlapping ranges resolve to the lowest START (deterministic).  In-process
# by contract: the range index is built once per process and reused (see the
# API contract note - do not wrap in a command substitution).
FLB_ARCHIVE=""
flb_find_archive() { # $1 = FileNumber, $2 = fb2|usr
    local file_number="$1" type="$2"
    flb_index_load "$type" || return 1

    local -n _starts="${type^^}_STARTS"
    local -n _ends="${type^^}_ENDS"
    local -n _paths="${type^^}_PATHS"

    local i best=-1 best_start=""
    for (( i = 0; i < ${#_paths[@]}; i++ )); do
        if (( 10#${_starts[i]} <= 10#$file_number && 10#$file_number <= 10#${_ends[i]} )); then
            if [[ -z "$best_start" ]] || (( 10#${_starts[i]} < 10#$best_start )); then
                best=$i
                best_start="${_starts[i]}"
            fi
        fi
    done
    (( best >= 0 )) || return 1
    # shellcheck disable=SC2034  # consumed by callers via $FLB_ARCHIVE
    FLB_ARCHIVE="${_paths[best]}"
    return 0
}

# flb_resolve_member ARCHIVE NUMBER TYPE -> member name on stdout; rc 1 when
# the archive holds no member for the number.  fb2: exact "<N>.fb2".
# usr: prefix "<N>." with any real extension (pdf, djvu, .pdf.zip, ...).
# Implementation note (live-tested 2026-09-13): the listing is consumed
# WHOLE (mapfile) and scanned in bash - the previous `grep -m1` pipeline
# closed the pipe after the first match, so unzip died with SIGPIPE (141)
# on large listings under pipefail and the member was reported missing
# even though it exists.  No early-closing consumer, no race.
#
# Listing cache (live-tested 2026-09-13): batch runs over hundreds of
# numbers re-list the same few range archives again and again, and each
# `unzip -Z1` over the WSL mount costs seconds of CPU/sys.  The first
# resolution of an archive reads its listing once into the FLB_LISTINGS map
# (newline-joined); later resolutions scan the cached string in bash.
# Key: the archive basename cannot contain newline, so it is unambiguous.
declare -A FLB_LISTINGS=()
# flb_listing_of ARCHIVE -> sets the global FLB_LISTING to the newline-joined
# member listing (populating the cache on first touch).  Returns by variable,
# not stdout: printing would fork a subshell per number, and scanning happens
# per number, so the hot path must stay fork-free.
FLB_LISTING=""
flb_listing_of() { # $1 = archive path
    local archive="$1"
    local key
    key="$(basename -- "$archive")"
    if [[ -z "${FLB_LISTINGS[$key]+x}" ]]; then
        FLB_LISTINGS[$key]="$(unzip -Z1 -- "$archive" 2>/dev/null | tr -d '\r')"
        debug "listing cached: $key"
    fi
    FLB_LISTING="${FLB_LISTINGS[$key]}"
}

FLB_MEMBER=""
flb_resolve_member() { # $1 = archive, $2 = FileNumber, $3 = fb2|usr
    local archive="$1" file_number="$2" type="$3"
    flb_listing_of "$archive"
    if [[ "$type" == fb2 ]]; then
        # exact-line membership check on the cached string: sentinel newlines
        # on both sides make "<N>.fb2" match only a whole line.
        local wanted="${file_number}.fb2"
        if [[ $'\n'"${FLB_LISTING}"$'\n' == *$'\n'"$wanted"$'\n'* ]]; then
            FLB_MEMBER="$wanted"
            return 0
        fi
    else
        # first line whose prefix is "<N>." - anchored to start-of-line so
        # "51234.x" never matches a probe of "1234".  One bash regex on the
        # cached string; no per-line read loop (that loop was the batch hot
        # spot - thousands of read-line iterations per number).
        local nl=$'\n'
        local re="(^|${nl})${file_number}\.[^${nl}]*"
        if [[ "${FLB_LISTING}" =~ $re ]]; then
            local entry="${BASH_REMATCH[0]}"
            # shellcheck disable=SC2034  # consumed by callers via $FLB_MEMBER
            FLB_MEMBER="${entry#"$nl"}"
            return 0
        fi
    fi
    return 1
}

# flb_extract ARCHIVE MEMBER OUTPUT_FILE -> atomic member extraction.
# Streams the single member via `unzip -p` into a temp file next to the
# output, then mv; an empty member is an error (die - consumers run under
# common_init, so die is the house exit-1 behavior).
flb_extract() { # $1 = archive, $2 = member name, $3 = output file
    local archive="$1" member="$2" output_file="$3"
    local temp_file="${output_file}.tmp.$$"

    if ! unzip -p -q -- "$archive" "$member" > "$temp_file"; then
        rm -f -- "$temp_file"
        die "failed to extract '$member' from '$archive'"
    fi

    if [[ ! -s "$temp_file" ]]; then
        rm -f -- "$temp_file"
        die "extracted file is empty: '$member'"
    fi

    mv -- "$temp_file" "$output_file"
}

# flb_read_numbers FILE -> numbers on stdout (BOM/CR/blank/#-comment safe).
flb_read_numbers() { # $1 = list file
    local file="$1"
    sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -e 's/#.*//' "$file" \
        | grep -v '^[[:space:]]*$' || true
}

# flb_sql_like_escape STRING -> a string safe to embed inside a
# LIKE '...<s>...' pattern.  Backslash is doubled first (order matters),
# single quotes are doubled (works with and without NO_BACKSLASH_ESCAPES),
# and the LIKE wildcards % and _ are backslash-escaped so user input is
# matched literally.
flb_sql_like_escape() { # $1 = raw user input
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\'/\'\'}"
    s="${s//%/\\%}"
    s="${s//_/\\_}"
    printf '%s' "$s"
}

# flb_sql_literal_escape STRING -> a string safe to embed inside an
# equality literal '...<s>...' (= comparisons: % and _ are NOT special
# there, so they stay untouched).
flb_sql_literal_escape() { # $1 = raw user input
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\'/\'\'}"
    printf '%s' "$s"
}

return 0
