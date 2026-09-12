# Phase 4 — Tool Conversion & Rename (progress log)

> **Deliverable of:** Phase 4 of `docs/archive/ebook-library-tools — Updated Refactoring Plan.md` (§8)
> **Version:** 1.2.0
> **Created:** 2026-09-12
> **Based on:** ratified rename map D-02.5 (`docs/PHASE_02_TARGET_ARCHITECTURE.md` §4) and the Phase 3 infrastructure (`docs/PHASE_03_COMMON_INFRASTRUCTURE.md`)
> **Scope:** all 14 tools move into the ratified `bin/<group>/` layout, convert onto the shared `lib/` infrastructure where it genuinely applies, with suites/configs/registries/docs switched in the same commit (clean cutover, D-02.13 — no wrappers). Versions never bump on pure renames (D-02.15).
> **Status:** **all four groups done** — Phase 4 complete pending final docs (ARCHITECTURE.md, completion-criteria sign-off) and release.

---

## 1. Conversion model (what "convert" means per tool)

The Phase 1 inventory identified two tool families, and Phase 4 treats them differently:

| Family | Tools | Conversion |
|---|---|---|
| **Infra consumers** (have `SCRIPT_DIR`/`PROJECT_ROOT` + the `log/debug/die` triplet) | `authors_export`, `books_estimate`, `books_reconcile`, `library_backup`, `library_populate`, `library_refresh`, `library_report`, `books_finalize` (config-path resolution only) | `git mv` **+** delete the local `log/debug/die` copies and hand-rolled root detection, source `lib/common.sh` + `common_init` (depth-2 aware) |
| **Pure filters** (stdin/argv → stdout, no root, no logging) | `authors_prefix_build`, `authors_prefix_check`, `authors_prefix_tree`, `authors_tree_build`, `books_merge` (lib-composed), `version_bump` | `git mv` **+** self-reference updates only — forcing `common_init` would add nothing; their CLI contracts are kept (documented deviation) |

Per-commit checklist (every group, no exceptions):
1. `git mv` tool + suite + config (history preserved).
2. Update tool self-references: header comment, `Usage:` line, `-v/--version` banner.
3. Update suite: `SCRIPT=` path, banner/version regexes, report-filename globs, mock layouts.
4. Update registries: `bin/bump-version.sh` (registry key stays, paths change, `[was <old>]` note) + `tests/test_version_sync.sh` (primary/twin/marker).
5. Update `ci.yml` suite names (syntax glob `bin/*.sh bin/*/*.sh` already extended in Phase 3).
6. Update `README.md` (usage sections, release table incl. tag names), `RELEASE_NOTES.md`, config-file headers, cross-references in other tools and `lib/` provenance comments.
7. Full battery: syntax, version sync, all affected suites under WSL, then push — CI must be green before the next group starts.

---

## 2. Group 1 — AUTHORS chain (DONE)

Commits: `b3f9811` (pilot), `acebddd` (rest of group).

| Old | New | Infra converted | Suite |
|---|---|---|---|
| `bin/export_authors_from_db.sh` | `bin/authors/authors_export.sh` | ✅ `common_init` (local log/debug/die + root block deleted) | `tests/test_authors_export.sh` (18 ✅) |
| `bin/build_prefix_table.sh` | `bin/authors/authors_prefix_build.sh` | — (pure filter) | `tests/test_authors_prefix_build.sh` (35 ✅) |
| `bin/prefix_table_integrity.sh` | `bin/authors/authors_prefix_check.sh` | — (pure filter) | `tests/test_authors_prefix_check` via e2e ✅ |
| `bin/prefix_tree_visualizer.sh` | `bin/authors/authors_prefix_tree.sh` | — (pure filter) | `tests/test_authors_prefix_tree.sh` (12 ✅) |
| `bin/build_shell_nested_authors.sh` | `bin/authors/authors_tree_build.sh` | — (pure filter) | `tests/test_authors_tree_build.sh` ✅ |

Incident notes: the depth-2 lib source path was first wrong (`../lib` instead of `../../lib`) — caught by the suites; suite-internal banner regexes still expected old names — caught by `cli_help_version`/`cli_banner_stderr_only`/`cli_no_table_usage` assertions. Both fixed in the same commits.

## 3. Group 2 — critical BOOKS merge pair (DONE)

Commit: `68d2bcf`, plus `cb17b2d` (gitignore cleanup).

