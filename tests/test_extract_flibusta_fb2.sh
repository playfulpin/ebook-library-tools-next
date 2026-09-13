#!/usr/bin/env bash
#
# Title: Test Flibusta FB2 extraction
# Script Name: test_extract_flibusta_fb2.sh
# Description: Basic fixture-based tests for archive discovery and extraction.
# Project: ebook-library-tools-next
# Author: mp
# Date: 2026-09-13
# Version: 0.1.0
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

SOURCE_DIR="$TEST_ROOT/source"
OUTPUT_DIR="$TEST_ROOT/output"

mkdir -p "$SOURCE_DIR" "$OUTPUT_DIR"

printf 'test fb2 content\n' |
    zip -q -j "$SOURCE_DIR/f.fb2-100001-100010.zip" - >/dev/null 2>&1 || true

# Recreate the fixture with a deterministic member name.
rm -f "$SOURCE_DIR/f.fb2-100001-100010.zip"
printf 'test fb2 content\n' > "$TEST_ROOT/100005.fb2"
printf 'outside range\n' > "$TEST_ROOT/100011.fb2"

(
    cd "$TEST_ROOT"
    zip -q "$SOURCE_DIR/f.fb2-100001-100010.zip" 100005.fb2
    zip -q "$SOURCE_DIR/f.fb2-100011-100020.zip" 100011.fb2
)

export FLIBUSTA_SOURCE_DIR="$SOURCE_DIR"
export FB2_OUTPUT_DIR="$OUTPUT_DIR"

# shellcheck source=../lib/flibusta_fb2.sh
source "$PROJECT_ROOT_DIR/lib/flibusta_fb2.sh"

[[ "$(find_fb2_archive 100005)" == "$SOURCE_DIR/f.fb2-100001-100010.zip" ]]
[[ "$(find_fb2_archive 100011)" == "$SOURCE_DIR/f.fb2-100011-100020.zip" ]]

extract_fb2_file \
    "$SOURCE_DIR/f.fb2-100001-100010.zip" \
    100005 \
    "$OUTPUT_DIR/100005.fb2"

grep -Fxq 'test fb2 content' "$OUTPUT_DIR/100005.fb2"

if find_fb2_archive 100021 >/dev/null 2>&1; then
    printf 'FAIL: unexpected archive match\n' >&2
    exit 1
fi

printf 'PASS: Flibusta FB2 extraction tests\n'
