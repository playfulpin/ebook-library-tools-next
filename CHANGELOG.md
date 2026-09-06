# Changelog

All notable changes to the author-toolchain scripts in this repository:
`bin/build_shell_nested_authors.sh` (directory-tree builder),
`bin/build_prefix_table.sh` (prefix-table generator),
`bin/prefix_tree_visualizer.sh` (tree renderer),
`bin/merge_books_into_skeleton.sh`, and
`bin/merge_skeleton_into_books.sh`.

## [Unreleased]

- **`bin/report_library.sh` v1.0.0 — new tool: the personal-library wish
  list (reading plan) and reporting view.**  A wish entry is a book you
  want to read within a given time period; state lives in a plain TSV
  file (`data/wishlist.tsv`: `bookid`, `added`, `target_period`,
  `status`, `note`; comments/blanks allowed, BOM/CR tolerated) and is
  deliberately kept OUT of the database so the populate TRUNCATE-reload
  cycle never wipes the plan.  Mutations (`--add BOOKID
  [--period P] [--note N]`, `--set-status BOOKID wish|reading|done`,
  `--remove BOOKID`) never touch the server; `--search SUBSTR` resolves
  titles/authors to candidate bookids (LIKE-escaped, read-only) before
  adding.  The default view joins the wish bookids against
  `myprivatelib` read-only (title, aggregated authors, series +
  `#position`, rating) and renders a target_period → author grouped
  plan with `[ ]` wish / `[~]` reading / `[x]` done marks, a completion
  tally, and a separate "not in library" section for bookids planned
  before they are collected; batches of 500 ids per query;
  multi-author books aggregate with ','; NULL-tolerant.  `--export
  md|tsv` writes `report_wishlist_<ts>.{md,tsv}` into the output dir
  (config `config/report_library.conf`: `REPORT_WISHLIST_FILE`,
  `REPORT_OUTPUT_DIR`, `REPORT_TARGET_DB`, `REPORT_STATUSES`).
  Malformed wish rows are warned and skipped instead of failing the
  run; mutation rewrites preserve header comments; password goes via
  `MYSQL_PWD` only.  Shares the MariaDB lifecycle via
  `lib/mariadb_lifecycle.sh` (auto-start on view/search, never for
  offline modes).  Mock suite `tests/test_report_library.sh` 44
  assertions.

- **`bin/refresh_myprivatelib.sh` v1.0.0 — new tool: the freshness
  orchestrator with a tree-fingerprint checkpoint.**  Closes the loop
  proposed in `docs/Flibusta_DB_findings.txt` (a `stat` checkpoint +
  `PROCESS_FLAG`) as a full pipeline: fingerprint the Books tree
  (recursive rel-path + size + mtime per file, C-sorted), compare against
  the checkpoint from the previous run, and on change run
  `backup_myprivatelib.sh` then `populate_myprivatelib.sh`, then write
  the new checkpoint.  The fingerprint is deliberately recursive — a
  single root-folder `stat` misses changes on the Windows/9P mount
  (folder mtimes do not reliably propagate), while per-file lines catch
  add/remove/resize/touch exactly.  `--force` (initial run / repair),
  `--dry-run` (plan only, no children invoked, no checkpoint written),
  `--status` (checkpoint state + counts); "up to date" exits 0 without
  touching anything so cron/scheduled runs are safe; a child failure
  aborts the run and leaves the previous checkpoint intact (backup
  failure means populate is never invoked).  Child tools are invoked as
  subprocesses with `MYSQL_*` passthrough and `REFRESH_MYSQL_ARGS`
  forwarding — the orchestrator itself never talks to MariaDB.  Config:
  `config/refresh_myprivatelib.conf` (`REFRESH_LIBRARY_ROOT` kept
  explicitly in sync with `POP_LIBRARY_ROOT`).  Mock suite
  `tests/test_refresh_myprivatelib.sh` — **20 assertions** (checkpoint
  shape incl. multibyte paths, the four change kinds, dir-mtime
  non-event, force/dry-run/status, failure isolation, missing root);
  registered in bump-version.sh / test_version_sync.sh / CI.

- **`bin/populate_myprivatelib.sh` v1.2.0 -> v1.3.0 — key strategy
  reversed: flibusta SOURCE keys copied verbatim, NO synthetic keys
  (docs/`DO_IT_20260906_141511.md`).**  The synthetic 1..N key
  generation introduced in v1.2.0 violated the population contract:
  the target must map `flibusta` -> `myprivatelib` strictly by the md5
  checksum of the uncompressed file, with keys preserved per source
  definition.  Changes:

  - every managed INSERT now carries the flibusta key values unchanged:
    the md5-resolved `bookid`, the source `authorid`/`genreid`/
    `seqid`, and the child PKs (`la_id`/`gn_id`/`sq_id`/`rt_id`/
    `ci_id`) straight from the source rows — no tool-assigned
    counters, no `@<var>_<old>` session-variable remaps, no
    `LAST_INSERT_ID()`;
  - `mlgenrename.parentgenreid` is the source value verbatim (the
    source tree is self-consistent, so no parent remap is needed); the
    ancestor fetch dedupes by id when a fetched ancestor is also a used
    genre (both carry the same source id now);
  - the v1.2.0 AUTO_INCREMENT strip is retained unchanged — a verbatim
    source key is a plain PK value, not a server-generated one, and the
    `la_id`/`gn_id`/`sq_id`/`rt_id`/`ci_id` columns are plain `NOT
    NULL` (the strip is exactly what allows the verbatim child PKs to
    load);
  - new post-reload **FK integrity gate**: 9 reference paths checked,
    any orphan aborts the run — with verbatim keys a wrong reference can
    no longer be hidden by a remap;
  - the rebuild remains a purge-and-reload (`TRUNCATE` all 9 managed
    tables first) in a single client session, byte-deterministic;
  - mock suite grown to **35 assertions** (source-key INSERTs for all
    9 tables, no-`SET @var` guarantee, FK gate incl. the
    abort-on-orphans path);
  - `myprivatelib` purged and re-populated live; verification: key
    counts match the distinct-md5 bookids, 0 AUTO_INCREMENT columns, 0
    orphan references.

- **`bin/populate_myprivatelib.sh` v1.1.1 -> v1.2.0 — AUTO_INCREMENT
  stripped from the target schema; explicit tool-assigned keys (docs/
  `DO_IT.md`).**  App re-testing showed MultiLib.exe still misbehaves with
  a populated library: it treats server-generated (AUTO_INCREMENT)
  primary-key columns differently from the original schema's plain PK
  columns.  Two changes, applied to ALL 16 AUTO_INCREMENT PK columns of
  the ml* schema (mlauthor.la_id, mlauthorname.authorid, mlbook.bookid,
  mlcoverpage.cp_id, mlcustinfo.ci_id, mldescription.ds_id,
  mldownloaddata.dd_id, mlgenre.gn_id, mlgenrename.genreid, mlnews.cb_id,
  mlnewsname.critid, mlrating.rt_id, mlseq.sq_id, mlseqname.seqid,
  mluserkeyword.kw_id, mluserprim.up_id):
  - **schema**: before any data lands, the tool emits schema-driven,
    attribute-preserving `ALTER TABLE ... MODIFY COLUMN` statements that
    re-declare each PK column verbatim from `SHOW CREATE TABLE` minus the
    `AUTO_INCREMENT` keyword (type / NULL-ness / DEFAULT / COLLATE and
    the PRIMARY KEY untouched; idempotent — already-plain columns emit
    nothing); the strip includes the app-owned tables (mlactual,
    mldownloaddata, mlnews*, mluser*, mlcoverpage, mldescription) but is
    a schema-only fix that never touches their rows; verified afterwards
    (and post-run) via `information_schema.COLUMNS.EXTRA`, run aborts if
    any column still carries the flag;
  - **keys**: with AUTO_INCREMENT gone `LAST_INSERT_ID()` cannot work, so
    keys are assigned EXPLICITLY — authorid/genreid/seqid/bookid = 1..N
    in deterministic emission order, captured as `@aid_/@gid_/@sid_/
    @bid_<old>` and referenced by the join/attached-data tables exactly
    as before; the rebuild stays byte-deterministic (POP_CHUNK=
    independence, suite-verified) and every run restarts keys at 1.
  - **child tables carry their own PKs too**: the strip surfaced a
    generator gap the AUTO_INCREMENT path had hidden — the child emitters
    (mlauthor, mlgenre, mlseq, mlrating, mlcustinfo) omitted their PK
    columns (la_id/gn_id/sq_id/rt_id/ci_id), which previously came from
    the auto counter; since those columns are plain `NOT NULL` after the
    strip, the first live rebuild failed with "Field 'la_id' doesn't
    have a default value".  All five emitters now assign these PKs
    explicitly (1..N) as well.
  Mock suite grown to 33 assertions (strip ALTERs + verification query,
  explicit-key INSERTs incl. child PKs, no-LAST_INSERT_ID guarantee);
  the live `myprivatelib` DB was created fresh from the app schema
  (createtable.sql) and rebuilt + verified (0 AUTO_INCREMENT PK columns;
  contiguous keys 1..N in all nine managed tables; 0 dangling FK
  references; genre tree intact: 14 roots + 70 children; row counts
  unchanged: 2,138 books / 187 authors).

