# Author Toolchain

A collection of Bash + AWK scripts that turn a flat list of author names into
a UTF-8-safe, byte-ordered prefix structure — a prefix table, an integrity
check on that table, a rendered prefix tree, and a nested directory hierarchy.

Everything here operates on UTF-8 names (Russian/Cyrillic, ASCII, and other
scripts) and depends on one hard contract: **the author list is sorted in
`LC_ALL=C` byte order**, which keeps identical prefixes contiguous.

## Pipeline

Two families of tools live here:

```
bin/authors/authors_prefix_build.sh ──> bin/authors/authors_prefix_check.sh ──> bin/authors/authors_prefix_tree.sh
   (generate table)          (validate table)              (render tree)

bin/authors/authors_tree_build.sh
   (build a nested directory tree from names: mkdir -p commands or SQL)

bin/books/books_merge.sh
   (merge a legacy archive into an in-memory author-prefix hierarchy,
    emitting a pruned, timestamped BooksInput_<ts> staging tree -- no
    on-disk skeleton is built or consumed)

bin/books/books_finalize.sh
   (rsync the BooksInput_* staging tree into the Books library,
    destination wins -- the old rename/prune/copy loop is gone)
```

The canonical prefix table format is TAB-separated with four columns:

```
prefix<TAB>count<TAB>start<TAB>end
```

where `prefix` is a name prefix, `count` is the number of authors sharing it,
and `[start..end]` is the contiguous 0-based index range those authors occupy
in the byte-sorted list (`end` is inclusive, so `count == end - start + 1`).

## Requirements

- **A multibyte-capable Bash.** The scripts slice UTF-8 prefixes character by
  character; Cygwin/MSYS Bash slices bytes and is rejected by the suites. Use
  **WSL** (`wsl.exe bash …`).
- **`gawk`** — required by `bin/authors/authors_prefix_tree.sh` and by the AWK parity
  checks.
- **`rsync`** — required by the finalize step
  (`bin/books/books_finalize.sh`). WSL and Ubuntu CI runners ship it.
- **A `mysql`/`mariadb` client (optional)** — only needed to regenerate the
  author list with `bin/authors/authors_export.sh` and to size the next
  collecting round with `bin/books/books_estimate.sh`. The prefix/merge
  tools themselves never touch the database.

## The author list

Every tool above consumes the flat author list at
`data/fixtures/authors_list_from_db.txt` (one canonical name per line). It is
no longer a hand-maintained snapshot: regenerate it straight from the MariaDB
catalog whenever the library changes.

```bash
./bin/authors/authors_export.sh                  # -> data/fixtures/authors_list_from_db.txt
./bin/authors/authors_export.sh --dry-run        # count the authors, write nothing
./bin/authors/authors_export.sh -q MY_QUERY.sql -o -   # run a different query to stdout
```

