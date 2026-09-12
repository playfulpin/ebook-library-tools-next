# Book library skeleton and merge plan

**Status:** Implemented (refactored pipeline: in-memory merge v0.2.0 + rsync finalize v0.2.0)  
**Updated:** 2026-09-01

## Goal

Build an author-prefix directory hierarchy with the existing tools, then copy
books from the existing archive into the deepest valid prefix directory for
each author — without materializing an `Empty_Skeleton` staging folder on
disk.

The source archive is:

```text
C:\Backup_Go7\ToLoad
```

From WSL2, use:

```text
/mnt/c/Backup_Go7/ToLoad
```

The archive contains mixed book formats. Author folders already exist, but use
a different structure from the new hierarchy:

```text
ToLoad/
└── Author/
    ├── <author-name>/
    │   ├── book files
    │   └── optional nested folders (book series)
    └── ...
```

## The two-step pipeline

```
step 1   bin/merge_books_into_skeleton.sh       step 2   bin/merge_skeleton_into_books.sh
ToLoad ──────────────────────────────► BooksInput_<ts> ──────────────────────► Books
authors_list_from_db.txt              (pruned, timestamped)                    (rsync, destination wins)
```

There is **no `build_shell_nested_authors.sh → Empty_Skeleton` on-disk skeleton
stage** any more:

- `bin/merge_books_into_skeleton.sh` computes the prefix tree **in memory**
  from the flat author list and writes books straight into a timestamped,
  pruned staging tree `BooksInput_<timestamp>`.
- `bin/merge_skeleton_into_books.sh` is a thin, validated **rsync** wrapper
  that syncs the staging tree into Books with `--ignore-existing` (the
  destination wins — nothing is ever overwritten). The old rename → prune →
  copy loop is gone, because the merge tool already emits the staging tree
  under its final `BooksInput_<ts>` name, already pruned.

`bin/build_shell_nested_authors.sh` remains in the toolchain for generating
`mkdir -p` scripts and the SQL nested-set table
(`dictionary_nested_set`); the book-merge pipeline no longer consumes its
output.

## Step 1: merge the archive into the in-memory hierarchy

```bash
cd /home/mike/GIT_ROOT/MultiLib_Utilities

./bin/merge_books_into_skeleton.sh \
  --source /mnt/c/Backup_Go7/ToLoad \
  --input-file data/fixtures/authors_list_from_db.txt \
  --output-root /mnt/c/Backup_Go7 \
  --min-authors 10 \
  --max-prefix 5 \
  --report-dir /mnt/c/Backup_Go7/merge-reports \
  --dry-run
```

### Building the prefix tree in memory

The author list (`--input-file`) is normalized (CRLF → LF, blank lines
dropped) and sorted with `LC_ALL=C` (byte order), then walked with the same
contiguous-range algorithm as the shell builder:

- a prefix becomes a directory level only when at least `--min-authors`
  authors share it (default 10);
- prefixes are capped at `--max-prefix` characters (default 5);
- a space is a word boundary and never becomes a directory level;
- apostrophes become a caret in directory names (`О'Брайен` → `О/О^`),
  matching what the shell builder emits.

The in-memory index records **every valid prefix** (SQL-mode semantics), not
just the deepest ones, because resolution needs ancestors: author
`Абби Линн` resolves to `А/Аб`, an ancestor of the deepest emitted directory.

### Resolution and copy

Each top-level author folder is trimmed and resolved to the **longest valid
prefix** that is a byte-prefix of the author name (case-sensitive, exact for
UTF-8). The author becomes its own folder under that prefix; authors sharing
a prefix never mix their books.

```text
Source author:  Толстой Лев Николаевич
Destination:   BooksInput_<ts>/Т/То/Тол/Толс/Толстой Лев Николаевич/
```

Behavior:

- files are copied **recursively by default** — subfolders are book series
  and keep their relative layout (`Серия/том1.fb2` lands inside the author
  folder); `--no-recursive` copies direct files only and records subfolders
  as skipped;
- **Windows metadata is never copied** (`desktop.ini`, `Thumbs.db` by
  default, configurable via `MERGE_SKIP_NAMES`);
- empty subfolders are never created — **the staging tree is pruned by
  construction**: only directories that receive a copied file exist, so no
  prune pass is needed;
- existing destination files are handled per the overwrite policy
  (`never` default / `ask` / `force`), and a file written twice from the same
  source is always skipped as a duplicate;
- if an author matches no valid prefix, it is reported as **unmatched** and
  nothing is copied;
- the source archive is never modified;
- an existing `BooksInput_<ts>` staging name is not an error: it is treated
  like the old persistent skeleton (the overwrite policy applies), so
  deliberate re-runs and incremental repopulation work.

If the matched prefix is already the author's own folder (from a previous
run), the author is not appended twice.

## Step 2: finalize into Books with rsync

