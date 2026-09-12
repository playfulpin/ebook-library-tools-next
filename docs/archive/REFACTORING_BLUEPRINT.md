# MultiLib_Utilities Repository Refactoring Blueprint

**Repository:** `playfulpin/MultiLib_Utilities`

**Proposed future name:** `ebook-library-tools`

**Refactoring type:** Controlled structural, naming, documentation, and
maintainability refactor

**Primary objective:** Improve the project's architecture and public interface
without rewriting its working algorithms or losing Git history.

---

# 1. Executive Decision

## Do NOT create a new repository

The existing repository should be retained.

The project already has:

* useful Git history;
* working regression tests;
* a meaningful `bin/`, `lib/`, `config/`, `data/`, `docs/`, and `tests/`
  structure;
* a functioning author-prefix toolchain;
* a functioning archive-to-Books workflow;
* database backup/population/refresh tools;
* a reading-list/reporting tool.

The main problem is that the project's terminology and filenames have not
caught up with its current architecture.

The safest strategy is:

```text
Current repository
        |
        v
Create refactoring branch
        |
        v
Inventory dependencies
        |
        v
Rename public commands
        |
        v
Remove obsolete terminology
        |
        v
Clean internal modules
        |
        v
Update tests
        |
        v
Update documentation
        |
        v
Full regression test
        |
        v
Merge to main
        |
        v
Rename GitHub repository
```

The result should feel like a new project while preserving the original
repository history.

---

# 2. Current Project Identity

The current GitHub repository is:

```text
playfulpin/MultiLib_Utilities
```

The current project describes itself as utilities for preparing and cleaning
data for MultiLib.

That description is now too narrow.

The project has evolved into a toolchain for:

```text
catalog metadata
       |
       v
author selection
       |
       v
book archive organization
       |
       v
personal Books library
       |
       v
personal-library database
       |
       v
collection synchronization
       |
       v
reading-plan/reporting
```

The project therefore deserves a more descriptive identity.

---

# 3. Proposed Repository Name

## Preferred

```text
ebook-library-tools
```

This is my preferred name.

It describes what the project actually does without tying the project forever
to one particular database application.

## Alternative

```text
multilib-library-tools
```

Use this if MultiLib is expected to remain the project's permanent primary
target.

## Names I would avoid

```text
MultiLib_Utilities
multilib-utils
multilib-tools
library-utils
book-utils
book-scripts
```

These are either too generic or preserve the current ambiguity.

---

# 4. Why `ebook-library-tools`

The project is not merely a collection of unrelated utilities.

It has several coherent responsibilities:

```text
Authors
Books
Library
Catalog
Database
Reports
```

The common purpose is:

> Maintain a personal ebook library using catalog metadata and local book
> archives.

MultiLib and Flibusta can then be treated as integrations rather than defining
the entire identity of the project.

This also gives the project room to support another catalog or personal-library
backend later.

---

# 5. Most Important Architectural Problem

The word:

```text
skeleton
```

is obsolete in the current implementation.

The historical architecture appears to have been:

```text
author list
    |
    v
Empty_Skeleton
    |
    v
BooksInput
    |
    v
Books
```

The current implementation is actually:

```text
author list
    |
    v
in-memory prefix tree
    |
    v
BooksInput_<timestamp>
    |
    v
Books
```

The GitHub documentation explicitly describes the current merge operation as
using an in-memory author-prefix hierarchy and producing a timestamped
`BooksInput_*` staging tree without building or consuming an on-disk skeleton.

Therefore the word `skeleton` should disappear from the active public API.

---

# 6. Public Naming Convention

Use:

```text
<object>_<operation>.sh
```

Examples:

```text
authors_export.sh
authors_prefix_build.sh
books_merge.sh
books_finalize.sh
library_backup.sh
library_refresh.sh
```

This convention gives every command two pieces of information:

```text
WHAT does it operate on?
WHAT does it do?
```

---

# 7. Complete Script Rename Map