- **Schema rename project-wide: `privetelib` -> `myprivatelib`**
  (docs/`DO_IT.md`): tool names (`bin/populate_myprivatelib.sh`,
  `bin/backup_myprivatelib.sh`), configs, test suites (33-assertion
  populate, 23-assertion backup),  `POP_TARGET_DB` default, backup dir
  default, docs and the DB reference.  The live server had no
  `privetelib` at migration time (it had been dropped during earlier app
  re-testing), so `myprivatelib` was created fresh from the app's own
  DDL (BookTracker-import/sql/createtable.sql) instead of renamed;
  backup archives keep their historical filenames.

- **Docs: `docs/MultiLib_Flibusta_DB.md` rewritten (rev 2) and
  `data/sql/qry_catalog_reference.sql` added.**  The DB reference is
  re-grounded in the live schema (every figure re-verified read-only
  against the server 2026-09-04) and corrects the pre-v1.1.1 claims that
  the app re-test disproved.  New/corrected content:
  - **genre tree, verified**: `mlgenrename` = 296 rows = **24 root
    category rows** (ids 1,000,001-1,000,024, EMPTY `genrecode`, zero
    counts — e.g. «Фантастика» = 1000022) + **272 leaf genres** (real
    codes, `parentgenreid` -> a root); the tree is exactly two levels,
    books join ONLY leaves, and the join is closed (0 orphans in both
    DBs).  `myprivatelib` after the v1.1.1 rebuild: 84 = 14 roots + 70
    leaves with remapped parent ids;
  - **key strategy**: sparse catalog ids (watermarks run far past row
    counts — `mlseqname` 80,744 rows / watermark 112,843) vs
    `myprivatelib`'s contiguous fresh keys (watermark = rows + 1 on all
    nine managed tables);
  - **filename contract corrected to v1.1.1**: `mlbook.filename` = the
    CATALOG value (71% of flibusta rows are a numeric bookid fallback;
    93% numeric in the personal library), `arcname` = verbatim on-disk
    zip member / `'-'` for loose `.fb2`, `filesize` = on-disk bytes;
  - **index inventory** with the flibusta-only oddity (indexes named
    `MiddleName`/`NickName` defined on the `LastName` column, absent in
    `myprivatelib`) and the corrected `mlbook.md5` non-unique index;
  - **mlbook census**: ~200 legacy `ext` values (fb2 728,881, pdf
    58,117, ...), `deleted` 0/1 split, `md5` 100% populated;
  - full live row counts + AUTO_INCREMENT watermarks for both DBs,
    `mllbr_main` exact schema, re-verified `Flibusta_Load_mlrating.sql`
    steps, and a quick-reference SQL section — now also shipped as the
    self-contained script `data/sql/qry_catalog_reference.sql` (genre
    tree, full-book lookup, md5 lookup, table parity; queries B/C use
    `@title`/`@md5` session variables; verified to run cleanly against
    `flibusta` 2026-09-04).

- **`bin/populate_myprivatelib.sh` v1.1.0 -> v1.1.1 — genre tree restored
  + catalog `filename` (fixes two MultiLib.exe test findings).**  App
tests after the v1.1.0 rebuild surfaced two issues, both fixed:
  - **genres**: the app renders `mlgenrename` as a tree, and in the
    catalog every genre's `parentgenreid` points at a top-level
    category row (ids 1000001+, e.g. «Фантастика» = 1000022) that no
    book references directly — so the v1.1.0 subset (only the books'
    own genres) produced a FLAT table (all 70 rows `parentgenreid`
    = NULL) and the genre panel lost its hierarchy.  The tool now
    pulls each used genre's ANCESTOR CATEGORIES from
    `flibusta.mlgenrename` (iterative, bounded, dangling parents
    safely skipped via a tried-set) and remaps `parentgenreid` to the
    freshly generated parent id, parent-first — myprivatelib carries the
    same 2-level tree the app expects (e.g. «Фантастика» ->
    «Научная фантастика»).
  - **filename**: `mlbook.filename` now carries the CATALOG value
    (`flibusta.mlbook.filename`, the transliterated name the app
    displays — the on-disk path was the user's mistake, not the app's
    contract); `arcname` (on-disk zip member) and `filesize` (on-disk
    bytes) are unchanged.

  Mock suite updated to 31 assertions (still 31): ancestor-category
  fixture served only by the new ancestor fetch, dangling-parent
  fallback (NULL), catalog-filename assertions (`Title_One_FB2` & co),
  and fresh-key joins through the ancestor-pulled genre.

  **Re-rebuilt live 2026-09-04 (22:22)** against the real `Books` folder
  (2156 files -> 2148 matched, 2138 bookids; same 99.6%): `mlgenrename`
  is now **84** rows = 70 genres + **14 ancestor categories** (e.g.
  «Фантастика» -> 30 children, «Детективы и триллеры» -> 5, …), every
  `parentgenreid` remapped to a fresh parent id and `mlgenre` joins
  100% intact (0 dangling); `mlbook.filename` = catalog value verbatim
  (0 on-disk paths left; note ~71% of flibusta books carry a NUMERIC
  `filename` = their bookid — a loader fallback — which the tool now
  copies faithfully).  Pre-rebuild safety backup:
  `/mnt/c/Backup_Go7/myprivatelib-backups/myprivatelib_20260904-221300.sql.gz`
  (the v1.1.0 state).

- **New `bin/backup_myprivatelib.sh` v1.0.0 — backup / restore of the
  app-registered personal library DB (`myprivatelib`).**  myprivatelib is the
  sibling library the MultiLib desktop app created in-app (Flibusta
  plugin, empty, same 17-table ml* schema as `flibusta`, connectable from
  the app) — the target of the representation plan
  (`docs/REPRESENTATION_PLAN.md`).  This tool is the safety net that must
  exist BEFORE anything is populated into it: `backup` mysqldumps the DB
  into `BACKUP_DIR/<db>_<ts>.sql.gz` (gzip-integrity-checked, optional
  `BACKUP_KEEP` retention prune); `restore` is safe by design — it backs
  up the current state first and refuses to overwrite a non-empty library
  without `--force`; `verify` checks gzip + dump sanity; `list` shows the
  backups.  Registered in `bump-version.sh`/`test_version_sync.sh`/CI;
  mock-mysql suite `tests/test_backup_myprivatelib.sh` (23 assertions:
  argv contract incl. password-never-on-cmdline, gz artifact, retention,
  restore guards, dry-run, lifecycle mocks).

  Live round-trip verified 2026-09-04: backup -> verify -> restore (with
  the automatic pre-restore safety backup) against the real (empty)
  myprivatelib, server lifecycle managed per invocation.  Two environment
  issues surfaced and were handled:
  1. WSL2 mirrored-networking connect hangs — a `mysql` connect to
     127.0.0.1:3306 can block indefinitely instead of failing fast (the
     lifecycle lib warns about exactly this).  `mysql` calls now carry
     `--connect-timeout` (10s, `MYSQL_CONNECT_TIMEOUT`); `mysqldump`
     (which does NOT accept that flag in MariaDB 10.4) is bounded with
     `timeout` (`MYSQL_CALL_TIMEOUT`, default 90s) and its stderr is now
     shown on failure instead of swallowed.
  2. `myprivatelib.mlcustinfo.frm` was corrupt (error 1033 on LOCK TABLES)
     — a damaged table definition in the app-created library.  Repaired
     by recreating the (empty) table from the valid schema:
     `CREATE TABLE myprivatelib.mlcustinfo LIKE flibusta.mlcustinfo`.
     The post-repair backup `myprivatelib_20260904-004417.sql.gz` is the
     known-good artifact.
