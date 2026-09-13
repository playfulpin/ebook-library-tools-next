# tests/ — the test battery

> Last updated: 2026-09-13
> Layout: D-02.11 option (b) — unit / integration / e2e, landed 2026-09-13
> (commit `34559c0`).  See `ARCHITECTURE.md` §11 for the as-built rationale.

The battery is grouped by test level and executed in canonical order —
**unit → integration → e2e** — by the runner `tests/run_all.sh`.  16
suites total: 12 unit, 3 integration, 1 e2e.

```
tests/
├── run_all.sh            # battery runner (group filters, -q, traced-caller guard)
├── unit/                 # 12 suites — one per tool/lib, fully mocked, run anywhere
├── integration/          # 3 suites — golden-file baselines (WSL-class)
│   └── golden/           #   20 byte-exact regression baselines
├── e2e/                  # 1 suite — cross-tool chain on real data (WSL-class)
├── fixtures/             # 7 shared input fixtures (case_*.txt, viz_*.txt)
└── README.md             # this file
```

## Running

```bash
tests/run_all.sh              # everything: unit -> integration -> e2e
tests/run_all.sh -q           # one line per suite (summary output only)
tests/run_all.sh unit         # a single group: unit | integration | e2e
tests/run_all.sh -q unit e2e  # several groups, in the given order
tests/run_all.sh -h           # help
```

A single suite can also be run directly:

```bash
bash tests/unit/test_library_report.sh                 # runs anywhere
wsl.exe tests/integration/test_authors_tree_build.sh   # needs WSL-class bash
```

Exit codes: `0` all selected suites passed, `1` at least one suite
failed, `2` usage error (unknown group or missing group directory).

**Do not re-introduce the old flat loop** — `for t in tests/test_*.sh`
matches nothing now that suites live in group directories.  Use the
runner.

## The three levels

### `unit/` — one suite per tool or lib

Fully mocked (mock `mysql`, `rsync`, `pv`, MariaDB lifecycle, PATH
shims), hermetic against a dirty caller shell, and **runs anywhere** —
CI executes them directly on stock ubuntu-latest.  No network, no
database, no writes outside a `mktemp` sandbox.

| Suite | Under test | Notes |
|---|---|---|
| `test_authors_export.sh` | `bin/authors/authors_export.sh` | argv, rows, lifecycle mocks |
| `test_books_merge.sh` | `bin/books/books_merge.sh` | archive → in-memory prefix hierarchy |
| `test_books_finalize.sh` | `bin/books/books_finalize.sh` | BooksInput_* → Books rsync finalize |
| `test_books_reconcile.sh` | `bin/books/books_reconcile.sh` | classification + collection-progress summary |
| `test_books_estimate.sh` | `bin/books/books_estimate.sh` | sums, top-rated breakdown, lifecycle mocks |
| `test_library_backup.sh` | `bin/library/library_backup.sh` | argv, gz artifact, restore guards |
| `test_library_populate.sh` | `bin/library/library_populate.sh` | md5 map, verbatim keys, parity abort |
| `test_library_refresh.sh` | `bin/library/library_refresh.sh` | checkpoint decisions, failure isolation |
| `test_library_report.sh` | `bin/library/library_report.sh` | wish-file format, views, exports |
| `test_lib_infrastructure.sh` | `lib/*.sh` | init, root detection, logging, cli, fs, db argv |
| `test_utf8_prefix_generator.sh` | `lib/utf8_prefix_generator.awk` | direct AWK edge-case tests |
| `test_version_sync.sh` | all of `bin/` + `lib/` | version agrees across 4 locations (14 checks) |

### `integration/` — golden-file suites

Multi-component suites that compare tool output byte-for-byte against
checked-in goldens in `integration/golden/`.  These are **WSL-class**:
they rely on multibyte-safe bash and `gawk`, so run them under WSL
(CI gives them a dedicated step; they also self-probe and refuse to run
on byte-slicing shells such as cygwin's bash).

| Suite | Under test | Goldens cover |
|---|---|---|
| `test_authors_prefix_build.sh` | `bin/authors/authors_prefix_build.sh` | generator output for the case fixtures; CRLF/BOM handling; real-fixture byte-order + integrity |
| `test_authors_prefix_tree.sh` | `bin/authors/authors_prefix_tree.sh` | rendered trees (full / filtered / depth-limited); descent + CLI behavior |
| `test_authors_tree_build.sh` | `bin/authors/authors_tree_build.sh` | mkdir/SQL/SHELL outputs; defaults; debug; custom roots; prune |

All three accept `--regen` to rewrite their golden files from current
output.  Goldens are byte-exact regression baselines — **never
regenerate casually**; a golden diff is a format change and must be
reviewed as such (ARCHITECTURE.md §11).

### `e2e/` — the cross-tool chain

`test_e2e_pipeline.sh` chains three tools on the **real** fixture
(`data/fixtures/authors_list_from_db.txt`, 5,707 authors):
`authors_prefix_build` (generator) → `authors_prefix_check`
(validator) → `authors_prefix_tree` (renderer).  It locks out
cross-tool format drift — if the generator's output format shifts, the
validator/renderer chain fails here rather than in production.
WSL-class, like the integration suites.

## Fixtures and ownership

Shared inputs live in `fixtures/` and are owned per suite:

| Fixture | Used by | Content |
|---|---|---|
| `case_spaces.txt` | prefix_build, tree_build | names with inner/multiple spaces |
| `case_case_variants.txt` | prefix_build, tree_build | case-variant duplicates |
| `case_duplicates.txt` | prefix_build, tree_build | exact duplicates |
| `case_quotes.txt` | prefix_build | quoted names |
| `case_apostrophe.txt` | tree_build | apostrophes (SHELL output maps `'` → `^`) |
| `viz_mini.txt` | prefix_tree | minimal tree (punctuation + Cyrillic roots) |
| `viz_spaces.txt` | prefix_tree | space-bearing names for rendering |

Notes:

- `edge` and `crlf` inputs are **generated at runtime** into the suite's
  `mktemp` sandbox (edge-case list, CRLF twin of `case_spaces.txt`) —
  they are not checked in.
- `data/fixtures/authors_list_from_db.txt` (5,707 authors) is the
  real-data fixture used by the e2e suite and — as the configured
  default input — by the `books_merge` suite.  It lives with the
  project data, not here, because production tools read it too.
- Golden files belong to exactly one suite each (the integration suites
  listed above); no sharing.

## Conventions

- **Every suite is self-contained**: it resolves its own paths from
  `BASH_SOURCE`, builds all scratch state under `mktemp -d`, and writes
  nothing into the repository (the runner and suites may be invoked from
  any working directory).
- **Hermetic against the caller**: every suite and the runner re-exec
  themselves without `SHELLOPTS`/`BASHOPTS` when xtrace/verbose is
  detected, and unset leak-prone environment (`MYSQL_*`, `ETL_DEBUG`)
  where a `bash -c` block asserts on it.  A dirty interactive shell
  must not change results — this was learned the hard way (see
  CHANGELOG 2026-09-12/13 entries).
- **No version stamps in test files**: the version-sync gate
  (`test_version_sync.sh`, mirrored by `bin/version_bump.sh`) covers
  `bin/` and `lib/` headers only; test suites are not versioned.
- **Adding a suite**: put it in the group that matches its level, name
  it `test_<command>.sh`, and it is picked up by the runner and CI
  automatically — no registration list to update.
