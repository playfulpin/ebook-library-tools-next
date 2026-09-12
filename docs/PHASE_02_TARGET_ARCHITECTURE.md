# Phase 2 — Target Architecture

> **Deliverable of:** Phase 2 of `docs/archive/ebook-library-tools — Updated Refactoring Plan.md` (§6)
> **Version:** 1.0.0 — **RATIFIED** (all four open decisions resolved by Mike, 2026-09-07 — see §15 register and §17 approval)
> **Created:** 2026-09-07
> **Based on:** `docs/PHASE_01_INVENTORY.md` v1.0.0 (commit `6f73793`), `docs/archive/REFACTORING_BLUEPRINT.md` (§1–23, §29–44), Phase 2 entry/exit criteria (`docs/archive/ebook-library-tools — Refactoring Plan with Phase Entry & Exit Criteria.md` §5)
> **Status of decisions:** all decisions are now **RATIFIED** (v1.0.0, 2026-09-07). `[PROPOSED]`/`[OPEN]` tags in the text are historical; the resolution of each is recorded in §15 (register) and §17 (approval).

---

## Table of contents

1. [Goals & constraints](#1-goals--constraints)
2. [Repository identity](#2-repository-identity)
3. [Target directory structure](#3-target-directory-structure)
4. [Public naming convention & rename map](#4-public-naming-convention--rename-map)
5. [Executable boundaries (bin/)](#5-executable-boundaries-bin)
6. [Reusable library boundaries (lib/)](#6-reusable-library-boundaries-lib)
7. [Configuration ownership (config/)](#7-configuration-ownership-config)
8. [Data ownership (data/)](#8-data-ownership-data)
9. [Database ownership & naming](#9-database-ownership--naming)
10. [Dependency direction rules](#10-dependency-direction-rules)
11. [Testing structure](#11-testing-structure)
12. [Documentation structure](#12-documentation-structure)
13. [Component responsibility table](#13-component-responsibility-table)
14. [Migration & compatibility policy](#14-migration--compatibility-policy)
15. [Decision register](#15-decision-register)
16. [Phase 2 exit-criteria mapping](#16-phase-2-exit-criteria-mapping)
17. [Approval](#17-approval)

---

## 1. Goals & constraints

### 1.1 Goals

- Establish the **destination** before any substantial code movement (plan §6: "freeze the target architecture").
- Make every significant component answer: *who calls it, what it owns, what it depends on, what it modifies, where its tests live* (exit criteria).
- Preserve all working functionality at every step — the refactor must be executable as a sequence of green-CI commits.

### 1.2 Hard constraints (from the Blueprint and project history)

| # | Constraint | Source |
|---|---|---|
| C1 | Do **not** create a new repository; refactor this one in place | Blueprint §1 |
| C2 | Preserve git history — use `git mv`, no mass blind rename | Blueprint §37–39 |
| C3 | `wishlist.tsv` stays **outside** the database (survives purge/reload) | Blueprint §12 |
| C4 | `mariadb_lifecycle.sh` stays a single shared boundary | Blueprint §23 |
| C5 | Safety contract: `--dry-run` everywhere, never overwrite existing files, backup before any DB write | Blueprint §29–30, §32 |
| C6 | Keep config precedence `CLI > environment > file > default` | Blueprint §13 |
| C7 | AWK prefix generator stays as the **reference/parity** implementation | Blueprint §19, §53 |
| C8 | No credentials in code, config, or reports | Blueprint §60 |
| C9 | Every intermediate state must pass CI (syntax, version sync, suites) | project practice |

### 1.3 Non-goals

- No new features during the refactor (reporting roadmap items wait in `docs/NEXT.md`).
- No rewrite of the AWK engine or the UTF-8 algorithms — they are correct and golden-tested.
- No schema changes to `myprivatelib` or `mllbr_main`.

---

## 2. Repository identity

**Decision D-02.1 — repository name [RATIFIED].**
The repository is and remains `ebook-library-tools-next` on GitHub; the *project* name in user-facing text is **`ebook-library-tools`** (Blueprint §3–4). No repo rename is required for the refactor; the `-next` suffix may be dropped by a GitHub rename later at your discretion — code and docs must not hardcode either name (see D-02.9).

**Decision D-02.2 — implementation strategy [RATIFIED].**
Incremental, history-preserving, in-place refactor in the rename groups defined by the Blueprint (§69–73): one group per commit-series, CI green between groups, compatibility wrappers where public names change (§14 below).

---

## 3. Target directory structure

**Decision D-02.3 — top-level layout [RATIFIED 2026-09-07 — revised: `bin/` uses group subdirectories, superseding Blueprint §8's flat-bin rule].**

```text
ebook-library-tools/
├── .github/workflows/ci.yml     # unchanged mechanism; suite paths updated per rename
├── bin/                         # 14 user-facing commands in group subdirectories
│   ├── authors/                 #   ── AUTHORS group
│   │   ├── authors_export.sh
│   │   ├── authors_prefix_build.sh
│   │   ├── authors_prefix_check.sh
│   │   ├── authors_prefix_tree.sh
│   │   └── authors_tree_build.sh
│   ├── books/                   #   ── BOOKS group
│   │   ├── books_merge.sh
│   │   ├── books_estimate.sh
│   │   ├── books_finalize.sh
│   │   └── books_reconcile.sh
│   ├── library/                 #   ── LIBRARY group
│   │   ├── library_backup.sh
│   │   ├── library_populate.sh
│   │   ├── library_refresh.sh
│   │   └── library_report.sh
│   └── version_bump.sh          #   ── MAINTENANCE (flat — cross-group tool)
├── lib/                         # reusable components (see §6)
├── config/                      # per-tool config files (see §7)
├── data/                        # see §8 — inputs vs generated vs user-owned
│   ├── fixtures/
│   ├── sql/
│   ├── reports/
│   └── wishlist.tsv
├── tests/                       # see §11
├── docs/                        # see §12
├── .gitignore
├── CHANGELOG.md
├── LICENSE                      # NEW — MIT (D-02.16, ratified)
├── README.md
└── RELEASE_NOTES.md
```

Rationale:
- Commands live in **group subdirectories** (`bin/authors/`, `bin/books/`, `bin/library/`); the directory is the primary grouping, the `<object>_` prefix stays in the filename for standalone reference. `version_bump.sh` remains flat as a cross-group maintenance tool.
- **Supersedes Blueprint §8** ("keep `bin/` flat") — ratified 2026-09-07. Consequences folded into later phases: the CI syntax-check glob must expand to `bin/*.sh` **and** `bin/*/*.sh`, and script-location resolution must go two directory levels up (`bin/<group>/<cmd>.sh` → project root) — part of Phase 3 §7.2.
- `data/archives/` (flibusta dumps) is **workspace-local, gitignored** input — it does not appear in the tracked target tree; its location stays configurable because it lives outside the repo today.

---

## 4. Public naming convention & rename map

**Decision D-02.4 — naming convention [RATIFIED].**
Every public command is named `<object>_<operation>.sh`, answering *what it operates on* and *what it does*.

**Decision D-02.5 — rename map [RATIFIED 2026-09-07 — names frozen as below; targets live in group subdirectories per D-02.3].**

| Current (Phase 1 inventory) | Target | Group | Priority |
|---|---|---|---|
| `bin/export_authors_from_db.sh` | `bin/authors/authors_export.sh` | 1st rename group | High |
| `bin/build_prefix_table.sh` | `bin/authors/authors_prefix_build.sh` | 1st | High |
| `bin/prefix_table_integrity.sh` | `bin/authors/authors_prefix_check.sh` | 1st | High |
| `bin/prefix_tree_visualizer.sh` | `bin/authors/authors_prefix_tree.sh` | 1st | High |
| `bin/build_shell_nested_authors.sh` | `bin/authors/authors_tree_build.sh` | 1st | High |
| `bin/merge_books_into_skeleton.sh` | `bin/books/books_merge.sh` | 2nd | **Critical** |
| `bin/merge_skeleton_into_books.sh` | `bin/books/books_finalize.sh` | 2nd | **Critical** |
| `bin/estimate_download_size.sh` | `bin/books/books_estimate.sh` | 3rd | Medium |
| `bin/reconcile_library.sh` | `bin/books/books_reconcile.sh` | 3rd | Medium |
| `bin/backup_myprivatelib.sh` | `bin/library/library_backup.sh` | 3rd | Medium |
| `bin/populate_myprivatelib.sh` | `bin/library/library_populate.sh` | 3rd | Medium |
| `bin/refresh_myprivatelib.sh` | `bin/library/library_refresh.sh` | 3rd | Medium |
| `bin/report_library.sh` | `bin/library/library_report.sh` | 4th | Medium |
| `bin/bump-version.sh` | `bin/version_bump.sh` | last | Low |

Rename rules (per commit/group):
1. `git mv` only — history preserved (C2).
2. Rename the test suite in the same commit (`test_<old>.sh` → `test_<new>.sh`).
3. Update, in the same commit: `bump-version.sh` registry, `tests/test_version_sync.sh`, `ci.yml` suite paths, README tool table + usage, RELEASE_NOTES lines, and any cross-references in `docs/`.
4. Tool **version numbers do not bump on pure renames** (Blueprint §43); the version-sync registry entry moves with the file.
5. **No compatibility wrappers** (D-02.13, ratified): clean cutover per group — every caller, doc reference, and registry entry switches in the same commit; the CI syntax-check glob expands to `bin/*.sh bin/*/*.sh`.

---

## 5. Executable boundaries (bin/)

Four functional groups plus maintenance (Blueprint §9); every command is independently runnable, CLI-first, and owns exactly one stage of its pipeline. Locations per D-02.3: `bin/<group>/<command>.sh`, with `version_bump.sh` flat in `bin/`.

| Group | Commands | Owns |
|---|---|---|
| **AUTHORS** | `authors_export`, `authors_prefix_build`, `authors_prefix_check`, `authors_prefix_tree`, `authors_tree_build` | Canonical author list; prefix generation/validation/visualization; nested skeleton generation |
| **BOOKS** | `books_estimate`, `books_merge`, `books_finalize`, `books_reconcile` | Round sizing; archive → staging merge; staging → Books finalization; disk-vs-catalog reconciliation |
| **LIBRARY** | `library_backup`, `library_populate`, `library_refresh`, `library_report` | DB datadir safety; Books → `myprivatelib` population; freshness checkpoint; reading plan & reports |
| **MAINTENANCE** | `version_bump` | Version registry and release metadata |

Boundary rules:
- A command **never** sources another command; shared code goes to `lib/`.
- Pipeline hand-off is **by artifact** (file paths from `data/`), never by in-process state.
- Group-subdirectory depth is absorbed by the shared location helper (Phase 3 §7.2): a script at `bin/<group>/<cmd>.sh` resolves the project root two levels up.

---

## 6. Reusable library boundaries (lib/)

**Decision D-02.6 — lib/ target [RATIFIED].**
Target components (Blueprint §15–23); each is *seeded from* the duplicated code identified in the Phase 1 inventory (§11.1) — nothing is invented:

| Library | Contents (seeded from) | Notes |
|---|---|---|
| `lib/common.sh` | `die`, `require_command`, `timestamp_now`, `is_true`, temp-dir helpers, dry-run helpers | No domain logic |
| `lib/cli.sh` | arg-parsing helpers, usage-block helpers, exit-code constants | Extracted from the copy-pasted CLI blocks |
| `lib/logging.sh` | `log_info/warn/error/debug`, level filtering | House format preserved |
| `lib/filesystem.sh` | path validation, safe mkdir, tree fingerprint (from refresh), empty-dir prune (from books_finalize) | |
| `lib/database.sh` | mysql argv assembly, query-file execution, existence checks | Thin; lifecycle stays separate |
| `lib/mariadb_lifecycle.sh` | **unchanged boundary** — start/wait/stop/upgrade over Windows interop | C4 — preserve as is |
| `lib/authors.sh` | UTF-8 prefix handling, author-name normalization | One conceptual prefix algorithm; AWK stays the parity reference (C7) |
| `lib/books.sh` | archive scanning, author-folder discovery, `SKIP_NAMES` filtering (from merge_books_functions) | Successor of `lib/merge_books_functions.sh` |
| `lib/library.sh` | wishlist.tsv helpers, catalog lookup helpers | |
| `lib/reporting.sh` | report rendering, export writers (md/tsv) | |

Sourcing model: `bin/<cmd>.sh` sources **only** the libraries it needs; libraries **never** source each other sideways except `common.sh` (see §10). Migration is gradual — a library is created when the second consumer appears, not speculatively.

---

## 7. Configuration ownership (config/)

**Decision D-02.7 — keep per-tool config files [RATIFIED].**
The eight existing `config/<tool>.conf` files are **retained** and renamed with their tools (`config/authors_export.conf`, …). Group-level merging (`authors.conf`, `books.conf`, …) is **rejected** for now — Blueprint §13: "do not merge existing configuration files simply to reduce the number of files."

Ownership rules:
- Precedence stays `CLI > environment > file > default` (C6).
- Environment override variables keep the `REPORT_*`/tool-prefixed pattern.
- DB connection defaults (host, port, user, charset) become a single shared block inside `lib/database.sh`; per-tool configs may still override.

---

## 8. Data ownership (data/)

**Decision D-02.8 — data classification [RATIFIED].**

| Class | Path | Committed | Owner | Examples |
|---|---|---|---|---|
| Controlled inputs | `data/fixtures/` | yes | project | `authors_list_from_db.txt` (regenerable via `authors_export`) |
| Tracked SQL definitions | `data/sql/` | yes | project | `qry_*`, `populate_tree.sql`, `CTE_table.sql` |
| Generated reports | `data/reports/{merge,reconcile,estimate,library}/` | **no** (gitignored) | tools | `merge_*.tsv`, `reconcile_*.tsv`, wishlist exports |
| Generated backups | `data/backups/myprivatelib/` (or configured Windows-side path) | **no** (gitignored) | `library_backup` | datadir snapshots |
| **User-owned persistent state** | `data/wishlist.tsv` | yes | **the user** | the reading plan |

Architectural invariant (C3, Blueprint §12):

```text
Books database  ──rebuildable──►  myprivatelib      (purge/reload allowed)
Reading plan    ──persistent───►  data/wishlist.tsv (never written by tools' DB logic)
```

Workspace-local, gitignored: `data/archives/flibusta{,_gz}/` (flibusta dumps — input to nothing in this repo directly; they belong to the BookTracker-import ingest flow and stay out of git).

---

## 9. Database ownership & naming

**Decision D-02.9 — schemas and ownership [RATIFIED by prior work].**

| Schema | Role | Owner | This repo's rights |
|---|---|---|---|
| `flibusta` | Source catalog (dump-loaded) | sibling **BookTracker-import** pipeline | **read-only** |
| `myprivatelib` | Personal library target (MultiLib.exe-compatible) | **this repo** (`library_populate`, `library_backup`, `library_refresh`) | full |
| `mllbr_main` | App-managed wishlist groups (Избранное/К прочтению/Прочитано) | **MultiLib.exe** | **read-only, never written** |

No schema name changes. Keys in `myprivatelib` are copied **verbatim** from `flibusta` (no synthetic keys) — invariant introduced in v1.3.0 and preserved.

---

## 10. Dependency direction rules

**Decision D-02.10 — allowed dependency directions [RATIFIED].**

```text
bin/<command>  ──sources──►  lib/*.sh        ──reads/writes──►  data/, config/
lib/common.sh  ◄──sourced──  all lib modules  (only allowed sideways edge)
lib/*          ──✗──►  bin/*                 (libraries never call commands)
lib/database.sh ──wraps──►  lib/mariadb_lifecycle.sh (one-way, no cycles)
```

Explicit prohibitions:
- **No circular sourcing** — `common.sh` is the only module others may source; everything else is a leaf.
- Commands communicate **only through data artifacts**; no command executes another command in-process (pipeline orchestration, if ever needed, is a separate future decision — currently nothing does this).
- Tests never source `bin/` internals beyond the public CLI + the mocked seams (mysql/rsync/pv/lifecycle).

---

## 11. Testing structure

**Decision D-02.11 — test layout [RATIFIED 2026-09-07 — option (b): keep flat `tests/` until the rename groups land; split afterwards].**

*Proposed target* (Blueprint §34 direction, plan's proposed layout):

```text
tests/
├── unit/          # per-command suites with mocked seams (mock mysql/rsync/pv)
├── integration/   # cross-tool suites (e2e pipeline chain, version sync)
├── fixtures/      # case_*.txt, viz_*.txt, wishlist seeds
└── golden/        # golden outputs (17 files, byte-exact)
```

*Ratified path (b):* keep the current flat `tests/` layout through the renames; create the split as a separate, later change set so CI suite paths are only touched once each.

The e2e suite (generate → validate → render on the real fixture) and `test_version_sync.sh` are **integration-class** regardless of layout; the golden files are byte-exact regression baselines and are never regenerated casually (Blueprint §36 test baseline).

CI keeps its two execution classes: "run anywhere" (mocked) vs "UTF-8/WSL-style" (gawk, multibyte). Suite paths in `ci.yml` change with the renames, in the same commits.

---

## 12. Documentation structure

**Decision D-02.12 — docs disposition [RATIFIED].**

```text
docs/
├── ARCHITECTURE.md            # NEW — distilled, permanent architecture description
│                              #   (Phase 2 output; maintained from then on)
├── UserGuide.md               # consolidated user guide (merge of the two existing guides)
├── DEVELOPMENT.md             # NEW — how to develop/test/release (phase criteria live here or link)
├── PHASE_01_INVENTORY.md      # Phase 1 deliverable (kept as record)
├── PHASE_02_TARGET_ARCHITECTURE.md  # this document (superseded by ARCHITECTURE.md at Phase 2 close)
├── planning/                  # historical plans move here, banner-marked, NOT deleted:
│   ├── REFACTORING_BLUEPRINT.md
│   ├── Refactoring Plan with Phase Entry & Exit Criteria.md
│   ├── Updated Refactoring Plan.md
│   ├── Measurable Phase Completion Criteria.md
│   ├── REPRESENTATION_PLAN.md
│   └── BOOK_LIBRARY_MERGE_PLAN.md
├── reference/                 # living reference material
│   ├── MultiLib_Flibusta_DB.md
│   └── qry_wishlist_native notes (companion SQL docs)
└── NEXT.md, DO_IT_ongoing.md  # stay at top level (living docs)
```

Historical docs are **moved, banner-marked** ("superseded in part by ARCHITECTURE.md"), never deleted (preserves the reasoning trail). `COVERS_PLAN.md`, `NB_001…`, `Flibusta_DB_findings.txt` move to `planning/`/`reference/` accordingly.

---

## 13. Component responsibility table

Exit criterion: every significant component answers *who calls it / what it owns / what it depends on / what it modifies / where its tests live*. (Names shown as **current → target**.)

| Component | Called by | Owns | Depends on | Modifies | Tests |
|---|---|---|---|---|---|
| `export_authors_from_db` → `authors_export` | user, docs | author-list regeneration | `mariadb_lifecycle`, config | `data/fixtures/authors_list_from_db.txt` | `test_export_authors_from_db.sh` |
| `build_prefix_table` → `authors_prefix_build` | user, e2e | prefix table generation | `utf8_prefix_generator.awk` | table file (stdout or `--output`) | `test_build_prefix_table.sh`, e2e |
| `prefix_table_integrity` → `authors_prefix_check` | user, e2e | table validation (0-critical gate) | — | nothing (read-only) | e2e validate stage + golden paths (no standalone suite — noted for Phase 4) |
| `prefix_tree_visualizer` → `authors_prefix_tree` | user, e2e | tree rendering / `mkdir -p` script | table file | nothing (read-only) | `test_prefix_tree_visualizer.sh`, e2e |
| `build_shell_nested_authors` → `authors_tree_build` | user | nested skeleton generation | table/list input | target skeleton dir | `test_build_shell_nested_authors.sh` |
| `merge_books_into_skeleton` → `books_merge` | user | archive → staging merge, report | `merge_books_functions` → `lib/books.sh` | staging tree, report TSV | `test_merge_books_into_skeleton.sh` |
| `merge_skeleton_into_books` → `books_finalize` | user | staging → Books (rsync+pv, no overwrite, prune) | rsync, pv | Books tree, report TSV | `test_merge_skeleton_into_books.sh` |
| `estimate_download_size` → `books_estimate` | user | round sizing from catalog | `mariadb_lifecycle` | nothing (read-only) + estimate report | `test_estimate_download_size.sh` |
| `reconcile_library` → `books_reconcile` | user | disk-vs-catalog stats, to-collect & beyond exports | `mariadb_lifecycle` | reports | `test_reconcile_library.sh` |
| `backup_myprivatelib` → `library_backup` | user, populate/refresh flow | datadir backup/restore | filesystem | backup dir | `test_backup_myprivatelib.sh` |
| `populate_myprivatelib` → `library_populate` | user, refresh | Books → myprivatelib (md5-exact, verbatim keys) | `mariadb_lifecycle`, `backup` | **myprivatelib only** | `test_populate_myprivatelib.sh` |
| `refresh_myprivatelib` → `library_refresh` | user | freshness checkpoint, orchestration | fingerprint, populate | checkpoint file, conditionally DB | `test_refresh_myprivatelib.sh` |
| `report_library` → `library_report` | user | wish list views/mutations/exports | `mariadb_lifecycle`, `data/wishlist.tsv` | **wishlist.tsv only** (+exports) | `test_report_library.sh` |
| `bump-version` → `version_bump` | maintainer | version registry | — | headers, README, RELEASE_NOTES | `test_version_sync.sh` |
| `lib/mariadb_lifecycle.sh` | 6 DB tools | server start/stop/upgrade | Windows interop | server process state | exercised via all DB suites |
| `lib/utf8_prefix_generator.awk` | `authors_prefix_build` | UTF-8 chop reference impl | gawk | nothing (stdin→stdout) | `test_utf8_prefix_generator.sh` |

*(Correction note: `prefix_table_integrity` is covered by `test_build_prefix_table.sh` golden path **and** the e2e validate stage; it has no standalone suite today — acceptable, noted for Phase 4.)*

---

## 14. Migration & compatibility policy

**Decision D-02.13 — no compatibility wrappers [RATIFIED 2026-09-07].**
Clean cutover per rename group: the old command name disappears in the same commit that introduces the new one. This is a personal toolchain with no external callers; docs, README usage, the version registry, and CI switch in the same commit.

**Decision D-02.14 — branch & commit discipline [RATIFIED].**
All rename work happens on a refactor branch (`refactor/<topic>`), merged to `main` per completed group; every push must be CI-green (Blueprint §37, §40 commit sequence).

**Decision D-02.15 — versioning during refactor [RATIFIED].**
Pure renames/moves do **not** bump tool versions or repo tags. Real behavior changes during Phase 4 refactors bump the tool version via `version_bump` as usual (Blueprint §43–44).

**Decision D-02.16 — MIT License [RATIFIED 2026-09-07].**
The repository ships a `LICENSE` file under the **MIT** license (© 2026 Mike / playfulpin). **Landed 2026-09-07** at the repository root, together with this document's ratification update.

---

## 15. Decision register

| ID | Decision | Status | Notes |
|---|---|---|---|
| D-02.1 | Repo stays `ebook-library-tools-next`; project name `ebook-library-tools` | RATIFIED | GitHub rename optional later |
| D-02.2 | In-place incremental refactor, rename groups per Blueprint §69–73 | RATIFIED | |
| D-02.3 | Target top-level layout (§3) | **RATIFIED (revised)** — `bin/` uses group subdirectories `authors/`, `books/`, `library/`; `version_bump.sh` flat | supersedes Blueprint §8 flat-bin rule |
| D-02.4 | `<object>_<operation>.sh` naming | RATIFIED | |
| D-02.5 | Full rename map (§4) | **RATIFIED** — all 14 names frozen; targets in group subdirs | drives Phase 4 order |
| D-02.6 | `lib/` component set (§6) | RATIFIED | seeded from real duplication |
| D-02.7 | Keep 8 per-tool configs, no merging | RATIFIED | per Blueprint §13 |
| D-02.8 | Data classification + `data/reports`, `data/backups` | RATIFIED | generated data gitignored |
| D-02.9 | Schema ownership: flibusta RO / myprivatelib full / mllbr_main RO | RATIFIED | |
| D-02.10 | Dependency direction rules (§10) | RATIFIED | |
| D-02.11 | Test layout: split unit/integration | **RATIFIED — option (b)**: after the renames | avoids touching CI paths twice |
| D-02.12 | Docs disposition incl. `ARCHITECTURE.md`, `planning/` move | RATIFIED | |
| D-02.13 | Compatibility wrappers | **RATIFIED — NO wrappers**, clean cutover per group | personal toolchain, no external callers |
| D-02.14 | Refactor branch + green-CI-per-group | RATIFIED | |
| D-02.15 | Renames don't bump versions | RATIFIED | |
| D-02.16 | Add `LICENSE` | **RATIFIED — MIT** | landed 2026-09-07 (`LICENSE` at repo root) |

---

## 16. Phase 2 exit-criteria mapping

| Criterion (Entry/Exit doc §5) | Where satisfied |
|---|---|
| 100% of significant directories have a target disposition | §3, §8, §11, §12 |
| 100% of public commands have a target location | §4, §5 |
| 100% of reusable components have an intended library location | §6 |
| Configuration ownership defined | §7 |
| Runtime-state ownership defined | §8, §9 |
| Data-flow boundaries defined | §8, §10 |
| Dependency direction documented | §10 |
| `ARCHITECTURE.md` exists | produced at Phase 2 close from §3–§13 (D-02.12) |
| Every component answers the 5 questions | §13 |
| No intentional circular dependency | §10 |
| Target structure approved for implementation | §17 approval block |
| No major architectural decision remains implicit | §15 decision register |

---

## 17. Approval

> **Ratified 2026-09-07 by Mike** — all four open decisions resolved:
>
> 1. **D-02.5** — rename map ratified as proposed (14 names frozen), with targets placed in group subdirectories per the revised D-02.3.
> 2. **D-02.3 (revised)** — `bin/` uses **group subdirectories** (`bin/authors/`, `bin/books/`, `bin/library/`), `version_bump.sh` flat — supersedes Blueprint §8 flat-bin rule.
> 3. **D-02.11** — test layout split deferred until after the rename groups (option b).
> 4. **D-02.16** — MIT `LICENSE` file to be added.
> 5. **D-02.13** — **no** compatibility wrappers; clean cutover per rename group.
>
> Consequence: `ARCHITECTURE.md` (distilled from §3–§13) is generated at Phase 2 close; Phase 3 may begin.
>
| Approved by | Date | Result |
|---|---|---|
| Mike | 2026-09-07 | ☑ ratified as v1.0.0 |