| Old | New | Notes |
|---|---|---|
| `bin/merge_books_into_skeleton.sh` | `bin/books/books_merge.sh` | sources its lib at depth 2; lib twin renamed with it |
| `lib/merge_books_functions.sh` | `lib/books_functions.sh` | version-sync twin; 99% similarity |
| `bin/merge_skeleton_into_books.sh` | `bin/books/books_finalize.sh` | report file renamed `books_finalize_<ts>.tsv` |
| configs ×2 | `config/books_merge.conf`, `config/books_finalize.conf` | headers updated |

Incident note: renaming the `.gitignore` report patterns exposed the workspace scratch file `merge_skeleton_into_books_20260831-150603.tsv`, which `git add -A` staged accidentally; `cb17b2d` untracked it and kept the legacy pattern ignored.

## 4. Group 3 — estimate/reconcile + LIBRARY trio (DONE)

Commits: this changeset. Five tools, all infra consumers → **all five converted onto `common_init`**:

| Old | New | Suite (renamed) |
|---|---|---|
| `bin/estimate_download_size.sh` | `bin/books/books_estimate.sh` | `tests/test_books_estimate.sh` ✅ |
| `bin/reconcile_library.sh` | `bin/books/books_reconcile.sh` | `tests/test_books_reconcile.sh` ✅ |
| `bin/backup_myprivatelib.sh` | `bin/library/library_backup.sh` | `tests/test_library_backup.sh` ✅ |
| `bin/populate_myprivatelib.sh` | `bin/library/library_populate.sh` | `tests/test_library_populate.sh` ✅ |
| `bin/refresh_myprivatelib.sh` | `bin/library/library_refresh.sh` | `tests/test_library_refresh.sh` ✅ |

Behavioral renames that follow the tool rename: reconcile exports are now `books_reconcile_to_collect_<ts>.txt` / `books_reconcile_beyond_books_<ts>.tsv`, the estimate breakdown is `books_estimate_<ts>.tsv`, the populate report is `library_populate_<ts>.tsv`, the reconcile report is `books_reconcile_<stamp>.tsv`.

Incident notes: the refresh suite's mock project had to be upgraded — the orchestrator now resolves children as `$PROJECT_ROOT/bin/library/<tool>` and sources `lib/common.sh`, so the mock carries `bin/library/` children and a copy of the real `lib/` (this is the intended effect of the infrastructure: the old copy could never have caught it). Suite globs for the renamed report files were caught by the suites themselves.

## 5. Group 4 — final (DONE)

Commits: this changeset. Two moves + one infra conversion:

| Old | New | Notes |
|---|---|---|
| `bin/report_library.sh` | `bin/library/library_report.sh` | infra consumer — **converted onto `common_init --no-errexit`** (the documented §7.1 exception applied as planned: the leftover `set -uo pipefail` is a deliberate no-op on top of `set -Euo pipefail`; local `log/debug/die` deleted, the triplet now exists only in `lib/logging.sh`) |
| `bin/bump-version.sh` | `bin/version_bump.sh` (flat in `bin/`) | registry self-reference fixed; **case registry keys updated to the new names** (`authors_tree_build`, `authors_prefix_build`, `authors_prefix_check`, `authors_prefix_tree`, `authors_export`) — this closes a latent inconsistency: the usage text already advertised the new keys while the case statement still answered only the old ones, so those bumps would have failed; version 1.0.1 → 1.0.2 (behavioral fix) |
| `config/report_library.conf` | `config/library_report.conf` | tool's `shellcheck` source comment updated to the depth-2 relative path |
| suite | `tests/test_library_report.sh` | 71/71 green; section banners updated to the new tool name |
| registries | `bump-version` case registry, `test_version_sync` registry, README (tool section + testing list + release-table tag + repo layout + bump example), RELEASE_NOTES | clean cutover |

Incident notes: the `version_bump` case-registry mismatch was found and fixed during the group-4 sweep (usage text vs case keys disagreed for five tools); the `-h`/`--help` contract is unchanged. Historical docs (`DO_IT_ongoing.md`, the User Guide) keep old paths deliberately — they are dated archives, not living instructions.

## 5b. Phase 4 wrap-up

After group 4: `ARCHITECTURE.md` is distilled from the ratified Phase 2 document (D-02.12), `docs/Measurable Phase Completion Criteria.md` gets its Phase 4 sign-off, and a release (repo tag) cuts.

## 6. Validation state after groups 1–4

- Syntax: `bin/*.sh` + `bin/*/*.sh` + `lib/*.sh` all clean.
- Version sync: **14/14**.
- Suites green under WSL: all five group-3 suites, both group-2 suites, all five AUTHORS suites, `test_library_report` (71), `test_lib_infrastructure` (42), e2e pipeline (real fixture), utf8 generator suite.
- CI: green on every group commit (`b3f9811`, `acebddd`, `68d2bcf`, `cb17b2d`, group-3 `b1a540a`).
