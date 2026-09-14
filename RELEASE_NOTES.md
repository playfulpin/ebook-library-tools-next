# Author Toolchain — current milestone

**Latest release: v1.10.0 (2026-09-13)** — the Flibusta extraction
pipeline (branch `feature/flibusta-fb2-extract`, PR #1): a complete,
live-verified path from the Flibusta range archives
(`f.<TYPE>-START-END.zip`) to the placed book library — three extractors
(bookid / author / series) on one shared engine, catalog-driven placement,
and a single-process round orchestrator.  Both stages are sourceable
libraries; live testing on real data caught and fixed three defects the
mock suites could not see (SIGPIPE member resolution, usr filename
lookup, a 30× batch hot-path slowdown).  Battery 21/21, shellcheck
clean, layer gate green.

The previous release, **v1.9.0 (2026-09-13)**, was Follow-It §4, strict
layer boundaries: the domain logic that lived in `lib/books_functions.sh`
left the infrastructure layer (inlined into its only consumer
`bin/books/books_merge.sh`, which is now self-contained),
`lib/database.sh` no longer names application tools, and the dependency
rule — *lib/ is domain-free, bin/ sources only from lib/* — is enforced
mechanically by the `bin/check_layers.sh` gate wired into CI.
Every step confirmed before work started; version sync 15/15,
shellcheck clean, layer gate green throughout.

The previous release, **v1.8.0 (2026-09-13)**, was the tests split
(D-02.11): the flat `tests/` layout reorganized into
**unit / integration / e2e** groups with a battery runner
(`tests/run_all.sh`), shared fixtures in `tests/fixtures/`, goldens in
`tests/integration/golden/`, CI rewritten around the runner, and the
layout documented in `tests/README.md`.

The previous release, **v1.7.1 (2026-09-12)**, was Phase 5, function
headers & coding standards: all 21 production shell files standardized,
every non-trivial function documented (args / returns / side effects),
and ShellCheck `--severity=warning` clean across every production file.

Before that, **v1.7.0 (2026-09-12)** was the rename era: refactoring
Phases 1–4 executed and signed off, the ratified
`bin/{authors,books,library}/` layout fully landed, `ARCHITECTURE.md`
published as the permanent as-built reference, and the docs archive
established.

A Bash + AWK toolchain that turns a flat author list into UTF-8-safe,
byte-ordered prefix structures: a prefix table, its integrity check, a rendered
prefix tree, and a nested directory hierarchy — all validated against a real
6,088-author dataset.  It also provides safe tools for merging a legacy book
archive into an author-prefix skeleton and finalizing that skeleton into the
Books library.

## Shipped tools

- `bin/authors/authors_tree_build.sh` **6.6.10** — nested directory-tree builder (`mkdir -p` / SQL; apostrophes become `^` in SHELL output)
- `bin/authors/authors_prefix_build.sh` **1.0.4** — pre-order trie prefix-table generator
- `bin/authors/authors_prefix_check.sh` **1.2.1** — ultra-strict table validator
- `bin/authors/authors_prefix_tree.sh` **2.8.1** — Unicode tree renderer
- `lib/utf8_prefix_generator.awk` **1.1** — original AWK generator (parity reference)
- `bin/books/books_merge.sh` **0.2.1** — merge a legacy archive into an in-memory author-prefix hierarchy (pruned, timestamped `BooksInput_<ts>` staging; no on-disk skeleton)
- `bin/books/books_finalize.sh` **0.2.3** — finalize a `BooksInput_*` staging tree into the Books library with rsync (destination wins, live `pv -l` item-count progress bar with `--info=progress2` fallback, empty-dir prune after merge)
- `bin/check_layers.sh` **1.2.0** — layer-boundary gate (Follow-It §4): `lib/` code lines must be domain-free and every `bin/` tool may source only from `lib/`, its own group's underscore-prefixed includes (`bin/<group>/_*.sh`), or — for orchestrators only (`bin/<group>/run_*.sh`) — the other tools of its own group sourced as libraries (the `*_LIB_ONLY=1` contract; no orchestrator-chaining). Fails CI on violation. The AWK parity reference is a documented, deliberate exemption (its variable vocabulary IS the domain by design)
- `bin/authors/authors_export.sh` **1.0.2** — regenerate the flat author list (`data/fixtures/authors_list_from_db.txt`) straight from the MariaDB catalog by running a query file (default `data/sql/qry_authors_4_and_5_all.sql`); uses the same `MYSQL_*` connection contract as BookTracker-import, and mirrors its MariaDB lifecycle (auto-start a stopped server via elevated PowerShell, graceful SHUTDOWN on exit, already-running servers left untouched) — the lifecycle now lives in the shared `lib/mariadb_lifecycle.sh`
- `bin/books/books_reconcile.sh` **1.0.3** — personal-catalog collection-progress report: the scope file (`data/fixtures/authors_list_from_db.txt`) is the recommended-author list, and the library root (default `/mnt/c/Backup_Go7/Books`) is where the user collects those authors' books; the report counts how much of the list is collected (`collected` / remaining-to-collect / empty) and what extra content sits beyond the list (the user's own picks, known / unknown to the catalog), with catalog book counts (mlauthorname snapshot) vs on-disk file counts, output as a progress summary plus a per-run TSV report — and it exports the next-round shopping list (recommended authors with no books on disk yet) as a byte-ordered `books_reconcile_to_collect_<ts>.txt` next to the report, plus, in DB mode, the beyond-books review export `books_reconcile_beyond_books_<ts>.tsv` (every on-disk file attributed to a beyond-list author, `author<TAB>relative-path`, to review whether those books should stay; book-less folders that are not on the list are not counted as authors)
- `bin/books/books_estimate.sh` **1.0.0** — catalog download-size estimate for the next collecting round, BEFORE anything is downloaded: given a to-collect author list (the reconcile shopping-list export or the recommended-author fixture), it resolves the names to catalog authorids via an mlauthorname dump (same whitespace normalization as the exporter, so exported lists match 1:1) and sums the real per-book sizes (`mlbook.filesize`) as DISTINCT-book totals — the honest download figures: the qualifying subset (Russian books rated 4/5 in the `Фантастика` genre family, 40,535 books / ~61 GB for the 5,663-author round) and the full oeuvre (all Russian books by those authors, 234,388 books / ~432 GB); every run writes a per-author breakdown TSV sorted top-rated first (5-rated qualifying books desc, then qualifying count desc) with the top 10 printed in the summary, so the round can be prioritized author by author (per-author rows attribute co-authored books to each author, so their sums exceed the distinct totals by the multi-author overlap); shares the MariaDB lifecycle via `lib/mariadb_lifecycle.sh`
- `bin/library/library_backup.sh` **1.0.0** — backup / restore of the app-registered personal library DB (`myprivatelib`, the sibling library the MultiLib desktop app created with the same 17-table ml* schema as `flibusta`); the safety net that must exist BEFORE anything is populated into it: `backup` mysqldumps the DB into a timestamped, integrity-checked `.sql.gz` under `BACKUP_DIR` (optional `BACKUP_KEEP` retention), `restore` is safe by design (backs up the current state first, refuses to overwrite a non-empty library without `--force`), plus `verify` (gzip + dump sanity) and `list`; shares the MariaDB lifecycle via `lib/mariadb_lifecycle.sh`, password via `MYSQL_PWD` only
- `bin/library/library_refresh.sh` **1.0.0** — the freshness orchestrator: fingerprints the Books tree (recursive rel-path + size + mtime per file — deliberately not a root-folder stat, which misses changes on the Windows mount), compares against the checkpoint from the previous run, and on change runs the safety backup then the populate rebuild, then writes the new checkpoint; `--force` refreshes unconditionally, `--dry-run` reports the plan, `--status` prints the checkpoint state; "up to date" exits 0 without touching anything (cron-friendly), a child failure aborts leaving the previous checkpoint intact; mock suite 20 assertions
- `bin/library/library_report.sh` **1.2.0** — the personal-library wish list (reading plan): books you want to read within a given time period, stored as plain TSV (`data/wishlist.tsv`: bookid, added, target_period, status, note — deliberately out of the DB so the populate reload never wipes it); `--search` resolves titles/authors to catalog bookids, `--add/--set-status/--remove` manage entries offline, and the default view joins the bookids against `myprivatelib` read-only (title, authors, series + `#position`, rating) rendering a period → author grouped plan with `[ ]/[~]/[x]` status marks, a completion tally and a separate "not in library" section for books planned before they are collected; TSV/Markdown exports via `--export`; shares the MariaDB lifecycle via `lib/mariadb_lifecycle.sh`; mock suite 44 assertions
- `bin/flibusta/extract_bookid_flibusta.sh` **0.4.0** — stage-1 Flibusta extraction by BOOKID FILENUMBER: for each FileNumber, find the range archive `f.<TYPE>-START-END.zip` whose window contains it (fb2 / usr / both — fb2 first, usr fallback; this is the only family tool handling usr), resolve the member (`<N>.fb2` exactly; usr members keep their real basename — pdf/djvu/epub/`.pdf.zip`), extract atomically into the output dir.  Dual-mode: script CLI or library (`FB2_LIB_ONLY=1` → `fb2_parse_args` / `fb2_run` returning codes, per-number results in `FB2_DELIVERED[]`).  Per-archive listing cache + FLB_ARCHIVE/FLB_MEMBER result globals (the 30× batch speedup); sparse numbers are per-item failures, never fatal
- `bin/flibusta/extract_author_flibusta.sh` **0.1.1** — all fb2 books of every author matching a name substring (`mlauthorname.FullName LIKE`): name → authorids → bare-number filenames → the shared extraction chain; `--from-file` batch lists, `--limit`, skip-existing BEFORE archive resolution, quote/%-escaped SQL patterns; DB via lib/database.sh (§8), literal authorid IN-lists (the MariaDB 10.4 subquery-plan hazard is documented in CHANGELOG)
- `bin/flibusta/extract_series_flibusta.sh` **0.1.1** — all fb2 books of every series matching a name substring (`mlseqname.seqname` via `mlseq`); same shape, contracts and SQL guards as the author extractor; live-verified (157 books / 9.7s dry-run)
- `bin/flibusta/place_flibusta_book.sh` **0.3.3** — stage-2 catalog-driven placement: resolves each FileNumber through `flibusta` (`mlbook` → lowest authorid → `mlauthorname.FullName`, lowest seqid → `mlseqname.seqname` + seqnum) and compresses the stage-1 file in place to `ROOT_LOAD/<FullName>[/<Series>]/<NN - Title>.zip` (two-digit series padding, Windows-unsafe chars sanitized, atomic temp+mv, extension dropped).  Trash-source default (`--keep-source` opt-out; `--rm-source` accepted no-op), existing targets skipped unless `--force`, `--dry-run` resolves and writes nothing (missing source = would-place), per-run TSV report; usr lookup matches `filename = N` OR `N.%` (exact preferred).  Dual-mode library (`PLACE_LIB_ONLY=1` → `place_parse_args` / `place_run`, prefixed PLACE_ version constants so both libraries coexist in one process)
- `bin/flibusta/run_round.sh` **0.1.0** — one-command round orchestrator: stage 1 (extract) + stage 2 (place) in a SINGLE process, both stage tools sourced as libraries (the check_layers v1.2.0 sanctioned rule); one summary, one MariaDB lifecycle, and a per-number joined TSV round report (`run_round_<ts>.tsv`: placed / skipped / extracted / failed-stage1 / failed-stage2) — retry = failed-* rows → a new list → re-run, idempotent because placed targets are skipped automatically; `--extract-only` stops after stage 1, `--dry-run` writes nothing
- `bin/flibusta/_flibusta_extract_common.sh` **1.2.0** — shared family engine (intra-group include, layer-gate carve-out): per-type range index built once per run, member resolution with the per-archive listing cache (SIGPIPE-free whole-listing consumption), atomic `unzip -p` extraction, from-file reader (BOM/CR/blank/#-safe), SQL LIKE/equality escapers; documented result-delivery contract (FLB_ARCHIVE / FLB_MEMBER globals — never command substitutions, which killed the cache per call)
- `bin/library/library_populate.sh` **1.3.0** — rebuild the app-registered personal library DB (`myprivatelib`) from the on-disk `Books` collection (Phase 1 of `docs/archive/REPRESENTATION_PLAN.md`): every book file is md5-hashed (zip-wrapped FB2 by its **decompressed content**, loose `*.fb2` directly) and matched against `flibusta.mlbook.md5`, which the dump pipeline populates for ALL 869,130 catalog rows — so the match is exact and unambiguous.  **Only books present in the `Books` folder are represented**.  **v1.3.0 (per `docs/archive/DO_IT_ongoing.md`) reverses the key strategy: keys are the flibusta SOURCE keys, copied verbatim — no synthetic keys.**  The md5 match resolves a file to the catalog `bookid`, and that `bookid` (plus the source `authorid`/`genreid`/`seqid` and the child PKs `la_id`/`gn_id`/`sq_id`/`rt_id`/`ci_id`) is inserted unchanged; the v1.2.0 tool-assigned 1..N counters and session-variable remaps are gone.  The v1.2.0 **AUTO_INCREMENT strip stays** (all 16 PK columns, schema-driven attribute-preserving `ALTER`s verified via `information_schema` — per `docs/archive/DO_IT_ongoing.md`, the app treats server-generated PK columns differently from the original schema's plain ones): a stripped PK is exactly what makes the verbatim source keys loadable.  A new post-reload **FK integrity gate** verifies 9 reference paths (any orphan aborts).  The whole rebuild is one SQL script in a single session (`TRUNCATE` first = clean purge-and-reload).  Reference tables (`mlauthorname`, `mlgenrename`, `mlseqname`) are inserted for the personal library's books only; `mlgenrename` pulls the **ancestor categories** of the used genres (the catalog's 1000001+ tree rows no book references directly) so the genre tree the app renders is preserved — `parentgenreid` is the source value verbatim, the tree is self-consistent; `mlbook.filename` carries the **catalog value** (`flibusta.mlbook.filename`, the transliterated name the app displays) instead of the on-disk path — `arcname` (on-disk zip member) and `filesize` (on-disk bytes) unchanged.  `mlrating` is copied from `flibusta.mlrating` (the per-book aggregate produced by `BookTracker-import/sql/Flibusta_Load_mlrating.sql`) for books that have a rating.  `flibusta` is read-only, app-owned tables in `myprivatelib` are never touched, `mlcoverpage`/`mldescription` stay empty; a column-parity mismatch on ANY managed table aborts the run before any `TRUNCATE`;  every run writes a matched/unmatched TSV report to `POP_REPORT_DIR`; shares the MariaDB lifecycle via `lib/mariadb_lifecycle.sh`, password via `MYSQL_PWD` only; mock suite `tests/test_library_populate.sh` 35 assertions

### Database reference

- **`docs/MultiLib_Flibusta_DB.md` (rev 2)** — the comprehensive, live-verified reference for the MariaDB instance behind the MultiLib app and the Flibusta catalog: the three databases (`flibusta`, `myprivatelib`, `mllbr_main`), the shared 17-table ml\* schema (full column reference), relationships and the **verified two-level genre tree** (24 root category rows id 1000001+, 272 leaf genres, books join leaves only), the AUTO_INCREMENT / no-FK key strategy (sparse catalog ids vs contiguous fresh keys in `myprivatelib`), the lib\* dump schema and load order, the BookTracker-import ingest stages and mlrating aggregation, the populate tool's data flow, and the connection contract / invariants.  Accompanying it: **`data/sql/qry_catalog_reference.sql`**, a self-contained runnable script with the quick-reference queries (genre tree, full-book lookup, md5 lookup, table parity).  See also `docs/archive/REPRESENTATION_PLAN.md`, `docs/NEXT.md`, `docs/archive/Flibusta_DB_findings.txt`.

## Highlights

- Deterministic `LC_ALL=C` byte-order output — zero byte-order violations on real data.
- Multi-byte prefix-slicing fixes (`utf8_chop`, `utf8_prefix`) so trees descend through every level under byte locales.
- New end-to-end pipeline suite locks out cross-tool format drift.
- Root-only layout finalized — the `release/` snapshot model is retired; the root script is the released artifact.
- Tool-prefixed release tags: `build_prefix_table-1.0.4`, `prefix_table_integrity-1.2.1`, `utf8_prefix_generator-1.1` (plus the earlier `v6.6.8`, `v2.8.1`).

### Book-library merge tools

- **`merge_books_into_skeleton.sh` (0.2.0)**  
  Builds the author prefix tree **in memory** from a flat author list (the
  same range-walk algorithm as `bin/authors/authors_tree_build.sh` —
  `MERGE_MIN_AUTHORS` pruning, `MERGE_MAX_PREFIX` cap), then copies every
  top-level author folder from the legacy archive into the deepest valid
  prefix.  Output lands directly in a timestamped, **pruned** staging tree
  `<output-root>/BooksInput_<timestamp>` — the `Empty_Skeleton` folder is
  gone: it is neither built nor consumed.  Supports recursive series copy,
  configurable overwrite policy, skip-list for Windows metadata, dry-run
  reports, and config-file / environment overrides.

- **`merge_skeleton_into_books.sh` (0.2.0)**  
  Replaces the rename → prune → copy loop with a thin, validated **rsync**
  wrapper: `rsync -a --ignore-existing` onto the Books library (destination
  wins, never overwrites), with auto-discovery of the newest `BooksInput_*`
  folder, path-safety guards, and a per-file TSV report (`copied` /
  `would-copy` / `kept-existing` / `would-keep`).

## Testing

- **CI (GitHub Actions):** every push/PR runs shell syntax checks, the
  version-sync suite, and all ten test suites on `ubuntu-latest`.
- Prefix-table family: green under WSL (prefix table, nested-authors,
  visualizer, AWK generator, e2e pipeline) and in CI on Linux bash.
- Merge tools: the merge suite slices UTF-8 prefixes, so it runs under WSL
  (byte-based Git Bash mangles Cyrillic); the finalize suite needs rsync and
  real POSIX paths (WSL/Linux — MSYS rsync cannot sync Windows-drive paths),
  and skips cleanly when either is absent.
  - `test_merge_books_into_skeleton.sh` — in-memory prefix build, pruned
    staging output, dry-run, overwrite policies, config/env precedence, etc.
  - `test_merge_skeleton_into_books.sh` — rsync dry-run and full run,
    keep-existing conflicts, auto-detection, CLI, version header.
- `test_version_sync.sh` — every tool's version identical across header,
  lib twin, README table, and RELEASE_NOTES; backed by `bin/version_bump.sh`
  which edits all locations in one command.
