# DO_IT_ongoing — consolidated assignment log

> Created: 2026-09-07 04:10 CDT — final consolidation of the completed
> DO_IT assignment series.  Every part carries its original timestamp
> (from the filename; for the undated original, the commit that
> implemented it) plus a resolution note.  The individual files
> (`DO_IT.md`, `DO_IT_20260906_141511.md`, `DO_IT_20260906_172550.md`,
> `DO_IT_20260906_201455.md`) were folded into this document and
> removed from the working tree; their full text remains in git
> history (provenance commit noted per part).

---

## Part 1 — [2026-09-06, undated original] Strip AUTO_INCREMENT, rename privetelib -> myprivatelib

> Source: `docs/DO_IT.md` (original preserved at git history of
> `6cb03b7` and earlier).  Implemented in commit `d2652e4`
> (populate v1.2.0, 2026-09-06).

The MultiLib application still does not accept or work correctly with our uploaded schema `privetelib`.

I believe I have found the source of the problem.

For some reason, our generated schema is still modifying or interfering with the predefined relationships between tables. In particular, it appears that the `AUTO_INCREMENT` attribute on certain primary-key columns may be causing MultiLib to treat these columns differently from the original database schema.

As a workaround, I want to remove the `AUTO_INCREMENT` attribute from the corresponding columns in the `CREATE TABLE` statements for **ALL TABLES**.

For example, the original table definition is:

```sql
CREATE TABLE `mlbook` (
  `bookid` INT(11) NOT NULL AUTO_INCREMENT,
  `library` VARCHAR(64) NOT NULL DEFAULT '' COLLATE 'utf8_general_ci',
  `title` VARCHAR(255) NOT NULL DEFAULT '' COLLATE 'utf8_general_ci',
  ...
```

Our generated code currently produces:

```sql
CREATE TABLE `mlbook` (
  `bookid` INT(11) NOT NULL,
  `library` VARCHAR(64) NOT NULL DEFAULT '' COLLATE 'utf8_general_ci',
  `title` VARCHAR(255) NOT NULL DEFAULT '' COLLATE 'utf8_general_ci',
  ...
```

In other words, the only change required here is to **omit `AUTO_INCREMENT`** from the column definition. Everything else in the column definition should remain unchanged.

This change must be applied consistently to the following table/column combinations:

```text
+----------------+-------------+
| TABLE_NAME     | COLUMN_NAME |
+----------------+-------------+
| mlauthor       | la_id       |
| mlauthorname   | authorid    |
| mlbook         | bookid      |
| mlcoverpage    | cp_id       |
| mlcustinfo     | ci_id       |
| mldescription  | ds_id       |
| mldownloaddata | dd_id       |
| mlgenre        | gn_id       |
| mlgenrename    | genreid     |
| mlnews         | cb_id       |
| mlnewsname     | critid      |
| mlrating       | rt_id       |
| mlseq          | sq_id       |
| mlseqname      | seqid       |
| mluserkeyword  | kw_id       |
| mluserprim     | up_id       |
+----------------+-------------+
```

Please make sure that:

1. `AUTO_INCREMENT` is removed from these specified columns in the generated `CREATE TABLE` statements.
2. No other column attributes are changed as part of this modification.
3. The existing primary keys and other predefined relationships remain intact.
4. The change is applied consistently to **all** affected tables, rather than only to `mlbook`.
5. Any code, SQL-generation logic, configuration, examples, tests, or other project files that depend on the old behavior are updated accordingly.

### Schema name change

I also want to rename the schema throughout the project.

Change: `privetelib` to `myprivatelib`.

This is a global schema-name change. Please propagate it throughout **all corresponding project documentation and related files**, including SQL examples, configuration files, README/documentation, scripts, comments, test data, and any other places where the old schema name is referenced.

The final result should consistently use `myprivatelib` everywhere and should not leave stale references to `privetelib` behind.

**Resolution (2026-09-06, `d2652e4`):** implemented as populate v1.2.0 —
schema-driven `ALTER TABLE ... MODIFY` re-declares all 16 PK columns
verbatim minus `AUTO_INCREMENT` (idempotent, verified via
`information_schema.COLUMNS.EXTRA`); global rename to `myprivatelib`
across tools/configs/suites/docs.  Same day, Part 2 superseded the
synthetic-key half of v1.2.0 while RETAINING the strip (a verbatim
source key needs a plain PK column — the strip is exactly what makes
it loadable).

---