The default query (`data/sql/qry_authors_4_and_5_all.sql`) selects authors
with at least one book rated 4 or 5 and enough books overall. Connection
settings mirror the BookTracker-import contract (`MYSQL_CLIENT`, `MYSQL_HOST`,
`MYSQL_PORT`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DATABASE`,
`MYSQL_EXTRA_ARGS`; defaults `mysql`, `127.0.0.1`, `3306`, `root`, empty,
`flibusta`); the password travels via `MYSQL_PWD` only and never appears on
the command line, and the session charset is pinned to UTF-8 regardless of
the server's handshake default. MariaDB must already be running — the
exporter only reads from it.

## Tools

### `bin/authors/authors_prefix_build.sh`

Generates the prefix table from a flat author list via a pre-order prefix-trie
walk over the byte-sorted names, so the rows are byte-ordered by construction.

```bash
./bin/authors/authors_prefix_build.sh <input_file> [<max_prefix_length>]        # positional
./bin/authors/authors_prefix_build.sh -i INPUT_FILE [-x NUM] [-o FILE] [-d ON|OFF]
```

Options: `-x/--max-prefix` (default 5), `-o/--output` (write to a file instead
of stdout), `-d/--debugger` (stderr diagnostics).

```bash
./bin/authors/authors_prefix_build.sh data/fixtures/authors_list_from_db.txt 5 > tmp_SORTED_AUTHORS
```

### `bin/authors/authors_prefix_check.sh`

Ultra-strict validator for the prefix table. Reports problems by severity and
exits non-zero if any critical problem is found.

```bash
./bin/authors/authors_prefix_check.sh [SEVERITY] <prefix_table> <max_prefix_length>
./bin/authors/authors_prefix_check.sh -t TABLE [-x NUM] [-s SEVERITY]
```

Severities: `all` (default), `critical`, `warnings`, `info`.

```bash
./bin/authors/authors_prefix_check.sh -t tmp_SORTED_AUTHORS -x 5
```

### `bin/authors/authors_prefix_tree.sh`

Renders the prefix table as a Unicode tree (`├──`, `└──`, `│`), grouped by
category (Symbols, Digits, ASCII, Cyrillic, Other) with true Russian
alphabetical ordering, per-node counts/ranges, depth limiting, and filtering.

```bash
./bin/authors/authors_prefix_tree.sh tmp_SORTED_AUTHORS [--depth N] [--filter CATEGORY]
```

### `bin/authors/authors_tree_build.sh`

Emits `mkdir -p` commands (or SQL) that build a nested directory hierarchy from
the author names. A level is only created when its prefix is shared by at least
`MINIMUM_AUTHORS` authors, and only the deepest valid directory of each branch
is printed.

Author names may contain apostrophes (e.g. `О'Брайен`); the SHELL output
replaces each apostrophe with a caret (`О/О^`) so generated paths stay clean
and safe to copy-paste. The SQL output keeps the raw prefix (its rows escape
single quotes for the SQL literal).

```bash
./bin/authors/authors_tree_build.sh <input_file> <minimum_authors> <max_prefix_length>
./bin/authors/authors_tree_build.sh -i INPUT_FILE [-m NUM] [-x NUM] [-d ON|OFF] [-f SHELL|SQL] [-r PATH] [-c ON|OFF]
```

Options: `-m/--min-authors` (default 10), `-x/--max-prefix` (default 5),
`-f/--format` (`SHELL` or `SQL`), `-r/--root-dir`, `-c/--clean-run`.

```bash
./bin/authors/authors_tree_build.sh -i data/fixtures/authors_list_from_db.txt -m 10 -x 5
```

### `bin/books/books_merge.sh`

Builds the author prefix tree **in memory** from a flat author list (the same
range-walk algorithm as `bin/authors/authors_tree_build.sh`: a prefix becomes
a directory only when at least `--min-authors` authors share it, capped at
`--max-prefix` characters), then copies the files of every top-level author
folder in a legacy archive into a directory named after the author, placed
under the **deepest valid prefix**:

```text
source:  Абби Линн/Magic The Gathering/0Мироходец.zip
dest:    А/Аб/Абби Линн/Magic The Gathering/0Мироходец.zip
```

Output goes straight into a **timestamped, pruned staging tree** —
`<output-root>/BooksInput_<timestamp>/` — with no `Empty_Skeleton` folder
built or consumed. Only directories that receive a copied file are created,
so the tree is pruned by construction.

Book-series subfolders are copied recursively by default, preserving their
relative layout. Windows metadata files (`desktop.ini`, `Thumbs.db` by
default) are never copied. Existing destination files are never overwritten
unless the user allows it. The source archive is never modified. See
`docs/archive/BOOK_LIBRARY_MERGE_PLAN.md` for the full design.

```bash
./bin/books/books_merge.sh \
    --source /mnt/c/Backup_Go7/ToLoad \
    --input-file data/fixtures/authors_list_from_db.txt \
    --output-root /mnt/c/Backup_Go7 \
    --report-dir /mnt/c/Backup_Go7/merge-reports \
    --dry-run
```

Options: `-s/--source`, `-i/--input-file`, `-o/--output-root`,
`--timestamp STAMP`, `-m/--min-authors` (default 10), `-x/--max-prefix`
(default 5), `-r/--report-dir` (default `$PWD/merge-reports`),
`--config FILE`, `--recursive` / `--no-recursive`,
`--overwrite never|ask|force`, `--dry-run` (resolve and report, copy
nothing), `-v/--version`, `-h/--help`.

Every setting resolves **flag > environment variable > config file > built-in
default**. The optional `config/books_merge.conf` holds the input file,
source, output root, report directory, recursive behavior, overwrite policy,
tree knobs, and the skip list (`MERGE_SKIP_NAMES`); the same keys work as
environment variables (`MERGE_INPUT_FILE`, `MERGE_SOURCE_DIR`,
`MERGE_OUTPUT_DIR`, `MERGE_MIN_AUTHORS`, `MERGE_MAX_PREFIX`, ...).
`--dry-run` is intentionally not configurable.

Reports are written as TSV files: `merge-manifest.tsv`,
`unmatched-authors.tsv`, `ambiguous-authors.tsv`, `collisions.tsv`,
`duplicates.tsv`, and `skipped-files.tsv`. Always run `--dry-run` first and
review the reports before a real copy.

The prefix tree slices UTF-8 prefixes character by character, so — like the
builder — this script requires a multibyte-capable shell (WSL).

### `bin/books/books_finalize.sh`

The finalize step: rsync a `BooksInput_<ts>` staging tree (produced by
`bin/books/books_merge.sh`, already named and already pruned) into
the Books library. The rename and prune steps no longer exist; rsync does
the copy, resumably and safely, with a **live progress bar** on the
terminal:

```bash
item_count=$(find <BooksInput_ts> -mindepth 1 -type f -o -type d | wc -l)
rsync -av --ignore-existing <BooksInput_ts>/  <Books>/ | pv -l -s "$item_count" > /dev/null
```

The wrapper validates the paths, requires the source to be a `BooksInput_*`
folder, and writes a per-file TSV report (`copied` / `would-copy` /
`kept-existing` / `would-keep`). The destination wins: a file already
present in the library is never overwritten. The progress bar does not
interfere with the report: the per-file itemize lines are captured via
rsync's `--log-file` instead of stdout. When `pv` is not installed the run
falls back to rsync's native `--info=progress2`. `pv -l` counts listing
lines (one per transferred file and directory), so the count is files+dirs
and a grep filter strips rsync's header/blank/summary lines before pv so
the bar lands at exactly 100%; rsync streams payloads over its own
channel, so the pipe never carries the bytes themselves.

After a successful merge the library is **pruned of empty directories**
(`find <Books> -depth -mindepth 1 -type d -empty -delete`) as a safety net
for interrupted runs — `--no-prune` (or `MERGE_PRUNE_EMPTY_DIRS=false`)
disables it. A dry run only reports how many would be removed.

```bash
# Dry run first (nothing changes)
./bin/books/books_finalize.sh \
    --output-root /mnt/c/Backup_Go7 \
    --target /mnt/c/Backup_Go7/Books \
    --dry-run

# Explicit source
./bin/books/books_finalize.sh \
    --source /mnt/c/Backup_Go7/BooksInput_20260830-223135 \
    --target /mnt/c/Backup_Go7/Books
```

**Options**

| Flag | Description |
|------|-------------|
| `-s, --source=DIR` | Staging tree; when omitted, the **newest** `BooksInput_*` under `--output-root` is auto-discovered |
| `-t, --target=DIR` | Books library to merge into (destination wins) |
| `-o, --output-root=DIR` | Discovery root for `BooksInput_*` (default: `/mnt/c/Backup_Go7`) |
| `--report-dir=DIR` | Where the TSV report is written (default: `/mnt/c/Backup_Go7/merge-reports`) |
| `--dry-run` | Show what rsync would copy and write the report, change nothing |
| `--no-prune` | Keep empty directories in the library (pruning is on by default) |
| `-v, --version` | Print version and exit 0 |
| `-h, --help` | Show help |

The staging folder is always retained intact. Requires **rsync** on PATH.
Windows metadata (`desktop.ini`, `Thumbs.db`) is excluded belt-and-braces in
addition to the merge tool's skip list.

### `lib/utf8_prefix_generator.awk`

The original AWK generator, kept as a parity reference against
`bin/authors/authors_prefix_build.sh`. Emits the same `prefix<TAB>count<TAB>start<TAB>end`
rows (in hash order — sort before comparing).

```bash
gawk -v maxlen=5 -F '\n' -f lib/utf8_prefix_generator.awk <sorted_input>
```

### Shared libraries (`lib/common.sh`, `lib/logging.sh`, `lib/cli.sh`, `lib/filesystem.sh`, `lib/database.sh`)

Phase 3 of the refactoring plan: the common shell infrastructure every
tool builds on. `common.sh` provides standard `set -Eeuo pipefail`
initialization, project-root detection at any `bin/` depth, and the
`die`/`require_command` helpers; `logging.sh` owns the house
`[timestamp] message` format; `cli.sh` owns the global flags
(`-h/-v/--debug`) and the 0/1/2 exit-code contract; `filesystem.sh`
hosts the tree fingerprint and empty-dir prune; `database.sh` assembles
the shared `mysql` argv (opt-in). The MariaDB server lifecycle remains
in `lib/mariadb_lifecycle.sh`. Conversion of individual tools happens
in Phase 4 — see `docs/PHASE_03_COMMON_INFRASTRUCTURE.md`.

### `bin/books/books_reconcile.sh`

Personal-catalog **collection-progress** report.  The scope file
(`data/fixtures/authors_list_from_db.txt`) is the recommended-author list —
authors with highly rated books in the chosen genre; the library root
(`/mnt/c/Backup_Go7/Books`) is where the user collects those authors' books
for later reading.  The report counts how much of the list is already
collected, what is still to collect, and what extra content sits beyond the
list (the user's own picks, known / unknown to the catalog), with catalog
book counts (mlauthorname snapshot) next to on-disk file counts.

```bash
./bin/books/books_reconcile.sh                # summary + per-run TSV report
./bin/books/books_reconcile.sh --no-db        # skip the mlauthorname snapshot
./bin/books/books_reconcile.sh --dry-run      # analyze, write no report
```

Each run also writes the **next-round shopping list** — the recommended
authors with no books on disk yet (`authors (remaining to collect)`) — as
`books_reconcile_to_collect_<ts>.txt` next to the TSV report: byte-ordered, one
canonical name per line, the same shape as the author-list fixture, so it
can feed the merge pipeline directly.  In DB mode it additionally writes
the **beyond-books review export** — `books_reconcile_beyond_books_<ts>.tsv`,
every on-disk file attributed to a beyond-list author as
`author<TAB>relative-path` — the per-file content behind
`books (beyond list authors)`, to review whether those books should stay.

Options: `-l/--library-root`, `-s/--scope-file`, `-r/--report-dir`,
`--no-db`, `-n/--dry-run`, `-d/--debug`, `-v/--version`, `-h/--help`.
Defaults live in `config/books_reconcile.conf`; the MariaDB lifecycle and
`MYSQL_*` client settings are shared via `lib/mariadb_lifecycle.sh`.

### `bin/books/books_estimate.sh`

Estimates the download size of the next collecting round **straight from the
catalog, before anything is downloaded**.  The input is a to-collect author
list (one canonical name per line — e.g. the reconcile shopping-list export
`books_reconcile_to_collect_<ts>.txt`, or the recommended-author fixture); the
tool sums the real per-book sizes the catalog stores (`mlbook.filesize`)
through the same `mlauthorname -> mlauthor -> mlbook` linkage and
whitespace normalization the exporter uses, so a list exported from the
catalog matches 1:1 (list names are resolved to catalog authorids via an
mlauthorname dump and the aggregates run on the resulting integer
IN-list).  Two **distinct-book** totals are reported — a co-authored book
counts once even when several list authors wrote it, so these are the
honest "how much will I download" figures:

- **qualifying** — Russian books rated 4/5 in the `Фантастика` genre family
  (the list's own criteria; ~61 GB for the 5,663-author to-collect round),
- **full oeuvre** — ALL Russian books by those authors, rated or not
  (~432 GB for the same round).

```bash
./bin/books/books_estimate.sh                                          # the recommended-author fixture
./bin/books/books_estimate.sh -i <merge-reports>/books_reconcile_to_collect_20260903-212501.txt
./bin/books/books_estimate.sh --dry-run                                # summarize, write nothing
```

Every run also writes a **per-author breakdown TSV** next to the summary,
sorted **top-rated first** (5-rated qualifying books desc, then qualifying
count desc) so the round can be prioritized author by author:
`books_estimate_<ts>.tsv` with columns
`author | qualifying_books | qualifying_bytes | 5rated_books | avg_rating |
full_books | full_bytes`; the top 10 of that order are printed in the
summary.  Per-author rows attribute co-authored books to each author, so
their sums exceed the distinct-book totals by exactly the multi-author
overlap.  The MariaDB lifecycle and `MYSQL_*` settings are shared via
`lib/mariadb_lifecycle.sh` (auto-start when down, graceful stop on exit
when this script started it; `--dry-run` never starts or stops the server
and writes no breakdown file).

Options: `-i/--input-file`, `-o/--output`, `-r/--report-dir`,
`-n/--dry-run`, `-d/--debug`, `-v/--version`, `-h/--help`.  Defaults live
in `config/books_estimate.conf`.

### `bin/library/library_backup.sh`

Backup / restore of the **app-registered personal library database
(`myprivatelib`)** — the sibling library the MultiLib desktop app created
(same 17-table ml* schema as `flibusta`, empty, connectable from the app).
This is the safety net that must exist BEFORE anything is populated into
`myprivatelib` (see `docs/archive/REPRESENTATION_PLAN.md`):

```bash
./bin/library/library_backup.sh                              # backup (default action)
./bin/library/library_backup.sh list                         # list backups newest first
./bin/library/library_backup.sh verify <file>.sql.gz         # integrity-check a backup
./bin/library/library_backup.sh restore <file>.sql.gz        # restore over the library
./bin/library/library_backup.sh --dry-run restore <file>.sql.gz   # report only
```

`backup` dumps the library DB with `mysqldump` and gzips it into
`BACKUP_DIR` as `<db>_<timestamp>.sql.gz` (integrity-checked, optional
`BACKUP_KEEP` retention prune).  `restore` is safe by design: it backs up
the current state first, and refuses to overwrite a non-empty library
without `--force`.  `verify` checks gzip integrity + dump sanity; `list`
shows the backups.  The MariaDB lifecycle and `MYSQL_*` client settings are
shared via `lib/mariadb_lifecycle.sh`; the password travels via
`MYSQL_PWD` only, never on a command line.

Options: `-f/--force`, `-n/--dry-run`, `-d/--debug`, `-v/--version`,
`-h/--help`.  Defaults live in `config/library_backup.conf`
(`BACKUP_DIR`, `BACKUP_DB`, `BACKUP_KEEP`).

### `bin/library/library_refresh.sh`

Orchestrates the freshness loop: detect change -> backup -> populate.

```bash
./bin/library/library_refresh.sh             # refresh only when the Books tree changed
./bin/library/library_refresh.sh --status    # checkpoint state + file count, no side effects
./bin/library/library_refresh.sh --dry-run   # report the decision and the plan, change nothing
./bin/library/library_refresh.sh --force     # refresh even when the checkpoint says up-to-date
```

### `bin/library/library_report.sh`

The personal-library wish list (reading plan) and reporting view.

```bash
./bin/library/library_report.sh --search piranha        # find bookids by title/author
./bin/library/library_report.sh --add 882939 --period 2026-09 --note "Piranha cycle"
./bin/library/library_report.sh                         # render the wish-list view (DB join)
./bin/library/library_report.sh --set-status 882939 reading
./bin/library/library_report.sh --set-status 882939 done
./bin/library/library_report.sh --export md             # report_wishlist_<ts>.md
./bin/library/library_report.sh --list --no-db          # raw entries, offline
```

**Wish-list store (v1.0.0).**  State lives in `data/wishlist.tsv` —
plain TSV rows `bookid <TAB> added <TAB> target_period <TAB> status
<TAB> note`, comments/blanks allowed — deliberately OUT of the
database so the populate TRUNCATE-reload cycle never wipes the plan.
The default view joins the wish bookids against `myprivatelib`
(read-only: title, authors, series + position, rating), groups by
target period then author, marks entries `[ ]` wish / `[~]` reading /
`[x]` done, prints a per-run completion tally, and lists bookids not
yet in the library separately so a book can be planned before it is
collected.  Mutations never touch the server; the view auto-starts
MariaDB via the shared lifecycle when it is down.  Defaults live in
`config/library_report.conf` (`REPORT_WISHLIST_FILE`,
`REPORT_OUTPUT_DIR`, `REPORT_TARGET_DB`, `REPORT_STATUSES`).

**Tree-fingerprint checkpoint (v1.0.0).**  The checkpoint is a recursive
fingerprint of the Books tree — one line per file: relative path, size,
mtime (epoch) — C-sorted, stored in `REFRESH_REPORT_DIR`.  It is
deliberately not a single `stat` of the root folder: folder mtimes do
not reliably propagate on the Windows/9P mount when files land in
subfolders, so a root-only stat would miss real changes.  A changed
fingerprint means at least one file was added / removed / resized /
touched — exactly what changes what populate must represent.  On
"changed" (or `--force`) the orchestrator runs the safety backup
(`backup_myprivatelib.sh`), then the rebuild (`populate_myprivatelib.sh`),
then writes the new checkpoint; every step delegates to the existing
tools (`MYSQL_*` env vars pass through, `REFRESH_MYSQL_ARGS` forwards
extra CLI args), and a child failure aborts the run leaving the previous
checkpoint intact.  "Up to date" exits 0 without touching anything — a
cron-friendly contract.  The directory-mtime case is covered by a
dedicated suite assertion (touching only a folder does NOT flip the
decision).

### `bin/library/library_populate.sh`

Rebuild the **app-registered personal library database (`myprivatelib`)**
from the on-disk `Books` collection (Phase 1 of
`docs/archive/REPRESENTATION_PLAN.md`).  Every book file is md5-hashed
(zip-wrapped FB2 by its **decompressed content**, loose `*.fb2` directly)
and matched against `flibusta.mlbook.md5` — the dump pipeline populates
that column for ALL 869,130 catalog rows, so md5 matching is exact and
unambiguous.  **Only books present in the `Books` folder are represented**
— no exact-copy of the flibusta catalog:

```bash
./bin/library/library_populate.sh                     # rebuild myprivatelib from Books
./bin/library/library_populate.sh --dry-run           # walk + resolve + summarize, write nothing
./bin/library/library_populate.sh --debug             # verbose diagnostics
```

**Source keys verbatim, AUTO_INCREMENT-free schema (v1.3.0).**  MultiLib.exe
treats server-generated (AUTO_INCREMENT) primary-key columns differently
from the original schema's plain PK columns and misbehaves with a
populated library (see `docs/archive/DO_IT_ongoing.md`), so the tool first
**strips `AUTO_INCREMENT` from all 16 PK columns** of the target schema
(schema-driven, attribute-preserving `ALTER TABLE ... MODIFY COLUMN` —
the column definition is read from `SHOW CREATE TABLE` and only the
`AUTO_INCREMENT` keyword is dropped; list in `PK_COLUMNS`, verified
afterwards via `information_schema.COLUMNS.EXTRA`).  Keys themselves are
**the flibusta source keys, copied verbatim — the tool generates NO
synthetic keys** (per `docs/archive/DO_IT_ongoing.md`): the md5 match
resolves a file to the catalog `bookid`, and that `bookid` (plus the
source `authorid`/`genreid`/`seqid` and the child PKs
`la_id`/`gn_id`/`sq_id`/`rt_id`/`ci_id`) is inserted unchanged — the
v1.2.0 tool-assigned 1..N counters and session-variable remaps are gone.
Because every reference now equals its source value, a post-reload
**FK integrity gate** verifies 9 reference paths (0 orphans required).
The whole rebuild runs as one SQL script in a single client session
(`TRUNCATE` first, so every run is a clean purge-and-reload).  Reference
entities are inserted for the personal library's books only —
`mlauthorname` (distinct authors), `mlgenrename` (distinct genres
**plus their ancestor categories, so the genre tree the app renders is
preserved**; `parentgenreid` is the source value verbatim — the tree is
self-consistent in the source), `mlseqname` (distinct series).
`mlbook.filename` carries the **catalog value**
(`flibusta.mlbook.filename`, the transliterated name the app displays —
not the on-disk path), `arcname` the on-disk zip member name
(`library='myprivatelib'`, `filesize` = on-disk bytes, catalog metadata
copied verbatim).  `mlrating` rows come from `flibusta.mlrating` — the
per-book aggregate
rating produced by `BookTracker-import/sql/Flibusta_Load_mlrating.sql`.
`flibusta` is read-only; app-owned tables in `myprivatelib` (`mlactual`,
`mldownloaddata`, `mlnews*`, `mluser*`) are never touched.
`mlcoverpage`/`mldescription` are not populated — the loaded dump leaves
both empty (covers/descriptions need the separate extended-data torrents
loaded first).  A column-parity mismatch on ANY managed table aborts the
run before any `TRUNCATE` (a partial rebuild would leave dangling key
references).  Each run writes a TSV report (matched/unmatched per file)
to `POP_REPORT_DIR`; the MariaDB lifecycle and `MYSQL_*` client settings
are shared via `lib/mariadb_lifecycle.sh`, password via `MYSQL_PWD` only.

Options: `-n/--dry-run`, `-d/--debug`, `-v/--version`, `-h/--help`.
Defaults live in `config/library_populate.conf` (`POP_LIBRARY_ROOT`,
`POP_REPORT_DIR`, `POP_SOURCE_DB`, `POP_TARGET_DB`, `POP_CHUNK`).

## Testing

Each tool has a self-contained regression suite, plus one end-to-end suite that
chains the whole pipeline. All suites must run from WSL:

Suites are grouped by level and run in order (unit → integration → e2e)
with the battery runner:

```bash
tests/run_all.sh -q        # everything, one line per suite
tests/run_all.sh unit      # one group: unit | integration | e2e
```

Or run a single suite directly:

```bash
# unit — one tool or lib, fully mocked, runs anywhere
tests/unit/test_authors_export.sh            # exporter: argv, rows, lifecycle mocks
tests/unit/test_books_merge.sh               # archive -> in-memory prefix hierarchy
tests/unit/test_books_finalize.sh            # BooksInput_* -> Books rsync finalize (+ rsync)
tests/unit/test_books_reconcile.sh           # recon: classification + collection-progress summary (mock mysql)
tests/unit/test_books_estimate.sh            # estimator: sums, top-rated-first breakdown, lifecycle mocks
tests/unit/test_library_backup.sh            # backup/restore: argv, gz artifact, restore guards, lifecycle mocks
tests/unit/test_library_populate.sh          # populate: md5 map, walk/hash, resolve, source-key-verbatim rebuild, parity abort
tests/unit/test_library_refresh.sh           # refresh: checkpoint decisions, child invocation, failure isolation
tests/unit/test_library_report.sh            # report: wish-file format, mutations, view grouping, exports, password hygiene
tests/unit/test_lib_infrastructure.sh        # Phase 3 libs: init, root detection, logging, cli, fs, db
tests/unit/test_utf8_prefix_generator.sh     # AWK generator: direct edge-case tests
tests/unit/test_version_sync.sh              # version locations agree

# integration — multi-component suites with golden-file baselines (WSL-class)
wsl.exe tests/integration/test_authors_prefix_build.sh   # generator: goldens, invariants, parity, CLI
wsl.exe tests/integration/test_authors_tree_build.sh
wsl.exe tests/integration/test_authors_prefix_tree.sh    # renderer: goldens, descent, filters, depth, CLI

# e2e — the cross-tool chain on real data (WSL-class)
wsl.exe tests/e2e/test_e2e_pipeline.sh       # export -> prefix build -> check -> tree
```

Suites write nothing to the repository; each builds its scratch files in a
temporary directory. The golden-based suites accept `--regen` to refresh their
golden files.

A new `tests/unit/test_version_sync.sh` suite (runs anywhere) verifies that every
tool's version is identical across all four tracked locations — header, lib
twin, README release-table row, and RELEASE_NOTES shipped line. `bin/version_bump.sh`
edits all four in one shot, so use it for every bump:

```bash
./bin/version_bump.sh authors_tree_build 6.6.12
```

## Continuous integration

GitHub Actions (`.github/workflows/ci.yml`) runs on every push/PR: shell
syntax check across `bin/` and `lib/`, the version-sync suite, and all ten
tool suites on `ubuntu-latest`. Linux bash is multibyte-capable, so the
WSL-only constraint of the UTF-8 suites does not block CI; the finalize suite
needs rsync (present on the runners) and the rest run anywhere. This is what
caught the two suites that had been broken since the layout refactor.

## Releases & versioning

Each script's version lives in its header comment (`# Version:`), which the
script also prints in `-h` — a single source of truth, bumped `0.0.1` per
iteration. The working script at the repository root is the released artifact;
there is no separate `release/` snapshot to maintain.

Releases are tagged with a tool-prefixed name:

| Tool | Version | Tag |
|---|---|---|
| `bin/authors/authors_prefix_build.sh` | 1.0.4 | `build_prefix_table-1.0.4` |
| `bin/authors/authors_prefix_check.sh` | 1.2.1 | `prefix_table_integrity-1.2.1` |
| `bin/authors/authors_prefix_tree.sh` | 2.8.1 | `v2.8.1` |
| `bin/authors/authors_tree_build.sh` | 6.6.10 | `v6.6.10` |
| `bin/books/books_merge.sh` | 0.2.1 | `books_merge-0.2.1` |
| `bin/books/books_finalize.sh` | 0.2.3 | `books_finalize-0.2.3` |
| `bin/authors/authors_export.sh` | 1.0.2 | `export_authors_from_db-1.0.2` |
| `bin/books/books_reconcile.sh` | 1.0.3 | `books_reconcile-1.0.3` |
| `bin/books/books_estimate.sh` | 1.0.0 | `books_estimate-1.0.0` |
| `bin/library/library_backup.sh` | 1.0.0 | `library_backup-1.0.0` |
| `bin/library/library_populate.sh` | 1.3.0 | `library_populate-1.3.0` |
| `bin/library/library_refresh.sh` | 1.0.0 | `library_refresh-1.0.0` |
| `bin/library/library_report.sh` | 1.2.0 | `library_report-1.2.0` |
| `lib/utf8_prefix_generator.awk` | 1.1 | `utf8_prefix_generator-1.1` |

`v2.8.1` and `v6.6.8` predate the tool-prefixed convention.

**`v1.0.0` was the first production release** of the toolchain as a whole,
cut 2026-09-01 on top of the 6.6.10 tool work; it superseded the individual
tool tags as the repository-wide release marker.  **`v1.1.0`, cut 2026-09-03
on top of the library-catalog refactor**, moved the merge pipeline to run
without an on-disk skeleton (in-memory `BooksInput_<ts>` staging, rsync
finalize with a live `pv -l` progress bar) and added CI on every push and
pull request.  **`v1.2.0`, cut 2026-09-03**: the author list is DB-driven —
`bin/authors/authors_export.sh` regenerates `data/fixtures/authors_list_from_db.txt`
from a query against the MariaDB catalog and manages the server lifecycle
itself (auto-start when down, graceful stop on exit), and the working fixture
is a genre-scoped 5,707-author Фантастика list, regenerable at any time.

To cut a release: bump the header version, run the WSL test suites (see
[Testing](#testing)), commit, then tag with the tool-prefixed name. See
`CHANGELOG.md` for the full history and step-by-step workflow.

## Documentation map

| Need | Read |
|---|---|
| Architecture: layout, groups, ownership, dependencies, safety contract | **`ARCHITECTURE.md`** (authoritative, distilled from the ratified Phase 2 doc) |
| Why it is this way (decision register) | `docs/PHASE_02_TARGET_ARCHITECTURE.md` |
| How the refactor was executed | `docs/PHASE_01_INVENTORY.md`, `docs/PHASE_03_COMMON_INFRASTRUCTURE.md`, `docs/PHASE_04_TOOL_CONVERSION.md` |
| Databases behind the tools | `docs/MultiLib_Flibusta_DB.md` |
| Phase completion gates & records | `docs/Measurable Phase Completion Criteria.md` |
| What to do next | `docs/NEXT.md` |
| Historical plans & consumed docs | `docs/archive/` (+ its README) |

## Repository layout

```
bin/                            user-facing commands, grouped by function
  authors/                      authors_export.sh, authors_prefix_build.sh,
                                authors_prefix_check.sh, authors_prefix_tree.sh,
                                authors_tree_build.sh
  books/                        books_merge.sh, books_finalize.sh,
                                books_estimate.sh, books_reconcile.sh
  library/                      library_backup.sh, library_populate.sh,
                                library_refresh.sh, library_report.sh
bin/version_bump.sh                 bump one tool's version across header + docs (flat in bin/, not a group)
lib/books_functions.sh        shared functions for the merge tool
lib/mariadb_lifecycle.sh            shared MariaDB lifecycle (start/stop/readiness)
lib/utf8_prefix_generator.awk       original AWK generator (parity reference)
config/books_merge.conf             defaults for the merge tool (input file, paths, tree knobs)
config/books_finalize.conf   defaults for the finalize tool (paths + discovery root)
config/books_reconcile.conf       defaults for the recon report (library root, scope, report dir)
config/books_estimate.conf  defaults for the estimator (input list, report dir)
config/library_backup.conf   defaults for the backup tool (backup dir, db, retention)
config/library_populate.conf defaults for the population tool (library root, report dir, db pair, chunk)

tests/run_all.sh                # battery runner: unit -> integration -> e2e
tests/unit/                     # one suite per tool/lib, fully mocked (runs anywhere)
tests/integration/              # multi-component suites + golden/ baselines
tests/e2e/                      # cross-tool chain on real data
tests/fixtures/                 # shared input fixtures (case_*.txt, viz_*.txt)

.github/workflows/ci.yml        CI: syntax + version sync + all suites on push/PR

docs/archive/BOOK_LIBRARY_MERGE_PLAN.md        skeleton + merge design document

data/fixtures/authors_list_from_db.txt        flat author list (regenerated from the DB by bin/authors/authors_export.sh)
data/sql/CTE_table.sql / data/sql/populate_tree.sql   nested-set dictionary table (schema + data)
data/sql/qry_authors_4_and_5_all.sql           default author-list query (rated-4/5 authors) for the exporter

CHANGELOG.md                    full release history
_Old_Stuff/                     archived/scratch files (git-ignored)
data/commit_msg/                commit-message drafts (git-ignored)
```

See `CHANGELOG.md` for the full release history and the step-by-step release
workflow.
