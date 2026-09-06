# NEXT — where to resume

> Updated: 2026-09-06 — populate tool bumped to v1.3.0 (key strategy
> reversed: flibusta source keys copied verbatim, NO synthetic keys, per
> `docs/DO_IT_20260906_141511.md`; the v1.2.0 AUTO_INCREMENT strip
> stays).  Live DB purged and re-populated; see the v1.3.0 section below.

## Resume checklist

```bash
cd /home/mike/GIT_ROOT/MultiLib_Utilities
git status             # expect: clean tree, on main, up to date with origin/main
git log --oneline -3   # expect: the v1.2.0 rename/strip commit at the top
git pull               # no-op if nothing else changed upstream
bash tests/test_version_sync.sh          # 12/12 (fast, mock-only)
bash tests/test_populate_myprivatelib.sh   # 33/33 (mock mysql, runs anywhere)
```

Everything is pushed: `21a60a4` (docs) -> `e2628bc` (populate v1.1.1) ->
`cb6a934` (populate v1.1.0) on `origin/main`, each with a green CI run.
Nothing local is ahead of the remote.

## Current state

The **representation layer** for the personal library is designed, its
safety net is shipped, and the population tool is **live and verified**.
The end-user app (`MultiLib.exe`, `C:\MultiLib\`) models **a library = a
MySQL DB with the 17-table ml\* schema** and switches between them
(`CurrentLibName` in `MultiLib.ini`, `[MySQL] root@localhost:3306`, no
password). The user created **`myprivatelib`** in-app via the Flibusta
plugin: an empty sibling library, same schema as `flibusta`, connectable
from the app. Everything downstream is about populating `myprivatelib`
with the personal collection (the `Books` folder) and never touching
`flibusta` / `mllbr_main`. Full design: `docs/REPRESENTATION_PLAN.md`
(rev 6); full database reference: `docs/MultiLib_Flibusta_DB.md` (rev 2).

**Open re-test thread:** the user re-tested MultiLib.exe against the
v1.1.1 rebuild — the genre tree and filename fixes landed ("things are
getting better") but **some app-side problems remain, to be resolved
later**. See `docs/MultiLib_Flibusta_DB.md` §7.9 for the known-at-this-
writing observations (numeric `filename` = bare bookid for ~93% of the
personal library; verbatim double-encoded `arcname`; all app-owned
tables still empty in `myprivatelib`).

### Shipped: the safety net (`bin/backup_myprivatelib.sh` v1.0.0, commit `6dd7342`)

Backup / restore / verify / list of `myprivatelib` via mysqldump — the
mandatory prerequisite before Phase 1 populates anything:

```bash
./bin/backup_myprivatelib.sh                        # backup -> BACKUP_DIR/myprivatelib_<ts>.sql.gz
./bin/backup_myprivatelib.sh list
./bin/backup_myprivatelib.sh verify <file>.sql.gz
./bin/backup_myprivatelib.sh restore <file>.sql.gz  # safe: backs up current state first;
                                                  # refuses non-empty overwrite without --force
```

- Backups live in `/mnt/c/Backup_Go7/myprivatelib-backups/`.
- Registered in `bump-version.sh` / `tests/test_version_sync.sh` / CI;
  mock-mysql suite `tests/test_backup_myprivatelib.sh` (23 assertions).
- Verified live 2026-09-04: backup -> verify -> restore round-trip green.

### Shipped: the population tool (`bin/populate_myprivatelib.sh` v1.3.0)

**v1.3.0 (2026-09-06, `docs/DO_IT_20260906_141511.md`):** the key
strategy is reversed — keys are the **flibusta source keys, copied
verbatim**; the tool generates NO synthetic keys.  The v1.2.0
tool-assigned 1..N counters and `@<var>_<old>` session-variable remaps
are gone.  Matching is unchanged (md5-exact), and the AUTO_INCREMENT
strip from `docs/DO_IT.md` stays (a verbatim source key is a plain PK
value, not a server-generated one).  A post-reload **FK integrity gate**
verifies 9 reference paths — with verbatim keys a wrong reference can no
longer be hidden by a remap.  Mock suite grown to **35 assertions**
(source-key INSERTs, no-`SET @var` guarantee, FK gate incl. the
abort-on-orphans path).

**v1.2.0 (2026-09-06, `docs/DO_IT.md`):** MultiLib.exe treats
server-generated (AUTO_INCREMENT) PK columns differently from the
original schema's plain PK columns — the root cause the v1.1.x fixes
could not reach.  The strip (below) was introduced here and is retained
by v1.3.0; its tool-assigned-keys half is superseded.

1. **Strip** — before any data lands, schema-driven
   `ALTER TABLE ... MODIFY COLUMN` statements re-declare each PK column
   verbatim from `SHOW CREATE TABLE` minus the `AUTO_INCREMENT` keyword
   (idempotent; verified via `information_schema.COLUMNS.EXTRA` before
   and after the rebuild).
2. ~~Explicit keys~~ — superseded in v1.3.0 by source keys verbatim
   (the strip's `la_id/gn_id/sq_id/rt_id/ci_id` finding is what makes
   the verbatim child PKs work: they are plain NOT NULL columns now).

The rename (`privetelib` -> `myprivatelib`) is project-wide: tools,
configs, suites, docs.  At migration time the live server had no
`privetelib` (dropped during earlier app re-testing), so
`myprivatelib` was created fresh from the app's own DDL
(createtable.sql) and populated from scratch.

Rebuilds `myprivatelib` from the `Books` collection: hash each file (zip by
decompressed content, loose fb2 directly) -> join the one-shot `(md5, bookid)`
map -> rebuild the 9 managed tables **row-by-row with SOURCE keys
verbatim** (since v1.3.0): the tool strips `AUTO_INCREMENT` from all 16
PK columns of the target schema first, then inserts every row with the
flibusta key values unchanged — the md5-resolved `bookid`, the source
`authorid`/`genreid`/`seqid`, and the child PKs (`la_id`/`gn_id`/
`sq_id`/`rt_id`/`ci_id`) straight from the source rows.  No synthetic
keys anywhere: no 1..N counters, no session-variable remaps, no
`LAST_INSERT_ID()` — and a post-reload FK integrity gate (9 reference
paths) proves every reference resolves.  The purge-and-reload runs in a
single client session (`TRUNCATE` first). Reference entities are
inserted for OUR books only (distinct authors/genres/series of the
resolved bookids); **v1.1.1 fixes the
two app-test findings** (both retained): `mlgenrename` pulls each used
genre's ancestor categories (the catalog's 1000001+ tree rows) so the
genre tree renders instead of a flat list — `parentgenreid` is the
source value verbatim, the tree is self-consistent — and
`mlbook.filename` carries the CATALOG value (the transliterated name the
app displays — the on-disk path was the user's mistake, not the app's
contract) — `arcname` keeps the on-disk zip member name, `filesize` the
on-disk bytes. `mlrating` copies the per-book aggregate
from `flibusta.mlrating` (the `Flibusta_Load_mlrating.sql` output). Parity
is checked for ALL 9 tables BEFORE any TRUNCATE — a mismatch aborts, never a
partial rebuild. `flibusta` read-only; app-owned tables never touched.
Report TSV per run
(`/mnt/c/Backup_Go7/merge-reports/populate_myprivatelib_<ts>.tsv`).

```bash
./bin/backup_myprivatelib.sh                # FIRST: safety backup of current myprivatelib
./bin/populate_myprivatelib.sh --dry-run   # walk + resolve + summarize, write nothing
./bin/populate_myprivatelib.sh             # rebuild (AUTO_INCREMENT strip + source-key-verbatim INSERTs)
```

- **v1.3.0 rebuilt live 2026-09-06 (14:56, verbatim keys)**: same match
  numbers (2156 files -> 2148 matched, 8 unmatched, 2138 bookids). All 9
  managed tables reloaded with the **flibusta source keys verbatim**:
  mlbook bookid 9461..882939 (sparse, NOT 1..N), every one of the 2138
  bookids present in flibusta, 0 md5 collisions (a target row's md5 never
  maps to a different source bookid), 0 AUTO_INCREMENT columns, FK gate
  9 paths / 0 orphans, genre tree 14 roots + 70 children / 0 dangling.
  Payload matches the source row-for-row except `ext='fb2'` (forced, as
  designed — 35 rows carry legacy pdf/doc catalog values). Safety backup
  before the purge: `myprivatelib_20260906-145121.sql.gz`.
- **v1.1.1 re-rebuilt live 2026-09-04 (22:22)**: 2156 files -> 2148 matched
  (99.6%), 8 unmatched, 2138 bookids. myprivatelib rows: mlbook **2138**,
  mlauthor 2798, mlgenre 5468, mlseq 2619, mlrating 1948 (distribution
  1:30, 2:278, 3:874, 4:534, 5:232), mlcustinfo 757, mlauthorname **187**,
  mlgenrename **84** (70 genres + 14 ancestor categories — «Фантастика»
  -> 30 children), mlseqname **422**; AUTO_INCREMENT watermarks verified at
  rowcount+1 (contiguous fresh keys). `mlbook.filename` = catalog value
  verbatim (2138/2138 non-empty, 0 on-disk paths); `arcname` 2127 member
  names + 11 `'-'` (loose `.fb2`).
- Suite `tests/test_populate_myprivatelib.sh` **31/31**; registered in
  bump-version.sh / test_version_sync.sh / CI. Pre-rebuild safety backups:
  `/mnt/c/Backup_Go7/myprivatelib-backups/myprivatelib_20260904-221300.sql.gz`
  (the v1.1.0 state) and the earlier v1.0.0 snapshot
  (`...-210914.sql.gz`, the 6 MB exact-copy state).
- **The 8 unmatched** are 7 Bушков «Пиранья» volumes + 1 Bulychev
  «Девочка…» — exact-content mismatches (catalog has a different edition/
  normalization of the same book). These are the fallback-tier candidates
  (author/series/title ladder).
- **arcname finding (verified 2026-09-04)**: the zip member names inside the
  Books archives are themselves double-encoded mojibake (`01-╨Я╨╡╤А╨▓╨╛╨╡`
  — UTF-8 decoded as cp866 by whatever tool created the zips). The tool
  stores the member bytes VERBATIM, so the app's zip reader sees exactly the
  name physically in the archive — do NOT "fix" arcname to clean UTF-8 or
  member lookup inside the zip would break. `flibusta.mlbook.arcname` is
  empty, so the source catalog is no help here either.

### Shipped: the DB reference (`docs/MultiLib_Flibusta_DB.md` rev 2 + `data/sql/qry_catalog_reference.sql`)

The comprehensive database reference was rewritten and re-grounded in the
live schema (every figure re-verified read-only 2026-09-04), correcting
the pre-v1.1.1 claims the app re-test disproved — most importantly the
**genre tree** (`mlgenrename` = 24 root category rows id 1000001+ with
EMPTY `genrecode` + 272 leaf genres; books join ONLY leaves; exactly two
levels) and the **filename contract** (`mlbook.filename` = catalog value;
71% of flibusta rows are a numeric bookid fallback — 93% numeric in the
personal library; `arcname` verbatim on-disk member, `'-'` for loose
`.fb2`). Also documents the sparse-vs-fresh key strategy with live
AUTO_INCREMENT watermarks, the full index inventory (incl. the flibusta
`MiddleName`/`NickName`-on-`LastName` oddity absent in myprivatelib), and
the mlbook value census. The quick-reference queries are shipped as the
self-contained, runnable `data/sql/qry_catalog_reference.sql` (genre
tree / full-book / md5 / table-parity; `@title`/`@md5`/`@tbl` session
variables; verified against `flibusta` 2026-09-04).

## Environment quirks (learned 2026-09-04 — remember these)

1. **WSL2 mirrored-networking connect hangs**: a `mysql` connect to
   `127.0.0.1:3306` can block indefinitely instead of failing fast.
   Always use `--connect-timeout` (the tools do; ad-hoc commands should
   too). `mysqldump` in MariaDB 10.4 does **not** accept that flag —
   bound with `timeout` (`MYSQL_CALL_TIMEOUT`, default 90s) in the tool.
2. **Wedged server after operations**: after several start/stop cycles the
   `--console` mysqld instance can keep running but stop answering
   (handshake stalls; `SELECT 1` hangs). This is the user's known
   "minimized window, still working" quirk. Fix: `taskkill /F /IM mysqld.exe`,
   then start fresh. After a force-kill, first boot may need
   `MARIA_START_TIMEOUT` well above the 30s default (recovery of the big
   MyISAM catalog) — pass `MARIA_START_TIMEOUT=120` until it's stable.
3. **`myprivatelib.mlcustinfo.frm` was corrupt** (error 1033 on LOCK TABLES) —
   repaired by `CREATE TABLE myprivatelib.mlcustinfo LIKE flibusta.mlcustinfo`.
   If the app misbehaves on `myprivatelib`, this is a candidate cause; the
   backup now makes such repairs safe.
4. Server lifecycle on this box requires WSL2 **elevated** (no UAC prompt).
5. `mysql_upgrade` (ingest `--upgrade`) fixed the portable datadir's
   version skew (`mysql.proc` expected 21/found 20 — datadir predated the
   10.4 server). WSL2 ships mysql **client 8.0.46** against the 10.4.7
   server — fine for plain SQL; watch out in tooling that reads server
   internals.

## Next steps (priority order)

1. **Resolve the remaining app re-test problems** (see
   `docs/MultiLib_Flibusta_DB.md` §7.9): switch MultiLib.exe to
   `myprivatelib`, confirm the book list renders and a book opens (e.g.
   myprivatelib bookid 1 — MeXXanik «Адвокат Чехов»); investigate whatever
   the user still sees. Candidates already known: numeric `filename`
   display (93% of rows), verbatim mojibake `arcname` rendering, empty
   app-owned tables (`mlactual`, `mldownloaddata`, `mlnews*`, `mluser*`).
2. **Behavior probe (post-population)**: user downloads/opens one book in
   `myprivatelib` in-app; diff datadir before/after to learn the exact rows
   the app writes (`mlbook` shape, `mldownloaddata`) and where files land.
3. **Unmatched fallback (ladder b)**: author/series/title matching for the
   8 unmatched files (and any future misses) — extend the tool's resolve
   step or add a small companion.
4. **Covers/descriptions (future)**: load the extended-data torrents
   (covers/descriptions) into `flibusta`, re-run the ingest + populate tool
   — `mlcoverpage`/`mldescription` are in the managed set once populated.
5. **Phase 2 — collection-status query bank**: more `qry_*` files in
   `data/sql/` (the reference lookups are already at
   `data/sql/qry_catalog_reference.sql`) — coverage per author/genre,
   series gaps, next-to-collect priorities, reconcile summary rendered
   from the ledger.
6. **Phase 3** — read/search polish; optional `mldownload` mirror for the
   app's Downloads grid.

## Open notes carried forward

- `mlbook.filename`/`arcname` are NOT the flibusta archive names — do not
  plan matching around them. The monthly-archive filenames on disk
  (`01-Первое дело.zip`, `0Мироходец.zip`) are series-number + title;
  normalize by stripping `^[0-9]+[ -]*` before comparing to `mlbook.title`.
- The raw dump sources (`lib*.sql.gz`, the 12 tables) are kept on disk at
  `data/archives/flibusta_gz/` (git-ignored, ~130 MB) for reference /
  re-loads; they are already ingested into `flibusta` by the
  BookTracker-import pipeline.
- Full database reference: `docs/MultiLib_Flibusta_DB.md` (rev 2) — keep it
  in sync with the tools and the live schema; its §9.6 quick-reference SQL
  doubles as the shipped `data/sql/qry_catalog_reference.sql`.
- `docs/` is markdown-only; keep the plan and this file in sync after each
  phase. MariaDB is currently STOPPED (shut down gracefully) — start it
  elevated when resuming DB work.