| Current                         | Proposed                  | Priority     |
| ------------------------------- | ------------------------- | ------------ |
| `export_authors_from_db.sh`     | `authors_export.sh`       | High         |
| `build_prefix_table.sh`         | `authors_prefix_build.sh` | High         |
| `prefix_table_integrity.sh`     | `authors_prefix_check.sh` | High         |
| `prefix_tree_visualizer.sh`     | `authors_prefix_tree.sh`  | High         |
| `build_shell_nested_authors.sh` | `authors_tree_build.sh`   | High         |
| `merge_books_into_skeleton.sh`  | `books_merge.sh`          | **Critical** |
| `merge_skeleton_into_books.sh`  | `books_finalize.sh`       | **Critical** |
| `estimate_download_size.sh`     | `books_estimate.sh`       | Medium       |
| `reconcile_library.sh`          | `books_reconcile.sh`      | Medium       |
| `backup_myprivatelib.sh`        | `library_backup.sh`       | Medium       |
| `populate_myprivatelib.sh`      | `library_populate.sh`     | Medium       |
| `refresh_myprivatelib.sh`       | `library_refresh.sh`      | Medium       |
| `report_library.sh`             | `library_report.sh`       | Medium       |
| `bump-version.sh`               | `version_bump.sh`         | Low          |

---

# 8. Final `bin/` Layout

Keep the executable directory flat.

Do NOT initially create:

```text
bin/authors/
bin/books/
bin/library/
```

Instead:

```text
bin/
├── authors_export.sh
├── authors_prefix_build.sh
├── authors_prefix_check.sh
├── authors_prefix_tree.sh
├── authors_tree_build.sh
│
├── books_estimate.sh
├── books_merge.sh
├── books_finalize.sh
├── books_reconcile.sh
│
├── library_backup.sh
├── library_populate.sh
├── library_refresh.sh
├── library_report.sh
│
└── version_bump.sh
```

The prefixes already provide the logical grouping.

---

# 9. Functional Groups

The command-line interface should be organized conceptually into four groups.

## AUTHORS

```text
authors_export.sh
authors_prefix_build.sh
authors_prefix_check.sh
authors_prefix_tree.sh
authors_tree_build.sh
```

Responsibilities:

* obtain the canonical author list;
* generate prefix information;
* validate prefix information;
* visualize the prefix tree;
* generate nested author-directory structures.

---

## BOOKS

```text
books_estimate.sh
books_merge.sh
books_finalize.sh
books_reconcile.sh
```

Responsibilities:

* estimate the size of the next collection round;
* merge an external archive into a staging tree;
* finalize staging into the Books library;
* reconcile the Books library against the recommended author set.

---

## LIBRARY

```text
library_backup.sh
library_populate.sh
library_refresh.sh
library_report.sh
```

Responsibilities:

* protect the personal database;
* populate the personal database from Books;
* detect changes and refresh the personal database;
* maintain/report the reading plan.

---

## MAINTENANCE

```text
version_bump.sh
```

Responsibilities:

* synchronize versions;
* maintain release metadata.

---

# 10. Proposed Top-Level Structure

The final project should look approximately like:

```text
ebook-library-tools/
│
├── .github/
│   └── workflows/
│
├── bin/
│   ├── authors_export.sh
│   ├── authors_prefix_build.sh
│   ├── authors_prefix_check.sh
│   ├── authors_prefix_tree.sh
│   ├── authors_tree_build.sh
│   │
│   ├── books_estimate.sh
│   ├── books_merge.sh
│   ├── books_finalize.sh
│   ├── books_reconcile.sh
│   │
│   ├── library_backup.sh
│   ├── library_populate.sh
│   ├── library_refresh.sh
│   ├── library_report.sh
│   │
│   └── version_bump.sh
│
├── config/
│
├── data/
│   ├── fixtures/
│   ├── sql/
│   ├── reports/
│   ├── backups/
│   └── wishlist.tsv
│
├── docs/
│   ├── UserGuide.md
│   ├── REFACTORING_BLUEPRINT.md
│   ├── BOOK_LIBRARY_MERGE_PLAN.md
│   ├── MultiLib_Flibusta_DB.md
│   └── ...
│
├── lib/
│
├── tests/
│
├── .gitignore
├── CHANGELOG.md
├── LICENSE
├── README.md
└── RELEASE_NOTES.md
```

---

# 11. `data/` Refactoring

The current `data/` directory should clearly distinguish controlled input from
generated data.

Recommended:

```text
data/
├── fixtures/
│   └── authors_list_from_db.txt
│
├── sql/
│   ├── qry_authors_4_and_5_all.sql
│   └── ...
│
├── reports/
│   ├── merge/
│   ├── reconcile/
│   ├── estimate/
│   └── library/
│
├── backups/
│   └── myprivatelib/
│
└── wishlist.tsv
```

The conceptual distinction should be:

```text
fixtures/ = controlled project inputs
sql/      = tracked SQL definitions
reports/  = generated reports
backups/  = generated database backups
wishlist  = persistent user-owned data
```

Generated reports and backups should not normally be committed.

---

# 12. `wishlist.tsv`

