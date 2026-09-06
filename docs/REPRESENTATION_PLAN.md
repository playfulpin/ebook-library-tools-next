# Personal library representation plan

**Status:** Design approved; safety net + Phase 1 tool implemented (v1.1.0)
**Updated:** 2026-09-04 (rev 6 — fresh-key population rewrite)

> **Safety net (implemented):** `bin/backup_myprivatelib.sh` v1.0.0 — backup /
> restore / verify / list of `myprivatelib` via mysqldump.  `restore` is safe
> by design (backs up the current state first; refuses to overwrite a
> non-empty library without `--force`).
>
> **Population tool (implemented):** `bin/populate_myprivatelib.sh` v1.2.0 —
> rebuilds `myprivatelib` from the on-disk `Books` collection by md5-matching
> every book file against `flibusta.mlbook.md5` and inserting ONLY the
> resolved books with FRESH keys (row-by-row, `LAST_INSERT_ID()` captured
> into session variables child rows reference), genre ancestor categories
> pulled in so the genre tree renders, catalog `filename` (not the on-disk
> path), and reference tables populated for the personal library's books
> only.  The md5 finding below made the match exact and unambiguous; the
> v1.1.0 key strategy made the result visible in the app; v1.1.1 fixed the
> flat genre tree and the filename contract found in app tests.

## Goal

Make everything we collect visible and useful inside **MultiLib.exe** — the
existing Windows desktop app that is the end-user interface for this project.
Three concrete needs, all scoped to "myself, on this Windows box, through the
app":

1. **Enrich owned books** — link the ~2,156 books on disk back to their
   catalog rows so the app can show covers, descriptions, ratings and series
   position for what is actually in the personal library.
2. **Collection status view** — see, inside the app's own idiom, collection
   coverage per author/genre, series gaps, and the next to-collect priorities.
3. **Read/search experience** — open and find books already on disk without
   leaving the app. (Confirmed: the user opens books from inside the app.)

## Architecture (confirmed, not hypothetical)

The app models **a library = a MySQL database holding the ml* catalog schema**
and switches between them. The user proved this by creating a third library
through the app itself:

- **`myprivatelib`** — an empty library DB created in-app with the Flibusta
  plugin, connectable from the app, sitting in the MariaDB datadir with the
  **same 17-table schema as `flibusta`** (`mlbook`, `mlauthorname`,
  `mlcoverpage`, `mldescription`, `mlrating`, `mlseq`/`mlseqname`,
  `mlgenre`/`mlgenrename`, `mlauthor`, `mlnews*`, `mluser*`, `mlactual`,
  `mlcustinfo`, `mldownloaddata`), plus a `myprivatelib.lib` marker next to
  `flibusta.lib`.
- Nothing in `flibusta` or `mllbr_main` needs to be touched, ever: the
  personal library is a **self-contained sibling DB**. Deleting it = deleting
  one database; rebuilding it = re-running one tool.
- `[MySQL]` in `MultiLib.ini`: `root` / no password / `localhost:3306` — the
  same connection our utilities already use.

The plan: **populate `myprivatelib` with the personal collection** — full
catalog rows copied from `flibusta` for exactly the books on disk, written in
the shape the app itself writes — then switch the app to it like
Flibusta ↔ Librusec. Enrichment (covers/descriptions/ratings/series) is
inherited because the copied rows carry the same metadata, self-contained in
`myprivatelib`.

## Ecosystem today (grounded)

