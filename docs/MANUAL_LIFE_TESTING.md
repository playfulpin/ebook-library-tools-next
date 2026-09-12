# Manual life testing — ebook-library-tools (v1.7.1)

> Created: 2026-09-12
> Updated:  2026-09-12 (command-contract review: every command below was
> checked against the tool's own usage text, config defaults and arg
> parser — stdin redirects replaced with file arguments, non-existent
> flags removed, output names and exit codes corrected)
> Scope: real-data, hands-on verification of every command after the
> Phase 4/5 refactoring.  Ordered **safest first** — everything before
> §5 is read-only; the destructive DB work starts at §5 and is
> bracketed by backups.
>
> Run everything from **WSL2, elevated** (server lifecycle needs it):
>
> ```bash
> cd /mnt/c/git_root/ebook-library-tools-next   # == C:\git_root\ebook-library-tools-next
> git status             # expect: clean, main, up to date with origin/main
> git log --oneline -2   # expect: 8eed2d8 (docs: manual life-testing list) on top
> ```

Pre-flight (no DB, no side effects):

```bash
shellcheck --severity=warning bin/*.sh bin/*/*.sh lib/*.sh && echo "shellcheck clean"
bash tests/test_version_sync.sh | tail -1        # expect: All versions in sync. (14 checks)
bash tests/test_lib_infrastructure.sh | tail -1  # expect: 42 passed, 0 failed
```

---

## §1 AUTHORS chain (writes only to /tmp and stdout)

| # | Task | Command | Expected |
|---|---|---|---|
| 1.1 | Prefix table from the real 5,707-author list | `./bin/authors/authors_prefix_build.sh --input-file=data/fixtures/authors_list_from_db.txt --max-prefix=5 --output=/tmp/prefix_table.txt` | exit 0; banner on **stderr**; `/tmp/prefix_table.txt` non-empty, TAB-separated |
| 1.2 | Validate that table (0-critical gate) | `./bin/authors/authors_prefix_check.sh --table=/tmp/prefix_table.txt --max-prefix=5` | exit 0, summary `Checked N rows: 0 critical, …`; exit 1 on any critical |
| 1.3 | Render the tree | `./bin/authors/authors_prefix_tree.sh /tmp/prefix_table.txt | head -30` | Unicode tree, Cyrillic roots intact (FILE argument — this tool does not read stdin) |
| 1.4 | Generate the skeleton script (no `--dry-run` flag exists) | `./bin/authors/authors_tree_build.sh --input-file=data/fixtures/authors_list_from_db.txt --min-authors=10 --max-prefix=5 --root-dir=/tmp/tree_build_probe | head -10` | first lines are `rm -rf`/`cd`/`mkdir -p` for `/tmp/tree_build_probe`; pipe to `head` so nothing is executed.  NOTE: the tool itself creates the root dir (and `mkdir -p`s it) even without `-c`; with `--root-dir` under `/tmp` that side effect stays in /tmp |

§1 touches nothing outside `/tmp` and stdout.  To actually build the
skeleton, pipe 1.4 into bash **with a disposable root**:

```bash
./bin/authors/authors_tree_build.sh --input-file=data/fixtures/authors_list_from_db.txt \
    -r /tmp/Empty_Skeleton | bash    # builds the tree under /tmp — nothing in /mnt/c
```

## §2 BOOKS group (read-only DB or pure filesystem)

| # | Task | Command | Expected |
|---|---|---|---|
| 2.1 | Merge dry-run (archive → staging) | `./bin/books/books_merge.sh --dry-run` | plan + summary printed (`mode: DRY RUN`); reports under `/mnt/c/Backup_Go7/merge-reports/`; every manifest row says `would-copy`; **no files copied, no `BooksInput_` dir created**.  Note: the run DOES create `REPORT_DIR` and reports even in dry-run |
| 2.2 | Finalize dry-run (staging → Books) | `./bin/books/books_finalize.sh --target /mnt/c/Backup_Go7/Books --dry-run` | one-line rsync command echoed, `would-copy`/`would-keep` report written; **no `pv` progress in dry-run** — the `pv -l` bar appears only in the real run; destination untouched |
| 2.3 | Reconcile (DB-backed, read-only) | `./bin/books/books_reconcile.sh --debug` | starts MariaDB (elevated window), prints the collection-progress summary, writes `books_reconcile_<ts>.tsv` + `books_reconcile_to_collect_<ts>.txt` + (DB mode) `books_reconcile_beyond_books_<ts>.tsv` under `/mnt/c/Backup_Go7/merge-reports/`; **stops the server if it started it** |
| 2.4 | Estimate next round | `./bin/books/books_estimate.sh --debug` | starts/stops MariaDB the same way; qualifying + full-oeuvre distinct-book totals, top-10 printed; per-author TSV `books_estimate_<ts>.tsv` sorted top-rated first |

## §3 LIBRARY group — safety net first (§3.1 is the one that matters)

