The MultiLib application still does not accept or work correctly with our uploaded schema `privetelib`.

I believe I have found the source of the problem.

For some reason, our generated schema is still modifying or interfering with the predefined relationships between tables. In particular, it appears that the `AUTO_INCREMENT` attribute on certain primary-key columns may be causing MultiLib to treat these columns differently from the original database schema.

As a workaround, I want to remove the `AUTO_INCREMENT` attribute from the corresponding columns in the `CREATE TABLE` statements for **ALL TABLES**.

For example, the original table definition is:

```sql
CREATE TABLE `mlbook` (
  `bookid` INT(11) NOT NULL AUTO_INCREMENT,
  `library` VARCHAR(64) NOT NULL DEFAULT '' COLLATE 'utf8_general_ci',
  `title` VARCHAR(255) NOT NULL DEFAULT '' COLLATE 'utf8_general_ci',
  ...
```

Our generated code currently produces:

```sql
CREATE TABLE `mlbook` (
  `bookid` INT(11) NOT NULL,
  `library` VARCHAR(64) NOT NULL DEFAULT '' COLLATE 'utf8_general_ci',
  `title` VARCHAR(255) NOT NULL DEFAULT '' COLLATE 'utf8_general_ci',
  ...
```

In other words, the only change required here is to **omit `AUTO_INCREMENT`** from the column definition. Everything else in the column definition should remain unchanged.

This change must be applied consistently to the following table/column combinations:

```text
+----------------+-------------+
| TABLE_NAME     | COLUMN_NAME |
+----------------+-------------+
| mlauthor       | la_id       |
| mlauthorname   | authorid    |
| mlbook         | bookid      |
| mlcoverpage    | cp_id       |
| mlcustinfo     | ci_id       |
| mldescription  | ds_id       |
| mldownloaddata | dd_id       |
| mlgenre        | gn_id       |
| mlgenrename    | genreid     |
| mlnews         | cb_id       |
| mlnewsname     | critid      |
| mlrating       | rt_id       |
| mlseq          | sq_id       |
| mlseqname      | seqid       |
| mluserkeyword  | kw_id       |
| mluserprim     | up_id       |
+----------------+-------------+
```

Please make sure that:

1. `AUTO_INCREMENT` is removed from these specified columns in the generated `CREATE TABLE` statements.
2. No other column attributes are changed as part of this modification.
3. The existing primary keys and other predefined relationships remain intact.
4. The change is applied consistently to **all** affected tables, rather than only to `mlbook`.
5. Any code, SQL-generation logic, configuration, examples, tests, or other project files that depend on the old behavior are updated accordingly.

### Schema name change

I also want to rename the schema throughout the project.

Change:

```text
privetelib
```

to:

```text
myprivatelib
```

This is a global schema-name change. Please propagate it throughout **all corresponding project documentation and related files**, including SQL examples, configuration files, README/documentation, scripts, comments, test data, and any other places where the old schema name is referenced.

The final result should consistently use `myprivatelib` everywhere and should not leave stale references to `privetelib` behind.