- **`bin/populate_myprivatelib.sh` v1.0.0 -> v1.1.0 — fresh-key, row-by-row
  rebuild of `myprivatelib` (fixes the app showing no books).**  The v1.0.0
  exact-copy approach (`INSERT … SELECT *` carrying flibusta's ids
  wholesale) was wrong: the copied foreign ids were meaningless to the
  app's own key bookkeeping, which is why MultiLib.exe showed catalog
  basics but zero books.  v1.1.0 generates EVERY key in myprivatelib's own
  `AUTO_INCREMENT` columns: one `INSERT` per row, `LAST_INSERT_ID()`
  captured into a session variable (`@bid_<old>`, `@aid_<old>`,
  `@gid_<old>`, `@sid_<old>`), and the join/attached tables
  (`mlauthor`, `mlgenre`, `mlseq`, `mlrating`, `mlcustinfo`) reference
  ONLY those captured ids — keys are used only after they come into
  existence, exactly as the dump files themselves do (ids generated via
  `AUTO_INCREMENT`, then referenced).  The whole rebuild is one SQL
  script in a single client session; `TRUNCATE` first resets the
  counters, so every run is a clean rebuild.  ONLY books present in the
  `Books` folder are represented:
  - reference tables inserted for our books only — `mlauthorname`
    (distinct authors), `mlgenrename` (distinct genres, `parentgenreid`
    remapped to the fresh parent id or `NULL` when the parent genre is
    not used, emitted parent-first), `mlseqname` (distinct series);
    no more whole-table copies (v1.0.0 had 216,491 authors / 80,744
    series);
  - `mlbook.filename`/`arcname` carry the **real on-disk relative path**
    (e.g. `А/Аб/Абби Линн/Series X/0Мироходец.zip`) and the zip member
    name (`library='myprivatelib'`, `filesize` = on-disk bytes, `ext='fb2'`,
    catalog metadata verbatim);
  - `mlrating` copied from `flibusta.mlrating` — the per-book CHAR(1)
    aggregate produced by `BookTracker-import/sql/
    Flibusta_Load_mlrating.sql` (the raw per-user `librate` source is
    dropped by the ingest cleanup, so the aggregate is authoritative);
  - column-parity mismatch on ANY managed table now ABORTS before any
    `TRUNCATE` (all-or-nothing — a partial rebuild would leave dangling
    key references).

  Mock suite `tests/test_populate_myprivatelib.sh` rewritten (31
  assertions): fresh-key captures, no raw flibusta ids in any `VALUES`,
  real filename/arcname, genre parent remap + parent-first ordering,
  mlrating only for rated books, chunked-read determinism (`POP_CHUNK`
  independent), parity abort, dry-run no-writes, lifecycle mocks.

  **Rebuilt live 2026-09-04**: dry-run and real run against the real
  `Books` folder (2156 files -> 2148 matched = 99.6%, 8 unmatched,
  2138 bookids, 0 corrupt).  Post-rebuild row counts (fresh keys,
  auto-increment verified at rowcount+1 on all 9 managed tables):
  `mlbook` 2138, `mlauthor` 2798, `mlgenre` 5468, `mlseq` 2619,
  `mlrating` 1948 (distribution 1:30 / 2:278 / 3:874 / 4:534 / 5:232),
  `mlcustinfo` 757, `mlauthorname` 187, `mlgenrename` 70,
  `mlseqname` 422 — only the entities the personal library actually
  uses, vs. 216,491 / 296 / 80,744 in the v1.0.0 exact-copy state.
  Pre-rebuild safety backups saved to
  `/mnt/c/Backup_Go7/myprivatelib-backups/` (latest:
  `myprivatelib_20260904-210914.sql.gz`, the 6 MB v1.0.0 state).
  Note: the zip member names inside the Books archives are themselves
  double-encoded (UTF-8 bytes decoded as cp866 when the zips were
  created) — `arcname` stores the member bytes verbatim so the app's
  zip reader sees exactly what is in the archive.

- **New `bin/populate_myprivatelib.sh` v1.0.0 — rebuild `myprivatelib` from
  the on-disk `Books` collection (representation plan Phase 1).**  The
  matching key is the md5 finding (see below): every book file is hashed
  (zip-wrapped FB2 by its DECOMPRESSED content via `unzip -p`/`zcat`,
  loose `*.fb2` directly) and joined against a single read-only
  `(md5, bookid)` map pulled from `flibusta.mlbook.md5` — populated for
  all 869,130 catalog rows, so no per-file queries and no fuzzy
  matching.  Duplicate md5s (catalog duplicates) resolve to the lowest
  bookid and are counted; unmatched files land in the per-run TSV report
  for the author/series/title fallback later.  Copied tables:
  per-book `mlbook`, `mlauthor`, `mlgenre`, `mlseq`, `mlrating`,
  `mlcustinfo` (chunked `IN`-lists, `POP_CHUNK`), whole reference
  `mlauthorname`, `mlgenrename`, `mlseqname`; a per-run column-parity
  check (Phase 0.1, verified identical for all 9) skips mismatched
  tables with a warning.  `flibusta` is NEVER written; app-owned
  `myprivatelib` tables (`mlactual`, `mldownloaddata`, `mlnews*`,
  `mluser*`) are never touched; `mlcoverpage`/`mldescription` stay empty
  (the loaded dump has both EMPTY — covers/descriptions require the
  separate extended-data torrents loaded first; this corrects the plan's
  "enrichment comes free" assumption).  Registered in
  `bump-version.sh`/`test_version_sync.sh`/CI; mock suite
  `tests/test_populate_myprivatelib.sh` (23 assertions: walk/hash
  incl. corrupt-zip + zcat fallback + desktop.ini skip, map contract,
  dupe resolution, chunked rebuild, parity skip, dry-run no-writes,
  report, guards, lifecycle mocks).

  **Verified live 2026-09-04**: dry-run then real rebuild against the real
  catalog and Books collection — 2156 files scanned (2145 zip + 11 loose
  fb2, 0 corrupt, 0 skipped), **2148 matched (99.6%)** via the exact md5
  tier, 8 unmatched (7 Bушков «Пиранья» volumes + 1 Bulychev
  «Девочка…» — exact-content mismatches; the fallback ladder's
  candidates), 2138 distinct bookids registered (10 files were duplicate
  copies of already-collected books), 0 catalog md5 duplicates.
  myprivatelib rows after the run: mlbook 2138, mlauthor 2798 (multi-author
  links), mlgenre 5468, mlseq 2619, mlrating 1948, mlcustinfo 757,
  mlauthorname 216491, mlgenrename 296, mlseqname 80744.  Pre-population
  empty-state backup: `myprivatelib_20260904-164703.sql.gz`.  Spot-check:
  bookid 767638 (MeXXanik «Адвокат Чехов») resolves with both authors;
  `flibusta` untouched (read-only source).
- **Catalog finding: `flibusta.mlbook.md5` is 100% populated and is the
  strongest possible match tier.**  Verified 2026-09-04 against the live
  catalog: `md5` exists on every one of the 869,130 `mlbook` rows and
  hashes the DECOMPRESSED FB2 content — `zcat file.zip | md5sum` (==
  `unzip -p`) resolves a real disk file to exactly one `bookid`, and a
  loose `.fb2` resolves directly.  This overturns the plan's earlier
  "md5 matching unavailable" note (that referred to the unloaded
  `lib.md5` dump — the catalog column itself carries the hashes) and
  replaces the dead `mlbook.filename`/`arcname` ladder tier (spike:
  `filename` holds transliterated librusec-style names, `arcname` is 0%
  populated).  Also measured: `mlcoverpage` and `mldescription` are
  EMPTY in the loaded dump, so the self-contained enrichment in
  `myprivatelib` is ratings (361,761), series, genres and `mlcustinfo`
  (163,161) — covers/descriptions only after the extended-data torrents
  are loaded.