Keep:

```text
data/wishlist.tsv
```

outside the database.

This is an important architectural decision.

The personal database is rebuilt using a purge/reload operation, while the
reading plan must survive database rebuilds.

Therefore:

```text
Books database
      |
      | rebuildable
      v
myprivatelib

Reading plan
      |
      | persistent
      v
data/wishlist.tsv
```

Do not move the wish list into the database merely to make the structure look
cleaner.

---

# 13. Configuration Architecture

The configuration system should retain the current precedence:

```text
command line
      >
environment
      >
configuration file
      >
built-in default
```

This is a good model and should not be changed casually.

Possible conceptual configuration files:

```text
config/
├── authors.conf
├── books.conf
├── library.conf
└── database.conf
```

However, do not merge existing configuration files simply to reduce the number
of files.

If separate files make individual tools easier to configure, retain them.

The refactor should improve clarity, not introduce unnecessary indirection.

---

# 14. Database Naming

Do not rename the actual schema:

```text
myprivatelib
```

That is an implementation/database name.

It should remain in:

```text
SQL
configuration
database diagnostics
technical documentation
```

But user-facing command names should describe the logical object:

```text
library_backup.sh
library_populate.sh
library_refresh.sh
```

This gives the project freedom to change the database implementation later.

---

# 15. Proposed `lib/` Architecture

The current library files should first be analyzed for dependencies.

Do not blindly merge them.

A possible target architecture is:

```text
lib/
├── common.sh
├── cli.sh
├── logging.sh
├── filesystem.sh
├── authors.sh
├── books.sh
├── library.sh
├── database.sh
├── mariadb_lifecycle.sh
└── reporting.sh
```

This is a target architecture, not a requirement that every current file be
renamed or merged.

---

# 16. `common.sh`

Possible contents:

```text
error handling
exit helpers
command detection
temporary directory helpers
timestamp helpers
boolean parsing
dry-run helpers
```

Examples of genuinely common functions:

```bash
die()
require_command()
timestamp_now()
is_true()
```

Do not put domain-specific logic here.

---

# 17. `logging.sh`

Centralize genuinely shared logging behavior.

Possible responsibilities:

```text
log_info()
log_warn()
log_error()
log_debug()
```

Do not force every script to use an elaborate logging abstraction if simple
stderr output is clearer.

---

# 18. `filesystem.sh`

Possible shared operations:

```text
path validation
directory creation
safe temporary directories
file existence checks
relative path calculation
file metadata
```

Keep archive-specific logic in `books.sh`.

---

# 19. `authors.sh`

Potential shared author-tree functionality:

```text
author-list validation
UTF-8 prefix handling
prefix-tree generation
prefix resolution
author-name normalization
```

The author-prefix algorithm should have one conceptual implementation.

The current project has both an AWK reference implementation and Bash
implementations. Keep the AWK implementation as a parity/reference tool rather
than accidentally maintaining two unrelated production algorithms.

---

# 20. `books.sh`

Potential shared book operations:

```text
archive scanning
author-folder discovery
staging path calculation
book-file filtering
metadata exclusion
collision handling
```

The actual archive merge and finalization commands remain separate.

---

# 21. `library.sh`

Potential personal-library operations:

```text
Books tree fingerprint
library state detection
library report helpers
wish-list helpers
```

---

# 22. `database.sh`

Potential database abstraction:

```text
connection setup
query execution
database existence checks
schema checks
transaction helpers
```

The specialized MariaDB lifecycle logic should remain in:

```text
mariadb_lifecycle.sh
```

---

# 23. Preserve `mariadb_lifecycle.sh`

This is already a useful architectural boundary.

The current tools share MariaDB lifecycle and `MYSQL_*` handling. Keep that
centralized rather than duplicating it across every database script.

---

# 24. Rename `reconcile_library.sh` Carefully

I recommend:

```text
books_reconcile.sh
```

because the primary object being reconciled is:

```text
recommended author scope
          vs.
physical Books collection
```

However, this script is also a higher-level collection-progress report.

If after inspection its responsibilities are broader than Books, an alternative
is:

```text
library_reconcile.sh
```

This is one rename I would decide only after reviewing the internal functions.

---

# 25. Rename `report_library.sh` Carefully

The current tool is primarily a reading-plan/wish-list tool.

A potentially better name is:

```text
library_report.sh
```

but an even more descriptive future name could be:

```text
library_reading_plan.sh
```

I recommend:

```text
library_report.sh
```

for now because the command already includes searching, mutations, native
state, hybrid views, and exports.