| # | Task | Command | Expected |
|---|---|---|---|
| 3.1 | **Backup myprivatelib BEFORE anything else** | `./bin/library/library_backup.sh backup` | timestamped `myprivatelib_<ts>.sql.gz` under `/mnt/c/Backup_Go7/myprivatelib-backups/`, gzip-verified; note the filename |
| 3.2 | List backups | `./bin/library/library_backup.sh list` | the §3.1 artifact listed with size/date |
| 3.3 | Verify the fresh backup | `./bin/library/library_backup.sh verify /mnt/c/Backup_Go7/myprivatelib-backups/<file-from-3.1>` | gzip OK + dump sanity OK (FILE is a positional argument, no `--file` flag) |
| 3.4 | Refresh checkpoint status | `./bin/library/library_refresh.sh --status` | `checkpoint: …` / `state: …` lines (`no-checkpoint` on first ever run, else `up-to-date` or `changed`); never starts the server |
| 3.5 | Refresh dry-run | `./bin/library/library_refresh.sh --dry-run` | prints the decision and what would run; changes nothing, writes no checkpoint, does NOT start the server |

## §4 LIBRARY report — wish list (writes only to data/wishlist.tsv + exports)

| # | Task | Command | Expected |
|---|---|---|---|
| 4.1 | Find a bookid | `./bin/library/library_report.sh --search piranha` | bookid candidates printed (this mode starts MariaDB if down, stops it on exit if it started it) |
| 4.2 | Add a wish entry (pick a bookid from 4.1) | `./bin/library/library_report.sh --add <bookid> --period 2026-10 --note "life test"` | entry appended to `data/wishlist.tsv` (no server needed) |
| 4.3 | View the plan | `./bin/library/library_report.sh` | period → author grouped plan; entry marked `[ ]` (wish) |
| 4.4 | Native view (app wishlists, read-only) | `./bin/library/library_report.sh --native` | `mllbr_main` groups rendered; **server is only read, never written** |
| 4.5 | Hybrid view | `./bin/library/library_report.sh --hybrid` | TSV plan × native state merged; rows tagged `[app]`/`[tsv]`/`[app+tsv]` |
| 4.6 | Mark reading | `./bin/library/library_report.sh --set-status <bookid> reading` | status flips to `reading` → `[~]` in the view |
| 4.7 | Export | `./bin/library/library_report.sh --export md` | `report_wishlist_<ts>.md` in `/mnt/c/Backup_Go7/merge-reports/` (view mode only) |
| 4.8 | Clean up the test entry | `./bin/library/library_report.sh --remove <bookid>` | `data/wishlist.tsv` back to its prior state |

## §5 POPULATE — the destructive one (backup from §3.1 is the rollback)

Do this **only** after §3.1 succeeded.

```bash
# 5.1 dry-run the whole freshness loop first (no server, no writes)
./bin/library/library_refresh.sh --dry-run

# 5.2 real run: fingerprint → backup (again, automatic) → truncate+rebuild myprivatelib
./bin/library/library_refresh.sh
#    expect: state "changed" → MariaDB started (elevated window) → backup →
#    populate stages → FK gate OK → new checkpoint; server stopped on exit.
#    A column-parity mismatch aborts BEFORE any TRUNCATE — that is by design.

# 5.3 verify (in a SECOND shell or while the server window is still up —
#     refresh stops the server only if IT started it):
mysql --connect-timeout=10 -h 127.0.0.1 -u root -e \
  "SELECT COUNT(*) AS books FROM myprivatelib.mlbook;
   SELECT COUNT(*) AS authors FROM myprivatelib.mlauthorname;"

# 5.4 THE acceptance test: open MultiLib.exe → myprivatelib →
#     open a book, check cover/annotation/series view still work
```

Rollback if anything looks wrong:

```bash
# restore NEEDS the backup file as a positional argument (no --file flag);
# it backs up the current state first and refuses a non-empty library without --force
./bin/library/library_backup.sh restore /mnt/c/Backup_Go7/myprivatelib-backups/<file-from-3.1>
# (then re-check 5.3)
```

## §6 Loop-closer (after §5 passes)

```bash
# refresh is now idempotent: state prints "up-to-date", exits 0,
# and never even starts the server
./bin/library/library_refresh.sh --status   # expect: state: up-to-date
./bin/library/library_refresh.sh            # expect: "nothing to do", exit 0, no server start
```

---

## Observing during the run

- **Server lifecycle**: tools auto-start a stopped MariaDB via an
  elevated PowerShell window — accept the UAC prompt.  Tools that
  started the server stop it gracefully on exit; a server YOU started
  is left running.  Reminder: start WSL2 elevated to avoid the UAC
  dance.
- **Reports**: everything lands in `/mnt/c/Backup_Go7/merge-reports/`
  with timestamps — nothing in the repo tree is written except the
  wish-list edits in §4 (`data/wishlist.tsv`).
- **Password**: `MYSQL_PWD` env only; never echoed (suites assert
  this).  Export it before DB-touching tasks:
  `export MYSQL_PWD='<your root password>'`
- **Hangs**: if a mysql call hangs, the mirrored-network quirk is the
  suspect — tools pass `--connect-timeout`; kill a wedged server with
  `/mnt/c/Windows/System32/taskkill.exe /F /IM mysqld.exe` and retry
  with `MARIA_START_TIMEOUT=120` (seconds; default 30).

## Regression suites between manual steps (optional, fast)

```bash
for t in tests/test_*.sh; do bash "$t" >/dev/null 2>&1 && echo "ok   $t" || echo "FAIL $t"; done
```