- **`bin/bump-version.sh` 1.0.0 -> 1.0.1: fix a comment that broke shell
  syntax.**  The registry entry for the new `estimate_download_size` tool
  was pasted into the header usage block without its `#` prefix, so
  `bash -n bin/bump-version.sh` (and the CI Shell-syntax step) failed on
  the line `estimate_download_size (1.0.x)`.  The block is commented and
  aligned again; bump-version.sh is not itself version-synced (it has no
  README/RELEASE_NOTES row), so the header bump is standalone.
- **New `bin/estimate_download_size.sh` v1.0.0 — catalog download-size
  estimate for the next collecting round.**  Given a to-collect author list
  (one canonical name per line — e.g. the reconcile shopping-list export
  `reconcile_to_collect_<ts>.txt`, or the recommended-author fixture
  `data/fixtures/authors_list_from_db.txt`), it sums the REAL per-book
  sizes the catalog stores (`mlbook.filesize`) and reports two
  **distinct-book totals** — a co-authored book counts once even when
  several list authors wrote it, so the totals are the honest "how much
  will I download" figures: the **qualifying** subset (Russian books
  rated 4/5 in the `Фантастика` genre family, the list's own criteria:
  40,535 books / ~61 GB for the 5,663-author round) and the **full
  oeuvre** (all Russian books by those authors: 234,388 books / ~432 GB).
  List names are resolved to catalog authorids via an `mlauthorname` dump
  with the same trailing-whitespace normalization the exporter applies
  (5,663/5,663 matched; unmatched names are counted and reported), and
  the aggregates restrict with the resulting integer IN-list — fast, and
  no SQL-escaping of names ever happens.  Every run also writes a
  per-author breakdown TSV next to the summary
  (`estimate_download_size_<ts>.tsv`, columns
  `author|qualifying_books|qualifying_bytes|5rated_books|avg_rating|full_books|full_bytes`)
  sorted **top-rated first** (5-rated qualifying books desc, then
  qualifying count desc) with the top 10 printed in the summary
  (Шекли, Брэдбери, Саймак, Азимов, Лем...), so the round can be
  prioritized author by author; per-author rows attribute co-authored
  books to each author, so their sums exceed the distinct-book totals by
  exactly the multi-author overlap.  The MariaDB lifecycle and `MYSQL_*`
  client settings are shared via `lib/mariadb_lifecycle.sh` (auto-start
  when down, graceful stop on exit when this script started it;
  `--dry-run` never starts or stops the server and writes no breakdown
  file).  Config `config/estimate_download_size.conf` (flag > env >
  config > default); registered in the version-sync machinery and CI.
  New mock-mysql suite `tests/test_estimate_download_size.sh` (runs
  anywhere, 21/21 checks): argv/password contract, all five query shapes
  dispatched by stdin, name→authorid resolution into the IN-list,
  unmatched-author count, summary totals, top-rated-first breakdown
  content, dry-run / failure / missing-input handling, and the lifecycle
  mocks.  **Correction vs the earlier ad-hoc estimate:** the previously
  reported ~181 GB / ~562 GB figures matched no correct query — they came
  from a scratch join whose byte sums were wrong and which counted
  co-authored books once per author; the verified numbers are ~61 GB
  qualifying / ~432 GB full (distinct books).
- **`bin/reconcile_library.sh` v1.0.2 → 1.0.3 — beyond-books review export.
  In DB mode every run now also writes `reconcile_beyond_books_<ts>.tsv`
  next to the TSV report: every on-disk file attributed to a beyond-list
  author (the `orphan-known` / `orphan-unknown` rows) as
  `author<TAB>relative-path`, sorted by author then path — the per-file
  content behind the summary's `books (beyond list authors)` figure, so
  the user can review whether those 961 books should stay.  Requires DB
  mode (per-file attribution comes from the catalog name set); `--no-db`
  logs a warning, `--dry-run` logs would-write without creating the file.
  Book-less folders whose name is not on the list (structural prefix dirs
  that happen to match a catalog name, or folders left with only
  desktop.ini) are no longer counted as authors at all — in-scope empty
  folders still report as `empty` — so `authors (beyond list)` now equals
  the export's author count and always holds books (64 -> 55 on the real
  library; 961 books unchanged).  Suite grown to 23/23 checks (export
  content, collected-author exclusion, book-less folder suppression).
- **`bin/reconcile_library.sh` v1.0.1 → 1.0.2 — next-round shopping list.
  Every run now also exports the `reconcile_to_collect_<ts>.txt` artifact
  next to the TSV report: every recommended author with no books on disk
  yet — the `missing` rows plus `empty`-folder rows (`authors (remaining
  to collect)` now counts both, so an author with an empty folder is still
  to collect; identical numbers while no empty folders exist) — one
  canonical name per line in byte order, the same shape as the author-list
  fixture, ready to feed the merge pipeline for the next collecting round.
  `--dry-run` logs would-write without creating it.  Suite grown to 20/20
  checks (export content + byte order asserted).