If its functionality remains focused on the wish list, a later rename to
`library_reading_plan.sh` would be reasonable.

---

# 26. Main Book Pipeline

The final documented workflow should be:

```text
1. Export author list
        |
        v
2. Estimate next collection
        |
        v
3. Merge archive
        |
        v
4. Review staging tree
        |
        v
5. Finalize into Books
        |
        v
6. Reconcile collection
        |
        v
7. Backup personal database
        |
        v
8. Populate personal database
        |
        v
9. Refresh automatically in the future
```

Commands:

```bash
./bin/authors_export.sh

./bin/books_estimate.sh

./bin/books_merge.sh

./bin/books_finalize.sh

./bin/books_reconcile.sh

./bin/library_backup.sh

./bin/library_populate.sh

./bin/library_refresh.sh
```

---

# 27. `books_merge.sh`

The renamed command should retain the current behavior.

It should:

1. read the canonical author list;
2. build the prefix hierarchy in memory;
3. inspect the source archive;
4. resolve authors;
5. create only directories receiving files;
6. copy to `BooksInput_<timestamp>`;
7. produce TSV reports;
8. never modify the source archive.

The existing safety model should remain unchanged.

---

# 28. `books_finalize.sh`

The renamed finalization command should:

1. identify a `BooksInput_*` staging tree;
2. validate the source;
3. validate the Books target;
4. perform rsync;
5. preserve existing destination files;
6. write a per-file TSV report;
7. optionally prune empty destination directories;
8. retain the staging tree.

The current use of rsync is preferable to reimplementing file-copy semantics
in Bash.

---

# 29. Safety Contract

The refactor must preserve these principles:

```text
source archive is never modified
destination wins by default
dry-run changes nothing
database is backed up before destructive reload
schema mismatch aborts before TRUNCATE
failed refresh does not update checkpoint
wish list survives database rebuild
```

These should become explicit project design principles.

---

# 30. `--dry-run`

`--dry-run` should remain a command-line safety switch.

Do not make it configurable through normal configuration files.

This is a good design choice because a configuration file should not
accidentally cause a supposedly destructive command to silently become a
simulation.

---

# 31. Database Population

Do not change the current data model during this refactor.

The current design has several important properties:

```text
physical Books files
        |
        v
MD5 of actual book content
        |
        v
flibusta.mlbook.md5
        |
        v
source bookid
        |
        v
myprivatelib
```

Source IDs are preserved rather than regenerated.

`AUTO_INCREMENT` behavior is deliberately removed from the relevant personal
library schema columns.

Foreign-key/reference integrity is explicitly verified.

These are architectural behaviors, not naming details.

They should not be changed during the refactor.

---

# 32. Database Backup

The command:

```text
library_backup.sh
```

should retain:

```text
backup
list
verify
restore
```

operations.

The backup must remain the safety gate before a destructive population.

---

# 33. Database Refresh

The command:

```text
library_refresh.sh
```

should retain the current state machine:

```text
calculate Books fingerprint
        |
        v
compare checkpoint
        |
        +---- unchanged ---> exit successfully
        |
        +---- changed
                 |
                 v
               backup
                 |
                 v
              populate
                 |
                 v
          write checkpoint
```

Do not simplify this to a root-directory mtime check.

The current recursive fingerprint approach exists specifically because directory
timestamps on Windows/WSL mounts are insufficient.

---

# 34. Testing Architecture

The current repository already has separate tests for the major tools and an
end-to-end pipeline.

That is good and should be retained.

The test naming should follow executable naming.

Examples:

```text
test_build_prefix_table.sh
    ->
test_authors_prefix_build.sh

test_prefix_tree_visualizer.sh
    ->
test_authors_prefix_tree.sh

test_build_shell_nested_authors.sh
    ->
test_authors_tree_build.sh

test_merge_books_into_skeleton.sh
    ->
test_books_merge.sh

test_merge_skeleton_into_books.sh
    ->
test_books_finalize.sh

test_reconcile_library.sh
    ->
test_books_reconcile.sh

test_estimate_download_size.sh
    ->
test_books_estimate.sh

test_backup_myprivatelib.sh
    ->
test_library_backup.sh

test_populate_myprivatelib.sh
    ->
test_library_populate.sh

test_refresh_myprivatelib.sh
    ->
test_library_refresh.sh

test_report_library.sh
    ->
test_library_report.sh
```

---

# 35. Test Execution

The final test matrix should remain explicit.

UTF-8/WSL tests:

```bash
wsl.exe bash tests/test_authors_prefix_build.sh
wsl.exe bash tests/test_authors_tree_build.sh
wsl.exe bash tests/test_authors_prefix_tree.sh
wsl.exe bash tests/test_utf8_prefix_generator.sh
wsl.exe bash tests/test_e2e_pipeline.sh
wsl.exe bash tests/test_books_merge.sh
wsl.exe bash tests/test_books_finalize.sh
```

Database/mock tests:

```bash
bash tests/test_authors_export.sh
bash tests/test_books_reconcile.sh
bash tests/test_books_estimate.sh
bash tests/test_library_backup.sh
bash tests/test_library_populate.sh
bash tests/test_library_refresh.sh
bash tests/test_library_report.sh
bash tests/test_version_sync.sh
```

---

# 36. Test Baseline

Before starting:

```bash
git checkout main
git pull
```

Run the existing suite.

Record:

```text
pass/fail status
test count
known failures
current version
```

Do not start the rename until the baseline is known.

If a test is already failing, fix or document that failure first.

Otherwise it will be impossible to determine whether the refactor introduced
the failure.

---

# 37. Git Branch

Create:

```bash
git checkout -b refactor/project-naming
```

Do not perform the entire refactor directly on `main`.

---

# 38. Git Rename Rules

Use:

```bash
git mv
```

rather than deleting and recreating files.

Example:

```bash
git mv \
    bin/merge_books_into_skeleton.sh \
    bin/books_merge.sh
```

This preserves the intent of the rename in Git history.

---

# 39. Do Not Perform a Mass Rename Blindly

Do not do:

```text
rename everything
      |
      v
hope grep finds everything
```

Instead:

```text
rename one logical group
      |
      v
update references
      |
      v
run tests
      |
      v
commit
```

This makes regressions much easier to diagnose.

---

# 40. Recommended Commit Sequence

Use small, focused commits.

```text
test: establish clean baseline

refactor: document current command dependencies

rename: merge_books_into_skeleton to books_merge

rename: merge_skeleton_into_books to books_finalize

rename: author prefix commands

rename: author tree command

rename: library commands

rename: test scripts

refactor: remove obsolete skeleton terminology

refactor: consolidate common shell helpers

refactor: clean configuration

docs: rewrite README

docs: update UserGuide

test: complete regression suite

chore: prepare repository rename
```

Do not combine all of this into one giant commit.

---

# 41. Search Strategy

After every rename group, search for stale names.

For example:

```bash
grep -RIn \
    --exclude-dir=.git \
    "merge_books_into_skeleton" .
```

Then:

```bash
grep -RIn \
    --exclude-dir=.git \
    "merge_skeleton_into_books" .
```

Finally:

```bash
grep -RIn \
    --exclude-dir=.git \
    "skeleton" .
```

Every remaining active-code occurrence should be intentional.

---

# 42. Compatibility Wrappers

If users or scripts already depend on the old command names, temporary wrappers
may be used.

Example:

```bash
#!/usr/bin/env bash

exec "$(dirname "$0")/books_merge.sh" "$@"
```

Possible deprecated wrappers:

```text
merge_books_into_skeleton.sh
merge_skeleton_into_books.sh
```

Mark them:

```text
DEPRECATED
Use books_merge.sh instead.
```

Do not keep compatibility wrappers forever.

Remove them after a deliberate transition period.

---

# 43. Versioning During the Refactor

Do not use a normal feature version bump for every rename.

The entire refactor should culminate in a clearly identifiable release.

For example:

```text
6.x
```

for the current project line, followed by:

```text
7.0.0
```

if the public command names are intentionally breaking changes.

Whether the actual major version should change depends on the project's
current versioning policy.

The important principle is:

> Renaming executable commands is a user-facing breaking change.

---

# 44. Version Synchronization

Retain the existing version synchronization mechanism.

Do not manually edit version numbers in multiple locations.

Continue using the project's version-bump mechanism, after adapting it to the
new script names.

The version-sync test should remain mandatory.

---

# 45. README Rewrite

The README should no longer lead with implementation history.

Recommended structure:

```text
# ebook-library-tools

## Overview

## What it does

## Features

## Architecture

## Requirements

## Installation

## Quick Start

## Command Reference

### Authors

### Books

### Library

## Typical Workflow

## Safety

## Database Integration

## Testing

## Configuration

## Documentation

## License
```

---

# 46. README Opening

The first paragraph should communicate the project in one sentence.

Recommended concept:

```text
ebook-library-tools is a collection of Bash and AWK utilities for maintaining
a personal ebook library from catalog metadata and local book archives.
```

