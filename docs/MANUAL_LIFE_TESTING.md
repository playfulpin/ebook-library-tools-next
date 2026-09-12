# Manual life testing — ebook-library-tools (v1.7.1)

> Created: 2026-09-12
> Scope: real-data, hands-on verification of every command after the
> Phase 4/5 refactoring.  Ordered **safest first** — everything before
> §5 is read-only; the destructive DB work starts at §5 and is
> bracketed by backups.
>
> Run everything from **WSL2, elevated** (server lifecycle needs it):
>
> ```bash
> cd /mnt/c/git_root/ebook-library-tools-next   # == C:\git_root\ebook-library-tools-next
> git status          # expect: clean, main, up to date with origin/main
> git log --oneline -2   # expect: 5ca04a4 (v1.7.1) on top
> ```

Pre-flight (no DB, no side effects):

```bash
shellcheck --severity=warning bin/*.sh bin/*/*.sh lib/*.sh && echo "shellcheck clean"
bash tests/test_version_sync.sh | tail -2        # expect: PASS: 14
bash tests/test_lib_infrastructure.sh | tail -1  # expect: 42 passed
```

---

## §1 AUTHORS chain (read-only + writes only to stdout/tmp)

| # | Task | Command | Expected |
|---|---|---|---|
| 1.1 | Prefix table from the real 5,707-author list | `./bin/authors/authors_prefix_build.sh --input-file=data/fixtures/authors_list_from_db.txt --max-prefix=5 --output=/tmp/prefix_table.txt` | exit 0; `/tmp/prefix_table.txt` non-empty, TAB-separated |
| 1.2 | Validate that table (0-critical gate) | `./bin/authors/authors_prefix_check.sh < /tmp/prefix_table.txt` | exit 0, no critical findings |
| 1.3 | Render the tree | `./bin/authors/authors_prefix_tree.sh < /tmp/prefix_table.txt | head -30` | Unicode tree, Cyrillic roots intact |
| 1.4 | Dry-run the skeleton build | `./bin/authors/authors_tree_build.sh --dry-run data/fixtures/authors_list_from_db.txt | head -10` | `mkdir -p` lines printed, nothing created |

§1 touches nothing outside `/tmp`.

## §2 BOOKS group (read-only DB or pure filesystem)

| # | Task | Command | Expected |
|---|---|---|---|
| 2.1 | Merge dry-run (archive → staging) | `./bin/books/books_merge.sh --dry-run` | plan printed; report says would-copy; **no files copied, no BooksInput_ dir created** |
| 2.2 | Finalize dry-run (staging → Books) | `./bin/books/books_finalize.sh --dry-run` | rsync plan printed with `pv` progress; no destination writes |
| 2.3 | Reconcile (DB-backed, read-only) | `./bin/books/books_reconcile.sh --debug` | starts MariaDB (elevated window), prints collection-progress summary, writes `books_reconcile_<stamp>.tsv` + the to-collect export; **stops the server if it started it** |
| 2.4 | Estimate next round | `./bin/books/books_estimate.sh --debug` | qualifying + full-oeuvre totals, per-author TSV sorted top-rated first |

## §3 LIBRARY group — safety net first (§3.1 is the one that matters)

| # | Task | Command | Expected |
|---|---|---|---|
| 3.1 | **Backup myprivatelib BEFORE anything else** | `./bin/library/library_backup.sh backup` | timestamped `.sql.gz` under `/mnt/c/Backup_Go7/myprivatelib-backups/`, integrity-verified; note the filename |
| 3.2 | List backups | `./bin/library/library_backup.sh list` | the §3.1 artifact listed with size/date |
| 3.3 | Verify the fresh backup | `./bin/library/library_backup.sh verify <file-from-3.1>` | gzip OK + dump sanity OK |
| 3.4 | Refresh checkpoint status | `./bin/library/library_refresh.sh --status` | prints checkpoint state (`no-checkpoint` on first ever run, or the stored fingerprint) |
| 3.5 | Refresh dry-run | `./bin/library/library_refresh.sh --dry-run` | plan: fingerprint → (changed?) backup → populate; nothing executed |