- **`bin/reconcile_library.sh` v1.0.0 → 1.0.1 — statistics rebuilt around
  the personal-catalog model.**  The tool is a **collection-progress** report,
  not a completeness audit: the scope file is the recommended-author list
  (highly rated authors in the chosen genre, the user's shopping list) and
  the library root is where the user keeps the books collected so far.
  "Not yet collected" is therefore the normal, expected state of most of the
  list — not a defect — and on-disk content that is not on the current list
  is the user's own pick, not an orphan to flag.  The summary now reads as
  collection progress against the recommended list, in the user's own
  shape: author counts first (`authors (from list)` with its % of the
  list, `authors (beyond list)` with its % of all loaded authors, the
  `listed / unlisted author ratio` = listed share of all loaded, `authors
  (remaining to collect)`), then the books (`books on disk`;
  `books (from listed authors)` / `books (beyond list authors)` each with
  its % of books on disk; the `listed / unlisted books ratio`), and
  `empty (folder, no books)` last.  Units and percentage bases are
  explicit on every line — list coverage vs composition of the loaded set
  vs share of books on disk — so the 44 loaded list authors (holding
  1,195 books) can never be read as a book count against the 2,156 books
  on disk.  The known/unknown-to-catalog split of beyond-list authors
  stays in the per-row TSV.  `collected` counts distinct
  list authors, so a case-variant disk folder of a list author (which the
  report marks matched under both spellings) is not double-counted and the
  headline partition stays exact: collected + still-to-collect + empty ==
  scope.  The report's machine statuses
  and TSV shape are unchanged.  Also fixes the on-disk file-count readout,
  which assumed a header row the headerless report does not have and so
  silently dropped the first author's files from the total every run; the
  suite now asserts the progress summary (no-db and db variants, 18/18
  checks green).
- **New `bin/reconcile_library.sh` v1.0.0 — catalog vs library reconciliation
  report.**  Compares the on-disk book library (default
  `/mnt/c/Backup_Go7/Books`) against the catalog author scope the merge
  pipeline was built from (default
  `data/fixtures/authors_list_from_db.txt`) and classifies every author:
  `matched` (in scope + on disk), `missing` (in scope, no folder),
  `empty` (folder present, zero files), `orphan-known` / `orphan-unknown`
  (on disk but outside the scope).  The disk walk handles BOTH library
  layouts the pipeline produces — the flat `<letter>/<author>[/series]`
  and the nested skeleton `<letter>/<prefix>/.../<author>[/series]` — by
  recognizing author folders **by name** (a folder is an author folder iff
  its basename matches a known author name from scope ∪ catalog) at any
  depth, attributing every file to its nearest ancestor author folder, so
  structural prefix dirs are never mistaken for authors and authors nested
  under prefixes are found (verified against the real `Books` root:
  `А/Аб/Абр/Абра/Абрамов Александр` at depth 5).  With the catalog
  reachable (default) it pulls the `mlauthorname.FullName` snapshot so
  each row carries the catalog book count next to the on-disk file count;
  `--no-db` skips the pull and assumes the flat layout (without the name
  set a nested skeleton cannot be told from series dirs).  desktop.ini
  never counts as a book file.  Read-only against the library; output is
  a summary plus one per-run TSV report in the report dir (default
  `/mnt/c/Backup_Go7/merge-reports`).  Config `config/reconcile_library.conf`
  (flag > env > config > default); registered in the version-sync
  machinery and CI (mock-mysql suite, runs anywhere).
- **Shared `lib/mariadb_lifecycle.sh` v1.0.0.**  The MariaDB lifecycle
  (tasklist interop check, elevated PowerShell start, bounded readiness
  probe, graceful SHUTDOWN / taskkill stop, already-running servers left
  untouched) is extracted from `bin/export_authors_from_db.sh` into a
  shared library sourced by every DB tool; the exporter now sources it
  (`bin/export_authors_from_db.sh` v1.0.1 → 1.0.2, behavior unchanged).
  The shared library also owns the `MYSQL_*` client defaults (host/port/
  user/db over TCP), fixing DB-mode in the new recon tool, whose own
  defaults previously left it probing the local socket instead of the
  Windows-side server.
- **CI: bump `actions/checkout` v4 -> v5.**  GitHub is deprecating
  Node.js 20, which forced the v4 action onto Node.js 24 with an
  annotation warning; v5 runs on a supported runtime and silences it.

## [v1.2.0] - 2026-09-03

**DB-driven author-list release.**  New `bin/export_authors_from_db.sh`
regenerates the flat author fixture straight from the MariaDB catalog by
running a query file, and manages the MariaDB lifecycle itself — auto-start
when down, graceful stop on exit, already-running servers left untouched —
so no manual server handling is needed.  The working fixture is now a
genre-scoped list (5,707 Фантастика authors, 2026-09-03) and stays fully
regenerable; the previous 6,088-name snapshot traced back to a
single-genre legacy query, now annotated for provenance.  All 9 suites
(190 checks) green under WSL.

- **The author list is now DB-driven.**  New `bin/export_authors_from_db.sh`
  v1.0.0 regenerates `data/fixtures/authors_list_from_db.txt` straight from
  the MariaDB catalog by running a query file (default
  `data/sql/qry_authors_4_and_5_all.sql`, a new committed query selecting
  authors with at least one book rated 4/5 and enough books overall).
  Connection settings reuse the BookTracker-import `MYSQL_*` contract
  (defaults `mysql` / `127.0.0.1` / `3306` / `root` / empty / `flibusta`;
  password via `MYSQL_PWD` only).  The session charset is pinned with
  `SET NAMES utf8` via `--init-command`, because the server ignores the
  client handshake charset (`skip-character-set-client-handshake`) and would
  otherwise transcode results to cp1251.  Rows are normalized (BOM/CRLF,
  trailing whitespace, blank lines, literal `NULL` rows) before the atomic
  write; `--dry-run` counts without writing; `-o -` streams to stdout.
  Registered in the version-sync machinery (header = README table row =
  RELEASE_NOTES shipped line = bump-version registry).
- **Fixture refreshed from the live catalog**: 6,088 -> 13,396 authors
  (2026-09-03 query run).  The old snapshot was produced by the
  genre-restricted `data/sql/qry_authors_4_and_5_love_hard.sql` (books in
  the single `Порно` genre rated 4/5, no book-count thresholds) and an
  untrimmed CONCAT; that query is now annotated for provenance and
  superseded by `qry_authors_4_and_5_all.sql` (all genres, `TotalCount
  >= 10` / `NormalCount > 6`).  Membership diff (whitespace-trimmed):
  6,069 of the 6,089 old unique names are kept, 20 genuinely dropped,
  ~7,327 genuinely added; ~3,150 of the raw "losses" were just
  trailing-space artifacts of the old CONCAT.  All toolchain suites green
  on the new list.
- **Working fixture is now genre-scoped (5,707 authors).**  On 2026-09-03
  the fixture was re-generated from the corrected
  `data/sql/qry_Фантастика_4-and-5.sql` (authors of the Фантастика genre
  family rated 4/5, `TotalCount >= 10` / `NormalCount > 6`).  The
  originally committed query was an Access-export artifact (square-bracket
  `[Books]` syntax, tables absent from `flibusta`, book rows instead of
  author names) and is replaced by a faithful `ml*`-schema translation of
  its intent (`ParentCode = "0.17"` -> every genre whose `parentgenreid`
  is the root `Фантастика`); the Access original stays in git history.
  The list remains regenerable at any time via `bin/export_authors_from_db.sh`
  (which now auto-starts/stops MariaDB).
- **Prefix-table roots grow 24 -> 33 first characters.**  Regenerated
  from the new fixture, `bin/build_prefix_table.sh` emits 17,670 rows
  (old list: 10,151, matching the historical record) with no root present
  only in the old list.  New root classes, verified with real authors:
  digit `1` ("100 Рожева Татьяна"), Latin `H Q d e l p` ("Harvard
  Business Review (HBR)", "Qrasik", "de Budyon Michael A.",
  "estimata", "linnea", "pavel_7_8"), lowercase Cyrillic `б к ф`
  ("бен-Маймон Моше", "клевчук", "фон Беренготт Лючия"), and CJK
  `我` ("我吃西红柿 .").  Existing roots grow too (Ё 1->3, Й 5->14,
  Э 71->172); Ъ/Ы/Ь remain impossible initials (0 in both lists).
- **MariaDB lifecycle in the exporter (`bin/export_authors_from_db.sh`
  v1.0.0 → 1.0.1).**  The tool no longer requires a manually started
  server: mirroring `bin/booktracker-ingest.sh` from BookTracker-import, it
  checks `mysqld.exe` via the Windows `tasklist` interop and, when the
  server is down, starts it with an elevated PowerShell `Start-Process`,
  waits up to `MARIA_START_TIMEOUT` for it to answer, and stops it again on
  exit with a graceful `SHUTDOWN` (taskkill fallback) — but only when it
  was this script that started it; a server that was already running is
  left untouched.  `--dry-run` never starts or stops the server (it logs
  would-start / would-stop).  When the `tasklist` interop is unavailable
  (e.g. plain Linux CI) lifecycle management degrades to connect-directly.
  New env vars with BookTracker-import defaults: `MARIA_TASKLIST`,
  `MARIA_TASKKILL`, `MARIA_EXE`, `MARIA_BIN_DIR`, `MARIA_START_TIMEOUT`,
  `MARIA_READY_TIMEOUT`, `MARIA_STOP_TIMEOUT`.
- **New mock suite `tests/test_export_authors_from_db.sh` grown to 18
  checks (runs anywhere, no DB needed)**: asserts the connection argv
  (password never on the command line, `SET NAMES` init-command), row
  normalization, NULL-row drop, dry-run/stderr/stdout modes, failure
  handling, and — via a mock `tasklist` + mock `powershell.exe` — the
  MariaDB lifecycle: already-running server left untouched, full
  start → ready → graceful-stop cycle, no-tasklist management disable,
  and dry-run reporting only.  CI runs it.
- **Byte-order detector fix in two suites.**  `byte_order_violations()` used
  a bare gawk `>=`, which coerces numeric-looking prefixes ("100", "100 ")
  to numbers and both false-flagged valid tables and could mask real
  violations.  The comparisons are forced back to bytes with a `""`
  concatenation; a numeric-prefix regression check was added to the prefix
  suite's invariants.  Exposed by the refreshed list (author
  "100 Рожева Татьяна"); `LC_ALL=C sort -c` and the integrity checker both
  confirm the generator output was always correctly byte-ordered.

## [v1.1.0] - 2026-09-03

**Library-catalog refactor release.**  The merge pipeline no longer depends
on an on-disk `Empty_Skeleton` tree: `bin/merge_books_into_skeleton.sh`
builds the author-prefix hierarchy in memory and writes straight into a
timestamped, pruned `BooksInput_<ts>` staging tree, and
`bin/merge_skeleton_into_books.sh` finalizes it with rsync (destination
wins, live `pv -l` progress bar).  Also ships the GitHub Actions CI +
version-automation workflow; the merge suites now run on the Linux CI
runner.  Suites green under WSL and CI.

- **Refactor branch `refactor/update-library-catalog`: the merge pipeline no
  longer uses the `Empty_Skeleton` folder.**  `bin/build_shell_nested_authors.sh`
  remains for `mkdir -p` scripts and the SQL nested-set table, but the book
  merge builds the prefix tree **in memory** from the flat author list and
  writes straight into a timestamped, pruned staging tree
  `<output-root>/BooksInput_<timestamp>` — only directories that receive a
  copied file are created, so the prune pass is gone by construction.

