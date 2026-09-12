# Phase 1 — Repository Inventory & Dependency Map

> **Deliverable of:** Phase 1 of `docs/archive/ebook-library-tools — Updated Refactoring Plan.md` (§4–5)
> **Version:** 1.0.0
> **Created:** 2026-09-07
> **Audited commit:** `328bdd9` (rename `qry_Фантастика_4-and-5.sql` → `qry_Fantastika_4-and-5.sql`); docs-sync commit `8483292`
> **Method:** read-only audit — tree walk, script headers, git log/tags, CI workflow, config and data cross-reference. No code was modified.
> **Related:** `docs/archive/REFACTORING_BLUEPRINT.md`, `docs/archive/ebook-library-tools — Refactoring Plan with Phase Entry & Exit Criteria.md`, `docs/Measurable Phase Completion Criteria.md`

---

## Table of contents

1. [Repository identity](#1-repository-identity)
2. [Repository tree](#2-repository-tree)
3. [Runtime inventory — tools by functional group](#3-runtime-inventory)
4. [Shared libraries](#4-shared-libraries)
5. [Test & CI inventory](#5-test--ci-inventory)
6. [Configuration inventory](#6-configuration-inventory)
7. [Data inventory](#7-data-inventory)
8. [Documentation inventory](#8-documentation-inventory)
9. [Dependency map](#9-dependency-map)
10. [File disposition](#10-file-disposition)
11. [Duplicate / obsolete functionality & hotspots](#11-duplicate--obsolete-functionality--hotspots)
12. [Metrics snapshot](#12-metrics-snapshot)
13. [Phase 1 exit-criteria checklist](#13-phase-1-exit-criteria-checklist)

---

## 1. Repository identity

| Item | Value |
|---|---|
| GitHub | `https://github.com/playfulpin/ebook-library-tools-next` |
| Lineage | **MultiLib_Utilities renamed** — full commit history preserved (pre-rename history: prefix pipeline → merge pipeline → myprivatelib population → reporting layer) |
| Branch | `main` (single-branch development) |
| Remote state | up to date with `origin/main`; working tree clean at audit time |
| Tag chain | repo releases **v1.0.0 → v1.6.0** (v1.6.0 = hybrid wish-list view, latest published) |
| Legacy per-tool tags | `utf8_prefix_generator-1.1`, `build_prefix_table-1.0.4`, `prefix_table_integrity-1.2.1`, `prefix_tree_visualizer-2.8.1`, `v2.8.1`, `v6.6.8`, `Release_line` |
| Refactoring commits | `51ca084` "Snc with original" (user guides), `8483292` "Last touch sync for docs/", `10ab149` "Add refactoring documentation", `328bdd9` ASCII rename of the Fantastika query |

Two version schemes coexist (see §11.3): repo-wide release tags (`v1.x`) and per-tool script versions (`0.2.x` … `6.6.10`) managed by `bin/bump-version.sh` and enforced by `tests/test_version_sync.sh`.

---

## 2. Repository tree

```
ebook-library-tools-next/
├── .github/workflows/ci.yml        # CI: syntax → version sync → 9 unit suites → 5 UTF-8 suites
├── bin/                            # 14 executable tools (see §3)
├── lib/                            # 2 shared libraries (see §4)
├── tests/                          # 15 suites + golden fixtures + case fixtures (see §5)
├── config/                         # 8 per-tool config files (see §6)
├── data/
│   ├── archives/flibusta/          # 12 uncompressed lib*.sql dumps   [gitignored]
│   ├── archives/flibusta_gz/       # 12 lib*.sql.gz dumps             [gitignored]
│   ├── fixtures/                   # authors_list_from_db.txt (~5,707 names)
│   ├── sql/                        # 8 query/DDL files
│   └── wishlist.tsv                # reading-plan store (report_library)
├── docs/                           # 13 documents (see §8)
├── CHANGELOG.md  README.md  RELEASE_NOTES.md
├── commit_msg/                     # commit-message scratchpad        [gitignored]
└── _Save_Stuff/                    # dev-era zip archives             [gitignored]
```

Ignored scratch at workspace root (not tracked, no action needed): `tmp_SORTED_AUTHORS`, `tmp_NESTED_AUTHORS`, `tmp_NESTED_AUTHORS_upd`, `merge_skeleton_into_books_20260831-150603.tsv`.

---

## 3. Runtime inventory

Fourteen tools in `bin/`, grouped by subsystem. Version = header `# Version:` line, kept in sync with `--version` output and README by the registry.

### 3.1 Prefix / trie pipeline (AUTHORS subsystem — oldest, most mature)

| Tool | Ver | Role |
|---|---|---|
| `bin/build_prefix_table.sh` | 1.0.4 | Pre-order trie walker: author list → prefix table (strict byte order) |
| `bin/prefix_table_integrity.sh` | 1.2.1 | Validates a generated table (0-critical gate), parent-prefix checks |
| `bin/prefix_tree_visualizer.sh` | 2.8.1 | Renders the table as `mkdir -p` tree / visualization |
| `bin/build_shell_nested_authors.sh` | 6.6.10 | Shell-nested author skeleton builder (highest tool version in repo) |
| `lib/utf8_prefix_generator.awk` | 1.1 | Multibyte chop engine (gawk; the historical 6,483-warning fix lives here) |

### 3.2 Merge pipeline (BOOKS subsystem)

| Tool | Ver | Role |
|---|---|---|
| `bin/merge_books_into_skeleton.sh` | 0.2.0 | Source authors → skeleton destinations (series subfolders, `SKIP_NAMES`, CSV report, dry-run) |
| `bin/merge_skeleton_into_books.sh` | 0.2.3 | Skeleton → Books target: `rsync --info=progress2` + `pv -l` file-count progress, empty-dir prune, never overwrites |

### 3.3 DB population pipeline (LIBRARY subsystem — flibusta → myprivatelib, MariaDB 10.4 on Windows)

| Tool | Ver | Role |
|---|---|---|
| `bin/export_authors_from_db.sh` | 1.0.2 | SQL query file → author-list fixture (auto MariaDB lifecycle, graceful stop) |
| `bin/populate_myprivatelib.sh` | 1.3.0 | Books folder → `myprivatelib` via md5-exact matching; **copies flibusta keys verbatim** (no synthetic keys) |
| `bin/backup_myprivatelib.sh` | 1.0.0 | Datadir backup/restore gate before any population |
| `bin/refresh_myprivatelib.sh` | 1.0.0 | Freshness orchestrator: tree-fingerprint checkpoint decides whether repopulation is needed |
| `bin/reconcile_library.sh` | 1.0.3 | Disk vs catalog progress stats + to-collect shopping list + beyond-list books export |

### 3.4 Reporting layer (newest subsystem)

| Tool | Ver | Role |
|---|---|---|
| `bin/report_library.sh` | 1.2.0 | Wish list: TSV plan (`data/wishlist.tsv`) + `--native` views over app-managed `mllbr_main` + `--hybrid` merge; `--search/--add/--set-status/--remove/--export` |
| `bin/estimate_download_size.sh` | 1.0.0 | Next-round download-size estimator from the catalog for to-collect authors |

### 3.5 Maintenance

| Tool | Ver | Role |
|---|---|---|
| `bin/bump-version.sh` | 1.0.1 | 14-tool version registry; bumps header + `SCRIPT_VERSION` + README row + RELEASE_NOTES line |

---

## 4. Shared libraries

| Library | Ver | Consumers |
|---|---|---|
| `lib/mariadb_lifecycle.sh` | 1.0.1 | `export_authors_from_db.sh`, `populate_myprivatelib.sh`, `backup_myprivatelib.sh` (restore path), `refresh_myprivatelib.sh`, `reconcile_library.sh`, `report_library.sh` — start (PowerShell UAC + wait-for-listener), stop (graceful SHUTDOWN), Windows-interop checks |
| `lib/merge_books_functions.sh` | 0.2.0 | `merge_books_into_skeleton.sh` only — copy policy, SKIP_NAMES filtering, destination resolution, report rows |

No other code sharing exists; conventions (header block, `log()`, arg parsing, config loading) are **copy-paste** across tools — the main Phase 3 target (see §11.1).

---

## 5. Test & CI inventory

**15 suites** in `tests/`, all wired into CI (nothing orphaned):

| Suite | Covers | Class |
|---|---|---|
| `test_build_prefix_table.sh` | generator | UTF-8 (WSL-style multibyte) |
| `test_prefix_tree_visualizer.sh` | renderer | UTF-8 |
| `test_build_shell_nested_authors.sh` | skeleton builder | UTF-8 |
| `test_utf8_prefix_generator.sh` | awk engine | UTF-8 |
| `test_e2e_pipeline.sh` | **cross-tool**: generate → validate → render on the real fixture; locks out format drift | UTF-8, e2e |
| `test_merge_books_into_skeleton.sh` | merge out | unit (mock rsync/pv) |
| `test_merge_skeleton_into_books.sh` | merge in | unit |
| `test_export_authors_from_db.sh` | author exporter | unit (mock mysql) |
| `test_reconcile_library.sh` | reconciliation stats/exports | unit |
| `test_estimate_download_size.sh` | size estimator | unit |
| `test_backup_myprivatelib.sh` | backup/restore | unit |
| `test_populate_myprivatelib.sh` | population | unit (mock mysql) |
| `test_refresh_myprivatelib.sh` | freshness orchestrator | unit |
| `test_report_library.sh` | wish list (71 assertions after v1.2.0) | unit (mock mysql) |
| `test_version_sync.sh` | 14-tool registry gate (header ↔ `--version` ↔ README ↔ RELEASE_NOTES) | meta |

Test assets: `tests/golden/` (17 golden files: `*_m6_x5.txt`, `*_sql.txt`, `viz_*.txt`), `tests/case_*.txt` (apostrophe, case variants, duplicates, quotes, spaces), `tests/viz_*.txt`.

**CI** (`.github/workflows/ci.yml`, `actions/checkout@v5`, ubuntu-latest):
1. Install `gawk rsync pv`
2. Shell syntax check — `bash -n` over `bin/*.sh`, `gawk --lint` over `lib/*.awk`
3. Version sync check — `test_version_sync.sh`
4. Unit suites (9, run anywhere)
5. UTF-8 suites (5, multibyte bash)

---

## 6. Configuration inventory

Eight config files, one per configurable tool (house pattern: tool reads `config/<tool>.conf` first, environment overrides):

| Config | Consumer |
|---|---|
| `config/merge_books.conf` | merge_books_into_skeleton.sh |
| `config/merge_skeleton_into_books.conf` | merge_skeleton_into_books.sh |
| `config/populate_myprivatelib.conf` | populate_myprivatelib.sh |
| `config/backup_myprivatelib.conf` | backup_myprivatelib.sh |
| `config/refresh_myprivatelib.conf` | refresh_myprivatelib.sh |
| `config/reconcile_library.conf` | reconcile_library.sh |
| `config/report_library.conf` | report_library.sh |
| `config/estimate_download_size.conf` | estimate_download_size.sh |

Notable config values: `BOOK_CATALOG_DIR=/mnt/c/Backup_Go7/Books`, `REPORT_DIR=/mnt/c/Backup_Go7/merge-reports`, `STAGING`-era paths retired. DB tools share connection defaults (host 127.0.0.1, port 3306, user root, utf8) via `mariadb_lifecycle.sh` conventions.

---

## 7. Data inventory

| Path | Tracked | Content / role |
|---|---|---|
| `data/archives/flibusta_gz/` (12 × `.sql.gz`) | **no** (gitignored) | Raw flibusta dump archives — load source for populate pipeline |
| `data/archives/flibusta/` (12 × `.sql`) | **no** (gitignored) | Decompressed working copies |
| `data/fixtures/authors_list_from_db.txt` | yes | Working author fixture (~5,707 names, Фантастика 4–5 genre scope), regenerated by `export_authors_from_db.sh` |
| `data/wishlist.tsv` | yes | Reading-plan store (bookid, added, target_period, status, note) — deliberately outside the DB so populate reloads never wipe it |
| `data/sql/qry_authors_4_and_5_all.sql` | yes | All-author catalog query (13,396-row fixture source) |
| `data/sql/qry_authors_4_and_5_love_hard.sql` | yes | Historical query source of the old 6,088-name fixture |
| `data/sql/qry_Fantastika_4-and-5.sql` | yes | Working genre-scope query (renamed from Cyrillic `qry_Фантастика_4-and-5.sql` in `328bdd9`) |
| `data/sql/qry_catalog_reference.sql` | yes | Catalog reference lookup (md5 → bookid/author joins) |
| `data/sql/qry_wishlist_native.sql` | yes | 5 companion queries (A–E) for native `mllbr_main` wishlists |
| `data/sql/CTE_table.sql` | yes | Large CTE-based catalog build (352 KB, biggest tracked file) |
| `data/sql/populate_tree.sql` | yes | Catalog-tree population DDL/DML |
| `data/sql/rebuild_library_statistics.sql` | yes | Catalog statistics rebuild |

---

## 8. Documentation inventory

| Document | Size | Role / status |
|---|---|---|
| `docs/archive/REFACTORING_BLUEPRINT.md` | 2,401 ln | Foundational blueprint: keep-repo decision, rename map, target `bin/` layout, data/ refactor. **Superseded in parts by the Updated Plan** |
| `docs/archive/ebook-library-tools — Updated Refactoring Plan.md` | 1,003 ln | **Active plan** — phase definitions; Phase 1 = this inventory |
| `docs/archive/ebook-library-tools — Refactoring Plan with Phase Entry & Exit Criteria.md` | 869 ln | Per-phase entry/exit gates |
| `docs/Measurable Phase Completion Criteria.md` | 502 ln | Phase completion scorecard |
| `docs/PHASE_01_INVENTORY.md` | this file | Phase 1 deliverable |
| `docs/NEXT.md` | 161 ln | Living resume point (last: post v1.6.0 state) |
| `docs/archive/DO_IT_ongoing.md` | 255 ln | Folded assignment history (4 timestamped parts, all resolved) |
| `docs/MultiLib_Flibusta_DB.md` | ~52 KB | DB reference: flibusta/myprivatelib tables, keys, load order, data flow |
| `docs/archive/REPRESENTATION_PLAN.md` | — | Representation-layer plan (myprivatelib strategy) |
| `docs/archive/BOOK_LIBRARY_MERGE_PLAN.md` | — | Merge pipeline plan |
| `docs/archive/COVERS_PLAN.md` | — | **Closed** — covers/annotations render from FB2 payload |
| `docs/MultiLib_Utilities — User Guide.md` | — | End-user guide (historical name) |
| `docs/BookTracker Import — User Guide.md` | — | Guide for the sibling BookTracker-import pipeline |
| `docs/archive/NB_001-find-bookid-in-schema.md`, `docs/archive/Flibusta_DB_findings.txt` | — | Working notes (candidates for archival) |

---

## 9. Dependency map

### 9.1 Shell-source dependencies

```
bin/merge_books_into_skeleton.sh ──► lib/merge_books_functions.sh
bin/export_authors_from_db.sh    ──► lib/mariadb_lifecycle.sh
bin/populate_myprivatelib.sh     ──► lib/mariadb_lifecycle.sh
bin/backup_myprivatelib.sh       ──► lib/mariadb_lifecycle.sh
bin/refresh_myprivatelib.sh      ──► lib/mariadb_lifecycle.sh
bin/reconcile_library.sh         ──► lib/mariadb_lifecycle.sh
bin/report_library.sh            ──► lib/mariadb_lifecycle.sh
bin/build_prefix_table.sh        ──► lib/utf8_prefix_generator.awk (gawk -f)
```

### 9.2 Script-to-script (pipeline) dependencies

```
AUTHORS chain:
  export_authors_from_db.sh ─► data/fixtures/authors_list_from_db.txt
        └─► build_prefix_table.sh ─► prefix table
              ├─► prefix_table_integrity.sh   (validate, 0-critical gate)
              └─► prefix_tree_visualizer.sh   (render mkdir -p tree)
        (build_shell_nested_authors.sh — legacy full-name path, same input)

BOOKS chain:
  build_prefix_tree output / Empty_Skeleton ─► merge_books_into_skeleton.sh
        └─► merge_skeleton_into_books.sh ─► Books library (rsync + pv, no overwrite)

LIBRARY chain:
  Books folder ─► refresh_myprivatelib.sh (fingerprint checkpoint)
        ├─► backup_myprivatelib.sh (datadir safety gate)
        └─► populate_myprivatelib.sh (md5-exact match, verbatim keys)
  reconcile_library.sh ─► to-collect list ─► estimate_download_size.sh

REPORTING:
  report_library.sh ◄── data/wishlist.tsv + myprivatelib + mllbr_main (read-only)
```

### 9.3 Cross-repo dependencies (external, informational)

- **flibusta DB schema** (MariaDB 10.4 Windows, `C:\mariadb-10.4.7-winx64`) — populated by the sibling **BookTracker-import** pipeline (dump → ingest).
- **MultiLib.exe** — the consumer application of `myprivatelib`; owns `mllbr_main` wishlist groups.
- Windows interop from WSL2: `/mnt/c/Windows/System32/tasklist.exe`, `taskkill.exe`, `powershell.exe` (UAC elevation).

### 9.4 Meta dependencies

- `bin/bump-version.sh` ↔ `tests/test_version_sync.sh` ↔ README release table ↔ RELEASE_NOTES lines ↔ per-script headers/`SCRIPT_VERSION` (5-way consistency contract).
- CI lists suites explicitly; a new suite must be added to `ci.yml` (current state: complete — 15/15 wired).

---

## 10. File disposition

| Class | Items | Disposition for refactor |
|---|---|---|
| Core tools (keep, refactor in place) | all 14 `bin/*.sh` | Phase 4 targets; order per Updated Plan §8 |
| Shared libs (keep, extend) | `lib/mariadb_lifecycle.sh`, `lib/merge_books_functions.sh`, `lib/utf8_prefix_generator.awk` | Phase 3 seeds the common- infrastructure layer around them |
| Configs | 8 × `config/*.conf` | Keep pattern; centralize DB defaults in Phase 3 |
| Data (tracked) | fixtures, wishlist.tsv, 8 SQL files | Keep; ASCII rename already done (`328bdd9`) |
| Data (ignored) | `data/archives/*` | Never commit (2×12 dump files) |
| Active docs | Updated Plan, Entry/Exit Criteria, Measurable Criteria, PHASE_01_INVENTORY, NEXT, DO_IT_ongoing, MultiLib_Flibusta_DB | Keep at `docs/` top level |
| Historical docs | REFACTORING_BLUEPRINT, REPRESENTATION_PLAN, BOOK_LIBRARY_MERGE_PLAN, COVERS_PLAN, user guides, NB_001, Flibusta_DB_findings | Keep but mark/archive when superseded (see §11.2) |
| Ignored scratch | `tmp_*`, `merge_skeleton_into_books_*.tsv`, `commit_msg/`, `_Save_Stuff/` | No action (already ignored) |
| Stale references | `CHANGELOG.md:613` mentions old Cyrillic filename | Historical log line — leave as-is (do not rewrite history); new entries use the ASCII name |

---

## 11. Duplicate / obsolete functionality & hotspots

### 11.1 Duplicated conventions (Phase 3 extraction targets)

Copy-pasted across tools today, to become `lib/common.sh` (or equivalent) per Updated Plan §7:

1. Header/version block + `--version` handling (`SCRIPT_VERSION` pattern).
2. `log()` (levels info/warn/error/debug), log-prefix format.
3. CLI conventions: `--force/--dry-run/--debug/-h` parsing, usage blocks, exit codes 0/1/2.
4. Config loading (conf-first, env-overrides) and `${VAR:-}` validation.
5. MariaDB connection argv assembly (exists in lifecycle lib but each tool re-assembles mysql args).
6. Temp-file / trap cleanup patterns (house NOTIN-style temp files, traps).

### 11.2 Overlapping planning documents

Three documents describe phase structure: **Blueprint** (§9–11 functional groups + layout), **Updated Refactoring Plan** (authoritative phases 1–5), **Entry/Exit Criteria** (gates). The Updated Plan supersedes the Blueprint's phase content; the Blueprint remains valuable for its rename map and target layout. *Recommendation:* add "superseded-in-part" banners rather than merging, to preserve history.

### 11.3 Two-tier versioning

Repo tags `v1.x` (releases) vs per-tool versions (0.2.x–6.6.10). The 5-way sync contract keeps them consistent. *Recommendation:* document the policy (release tag = repo snapshot; tool version = artifact identity) in README during Phase 2.

### 11.4 Obsolete / retired functionality

- **Skeleton-folder era:** `Empty_Skeleton` workflow was replaced by generated trees; `build_shell_nested_authors.sh` (v6.6.10) and `merge_skeleton_into_books.sh` still reference it. Deprecation decision needed in Phase 4 (likely keep both, mark legacy paths in usage).
- **COVERS_PLAN.md** — closed workstream; archive.
- **`qry_authors_4_and_5_love_hard.sql`** — kept deliberately as historical fixture source (annotate, don't delete).

### 11.5 Known resolved items (for the record)

- Cyrillic SQL filename → ASCII (`328bdd9`); `docs/refactoring/` folder flattened back into `docs/` (`8483292`); `actions/checkout` v4→v5 bump carried over from MultiLib_Utilities CI.

---

## 12. Metrics snapshot

| Metric | Value |
|---|---|
| Tools in `bin/` | 14 |
| Shared libraries | 3 (2 `.sh`, 1 `.awk`) |
| Test suites | 15 (incl. 1 e2e, 1 meta) — all in CI |
| Config files | 8 |
| SQL files | 8 |
| Docs | 13 (+ this file) |
| Repo release tags | 7 (v1.0.0 → v1.6.0) + 6 legacy per-tool tags |
| Largest tracked file | `data/sql/CTE_table.sql` (352 KB) |
| Working-tree state at audit | clean, `main` == `origin/main` |

---

## 13. Phase 1 exit-criteria checklist

| Criterion (per Updated Plan §4/5) | Status |
|---|---|
| Repository tree produced | ✅ §2 |
| Shell dependency map | ✅ §9.1 |
| Script-to-script dependency map | ✅ §9.2 |
| Configuration dependency map | ✅ §6, §9 |
| Data dependency map | ✅ §7, §9.2 |
| File disposition (keep/refactor/archive/ignore) | ✅ §10 |
| Duplicate/obsolete functionality identified | ✅ §11 |
| External/cross-repo dependencies documented | ✅ §9.3 |
| Inventory committed to `docs/` | ✅ this document |

**Phase 1 complete — next phase:** Phase 2 (Define Target Architecture) per the Updated Plan §6.