```bash
# Dry run first (rows are would-copy / would-keep)
./bin/merge_skeleton_into_books.sh \
  --output-root /mnt/c/Backup_Go7 \
  --target /mnt/c/Backup_Go7/Books \
  --dry-run

# Real sync (under the hood):
#   rsync -a --ignore-existing BooksInput_<ts>/  Books/
./bin/merge_skeleton_into_books.sh \
  --output-root /mnt/c/Backup_Go7 \
  --target /mnt/c/Backup_Go7/Books
```

`bin/merge_skeleton_into_books.sh`:

- with no `--source`, auto-discovers the **newest** `BooksInput_*` folder
  under `--output-root`;
- requires the source basename to start with `BooksInput_`;
- validates paths (dangerous paths, source/target nesting) before doing
  anything;
- runs `rsync -a --ignore-existing --itemize-changes` with
  `--exclude=desktop.ini --exclude=Thumbs.db` belt-and-braces; a trailing
  slash on the source copies the *contents*, not the folder itself;
- writes a per-file TSV report
  (`merge_skeleton_into_books_<ts>.tsv`) with status `copied` /
  `would-copy` (dry run) and `kept-existing` / `would-keep` — files already
  present in the library are never overwritten (the destination wins);
- retains the staging folder intact;
- requires rsync on PATH (WSL and Ubuntu CI runners ship it).

## Duplicate, collision, and overwrite policy

Duplicate detection uses destination filename matching:

- If the destination filename does not exist, copy the file.
- If the same filename already exists, the **overwrite policy** decides:
  - `never` (default) — skip the copy and record it;
  - `ask` — prompt per file (non-interactive runs behave like `never`);
  - `force` — replace it and record status `overwritten`.
- A file written twice by the same source is always skipped as a duplicate.
- Same-name cases from different sources are recorded as collisions.
- Record every skipped duplicate.

Filename-only comparison is not content-safe: unrelated books may share a
filename. A future improvement should use size plus SHA-256 verification
before considering files identical.

## Reports and manifest

The merge operation writes a report directory containing:

```text
merge-manifest.tsv
unmatched-authors.tsv
ambiguous-authors.tsv
collisions.tsv
duplicates.tsv
skipped-files.tsv
```

The manifest records at least:

```text
processed_at  source_author  source_file  destination_file  status  reason
```

Possible statuses include `copied`, `would-copy` (dry run), `overwritten`,
`duplicate`, `duplicate-name`, `collision`, `unmatched-author`,
`ambiguous-author`, and `skipped` (failed copies, subfolders under
`--no-recursive`, or Windows metadata matched by the skip list).

The finalize step writes its own single report
(`merge_skeleton_into_books_<ts>.tsv`) with statuses `copied`, `would-copy`,
`kept-existing`, `would-keep`.

## Configuration

`config/merge_books.conf` supplies defaults for the input file, source,
output root, report directory, recursion, overwrite policy, tree knobs
(`MERGE_MIN_AUTHORS`, `MERGE_MAX_PREFIX`), and skip list. Every setting
resolves **flag > environment variable > config file > built-in default**.
`--dry-run` is deliberately not configurable — it stays a command-line safety
gate.

`config/merge_skeleton_into_books.conf` supplies defaults for the finalize
wrapper (`OUTPUT_DIR` discovery root, `TARGET_DIR`, `REPORT_DIR`); the same
resolution order applies.

## Safety and rollout

Run the following sequence:

1. Review the author list (`data/fixtures/authors_list_from_db.txt`) and the
   tree knobs (`--min-authors`, `--max-prefix`).
2. Run the merge tool with `--dry-run` and review unmatched authors,
   collisions, duplicates, and skipped files — dry run creates nothing.
3. Run the real merge; inspect the pruned staging tree
   (`/mnt/c/Backup_Go7/BooksInput_<ts>`).
4. Run the finalize step with `--dry-run` and review the would-copy /
   would-keep rows.
5. Run the real finalize; the destination wins, so nothing in `Books` is
   ever overwritten.

`--overwrite=force` is implemented and reviewed, but treat it as the
exception: `never` is the safe default and `ask` prompts per file.

## Implementation

The whole pipeline below is implemented (see `CHANGELOG.md`):

```text
bin/merge_books_into_skeleton.sh         merge the archive into an in-memory
                                         prefix hierarchy -> BooksInput_<ts> (0.2.0)
lib/merge_books_functions.sh             shared functions for the merge tool (0.2.0)
bin/merge_skeleton_into_books.sh         rsync finalize into Books (0.2.0)
bin/build_shell_nested_authors.sh        still available: mkdir -p scripts /
                                         SQL nested-set table (6.6.10)
```

The merge suite covers the in-memory tree build, pruned staging output,
unmatched authors, duplicate filenames, collisions, recursive series copy,
`--no-recursive`, overwrite policies, skip list, config/env/flags precedence,
CLI, and version headers (44/44 checks). The finalize suite covers rsync
dry-run and full run, kept-existing conflicts, auto-discovery, CLI, and the
version header (19/19 checks; skips cleanly when rsync is absent).

Because the prefix tree is generated from the author list itself, each prefix
has exactly one path — the ambiguity case (several distinct skeleton paths
sharing the longest prefix) can no longer arise from a hand-built skeleton;
the code path is kept defensively.