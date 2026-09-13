# Flibusta FB2 / USR Extraction

> Last updated: 2026-09-13 (v0.2.0)
> Tool: `bin/flibusta/extract_flibusta_fb2.sh` (branch
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

Given one or more Flibusta `FileNumber`s, the tool:

1. Finds `f.<TYPE>-START-END.zip` whose inclusive window contains each number.
2. Resolves the member (`<N>.fb2` exactly; for usr, prefix `<N>.` with any
   real extension — the output keeps the member's real basename).
3. Writes it atomically (temp file + `mv`) into `FB2_OUTPUT_DIR`.

Numbers are SPARSE: a number inside an archive's range may be absent from
it (`811194` owns `f.usr-811194-815075.zip` but the member is not there).
Per-item failures are reported and summarized, never fatal to the batch.

## Usage

```bash
# single FB2
./bin/flibusta/extract_flibusta_fb2.sh 811194

# usr family (keeps the real extension: .pdf, .djvu, .pdf.zip ...)
./bin/flibusta/extract_flibusta_fb2.sh --type usr 811215

# try fb2 first, fall back to usr
./bin/flibusta/extract_flibusta_fb2.sh --type both 811194

# batch: several numbers on the command line
./bin/flibusta/extract_flibusta_fb2.sh 173909 173910 811194

# batch from a list file (one number per line; BOM/CR/blank/#-comments
# tolerated) mixed with positionals
./bin/flibusta/extract_flibusta_fb2.sh --from-file numbers.txt 173911

# re-extract over existing outputs
./bin/flibusta/extract_flibusta_fb2.sh --force 173909
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
bash tests/unit/test_extract_flibusta_fb2.sh    # 24 assertions
bash tests/unit/test_place_flibusta_book.sh     # 20 assertions
tests/run_all.sh unit                           # part of the standard battery
```

Both suites are hermetic: real zip fixtures in a temp dir, a mock mysql
recording argv and serving fixture catalog rows; no network, no real
MariaDB.

---

# Stage 2 — placement (`bin/flibusta/place_flibusta_book.sh` v0.1.0)

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

## Usage

```bash
# resolve, print the target, place nothing
./bin/flibusta/place_flibusta_book.sh --dry-run 100001

# place one (zip appears under ROOT_LOAD/<FullName>/...)
./bin/flibusta/place_flibusta_book.sh 100001

# batch from a stage-1 round, deleting sources as they are consumed
./bin/flibusta/place_flibusta_book.sh --from-file numbers.txt --rm-source
```

Options: `-i/--input-dir` (stage-1 output, default `/mnt/c/Backup_Go7/ToLoad`),
`-r/--root-load` (default `/mnt/c/Backup_Go7/ToLoad`), `--db` (default
`flibusta`), `--force`, `--rm-source`, `-n/--dry-run`, `-d/--debug`,
`-h/-v`.  Exit codes: 0 all placed, 1 any failed, 2 usage error.

## Database boundary

All SQL goes through `lib/database.sh` (`db_run_sql`; Follow-It §8) — the
tool builds no mysql command line.  The MariaDB lifecycle follows the
house pattern: a stopped server is started and stopped again on exit only
when this script started it; `--dry-run` performs the lookups (it must,
to resolve paths) but writes nothing.

The lookup is a single aggregated query (one row guaranteed: `MIN(authorid)`
per bookid, `MIN(seqid)` per bookid); the FileNumber is validated digits-only
before it is interpolated into the SQL literal.
