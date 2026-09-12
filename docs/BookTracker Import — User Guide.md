# BookTracker Import — User Guide

## 1. Overview

`booktracker-import` is a collection of scripts used to prepare and import book data from BookTracker/Flibusta sources into a local library database.

The scripts are designed to be executed in a specific order. Each step prepares data required by the following step.

This document describes the normal end-user workflow, required prerequisites, command-line examples, expected results, and important precautions.

---

## 2. Basic Workflow

The normal workflow is:

```text
Source data
    |
    v
1. Prepare source data
    |
    v
2. Create / prepare database schema
    |
    v
3. Import book and metadata records
    |
    v
4. Build auxiliary structures
    |
    v
5. Recalculate derived counters
    |
    v
6. Verify the resulting database
```

**Do not normally execute the scripts in a different order.**

Some scripts depend on tables or data created by earlier steps.

---

## 3. Prerequisites

Before starting, make sure the following are available:

- Linux, WSL, or another Unix-like environment.
- MariaDB/MySQL client.
- Access to the source database or SQL dump.
- Sufficient disk space for the database and temporary files.
- The complete `booktracker-import` project.
- Appropriate permissions to read the input files and write the output files.

Check the database client:

```bash
mysql --version
```

Check that the project is available:

```bash
cd /path/to/booktracker-import
```

---

# 4. Step 1 — Prepare the Source Data

Start with the original source data.

Do not modify the original source files manually unless a particular script explicitly requires it.

Keep the original data available so that the import can be repeated if necessary.

A typical project layout is:

```text
booktracker-import/
├── data/
├── sql/
├── scripts/
└── README.md
```

The exact locations may differ depending on the installation.

---

# 5. Step 2 — Prepare the Database

Create the destination database before importing data.

Example:

```sql
CREATE DATABASE myprivatelib;
```

Select the destination database:

```sql
USE myprivatelib;
```

The database must contain the tables required by the import scripts.

Before proceeding, verify that the expected tables exist:

```sql
SHOW TABLES;
```

---

# 6. Step 3 — Import the Main Data

Run the main import script(s) in the order specified by the project.

A typical command has the following form:

```bash
mysql -u USER -p myprivatelib < sql/<import-script>.sql
```

Example:

```bash
mysql -u root -p myprivatelib < sql/<import-script>.sql
```

Enter the database password when prompted.

### Verify the import

After the import finishes, check that the database contains records:

```sql
USE myprivatelib;

SELECT COUNT(*) FROM mlbook;
```

Also check the major relationship tables:

```sql
SELECT COUNT(*) FROM mlauthor;
SELECT COUNT(*) FROM mlgenre;
SELECT COUNT(*) FROM mlseq;
```

The exact expected numbers depend on the source dataset.

---

# 7. Step 4 — Build the Author Directory Structure

The author-directory generation script creates a compact nested directory hierarchy based on author-name prefixes.

For example:

```text
А
└── Аб
    └── Абр
        └── Абра
```

is represented by one command:

```bash
mkdir -p А/Аб/Абр/Абра
```

There is no need to generate separate commands for:

```bash
mkdir -p А
mkdir -p А/Аб
mkdir -p А/Аб/Абр
mkdir -p А/Аб/Абр/Абра
```

because `mkdir -p` automatically creates the missing parent directories.

### Example

Run:

```bash
./build_shell_nested_authors.sh \
    --input-file=authors_list_from_db.txt \
    --min-authors=10 \
    --max-prefix=5
```

Where:

- `--input-file` specifies the author list.
- `--min-authors` specifies the minimum number of authors required for a prefix.
- `--max-prefix` specifies the maximum prefix length.

For example:

```bash
--min-authors=10
--max-prefix=5
```

means that a prefix must represent at least 10 authors to be considered valid, and prefixes longer than five characters are not considered.

### Save the generated commands

The output can be redirected to a file:

```bash
./build_shell_nested_authors.sh \
    --input-file=authors_list_from_db.txt \
    --min-authors=10 \
    --max-prefix=5 \
    > build_authors.sql
```

Review the generated file before executing it.

---

# 8. Step 5 — Recalculate Library Counts

After the database relationships have been populated, run:

```text
recalculate_library_counts.sql
```

This script recalculates derived book counters for:

- authors;
- genres;
- series.

The script operates on the `myprivatelib` database.

Execute it with:

```bash
mysql -u root -p < sql/recalculate_library_counts.sql
```

or:

```bash
mysql -u root -p myprivatelib < sql/recalculate_library_counts.sql
```

The script itself selects the destination database with:

```sql
USE myprivatelib;
```

Therefore the first form is sufficient.

---

## 9. What the Count Recalculation Does

For every author, genre, and series, the script calculates two values.

### `TotalCount`

The total number of associated books.

### `NormalCount`

The number of associated books whose:

```text
mlbook.deleted = '0'
```

In other words, `NormalCount` counts books that are not marked as deleted.

Records without associated books receive:

```text
TotalCount  = 0
NormalCount = 0
```

The counters are **recalculated from the actual relationships**.

They are not incremented or decremented from their previous values.

This is important because the script can safely rebuild the counters after a large import or data correction.

---

# 10. Verify the Recalculated Counts

After running:

```bash
mysql -u root -p myprivatelib
```

check several records.

For authors:

```sql
SELECT
    authorid,
    TotalCount,
    NormalCount
FROM mlauthorname
LIMIT 20;
```

For genres:

```sql
SELECT
    genreid,
    TotalCount,
    NormalCount
FROM mlgenrename
LIMIT 20;
```

For series:

```sql
SELECT
    seqid,
    TotalCount,
    NormalCount
FROM mlseqname
LIMIT 20;
```

---