Then immediately explain:

```text
The current implementation integrates with Flibusta catalog data and the
MultiLib personal-library database.
```

---

# 47. User Guide

`docs/UserGuide.md` should remain the detailed operational manual.

It should explain the workflow in the order a user actually performs it:

```text
1. prerequisites
2. configuration
3. author list
4. estimate
5. archive merge
6. finalization
7. reconciliation
8. database backup
9. database population
10. automatic refresh
11. reading plan
12. troubleshooting
```

The guide we just created for the current project can become the basis for this
document after command names stabilize.

---

# 48. Architecture Documentation

Keep:

```text
docs/BOOK_LIBRARY_MERGE_PLAN.md
```

but update terminology.

Replace obsolete concepts:

```text
Empty_Skeleton
```

with:

```text
in-memory author-prefix tree
```

and:

```text
staging tree
```

where appropriate.

Keep implementation details that remain useful.

---

# 49. Historical Documentation

Do not rewrite history out of existence.

If an old document describes the former skeleton architecture, it can remain
as a historical/design record.

However, clearly mark it:

```text
Historical architecture
```

or:

```text
Superseded by the current staging-tree implementation.
```

This is preferable to silently rewriting history.

---

# 50. `.gitignore`

Review `.gitignore` carefully.

It should exclude generated data such as:

```text
temporary files
scratch prefix tables
generated reports
database backups
BooksInput staging trees
local environment/configuration overrides
```

Do not ignore controlled fixtures or SQL definitions that are intentionally
part of the repository.

---

# 51. CI

Review GitHub Actions after renaming.

Look for:

```text
script paths
test paths
working directories
shell selection
WSL assumptions
Ubuntu dependencies
```

The CI pipeline should use the new command names.

Do not introduce a new CI system during this refactor.

---

# 52. WSL Requirement

The project has a real UTF-8 environment constraint.

The documentation currently explains that a multibyte-capable Bash is required
and that MSYS/Cygwin Bash is rejected by the relevant suites.

Preserve that requirement.

State it prominently:

```text
UTF-8-sensitive tools require WSL/Linux.
```

Do not "fix" this by replacing the existing algorithms during the naming
refactor.

---

# 53. AWK Parity Tool

The original:

```text
lib/utf8_prefix_generator.awk
```

should remain as a parity/reference implementation if the tests depend on it.

Possible future name:

```text
lib/utf8_prefix_reference.awk
```

but this is **low priority**.

Do not rename it until the main command rename is complete.

Its role should be documented as:

```text
reference/parity implementation
```

rather than a second independent production implementation.

---

# 54. Archive Merge Reports

Keep the existing report concepts:

```text
merge-manifest.tsv
unmatched-authors.tsv
ambiguous-authors.tsv
collisions.tsv
duplicates.tsv
skipped-files.tsv
```

These are valuable operational artifacts.

If report directories are reorganized, update configuration and documentation
without changing report semantics.

---

# 55. Books Staging Naming

Keep:

```text
BooksInput_<timestamp>
```

This is a useful name.

It clearly communicates:

```text
BooksInput = not yet final
timestamp  = distinct operation
```

Do not rename it to something more abstract unless a strong reason emerges.

---

# 56. Books Final Directory

Keep:

```text
Books
```

This is concise and user-friendly.

The terminology becomes:

```text
source archive
        |
        v
BooksInput_<timestamp>
        |
        v
Books
```

This is much clearer than:

```text
source
        |
        v
skeleton
        |
        v
Books
```

---

# 57. Collection Reconciliation

The command should answer:

```text
What authors should I collect?
What have I already collected?
What remains?
What is outside the recommended list?
```

The generated next-round file:

```text
reconcile_to_collect_<timestamp>.txt
```

should remain compatible with the download-size estimator and merge pipeline.

If renamed later, maintain that compatibility deliberately.

---

# 58. Download Estimation

`books_estimate.sh` should remain a planning tool.

It should not perform downloads.

Its responsibility is:

```text
catalog
   |
   v
selected authors
   |
   v
book-size aggregation
   |
   v
collection estimate
```

This separation should remain explicit.

---

# 59. Reading Plan

The reading plan remains logically independent:

```text
data/wishlist.tsv
```

The command:

```text
library_report.sh
```

can read database metadata but must not depend on database rebuilds to preserve
the wish list.

This is an important architectural boundary.

---

# 60. Security / Credential Rules

Preserve the existing database credential contract.

Passwords should not appear in:

```text
command arguments
logs
reports
Git-tracked configuration
```

