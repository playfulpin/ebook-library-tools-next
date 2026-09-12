#!/usr/bin/gawk
# shellcheck shell=awk  # (not a shell script — gawk program; syntax-checked by CI gawk run)
###############################################################################
# utf8_prefix_generator.awk
#
# Version: 1.1
# Timestamp: 2026‑07‑28 01:42 CDT
#
# PURPOSE:
#   Generate a UTF‑8‑safe prefix table for the V11 pipeline.
#   This version FIXES the corruption caused by AWK whitespace splitting.
#
# FEATURES:
#   • UTF‑8‑safe prefix slicing
#   • UTF‑8‑safe character counting
#   • TAB‑SEPARATED output (critical!)
#   • No whitespace splitting
#   • No corruption from multi‑word authors
#   • No corruption from Cyrillic UTF‑8
#   • No corruption in numeric fields
#
# OUTPUT FORMAT (TAB‑SEPARATED):
#   prefix<TAB>count<TAB>start<TAB>end
#
###############################################################################

# Detect UTF‑8 continuation byte (10xxxxxx)
function is_cont_byte(c) {
    b = index("\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8A\x8B\x8C\x8D\x8E\x8F\
\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9A\x9B\x9C\x9D\x9E\x9F\
\xA0\xA1\xA2\xA3\xA4\xA5\xA6\xA7\xA8\xA9\xAA\xAB\xAC\xAD\xAE\xAF\
\xB0\xB1\xB2\xB3\xB4\xB5\xB6\xB7\xB8\xB9\xBA\xBB\xBC\xBD\xBE\xBF", c)
    return (b > 0)
}

# Count UTF‑8 characters
function utf8_len(s,    i,c,len) {
    len = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (!is_cont_byte(c))
            len++
    }
    return len
}

# Extract first N UTF‑8 characters
function utf8_prefix(s, chars,    c,count,pos) {
    count = 0
    pos = 0
    while (count < chars && pos < length(s)) {
        pos++
        c = substr(s, pos, 1)
        if (!is_cont_byte(c))
            count++
    }
    # pos is the lead byte of the chars-th character.  Advance past the
    # continuation bytes that follow it so the slice ends on a character
    # boundary.  The historical code broke at the lead byte itself, which
    # sliced a multi-byte character in half under a byte locale (LC_ALL=C).
    while (pos < length(s) && is_cont_byte(substr(s, pos + 1, 1)))
        pos++
    return substr(s, 1, pos)
}

BEGIN {
    FS = "\n"   # NEVER split on spaces
    OFS = "\t"  # TAB‑separated output
}

{
    author = $0
    idx = NR - 1

    clen = utf8_len(author)
    max = (clen < maxlen ? clen : maxlen)

    for (L = 1; L <= max; L++) {
        p = utf8_prefix(author, L)
        count[p]++
        if (!(p in start)) start[p] = idx
        end[p] = idx
    }
}

END {
    for (p in count)
        print p, count[p], start[p], end[p]
}
