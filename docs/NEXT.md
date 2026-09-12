# NEXT — where to resume

> Updated: 2026-09-12 — **refactoring Phase 4 COMPLETE (all four
> groups)**: AUTHORS chain in `bin/authors/`, merge pair +
> estimate/reconcile in `bin/books/`, backup/populate/refresh + report
> in `bin/library/`, `bin/version_bump.sh` flat in `bin/`; all
> infra consumers converted onto `common_init`; progress log in
> `docs/PHASE_04_TOOL_CONVERSION.md` v1.2.0. Remaining: **final docs
> pass** — distill `ARCHITECTURE.md` from the ratified Phase 2 doc,
> sign off `docs/Measurable Phase Completion Criteria.md` for Phase 4,
> then cut a release tag. Phases 1–3 complete.

## Resume checklist

```bash
cd /home/mike/GIT_ROOT/MultiLib_Utilities
git status             # expect: clean tree, on main, up to date with origin/main
git log --oneline -3   # expect: d648a67 (hybrid view) at the top; tags v1.5.0 + v1.6.0 on 612b5e2 / d648a67
bash tests/test_version_sync.sh          # 14/14 (fast, mock-only)
bash tests/test_library_report.sh        # 71/71 (mock mysql, runs anywhere)
bash tests/test_library_refresh.sh       # 20/20
bash tests/test_library_populate.sh      # 35/35
```

### Reporting quickstart

```bash
./bin/library/library_report.sh --search piranha            # find bookids
./bin/library/library_report.sh --add 882939 --period 2026-09 --note "..."
./bin/library/library_report.sh                             # TSV plan view
./bin/library/library_report.sh --native                    # app wishlists (mllbr_main), by author
./bin/library/library_report.sh --native series             # app wishlists, series order
./bin/library/library_report.sh --hybrid                    # TSV plan x app state, one view
./bin/library/library_report.sh --set-status 882939 done
./bin/library/library_report.sh --export md                 # printable export
```

Wish state: `data/wishlist.tsv` (bookid, added, target_period, status,
note) + native `mllbr_main.mlgroup` rows (marked in-app).

## Current state (post v1.6.0)

| Piece | State |
|---|---|
| `myprivatelib` | live in MultiLib.exe, full-scale operation confirmed by the user; populate v1.3.0 (verbatim source keys, 0 AUTO_INCREMENT, FK gate) |
| `bin/refresh_myprivatelib.sh` v1.0.0 | shipped; tree-fingerprint checkpoint; first real run will write the checkpoint (`--status` shows `no-checkpoint`) |
| `bin/library/library_report.sh` v1.2.0 | shipped; TSV wish list (`data/wishlist.tsv`), view + mutations + exports; `--native title\|author\|series\|all` views over the app-managed `mllbr_main` wishlists (read-only, library-scoped; companion SQL `data/sql/qry_wishlist_native.sql`); `--hybrid` merges both sources (native status wins, TSV keeps periods, ★ favorites, source tags); suite 71/71 |
| Releases | v1.3.0 (`47f8ddc`, verbatim keys) + v1.4.0 (`708d963`, refresh + wish list) + v1.5.0 (`612b5e2`, native wishlist views) + v1.6.0 (`d648a67`, hybrid view) published on GitHub, v1.6.0 = Latest |
| CI | green on `d648a67` |
| Assignment history | `docs/archive/DO_IT_ongoing.md` (Parts 1-4, folded + resolved) |
| MariaDB | stopped (shut down gracefully 2026-09-07) |

## The discovery: native wishlist lives in `mllbr_main` (verified live 2026-09-07)

From the assignment doc (folded into `docs/archive/DO_IT_ongoing.md` Part 4)
plus a read-only probe against the live server. **MultiLib.exe manages
user reading lists natively** — no TSV,
no `mluserkeyword`, no `di_history` probing needed:

- `mllbr_main.mlgroupname` — group metadata, **3 built-in categories**:
  `1` «Избранное», `2` «К прочтению», `3` «Прочитано». Columns:
  `groupid` (AI PK), `groupidparrent` (nested groups are possible),
  `groupname` varchar(50).
- `mllbr_main.mlgroup` — book-to-group assignments. Columns: `uc_id` (AI PK),
  `bookid`, `groupid`, **`library` varchar(256)**, `date_gr` datetime.
- Live row: `bookid=785309, groupid=2, library='myprivatelib',
  date_gr=2026-09-06 18:20:01` — the user assigned it in-app.

What this settles, and the two corrections to the assignment doc's SQL:

1. **Read/unread is native**: «Прочитано» (groupid=3) membership is the
   read signal — the `mlcustinfo.di_history` probe from the old plan is
   unnecessary. «Избранное» gives favorites for free.
2. **`library` scoping**: every query MUST filter
   `g.library = 'myprivatelib'` — the table serves all libraries.
3. The doc's joins reference `myprivatelib.books` — no such table;
   the book data is `myprivatelib.mlbook` (joined to `mlauthor`/
   `mlauthorname`/`mlseq`/`mlseqname` for author/series views).