Continue using:

```text
MYSQL_PWD
```

or another secure client mechanism as appropriate.

The refactor must not accidentally expose credentials through new logging or
debug output.

---

# 61. What NOT to Change

The following are explicitly out of scope for the first refactor:

```text
database schema redesign
MD5 matching redesign
Flibusta schema changes
MultiLib relationship redesign
book-directory semantics
duplicate policy
source-key strategy
AUTO_INCREMENT strategy
Bash -> Python rewrite
Bash -> another shell rewrite
test framework replacement
complete configuration redesign
```

These can be separate future projects.

---

# 62. Refactor Risk Levels

## Low risk

```text
README wording
documentation
test filenames
Git-aware file renames
comments
obsolete terminology
```

## Medium risk

```text
configuration file names
shared helper consolidation
variable renaming
function renaming
report directory changes
```

## High risk

```text
database logic
MD5 matching
schema generation
relationship IDs
AUTO_INCREMENT behavior
archive-copy semantics
Books merge algorithm
```

The high-risk areas should remain untouched during the naming refactor.

---

# 63. Estimated Effort

| Task                          |    Estimate |
| ----------------------------- | ----------: |
| Repository inventory          |       1–2 h |
| Dependency mapping            |       1–3 h |
| Script renames                |       1–2 h |
| Reference updates             |       2–4 h |
| Terminology cleanup           |       2–4 h |
| Shared-library cleanup        |       3–6 h |
| Configuration cleanup         |       1–3 h |
| Test updates                  |       2–4 h |
| README/UserGuide              |       3–5 h |
| Regression testing            |       3–6 h |
| GitHub rename/release cleanup |        <1 h |
| **Total**                     | **18–40 h** |

The lower end assumes the current internal dependencies are already clean.

The upper end allows for hidden coupling discovered during the inventory.

---

# 64. Recommended Milestones

## Milestone 1 — Baseline

```text
existing repository
existing tests
known-good state
```

Deliverable:

```text
baseline test report
```

---

## Milestone 2 — Public command rename

Deliverable:

```text
new bin/ names
new test names
no stale active references
```

---

## Milestone 3 — Terminology cleanup

Deliverable:

```text
no obsolete "skeleton" terminology in active code
```

except explicitly historical documentation.

---

## Milestone 4 — Internal library cleanup

Deliverable:

```text
clear common/domain-specific boundaries
```

---

## Milestone 5 — Documentation

Deliverable:

```text
README.md
docs/UserGuide.md
architecture documents
```

all using the new vocabulary.

---

## Milestone 6 — Release candidate

Deliverable:

```text
complete regression pass
clean Git diff
clean working tree
```

---

## Milestone 7 — Repository rename

Only now:

```text
playfulpin/MultiLib_Utilities
        |
        v
playfulpin/ebook-library-tools
```

---

# 65. Final Repository Identity

The preferred result is:

```text
ebook-library-tools/
```

with:

```text
Authors
Books
Library
Catalog
MultiLib
Flibusta
```

as the major concepts.

The repository description should be approximately:

```text
Bash and AWK tools for maintaining a personal ebook library from catalog
metadata and local book archives.
```

---

# 66. Final Command Interface

The final user-facing command set should be:

```text
AUTHORS

authors_export.sh
authors_prefix_build.sh
authors_prefix_check.sh
authors_prefix_tree.sh
authors_tree_build.sh


BOOKS

books_estimate.sh
books_merge.sh
books_finalize.sh
books_reconcile.sh


LIBRARY

library_backup.sh
library_populate.sh
library_refresh.sh
library_report.sh


MAINTENANCE

version_bump.sh
```

This is the interface a new user should learn.

The internal implementation can evolve independently.

---

# 67. Final Recommended Workflow

The finished project should communicate this workflow:

```text
                 AUTHORS
                    |
                    v
          authors_export.sh
                    |
                    v
          books_estimate.sh
                    |
                    v
               source archive
                    |
                    v
             books_merge.sh
                    |
                    v
          BooksInput_<timestamp>
                    |
                    v
           books_finalize.sh
                    |
                    v
                  Books
                    |
                    v
          books_reconcile.sh
                    |
                    v
             collection plan
                    |
                    v
          library_backup.sh
                    |
                    v
         library_populate.sh
                    |
                    v
             myprivatelib
                    |
                    v
          library_refresh.sh
```

The reading plan operates independently:

```text
data/wishlist.tsv
        |
        v
library_report.sh
```

---

# 68. Recommended First Implementation Session

Do not start by changing code.

