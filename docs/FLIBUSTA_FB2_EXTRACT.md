# Flibusta FB2 Extraction

## Purpose

`extract_flibusta_fb2.sh` is the first-stage utility for retrieving a single
FB2 file from the large range archives stored under `/mnt/x/flibusta`.

Given a Flibusta `FileNumber`, the tool:

1. Finds `f.fb2-START-END.zip` whose range contains the number.
2. Extracts only `FileNumber.fb2`.
3. Writes it to `/mnt/c/Backup_Go7/ToLoad/FileNumber.fb2`.

The archive itself is never copied to `ToLoad`.

## Example

```bash
./bin/flibusta/extract_flibusta_fb2.sh 811194
```

Expected result:

```text
/mnt/c/Backup_Go7/ToLoad/811194.fb2
```

## Scope

Current scope is deliberately limited to:

- FB2 archives only.
- One FileNumber per invocation.
- Range detection from the archive filename.
- Extraction of one archive member.
- No database access.
- No `.usr` processing.
- No second-stage FB2 packaging or library placement.

## Future integration

Database access is expected in a later stage. It should be introduced through
a separate database module and shared database infrastructure rather than
embedding SQL commands in the extraction functions.

The intended future flow is:

```text
FileNumber
    |
    +--> database lookup
    |
    +--> archive lookup
    |
    +--> FB2 extraction
    |
    +--> metadata / packaging
    |
    +--> final library placement
```

This document describes the initial stage only.