## Part 2 — [2026-09-06 14:15] Data pipeline bug fix: verbatim source keys

> Source: `docs/DO_IT_20260906_141511.md` (original preserved in git
> history).  Implemented in commit `47f8ddc` (populate v1.3.0);
> live rebuild verified 2026-09-06 14:56; released as v1.3.0.

# Data Pipeline Bug Fix: Update `myprivatelib` Data Population Logic

## Overview
The current data implementation in the `myprivatelib` schema is incorrect due to artificial key generation. The pipeline logic needs to be updated to correctly populate records from `flibusta` based on uncompressed file checksums.

## Problem Description
- **Incorrect Key Generation:** Synthetic/dynamic keys are currently being generated during data insertion, which violates schema requirements.
- **Data Integrity Issue:** Existing data populated in `myprivatelib` is invalid and must be wiped and re-ingested.

## Technical Requirements
1. **Schema Mapping:** All data in `myprivatelib` must be populated directly from the `flibusta` source schema.
2. **Matching Logic:** Join/map records strictly using the **`md5` checksum** of the uncompressed actual file.
3. **Key Constraints:** **Do NOT generate any synthetic keys.** Preserve or map keys strictly per source definition.

## Acceptance Criteria & Tasks
- [x] **Logic Adjustment:** Update data pipeline / ingestion script to map `flibusta` → `myprivatelib` via uncompressed file `md5`.
- [x] **Documentation Update:** Revise data pipeline documentation and schema mapping spec to reflect this logic.
- [x] **Data Cleanup & Reload:** Purge existing invalid data in `myprivatelib` and re-upload the correct dataset.

## Verification Steps
1. [x] Verify that target table key counts match the distinct `md5` count in source `flibusta`. — **2,138 = 2,138; bookids 9461..882939, every key present in flibusta.**
2. [x] Ensure no generated/autoincrement keys are introduced during migration. — **0 AUTO_INCREMENT columns; no counters, no `@var` remaps, no `LAST_INSERT_ID()`.**
3. [x] Confirm documentation accurately reflects the updated ETL/ELT process. — **README / CHANGELOG / RELEASE_NOTES / MultiLib_Flibusta_DB.md / REPRESENTATION_PLAN.md rewritten to the verbatim-key contract.**

**Resolution (2026-09-06, `47f8ddc`):** every managed INSERT carries the
flibusta source key verbatim (md5-resolved `bookid`, source
`authorid`/`genreid`/`seqid`, child PKs from the source rows); new
post-reload FK integrity gate (9 reference paths, abort on orphans);
purge-and-reload unchanged; mock suite grown to 35.  End-to-end
confirmed by the user: MultiLib.exe operates `myprivatelib` at full
scale with source-verbatim keys.

---

## Part 3 — [2026-09-06 17:25] Status update & user reporting proposal

> Source: `docs/DO_IT_20260906_172550.md` (original preserved in git
> history).  Outcome spread over `708d963` (wish list v1.0.0),
> `612b5e2` (native views v1.1.0), `d648a67` (hybrid v1.2.0).

# Status Update & Next Steps: `myprivatelib` Covers Resolution & User Reporting Proposal

## Status Update: `COVERS_PLAN.md`
- **Resolution:** The latest script run (`bin/refresh_myprivatelib.sh`, Version 1.0.0, updated 2026-09-06 22:00) resolved the issue.
- **Verification:** `myprivatelib` now works end-to-end within `MultiLib.exe`. Both covers and annotations display correctly in the application.
- **Action Item:** `COVERS_PLAN.md` can be safely scrubbed/archived. No further work or schema changes are needed for cover and annotation integration.

## Proposal: User Reporting Feature Set

* **By Title:** A flat, searchable list of saved book titles sorted alphabetically or by date added.
* **By Author:** Grouped reporting displaying target authors alongside their available titles in `myprivatelib`.
* **By Series:** Sequential listing showing series titles ordered by volume/position number, highlighting missing entries.

### 2. Implementation Approach
* **Data Sources:** Query existing metadata mappings directly from `myprivatelib` without modifying the core schema.
* **Export Formats:** Support quick UI filtering within `MultiLib.exe` alongside optional exports (e.g., Markdown, CSV, or printable text).

### 3. Next Steps & Questions
1. Should these reports be built directly into the `MultiLib.exe` UI or generated via standalone CLI/SQL scripts first?
2. Are there specific sorting or filtering criteria (e.g., read vs. unread status, genre tags) you would like included in the initial release?