- **`bin/merge_books_into_skeleton.sh` v0.1.3 → 0.2.0** (with
  `lib/merge_books_functions.sh` 0.1.3 → 0.2.0).  The on-disk skeleton scan
  (`merge_collect_skeleton_dirs`) is replaced by `merge_build_prefix_index`:
  the same `LC_ALL=C` byte-sort + contiguous-range walk as the builder
  (SQL-mode semantics — every valid prefix, not just the deepest, because
  resolution needs ancestors too), with apostrophe→caret path substitution
  matching the old emitted directories.  The clean break drops `--skeleton`
  entirely; new flags `-i/--input-file` (required), `-o/--output-root`,
  `--timestamp`, `-m/--min-authors`, `-x/--max-prefix`; config gains
  `MERGE_INPUT_FILE`, `MERGE_OUTPUT_DIR`, `MERGE_MIN_AUTHORS`,
  `MERGE_MAX_PREFIX`.  An existing staging name is not an error: it is
  treated like the old persistent skeleton (duplicate/overwrite policy
  applies), so incremental re-runs work.  Ambiguity can no longer arise from
  a hand-built skeleton (each prefix has exactly one path); the code path is
  kept defensively.  Suite rewritten for the in-memory mode: **44/44 checks**
  green under WSL.

- **`bin/merge_skeleton_into_books.sh` v0.1.3 → 0.2.0.**  The three-step
  rename → prune → copy loop is replaced by a thin, validated **rsync**
  wrapper: `rsync -a --ignore-existing --itemize-changes` onto the Books
  library (destination wins, never overwrites, resumable), with the newest
  `BooksInput_*` auto-discovered under `--output-root`, path-safety guards,
  and a per-file TSV report (`copied` / `would-copy` / `kept-existing` /
  `would-keep`).  `--from-pruned` / `--no-rename` / `--no-prune` are gone;
  the rename/prune steps no longer exist.  Requires rsync on PATH; Windows
  metadata is excluded belt-and-braces.  Suite rewritten for the wrapper:
  **19/19 checks** green under WSL (skips cleanly without rsync).

- **`bin/merge_skeleton_into_books.sh` v0.2.0 → 0.2.1.**  The finalize step
  now shows a **live progress bar** on the terminal (`rsync -av
  --info=progress2`); the per-file itemize lines are captured via rsync's
  `--log-file` instead of stdout, so the TSV report stays exact while the
  screen stays usable.  After a successful merge the library is **pruned of
  empty directories** (`find ... -depth -mindepth 1 -type d -empty -delete`)
  as a safety net for interrupted runs — `--no-prune` / `MERGE_PRUNE_EMPTY_DIRS=false`
  disables it; a dry run only reports the count.

- **`bin/merge_skeleton_into_books.sh` v0.2.1 → 0.2.2.**  The live progress
  bar now pipes rsync's itemize listing through `pv -s <total-bytes>`
  (total from `du -sb` of the staging tree) with stdout discarded; when
  `pv` is not installed the run falls back to rsync's native
  `--info=progress2`.  The `--log-file` capture is unchanged, so the TSV
  report stays exact.  CI now installs pv (and rsync) so the merge suite
  exercises the pv path on GitHub.

- **`bin/merge_skeleton_into_books.sh` v0.2.2 → 0.2.3.**  The progress bar
  switches from `pv -s <bytes>` to `pv -l -s <item-count>` for an accurate
  percentage: pv counts listing lines (one per transferred file AND one
  per transferred directory, since rsync -a lists both), so the count is
  `find ... \( -type f -o -type d \) | wc -l`; a grep filter strips
  rsync's header/blank/summary lines before pv so the bar lands at exactly
  100%.  The `--log-file` capture and the `--info=progress2` fallback are
  unchanged.

- **First real finalize run (`BooksInput_20260903-140717` → `Books_01`).**
  Ran `bin/merge_skeleton_into_books.sh --target /mnt/c/Backup_Go7/Books_01
  --report-dir /mnt/c/Backup_Go7/merge-reports` against the newest staging
  tree (157 files, ~0.09 GB).  Result: **copied 0, kept-existing 157** —
  `Books_01` already contained every staged file (it was populated at the
  same time the staging tree was created), so `--ignore-existing` skipped
  everything; 0 empty dirs pruned; staging retained; report at
  `merge-reports/merge_skeleton_into_books_20260903-151230.tsv`.

- **Docs:** `docs/BOOK_LIBRARY_MERGE_PLAN.md` rewritten for the two-step
  pipeline (in-memory merge → rsync finalize); README tool sections, testing
  table, CI blurb, and repository layout updated; RELEASE_NOTES shipped
  tools and merge-tool prose updated.  Stale `bin/merge_skeleton_into_books.sh.bak`
  and `.01.bak` files removed.

- **New development workflow: GitHub Actions CI + version automation.**
  - `.github/workflows/ci.yml` runs on every push/PR: shell syntax check
    across `bin/*.sh` and `lib/*.awk`, the new version-sync suite, all three
    merge/finalize suites, and all five UTF-8 suites (Linux bash is
    multibyte-capable, so the WSL-only constraint no longer blocks CI).  A
    broken suite is now caught on day one instead of rotting unnoticed —
    which is exactly what happened to two suites after the layout refactor.
    The runner now installs `gawk` before the syntax step, since GitHub's
    `ubuntu-latest` image ships `mawk` but not `gawk`, and the awk lint
    (`gawk --lint`) previously failed the job in seconds with
    `gawk: command not found`.
  - **Tracked `lib/utf8_prefix_generator.awk`:** the broad `*utf8*`
    gitignore rule was silently excluding the AWK prefix-generator from the
    repository, so CI checkouts had no `lib/*.awk` at all — the syntax-check
    glob collapsed to the literal `lib/*.awk` and `gawk` died with "cannot
    open source file". The tool is now negated in `.gitignore` and tracked,
    and the syntax loop skips globs that match nothing (`[[ -f ]] ||
    continue`), so a future empty directory degrades to a clean pass instead
    of a cryptic `gawk` fatal.
  - **Fixed the two remaining suites broken by the layout refactor:**
    `tests/test_build_prefix_table.sh` and
    `tests/test_prefix_tree_visualizer.sh` still resolved fixtures via
    `TESTS_DIR="$SCRIPT_DIR/tests"` (pointing at `tests/tests/`) and the
    prefix-table suite read its version header from `$SCRIPT_DIR/$s`
    (`tests/bin/…`).  Both now resolve from `tests/` + `bin/` correctly,
    making all eight suites runnable again.
  - **Test-isolation fix in `tests/test_merge_skeleton_into_books.sh`:** the
    `cli_no_args` case ran the script with no flags, letting it inherit the
    real machine's config defaults — a stray `Empty_Skeleton` under
    `/mnt/c/Backup_Go7` once made it exit 0 and run a real finalize.  The
    case now injects guaranteed-missing `MERGE_SOURCE_DIR`/`MERGE_TARGET_DIR`/
    `MERGE_REPORT_DIR` so it must fail validation regardless of machine state.

- **New `bin/bump-version.sh` (v1.0.0).**  Bump one tool in a single command:
  header comment, lib twin (merge_books_into_skeleton), README release-table
  row (version + tag), and RELEASE_NOTES shipped-tools line — with shape
  validation and refusal of non-increases.  Historical mentions in the docs
  are left untouched; the new `tests/test_version_sync.sh` (7/7 green)
  verifies all tracked locations agree, so version drift becomes a test
  failure instead of a silent doc bug.

## [v1.0.0] - 2026-09-01

**First production release** of the author toolchain.  This tag marks the
whole repository as production-ready: the prefix-table generator, validator,
renderer, the nested directory-tree builder, and the book-library merge +
finalize tools, with their suites green under WSL.

