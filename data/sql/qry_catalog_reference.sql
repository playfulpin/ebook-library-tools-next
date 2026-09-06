-- +-----------------------------------------------
-- |
-- |  Quick-reference lookups against the ml* catalog
-- |  (doc: docs/MultiLib_Flibusta_DB.md section 9.6).
-- |
-- |  Run against the default database, e.g.
-- |      mysql ... flibusta < data/sql/qry_catalog_reference.sql
-- |  (or point MYSQL_DATABASE at myprivatelib to inspect the
-- |  personal library instead - the queries are unqualified).
-- |
-- |  The whole file is one self-contained script: queries
-- |  A and D run as-is; B and C read @title / @md5 session
-- |  variables, so edit the SET value or override it in
-- |  your mysql client before the query runs.
-- |
-- +-----------------------------------------------


-- ---------------------------------------------------------------------------
-- A. Genre tree roots and their child counts
--    (mlgenrename is a 2-level tree: 24 root category rows with
--    EMPTY genrecode + 272 leaf genres whose parentgenreid points
--    at a root; books join only the leaf genres.)
-- ---------------------------------------------------------------------------
SELECT gn.genreid,
       gn.genrenamerus,
       (SELECT COUNT(*)
          FROM mlgenrename ch
         WHERE ch.parentgenreid = gn.genreid) AS children
  FROM mlgenrename gn
 WHERE gn.parentgenreid IS NULL
 ORDER BY children DESC;

-- ---------------------------------------------------------------------------
-- B. Everything about one book (title + authors + genres + series + rating)
--    Edit the SET to the title you are looking for.
-- ---------------------------------------------------------------------------
SET @title = 'Первое дело';

SELECT b.bookid,
       b.title,
       b.filename,
       b.arcname,
       b.filesize,
       b.deleted,
       an.FullName,
       gn.genrenamerus,
       sn.seqname,
       s.seqnum,
       r.rating
  FROM mlbook b
  LEFT JOIN mlauthor a      ON a.bookid = b.bookid
  LEFT JOIN mlauthorname an ON an.authorid = a.authorid
  LEFT JOIN mlgenre g       ON g.bookid = b.bookid
  LEFT JOIN mlgenrename gn  ON gn.genreid = g.genreid
  LEFT JOIN mlseq s         ON s.bookid = b.bookid
  LEFT JOIN mlseqname sn    ON sn.seqid = s.seqid
  LEFT JOIN mlrating r      ON r.bookid = b.bookid
 WHERE b.title = @title;

-- ---------------------------------------------------------------------------
-- C. md5 lookup (the populate matcher: file content hash -> bookid)
--    Edit the SET to the md5 you are looking for.
-- ---------------------------------------------------------------------------
SET @md5 = '';

SELECT bookid,
       title,
       filename,
       ext,
       deleted
  FROM mlbook
 WHERE md5 = @md5;

-- ---------------------------------------------------------------------------
-- D. Column parity of one managed table between the two libraries
--    (flibusta vs myprivatelib; the populate tool aborts on any
--    mismatch before TRUNCATE).  Edit the SET to check another
--    managed table (mlauthorname, mlgenrename, mlseqname, mlbook,
--    mlauthor, mlgenre, mlseq, mlrating, mlcustinfo).
-- ---------------------------------------------------------------------------
SET @tbl = 'mlbook';

SELECT TABLE_SCHEMA AS db,
       GROUP_CONCAT(COLUMN_NAME ORDER BY ORDINAL_POSITION) AS columns
  FROM information_schema.COLUMNS
 WHERE TABLE_SCHEMA IN ('flibusta', 'myprivatelib')
   AND TABLE_NAME = @tbl
 GROUP BY TABLE_SCHEMA;