# 11. Verify the Counts Against the Source Relationships

For an author, the calculated count can be independently checked with:

```sql
SELECT
    a.authorid,
    COUNT(*) AS TotalCount,
    SUM(b.deleted = '0') AS NormalCount
FROM mlauthor AS a
JOIN mlbook AS b
    ON b.bookid = a.bookid
GROUP BY a.authorid;
```

The resulting values should agree with the corresponding values in `mlauthorname`.

The same principle applies to genres and series.

---

# 12. Recommended Complete Execution Order

For a clean import, use this general sequence:

```text
1. Prepare source data
       |
       v
2. Create destination database
       |
       v
3. Create destination tables
       |
       v
4. Import base book data
       |
       v
5. Import authors
       |
       v
6. Import genres
       |
       v
7. Import series
       |
       v
8. Build auxiliary/nested structures
       |
       v
9. Recalculate derived counters
       |
       v
10. Verify the resulting database
```

**The exact script names for steps 2–8 must be taken from the current project version.**

Do not substitute scripts from an older project version without checking their dependencies.

---

# 13. Important Rule — Do Not Recalculate Counts Too Early

`recalculate_library_counts.sql` must be run **after the relationship tables have been populated**.

For example, running it before `mlgenre` has been imported will produce incorrect genre counters.

Likewise, running it before `mlauthor` or `mlseq` is populated will produce incomplete author or series counters.

If additional book relationships are imported later, run the count-recalculation script again.

---

# 14. Repeating the Operation

The count-recalculation script is safe to run again after the underlying data changes.

For example:

```bash
mysql -u root -p myprivatelib < sql/recalculate_library_counts.sql
```

can be executed after:

- importing additional books;
- correcting book relationships;
- changing the deleted status of books;
- rebuilding author relationships;
- rebuilding genre relationships;
- rebuilding series relationships.

The counters will be rebuilt from the current database contents.

---

# 15. Troubleshooting

## Database does not exist

Check:

```sql
SHOW DATABASES;
```

Create the database if necessary:

```sql
CREATE DATABASE myprivatelib;
```

---

## Required table does not exist

Check:

```sql
USE myprivatelib;
SHOW TABLES;
```

If a required table is missing, stop the workflow.

Do not attempt to repair the missing table by modifying a later script. Run the earlier schema/import step that creates it.

---

## Counts are zero

First verify that the relationship tables contain data:

```sql
SELECT COUNT(*) FROM mlauthor;
SELECT COUNT(*) FROM mlgenre;
SELECT COUNT(*) FROM mlseq;
```

Then verify that the relationship records reference existing books:

```sql
SELECT COUNT(*)
FROM mlauthor AS a
JOIN mlbook AS b
    ON b.bookid = a.bookid;
```

If these queries return zero, the problem is with the imported relationships, not with the count-recalculation script.

---

## `NormalCount` is lower than `TotalCount`

This is expected when some books are marked as deleted.

Check:

```sql
SELECT deleted, COUNT(*)
FROM mlbook
GROUP BY deleted;
```

`NormalCount` includes only records where:

```sql
deleted = '0'
```

---

# 16. Recommended Backup

Before performing a large import or rebuilding database structures, create a database backup.

Example:

```bash
mysqldump -u root -p myprivatelib > myprivatelib_backup.sql
```

Verify that the backup file was created:

```bash
ls -lh myprivatelib_backup.sql
```

Do not overwrite your only known-good backup.

---

# 17. Final Verification

After all scripts have completed successfully, perform a basic sanity check:

```sql
USE myprivatelib;

SELECT COUNT(*) FROM mlbook;
SELECT COUNT(*) FROM mlauthor;
SELECT COUNT(*) FROM mlgenre;
SELECT COUNT(*) FROM mlseq;
```

Then inspect the calculated counters:

```sql
SELECT COUNT(*)
FROM mlauthorname
WHERE TotalCount < 0
   OR NormalCount < 0;
```

```sql
SELECT COUNT(*)
FROM mlgenrename
WHERE TotalCount < 0
   OR NormalCount < 0;
```

```sql
SELECT COUNT(*)
FROM mlseqname
WHERE TotalCount < 0
   OR NormalCount < 0;
```

All three queries should return:

```text
0
```

---

# 18. Important Notes

- Always use the scripts from the same project version.
- Do not mix SQL scripts from different revisions unless their compatibility has been verified.
- Keep the original source data unchanged.
- Back up the destination database before a major import.
- Run relationship-building scripts before recalculating aggregate counters.
- Run `recalculate_library_counts.sql` only after all relevant relationships have been populated.
- If data is imported or modified after count recalculation, run the recalculation again.
- Review generated SQL files before executing them when a script produces SQL as output.

---

# 19. Quick Reference

### Import an SQL file

```bash
mysql -u root -p myprivatelib < sql/script.sql
```

### Generate nested author directories

```bash
./build_shell_nested_authors.sh \
    --input-file=authors_list_from_db.txt \
    --min-authors=10 \
    --max-prefix=5
```

### Recalculate library counters

```bash
mysql -u root -p myprivatelib \
    < sql/recalculate_library_counts.sql
```

### Check database size/content

```sql
USE myprivatelib;

SELECT COUNT(*) FROM mlbook;
SELECT COUNT(*) FROM mlauthor;
SELECT COUNT(*) FROM mlgenre;
SELECT COUNT(*) FROM mlseq;
```

---

## 20. Summary

The most important rule is:

> **Populate the database first. Recalculate derived data last.**

The import workflow should therefore finish by rebuilding all counters and other derived structures from the final database contents.

This guarantees that `TotalCount` and `NormalCount` represent the actual current state of the library rather than values left over from an earlier import.