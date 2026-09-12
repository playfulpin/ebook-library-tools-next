-- +-----------------------------------------------
-- |
-- |  Native wishlist views against mllbr_main + myprivatelib
-- |  (companion to bin/report_library.sh --native, v1.1;
-- |   doc: docs/NEXT.md, docs/archive/DO_IT_ongoing.md).
-- |
-- |  MultiLib.exe stores reading lists natively:
-- |      mllbr_main.mlgroupname  groupid, groupidparrent, groupname
-- |        (built-ins: 1 «Избранное», 2 «К прочтению», 3 «Прочитано»)
-- |      mllbr_main.mlgroup      uc_id, bookid, groupid,
-- |                              library, date_gr
-- |  The library column scopes rows per registered library; the
-- |  queries below filter on @library (SET it before running, or
-- |  edit the default).
-- |
-- |  Run standalone:
-- |      mysql ... -e "SET @library='myprivatelib'" myprivatelib \
-- |          < data/sql/qry_wishlist_native.sql
-- |  (or run from inside a mysql session after SET @library).
-- |
-- +-----------------------------------------------


-- ---------------------------------------------------------------------------
-- A. Which groups exist and how many books each holds (our library only)
-- ---------------------------------------------------------------------------
SELECT gn.groupid,
       gn.groupname,
       COUNT(g.bookid) AS books
FROM mllbr_main.mlgroupname gn
LEFT JOIN mllbr_main.mlgroup g
       ON g.groupid = gn.groupid
      AND g.library = @library
GROUP BY gn.groupid, gn.groupname
HAVING COUNT(g.bookid) > 0
ORDER BY gn.groupid;


-- ---------------------------------------------------------------------------
-- B. Wishlist by title (alphabetical within each group)
--    The corrected shape of the query from DO_IT_20260906_201455.md:
--    the book data lives in myprivatelib.mlbook (not "books"), and every
--    query MUST scope mllbr_main.mlgroup by the library column.
-- ---------------------------------------------------------------------------
SELECT gn.groupname            AS wishlist,
       b.bookid,
       b.title                 AS book_title,
       an.fullname             AS author,
       g.date_gr               AS added
FROM mllbr_main.mlgroup g
JOIN mllbr_main.mlgroupname gn ON gn.groupid = g.groupid
JOIN myprivatelib.mlbook b     ON b.bookid  = g.bookid
LEFT JOIN myprivatelib.mlauthor a      ON a.bookid  = b.bookid
LEFT JOIN myprivatelib.mlauthorname an ON an.authorid = a.authorid
WHERE g.library = @library
ORDER BY gn.groupid, b.title;


-- ---------------------------------------------------------------------------
-- C. Wishlist by author (author -> their wished books)
-- ---------------------------------------------------------------------------
SELECT an.fullname            AS author,
       gn.groupname           AS wishlist,
       b.bookid,
       b.title                AS book_title,
       sq.seqnum              AS vol,
       sn.seqname             AS series,
       g.date_gr              AS added
FROM mllbr_main.mlgroup g
JOIN mllbr_main.mlgroupname gn ON gn.groupid = g.groupid
JOIN myprivatelib.mlbook b     ON b.bookid  = g.bookid
LEFT JOIN myprivatelib.mlauthor a      ON a.bookid  = b.bookid
LEFT JOIN myprivatelib.mlauthorname an ON an.authorid = a.authorid
LEFT JOIN myprivatelib.mlseq sq         ON sq.bookid = b.bookid
LEFT JOIN myprivatelib.mlseqname sn     ON sn.seqid = sq.seqid
WHERE g.library = @library
ORDER BY an.fullname, sn.seqname, sq.seqnum, b.title;


-- ---------------------------------------------------------------------------
-- D. Wishlist by series (series order, missing volumes visible as gaps
--    in the sequence numbers; other owned volumes of the same series
--    can be listed from myprivatelib directly - see qry_catalog_reference.sql)
-- ---------------------------------------------------------------------------
SELECT sn.seqname             AS series,
       sq.seqnum              AS vol,
       gn.groupname           AS wishlist,
       b.bookid,
       b.title                AS book_title,
       g.date_gr              AS added
FROM mllbr_main.mlgroup g
JOIN mllbr_main.mlgroupname gn ON gn.groupid = g.groupid
JOIN myprivatelib.mlbook b     ON b.bookid  = g.bookid
JOIN myprivatelib.mlseq sq             ON sq.bookid = b.bookid
JOIN myprivatelib.mlseqname sn         ON sn.seqid = sq.seqid
WHERE g.library = @library
ORDER BY sn.seqname, sq.seqnum;


-- ---------------------------------------------------------------------------
-- E. Assigned bookids missing from the library (wished before collected;
--    these have no mlbook row to join - listed raw)
-- ---------------------------------------------------------------------------
SELECT g.bookid,
       gn.groupname            AS wishlist,
       g.date_gr               AS added
FROM mllbr_main.mlgroup g
JOIN mllbr_main.mlgroupname gn ON gn.groupid = g.groupid
LEFT JOIN myprivatelib.mlbook b ON b.bookid = g.bookid
WHERE g.library = @library
  AND b.bookid IS NULL
ORDER BY g.bookid;
