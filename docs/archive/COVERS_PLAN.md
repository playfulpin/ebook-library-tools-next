# Covers & Annotations Workstream — Phase 2 investigation plan

> Created: 2026-09-06
> Status: **investigation** — no code written yet; this document frames the
> problem, the data sources, and the decision points before implementation.
> Related: `docs/REPRESENTATION_PLAN.md` (Phase 2), `docs/MultiLib_Flibusta_DB.md`
> §5 (table reference), BookTracker-import (dump pipeline).

---

## 1. Problem statement

`myprivatelib` works end-to-end in MultiLib.exe (v1.3.0 verbatim keys),
but the app shows **no covers and no annotations**: `mlcoverpage` and
`mldescription` are empty in the target, and they are empty in `flibusta`
too — the standard dump pipeline (BookTracker-import `lib.libbook.sql.gz`
etc.) does not carry covers or descriptions.

What the app needs (from the app's own DDL, `createtable.sql`):

| Table           | Columns                        | Notes |
|---|---|---|
| `mldescription` | `ds_id` PK, `bookid`, `descr VARCHAR(20000)` | book annotation text |
| `mlcoverpage`   | `cp_id` PK, `bookid`, `cover MEDIUMBLOB`     | image bytes |

Both tables are **app-owned** (populate never fills them today), so the
covers workstream adds a *new* data source and extends the pipeline with
a *bounded*, per-book enrichment step — it must NOT regress the v1.3.0
verbatim-key contract.

---

## 2. Candidate data sources (to verify, in order)

1. **FB2 content itself (preferred — zero new downloads).**
   A `.fb2` file carries `<description><title-info><annotation>` and
   often `<coverpage><image l:href="#cover.jpg">` with the binary in
   `<binary id="cover.jpg" content-type="image/jpeg">`.
   - For our 2,146 zip-wrapped books the bytes are already on disk —
     extraction is local CPU only.
   - Covers are per-book, so matching is trivial: the same md5-resolved
     `bookid` populate already computed.
   - Open questions to spike:
     a. does MultiLib render covers from `mlcoverpage` even when the FB2
        itself carries them (i.e. is the DB the only source the app uses)?
     b. annotation length distribution vs the `VARCHAR(20000)` bound —
        how many need truncation?
     c. ZIP files containing multiple `.fb2` members (cover from the
        first / largest member? populate already pins `arcname` to one
        member).
2. **Flibusta extended-data torrents (fallback / completeness).**
   The tracker publishes supplementary packages (covers, annotations,
   authors' photos) as separate torrents.  If spike (1) proves
   insufficient, add them to BookTracker-import as new import targets
   (same forum/topic machinery as the dump) landing in
   `/Downloads/flibusta_snapshot/`, then load them into `flibusta` as
   extra tables — and only then extend populate to copy from source to
   target.  This is the heavier path: new import targets + ingest stages
   + much bigger disk footprint.
3. **Manual enrichment** — not planned; personal-catalog scale (2k books)
   makes per-book hand work pointless.

---

## 3. Proposed pipeline design (after the spike decides the source)

**Phase A — extract (local, source of truth = the book files):**
`bin/extract_book_metadata.sh` walks `POP_LIBRARY_ROOT`, and for every
zip-wrapped/loose FB2 emits into a work dir:

- `descriptions.tsv` — `bookid \t annotation` (annotation = FB2
  `<annotation>` text, XML-stripped, CRLF-normalized, truncated at
  20000 bytes with a marker)
- `covers/<bookid>.jpg|png` — the cover binary from the FB2 `<binary>`
  (id resolved from `<coverpage><image l:href="#...">`)

**Phase B — load:**
`bin/populate_myprivatelib.sh --with-richness` (new flag, default off):

- `mlrating`-style gated insert: only books that HAVE an annotation/cover
  get rows;
- `ds_id` / `cp_id` handling per the v1.3.0 contract — these are
  tool-owned child tables whose PKs were stripped like every other
  (they are in the `PK_COLUMNS` strip list already); assign **source-
  derived** keys where a source exists, else sequential in bookid order —
  decision to be finalized after the spike (the flibusta side has no
  rows to copy keys from, which is the one case where "verbatim" cannot
  apply);
- idempotent, purge-and-reload for the two tables only (never touches
  the 9 managed tables);
- FK gate extended to 11 paths (descriptions→mlbook, covers→mlbook).

**Phase C — verification:**
extend the acceptance checks: counts vs files-with-annotation / files-
with-cover, spot-render one book in MultiLib.exe.

---

## 4. Decision points (need user input / spike results)

1. Source: FB2-embedded only (fast, complete for our shelf) vs extended
   torrents too (heavier, also fixes the 8 unmatched files' metadata).
2. Cover storage: raw bytes in `mlcoverpage` (app-native) — yes, per DDL.
3. Truncation policy for long annotations (hard cut vs skip).
4. Whether extraction runs inside refresh (auto) or as a separate manual
   step (explicit).

---

## 5. Next concrete step

A one-book spike: extract `annotation` + cover from a single known zip
(`А/Автор One/...`), insert into `myprivatelib` by hand, open the book in
MultiLib.exe, and confirm the app renders both.  That validates the DB
path before any tooling is written (same pattern as the Phase 0.2/0.4
spikes that de-risked populate).
