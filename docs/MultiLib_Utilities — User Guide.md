# MultiLib_Utilities — User Guide

## 1. Overview

`MultiLib_Utilities` is a Bash/AWK toolchain for maintaining a local book
library around the MultiLib application and the Flibusta catalog.

The project has two related areas:

1. **Author/prefix tools** — generate, validate, and visualize the UTF-8-safe
   author prefix hierarchy.
2. **Personal-library tools** — collect authors, merge an existing book archive
   into the library, estimate collection size, reconcile collection progress,
   populate the MultiLib `myprivatelib` database, maintain backups, refresh the
   database when the Books tree changes, and manage a reading wish list.

The tools are designed to be used in a sensible sequence. Some commands are
independent utilities; others form a pipeline and should be run in the order
described below.

---

## 2. Prerequisites

### 2.1 WSL / Linux

For the UTF-8 prefix and book-merge tools, use **WSL** or native Linux.

Do not use Git Bash/MSYS for the UTF-8 hierarchy tools. Their Bash string
slicing is byte-oriented and can corrupt Cyrillic and other multibyte names.

Check Bash:

```bash
bash --version
```

A typical WSL invocation from Windows is:

```bash
wsl.exe bash ...
```

### 2.2 Required commands

Check the main dependencies:

```bash
bash --version
gawk --version
rsync --version
```

The database-related tools additionally require a MariaDB/MySQL client:

```bash
mysql --version
mysqldump --version
```

`rsync` is required by the final Books merge step.

`pv` is optional. If installed, `merge_skeleton_into_books.sh` uses it for a
live progress bar; otherwise it falls back to rsync's native progress display.

### 2.3 Project directory

From WSL, change to the project:

```bash
cd /path/to/MultiLib_Utilities
```

For example:

```bash
cd /home/mike/GIT_ROOT/MultiLib_Utilities
```

All commands in this guide assume that the current directory is the project
root unless stated otherwise.

---

# 3. The Big Picture

The complete personal-library workflow is:

```text
MariaDB / Flibusta catalog
        |
        | 1. export recommended authors
        v
authors_list_from_db.txt
        |
        +------------------------------+
        |                              |
        v                              v
2. estimate download size       3. merge archive
                                      |
                                      v
                              BooksInput_<timestamp>
                                      |
                                      v
                              4. finalize into Books
                                      |
                                      v
                                    Books
                                      |
                                      v
5. backup myprivatelib
        |
        v
6. populate myprivatelib
        |
        v
7. reconcile collection
        |
        +--> next-round author list
        |
        +--> download-size estimate
        |
        v
8. refresh automatically when Books changes

9. report_library.sh manages the reading plan independently
```

The author-prefix toolchain is:

```text
authors_list_from_db.txt
        |
        v
build_prefix_table.sh
        |
        v
prefix_table_integrity.sh
        |
        v
prefix_tree_visualizer.sh
```

The older/direct nested-directory builder remains available:

```text
authors_list_from_db.txt
        |
        v
build_shell_nested_authors.sh
        |
        +--> SHELL mkdir -p commands
        |
        +--> SQL nested-set data
```

---

# 4. Step 1 — Generate the Author List

The canonical author list is:

```text
data/fixtures/authors_list_from_db.txt
```

It contains one canonical author name per line and is intended to be generated
from the MariaDB catalog rather than manually maintained.

Run:

```bash
./bin/export_authors_from_db.sh
```

This replaces the fixture with the result of:

```text
data/sql/qry_authors_4_and_5_all.sql
```

### Dry run

To check the operation without changing the output file:

```bash
./bin/export_authors_from_db.sh --dry-run
```

### Use another query

```bash
./bin/export_authors_from_db.sh \
    --query-file data/sql/my_query.sql \
    --output data/fixtures/my_authors.txt
```

To write the result to stdout:

```bash
./bin/export_authors_from_db.sh \
    --query-file data/sql/my_query.sql \
    --output -
```

### Important

MariaDB must be available. The exporter can start MariaDB when it is stopped
and stop it again if it was the process that started it.

`--dry-run` does not start or stop the server.

