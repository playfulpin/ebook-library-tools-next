# MultiLib / Flibusta database — reference

> **Scope:** everything we know about the MariaDB instance that backs the
> MultiLib desktop app and the Flibusta catalog — the `flibusta`,
> `myprivatelib` and `mllbr_main` databases, every table's schema and
> purpose, the relationships between them, how data gets loaded and
> updated (both the BookTracker-import catalog pipeline and the
> MultiLib_Utilities personal-library toolchain), and the hard-won
> implementation details that make the whole thing work from WSL2.
>
> **Updated:** 2026-09-04 (rev 2 — genre-tree and filename contract
> corrected after the v1.1.1 re-test; all numbers re-verified live).
> **How verified:** every schema/row-count/index figure below was taken
> read-only from the live server (`information_schema`, `SHOW INDEX`,
> `SELECT COUNT(*)`) on 2026-09-04 unless a date is stated otherwise.
> **Companion docs:** `docs/REPRESENTATION_PLAN.md` (the personal-library
> plan this DB serves, rev 6), `docs/NEXT.md` (resume notes),
> `docs/Flibusta_DB_findings.txt` (the original md5 idea that made exact
> matching possible), `docs/BOOK_LIBRARY_MERGE_PLAN.md`. The catalog
> loader lives in the sibling project `BookTracker-import` (see §6.1).

---

## Table of contents