- **`bin/build_shell_nested_authors.sh` v6.6.10 — apostrophes in directory
  names.**  Author names may contain an apostrophe (e.g. `О'Брайен`), which
  the prefix walker turned into a directory component ending in a quote
  (`mkdir -p О/О'`).  The SHELL output now substitutes a caret for every
  apostrophe (`mkdir -p О/О^`), keeping emitted paths clean and safe to
  copy-paste.  The SQL output is unchanged: it keeps the raw prefix and
  escapes single quotes for the SQL literal.  Both `mkdir` emission sites
  (max-depth and leaf) are covered; the substitution is a pure parameter
  expansion, so no subprocess is forked per row.
  - New fixture `tests/case_apostrophe.txt` plus SHELL and SQL goldens
    (`apostrophe_m6_x5.txt`, `apostrophe_m6_x5_sql.txt`) lock the behavior
    in; the SHELL golden asserts `mkdir -p О/О^`, the SQL golden keeps
    `('О/О''', …)`.
  - **Latent test-suite fixes from the layout refactor.**  The suite had
    been unrunnable since `1e75fbe` moved it into `tests/` and the tools
    into `bin/`: its `SCRIPT_DIR` path logic still assumed it lived at the
    repository root, and the sandbox/copy scratch names kept the `bin/`
    prefix (`copy_bin/…` instead of `copy_build_shell_nested_authors.sh`).
    Both are fixed (paths now resolve one level up via `../`, scratch
    names are basenames), the stray `tests/tests/` directory is removed,
    and the suite is green again under WSL: **30/30 checks** (was 28/28
    pre-refactor + 2 new apostrophe cases).

## [Unreleased] - 2026-08-31

- **Rename the backup root from `Backup_Nova3` to `Backup_Go7`** across the
  whole project: default directories, config files, usage examples,
  documentation (`README.md`, `RELEASE_NOTES.md`, `docs/BOOK_LIBRARY_MERGE_PLAN.md`),
  and the nested-authors suite's root-dir substitution.  The old name no
  longer appears in any tracked file.  Version bumps per the 0.0.1 rule:
  `bin/build_shell_nested_authors.sh` 6.6.8 → **6.6.9**,
  `bin/merge_books_into_skeleton.sh` 0.1.2 → **0.1.3**, and
  `bin/merge_skeleton_into_books.sh` 0.1.2 → **0.1.3**.

- **`bin/merge_skeleton_into_books.sh` v0.1.2.**  Finalize tool hardening and
  cleanup:
  - `set -euo pipefail` restored (it was disabled during debugging) so a failed
    `mv`, `cp`, or `find` aborts the run instead of silently continuing a
    half-finished merge.
  - The trailing report line is now an explicit `if` — a missing report can no
    longer flip the script's exit code.
  - `parse_arguments` simplified: uniform `--flag VALUE` and `--flag=VALUE`
    forms; the fragile `-s = DIR` and positional-argument forms are dropped
    (positional arguments now fail with a clear error).
  - Config and README examples aligned on `TARGET_DIR=/mnt/c/Backup_Go7/Books`
    (the docs previously showed a stray `/mnt/o/Books`).
  - Docs: version references bumped to 0.1.2, stray code fences removed from
    README and RELEASE_NOTES, the finalize config file listed in the repo
    layout, and `HH:MM` restored to the header timestamp.
  - Suite: 27/27 checks green.

- **`bin/merge_skeleton_into_books.sh` v0.1.1.**  Finalize tool improvements:
  - New flag `--from-pruned`: skip rename + prune when the source is already a
    cleared `BooksInput_<timestamp>` folder.
  - Auto-detection: if the source directory name starts with `BooksInput_`,
    rename and prune are skipped automatically (same effect as `--from-pruned`).
  - Default report directory changed to the fixed path
    `/mnt/c/Backup_Go7/merge-reports` so all reports are collected in one place.
  - Clear mode messages (`mode: from-pruned …` / `mode: auto-detected …`).
  - `RENAME` default now declared with the other configuration variables
    (avoids unbound-variable issues under `set -u`).
  - Suite `tests/test_merge_skeleton_into_books.sh` expanded and adjusted:
    dry-run, full run, `--no-rename`, `--from-pruned`, auto-detection,
    CLI, and version header.

## [Unreleased] - 2026-08-30

- **New finalize tool `bin/merge_skeleton_into_books.sh` (v0.1.0).**  Turns a
  populated author-prefix skeleton into the Books library in three safe steps:
  rename the skeleton to a timestamped staging folder `BooksInput_<ts>`,
  remove every empty directory inside it, then copy the remaining content into
  `Books` without ever overwriting an existing folder or file (the
  destination wins).  The staging folder is retained intact; only empty
  subdirectories are pruned.  `--dry-run` reports the three steps without
  changing anything.  Suite `tests/test_merge_skeleton_into_books.sh`:
  21/21 checks green (dry run, full run, no-rename, CLI, version).

- **Merge tool v0.1.2.**  Destination layout fixed to give each author its
  own folder under the deepest matching prefix, and Windows metadata is
  never copied:
  - **Author folder under the prefix.**  `Абби Линн/Magic The Gathering/…`
    now lands at `А/Аб/Абби Линн/…` instead of directly under `А/Аб/…`,
    so authors that share a prefix never mix their books.  When the matched
    skeleton path already is the author's own folder (from a prior run) the
    author is not appended twice.
  - **Skip list.**  `desktop.ini` and `Thumbs.db` (case-insensitive, any
    depth) are never copied and are reported as `skipped` with reason
    `Windows metadata file (skip list)`.  The list is configurable via
    `MERGE_SKIP_NAMES` (config or environment).
  - Config file documents the new key; suite grown to 45/45 checks.