Database connection settings are supplied through the shared `MYSQL_*`
environment variables and configuration contract. The password is passed via
`MYSQL_PWD`, not as a command-line argument.

---

# 5. Step 2 — Estimate the Next Download

Before downloading a large collection, estimate how much data the selected
authors represent.

Run:

```bash
./bin/estimate_download_size.sh
```

By default it uses:

```text
data/fixtures/authors_list_from_db.txt
```

A previous reconciliation can produce a ready-to-use shopping list:

```bash
./bin/estimate_download_size.sh \
    --input-file /path/to/reconcile_to_collect_<timestamp>.txt
```

The tool calculates two distinct-book totals:

- **qualifying** — Russian books rated 4/5 in the `Фантастика` genre family;
- **full oeuvre** — all Russian books by the selected authors.

Co-authored books are counted only once in the distinct totals.

### Save reports elsewhere

```bash
./bin/estimate_download_size.sh \
    --input-file data/fixtures/authors_list_from_db.txt \
    --report-dir /mnt/c/Backup_Go7/merge-reports
```

Each normal run produces a per-author TSV breakdown. The top 10 authors are
also shown in the summary, ordered by the number of highly rated qualifying
books and then qualifying count.

### Dry run

```bash
./bin/estimate_download_size.sh --dry-run
```

No breakdown file is written and the MariaDB lifecycle is not changed.

---

# 6. Step 3 — Inspect / Build the Author Prefix Table

The prefix-table family is useful when you need to inspect or validate the
author hierarchy itself.

## 6.1 Build the prefix table

```bash
./bin/build_prefix_table.sh \
    data/fixtures/authors_list_from_db.txt \
    5 \
    > tmp_SORTED_AUTHORS
```

Or use named options:

```bash
./bin/build_prefix_table.sh \
    --input-file data/fixtures/authors_list_from_db.txt \
    --max-prefix 5 \
    --output tmp_SORTED_AUTHORS
```

The output format is:

```text
prefix<TAB>count<TAB>start<TAB>end
```

The author list must use `LC_ALL=C` byte order.

## 6.2 Validate the table

```bash
./bin/prefix_table_integrity.sh \
    --table tmp_SORTED_AUTHORS \
    --max-prefix 5
```

For only critical errors:

```bash
./bin/prefix_table_integrity.sh \
    --table tmp_SORTED_AUTHORS \
    --max-prefix 5 \
    --severity critical
```

## 6.3 Visualize the table

```bash
./bin/prefix_tree_visualizer.sh tmp_SORTED_AUTHORS
```

Limit the depth:

```bash
./bin/prefix_tree_visualizer.sh \
    tmp_SORTED_AUTHORS \
    --depth 2
```

Filter by category:

```bash
./bin/prefix_tree_visualizer.sh \
    tmp_SORTED_AUTHORS \
    --filter Cyrillic
```

Supported categories are:

```text
ASCII
Cyrillic
Symbols
Digits
Other
```

---

# 7. Step 4 — Build Nested Author Directories Directly

`build_shell_nested_authors.sh` remains useful when you want generated
`mkdir -p` commands or the SQL nested-set representation.

Example:

```bash
./bin/build_shell_nested_authors.sh \
    --input-file data/fixtures/authors_list_from_db.txt \
    --min-authors 10 \
    --max-prefix 5
```

The default output format is `SHELL`.

Save it:

```bash
./bin/build_shell_nested_authors.sh \
    --input-file data/fixtures/authors_list_from_db.txt \
    --min-authors 10 \
    --max-prefix 5 \
    > build_authors.sh
```

For SQL:

```bash
./bin/build_shell_nested_authors.sh \
    --input-file data/fixtures/authors_list_from_db.txt \
    --min-authors 10 \
    --max-prefix 5 \
    --format SQL \
    > nested_authors.sql
```

A prefix is emitted only when at least `MINIMUM_AUTHORS` authors share it.

The default values are:

```text
minimum authors = 10
maximum prefix  = 5
```

Apostrophes are handled specially in generated shell paths:

```text
О'Брайен
```

becomes a shell directory component using the project's caret convention:

```text
О/О^
```

The SQL representation retains the actual prefix and escapes it correctly.