4. **`date_gr` is a real "added on" date** for wishlist entries — the
   TSV `added` column now has a native counterpart for app-marked books.
5. Scripts stay **read-only** on `mllbr_main` (the app owns it; marking
   happens in-app; populate/refresh never touch this schema).

Corrected reference query (By Title, verified shape):

```sql
SELECT gn.groupname AS wishlist, b.bookid, b.title AS book_title,
       an.fullname AS author, g.date_gr AS added
FROM mllbr_main.mlgroup g
JOIN mllbr_main.mlgroupname gn ON gn.groupid = g.groupid
JOIN myprivatelib.mlbook b   ON b.bookid  = g.bookid
LEFT JOIN myprivatelib.mlauthor a  ON a.bookid  = b.bookid
LEFT JOIN myprivatelib.mlauthorname an ON an.authorid = a.authorid
WHERE g.library = 'myprivatelib'
ORDER BY gn.groupid, b.title;
```

**Design question kept open for the user (v1.1 decision point):**
native groups vs `data/wishlist.tsv` — the native tables carry status
(wish/read/favorite) and the added date but have **no target-period
concept** («к прочтению до конца сентября» is not expressible in-app).
Proposal: **hybrid** — native groups = what/how-many (authoritative,
marked in-app), TSV = when planned (target_period, notes); the report
joins both by bookid.

## Next steps (priority order)

1. **By-Series gap report** (next reporting feature): series entries
   owned vs missing volumes via `mlseq.SeqNumb`, highlighting series
   with gaps and series on the wish list whose missing volumes should
   be collected next; feeds naturally from the hybrid view's data.
2. **App re-test leftovers** (`docs/MultiLib_Flibusta_DB.md` section 7.9):
   numeric `filename` display for ~93% of rows, verbatim mojibake
   `arcname`, empty app-owned tables (`mlactual`, `mldownloaddata`,
   `mlnews*`, `mluser*`) — resolve when the user re-tests and reports
   what still bothers them.
3. **Behavior probe, narrowed**: the app demonstrably writes
   `mllbr_main.mlgroup` (wishlist). One datadir diff while assigning a
   group + opening a book will settle what else it writes
   (`mlcustinfo`, `mldownloaddata`?) — informs which app-owned tables
   belong in future reports.
4. **Unmatched fallback (ladder b)**: author/series/title matching for
   the 8 unmatched files (7 Бушков «Пиранья» + 1 Булычев) — extend the
   populate resolve step or a small companion tool.
5. **Adopt the refresh loop**: after each BookTracker-import collecting
   round, `./bin/refresh_myprivatelib.sh` (backup -> populate ->
   checkpoint); check `--status` first. Consider a wrapper that also
   regenerates the reconcile statistics for the round.
6. **Docs pass**: add the `mllbr_main` wishlist findings (mlgroup /
   mlgroupname schema, library scoping, 3 built-in categories) to
   `docs/MultiLib_Flibusta_DB.md`; consider archiving
   `docs/archive/COVERS_PLAN.md` (superseded, see DO_IT_ongoing Part 3).
7. **Covers/annotations**: CLOSED — the app renders both from the FB2
   payload; `docs/archive/COVERS_PLAN.md` is superseded. Only revisit if
   DB-level thumbnail views are ever wanted.

## Environment quirks (carried forward — remember these)

1. **WSL2 mirrored-networking connect hangs**: always pass
   `--connect-timeout` to `mysql`; `mysqldump` (10.4) doesn't accept it
   — bound with `timeout` (`MYSQL_CALL_TIMEOUT`, default 90s).
2. **Wedged server after start/stop cycles**: `taskkill /F /IM mysqld.exe`,
   start fresh; after a force-kill pass `MARIA_START_TIMEOUT=120`.
3. Server lifecycle needs WSL2 **elevated** (no UAC prompt).
4. WSL2 mysql client 8.0.46 vs server 10.4.7 — fine for plain SQL.
5. Tool file-writes from the Git-Bash side can silently fail (observed
   twice: release-note temp files, docs/NEXT.md rewrite) — verify
   content landed, or write via WSL/heredoc.

## Open notes carried forward

- `mlbook.filename`/`arcname` are NOT flibusta archive names — don't
  plan matching around them; monthly-archive filenames normalize by
  stripping `^[0-9]+[ -]*` before comparing to `mlbook.title`.
- Raw dump sources stay at `data/archives/flibusta_gz/` (git-ignored,
  ~130 MB) for reference/re-loads.
- Full DB reference: `docs/MultiLib_Flibusta_DB.md` (rev 2); quick
  queries: `data/sql/qry_catalog_reference.sql`. Native-wishlist query
  bank: `data/sql/qry_wishlist_native.sql` (A-E, `@library` variable).
  Assignment history lives in `docs/archive/DO_IT_ongoing.md` — extend it with
  new timestamped parts rather than spawning new DO_IT* files.
- `data/wishlist.tsv` currently empty; TSV + native groups coexist per
  the hybrid model (`--hybrid`).