First do:

```bash
git checkout main
git pull

git status

git checkout -b refactor/project-naming
```

Then run the current tests.

Next create an inventory:

```bash
find bin lib config tests docs -type f | sort
```

Then search references:

```bash
grep -RIn --exclude-dir=.git \
    -E \
    'export_authors_from_db|build_prefix_table|prefix_table_integrity|prefix_tree_visualizer|build_shell_nested_authors|merge_books_into_skeleton|merge_skeleton_into_books|estimate_download_size|reconcile_library|backup_myprivatelib|populate_myprivatelib|refresh_myprivatelib|report_library|bump-version' \
    .
```

Then separately:

```bash
grep -RIn --exclude-dir=.git "skeleton" .
```

Do not change anything until this inventory has been reviewed.

---

# 69. The First Two Renames

I recommend beginning with the two clearest cases:

```bash
git mv \
    bin/merge_books_into_skeleton.sh \
    bin/books_merge.sh

git mv \
    bin/merge_skeleton_into_books.sh \
    bin/books_finalize.sh
```

Then update:

```text
README
UserGuide
tests
configuration
comments
usage text
references
```

Run only the affected tests.

Commit:

```text
rename: replace obsolete skeleton merge commands
```

This establishes the new terminology before touching the rest of the project.

---

# 70. The Second Rename Group

Then:

```text
build_prefix_table.sh
    ->
authors_prefix_build.sh

prefix_table_integrity.sh
    ->
authors_prefix_check.sh

prefix_tree_visualizer.sh
    ->
authors_prefix_tree.sh

build_shell_nested_authors.sh
    ->
authors_tree_build.sh
```

Commit:

```text
rename: standardize author tool commands
```

---

# 71. The Third Rename Group

Then:

```text
export_authors_from_db.sh
    ->
authors_export.sh

estimate_download_size.sh
    ->
books_estimate.sh

reconcile_library.sh
    ->
books_reconcile.sh
```

Commit:

```text
rename: standardize catalog and collection commands
```

---

# 72. The Fourth Rename Group

Then:

```text
backup_myprivatelib.sh
    ->
library_backup.sh

populate_myprivatelib.sh
    ->
library_populate.sh

refresh_myprivatelib.sh
    ->
library_refresh.sh

report_library.sh
    ->
library_report.sh
```

Commit:

```text
rename: standardize personal library commands
```

---

# 73. Maintenance Rename

Finally:

```text
bump-version.sh
    ->
version_bump.sh
```

Commit:

```text
rename: standardize maintenance command
```

---

# 74. Final Terminology Pass

Run:

```bash
grep -RIn --exclude-dir=.git "skeleton" .
```

Classify every result:

```text
active implementation -> eliminate
active documentation   -> eliminate
historical document    -> may retain with explicit historical context
test fixture           -> review
Git history            -> irrelevant
```

Then update the terminology throughout the project.

---

# 75. Final Acceptance Criteria

The refactor is complete only when all of the following are true.

## Naming

```text
all public scripts use the new naming convention
no active command contains "skeleton"
```

## References

```text
no stale script references
no broken configuration references
no broken test references
no stale README commands
```

## Tests

```text
all regression tests pass
UTF-8 tests pass under WSL
end-to-end test passes
database mock tests pass
version synchronization passes
```

## Behavior

```text
archive source remains protected
destination-wins behavior remains unchanged
dry-run remains safe
database backup remains mandatory
MD5 matching remains unchanged
source IDs remain unchanged
refresh checkpoint behavior remains unchanged
wish list remains independent
```

## Documentation

```text
README describes current architecture
UserGuide uses current commands
merge design document uses current terminology
database documentation remains accurate
```

## Git

```text
working tree clean
refactor commits logically separated
no generated files accidentally committed
```

---

# 76. Final Decision

The project should **not** be restarted as a new repository.

The correct approach is:

```text
preserve history
      +
rename deliberately
      +
remove obsolete concepts
      +
clarify architecture
      +
preserve behavior
      +
test aggressively
      =
new-quality project
```

The most important changes are:

```text
MultiLib_Utilities
        |
        v
ebook-library-tools

merge_books_into_skeleton.sh
        |
        v
books_merge.sh

merge_skeleton_into_books.sh
        |
        v
books_finalize.sh
```

Everything else should follow the same principle:

> **Name the tool according to what it does today, not according to how it
> happened to work during an earlier stage of the project's development.**

This approach preserves the project's valuable Git history while giving it a
clean, coherent public interface and a much stronger foundation for future
development.
