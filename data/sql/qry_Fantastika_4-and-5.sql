-- Фантастика family, rated 4 & 5
--
-- Authors of Russian books rated 4/5 whose genre belongs to the
-- "Фантастика" family of the genre tree.  The family root is the
-- mlgenrename row genrenamerus = 'Фантастика' (genreid 1000022,
-- parentgenreid NULL); its children (sf, sf_action, sf_space,
-- foreign_sf, nsf, sf_su, ...) link via parentgenreid.  This is the
-- faithful translation of the old Access query
-- ([Genres].[ParentCode] = "0.17") into the current ml* schema.
-- Thresholds match qry_authors_4_and_5_all.sql
-- (TotalCount >= 10, NormalCount > 6).
--
SELECT DISTINCT
        CONCAT(a_name.LastName, ' ', a_name.FirstName, ' ', a_name.MiddleName) AS CompleteName
FROM mlgenrename gname,
     mlrating r,
     mlgenre g,
     mlbook b,
     mlauthor a,
     mlauthorname a_name
WHERE g.genreid = gname.genreid
  AND g.bookid = b.bookid
  AND g.bookid = r.bookid
  AND a.bookid = b.bookid
  AND a_name.authorid = a.authorid
  AND a_name.TotalCount >= 10
  AND a_name.NormalCount > 6
  AND r.rating IN ('4', '5')
  AND b.lang = 'ru'
  AND gname.parentgenreid =
      (SELECT genreid FROM mlgenrename WHERE genrenamerus = 'Фантастика' AND parentgenreid IS NULL)
ORDER BY 1;