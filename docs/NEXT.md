# NEXT — where to resume

> Updated: 2026-09-12 (late) — **test-hermeticity day.**  Three distinct
> session-poisoning mechanisms were hunted down and fixed (see quirk 6
> below): leaked exports, inherited stdin in the MariaDB readiness probe
> (lib 1.0.3), and a traced caller shell (`SHELLOPTS=xtrace`).  The full
> battery is green from every environment I can drive (agent WSL, Git
> Bash, poison variants).  **One open item:** `test_lib_infrastructure.sh`
> still FAILs in Mike's interactive terminal — resume there first (see
> "OPEN: infra suite in Mike's session").  Refactoring Phases 1–5 remain
> COMPLETE and signed off; remaining plan items are the D-02.11 tests
> split and optional phases 6–13.

## Resume checklist

```bash
cd /c/git_root/ebook-library-tools-next
git status             # expect: clean tree, on main, up to date with origin/main
git log --oneline -3   # expect: 582c3a6 docs / 5a8335b test guards / 0b2e7d5 infra hermetic
git pull               # HEAD is 582c3a6; tags v1.7.0 + v1.7.1 on main
bash tests/test_version_sync.sh          # 14/14 (fast, mock-only)
bash tests/test_library_report.sh        # 71/71 (mock mysql, runs anywhere)
shellcheck --severity=warning bin/*.sh bin/*/*.sh lib/*.sh && echo clean   # Phase 5 gate
for t in tests/test_*.sh; do bash "$t" >/dev/null 2>&1 && echo "ok   $t" || echo "FAIL $t"; done
```

### OPEN: infra suite in Mike's session (top priority next time)

`test_lib_infrastructure.sh` is the only suite still failing in Mike's
interactive terminal (as of 2026-09-12 EOD) while passing 42/42 in every
agent-side environment, including `SHELLOPTS=xtrace`/`verbose` poison runs.
Diagnostics live in Mike's session only — next session step 1 is capturing
the failing assertion, not guessing:

```bash
cd /mnt/c/git_root/ebook-library-tools-next
bash tests/test_lib_infrastructure.sh > /tmp/infra.log 2>&1; echo "exit=$?"
grep -B2 -A6 '^  FAIL' /tmp/infra.log          # the real failing assertion + stderr
env | sort > /tmp/infra_env.txt                 # attach both to the session
set +x; set +v; echo "trace flags now: $-"     # rule the known culprits out for good
```

With the `FAIL` block visible, the fix should be mechanical.  Candidate
mechanisms already covered: leaked exports (unset guards in place), stdin
inheritance (lib 1.0.3), traced caller (re-exec guard in all 16 suites).
What is NOT yet excluded: exported functions (`declare -Fx` output was
empty in the last diag, but that was a fresh shell), `BASH_ENV` pointing
somewhere other than the stock `/etc/bash.bashrc` (WSLENV passes it through,
current copy is inert — re-verify in-session), a wedged `/tmp` sandbox
(stale `estimate_test.*` dirs; `rm -rf /tmp/estimate_test.* /tmp/sb.*`), or
 antivirus/file-locking on the DrvFs checkout breaking `mktemp`+`chmod`.

### Manual life testing

`docs/MANUAL_LIFE_TESTING.md` is the hands-on, real-data task list (§1 AUTHORS
→ §6 loop-closer, safest first).  Its commands were contract-reviewed
2026-09-12 and the review exposed one real defect now fixed: `books_merge`
0.2.1 loads `config/books_merge.conf` again (the Phase 4 rename missed the
lib's built-in default path), so `./bin/books/books_merge.sh --dry-run` works
bare from the repo root.

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

## Current state (post-Phase-4 refactor)

| Piece | State |
|---|---|
| Layout | ratified + as-built: `bin/{authors,books,library}/` + flat `bin/version_bump.sh`; `lib/` 7 components + AWK reference; docs archived under `docs/archive/` |
| Architecture doc | `ARCHITECTURE.md` v1.0.0 (as-built, authoritative; D-02.12 delivered) |
| Phase records | Phases 1–5 **PASS**, signed in `docs/Measurable Phase Completion Criteria.md` |
| ShellCheck | warning-clean across all 21 production files (info-level findings documented in the Phase 5 record) |
| Validation | version sync 14/14; report 71/71; lib suite 42/42; populate 35/35; backup 23/23; CI green on every group commit |

| Piece | State |
|---|---|
| `myprivatelib` | live in MultiLib.exe, full-scale operation confirmed by the user; populate v1.3.0 (verbatim source keys, 0 AUTO_INCREMENT, FK gate) |
| `bin/refresh_myprivatelib.sh` v1.0.0 | shipped; tree-fingerprint checkpoint; first real run will write the checkpoint (`--status` shows `no-checkpoint`) |
| `bin/library/library_report.sh` v1.2.0 | shipped; TSV wish list (`data/wishlist.tsv`), view + mutations + exports; `--native title\|author\|series\|all` views over the app-managed `mllbr_main` wishlists (read-only, library-scoped; companion SQL `data/sql/qry_wishlist_native.sql`); `--hybrid` merges both sources (native status wins, TSV keeps periods, ★ favorites, source tags); suite 71/71 |
| Releases | **v1.7.1** (Phase 5 standards sweep) + **v1.7.0** (`eec78b4`, the rename era — Phases 1–4, ARCHITECTURE.md) + v1.3.0–v1.6.0 (library pipeline releases) published on GitHub, v1.7.1 = Latest |
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

0. ~~Cut the rename-era release tag~~ — DONE: v1.7.0 (rename era) and
   v1.7.1 (Phase 5 standards) published.
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
5. **Adopt the refresh loop**: after each collecting round,
   `./bin/library/library_refresh.sh` (backup -> populate ->
   checkpoint); check `--status` first. Consider a wrapper that also
   regenerates the reconcile statistics for the round.
6. **Phase 5 (coding-standards sweep)** — DONE 2026-09-12: headers
   standardized, 6 bare functions documented, ShellCheck
   warning-clean; record signed in the criteria doc.
7. **D-02.11 tests split** — move `tests/` to
   unit/ + integration/ + fixtures/ + golden/ as ONE change set (CI
   paths touched once).  Open since Phase 2; do it when nothing else
   is mid-flight.
8. **Optional later phases** — the original plan lists Phases 6–13
   (config cleanup, fs/data safety, DB utilities, testing strategy,
   docs, CI gates, naming, release hardening).  Most are already
   satisfied by the architecture work; audit the criteria doc and
   close them formally or prune the list.
9. **Covers/annotations**: CLOSED — the app renders both from the FB2
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
6. **Session state poisons test suites** (three distinct mechanisms,
   all identified 2026-09-12):
   a. leaked exports (`MYSQL_CLIENT`, `MYSQL_DATABASE`, `ETL_DEBUG`, …)
      flip env-sensitive assertions — `test_lib_infrastructure.sh` now
      unsets them per block; six tool suites still assume a mostly-
      clean shell, so run the loop from a fresh terminal when unsure;
   b. **inherited stdin**: the lib's readiness probe used to inherit
      the TTY and stall (fixed in lib 1.0.3 — `</dev/null`);
   c. **traced caller (`set -x`/`set -v`)**: `SHELLOPTS` is auto-
      exported and imported readonly by every child bash, corrupting
      output captures — all 16 suites now re-exec themselves without
      `SHELLOPTS`/`BASHOPTS` when xtrace/verbose is detected
      (`__ETL_TEST_ENV_GUARD__` header).

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