| Piece | What it is | Where |
|---|---|---|
| `MultiLib.exe` | closed-source Delphi library app (Russian UI, AlReader2 reader, plugin dir, query bank, OPDS support, Downloads grid) | `C:\MultiLib\` |
| `flibusta` DB (17 tables) | the catalog the app browses (`CurrentLibName=flibusta`); `mlbook` carries per-file columns `filename`/`arcname`/`deleted`/`library` + `pi_*`/`di_*` info | MariaDB datadir |
| `myprivatelib` DB (17 tables) | **the target library** — app-created, empty, same schema as `flibusta` | MariaDB datadir |
| `mllbr_main` DB (4 tables) | app registry: `mldownload` (per-library download ledger, `(bookid, library)` unique), `mlgroup`/`mlgroupname`, `mlgenrelist` — feeds the app's Downloads grids | MariaDB datadir |
| `plugins/Private/` | the app's personal-library schema template (`init.sql` — `mlbook` w/ `filename`, `arcname`, `md5`) | `C:\MultiLib\plugins\Private\` |
| `plugins/Flibusta/`, `plugins/Librus/` | the two online-catalog plugins; user created `myprivatelib` through the Flibusta one | `C:\MultiLib\plugins\` |
| `upload/` | downloaded official dumps `flibusta_YYYY-MM-DD/` (the load-a-catalog path) | `C:\MultiLib\upload\` |
| `Books` folder | personal collection: 2,156 real books (2,145 zip-wrapped FB2 + 11 loose fb2; 457 `desktop.ini` noise), prefix tree `Letter/…/Author/Series/Book`; the user sets the app's library/download folder | `C:\Backup_Go7\Books` |
| Derived artifacts | per-author reconcile TSV, to-collect list (5,663), download-size estimate | `C:\Backup_Go7\merge-reports` |

Key facts that shape the plan:

- `MultiLib.ini`: `[MySQL] root@localhost:3306`, `CurrentLibName` = active
  library DB, `[recent]` entries keyed `bookid:library`, `ShowDownloaded` +
  `RGridDl*` = Downloads grid driven by `mldownload`.
- **`flibusta.mlbook.md5` is 100% populated and is the strongest match
  tier** (verified 2026-09-04): all 869,130 rows carry the md5 of the
  DECOMPRESSED FB2 content — `zcat file.zip | md5sum` (== `unzip -p`) and
  loose `.fb2` hashes resolve to exactly one `bookid`.  (The earlier
  "md5 unavailable" note referred to the unloaded `lib.md5` dump; the
  catalog column itself carries the hashes.)
- `flibusta.mlbook.filename`/`arcname` are NOT a usable match seam: the
  spike measured `filename` 100% populated but transliterated
  (librusec-style, e.g. `Aarh_Andrej_Aida`) and `arcname` 0% populated.
- **`mlcoverpage` and `mldescription` are EMPTY in the loaded dump** —
  covers/descriptions are not part of the loaded dump (they would need the
  separate extended-data torrents loaded first).  The self-contained
  enrichment `myprivatelib` copies today is ratings (361,761), series,
  genres and `mlcustinfo` (163,161).
- Author-level name matching is already proven by `reconcile_library.sh`
  (the spike: 2,075/2,156 disk files = 96.2% exact by author/series/title;
  md5 supersedes that tier entirely).

## What gets populated and how

For every real book on disk (zip-wrapped FB2 + loose fb2; skip `desktop.ini`,
empty dirs, hidden files):

1. **Hash it** — zip-wrapped FB2 by its decompressed content (`unzip -p`,
   `zcat` fallback), loose `*.fb2` directly; unreadable zips are marked
   `corrupt`.
2. **Resolve its catalog `bookid`** (match ladder, order of strength):
   a. **md5-exact** — join the file hash against `flibusta.mlbook.md5`
      (one read-only `(md5, bookid)` map pull; no per-file queries).
      Duplicate catalog md5s resolve to the lowest bookid and are counted.
   b. author (prefix dirs) → series (parent dir) → normalized title — the
      fallback tier for the few unmatched files (still future work).
   c. report as unmatched otherwise.
3. **Copy the catalog rows into `myprivatelib`** — `INSERT … SELECT` from
   `flibusta` by resolved `bookid`, per-run column-parity checked:
   per-book `mlbook`, `mlauthor`, `mlgenre`, `mlseq`, `mlrating`,
   `mlcustinfo` (chunked `IN`-lists), plus the whole small reference tables
   `mlauthorname`, `mlgenrename`, `mlseqname`.  `mlcoverpage` /
   `mldescription` are NOT populated (empty in the source — see above).
   `mlbook.filename` is copied as-is (the app's path convention is still
   unproven — the open-trial decides whether we must rewrite it).
4. **Multi-author books** appear once (canonical row) — dedupe on `bookid`
   (`mlauthor` keeps every author link, which is how MultiLib models them).
5. Write the per-run TSV report (matched / unmatched / corrupt / skipped per
   file) for review.

Rebuild semantics: `myprivatelib` is *our* database, so the tool reloads it
from scratch each run (managed tables are cleared and reloaded from
`flibusta`) while the app is not connected to it — simplest correctness, no
drift, idempotent by construction.  Only the 9 managed tables are touched:
app-owned tables (`mlactual`, `mldownloaddata`, `mlnews*`, `mluser*`) are
never cleared, so rows the app writes itself survive a rebuild. (Incremental
upsert is a later option if rebuilds get slow.)

## Phases

### Phase 0 — Probe (target is our own empty DB — safe by construction)

1. **Schema parity check — DONE**: diffed `myprivatelib`'s table columns
   against `flibusta`'s; all 9 managed tables are identical
   (`mlbook` 25 cols, `mlauthor`, `mlauthorname`, `mlgenre`, `mlgenrename`,
   `mlseq`, `mlseqname`, `mlrating`, `mlcustinfo`).  (One earlier wart
   repaired: `myprivatelib.mlcustinfo.frm` was corrupt; recreated empty from
   the valid schema.)
2. **Behavior probe (decisive) — BLOCKED**: with the app's current library =
   `myprivatelib`, the user downloads one known book the way they normally
   would, then opens it.  An empty catalog offers nothing to download, so
   this probe must come AFTER population (population first, then observe
   the app's own write shape on a follow-up download).  Still pinned in the
   plan: exact `mlbook` row shape incl. `filename` value, `mldownloaddata`,
   and the folder/filename convention.
3. **Open trial — still pending**: hand-insert (or populate-then-check) one
   `mlbook` row for an existing `Books` file, user opens it in the app →
   proves the app opens *our* rows and their files.  This is the
   naming-contract test for `mlbook.filename`; iterate until one file opens.
4. **Match-rate spike — DONE (superseded)**: measured 2,075/2,156 disk
   files (96.2%) exact by author/series/title; `mlbook.filename` proved
   unusable (transliterated) and `arcname` empty — but the md5 finding
   replaces that whole ladder with exact matching.

**Exit (revised):** schema parity confirmed ✓, md5 match ladder verified ✓,
behavior probe after population (pending), one disk book opening in-app from
populated rows (pending).

### Phase 1 — Population tool

**SHIPPED: `bin/populate_myprivatelib.sh` v1.3.0** (project conventions:
versioned header, config, `--dry-run`/`--debug`, MariaDB lifecycle, tests,
CI, docs): scan `Books` → hash → md5-resolve `bookid`s → rebuild `myprivatelib`
row-by-row with the **flibusta source keys verbatim** (v1.3.0, per
`docs/DO_IT_20260906_141511.md`: no synthetic keys — the v1.2.0
tool-assigned 1..N ids are gone) → FK integrity gate (9 reference
paths) → per-run TSV report (matched/unmatched/corrupt/skipped).  Matched
files are the whole collection: the ladder (a) md5 tier resolves them
exactly; ladder (b) (author/series/title) remains as the fallback for
unmatched files.

**Key strategy (v1.1.0, the fix for "app shows no books"):** the v1.0.0
`INSERT … SELECT *` copied flibusta's ids wholesale — foreign ids broke
the app's key bookkeeping, so MultiLib.exe listed catalog basics but no
books.  v1.1.0 lets myprivatelib's `AUTO_INCREMENT` generate every key
(v1.3.0 revision, per `docs/DO_IT.md` + `docs/DO_IT_20260906_141511.md`:
the app treats server-generated PK columns differently from the original
schema's plain ones — the tool still strips `AUTO_INCREMENT` from all 16
PK columns of the target schema, but the keys themselves are now the
**flibusta source keys, copied verbatim** — no 1..N counters, no session
variables, no `LAST_INSERT_ID()`):
one `INSERT` per row carrying the source key values unchanged; one SQL
script in one client session with `TRUNCATE` first and a post-reload FK
integrity gate.  Only books on disk are represented; `mlbook.filename`
holds the CATALOG value (the transliterated name the app displays —
v1.1.1 dropped the on-disk path), `arcname` the on-disk zip member;
`mlgenrename` pulls the used genres' ancestor categories so the genre
tree renders, with `parentgenreid` copied verbatim (the source tree is
self-consistent); `mlrating` comes from `flibusta.mlrating` (the
`Flibusta_Load_mlrating.sql` aggregate).  A parity mismatch on ANY
managed table aborts before any `TRUNCATE`.

**Acceptance (revised):** app switched to `myprivatelib` shows the full
personal collection with ratings/series/genres — v1.1.1 restored the
genre tree and the catalog `filename` after the first app tests; the
open-trial (with the on-disk `arcname`, this is the next probe) remains
pending; re-running is a no-op rebuild; `flibusta` and `mllbr_main`
untouched (verify by diff).  Covers/descriptions are a FUTURE add-on:
load the extended-data torrents, then re-run the population tool (which
will copy them automatically).

### Phase 2 — Collection status inside the app

A `qry_*` bank turning `myprivatelib` into status views — canonical in the repo
(`data/sql/`), mirrored to the app's query folder (`C:\MultiLib\queries\`):
coverage per author/genre, series gaps per collected author, next to-collect
priorities (against `flibusta`), reconcile summary lines. Keep the app's
parameterized-query idiom (`SET @…` + `SELECT`).

### Phase 3 — Read/search polish

- Fix any naming drift that blocks opening registered files.
- Search the owned subset through the app's existing search or an added
  `qry_*` on `myprivatelib`.
- Optional (only if wanted): mirror owned books into `mllbr_main.mldownload`
  (`library='myprivatelib'`) so the app's Downloads grid shows the collection —
  decided after Phase 0 reveals how much the app writes there itself.

## Risks & rules

- **Never alter the app's schema** — `myprivatelib` keeps exactly the columns
  the app created; we populate, we don't remodel (the per-run parity check
  enforces this by skipping, never altering).
- **App not connected to `myprivatelib` during rebuilds** (switch to `flibusta`
  or close the app); back up the datadir before first real run (existing
  pattern).
- **Folder & filename convention** still unproven (the open-trial is the
  test) — `mlbook.filename` is copied as-is today; the open-trial decides
  whether a mapping layer is needed.
- **md5 matching requires the source catalog to carry `md5`** — it does
  (100% populated), and a hash without a catalog row is simply reported
  unmatched (needs ladder (b) later).
- **Covers/descriptions absent** until the extended-data torrents are
  loaded; the tool already copies them whenever the source starts
  carrying them.
- **Multi-author books** deduped to one canonical row per `bookid`.
- **`desktop.ini` and empty dirs** are scan noise, never registered.
- The app may write rows itself (downloads, `mldownloaddata`) into
  `myprivatelib` over time — the rebuild touches only the 9 managed tables,
  so app-owned rows survive; if the app ever writes into `mlbook` itself,
  the rebuild policy must be revisited (switch to incremental upsert).

## Out of scope (for now)

- Web / mobile / OPDS export of the personal library (the app has an `[opds]`
  section — future option).
- A new reader application.
- Registering the earlier `Books_01` / `Books_02` / `Books_Initial_Load`
  trees — the plan targets the live `Books` collection; older trees can be
  registered later the same way.
