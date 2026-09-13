# Flibusta FB2 Extraction

> Last updated: 2026-09-13
> Tool: `bin/flibusta/extract_flibusta_fb2.sh` v0.1.0 (branch
> `feature/flibusta-fb2-extract`)

## Purpose

Stage-1 Flibusta extraction utility. The Flibusta book archives arrive as
massive range bundles with the naming convention

```
f.FILETYPE-<START>-<END>.zip        e.g. f.fb2-800000-849999.zip
```

where each archive holds individually-compressed members named

```
<FILENUMBER>.FILETYPE               e.g. 811194.fb2
```

Given a Flibusta `FileNumber`, the tool:

1. Finds `f.fb2-START-END.zip` under `FLIBUSTA_SOURCE_DIR` whose inclusive
   window contains the number.
2. Extracts ONLY the member `FileNumber.fb2` (via `unzip -p`).
3. Writes it atomically (temp file + `mv`) into `FB2_OUTPUT_DIR`.

The archive itself is never copied or unpacked wholesale.

## Usage

```bash
./bin/flibusta/extract_flibusta_fb2.sh 811194
# -> /mnt/c/Backup_Go7/ToLoad/811194.fb2
```

Options:

| Option | Effect |
|---|---|
| `-s, --source-dir DIR` | archive source root (default `/mnt/x/flibusta`) |
| `-o, --output-dir DIR` | extraction target (default `/mnt/c/Backup_Go7/ToLoad`) |
| `-n, --dry-run` | resolve archive + member, extract nothing |
| `-d, --debug` | verbose diagnostics on stderr |
| `-h, --help` / `-v, --version` | house CLI contract |

Configuration precedence: flag > environment (`FLIBUSTA_SOURCE_DIR`,
`FB2_OUTPUT_DIR`) > `config/flibusta_fb2.conf` (override the file itself
with `FLIBUSTA_FB2_CONF_FILE`).

Exit codes: 0 success, 1 operational failure, 2 usage error.

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

- FB2 archives only (`.usr` handling comes later).
- One FileNumber per invocation.
- Range detection from the archive filename.
- Extraction of one archive member.
- No database access.

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

`tests/unit/test_extract_flibusta_fb2.sh` (15 assertions, hermetic —
real zip fixtures in a temp dir, no network, no MariaDB):

```bash
bash tests/unit/test_extract_flibusta_fb2.sh
tests/run_all.sh unit        # part of the standard battery
```