**Resolution (2026-09-06/07):**

- **Covers finding re-attributed** (review note): MultiLib.exe renders
  covers and annotations from the FB2 payload itself
  (`BookLocation` + `arcname` -> zip -> `<annotation>`/cover image);
  no DB rows were needed.  What made the app work was the v1.3.0
  verbatim-key populate.  `docs/COVERS_PLAN.md` is superseded (see the
  section 3.5 note in the DB reference) - closed, do not re-plan.
- **Wish lists shipped** as `bin/report_library.sh`: v1.0.0 TSV reading
  plan (`708d963`, release v1.4.0) -> v1.1.0 native views (`612b5e2`,
  release v1.5.0) -> v1.2.0 hybrid merge (`d648a67`, release v1.6.0).
- **Q1 answered:** CLI/SQL first (MultiLib.exe is closed-source);
  `data/sql/qry_wishlist_native.sql` ships the runnable queries.
- **Q2 answered:** read/unread = native «Прочитано» group (no
  `di_history` probe needed); "date added" = native `mlgroup.date_gr`
  for app-marked books, TSV `added` for file entries.

---

## Part 4 — [2026-09-06 20:14] Native wishlist integration discovery

> Source: `docs/DO_IT_20260906_201455.md` (original preserved in git
> history at `6cb03b7`; the file was truncated mid-section as written).
> Verified live 2026-09-07; implemented in `612b5e2` (v1.1.0) +
> `d648a67` (v1.2.0); released as v1.5.0 + v1.6.0.

# Requirements & Design Spec: MultiLib Native Wishlist Integration

## 1. Overview
Recent testing confirms that the native `MultiLib.exe` interface manages user reading lists
directly via the `mllbr_main` schema. Specifically,
assigning a title (e.g., *'Кто ты, Такидзиро Решетников? Том 2'*, `bookid=785309`)
to a wishlist category (e.g., *'К прочтению'*, `groupid=2`) populates the `mlgroup` and `mlgroupname` tables.

Since the native application handles group creation and book assignments seamlessly,
our reporting layer can directly query these underlying tables to deliver structured
SQL-based reporting on user wishlists.

## 2. Schema & Native Mapping Discovery

### Database Target
- **Schema:** `mllbr_main`
- **Key Tables:** `mlgroup`, `mlgroupname`

### Data Relationship Model
The native wishlist assignment creates the following entity relationship:
- `mlgroupname`: Stores group metadata (e.g., `groupid=2` -> `groupname='К прочтению'`).
- `mlgroup`: Stores book-to-group mappings (e.g., `bookid=785309` -> `groupid=2`).

## 3. Proposed Reporting Logic (SQL Integration)

### 3.1 Wishlist by Title
*(original truncated here; the intended query is reproduced below in
its corrected shape)*

```sql
SELECT gn.groupname AS wishlist, b.bookid, b.title AS book_title,
       an.fullname AS author, g.date_gr AS added
FROM mllbr_main.mlgroup g
JOIN mllbr_main.mlgroupname gn ON gn.groupid = g.groupid
JOIN myprivatelib.mlbook b     ON b.bookid  = g.bookid
LEFT JOIN myprivatelib.mlauthor a      ON a.bookid  = b.bookid
LEFT JOIN myprivatelib.mlauthorname an ON an.authorid = a.authorid
WHERE g.library = 'myprivatelib'
ORDER BY gn.groupid, b.title;
```

**Resolution (2026-09-07):** discovery verified against the live
server - `mllbr_main.mlgroupname` holds 3 built-in categories
(1 «Избранное», 2 «К прочтению», 3 «Прочитано»); `mllbr_main.mlgroup`
rows carry `bookid`, `groupid`, **`library`**, `date_gr`; the live row
`785309 -> groupid=2, library='myprivatelib'` matches the doc's
example.  **Two corrections applied** to the doc's SQL: the book data
lives in `myprivatelib.mlbook` (no `books` table), and every query MUST
filter `g.library` (the table serves all libraries).  Shipped as
`report_library.sh --native [title|author|series|all]` (read-only,
library-scoped) + the runnable `data/sql/qry_wishlist_native.sql`
(A-E); the `--hybrid` view merges the native state with the TSV plan
(native status wins, TSV keeps periods).

---

*End of consolidated log.  Future assignments: either extend this file
with a new timestamped part or start a fresh `DO_IT_<timestamp>.md` -
if the latter, fold it here when completed.*
