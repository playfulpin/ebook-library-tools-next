# Flibusta Extractor Family (bookid / author / series)

> Last updated: 2026-09-13 (extract_bookid 0.4.0, extract_author 0.1.1,
> extract_series 0.1.1, place 0.3.2, run_round 0.1.0,
> _flibusta_extract_common 1.2.0)
> Tools: `bin/flibusta/extract_bookid_flibusta.sh`,
> `bin/flibusta/extract_author_flibusta.sh`,
> `bin/flibusta/extract_series_flibusta.sh`,
> `bin/flibusta/place_flibusta_book.sh` (branch
> `feature/flibusta-fb2-extract`)

## Purpose

Stage-1 Flibusta extraction utility. The Flibusta book archives arrive as
massive range bundles with the naming convention

```
f.FILETYPE-<START>-<END>.zip        e.g. f.fb2-800000-849999.zip
```

where each archive holds individually-compressed members.  Member naming
was verified against the real `/mnt/x/flibusta` dataset (2026-09-13):

| Family | Members | Example |
|---|---|---|
| `f.fb2-*` (201 archives) | `<N>.fb2`, unpadded | `811194.fb2` |
| `f.usr-*` (200 archives) | `<N>.<realext>` — pdf, djvu, epub, double-suffixed `.pdf.zip` / `.pdf.rar`; the OLDEST usr archives are fully title-named (`Author_Title.rar`) with no number mapping | `811226.pdf.zip` |
| legacy `fb2-*` / `usr-*` / `d.*` | outside this tool's scope (ignored) | |

Given one or more Flibusta `FileNumber`s, the tools:

1. Find `f.<TYPE>-START-END.zip` whose inclusive window contains each number.
2. Resolve the member (`<N>.fb2` exactly; for usr, prefix `<N>.` with any
   real extension — the output keeps the member's real basename).
3. Write it atomically (temp file + `mv`) into `FB2_OUTPUT_DIR`.

## The extractor family

Three extractors share one range-index / member-resolution / extraction
engine in `bin/flibusta/_flibusta_extract_common.sh` (intra-group include,
allowed by the layer gate v1.1.0).  Each tool owns its own CLI, batch loop
and — for the two DB-driven ones — its catalog query (Follow-It §8: all SQL
via `lib/database.sh`).

| Tool | Selects books by | Catalog source | Families |
|---|---|---|---|
| `extract_bookid_flibusta.sh` | FileNumber(s) | none (numbers given) | fb2, usr, both |
| `extract_author_flibusta.sh` | author name substring (`mlauthorname.FullName LIKE`) | `flibusta` DB | fb2 only |
| `extract_series_flibusta.sh` | series name substring (`mlseqname.seqname LIKE`) | `flibusta` DB | fb2 only |

The DB-driven tools resolve names → authorids/seqids → fb2 bare-number
filenames (numbers) → the same extraction chain.  usr stays bookid-only
(by design: usr members carry real extensions and the oldest usr archives
are title-named, so number-based selection is not meaningful there).

Result-delivery contract in the common engine: `flb_find_archive` sets
`FLB_ARCHIVE`, `flb_resolve_member` sets `FLB_MEMBER` (return code signals
success).  Call sites must invoke them directly — wrapping in `$( ... )`
would run them in a subshell where the range index and listing cache die
at call end (this exact mistake cost a 30× slowdown on live data before
being caught by timing tests).

Numbers are SPARSE: a number inside an archive's range may be absent from
it (`811194` owns `f.usr-811194-815075.zip` but the member is not there).
Per-item failures are reported and summarized, never fatal to the batch.

## Usage

```bash
# single FB2 (bookid extractor)
./bin/flibusta/extract_bookid_flibusta.sh 811194

# usr family (keeps the real extension: .pdf, .djvu, .pdf.zip ...)
./bin/flibusta/extract_bookid_flibusta.sh --type usr 811215

# try fb2 first, fall back to usr
./bin/flibusta/extract_bookid_flibusta.sh --type both 811194

# batch: several numbers on the command line
./bin/flibusta/extract_bookid_flibusta.sh 173909 173910 811194

# batch from a list file (one number per line; BOM/CR/blank/#-comments
# tolerated) mixed with positionals
./bin/flibusta/extract_bookid_flibusta.sh --from-file numbers.txt 173911

# re-extract over existing outputs
./bin/flibusta/extract_bookid_flibusta.sh --force 173909

# all fb2 books of every author matching a name substring (DB-driven)
./bin/flibusta/extract_author_flibusta.sh "Мартин"

# all fb2 books of every series matching a name substring (DB-driven)
./bin/flibusta/extract_series_flibusta.sh "Забытые королевства"
```

Options:

| Option | Effect |
|---|---|
| `-t, --type fb2\|usr\|both` | archive family (default `fb2`; `both` = fb2 first, usr fallback) |
| `-f, --from-file LIST` | FileNumbers from a list file |
| `-s, --source-dir DIR` | archive source root (default `/mnt/x/flibusta`) |
| `-o, --output-dir DIR` | extraction target (default `/mnt/c/Backup_Go7/ToLoad`) |
| `--force` | re-extract even when the output already exists |
| `-n, --dry-run` | resolve every number, extract nothing |
| `-d, --debug` | verbose diagnostics on stderr |
| `-h, --help` / `-v, --version` | house CLI contract |

Configuration precedence: flag > environment (`FLIBUSTA_SOURCE_DIR`,
`FB2_OUTPUT_DIR`) > `config/flibusta_fb2.conf` (override the file itself
with `FLIBUSTA_FB2_CONF_FILE`).

Exit codes: 0 all numbers delivered, 1 at least one failed, 2 usage error.

## Conventions honored

- `lib/common.sh` / `common_init`: `die`, `require_command`, house logging
  (`log_info`/`debug` to stderr), `fs_require_dir`.
- House CLI contract: `-h` exits 0, `-v` prints `bin/... v<version>`,
  unknown option exits 2, exactly one positional FILE_NUMBER required.
- House headers (`# Version:` / `# Last updated:`), so the version-sync
  registry can pick the tool up when it stabilizes.
- **No `lib/` domain module** — the extraction primitives are inlined in
  the tool per the ratified §4 layer rule (same decision as
  `books_merge.sh`); `lib/` stays domain-free.

## Scope (deliberately limited)

- FB2 and USR range archives only (legacy `fb2-*`/`usr-*`/`d.*` ignored).
- Extraction of one member per number; no conversion, no packaging.
- No database access.

## Batch semantics

- Every number is attempted independently; the run is summarized
  (`N delivered, M of them skipped (exist), K failed`).
- `--type both` is a FALLBACK CHAIN: fb2 first, then usr; a fb2 miss is
  not a failure when usr delivers (and vice versa with `--type usr`).
- Existing non-empty outputs are skipped by default; `--force` re-extracts.
- Exit 1 when anything failed, so orchestrators can react even when most
  numbers were delivered.

## Range-match details

- Archives are matched against `^f\.fb2-([0-9]+)-([0-9]+)\.zip$`.
- Bounds are inclusive: `START <= FileNumber <= END` (numbers are
  compared `10#`-normalized, so leading zeros do not trigger octal).
- Malformed names are ignored, never fatal.
- Ranges are expected disjoint; if they overlap, the lowest-START
  archive wins deterministically (a note goes to debug output).

## Future integration

The intended flow is:

```text
FileNumber
    |
    +--> database lookup   (through lib/database.sh — Follow-It §8)
    |
    +--> archive lookup    (this tool, stage 1)
    |
    +--> FB2 extraction    (this tool, stage 1)
    |
    +--> metadata / packaging
    |
    +--> final library placement
```

When the DB stage lands it MUST go through `lib/database.sh`
(`db_run_query`/`db_run_sql`); inline mysql command lines are a boundary
violation the layer gate and review will reject.

## Testing

```bash
bash tests/unit/test_extract_bookid_flibusta.sh   # 28 assertions
bash tests/unit/test_extract_author_flibusta.sh   # 18 assertions
bash tests/unit/test_extract_series_flibusta.sh   # 17 assertions
bash tests/unit/test_run_round.sh                 # 15 assertions
bash tests/unit/test_place_flibusta_book.sh     # 27 assertions
tests/run_all.sh unit                           # part of the standard battery
```

Both suites are hermetic: real zip fixtures in a temp dir, a mock mysql
recording argv and serving fixture catalog rows; no network, no real
MariaDB.

---

# Stage 2 — placement (`bin/flibusta/place_flibusta_book.sh` v0.3.0)

> Last updated: 2026-09-13

Takes the same FileNumbers and turns the stage-1 extracted files into
properly named zips in the library tree, resolving each number through
the `flibusta` catalog:

| Catalog step | Table | Provides |
|---|---|---|
| identity | `mlbook.filename` = FileNumber | `bookid`, `title` |
| author | `mlauthor` (by bookid) | `authorid` — lowest wins |
| top folder | `mlauthorname` (by authorid) | `FullName` |
| series | `mlseq` (by bookid) | `seqid` — lowest wins, plus `seqnum` |
| second folder | `mlseqname` (by seqid) | `seqname` |

## Target path (confirmed 2026-09-13)

```text
ROOT_LOAD
└── <mlauthorname.FullName>            top-level author folder
    └── <mlseqname.seqname>            only when the book has a series
        └── <0><seqnum> - <title>.zip  seq prefix two-digit padded
(no series:  ROOT_LOAD/<FullName>/<title>.zip)
```

- Seq prefix: `1 -> "01"`, `15 -> "15"`, `100 -> "100"` (two-digit pad).
- The zip name DROPS the extracted file's extension: `811226.pdf.zip` and
  `811215.djvu` alike become `<0><seqnum> - <title>.zip`.
- Title/FullName/seqname are sanitized into Windows-safe components
  (`\/:*?"<>|` and control chars become `_`; trailing dots/spaces trimmed —
  the target tree lives on NTFS).
- The extracted file is compressed IN PLACE: the zip is written to a temp
  name next to the target, then moved (atomic).
- **Source handling (v0.2.0):** the stage-1 extracted file is **trashed
  by default** after a successful placement (`--keep-source` retains it;
  `--rm-source` is a documented no-op kept for pipeline symmetry).  A
  failed placement never removes the source.
- **Per-run TSV report (v0.2.0):** every run writes one row per attempted
  number — `processed_at, file_number, bookid, status, target_zip, reason`
  — into the report dir (`--report-dir`, default
  `/mnt/c/Backup_Go7/merge-reports`).  Statuses: `placed` / `skipped` /
  `failed` (dry-run rows use `would-place` / `would-skip`).  This is the
  persistent error/retry log: re-run failed numbers from the report.

## Usage

```bash
# resolve, print the target, place nothing
./bin/flibusta/place_flibusta_book.sh --dry-run 100001

# place one (zip appears under ROOT_LOAD/<FullName>/...)
./bin/flibusta/place_flibusta_book.sh 100001

# batch from a stage-1 round; sources are consumed on success (default)
./bin/flibusta/place_flibusta_book.sh --from-file numbers.txt

# keep the extracted sources instead of trashing them
./bin/flibusta/place_flibusta_book.sh --from-file numbers.txt --keep-source
```

Options: `-i/--input-dir` (stage-1 output, default `/mnt/c/Backup_Go7/ToLoad`),
`-r/--root-load` (default `/mnt/c/Backup_Go7/ToLoad`), `--db` (default
`flibusta`), `--force`, `--keep-source`, `--rm-source` (no-op),
`--report-dir`, `-n/--dry-run`, `-d/--debug`, `-h/-v`.  Exit codes:
0 all placed, 1 any failed, 2 usage error.

## Library use (place v0.3.0; extract_bookid v0.4.0; orchestrator v0.1.0)

**Both** stage tools double as **sourceable libraries**: with
`PLACE_LIB_ONLY=1` / `FB2_LIB_ONLY=1` set before sourcing they define their
APIs without running.  `bin/flibusta/run_round.sh` is the sanctioned
consumer — the single-process round orchestrator (extract → place, one
summary, one joined TSV round report; see `run_round.sh --help`):

```bash
# the orchestrator, one command for a whole round:
./bin/flibusta/run_round.sh --from-file numbers.txt
# retry: failed-* rows of the round report -> a new list -> re-run

# manual in-process composition (what run_round does internally):
FB2_LIB_ONLY=1  source "$PROJECT_ROOT/bin/flibusta/extract_bookid_flibusta.sh"
PLACE_LIB_ONLY=1 source "$PROJECT_ROOT/bin/flibusta/place_flibusta_book.sh"
fb2_parse_args --type both 100031 && fb2_run          # stage 1
PLACE_POSITIONAL=(100031) && place_run                # stage 2
```

**Stage 1 library API** (extract_bookid v0.4.0, mirrors place):

| Function | Contract |
|---|---|
| `fb2_parse_args ARGS...` | sets the `FB2_*` run parameters; **returns** 2 on a usage error (never exits) |
| `fb2_run` | executes the batch; **returns** 1 when anything failed, 0 on success — never exits |
| `FB2_DELIVERED[]` | per-number results after `fb2_run`: `number<TAB>status<TAB>detail` (delivered / skipped / failed) |
| `fb2_assemble_numbers` | fills `FB2_NUMBERS[]` from positionals + `--from-file` |
| `fb2_validate_run` | prereq check (unzip, dirs, index) — returns 1 with the reason logged |

**Stage 2 library API** (place v0.3.0):

| Function | Contract |
|---|---|
| `place_parse_args ARGS...` | sets the `PLACE_*` run parameters; **returns** 2 on a usage error (never exits) |
| `place_run` | executes the batch; **returns** 1 when anything failed, 0 on success — never exits |
| `PLACE_REPORT_ROWS[]` | per-number results: `processed_at, number, bookid, status, target, reason` |
| `place_lookup NUMBER` | raw catalog row (TSV) on stdout |
| `place_sanitize_name RAW` | Windows-safe path component on stdout |
| `place_find_source N DIR` | stage-1 file path for number N |
| `place_zip SRC DST` | single-file zip, atomic temp+`mv` |

Sourcing implications (documented, by design): the house `set -Eeuo
pipefail` regime is enabled; config/env resolution happens at source time;
`place_run` installs its own EXIT cleanup trap for the MariaDB lifecycle
and removes it when done.  Sourcing **without** the guard keeps the exact
script-mode behavior (the bottom-of-file guard evaluates once).

## Database boundary

All SQL goes through `lib/database.sh` (`db_run_sql`; Follow-It §8) — the
tool builds no mysql command line.  The MariaDB lifecycle follows the
house pattern: a stopped server is started and stopped again on exit only
when this script started it; `--dry-run` performs the lookups (it must,
to resolve paths) but writes nothing.

The lookup is a single aggregated query (one row guaranteed: `MIN(authorid)`
per bookid, `MIN(seqid)` per bookid); the FileNumber is validated digits-only
before it is interpolated into the SQL literal.