### Important

The current book-merge pipeline does **not** build or consume an
`Empty_Skeleton` directory. The merge tool builds the hierarchy in memory.

---

# 8. Step 5 — Merge an Existing Book Archive

The normal book-import pipeline starts with:

```text
bin/merge_books_into_skeleton.sh
```

Despite its historical name, this tool no longer creates an on-disk
`Empty_Skeleton`.

Instead it:

1. reads the canonical author list;
2. builds the prefix hierarchy in memory;
3. examines the top-level author folders in the source archive;
4. resolves each author to the deepest valid prefix;
5. copies the books into a timestamped `BooksInput_<timestamp>` staging tree;
6. creates only directories that actually receive files.

Example source:

```text
/mnt/c/Backup_Go7/ToLoad
```

Run a dry run first:

```bash
./bin/merge_books_into_skeleton.sh \
    --source /mnt/c/Backup_Go7/ToLoad \
    --input-file data/fixtures/authors_list_from_db.txt \
    --output-root /mnt/c/Backup_Go7 \
    --report-dir /mnt/c/Backup_Go7/merge-reports \
    --dry-run
```

### Real merge

After reviewing the reports:

```bash
./bin/merge_books_into_skeleton.sh \
    --source /mnt/c/Backup_Go7/ToLoad \
    --input-file data/fixtures/authors_list_from_db.txt \
    --output-root /mnt/c/Backup_Go7 \
    --report-dir /mnt/c/Backup_Go7/merge-reports
```

The result looks like:

```text
/mnt/c/Backup_Go7/BooksInput_20260912-072000/
└── Т/
    └── То/
        └── Тол/
            └── Толс/
                └── Толстой Лев Николаевич/
                    └── book.zip
```

The exact timestamp will of course differ.

### Important safety properties

By default:

```text
--overwrite never
```

Existing destination files are not replaced.

Available policies:

```bash
--overwrite never
--overwrite ask
--overwrite force
```

`never` is the recommended setting.

The source archive is never modified.

Book-series subdirectories are copied recursively by default:

```text
Author/
└── Series/
    ├── volume1.fb2
    └── volume2.fb2
```

Use:

```bash
--no-recursive
```

to copy direct files only.

Windows metadata such as:

```text
desktop.ini
Thumbs.db
```

is skipped.

---

# 9. Step 6 — Review Merge Reports

The merge operation writes TSV reports in the report directory.

Typical files are:

```text
merge-manifest.tsv
unmatched-authors.tsv
ambiguous-authors.tsv
collisions.tsv
duplicates.tsv
skipped-files.tsv
```

Always inspect these after the dry run.

The most important items to investigate are:

- unmatched authors;
- ambiguous authors;
- filename collisions;
- duplicate files;
- skipped files.

A dry run should be treated as a review stage, not merely as a test that the
command starts.

---

# 10. Step 7 — Finalize the Staging Tree into Books

After the staging tree has been reviewed, use:

```text
bin/merge_skeleton_into_books.sh
```

First run a dry run:

```bash
./bin/merge_skeleton_into_books.sh \
    --output-root /mnt/c/Backup_Go7 \
    --target /mnt/c/Backup_Go7/Books \
    --dry-run
```

If the result is correct:

```bash
./bin/merge_skeleton_into_books.sh \
    --output-root /mnt/c/Backup_Go7 \
    --target /mnt/c/Backup_Go7/Books
```

If you know the exact staging directory:

```bash
./bin/merge_skeleton_into_books.sh \
    --source /mnt/c/Backup_Go7/BooksInput_20260912-072000 \
    --target /mnt/c/Backup_Go7/Books
```

When `--source` is omitted, the newest `BooksInput_*` directory under
`--output-root` is automatically selected.

### Destination wins

The final merge uses:

```text
rsync -a --ignore-existing
```

Therefore an existing file in `Books` is kept.

The staging tree remains intact after the merge.

### Empty-directory cleanup

After a successful real merge, empty directories are removed from `Books` as
a safety measure.

Disable this with:

```bash
--no-prune
```

The final step writes its own TSV report with statuses such as:

```text
copied
would-copy
kept-existing
would-keep
```

