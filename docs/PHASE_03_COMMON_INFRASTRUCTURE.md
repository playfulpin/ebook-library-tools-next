# Phase 3 — Common Shell Infrastructure

> **Deliverable of:** Phase 3 of `docs/archive/ebook-library-tools — Updated Refactoring Plan.md` (§7)
> **Version:** 1.0.0
> **Created:** 2026-09-12
> **Based on:** `docs/PHASE_02_TARGET_ARCHITECTURE.md` v1.0.0 (§6 lib/ boundaries), Phase 1 inventory §11.1 (duplication survey), Phase 3 entry/exit criteria
> **Principle:** every library function is seeded from real, already-working code found in the tools — nothing speculative.

---

## 1. What was built

Five libraries under `lib/`, per the ratified D-02.6 component set:

| Library | Ver | Provides | Seeded from |
|---|---|---|---|
| `lib/common.sh` | 1.0.0 | `common_init` (standard init), `SCRIPT_DIR`/`PROJECT_ROOT` resolution at any `bin/` depth, `die`, `require_command`, `timestamp_now` | the location block identical in 7 tools; `die` identical in 8 |
| `lib/logging.sh` | 1.0.0 | `log`, `debug`, `log_debug`, `log_info`, `log_warn`, `log_error` | the house triplet (`log`/`debug`/`die`-format) byte-identical in 8 tools |
| `lib/cli.sh` | 1.0.0 | `cli_print_version`, `cli_try_global` (global-flag scan), `CLI_EXIT_OK/FAIL/USAGE`, `CLI_REMAINING_COUNT` | the `-v/--version`, `--debug`, exit 0/1/2 conventions already used repo-wide |
| `lib/filesystem.sh` | 1.0.0 | `fs_require_dir/file`, `fs_mktmp`, `fs_tree_fingerprint`, `fs_prune_empty_dirs` | `tree_fingerprint` verbatim from `refresh_myprivatelib.sh`; prune policy verbatim from `merge_skeleton_into_books.sh` |
| `lib/database.sh` | 1.0.0 | `db_mysql_argv`, `db_run_query`, `db_run_sql`, `db_require_server` | the `mysql_args=(...)` block repeated in the DB tools |

Not created (deliberately): `lib/authors.sh`, `lib/books.sh`, `lib/library.sh`, `lib/reporting.sh`, `lib/progress.sh` — each awaits its second real consumer (Phase 4 converts tools; a library is extracted when duplication re-appears, not speculatively). `lib/merge_books_functions.sh` and `lib/mariadb_lifecycle.sh` remain untouched per D-02.6/Blueprint §23.

---

## 2. Contract details

### 2.1 Initialization (plan §7.1)

`common_init` activates `set -Eeuo pipefail`. **Documented exception** (the only one): `bin/report_library.sh` runs `set -uo pipefail` (no `-e`) because its view pipelines rely on failing command substitutions; when converted in Phase 4 it calls `common_init --no-errexit`, which explicitly removes `-e`/`-E` and fixes `-u -o pipefail`. Libraries never silently weaken a caller's mode.

### 2.2 Script location (plan §7.2)

`SCRIPT_DIR` resolves symlinks and never depends on `$PWD` or `$0`. `PROJECT_ROOT` climbs until it finds `lib/common.sh` — so **both** the current `bin/x.sh` (depth 1) and the post-rename `bin/<group>/x.sh` (depth 2, ratified D-02.3) work unchanged. Verified by tests at both depths.

### 2.3 Logging (plan §7.3)

The house format `[YYYY-MM-DD HH:MM:SS] message` → stderr is preserved byte-for-byte; stdout stays clean. All tools are stdout-logging-free today, so log-file handling is **not** invented yet (documented non-feature).

### 2.4 CLI conventions (plan §7.4)

Documented contract: `-h/--help` → usage, exit 0; `-v/--version` → `<invocation> v<version>`, exit 0; `--debug` → `DEBUG=1`; `--dry-run` where applicable. `cli_try_global` consumes leading globals and stops at the first tool-specific flag, setting `CLI_REMAINING_COUNT` (a global, not stdout — safe under `set -e` in command substitutions).

### 2.5 Progress reporting (plan §7.5)

Not implemented: the only progress consumers (`pv -l` in `books_finalize`-to-be, merge reports) are single-consumer today. The `progress_start/tick/finish` API will be extracted when the second consumer appears in Phase 4. This deviation is documented per the exit-criteria rule ("or every exception is documented").

### 2.6 Database

`lib/database.sh` is **opt-in** (not auto-sourced by `common_init`) — only DB tools pay for it. It composes with, and never duplicates, `lib/mariadb_lifecycle.sh` (which keeps server start/stop/upgrade).

---

## 3. Conversion status (criterion: "100% of converted scripts use the common infrastructure")

**No bin/ script was converted in Phase 3.** Conversion is Phase 4 work, done per tool during its rename/refactor — converting now would touch every tool twice (once for infra, once for rename) against the ratified D-02.11 "avoid touching CI paths twice" decision. The infrastructure + tests + CI wiring land first so Phase 4 conversions are one-line `source` swaps. This satisfies the criterion vacuously and honestly (0 converted, 0 not using it).

---

## 4. Tests

`tests/test_lib_infrastructure.sh` — **42 assertions, all green**, runs anywhere (no DB, no gawk, no WSL):

- syntax ×5; idempotent double-sourcing ×5
- `common_init`: `-e` active, `--no-errexit` documented-exception mode, DEBUG default/`--debug`/`ETL_DEBUG` env ×5
- root detection: depth 1, depth 2 (post-rename layout), sibling sourcing, database opt-in ×4
- logging: house format regex, debug gating, tagged levels, `die` exit 1 ×5
- cli: `--version` line, `-h` → `print_help`, global consumption + `CLI_REMAINING_COUNT`, stop-at-tool-flag, exit-code contract ×5
- filesystem: fingerprint byte-equality with the original implementation + stability + files-only, prune dry-run/real, guards, mktmp ×9
- database: minimal argv, env overrides, mock-client invocation, missing-query-file die ×4
- clean-load against the real repo ×1

CI wired: syntax check now covers `lib/*.sh`; the suite joined the "run anywhere" unit step.