## §4 LIBRARY report — wish list (writes only to data/wishlist.tsv + exports)

| # | Task | Command | Expected |
|---|---|---|---|
| 4.1 | Find a bookid | `./bin/library/library_report.sh --search piranha` | rows with bookid/title/author |
| 4.2 | Add a wish entry (pick a bookid from 4.1) | `./bin/library/library_report.sh --add <bookid> --period 2026-10 --note "life test"` | entry written to `data/wishlist.tsv` |
| 4.3 | View the plan | `./bin/library/library_report.sh` | period → author grouped plan, entry marked `[ ]` |
| 4.4 | Native view (app wishlists, read-only) | `./bin/library/library_report.sh --native` | mllbr_main groups rendered; **server never written** |
| 4.5 | Hybrid view | `./bin/library/library_report.sh --hybrid` | TSV plan × native state merged |
| 4.6 | Mark reading | `./bin/library/library_report.sh --set-status <bookid> reading` | `[~]` in the view |
| 4.7 | Export | `./bin/library/library_report.sh --export md` | printable `.md` in the report dir |
| 4.8 | Clean up the test entry | `./bin/library/library_report.sh --remove <bookid>` | wishlist.tsv back to its prior state |

## §5 POPULATE — the destructive one (backup from §3.1 is the rollback)

Do this **only** after §3.1 succeeded.

```bash
# 5.1 dry-run the whole freshness loop first
./bin/library/library_refresh.sh --dry-run

# 5.2 real run: fingerprint → backup (again, automatic) → truncate+rebuild myprivatelib
./bin/library/library_refresh.sh
#    expect: fingerprint differs → backup → populate stages → FK gate OK → new checkpoint
#    aborts BEFORE any TRUNCATE on column-parity mismatch — that is by design

# 5.3 verify: row counts sane, no orphans (the tool already gates this, but eyeball it)
mysql --connect-timeout=10 -h 127.0.0.1 -u root -e \
  "SELECT COUNT(*) AS books FROM myprivatelib.mlbook; SELECT COUNT(*) AS authors FROM myprivatelib.mlauthorname;"

# 5.4 THE acceptance test: open MultiLib.exe → myprivatelib →
#     open a book, check cover/annotation/series view still work
```

Rollback if anything looks wrong:

```bash
./bin/library/library_backup.sh restore   # refuses to overwrite a non-empty library without --force
# (then re-check 5.3)
```

## §6 Loop-closer (after §5 passes)

```bash
# refresh is now idempotent: checkpoint matches, exits 0 without touching anything
./bin/library/library_refresh.sh --status
./bin/library/library_refresh.sh          # expect: "up to date", exit 0, no server start
```

---

## Observing during the run

- **Server lifecycle**: tools auto-start a stopped MariaDB via an
  elevated PowerShell window — accept the UAC prompt.  Tools that
  started the server stop it gracefully on exit; a server YOU started
  is left running.  Reminder from NEXT.md: start WSL2 elevated to
  avoid the UAC dance.
- **Reports**: everything lands in `/mnt/c/Backup_Go7/merge-reports/`
  with timestamps — nothing in the repo tree is written.
- **Password**: always `MYSQL_PWD` env only; never echoed (suites
  assert this).  Export it before DB-touching tasks:
  `export MYSQL_PWD='<your root password>'`
- **Hangs**: if a mysql call hangs, the mirrored-network quirk is the
  suspect — tools pass `--connect-timeout`; kill a wedged server with
  `taskkill.exe /F /IM mysqld.exe` and retry with
  `MARIA_START_TIMEOUT=120`.

## Regression suites between manual steps (optional, fast)

```bash
for t in tests/test_*.sh; do bash "$t" >/dev/null 2>&1 && echo "ok   $t" || echo "FAIL $t"; done
```