---

# 11. Step 8 — Check Collection Progress

Once books have been added to the library, run:

```bash
./bin/reconcile_library.sh
```

This compares:

```text
data/fixtures/authors_list_from_db.txt
```

against the actual `Books` tree.

It reports:

- recommended authors already represented in the collection;
- authors still to collect;
- catalog book counts when MariaDB is available;
- on-disk file counts;
- extra authors/books outside the recommended list.

### Generate the next shopping list

A normal run creates a file similar to:

```text
reconcile_to_collect_20260912-072000.txt
```

This contains recommended authors with no books on disk yet.

That file can be fed directly into the download-size estimator:

```bash
./bin/estimate_download_size.sh \
    --input-file /path/to/reconcile_to_collect_<timestamp>.txt
```

### Skip the database snapshot

```bash
./bin/reconcile_library.sh --no-db
```

### Dry run

```bash
./bin/reconcile_library.sh --dry-run
```

No report file is written.

---

# 12. Step 9 — Protect the MultiLib Personal Database

Before populating `myprivatelib`, make a backup.

The dedicated tool is:

```text
bin/backup_myprivatelib.sh
```

Default action:

```bash
./bin/backup_myprivatelib.sh
```

List existing backups:

```bash
./bin/backup_myprivatelib.sh list
```

Verify a backup:

```bash
./bin/backup_myprivatelib.sh verify \
    /path/to/myprivatelib_<timestamp>.sql.gz
```

The verification checks gzip integrity and dump sanity.

### Restore

```bash
./bin/backup_myprivatelib.sh restore \
    /path/to/myprivatelib_<timestamp>.sql.gz
```

A restore first protects the current state with a backup.

By default it refuses to overwrite a non-empty library.

Use:

```bash
./bin/backup_myprivatelib.sh \
    --force \
    restore /path/to/myprivatelib_<timestamp>.sql.gz
```

only when you deliberately want that behavior.

### Dry run

```bash
./bin/backup_myprivatelib.sh --dry-run
```

---

# 13. Step 10 — Populate `myprivatelib`

The population tool is:

```text
bin/populate_myprivatelib.sh
```

Run a dry run first:

```bash
./bin/populate_myprivatelib.sh --dry-run
```

Then perform the rebuild:

```bash
./bin/populate_myprivatelib.sh
```

The tool walks the on-disk `Books` collection and represents **only books that
are actually present there**.

It does not copy the complete Flibusta catalog into `myprivatelib`.

---

## 13.1 How Books Are Matched

Each book is matched against:

```text
flibusta.mlbook.md5
```

For:

```text
*.fb2
```

the file itself is hashed.

For zip-wrapped FB2 files, the decompressed FB2 content is hashed.

The MD5 value resolves the physical file to the catalog `bookid`.

This makes the catalog record the source of truth for the book identity.

---

## 13.2 Source Keys Are Preserved

The population tool does **not** generate new sequential IDs.

The Flibusta source keys are copied verbatim.

This includes:

- `bookid`;
- author relationship keys;
- genre relationship keys;
- series relationship keys;
- child primary keys such as `la_id`, `gn_id`, `sq_id`, `rt_id`, and `ci_id`.

The tool also removes `AUTO_INCREMENT` from the relevant target primary-key
columns before loading the source keys.

This is intentional and is required by the current MultiLib application
behavior.

---

## 13.3 Database Safety

Before any destructive reload, the tool verifies column parity for all managed
tables.

If the target schema does not match the expected schema, the run aborts before
`TRUNCATE`.

The actual rebuild is a clean purge-and-reload operation.

The tool manages the intended `myprivatelib` catalog tables but does not write
the `flibusta` source database.

---

## 13.4 Reference Tables

The personal database receives only the reference data required by its books:

```text
mlauthorname
mlgenrename
mlseqname
```

For genres, ancestor categories are included so that the MultiLib application
can render the genre tree correctly.

The source genre IDs and `parentgenreid` values are preserved.

`mlbook.filename` uses the **catalog filename**, not the physical Windows/WSL
path.

The physical archive member name and on-disk size are retained separately.

Ratings are copied from:

```text
flibusta.mlrating
```

`mlcoverpage` and `mldescription` remain empty in this phase.

---

## 13.5 Populate Reports

Each run writes a TSV report under the configured population report directory.

The report records which physical files were matched and which could not be
resolved against the catalog.

Investigate unmatched files rather than assuming they are harmless.

---

# 14. Step 11 — Refresh `myprivatelib` Automatically

Once the initial population works, use:

```bash
./bin/refresh_myprivatelib.sh
```

This is the recommended routine command when the Books collection changes.

The tool:

```text
fingerprint Books
      |
      v
compare checkpoint
      |
      +---- unchanged ---> do nothing
      |
      +---- changed -----> backup
                              |
                              v
                           populate
                              |
                              v
                         write checkpoint
```

The fingerprint records, for every file:

```text
relative path
size
mtime
```

and stores the result in deterministic order.

It deliberately does **not** rely on the mtime of the Books root directory,
because directory timestamps on Windows/WSL mounts may not reliably reflect
changes made below the root.

### Normal run

```bash
./bin/refresh_myprivatelib.sh
```

### Check status

```bash
./bin/refresh_myprivatelib.sh --status
```

### Dry run

```bash
./bin/refresh_myprivatelib.sh --dry-run
```

### Force refresh

```bash
./bin/refresh_myprivatelib.sh --force
```

### Important behavior

If nothing changed, the command exits successfully without touching the
database.

If backup or population fails, the previous checkpoint is retained.

This makes the command suitable for repeated or scheduled use.

---

# 15. Step 12 — Manage the Reading Wish List

`report_library.sh` maintains a personal reading plan independently of the
database population cycle.

The wish-list file is:

```text
data/wishlist.tsv
```

It is intentionally stored outside the database so that rebuilding
`myprivatelib` does not erase the reading plan.

Each entry contains:

```text
bookid
added
target_period
status
note
```

---

## 15.1 Search for a Book

Search the catalog by title or author:

```bash
./bin/report_library.sh --search piranha
```

Use the returned `bookid` when adding the book.

---

## 15.2 Add a Book

Example:

```bash
./bin/report_library.sh \
    --add 882939 \
    --period 2026-09 \
    --note "Piranha cycle"
```

The default status is:

```text
wish
```

---

## 15.3 Change Status

Available statuses:

```text
wish
reading
done
```

Examples:

```bash
./bin/report_library.sh --set-status 882939 reading
```

```bash
./bin/report_library.sh --set-status 882939 done
```

---

## 15.4 Remove an Entry

```bash
./bin/report_library.sh --remove 882939
```

---

## 15.5 List the Raw TSV

```bash
./bin/report_library.sh --list --no-db
```

This does not contact MariaDB.

---

## 15.6 Render the Reading Plan

```bash
./bin/report_library.sh
```

The normal view joins the wish-list book IDs against `myprivatelib` and shows
information such as:

- title;
- authors;
- series and position;
- rating;
- target period;
- reading status;
- completion totals.

Books that are planned but not yet present in `myprivatelib` are shown
separately.

---

## 15.7 Export the Reading Plan

Markdown:

```bash
./bin/report_library.sh --export md
```

TSV:

```bash
./bin/report_library.sh --export tsv
```

The export is written to the configured report/output directory.

---

## 15.8 Native MultiLib Wish Lists

The tool can also inspect the native application wish-list state:

```bash
./bin/report_library.sh --native
```

Other views include:

```bash
./bin/report_library.sh --native author
./bin/report_library.sh --native title
./bin/report_library.sh --native series
./bin/report_library.sh --native all
```

The native state is read-only.

---

## 15.9 Hybrid View

To combine the TSV reading plan with native MultiLib application state:

```bash
./bin/report_library.sh --hybrid
```

The hybrid view combines the two sources while preserving the TSV's periods
and notes.

Application state takes precedence for native status information.

---

# 16. Recommended Normal Workflow

For a new or substantially changed collection, use this sequence:

```text
1. Start / verify MariaDB
        |
        v
2. Export the recommended author list
        |
        v
3. Estimate download size
        |
        v
4. Prepare/download the archive
        |
        v
5. merge_books_into_skeleton.sh --dry-run
        |
        v
6. Review merge reports
        |
        v
7. merge_books_into_skeleton.sh
        |
        v
8. Inspect BooksInput_<timestamp>
        |
        v
9. merge_skeleton_into_books.sh --dry-run
        |
        v
10. merge_skeleton_into_books.sh
        |
        v
11. reconcile_library.sh
        |
        v
12. backup_myprivatelib.sh
        |
        v
13. populate_myprivatelib.sh --dry-run
        |
        v
14. populate_myprivatelib.sh
        |
        v
15. refresh_myprivatelib.sh for future changes
```

The reading-plan tool is independent and can be used at any time:

```text
report_library.sh --search
        |
        v
report_library.sh --add
        |
        v
report_library.sh
```

---

# 17. Recommended Safety Procedure

For anything that changes the library, use this pattern:

### First: inspect

```bash
./bin/<tool> --dry-run
```

### Second: review

Look at the generated report files.

### Third: make the change

Run the same command without `--dry-run`.

### Fourth: verify

Run the appropriate reporting or validation command.

For example:

```bash
./bin/merge_books_into_skeleton.sh ... --dry-run
```

then:

```bash
./bin/merge_books_into_skeleton.sh ...
```

then:

```bash
./bin/merge_skeleton_into_books.sh ... --dry-run
```

then:

```bash
./bin/merge_skeleton_into_books.sh ...
```

For database population:

```bash
./bin/backup_myprivatelib.sh
```

then:

```bash
./bin/populate_myprivatelib.sh --dry-run
```

then:

```bash
./bin/populate_myprivatelib.sh
```

---

# 18. Configuration

Most tools have a configuration file under:

```text
config/
```

Examples:

```text
config/merge_books.conf
config/merge_skeleton_into_books.conf
config/reconcile_library.conf
config/estimate_download_size.conf
config/backup_myprivatelib.conf
config/populate_myprivatelib.conf
config/refresh_myprivatelib.conf
config/report_library.conf
```

The general precedence is:

```text
command-line option
        >
environment variable
        >
configuration file
        >
built-in default
```

Therefore a command-line option is the safest way to override one setting for a
single run.

`--dry-run` is deliberately a command-line safety switch and is not intended to
be configured as a permanent default.

---

# 19. MariaDB Connection Settings

Database-related tools share the MariaDB connection contract.

Common settings include:

```text
MYSQL_CLIENT
MYSQL_HOST
MYSQL_PORT
MYSQL_USER
MYSQL_PASSWORD
MYSQL_DATABASE
MYSQL_EXTRA_ARGS
```

The password should be supplied through:

```bash
export MYSQL_PWD='your-password'
```

Do not put the database password directly on the command line.

The database tools share:

```text
lib/mariadb_lifecycle.sh
```

for server readiness and lifecycle handling.

A tool that starts MariaDB itself can shut it down again when finished; a server
that was already running is normally left alone.

---

# 20. Testing the Project

Every major tool has a regression suite.

Run the complete set from the project root.

UTF-8-sensitive suites should be run under WSL:

```bash
wsl.exe bash tests/test_build_prefix_table.sh
wsl.exe bash tests/test_build_shell_nested_authors.sh
wsl.exe bash tests/test_prefix_tree_visualizer.sh
wsl.exe bash tests/test_utf8_prefix_generator.sh
wsl.exe bash tests/test_e2e_pipeline.sh
wsl.exe bash tests/test_merge_books_into_skeleton.sh
wsl.exe bash tests/test_merge_skeleton_into_books.sh
```

The database/mock suites can run directly in a Unix-like environment:

```bash
bash tests/test_export_authors_from_db.sh
bash tests/test_reconcile_library.sh
bash tests/test_estimate_download_size.sh
bash tests/test_backup_myprivatelib.sh
bash tests/test_populate_myprivatelib.sh
bash tests/test_refresh_myprivatelib.sh
bash tests/test_report_library.sh
bash tests/test_version_sync.sh
```

A useful full check is:

```bash
for test in tests/test_*.sh; do
    echo "===== $test ====="
    bash "$test" || exit 1
done
```

