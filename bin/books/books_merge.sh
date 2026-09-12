#!/usr/bin/env bash

###############################################################################
# bin/books/books_merge.sh
#
# Version:       0.2.0
# Last updated:  2026-09-12
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Merge a legacy book archive into an author-prefix hierarchy built IN
#   MEMORY from a flat author list.  Every top-level folder of the source
#   archive is treated as an author; its files are copied into a directory
#   named after the author, placed under the deepest valid prefix that
#   matches the author name.  Book-series subfolders are copied recursively
#   by default, preserving their relative layout.  Windows metadata files
#   (desktop.ini, Thumbs.db by default) are never copied.
#
#   The prefix tree uses the same range-walk algorithm as
#   bin/authors/authors_tree_build.sh (>= MINIMUM_AUTHORS authors per
#   prefix, capped at MAX_PREFIX_LENGTH), so the layout matches the old
#   on-disk skeleton -- but nothing is built to disk first: the old
#   Empty_Skeleton staging folder no longer exists.
#
#   Output goes straight into a timestamped, pruned staging tree:
#
#       <output-root>/BooksInput_<timestamp>/
#           Т/То/Тол/Толс/Толстой Лев Николаевич/...
#
#   Only directories that actually receive a copied file are created, so the
#   tree is pruned by construction.  The finalize step then rsyncs this tree
#   into the Books library (see bin/books/books_finalize.sh).
#
# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
#   Every setting resolves flag > env var > config file > built-in default.
#   The optional config file is config/merge_books.conf (keys:
#   MERGE_INPUT_FILE, MERGE_SOURCE_DIR, MERGE_OUTPUT_DIR, MERGE_REPORT_DIR,
#   MERGE_RECURSIVE, MERGE_OVERWRITE, MERGE_MIN_AUTHORS, MERGE_MAX_PREFIX,
#   MERGE_SKIP_NAMES).  --dry-run is intentionally not configurable.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/books/books_merge.sh \
#       --source /mnt/c/Backup_Go7/ToLoad \
#       --input-file data/fixtures/authors_list_from_db.txt \
#       --output-root /mnt/c/Backup_Go7 \
#       --report-dir /mnt/c/Backup_Go7/merge-reports \
#       --dry-run
#
#   Always run --dry-run first and review the reports before a real copy.
#   The real copy omits --dry-run and writes into
#   /mnt/c/Backup_Go7/BooksInput_<timestamp>.  Use --no-recursive to copy
#   only direct files, and --overwrite=force to replace existing destination
#   files.  A duplicate staging name is an error; pass --timestamp to pick
#   a different suffix.
#
# -----------------------------------------------------------------------------
# REPORTS (written to REPORT_DIR)
# -----------------------------------------------------------------------------
#   merge-manifest.tsv      one row per processed source child
#   unmatched-authors.tsv   authors with no matching prefix
#   ambiguous-authors.tsv   authors whose longest prefix has several paths
#   duplicates.tsv          destination name already existed / copied twice
#   collisions.tsv          same destination name written by 2 sources in-run
#   skipped-files.tsv       every non-copied row (folders, failures, ...)
#
#   Row format (TSV):
#       processed_at<TAB>source_author<TAB>source_file<TAB>destination_file<TAB>status<TAB>reason
#
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/books_functions.sh
source "$SCRIPT_DIR/../../lib/books_functions.sh"

merge_main "$@"