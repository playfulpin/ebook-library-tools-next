# ARCHITECTURE — ebook-library-tools

> **Version:** 1.0.0
> **Created:** 2026-09-12 (distilled from the ratified `docs/PHASE_02_TARGET_ARCHITECTURE.md`, D-02.12)
> **Status:** **authoritative.** This is the permanent architecture reference. When reality
> changes, change this document in the same commit. Historical reasoning lives in
> `docs/PHASE_01_INVENTORY.md`, `docs/PHASE_02_TARGET_ARCHITECTURE.md`,
> `docs/PHASE_03_COMMON_INFRASTRUCTURE.md`, `docs/PHASE_04_TOOL_CONVERSION.md`, and
> `docs/archive/` (see each file for what it still holds).

---

## Table of contents

1. [What this toolchain is](#1-what-this-toolchain-is)
2. [Hard constraints](#2-hard-constraints)
3. [Repository layout (as built)](#3-repository-layout-as-built)
4. [Command surface: 14 commands in 4 groups](#4-command-surface-14-commands-in-4-groups)
5. [Shared libraries (lib/)](#5-shared-libraries-lib)
6. [Configuration ownership](#6-configuration-ownership)
7. [Data ownership & classification](#7-data-ownership--classification)
8. [Database ownership](#8-database-ownership)
9. [Dependency direction rules](#9-dependency-direction-rules)
10. [Safety contract](#10-safety-contract)
11. [Testing structure](#11-testing-structure)
12. [Component responsibility table](#12-component-responsibility-table)
13. [Documented deviations from the original blueprint](#13-documented-deviations-from-the-original-blueprint)
14. [Release & versioning workflow](#14-release--versioning-workflow)
15. [Where things live: doc map](#15-where-things-live-doc-map)

---

## 1. What this toolchain is

A personal, bash-only toolchain (GNU/Linux userland, run from WSL2 against
Windows-side data and a Windows MariaDB 10.4) that:

1. keeps a **canonical author list** derived from the Flibusta catalog
   (rated-4/5 authors), and generates from it a **UTF-8-safe nested
   directory skeleton** and prefix tables;
2. merges book archives **into** that skeleton and the skeleton **into**
   the on-disk `Books` library — copies only, never overwrites;
3. reconciles the disk library against the catalog (what is collected,
   what is missing, what is beyond the list) and sizes future
   collecting rounds;
4. maintains a **personal library database** (`myprivatelib`,
   MultiLib.exe-compatible) rebuilt from the disk books by exact md5
   match against the Flibusta catalog, with backup/restore and a
   freshness checkpoint;
5. renders **reading-plan reports** (wish list: TSV plan × app-native
   wishlists × catalog metadata).

The sibling repository **BookTracker-import** feeds this one: it
downloads the Flibusta SQL dumps / INPX indexes and ingests them into
the `flibusta` schema, which this toolchain reads.

## 2. Hard constraints

| # | Constraint | Enforced by |
|---|---|---|
| C1 | Refactor/extend **in place**; one repository | practice |
| C2 | Preserve git history — `git mv`, never delete-and-recreate | practice |
| C3 | `data/wishlist.tsv` stays **outside** any database (survives purge/reload) | `library_report` design |
| C4 | `lib/mariadb_lifecycle.sh` is the single MariaDB start/stop/upgrade boundary | all DB tools source only it |
| C5 | Safety: `--dry-run` where destructive; never overwrite existing files; backup before DB writes | per-tool CLIs |
| C6 | Config precedence `CLI > environment > file > default` | every config consumer |
| C7 | The AWK prefix generator (`lib/utf8_prefix_generator.awk`) stays the **reference/parity** implementation | e2e + golden tests |
| C8 | No credentials in code, config, or reports (password via `MYSQL_PWD` only, never echoed) | all DB tools + suites |
| C9 | Every intermediate state passes CI (syntax, version sync, suites) | `.github/workflows/ci.yml` |

## 3. Repository layout (as built)

```text
ebook-library-tools/
├── .github/workflows/ci.yml    # syntax + version sync + all suites, on push/PR
├── bin/                        # user-facing commands, grouped by function
│   ├── authors/                #   AUTHORS: export, prefix build/check/tree, tree build
│   ├── books/                  #   BOOKS:   merge, finalize, estimate, reconcile
│   ├── library/                #   LIBRARY: backup, populate, refresh, report
│   └── version_bump.sh         #   MAINTENANCE (flat — cross-group tool)
├── lib/                        # reusable components (§5)
├── config/                     # per-tool config files, renamed with their tools (§6)
├── data/                       # inputs, SQL, user state (§7)
│   ├── fixtures/               #   tracked inputs (author lists)
│   ├── sql/                    #   tracked query/schema SQL
│   ├── commit_msg/             #   gitignored: commit-message drafts
│   ├── archives/               #   gitignored: workspace-local flibusta dumps
│   └── wishlist.tsv            #   tracked, user-owned reading plan (C3)
├── tests/                      # run_all.sh + unit/ + integration/ + e2e/ + fixtures/
├── docs/                       # living docs + phase records + docs/archive/
│   └── archive/                #   consumed/superseded documents (kept for provenance)
├── .gitignore
├── ARCHITECTURE.md             # this document
├── CHANGELOG.md                # full release history
├── LICENSE                     # MIT (D-02.16)
├── README.md                   # user-facing command reference + release table
└── RELEASE_NOTES.md            # per-release shipped lines (version-synced)
```

## 4. Command surface: 14 commands in 4 groups

Naming convention: `<object>_<operation>.sh` — what it operates on, what
it does. Final names (ratified D-02.5, all landed in Phase 4):

| Group | Command | One-line purpose |
|---|---|---|
| AUTHORS | `bin/authors/authors_export.sh` | regenerate the author list from the DB |
| AUTHORS | `bin/authors/authors_prefix_build.sh` | prefix-table generator (stdin/argv filter) |
| AUTHORS | `bin/authors/authors_prefix_check.sh` | prefix-table validator |
| AUTHORS | `bin/authors/authors_prefix_tree.sh` | render the table as a tree / `mkdir -p` script |
| AUTHORS | `bin/authors/authors_tree_build.sh` | build the nested author skeleton |
| BOOKS | `bin/books/books_merge.sh` | archive → in-memory prefix merge (BooksInput_<ts>) |
| BOOKS | `bin/books/books_finalize.sh` | BooksInput_* → Books via rsync+pv (no overwrite, prune) |
| BOOKS | `bin/books/books_estimate.sh` | catalog download-size estimate for a to-collect round |
| BOOKS | `bin/books/books_reconcile.sh` | disk-vs-catalog collection report + exports |
| LIBRARY | `bin/library/library_backup.sh` | backup/restore of the myprivatelib datadir |
| LIBRARY | `bin/library/library_populate.sh` | rebuild myprivatelib from Books (md5-exact, verbatim keys) |
| LIBRARY | `bin/library/library_refresh.sh` | tree-fingerprint checkpoint; backup→populate when changed |
| LIBRARY | `bin/library/library_report.sh` | wish-list views, mutations, exports (TSV × native × hybrid) |
| MAINTENANCE | `bin/version_bump.sh` | bump one tool's version across header + docs |

Boundary rules:

- A command **never sources another command**; shared code goes to `lib/`.
  (`library_refresh` is the sole orchestrator and shells out to its
  children as separate processes, resolved under its own root — that is
  invocation, not sourcing.)
- Pipeline hand-off is **by artifact** (file paths under `data/`), never
  in-process state.
- Scripts live at `bin/<group>/<cmd>.sh` and resolve the project root
  **two levels up** via `lib/common.sh`; `version_bump.sh` is flat and
  resolves one level up.

## 5. Shared libraries (lib/)

| Library | Contents | Consumers |
|---|---|---|
| `lib/common.sh` | `common_init` (`set -Eeuo pipefail`, `--no-errexit` opt-out), symlink-safe `SCRIPT_DIR`/`PROJECT_ROOT` at any bin/ depth, `die`, `require_command`, `timestamp_now` | all infra-consumer commands |
| `lib/logging.sh` | house `log`/`debug` triplet (byte-preserved) + tagged `log_info/warn/error` | infra-consumer commands |
| `lib/cli.sh` | `cli_try_global` (`-h/-v/--debug` scan, stops at tool flags), `CLI_REMAINING_COUNT` global (subshell-safe), 0/1/2 exit contract | optional for every command |
| `lib/filesystem.sh` | `fs_tree_fingerprint` (recursive size+mtime fingerprint), `fs_prune_empty_dirs`, guards, `fs_mktmp` | refresh, finalize |
| `lib/database.sh` | `db_mysql_argv` / `db_run_query` / `db_run_sql` / `db_require_server` — opt-in, composes with the lifecycle | DB-backed commands as they adopt it |
| `lib/mariadb_lifecycle.sh` | start (UAC PowerShell) / readiness wait / graceful stop / `mysql_upgrade` — **unchanged boundary since before the refactor** (C4) | all 6+ DB tools |
| `lib/utf8_prefix_generator.awk` | the AWK reference implementation of UTF-8 prefix chopping (C7) | `authors_prefix_build`, parity tests |

Library-creation rule: a new library is extracted **when the second
consumer appears**, not speculatively. The originally planned
`authors.sh` / `books.sh` / `library.sh` / `reporting.sh` components do
not exist yet for exactly this reason (see §13).

**Layer-boundary gate (Follow-It §4):** `bin/check_layers.sh`
enforces the dependency rule mechanically — (1) `lib/*.sh` code lines
must be domain-free (the domain vocabulary that once lived in
`lib/books_functions.sh`, retired 2026-09-13, is the denylist seed);
(2) `bin/**.sh` may source only from `lib/` (config sources exempt:
data, not dependency).  CI runs it after the syntax check; a violation
fails the build before tests run.  `lib/utf8_prefix_generator.awk` is a
documented exemption — as the C7 parity reference its variable
vocabulary is the domain by design.

## 6. Configuration ownership

Per-tool config files are **kept separate** (no group-level merging —
ratified D-02.7). Each lives at `config/<tool>.conf`, is sourced by
exactly one command, and is renamed in the same commit as its tool.

| Config | Tool |
|---|---|
| `config/authors_export.conf` | `authors_export` |
| `config/books_merge.conf` | `books_merge` |
| `config/books_finalize.conf` | `books_finalize` |
| `config/books_reconcile.conf` | `books_reconcile` |
| `config/books_estimate.conf` | `books_estimate` |
| `config/library_backup.conf` | `library_backup` |
| `config/library_populate.conf` | `library_populate` |
| `config/library_report.conf` | `library_report` |

Precedence is always `CLI > environment > file > default` (C6); env
override variables keep the tool-prefixed pattern (`REPORT_*`,
`POP_*`, …). DB connection defaults are a single shared block in
`lib/database.sh`; per-tool configs may still override.

## 7. Data ownership & classification

| Class | Path | Committed | Owner |
|---|---|---|---|
| Controlled inputs | `data/fixtures/` | yes | project (`authors_list_from_db.txt` is regenerable via `authors_export`) |
| Tracked SQL | `data/sql/` | yes | project (`qry_*`, `CTE_table.sql`, `populate_tree.sql`, `qry_wishlist_native.sql`) |
| User-owned state | `data/wishlist.tsv` | yes | **the user** — the only store tools may write for the reading plan; never in a DB (C3) |
| Generated reports | `data/reports/` (or configured report dir) | **no** (gitignored) | tools (`*_*.tsv` reports, exports) |
| Generated backups | configured backup dir (Windows side) | **no** (gitignored) | `library_backup` |
| Commit-message drafts | `data/commit_msg/` | **no** (gitignored) | user |
| Workspace-local dumps | `data/archives/flibusta{,_gz}/` | **no** (gitignored) | BookTracker-import flow (never committed here) |

Architectural invariant:

```text
Books database  ──rebuildable──►  myprivatelib       (purge/reload allowed)
Reading plan    ──persistent───►  data/wishlist.tsv  (never wiped by any reload)
```

## 8. Database ownership

| Schema | Role | Owner | This repo's rights |
|---|---|---|---|
| `flibusta` | source catalog, dump-loaded | sibling **BookTracker-import** pipeline | **read-only** |
| `myprivatelib` | personal library target (MultiLib.exe-compatible) | **this repo** (`library_backup` / `library_populate` / `library_refresh`) | full |
| `mllbr_main` | app-managed wishlists (Избранное / К прочтению / Прочитано) | **MultiLib.exe** | **read-only, never written** |

Key strategy invariant (since library_populate v1.3.0): keys in
`myprivatelib` are **copied verbatim from `flibusta`** — no synthetic
keys; the `AUTO_INCREMENT` strip on all 16 PK columns stays (the app
treats server-generated PKs differently). A post-reload FK integrity
gate verifies 9 reference paths and aborts on any orphan. Full DB
knowledge lives in `docs/MultiLib_Flibusta_DB.md`.

## 9. Dependency direction rules

```text
bin/<command>   ──sources──►   lib/*.sh         ──reads/writes──►  data/, config/
lib/common.sh   ◄──sourced──   all lib modules  (the ONLY sideways edge)
lib/*           ──✗──►         bin/*            (libraries never call commands)
lib/database.sh ──wraps──►     lib/mariadb_lifecycle.sh   (one-way, no cycles)
```

- **No circular sourcing.** `common.sh` is the only module others source;
  everything else is a leaf.
- Commands communicate only through **data artifacts**; no command
  executes another in-process.
- Tests never source `bin/` internals beyond the public CLI and the
  mocked seams (mysql / rsync / pv / lifecycle).

## 10. Safety contract

- `--dry-run` exists wherever a run would write outside the repo
  (merge, finalize, populate, backup, ingest-adjacent steps).
- Existing files are **never overwritten** by merges/finalize; conflicts
  are reported, not resolved silently.
- `library_backup` runs before any destructive DB work in the refresh
  flow; populate truncates only its own managed tables and aborts on
  column-parity mismatch **before** any `TRUNCATE`.
- Passwords travel via `MYSQL_PWD` only and are never logged (suites
  assert this).
- Exit-code contract: `0` success, `1` operational failure, `2` usage
  error.

## 11. Testing structure

Grouped `tests/` (unit / integration / e2e, D-02.11 option (b), landed
2026-09-13):

- **`tests/run_all.sh`** — battery runner; executes the groups in order
  (unit → integration → e2e), accepts group filters and `-q`; replaces
  the old flat `for t in tests/test_*.sh` loop.
- **`tests/unit/`** — one suite per command or lib
  (`test_<command>.sh`), each running **anywhere** against mocked seams
  (mock `mysql`, `rsync`, `pv`, lifecycle) — CI executes them directly.
- **`tests/integration/`** — multi-component suites with golden-file
  baselines (`test_authors_prefix_build`, `test_authors_prefix_tree`,
  `test_authors_tree_build`); UTF-8/WSL-class — need gawk/multibyte.
- **`tests/e2e/`** — `test_e2e_pipeline.sh`, the cross-tool chain
  (export → prefix build → check → tree) on the real fixture.
- **`tests/fixtures/`** — shared input fixtures (`case_*.txt`,
  `viz_*.txt`); **`tests/integration/golden/`** — byte-exact regression
  baselines, never regenerated casually.
- `tests/unit/test_version_sync.sh` — proves every tool's version
  agrees across header / lib twin / README release-table row /
  RELEASE_NOTES shipped line (the registry mirrors `version_bump`).
- `tests/unit/test_lib_infrastructure.sh` — the Phase 3 library suite
  (init modes, both bin/ depths, logging, CLI scan, fingerprint
  byte-equality, prune, db argv).

## 12. Component responsibility table

Every component answers: who calls it / what it owns / what it depends
on / what it modifies / where its tests live.

| Component | Called by | Owns | Depends on | Modifies | Tests |
|---|---|---|---|---|---|
| `authors_export` | user | author-list regeneration | `mariadb_lifecycle`, config | `data/fixtures/authors_list_from_db.txt` | `test_authors_export.sh` |
| `authors_prefix_build` | user, e2e | prefix-table generation | `utf8_prefix_generator.awk` | table file (stdout/`--output`) | `test_authors_prefix_build.sh`, e2e |
| `authors_prefix_check` | user, e2e | table validation (0-critical gate) | — | nothing (read-only) | e2e validate stage + golden paths |
| `authors_prefix_tree` | user, e2e | tree rendering / `mkdir -p` script | table file | nothing (read-only) | `test_authors_prefix_tree.sh`, e2e |
| `authors_tree_build` | user | nested skeleton generation | table/list input | target skeleton dir | `test_authors_tree_build.sh` |
| `books_merge` | user | archive → staging merge + report | self-contained (domain logic inlined, Follow-It §4) | staging tree, report TSV | `test_books_merge.sh` |
| `books_finalize` | user | staging → Books (rsync+pv, no overwrite, prune) | rsync, pv | Books tree, report TSV | `test_books_finalize.sh` |
| `books_estimate` | user | round sizing from catalog | `mariadb_lifecycle` | estimate report only | `test_books_estimate.sh` |
| `books_reconcile` | user | disk-vs-catalog stats + to-collect/beyond exports | `mariadb_lifecycle` | reports | `test_books_reconcile.sh` |
| `library_backup` | user, refresh flow | datadir backup/restore | filesystem | backup dir | `test_library_backup.sh` |
| `library_populate` | user, refresh | Books → myprivatelib (md5-exact, verbatim keys) | `mariadb_lifecycle`, `library_backup` | **myprivatelib only** | `test_library_populate.sh` |
| `library_refresh` | user | freshness checkpoint, backup→populate orchestration | fingerprint, populate | checkpoint file, conditionally DB | `test_library_refresh.sh` |
| `library_report` | user | wish-list views/mutations/exports | `mariadb_lifecycle`, `data/wishlist.tsv` | **wishlist.tsv only** (+exports) | `test_library_report.sh` |
| `version_bump` | maintainer | version registry | — | headers, README, RELEASE_NOTES | `test_version_sync.sh` |
| `lib/mariadb_lifecycle.sh` | 6+ DB tools | server start/stop/upgrade | Windows interop | server process state | exercised via all DB suites |
| `lib/utf8_prefix_generator.awk` | `authors_prefix_build` | UTF-8 chop reference impl | gawk | nothing (stdin→stdout) | `test_utf8_prefix_generator.sh` |

## 13. Documented deviations from the original blueprint

Kept here so nobody "fixes" them back by accident:

1. **`bin/` uses group subdirectories** (`bin/authors/`, `bin/books/`,
   `bin/library/`), `version_bump.sh` flat — ratified D-02.3, superseding
   the Blueprint's flat-bin rule. Consequences (CI glob
   `bin/*.sh bin/*/*.sh`, two-level root resolution) are absorbed by
   Phase 3 infrastructure.
2. **Pure-filter commands are not on `common_init`.** `authors_prefix_*`,
   `authors_tree_build`, and `version_bump` are stdin/argv filters with
   no project-root or logging needs; forcing the shared init onto them
   would change nothing. Documented in `docs/PHASE_04_TOOL_CONVERSION.md`.
3. **`library_report` runs without `-e`** via `common_init --no-errexit`
   (its view pipelines rely on failing command substitutions) — the one
   documented `set -e` exception.
4. **`lib/` is smaller than the original plan** — `authors.sh`,
   `books.sh`, `library.sh`, `reporting.sh` were never created because
   the extraction rule ("second consumer, not speculation") was applied
   honestly. The lib set as built is in §5.
5. **Docs archive is `docs/archive/`** (flat, with a README mapping each
   file to where its content lives now) rather than the blueprint's
   `planning/` + `reference/` split — simpler, same guarantees.
6. **`tests/` is grouped** — the unit/integration/e2e/fixtures split
   (D-02.11 option (b)) landed 2026-09-13 together with the
   `tests/run_all.sh` battery runner; CI paths were updated in the same
   change set. **Closed.**

## 14. Release & versioning workflow

1. Bump the tool: `./bin/version_bump.sh <tool> <new_version>` — edits
   header, lib twin, README release-table row, and RELEASE_NOTES shipped
   line in one shot. Shape must match (`X.Y.Z` shell, `X.Y` AWK) and
   strictly increase.
2. Add a `CHANGELOG.md` entry (the script prints the reminder).
3. `bash tests/unit/test_version_sync.sh` → **14/14** must pass.
4. Push; CI must be green (syntax over `bin/*.sh bin/*/*.sh lib/*.sh`,
   layer-boundary gate `bin/check_layers.sh`,
   version sync, all suites).
5. Tag the repo release (`vMAJOR.MINOR.PATCH`), publish on GitHub with
   `RELEASE_NOTES.md` as the body.

Tool version bumps are for **behavior changes**; pure renames/moves never
bump (D-02.15).

## 15. Where things live: doc map

| Need | Read |
|---|---|
| How to use a command | `README.md` (per-tool sections) |
| Why the architecture is what it is | `docs/PHASE_02_TARGET_ARCHITECTURE.md` (ratified decision register) |
| How the refactor was executed | `docs/PHASE_03_*`, `docs/PHASE_04_*` |
| Everything about the databases | `docs/MultiLib_Flibusta_DB.md` |
| What to do next | `docs/NEXT.md` |
| Phase completion gates | `docs/Measurable Phase Completion Criteria.md` |
| Historical plans & consumed docs | `docs/archive/` (+ its README) |
| Release history | `CHANGELOG.md`, `RELEASE_NOTES.md` |