For the UTF-8-sensitive tests, use WSL/Linux rather than MSYS/Git Bash.

The tests use temporary scratch locations and are intended not to modify the
repository's real data.

---

# 21. Version Management

Do not manually change a tool version in only one location.

Use:

```bash
./bin/bump-version.sh <tool> <new_version>
```

Example:

```bash
./bin/bump-version.sh build_shell_nested_authors 6.6.11
```

The project includes a version-sync test:

```bash
bash tests/test_version_sync.sh
```

This checks that the version remains synchronized between the tracked
locations.

---

# 22. Useful Command Reference

## Author list

```bash
./bin/export_authors_from_db.sh
./bin/export_authors_from_db.sh --dry-run
```

## Prefix table

```bash
./bin/build_prefix_table.sh \
    data/fixtures/authors_list_from_db.txt 5 \
    > tmp_SORTED_AUTHORS

./bin/prefix_table_integrity.sh \
    tmp_SORTED_AUTHORS 5

./bin/prefix_tree_visualizer.sh \
    tmp_SORTED_AUTHORS
```

## Nested directories

```bash
./bin/build_shell_nested_authors.sh \
    --input-file data/fixtures/authors_list_from_db.txt \
    --min-authors 10 \
    --max-prefix 5
```

## Estimate collection size

```bash
./bin/estimate_download_size.sh
```

## Merge archive

```bash
./bin/merge_books_into_skeleton.sh \
    --source /mnt/c/Backup_Go7/ToLoad \
    --input-file data/fixtures/authors_list_from_db.txt \
    --output-root /mnt/c/Backup_Go7 \
    --dry-run
```

## Finalize into Books

```bash
./bin/merge_skeleton_into_books.sh \
    --output-root /mnt/c/Backup_Go7 \
    --target /mnt/c/Backup_Go7/Books \
    --dry-run
```

## Collection progress

```bash
./bin/reconcile_library.sh
```

## Database backup

```bash
./bin/backup_myprivatelib.sh
./bin/backup_myprivatelib.sh list
```

## Populate personal database

```bash
./bin/populate_myprivatelib.sh --dry-run
./bin/populate_myprivatelib.sh
```

## Refresh database

```bash
./bin/refresh_myprivatelib.sh
./bin/refresh_myprivatelib.sh --status
./bin/refresh_myprivatelib.sh --dry-run
./bin/refresh_myprivatelib.sh --force
```

## Reading plan

```bash
./bin/report_library.sh --search <text>
./bin/report_library.sh --add <bookid> --period 2026-09
./bin/report_library.sh
./bin/report_library.sh --export md
```

---

# 23. Important Do / Do Not Rules

### Do

- Use WSL/Linux for UTF-8-sensitive scripts.
- Generate the author list from the database when the catalog changes.
- Run merge operations with `--dry-run` first.
- Review unmatched/collision/duplicate reports.
- Keep the original archive unchanged.
- Back up `myprivatelib` before rebuilding it.
- Use the MD5/catalog match as the source of book identity.
- Use `refresh_myprivatelib.sh` after the initial population when the Books
  tree is maintained incrementally.
- Keep the wish list in `data/wishlist.tsv`.

### Do not

- Do not use Git Bash/MSYS for the Cyrillic prefix-processing tools.
- Do not assume an existing filename is necessarily the same book merely
  because the filename matches.
- Do not use `--overwrite force` unless replacement is intentional.
- Do not populate `myprivatelib` before creating a backup.
- Do not manually invent replacement book IDs or relationship IDs.
- Do not expect `populate_myprivatelib.sh` to populate the entire Flibusta
  catalog.
- Do not store the wish list only inside the database; the TSV is deliberately
  outside the rebuild cycle.
- Do not mix scripts or SQL files from unrelated project revisions without
  checking compatibility.

---

# 24. Troubleshooting

## Cyrillic names look corrupted

You are probably running the scripts under a byte-oriented shell.

Use WSL:

```bash
wsl.exe bash
```

Then run the command from the WSL filesystem or a `/mnt/...` path.

---

## `rsync` is missing

Install it in WSL/Linux:

```bash
sudo apt update
sudo apt install rsync
```

Verify:

```bash
rsync --version
```

---

## `gawk` is missing

Install it:

```bash
sudo apt update
sudo apt install gawk
```

Verify:

```bash
gawk --version
```

---

## MariaDB is unavailable

Check:

```bash
mysql --version
```

Then verify the configured host/port and credentials.

The database tools share the MariaDB lifecycle helper, but a bad connection
configuration cannot be repaired automatically.

---

## Books are not being matched by `populate_myprivatelib.sh`

Check the population report for unmatched files.

The match is based on the MD5 of the actual FB2 content, not the filename.

A renamed book can still match correctly.

Conversely, a file with the expected filename but different content will not
necessarily match.

---

## The database population aborts before changing data

This can be intentional.

The population tool checks schema column parity before the destructive
`TRUNCATE` stage.

If the schema differs from what the tool expects, fix the schema mismatch first
rather than forcing the reload.

---

## `refresh_myprivatelib.sh` says "up to date"

That means the recursive Books fingerprint matches the saved checkpoint.

Use:

```bash
./bin/refresh_myprivatelib.sh --status
```

to inspect the checkpoint state.

Use:

```bash
./bin/refresh_myprivatelib.sh --force
```

only when a rebuild is intentionally required despite the checkpoint.

---

# 25. Project Documentation

For deeper technical details, consult:

```text
docs/MultiLib_Flibusta_DB.md
docs/REPRESENTATION_PLAN.md
docs/BOOK_LIBRARY_MERGE_PLAN.md
docs/Flibusta_DB_findings.txt
docs/NEXT.md
CHANGELOG.md
RELEASE_NOTES.md
```

The most important design document for the current archive-to-Books workflow is:

```text
docs/BOOK_LIBRARY_MERGE_PLAN.md
```

It describes the in-memory prefix tree, timestamped `BooksInput_*` staging
tree, duplicate/collision policy, rsync finalize stage, and safety checks.

The database reference is:

```text
docs/MultiLib_Flibusta_DB.md
```

It describes the shared `ml*` schema, relationships, genre tree, key strategy,
Flibusta catalog structure, and the personal-library representation.

---

# 26. Final Recommended Workflow

For everyday use, the following compact sequence is the most useful:

```bash
# 1. Refresh the recommended author list when the catalog changes.
./bin/export_authors_from_db.sh

# 2. Estimate the size before collecting books.
./bin/estimate_download_size.sh

# 3. Dry-run the archive merge.
./bin/merge_books_into_skeleton.sh \
    --source /mnt/c/Backup_Go7/ToLoad \
    --input-file data/fixtures/authors_list_from_db.txt \
    --output-root /mnt/c/Backup_Go7 \
    --dry-run

# 4. Perform the archive merge after reviewing the reports.
./bin/merge_books_into_skeleton.sh \
    --source /mnt/c/Backup_Go7/ToLoad \
    --input-file data/fixtures/authors_list_from_db.txt \
    --output-root /mnt/c/Backup_Go7

# 5. Dry-run the final merge.
./bin/merge_skeleton_into_books.sh \
    --output-root /mnt/c/Backup_Go7 \
    --target /mnt/c/Backup_Go7/Books \
    --dry-run

# 6. Finalize into Books.
./bin/merge_skeleton_into_books.sh \
    --output-root /mnt/c/Backup_Go7 \
    --target /mnt/c/Backup_Go7/Books

# 7. Review collection progress.
./bin/reconcile_library.sh

# 8. Protect the personal database.
./bin/backup_myprivatelib.sh

# 9. Dry-run database population.
./bin/populate_myprivatelib.sh --dry-run

# 10. Rebuild the personal database.
./bin/populate_myprivatelib.sh

# 11. From this point forward, let the refresh tool detect changes.
./bin/refresh_myprivatelib.sh
```

For the reading plan, use independently:

```bash
./bin/report_library.sh --search <title-or-author>
./bin/report_library.sh --add <bookid> --period 2026-09
./bin/report_library.sh
```

**The central safety rule is simple: dry-run first, review the reports, back up
the database before destructive work, and only then perform the real operation.**
