-- -----------------------------------------------------------------------------
-- Title: Recalculate Library Counts
-- Script Name: rebuild_library_statistics.sql
-- Description:
--   Recalculates derived book-count fields in the `myprivatelib` schema.
--
--   The script updates the following entities:
--     - Authors: total books and non-deleted books
--     - Genres:  total books and non-deleted books
--     - Series:  total books and non-deleted books
--
--   For each entity, TotalCount contains the total number of associated books.
--   NormalCount contains the number of associated books where `mlbook.deleted`
--   is '0'.
--
--   The counts are calculated directly from the relationships between the
--   entity tables and `mlbook`. Existing counter values are therefore
--   completely recalculated rather than incremented or decremented.
--
--   Entities without associated books are explicitly assigned zero counts.
--
--   This logic follows the original Flibusta conversion implementation:
--     lib.convert.sql, line 152
--
-- Database: myprivatelib
-- -----------------------------------------------------------------------------

USE myprivatelib;

-- -----------------------------------------------------------------------------
-- Recalculate Author Book Counts
-- -----------------------------------------------------------------------------
-- Rebuild TotalCount and NormalCount for every author.
--
-- TotalCount:
--   Number of books associated with the author.
--
-- NormalCount:
--   Number of associated books that are not marked as deleted.
--
-- Authors without associated books receive zero for both counters.
-- -----------------------------------------------------------------------------

UPDATE mlauthorname AS n
LEFT JOIN (
    SELECT a.authorid,
           COUNT(*) AS TotalCount,
           SUM(b.deleted = '0') AS NormalCount
    FROM mlauthor AS a
    JOIN mlbook AS b ON b.bookid = a.bookid
    GROUP BY a.authorid
) AS c ON c.authorid = n.authorid
SET n.TotalCount  = COALESCE(c.TotalCount, 0),
    n.NormalCount = COALESCE(c.NormalCount, 0);

-- -----------------------------------------------------------------------------
-- Recalculate Genre Book Counts
-- -----------------------------------------------------------------------------
-- Rebuild TotalCount and NormalCount for every genre.
--
-- TotalCount:
--   Number of books associated with the genre.
--
-- NormalCount:
--   Number of associated books that are not marked as deleted.
--
-- Genres without associated books receive zero for both counters.
-- -----------------------------------------------------------------------------

UPDATE mlgenrename AS n
LEFT JOIN (
    SELECT g.genreid,
           COUNT(*) AS TotalCount,
           SUM(b.deleted = '0') AS NormalCount
    FROM mlgenre AS g
    JOIN mlbook AS b ON b.bookid = g.bookid
    GROUP BY g.genreid
) AS c ON c.genreid = n.genreid
SET n.TotalCount  = COALESCE(c.TotalCount, 0),
    n.NormalCount = COALESCE(c.NormalCount, 0);

-- -----------------------------------------------------------------------------
-- Recalculate Series Book Counts
-- -----------------------------------------------------------------------------
-- Rebuild TotalCount and NormalCount for every series.
--
-- TotalCount:
--   Number of books associated with the series.
--
-- NormalCount:
--   Number of associated books that are not marked as deleted.
--
-- Series without associated books receive zero for both counters.
-- -----------------------------------------------------------------------------

UPDATE mlseqname AS n
LEFT JOIN (
    SELECT s.seqid,
           COUNT(*) AS TotalCount,
           SUM(b.deleted = '0') AS NormalCount
    FROM mlseq AS s
    JOIN mlbook AS b ON b.bookid = s.bookid
    GROUP BY s.seqid
) AS c ON c.seqid = n.seqid
SET n.TotalCount  = COALESCE(c.TotalCount, 0),
    n.NormalCount = COALESCE(c.NormalCount, 0);