- **Merge tool v0.1.1.**  `bin/merge_books_into_skeleton.sh` plus
  `lib/merge_books_functions.sh` copy every top-level author folder of a
  legacy archive into the deepest matching prefix directory of a pre-built
  skeleton, per `docs/BOOK_LIBRARY_MERGE_PLAN.md`:
  - The skeleton is the source of truth: prefixes are matched byte-wise against
    the author name (exact for UTF-8 in Cygwin and WSL bash), the longest
    match wins, and distinct paths sharing it are reported as ambiguous.
  - **Recursive series copy (default).**  Subfolders under an author are book
    series and are copied with their relative layout preserved
    (`Серия/том1.fb2` lands inside the author's prefix directory); empty
    subfolders are never created.  `--no-recursive` restores the direct-files-
    only behavior and records subfolders as skipped.
  - **Overwrite policy.**  Existing destination files are handled per
    `--overwrite never|ask|force` (default `never`): `force` replaces and
    records status `overwritten`, `ask` prompts per file (non-interactive
    runs behave like `never`).  A file copied twice from the same source is
    always skipped as a duplicate.
  - **Config file.**  `config/merge_books.conf` supplies defaults for the
    source, skeleton, report directory, recursion, and overwrite policy;
    every setting resolves flag > environment variable > config file > built-
    in default.  `--dry-run` is intentionally not configurable.
  - Copy-only: the source archive is never modified, and re-runs are
    idempotent (duplicate-name).  Mixed formats (`.fb2`, `.epub`, `.zip`,
    `.txt`, ...) are copied as-is.
  - Six TSV reports are written to `--report-dir`: `merge-manifest.tsv`,
    `unmatched-authors.tsv`, `ambiguous-authors.tsv`, `collisions.tsv`,
    `duplicates.tsv`, and `skipped-files.tsv`.
  - `--dry-run` resolves every author and writes the reports without touching
    the skeleton; run it first and review before a real copy.
  - New suite `tests/test_merge_books_into_skeleton.sh`: 42/42 checks green
    (dry run, full run, duplicate-name, collision, re-run idempotency,
    no-recursive, overwrite force/ask, config/env/flags precedence, ambiguous,
    CLI, version headers).  Unlike the UTF-8-slicing suites, it runs under
    both Cygwin/MSYS bash and WSL.

- Added `docs/BOOK_LIBRARY_MERGE_PLAN.md`, documenting the approved next
  phase: build the author-prefix skeleton, resolve archive authors to the
  deepest valid prefix directory, and safely copy mixed-format books from
  `C:\\Backup_Go7\\ToLoad` without overwriting existing filenames. The first
  implementation will use dry-run reports and will leave multi-author expansion
  out of scope.

- Reorganized the repository into a conventional Bash project layout:
  executable tools under `bin/`, reusable AWK code under `lib/`, regression
  suites under `tests/`, source data and SQL under `data/`, and documentation
  at the repository root.
- Updated script, test, and documentation references for the new paths.
- Kept archived/scratch directories and the pre-existing local cleanup changes
  separate from the active toolchain.

## [release] - 2026-08-13

- **Root-only layout finalized.**  The `release/` snapshot directory was moved
  to the repository root earlier, but the changelog's release workflow and the
  three shell suites still assumed the old snapshot model.  The workflow
  section now documents the root-only layout, and each suite's
  `release_snapshot_matches_working` diff (which compared the script against a
  `release/` copy one level up and would now fail) is replaced by the
  version-header check.
- **Integration path fix.**  `tests/test_build_prefix_table.sh`'s real-data
  integration group pointed `data/fixtures/authors_list_from_db.txt` and
  `bin/prefix_table_integrity.sh` at `$SCRIPT_DIR/../…`; it now points at the
  repository root and runs instead of skipping.
- **Removed a stray empty `1` file** from the repository root.
- **Tagged the release.**  Tool-prefixed tags `build_prefix_table-1.0.4`,
  `prefix_table_integrity-1.2.1`, and `utf8_prefix_generator-1.1` now name each
  tool's released version.
- **Suites green under WSL (96/96 checks):** prefix table 34/34, nested-authors
  28/28, visualizer 12/12, AWK generator 11/11, e2e pipeline 11/11.  (The three
  shell suites each report one fewer check than the historical 35/29/13
  figures — the obsolete release-snapshot diff was removed.)

## [lib/utf8_prefix_generator.awk 1.1] - 2026-08-13

- **`utf8_prefix` off-by-one fix.**  The prefix slicer broke at a character's
  lead byte instead of past its continuation bytes, so under a byte locale
  (`LC_ALL=C`) every prefix ending in a multi-byte character was sliced in
  half (e.g. `аб` became `а` plus a stray lead byte).  It now ends on a
  character boundary in both gawk string modes; UTF-8-locale output is
  unchanged (the AWK-parity group is still green).
- **New direct regression suite (`tests/test_utf8_prefix_generator.sh`).**  Unlike
  the parity group — which only compares this script against the newer
  generator, so a bug they share could still pass — this asserts the AWK
  script's own rows: multi-byte / 3-byte / 4-byte prefix slicing, `maxlen`
  capping, space-preserving multi-word authors, `count`/`start`/`end` ranges,
  and byte-locale correctness.
- Suite: **11/11 checks** green under WSL.

## [toolchain] - 2026-08-13

- **Restored `bin/prefix_table_integrity.sh` to the repository root.**  The
  validator (v1.2.1) had been parked in `_Save_Stuff/` and was absent from the
  active tree, so the generator suite's real-data integrity cross-check
  silently skipped.  It is once again a first-class toolchain component, living
  next to the generator whose output it validates.
- **New end-to-end pipeline suite (`tests/test_e2e_pipeline.sh`).**  Chains the three
  stages — `bin/build_prefix_table.sh` → `bin/prefix_table_integrity.sh` →
  `bin/prefix_tree_visualizer.sh` — on the real 6,088-author list.  Asserts the
  generated table is non-empty and in strict byte order, that the validator
  reports 0 criticals and checks exactly the emitted row count, that the
  renderer draws a multi-level tree (the utf8_chop fix), and that a concrete
  prefix's count survives generator → renderer intact.  This locks out the
  cross-tool format drift no single per-tool suite can see.
- Suite: **11/11 checks** green under WSL on the real author list.

## [bin/prefix_tree_visualizer.sh 2.8.1] - 2026-08-11

First release of the tree renderer, integrated into the toolchain.

- Moves into the release package: `release/bin/prefix_tree_visualizer.sh` (version
  kept in the header comment), the regression suite
  (`release/tests/test_prefix_tree_visualizer.sh`), and its fixtures/goldens under
  `release/tests/` (`viz_mini.txt`, `viz_spaces.txt`).  The working script
  stays at the repository root.
- **utf8_chop fix (2.8)**: the parent-prefix helper returned the reversed tail
  instead of everything except the last character, so every child was attached
  to a nonexistent parent and the tree never descended below the roots (e.g.
  `"Журн` hung under nothing, `WA` wrongly under `A`).  Fixed to iterate the
  characters in order.
- Version scheme converted to the shared 0.0.1 ladder: header carries
  `Version:` + `Last updated:`, usage prints `v2.8.1`, and the suite asserts
  the `2.8.x` pattern.
- Suite: **13/13 checks** — golden renders (full, Cyrillic filter, depth 2),
  descent regression for the utf8_chop fix (punctuation and Cyrillic branches
  reach their leaves), filter isolation, depth truncation, CLI usage errors,
  plus a release-integrity check that the snapshot is byte-identical to the
  working script.

## [bin/build_prefix_table.sh 1.0.4] - 2026-08-11

- **Startup banner**: every successful run prints
  `bin/build_prefix_table.sh v<version> (pre-order trie walker)` to **stderr**
  only — stdout stays byte-identical (it carries the table, often redirected
  straight into `tmp_SORTED_AUTHORS`).  A stale copy is instantly
  recognizable: it prints an older version or no banner at all.
- The regression suite now asserts the banner (version + walker variant) on
  stderr and that it never leaks into stdout.

## [bin/build_prefix_table.sh 1.0.3] - 2026-08-11

- New fixture `case_quotes.txt` + golden `quotes_x5.txt`: punctuation-leading
  names (`"Журнал …"`, `(Максимов)`) sort before all Cyrillic in byte order
  — the exact boundary the historical level-major walker violated (the
  4 byte-order warnings seen on real data).  Regression-locked.

## [bin/build_prefix_table.sh 1.0.2] - 2026-08-11

First release of the prefix-table generator, integrated into the toolchain.

- Moves into the release package: `release/bin/build_prefix_table.sh` (version kept
  in the header comment), the regression suite
  (`release/tests/test_build_prefix_table.sh`), and its fixtures/goldens under
  `release/tests/`.  The working script stays at the repository root.
- Generates the toolchain's prefix table (`tmp_SORTED_AUTHORS` format
  `prefix<TAB>count<TAB>start<TAB>end`) with the same core logic as the tree
  builder: normalize → `LC_ALL=C` byte sort → sorted-range prefix-tree walk.
- **Byte-ordered by construction**: the walk emits rows in pre-order of the
  prefix trie, which *is* lexicographic byte order.  The historical table
  (AWK hash-order dump from a locale-sorted list) carried 6,483 byte-order
  warnings in the integrity checker; the generator's output has zero.  Verified
  on the real 6,088-author list: 0 critical, 0 byte-order violations.
- **AWK parity**: emits identical rows to the original
  `lib/utf8_prefix_generator.awk` on the same byte-sorted input (checked in the
  suite).
- **Normalization**: CRLF endings, blank lines, and a leading UTF-8 BOM are
  stripped before sorting; all three yield byte-identical output.
- Per-prefix counts verified against the historical table: 10,151 rows, 10,151
  shared prefixes, zero count mismatches.
- Suite: **32/32 checks** — golden files, structural invariants (byte order,
  `count == end - start + 1`, unique prefixes, valid ranges), AWK parity,
  CRLF/BOM handling, CLI forms and error paths, real-data integration, plus a
  release-integrity check that the snapshot is byte-identical to the working
  script.

## [6.6.8] - 2026-08-11

Release of the final, tested state of `bin/build_shell_nested_authors.sh`.  No
functional changes since 6.6.7; the version increment marks the script as
complete and release-ready.

- The `V06` variant is retired; the canonical script is `bin/build_shell_nested_authors.sh`.
- Release package lives in `release/`: the snapshot `bin/build_shell_nested_authors.sh`
  (version kept in the header comment, not the file name), this changelog, and a
  self-contained regression suite (`release/tests/test_build_shell_nested_authors.sh`).
- Full regression suite green: **29/29 checks** against the release snapshot
  (`wsl.exe bash release/tests/test_build_shell_nested_authors.sh`), including a
  release-integrity check that the snapshot is byte-identical to the working script.
- Tagged `v6.6.8`.

## Development & release workflow

The design supports ongoing work on more tools in this repository.  Every
released tool follows the same pattern:

1. **Develop** against the working script at the repository root (e.g.
   `bin/build_prefix_table.sh`); it is both the source of truth and the released
   artifact — there is no separate `release/` snapshot.
2. **Bump the version** in the header comment by `0.0.1` per iteration (e.g.
   `6.6.8` → `6.6.9` for the tree builder, `1.0.3` → `1.0.4` for the prefix
   table, `2.8.1` → `2.8.2` for the visualizer) and update the `Last updated`
   timestamp.
3. **Run the relevant test suite(s)** under WSL.
4. **Commit** with a clear message and **tag** with the tool-prefixed name.