1. [Overview](#1-overview)
   1.1 [Environment at a glance](#11-environment-at-a-glance)
   1.2 [The three libraries](#12-the-three-libraries)
   1.3 [Who writes what](#13-who-writes-what)
2. [Database topology](#2-database-topology)
   2.1 [Databases](#21-databases)
   2.2 [The 17-table ml\* schema](#22-the-17-table-ml-schema)
   2.3 [mllbr_main — the app's own schema](#23-mllbr_main--the-apps-own-schema)
3. [Table reference (the 17-table ml\* schema)](#3-table-reference-the-17-table-ml-schema)
   3.1 [mlbook — the catalog hub](#31-mlbook--the-catalog-hub)
   3.2 [Reference (name) tables](#32-reference-name-tables)
   3.3 [Join tables](#33-join-tables)
   3.4 [Attached data](#34-attached-data)
   3.5 [Enrichment gaps: mlcoverpage / mldescription](#35-enrichment-gaps-mlcoverpage--mldescription)
   3.6 [App-owned tables](#36-app-owned-tables)
4. [Relationships and data model](#4-relationships-and-data-model)
   4.1 [Entity-relationship summary](#41-entity-relationship-summary)
   4.2 [The genre tree — two levels, verified](#42-the-genre-tree--two-levels-verified)
   4.3 [Key strategy: AUTO_INCREMENT, no foreign keys](#43-key-strategy-auto_increment-no-foreign-keys)
   4.4 [Index inventory](#44-index-inventory)
5. [The lib\* dump schema](#5-the-lib-dump-schema)
   5.1 [Table-by-table](#51-table-by-table)
   5.2 [Load order](#52-load-order)
   5.3 [Where the lib\* tables go](#53-where-the-lib-tables-go)
6. [Loading and update logic](#6-loading-and-update-logic)
   6.1 [BookTracker-import pipeline](#61-booktracker-import-pipeline)
   6.2 [The six ingest stages](#62-the-six-ingest-stages)
   6.3 [mlrating: per-user librate → per-book aggregate](#63-mlrating-per-user-librate--per-book-aggregate)
   6.4 [MultiLib_Utilities tools](#64-multilib_utilities-tools)
   6.5 [populate_myprivatelib.sh — the personal-library rebuild](#65-populate_myprivatelibsh--the-personal-library-rebuild)
   6.6 [Data flow end to end](#66-data-flow-end-to-end)
7. [Key findings and implementation details](#7-key-findings-and-implementation-details)
   7.1 [md5 matching: the strongest lookup tier](#71-md5-matching-the-strongest-lookup-tier)
   7.2 [filename / arcname are not the on-disk path](#72-filename--arcname-are-not-the-on-disk-path)
   7.3 [Covers and descriptions are empty](#73-covers-and-descriptions-are-empty)
   7.4 [Duplicate md5s and multi-author books](#74-duplicate-md5s-and-multi-author-books)
   7.5 [Charset: pinning the client](#75-charset-pinning-the-client)
   7.6 [WSL2 ↔ Windows MariaDB lifecycle](#76-wsl2--windows-mariadb-lifecycle)
   7.7 [The mysql_upgrade incident](#77-the-mysql_upgrade-incident)
   7.8 [MyISAM crash and recovery](#78-myisam-crash-and-recovery)
   7.9 [Re-test status after v1.1.1 (open issues)](#79-re-test-status-after-v111-open-issues)
8. [Connection contract and invariants](#8-connection-contract-and-invariants)
   8.1 [Connection contract](#81-connection-contract)
   8.2 [Invariants](#82-invariants)
9. [Appendix: snapshots and reference data](#9-appendix-snapshots-and-reference-data)
   9.1 [flibusta row counts + AUTO_INCREMENT watermarks](#91-flibusta-row-counts--auto_increment-watermarks)
   9.2 [myprivatelib row counts (v1.1.1 rebuild)](#92-myprivatelib-row-counts-v111-rebuild)
   9.3 [mlrating distribution (both DBs)](#93-mlrating-distribution-both-dbs)
   9.4 [mlbook column reference and value census](#94-mlbook-column-reference-and-value-census)
   9.5 [mllbr_main schema](#95-mllbr_main-schema)
   9.6 [Quick-reference queries](#96-quick-reference-queries)

---

## 1. Overview

The MultiLib desktop app (`C:\MultiLib\`, `MultiLib.exe`) models **a
library = a MySQL/MariaDB database with the 17-table `ml*` schema**. It
switches between libraries via `CurrentLibName` in `MultiLib.ini`
(`[MySQL] root@localhost:3306`, no password). The app never touches raw
dump tables — it reads only the `ml*` catalog shape.

The **Flibusta catalog** lives in the `flibusta` database (869,130 books
at the last load, 2026-09-01 dump). The **personal library** lives in
`myprivatelib` — an empty sibling library created in-app with the Flibusta
plugin, now populated from the on-disk `Books` collection by
`bin/populate_myprivatelib.sh`. A third database, `mllbr_main`, is the
app's original built-in library and uses a *different, smaller* schema.

The catalog is maintained by the sibling project **BookTracker-import**
(download → extract → ingest into `flibusta`). This project
(MultiLib_Utilities) builds on top of it: it exports author lists,
sizes the next collecting round, reconciles disk vs catalog, backs up
the personal library, and finally populates `myprivatelib` from the
`Books` folder. Both projects share the same MariaDB instance, the same
connection contract (§8.1) and the same MariaDB lifecycle helper.

### 1.1 Environment at a glance

| Item | Value |
|---|---|
| Server | MariaDB **10.4.7** portable Windows build |
| Executable | `C:\mariadb-10.4.7-winx64\bin\mysqld.exe --console` |
| Host / port | `127.0.0.1:3306` (TCP; WSL2 talks to the Windows host) |
| User | `root`, no password (local development box) |
| Client | WSL2 Ubuntu `mysql` CLI — **Ubuntu 24.04 ships client 8.0.46** against the 10.4.7 server (works; see §7.7 for why versions must be handled) |
| Storage engine | **MyISAM** everywhere in the ml\* schema (no InnoDB, no FK enforcement) |
| Collations | `utf8_general_ci` for the ml\* tables; **`mlactual` alone is `utf8_unicode_ci`**; `mllbr_main` is `utf8_general_ci` |
| Databases | `flibusta`, `myprivatelib`, `mllbr_main` (+ system DBs) |

### 1.2 The three libraries

| Database | Role | Schema | Populated by |
|---|---|---|---|
| `flibusta` | The full catalog — read-only source for everything | 17-table `ml*` | BookTracker-import ingest pipeline (§6.1–6.3) |
| `myprivatelib` | The **personal** library (the end-user's own collection) | Same 17-table `ml*` | `bin/populate_myprivatelib.sh` from the `Books` folder (§6.5) |
| `mllbr_main` | The app's original built-in library | Different, 4-table schema (`mldownload`, `mlgenrelist`, `mlgroup`, `mlgroupname`) | The app itself |

### 1.3 Who writes what

* **BookTracker-import** writes `flibusta`: loads the 12 dump files +
  one legacy filename table, converts `lib*` → `ml*`, creates the base
  tables, builds `mlrating`, checks, then drops the staging tables
  (§6.2). It never touches `myprivatelib` or `mllbr_main`.
* **MultiLib_Utilities tools** (export, reconcile, estimate, backup,
  populate) **never write `flibusta` or `mllbr_main`**. The populate
  tool writes only the nine managed catalog tables inside `myprivatelib`.
* **The app itself** owns `mlactual`, `mldownloaddata`, `mlnews*`,
  `mluser*` in any ml\* library — the tools leave those rows alone, so
  app-written rows survive population runs.

---

## 2. Database topology

### 2.1 Databases

```
MariaDB 10.4.7 (127.0.0.1:3306)
├── flibusta          # the catalog — 17 ml* tables, read-only source
├── myprivatelib        # the personal library — same 17 ml* tables
├── mllbr_main        # the app's original library — 4 tables, different shape
├── mysql             # server system tables
├── information_schema
└── performance_schema
```

### 2.2 The 17-table ml\* schema

`flibusta` and `myprivatelib` share the same 17 tables. **Column
definitions are identical for all 17** (the populate tool re-verifies
column parity on all nine tables it manages on every run; index sets
differ slightly — see §4.4). They fall into six groups:

| Group | Tables | Purpose |
|---|---|---|
| Hub | `mlbook` | One row per book — the center of the model |
| Reference names | `mlauthorname`, `mlgenrename`, `mlseqname` | Name dictionaries for authors, genres, series |
| Joins | `mlauthor`, `mlgenre`, `mlseq` | Many-to-many links book ↔ author / genre / series |
| Attached data | `mlrating`, `mlcustinfo` | Per-book rating and custom info |
| Enrichment gaps | `mlcoverpage`, `mldescription` | **Empty** in the loaded dump (see [7.3](#73-covers-and-descriptions-are-empty)) |
| App-owned | `mlactual`, `mldownloaddata`, `mlnews`, `mlnewsname`, `mluserkeyword`, `mluserprim` | Rows the app itself writes; tools never touch them |

### 2.3 mllbr_main — the app's own schema

The app's original library is *not* an `ml*` library — it uses a
different, minimal schema (full column reference in [9.5](#95-mllbr_main-schema)):

| Table | Rows (2026-09-04) | Purpose |
|---|---|---|
| `mldownload` | 0 | Download records |
| `mlgenrelist` | 109 | **Flat** genre dictionary: `genrecode` + `genregroup` + `genrenamerus` (no parent-id tree) |
| `mlgroup` | 0 | Group (collection) records |
| `mlgroupname` | 3 | Group names, with a `groupidparrent` self-reference |

This is why the app supports "switching libraries": the Flibusta plugin
creates a *second* library (`myprivatelib`) with the full `ml*` schema,
and the app's UI can point at either.

---

## 3. Table reference (the 17-table ml\* schema)

All definitions below were read live from `flibusta` on 2026-09-04 and
are column-identical in `myprivatelib`. Types are abbreviated
(`int(11)`, `varchar(n)`, `char(n)`, `datetime`, `binary(1)`).
`NOT NULL` is the norm; nullable columns are marked.

### 3.1 mlbook — the catalog hub

**Purpose:** one row per book. Everything else hangs off `bookid`.

**Key:** `bookid` INT AUTO_INCREMENT PRIMARY KEY.

| Column | Type | Null | Notes |
|---|---|---|---|
| `bookid` | int | no | PK, auto-increment |
| `library` | varchar(64) | no | Source library name — `'flibusta'` (catalog) or `'myprivatelib'` (personal); **single-valued in each DB** |
| `title` | varchar(255) | no | Book title |
| `lang` | varchar(10) | no | Language code (indexed) |
| `date_in` | datetime | **yes** | Date the book entered the catalog |
| `filename` | varchar(255) | no | Catalog "file name" — see [7.2](#72-filename--arcname-are-not-the-on-disk-path) (indexed) |
| `filesize` | int | no | Size in bytes — decompressed FB2 size in the catalog; **on-disk bytes in `myprivatelib`** |
| `arcname` | varchar(255) | no | Zip member name — **empty in the catalog**; on-disk member in `myprivatelib` |
| `ext` | varchar(5) | no | Content format (indexed). Catalog: mostly `fb2` but 200+ distinct legacy values; `myprivatelib`: always `fb2` |
| `deleted` | char(1) | no | `'0'`/`'1'` (indexed) — see census in [9.4](#94-mlbook-column-reference-and-value-census) |
| `md5` | char(32) | no | Hex md5 of the **book content** (indexed, non-unique) — see [7.1](#71-md5-matching-the-strongest-lookup-tier) |
| `srclang` | varchar(10) | no | Source language (empty in `myprivatelib` rows copied from the catalog) |
| `date_wr` | char(32) | **yes** | Written date (free-form) |
| `keywords` | varchar(255) | no | Keywords |
| `di_progused` | varchar(255) | no | Producing program |
| `di_date` | char(32) | **yes** | Document date |
| `di_srcurl` | varchar(255) | no | Source URL |
| `di_srcosr` | varchar(100) | no | Source origin |
| `di_author` | varchar(100) | no | Document author |
| `di_id` | varchar(254) | no | Document id |
| `di_version` | varchar(10) | no | Document version |
| `pi_bookname` | varchar(255) | no | Publication: book name |
| `pi_publisher` | varchar(100) | no | Publication: publisher |
| `pi_city` | varchar(50) | no | Publication: city |
| `pi_year` | varchar(10) | no | Publication: year |
| `pi_isbn` | varchar(100) | no | Publication: ISBN |

### 3.2 Reference (name) tables

Name dictionaries. Each row is one author / genre / series; the join
tables reference their ids.

#### mlauthorname

**Purpose:** author names and catalog-wide counts. **Key:** `authorid`
INT UNSIGNED AUTO_INCREMENT PRIMARY KEY.

| Column | Type | Notes |
|---|---|---|
| `authorid` | int unsigned | PK, auto-increment |
| `FirstName` / `MiddleName` / `LastName` | varchar(99) | Name parts (all NOT NULL, default `''`) |
| `NickName` | varchar(33) | Pen name |
| `FullName` | varchar(200) | Canonical display name — the field the reconcile tool matches disk folders against |
| `Email` | varchar(255) | NOT NULL, no default (`''` unless the loader fills it) |
| `TotalCount` | int | Books by this author in the catalog (incl. deleted) |
| `NormalCount` | int | Non-deleted books by this author |

#### mlgenrename

**Purpose:** genre names, forming a **two-level tree** via
`parentgenreid` — see [4.2](#42-the-genre-tree--two-levels-verified).
**Key:** `genreid` INT AUTO_INCREMENT PRIMARY KEY.

| Column | Type | Notes |
|---|---|---|
| `genreid` | int | PK, auto-increment. Leaves occupy ids ≈ 1–296; **root category rows use ids 1,000,001–1,000,024** |
| `parentgenreid` | int | **Null for the 24 root category rows**; for the 272 leaf genres points at a root |
| `genrecode` | varchar(30) | Machine code — **present on leaf genres** (`sf_history`, `sf`, …), **empty on root category rows** |
| `genrenamerus` | varchar(100) | Russian display name (root rows carry only this + counts of zero) |
| `TotalCount` / `NormalCount` | int | Catalog book counts **per leaf genre** (root rows: 0) |

Only 296 rows — the taxonomy is small and *closed*: every genreid a
book links to resolves (0 orphans in the join, see §4.2).

#### mlseqname

**Purpose:** series names. **Key:** `seqid` INT UNSIGNED AUTO_INCREMENT
PRIMARY KEY; `seqname` varchar(254) **UNIQUE**.

| Column | Type | Notes |
|---|---|---|
| `seqid` | int unsigned | PK, auto-increment |
| `seqname` | varchar(254) | UNIQUE |
| `TotalCount` / `NormalCount` | int | Catalog book counts per series |

### 3.3 Join tables

Pure many-to-many links. Each row has its own auto-increment PK **plus**
the two foreign ids; there are **no FK constraints** (MyISAM), so the
ids are meaningful only by convention — which is why the populate tool
regenerates them (see [4.3](#43-key-strategy-auto_increment-no-foreign-keys)).

#### mlauthor — book ↔ author

| Column | Type | Notes |
|---|---|---|
| `la_id` | int | PK, auto-increment |
| `bookid` | int unsigned | → `mlbook.bookid` (indexed) |
| `authorid` | int unsigned | → `mlauthorname.authorid` (indexed) |
| `role` | binary(1) | Role byte, `'a'` (author) |

A book can have **multiple** rows (multi-author books — every sampled
book had exactly 2 authors). `flibusta` holds 1,073,467 rows.
Unique index `bookseq` over `(bookid, authorid, role)`.

#### mlgenre — book ↔ genre

| Column | Type | Notes |
|---|---|---|
| `gn_id` | int | PK, auto-increment |
| `bookid` | int unsigned | → `mlbook.bookid` (indexed) |
| `genreid` | int unsigned | → `mlgenrename.genreid` (indexed) — **only leaf genres (ids ≤ 296), never the 1,000,001+ root rows** |

`flibusta` holds 1,374,515 rows (a book typically has 2–3 genres).

#### mlseq — book ↔ series (with position)

| Column | Type | Notes |
|---|---|---|
| `sq_id` | int | PK, auto-increment |
| `bookid` | int | → `mlbook.bookid` (indexed) |
| `seqid` | int | → `mlseqname.seqid` (indexed) |
| `seqnum` | int | Position **within** the series |

`flibusta` holds 446,629 rows. Unique index `bookseq` over
`(bookid, seqid, seqnum)`.

### 3.4 Attached data

#### mlrating — the per-book aggregate rating

**Purpose:** exactly one row per *rated* book (361,761 rows ↔ 361,761
distinct bookids). Built by `BookTracker-import/sql/Flibusta_Load_mlrating.sql`
from the raw per-user `librate` table (see [6.3](#63-mlrating-per-user-librate--per-book-aggregate)).

| Column | Type | Notes |
|---|---|---|
| `rt_id` | int unsigned | PK, auto-increment |
| `bookid` | int | → `mlbook.bookid` (indexed) |
| `rating` | char(1) | `'1'`–`'5'` (indexed) |

The dump definition uses `ROW_FORMAT=FIXED`, `AVG_ROW_LENGTH=12`,
MyISAM (the loaded table's auto-increment watermark is 361,762).

#### mlcustinfo — per-book custom info

| Column | Type | Notes |
|---|---|---|
| `ci_id` | int | PK, auto-increment |
| `bookid` | int | **Nullable** → `mlbook.bookid` (indexed) |
| `di_history` | varchar(2048) | Document history |
| `custominfo` | varchar(2048) | Custom info |

`flibusta` holds 163,161 rows (books that carry custom info).

### 3.5 Enrichment gaps: mlcoverpage / mldescription

Both tables exist in the schema but are **empty** in the loaded dump —
covers and descriptions are shipped in the *extended-data torrents*,
which the current pipeline does not load. So "enrichment comes free"
does **not** hold for covers/descriptions; the real enrichment in the
loaded catalog is ratings, series, genres, and `mlcustinfo`. See
[7.3](#73-covers-and-descriptions-are-empty).

| Table | Columns |
|---|---|
| `mlcoverpage` | `cp_id` PK auto, `bookid` (indexed, nullable), `cover` mediumblob |
| `mldescription` | `ds_id` PK auto, `bookid` (indexed, nullable), `descr` varchar(20000) |

### 3.6 App-owned tables

All six are **empty in `flibusta`** (0 rows) and **owned by the app**:
it writes them as the user works (downloads, news, user keyword
priming). MultiLib_Utilities tools never touch them.

| Table | Columns | Notes |
|---|---|---|
| `mlactual` | `BookId`, `FileType` char(4), `Author`, `Title`, `FileName`, `ArcName`, `Status` smallint | **No auto-increment PK**; indexed on `BookId`; the only table whose collation is `utf8_unicode_ci` |
| `mldownloaddata` | `dd_id` PK auto, `bookid` (UNIQUE), `date_dl` datetime | One row per downloaded book |
| `mlnews` | `cb_id` PK auto, `critid`, `bookid` | News/criteria link |
| `mlnewsname` | `critid` PK auto, `critname`, `critfilter` blob, `critsql` text | News criteria definitions |
| `mluserkeyword` | `kw_id` PK auto, `bookid`, `userkeywords` | User keywords per book |
| `mluserprim` | `up_id` PK auto, `bookid`, `prim` | User "prim" flags |

---

## 4. Relationships and data model

### 4.1 Entity-relationship summary

```
                  mlauthorname (authors)
                       ▲
                       │ authorid
mlbook ──┬── 1:N ── mlauthor (book↔author join, role='a')
         │
         ├── 1:N ── mlgenre ── N:1 ── mlgenrename (genres)
         │              │                │
         │              │                └── parentgenreid ── self → a root category row
         │              │                    (books never join the root rows)
         │
         ├── 1:N ── mlseq ── N:1 ── mlseqname (series)   (+ seqnum = position)
         │
         ├── 1:0..1 ── mlrating   (per-book aggregate rating)
         ├── 1:0..1 ── mlcustinfo (custom info)
         └── 1:0..1 ── mlcoverpage / mldescription (future: extended torrents)
```

All links are **by convention** — MyISAM has no FK enforcement, so
referential integrity is maintained by the loaders and by the populate
tool's key-capture discipline (below).

### 4.2 The genre tree — two levels, verified

`mlgenrename.parentgenreid` points at another row of the same table.
Live census (2026-09-04):

* **296 rows total = 24 root rows + 272 leaf genres.**
* The **24 root rows** (ids `1000001`–`1000024`, e.g. `1000022` =
  «Фантастика») are pure *category headers*: `genrecode` is **empty**,
  `TotalCount`/`NormalCount` are **0**, only `genrenamerus` is set.
* The **272 leaf genres** (ids ≈ 1–296, e.g. `1` = `sf_history`
  «Альтернативная история», `12` = `sf` «Научная фантастика») carry the
  real `genrecode` + counts and point their `parentgenreid` at a root.
* The tree is **exactly two levels** — verified: 0 rows whose parent is
  itself a non-root (no grandchildren).
* **Books join only leaf genres:** `mlgenre.genreid` spans 1–296 and no
  row ever references a `1,000,001+` id; 272 distinct genreids are
  used and **all resolve** (0 orphans in `flibusta` and `myprivatelib`).

**Consequence for the personal library:** the app renders this tree.
When the v1.1.0 populate imported only the leaf genres our books use,
every row landed with `parentgenreid = NULL` and the tree collapsed to a
flat list — the app's genre panel looked wrong. **v1.1.1 fixed this** by
pulling each used genre's *ancestor category rows* from the catalog and
remapping `parentgenreid` to the freshly generated root ids (parents
emitted first). Result in `myprivatelib`: **84 rows = 14 root categories
(the ones our books' genres fall under) + 70 leaf genres**, all
parent/child pointers valid. Examples verified live: «Фантастика»
(root id 13) → «Научная фантастика» (`sf`), «Альтернативная
история», … 30 children; «Детективы и триллеры» → 5 children.

### 4.3 Key strategy: AUTO_INCREMENT, no foreign keys

Every table generates its own ids (`AUTO_INCREMENT`), including the join
tables (`la_id`, `gn_id`, `sq_id`, `rt_id`, `ci_id`). The Flibusta dump
loader itself follows this pattern: generate via the sequence, then
store the id **explicitly** in the dump (the ids are stable artifacts of
the loader — `libavtorname` authorids, `libbook` bookids, etc.). That is
why the catalog's AUTO_INCREMENT watermarks run far ahead of the row
counts (e.g. `mlseqname`: 80,744 rows but watermark 112,843) — the ids
are sparse, inherited from the source catalog.

**Consequence for `myprivatelib`:** copying flibusta's ids wholesale
(the v1.0.0 populate) broke the app's key bookkeeping — the app showed
catalog basics but no books. The v1.1.0 populate therefore regenerates
**every** key; **v1.2.0 (per `docs/DO_IT.md`) goes further: the app also
treats server-generated (AUTO_INCREMENT) PK columns differently from the
original schema's plain PK columns**, so the populate tool first strips
`AUTO_INCREMENT` from all 16 PK columns of the target schema
(schema-driven, attribute-preserving `ALTER TABLE ... MODIFY COLUMN`
from `SHOW CREATE TABLE`, verified via `information_schema.COLUMNS.EXTRA`)
and then assigns **every** key explicitly: `INSERT` one row with a
contiguous tool-assigned id → capture it into a session variable
(`@bid_<old>`, `@aid_<old>`, `@gid_<old>`, `@sid_<old>`) → child rows
reference only captured variables — the server never generates a key.
(The strip also exposed that the child tables' own PKs — `la_id`,
`gn_id`, `sq_id`, `rt_id`, `ci_id` — must be assigned explicitly too;
the v1.2.0 emitters cover all of them, since a stripped PK is plain
`NOT NULL` with no default.)
`TRUNCATE` at the top of the one-session script restarts the assignment
at 1, so every run is a clean, idempotent rebuild with **contiguous ids**.
The catalog side is unchanged (its AUTO_INCREMENT is the dump loader's
legacy and the app's own databases keep the original DDL). See
`bin/populate_myprivatelib.sh` and [6.5](#65-populate_myprivatelibsh--the-personal-library-rebuild).

### 4.4 Index inventory

Live `SHOW INDEX` (2026-09-04), `flibusta` — `myprivatelib` is identical
**except where noted**:

| Table | Indexes |
|---|---|
| `mlbook` | PRIMARY(`bookid`); non-unique single-column: `lang`, `filename`, `ext`, `deleted`, `md5` |
| `mlauthor` | PRIMARY(`la_id`); `bookid`; `authorid`; UNIQUE `bookseq`(`bookid,authorid,role`) |
| `mlauthorname` | PRIMARY(`authorid`); `TotalCount`; `NormalCount`; `FirstName`; `LastName`; `FullName`. **flibusta-only oddity:** two extra indexes literally *named* `MiddleName` and `NickName` but **defined on the `LastName` column** (a convert-script artifact). `myprivatelib` does **not** have them — the populate parity check compares columns only, so this difference is invisible to it and harmless |
| `mlgenre` | PRIMARY(`gn_id`); `bookid`; `genreid` |
| `mlgenrename` | PRIMARY(`genreid`); `parentgenreid`; `genrecode`; `genrenamerus`; `TotalCount`; `NormalCount` |
| `mlseq` | PRIMARY(`sq_id`); `bookid`; `seqId`(`seqid`); UNIQUE `bookseq`(`bookid,seqid,seqnum`) |
| `mlseqname` | PRIMARY(`seqid`); **UNIQUE `seqname`**; `TotalCount`; `NormalCount` |
| `mlrating` | PRIMARY(`rt_id`); `bookid`; `rating` |
| `mlcustinfo` | PRIMARY(`ci_id`); `bookid` |

Notes:

* **`mlbook.md5` is indexed** (non-unique) — contrary to the earlier
  "no index" assumption, equality lookups are indexed; the populate tool
  still pulls the whole map once (§7.1) because it needs the *complete*
  join and wants to detect duplicate md5s.
* The join tables carry both a plain `bookid` index and a UNIQUE
  `bookseq` triple — the unique indexes are what make re-runs safe
  against duplicate link rows in the catalog loader.

---

## 5. The lib\* dump schema

The `flibusta` database is loaded from the official Flibusta SQL dumps
(`lib.*.sql.gz` from the `FlibustaSQL` torrent). These **source tables**
are a flat, loader-oriented mirror of the catalog — some are pure joins,
some are the dictionaries that later become the `ml*` reference tables.
The dumps were inspected (CREATE TABLE + insert samples) on 2026-09-04.

### 5.1 Table-by-table

| Dump file | Table (in DB) | Key construction | Role / destination |
|---|---|---|---|
| `lib.libavtor.sql` | `libavtor` | `(BookId, AvtorId)` composite PK + `Pos`; **no** auto-inc | Pure join rows book ↔ author → `mlauthor` |
| `lib.libavtorname.sql` | `libavtorname` | `AvtorId` AUTO_INCREMENT (watermark ≈ 344,676), ids **stored explicitly** (`VALUES (1,'','','Коллектив авторов',…)`) | Author name dictionary → `mlauthorname` |
| `lib.libbook.sql` | `libbook` | `BookId` AUTO_INCREMENT (watermark ≈ 887,686), `md5 binary(32)` UNIQUE; **no filename column** | Book core → `mlbook` (minus filename) |
| `lib.libfilename.sql` | `libfilename` | `BookId` PK + `FileName` (transliterated, latin1) | Filename lookup → `mlbook.filename` |
| `lib.libfilenameold.sql` | `libfilenameold` | Loaded from the repo (`sql/`), not the torrent | Legacy/archive filename map; loaded last in the `load` stage |
| `lib.libgenre.sql` | `libgenre` | `Id` AUTO_INCREMENT (≈1.7M) + `(BookId, GenreId)` UNIQUE | Book ↔ genre join → `mlgenre` |
| `lib.libgenrelist.sql` | `libgenrelist` | `GenreId` AUTO_INCREMENT, PK `(GenreId, GenreCode)`, UNIQUE `GenreCode` | Genre dictionary → `mlgenrename` (incl. the 24 category rows) |
| `lib.libjoinedbooks.sql` | `libjoinedbooks` | `Id` AUTO_INCREMENT | **Merge redirects** (`BadId` → `GoodId`); not needed for a personal copy |
| `lib.librate.sql` | `librate` | `ID` AUTO_INCREMENT (≈2.9M), `BookId`, `UserId`, `Rate` | **Per-user** ratings → aggregated into `mlrating` |
| `lib.librecs.sql` | `librecs` | — (recommendations uid → bid) | Not needed |
| `lib.libseq.sql` | `libseq` | `(BookId, SeqId)` composite PK | Book ↔ series join → `mlseq` |
| `lib.libseqname.sql` | `libseqname` | `SeqId` AUTO_INCREMENT, `SeqName` UNIQUE | Series dictionary → `mlseqname` |
| `lib.libtranslator.sql` | `libtranslator` | `(BookId, TranslatorId)` composite PK | Translators; no `ml*` counterpart in the managed tables |

### 5.2 Load order

The ingest pipeline loads the dumps in this exact order (it matters only
for MyISAM table creation, not for FK correctness — the loader relies on
`FOREIGN_KEY_CHECKS=0`):

```
lib.libavtor → lib.libavtorname → lib.libbook → lib.libfilename →
lib.libgenre → lib.libgenrelist → lib.libjoinedbooks → lib.librate →
lib.librecs → lib.libseq → lib.libseqname → lib.libtranslator
```

Then the repo's `sql/lib.libfilenameold.sql` is loaded last (13th file).
Note the order is **not** dependency-ordered (`libavtor` references
`AvtorId` before `libavtorname` exists) — it works because MyISAM does
not enforce FKs. The `ml*` schema the app reads is strictly
dependency-ordered instead.

### 5.3 Where the lib\* tables go

After a full ingest run, `flibusta` contains **only the 17 `ml*`
tables** — the `lib*` staging tables are consumed and dropped: the
convert stage (`lib.convert.sql`) rebuilds the `ml*` catalog from them,
and the cleanup stage drops `librating`, `librate`, `libjoinedbooks`,
`librecs`, `libtranslator`. Verified 2026-09-04: the inventory shows no
`lib*` table remaining. This is also why re-aggregating `mlrating` from
`librate` is no longer possible — the aggregate in `mlrating` is the
authoritative source (see [6.3](#63-mlrating-per-user-librate--per-book-aggregate)).

---

## 6. Loading and update logic

### 6.1 BookTracker-import pipeline

The catalog is refreshed from the Flibusta tracker by the
`BookTracker-import` project (`bin/booktracker-import.sh` →
`bin/booktracker-extract.sh` → `bin/booktracker-ingest.sh`,
orchestrated by `bin/booktracker-sync.sh`):

```
booktracker-import.sh   fetch .torrent files (INPX, dumps, monthly archives)
        │
booktracker-extract.sh  aria2c download + decompress .sql.gz → mysql_feeds/
        │
booktracker-ingest.sh   load .sql files into the flibusta database (6 stages)
```

* `import` — downloads the small `.torrent` files from booktracker.org
  into `torrents/`.
* `extract` — downloads the payloads (`.sql.gz` dumps → `mysql_feeds/`
  as plain `.sql`; `.inpx` files → `inpx/`; monthly book archives →
  `book_archives/`).
* `ingest` — runs the six database stages below.

### 6.2 The six ingest stages

`bin/booktracker-ingest.sh` tracks each stage in a state file, so a
re-run skips completed stages (`--force` re-runs them):

| # | Stage | What runs | Result |
|---|---|---|---|
| 1 | `load` | Load the 13 SQL files in [5.2](#52-load-order) order | Raw `lib*` tables present |
| 2 | `convert` | `sql/lib.convert.sql` | `lib*` → `ml*` catalog rebuild (drops the consumed `lib*` tables; creates `mlbook` + `ml*` from the `lib*` source) |
| 3 | `base` | `sql/createtable.sql` | Base/app-owned tables (`mlactual`, `mldownloaddata`, `mlnews*`, `mluser*`, …) |
| 4 | `rating` | `sql/Flibusta_Load_mlrating.sql` | `mlrating` from `librate` (see below) |
| 5 | `check` | Row-count verification | `mlbook=869130 mlrating=361761` etc. |
| 6 | `cleanup` | `DROP` leftover tables | Drops `librating librate libjoinedbooks librecs libtranslator` |

The whole ingest is wrapped in a MariaDB lifecycle: the server is
started (elevated PowerShell, no UAC when WSL2 is elevated), used, then
gracefully shut down (`SHUTDOWN`, falling back to `taskkill /F`).

### 6.3 mlrating: per-user librate → per-book aggregate

`BookTracker-import/sql/Flibusta_Load_mlrating.sql` (re-verified
2026-09-04):

1. **Step 01** — creates an intermediate `librating` table (`rt_id`
   auto-inc, `bookid`, `rating` CHAR(1)) and fills it with
   `INSERT IGNORE … SELECT 0, BookId, ROUND(AVG(CONVERT(Rate, UNSIGNED)))
   FROM librate GROUP BY bookid` — i.e. **one row per bookid**, the
   rounded mean of all user ratings.
2. **Step 02** — creates `mlrating` (same shape, MyISAM
   `ROW_FORMAT=FIXED`, indexes on `bookid` and `rating`) and copies
   `librating` into it.

`librate` is per-**user**; `mlrating` is per-**book**. The cleanup stage
drops `librate`, so `mlrating` is the only rating source that survives.
The personal-library populate tool copies the books' rows straight from
`flibusta.mlrating` — identical semantics without re-aggregation.

### 6.4 MultiLib_Utilities tools

All tools share the same connection contract ([8.1](#81-connection-contract))
and MariaDB lifecycle (`lib/mariadb_lifecycle.sh`), and none of them
writes `flibusta`:

| Tool | Database reads | Writes | Purpose |
|---|---|---|---|
| `bin/export_authors_from_db.sh` | `mlauthorname` (via `data/sql/qry_*.sql`) | none | Regenerate the author-list fixture from the catalog |
| `bin/reconcile_library.sh` | `mlauthorname` snapshot | none | Collection progress: disk `Books` folders vs recommended-author list |
| `bin/estimate_download_size.sh` | `mlbook.filesize` per author | none | Size the next to-collect round |
| `bin/backup_myprivatelib.sh` | — | mysqldump of `myprivatelib` | Safety net: backup / verify / restore / list |
| `bin/populate_myprivatelib.sh` | `flibusta.mlbook` (md5 map + catalog rows), `mlauthor`, `mlauthorname`, `mlgenre`, `mlgenrename`, `mlseq`, `mlseqname`, `mlrating`, `mlcustinfo` | `myprivatelib` managed tables (fresh keys) | Rebuild the personal library from the `Books` folder |

### 6.5 populate_myprivatelib.sh — the personal-library rebuild

**populate_myprivatelib.sh data flow** (v1.2.0):

```
Books folder ──walk──▶ hash each file (zip → decompressed FB2 md5;
                       loose .fb2 → file md5) + arcname + on-disk size
        │
flibusta.mlbook ──one bounded read──▶ (md5, bookid) map (869k rows,
        │                             dedup: lowest bookid kept)
        │
resolve: file md5 → bookid (2148/2156 = 99.6% on the real collection)
        │
flibusta (chunked reads, POP_CHUNK=500) ──▶ one SQL script, one session:
        │     ALTER PK columns  (strip AUTO_INCREMENT — schema-driven,
        │                           all 16 PK columns, rows untouched)
        │     TRUNCATE the 9 managed tables
        │     INSERT mlauthorname  (explicit @aid_* per author; our books only)
        │     INSERT mlgenrename   (explicit @gid_*; used genres + their
        │                           ancestor category rows pulled from the
        │                           catalog, parent remap, parents first)
        │     INSERT mlseqname     (explicit @sid_* per series)
        │     INSERT mlbook        (explicit @bid_*; catalog filename,
        │                           on-disk arcname/filesize, ext='fb2')
        │     INSERT mlauthor / mlgenre / mlseq     (reference captured vars)
        │     INSERT mlrating / mlcustinfo          (reference captured vars)
        ▼
myprivatelib rebuilt — only books on disk; flibusta never written
```

Key behaviours worth knowing:

* **Column-parity gate** — before any `TRUNCATE`, the tool compares all
  nine managed tables' columns between `flibusta` and `myprivatelib` and
  aborts on mismatch (a partial rebuild would leave dangling keys).
* **Genre tree** — each used genre's ancestor rows are fetched
  iteratively (bounded, with a tried-set so a dangling parent is not
  re-fetched forever) and inserted parent-first so `@gid_*` exists when
  a child references it; a parent absent from the catalog degrades to
  `NULL`.
* **`mlbook.filename` = the catalog value** (`flibusta.mlbook.filename`,
  transliterated or numeric — see [7.2](#72-filename--arcname-are-not-the-on-disk-path));
  `arcname` and `filesize` come from the on-disk walk (`arcname` is the
  zip member name, `'-'` for loose `.fb2`); `ext` is forced to `'fb2'`;
  every other column is copied verbatim from the catalog row
  (`library` is set to the literal `'myprivatelib'`).
* **Row-by-row SQL, one session** — `SET NAMES utf8;
  SET FOREIGN_KEY_CHECKS=0; ALTER …MODIFY… (strip AUTO_INCREMENT);
  TRUNCATE …; INSERT …; SET @x=<explicit id>; …` — the whole rebuild
  streams through a single `mysql` invocation (≈19k SQL lines for 2,138
  books), so the captured variables stay alive for the run.
* **md5 duplicates** — a file that resolves to a bookid already
  inserted is skipped (duplicate copies of the same book on disk);
  catalog md5 collisions keep the lowest bookid.
* **Dry run** (`-n`) walks + resolves + prints what *would* happen but
  writes nothing; the live report TSV
  (`populate_myprivatelib_<ts>.tsv`) records per-file `source_file`,
  `md5`, `bookid`, `status`.
* **Lifecycle** — starts MariaDB if down, shuts it down again on exit
  only if it started it (§7.6). `--force`-style re-runs are safe by
  construction (clean rebuild) but the project convention is to take a
  `backup_myprivatelib.sh` snapshot first (§8.2).

### 6.6 Data flow end to end

```
Flibusta tracker torrents
   │  (booktracker-import.sh)
   ▼
torrents/ → (booktracker-extract.sh, aria2c) → mysql_feeds/*.sql
   │  (booktracker-ingest.sh, 6 stages)
   ▼
flibusta (17 ml* tables: 869k books, 1.07M author links, 361k ratings…)
   │
   ├── export_authors_from_db.sh ──▶ author list fixture (5707 / 13396 names)
   ├── estimate_download_size.sh ──▶ to-collect round sizing
   │
   └── populate_myprivatelib.sh (md5 match against mlbook.md5)
         │
         ▼
myprivatelib (the personal library the MultiLib app opens)
   │
   └── reconcile_library.sh ──▶ collection-progress report vs the Books folder
```

---

## 7. Key findings and implementation details

### 7.1 md5 matching: the strongest lookup tier

* `mlbook.md5` is **100% populated** — 869,130 / 869,130 rows, and the
  column **has a non-unique index**.
* For FB2 books it hashes the **book content**: `zcat file.zip |
  md5sum` equals `unzip -p file.zip | md5sum`, and both resolve to
  exactly one bookid; a loose `.fb2` file's plain md5 also resolves.
* The populate tool still pulls the whole `(md5, bookid)` map once and
  joins locally — one query instead of 2,156 per-file lookups, and it
  reveals duplicate md5s (same book stored twice in the catalog).
* Result on the real collection: **2,148 / 2,156 files (99.6%)**
  resolved exactly — vs 96.2% for the previous author/series/title
  ladder. The 8 unmatched files were content-level mismatches (7
  Bушков «Пиранья» volumes + 1 Bulychev — a different edition/
  normalization in the catalog).

### 7.2 filename / arcname are not the on-disk path

This was the v1.1.1 correction after the user's app re-test:

* **`mlbook.filename` is the catalog's own value** — the transliterated
  librusec-style name *when one exists*, and — for **~71% of catalog
  rows (615,216 of 869,130)** — a **plain numeric bookid** (the
  loader's fallback when no transliteration exists). It is never the
  on-disk path.
* **`mlbook.arcname` is 0% populated in the catalog** (all 869,130
  empty) — you cannot match on-disk archive names against it.
* The on-disk filenames in the monthly archives are
  `series-number + title` (e.g. `01-Первое дело.zip`, `0Мироходец.zip`).
* `libfilename` / `libfilenameold` (the source tables) are the
  transliteration lookups — separate side tables, not part of `mlbook`
  once converted.
* **In `myprivatelib`** the tool writes: `filename` = the **catalog
  value** (so the app shows what it expects), `arcname` = the **on-disk
  zip member name** (the bytes stored verbatim — for older archives
  these member names are double-encoded, and storing them faithfully is
  correct: "fixing" them would break member lookup), `'-'` for the 11
  loose `.fb2` files, and `filesize` = on-disk bytes. `flibusta.mlbook`
  offers no better arcname to copy — it has none.

### 7.3 Covers and descriptions are empty

`mlcoverpage` and `mldescription` are both empty (0 rows) in the loaded
`flibusta` — covers/descriptions require the separate **extended-data
torrents**, which the pipeline does not load. Real enrichment in the
loaded catalog: ratings (361,761), series (80,744 names), genres (296
rows), `mlcustinfo` (163,161). Loading the extended torrents and
re-running the ingest + populate would populate them automatically.

### 7.4 Duplicate md5s and multi-author books

* **Duplicate md5s:** the catalog can hold the same book content under
  several bookids. The populate tool keeps the **lowest** bookid and
  counts the collisions.
* **Multi-author books:** `mlauthor` holds one row per (book, author) —
  every sampled book had exactly 2 authors. Author counts therefore
  exceed book counts (1,073,467 links for 869,130 books).

### 7.5 Charset: pinning the client

The Windows server may transcode to its own default charset (cp1251) if
the client does not pin it. Every tool sends
`--default-character-set=utf8 --init-command="SET NAMES utf8"` so the
Cyrillic payloads round-trip as UTF-8. Raw reads use
`-B --skip-column-names --raw`; `mysql -B` renders SQL `NULL` as the
literal text `NULL` (the populate generator relies on this to pass
nulls through its SQL emitters).

### 7.6 WSL2 ↔ Windows MariaDB lifecycle

* Server: `C:\mariadb-10.4.7-winx64\bin\mysqld.exe --console`, started
  elevated via PowerShell `Start-Process … -Verb RunAs` (no UAC prompt
  when WSL2 runs elevated; otherwise a console pops up once).
* **WSL2 networking quirk:** a `mysql` connect to `127.0.0.1:3306` can
  block indefinitely instead of failing fast — every probe/connect is
  bounded with `--connect-timeout` (and `timeout` for tools whose
  clients don't accept that flag, e.g. `mysqldump` in 10.4).
* The shared `lib/mariadb_lifecycle.sh` provides
  `mariadb_maybe_start` / `mariadb_stop_if_started`: a server that was
  already running is left untouched; one the tool started is shut down
  gracefully on exit (`SHUTDOWN`, then `taskkill /F` fallback after
  `MARIA_STOP_TIMEOUT`).
* After several start/stop cycles the `--console` instance can keep
  running but stop answering (the user's "minimized window, still
  working" quirk); fix is `taskkill /F /IM mysqld.exe` and a fresh
  start, possibly with `MARIA_START_TIMEOUT=120` for MyISAM recovery.
* `mysqld.exe` may keep running after a tool exits — always check
  `tasklist.exe | grep -i mysqld` before assuming the server is down.

### 7.7 The mysql_upgrade incident

After the first dump load, the server logged:
`Column count of mysql.proc is wrong. Expected 21, found 20. Created
with MariaDB 50150, now running 100407` — the portable data directory
predated the 10.4 server. `mysql_upgrade --force` (an ingest `--upgrade`
mode) repaired it (all `mysql.*` and `flibusta.*` tables checked OK,
`FLUSH PRIVILEGES` completed). Lesson: the WSL2 `mysql` client is
**8.0.46** while the server is **10.4.7**; the version-skew only shows
up in tooling that relies on server internals, not in the plain SQL the
tools run.

### 7.8 MyISAM crash and recovery

* After an unclean shutdown MyISAM tables are marked crashed
  (`'.\flibusta\mlauthor' is marked as crashed and should be repaired`)
  — the server auto-checks them; `mysql_upgrade`/`REPAIR TABLE` clears
  the flags.
* `myprivatelib.mlcustinfo.frm` was once corrupt (error 1033 on LOCK
  TABLES); repaired by recreating the empty table from the valid schema:
  `CREATE TABLE myprivatelib.mlcustinfo LIKE flibusta.mlcustinfo`.
  The backup tool now makes such repairs safe.

### 7.9 Re-test status after v1.1.1 (open issues)

The v1.1.1 rebuild (2026-09-04) fixed the two reported app-side
problems — genre relationships (tree restored, §4.2) and the filename
contract (§7.2). The user re-tested MultiLib.exe against the rebuilt
`myprivatelib`: **"things are getting better but there are still some
problems"** that are deferred. Known-at-this-writing observations worth
carrying into that work:

* `mlbook.filename` is numeric (a bare bookid) for **93% of the
  personal library** (1,987 of 2,138 rows) because that is what the
  catalog itself stores for those books — the app will display numbers
  unless the numeric case is handled.
* `arcname` member names in older archives carry double-encoded bytes;
  stored verbatim they are correct for lookup but will look odd in any
  UI that renders them.
* `mlactual`, `mldownloaddata`, `mlnews*`, `mluser*` are all empty in
  `myprivatelib` — opening/downloading books from inside the app will
  populate them and is the natural next end-to-end probe.

---

## 8. Connection contract and invariants

### 8.1 Connection contract

The exact client invocation every tool builds (password only via
`MYSQL_PWD`, never on the command line):

```
mysql -h 127.0.0.1 --protocol=TCP -P 3306 -u root \
      --default-character-set=utf8 \
      --init-command="SET NAMES utf8" \
      --connect-timeout=<10> \
      -B --skip-column-names --raw   # for reads
```

Env contract: `MYSQL_CLIENT`, `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`,
`MYSQL_PASSWORD` (→ `MYSQL_PWD`), `MYSQL_EXTRA_ARGS`,
`MYSQL_CONNECT_TIMEOUT`, `MARIA_*` (lifecycle: `MARIA_EXE`,
`MARIA_BIN_DIR`, `MARIA_START_TIMEOUT`, `MARIA_READY_TIMEOUT`,
`MARIA_STOP_TIMEOUT`).

### 8.2 Invariants

1. **`flibusta` and `mllbr_main` are never written** by MultiLib_Utilities.
2. The tools manage **only** the nine catalog tables they populate in
   `myprivatelib`; app-owned tables (`mlactual`, `mldownloaddata`,
   `mlnews*`, `mluser*`) are never touched.
3. Population is a **clean rebuild**: managed tables are
   `TRUNCATE`-and-reloaded per run — idempotent by construction.
4. **Keys are regenerated** per run in `myprivatelib`; flibusta ids are
   used only as the lookup source during the walk.
5. A column-parity mismatch on **any** managed table aborts the run
   before any `TRUNCATE` (all-or-nothing — a partial rebuild would leave
   dangling key references).
6. Every tool writes a per-run TSV report to its report dir
   (`/mnt/c/Backup_Go7/merge-reports/` by default).
7. Take a `backup_myprivatelib.sh` backup before re-populating a
   non-empty `myprivatelib` (restore is safe: it backs up first and
   refuses non-empty overwrites without `--force`).

---

## 9. Appendix: snapshots and reference data

### 9.1 flibusta row counts + AUTO_INCREMENT watermarks

Taken 2026-09-04 from `information_schema.TABLES` (MyISAM `TABLE_ROWS`
is engine-accurate; `AUTO_INCREMENT` shows the next id, which runs far
ahead of row counts because catalog ids are sparse).

| Table | Rows | AUTO_INCREMENT next |
|---|---|---|
| mlbook | 869,130 | 887,686 |
| mlauthor | 1,073,467 | 1,085,474 |
| mlgenre | 1,374,515 | 1,374,516 |
| mlseq | 446,629 | 446,630 |
| mlrating | 361,761 | 361,762 |
| mlcustinfo | 163,161 | 163,162 |
| mlauthorname | 216,491 | 344,676 |
| mlseqname | 80,744 | 112,843 |
| mlgenrename | 296 | 1,000,025 |
| mlcoverpage / mldescription / mlactual / mldownloaddata / mlnews / mlnewsname / mluserkeyword / mluserprim | 0 | 1 (or n/a for `mlactual`, which has no auto PK) |

### 9.2 myprivatelib row counts (v1.1.1 rebuild)

Personal library after the 2026-09-04 v1.1.1 rebuild (2,156 files →
2,148 matched → 2,138 bookids). Fresh contiguous keys: every
`AUTO_INCREMENT` watermark = rows + 1.

| Table | Rows | AUTO_INCREMENT next |
|---|---|---|
| mlbook | 2,138 | 2,139 |
| mlauthor | 2,798 | 2,799 |
| mlgenre | 5,468 | 5,469 |
| mlseq | 2,619 | 2,620 |
| mlrating | 1,948 | 1,949 |
| mlcustinfo | 757 | 758 |
| mlauthorname | 187 | 188 |
| mlseqname | 422 | 423 |
| mlgenrename | 84 (= 14 roots + 70 leaves) | 85 |
| mlcoverpage / mldescription / mlactual / mldownloaddata / mlnews / mlnewsname / mluserkeyword / mluserprim | 0 | 1 |

Only our books' entities are present — no exact-copy bloat. Contrast
with the v1.0.0 state (216,491 authors, 80,744 series, 296 genres
copied wholesale) that broke the app.

### 9.3 mlrating distribution (both DBs)

**flibusta** (361,761 rated books):

| rating | books |
|---|---|
| 1 | 67,067 |
| 2 | 57,001 |
| 3 | 79,368 |
| 4 | 82,584 |
| 5 | 75,741 |
| **total** | **361,761** |

**myprivatelib** (1,948 of 2,138 books have a rating):

| rating | books |
|---|---|
| 1 | 30 |
| 2 | 278 |
| 3 | 874 |
| 4 | 534 |
| 5 | 232 |
| **total** | **1,948** |

### 9.4 mlbook column reference and value census

Full `mlbook` census (flibusta, 2026-09-04):

* **`library`:** single-valued per DB — `'flibusta'` (869,130) /
  `'myprivatelib'` (2,138).
* **`ext`:** mostly `fb2` (728,881) but the catalog holds ~200 more
  legacy values — top: `pdf` 58,117, `djvu` 31,468, `epub` 30,436,
  `doc` 9,013, `docx` 2,799, `txt` 2,772, `rtf` 2,186 … down to
  one-row oddities (`???`, `-бер`, `вщс`). `myprivatelib`: `fb2` only.
* **`deleted`:** `'0'` 711,738 / `'1'` 157,392 in `flibusta`; all
  `'0'` in `myprivatelib`.
* **`md5`:** populated on **all** rows in both DBs.
* **`filename`:** 615,216 numeric (a bare bookid) + 253,914
  transliterated in `flibusta`; 1,987 numeric + 151 transliterated in
  `myprivatelib` (the numeric fraction is higher for the personal
  collection because of which books were collected).
* **`arcname`:** 0 populated in `flibusta`; 2,127 member names + 11
  `'-'` (loose `.fb2`) in `myprivatelib`.

### 9.5 mllbr_main schema

| Table | Columns |
|---|---|
| `mldownload` | `dl_id` PK auto, `bookid`, `library`, `title`, `FullName`, `seqname`, `genrenamerus`, `filesize`, `lang`, `ext`, `dl_position`, `dl_done`, `dl_date`, `dl_msg` |
| `mlgenrelist` | `genrecode` PK, `genregroup`, `genrenamerus` — flat genre dictionary (109 rows) |
| `mlgroup` | `uc_id` PK auto, `bookid`, `groupid`, `library`, `date_gr` |
| `mlgroupname` | `groupid` PK auto, `groupidparrent` (self-ref), `groupname` (3 rows) |

### 9.6 Quick-reference queries

All four queries below are also shipped as the self-contained, runnable
script `data/sql/qry_catalog_reference.sql` (queries B/C read `@title` /
`@md5` session variables; run against `flibusta` by default,
`myprivatelib` by pointing `MYSQL_DATABASE` at it).

```sql
-- A. Genre tree roots and their child counts (catalog)
SELECT gn.genreid, gn.genrenamerus,
       (SELECT COUNT(*) FROM mlgenrename ch
         WHERE ch.parentgenreid = gn.genreid) AS children
FROM mlgenrename gn
WHERE gn.parentgenreid IS NULL
ORDER BY children DESC;

-- B. Everything about one book (title + authors + genres + series + rating)
SET @title = '<title>';          -- in qry_catalog_reference.sql
SELECT b.bookid, b.title, b.filename, b.arcname, b.filesize, b.deleted,
       an.FullName, gn.genrenamerus, sn.seqname, s.seqnum, r.rating
FROM mlbook b
LEFT JOIN mlauthor a      ON a.bookid = b.bookid
LEFT JOIN mlauthorname an ON an.authorid = a.authorid
LEFT JOIN mlgenre g       ON g.bookid = b.bookid
LEFT JOIN mlgenrename gn  ON gn.genreid = g.genreid
LEFT JOIN mlseq s         ON s.bookid = b.bookid
LEFT JOIN mlseqname sn    ON sn.seqid = s.seqid
LEFT JOIN mlrating r      ON r.bookid = b.bookid
WHERE b.title = @title;

-- C. md5 lookup (the populate matcher)
SET @md5 = '<md5>';              -- in qry_catalog_reference.sql
SELECT bookid, title, filename, ext, deleted
FROM mlbook WHERE md5 = @md5;

-- D. Column parity of one managed table between the two DBs
SET @tbl = 'mlbook';             -- in qry_catalog_reference.sql
SELECT TABLE_SCHEMA AS db, GROUP_CONCAT(COLUMN_NAME ORDER BY ORDINAL_POSITION)
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA IN ('flibusta','myprivatelib') AND TABLE_NAME = @tbl
GROUP BY TABLE_SCHEMA;
```

---

*End of reference. Keep this document in sync with the tools and the
live schema — the populate tool's parity check re-verifies the nine
managed tables' columns on every run, and `SHOW INDEX` +
`information_schema.TABLES` are the fastest way to re-check the numbers
above.*
