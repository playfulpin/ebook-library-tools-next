# Find All Related Tables and Fields for a Given Book ID

**Example book ID:** `578275`

---

## Goal

We want to find **every table and every field** in the database that contains a specific book ID.  
In this example the book ID is **578275**.

There are three different ways to do this:

1. Automatic method (using a stored procedure)
2. Semi-automatic method (using mysqldump)
3. Fully manual method (looking table by table yourself)

---

## Method 1: Automatic Search with a Stored Procedure

This is the fastest way. You create a helper once, then just call it whenever you need.

### How to use it

```sql
CALL SearchAllTables('578275');
```

### Full code to create the helper

```sql
DROP PROCEDURE IF EXISTS SearchAllTables;

DELIMITER //

CREATE PROCEDURE SearchAllTables(IN search_val VARCHAR(255))
BEGIN
    DECLARE done INT DEFAULT FALSE;
    DECLARE tbl_name VARCHAR(255);
    DECLARE col_name VARCHAR(255);
    
    -- This part gets the list of all tables and columns in the database
    DECLARE col_cursor CURSOR FOR 
        SELECT TABLE_NAME, COLUMN_NAME 
        FROM information_schema.COLUMNS 
        WHERE TABLE_SCHEMA = 'your_database_name'  -- ← CHANGE THIS to your real database name (probably 'flibusta')
          AND DATA_TYPE IN ('varchar', 'char', 'text', 'int', 'bigint', 'tinyint'); -- You can add more types if needed
          
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

    -- Temporary place to store the results
    DROP TEMPORARY TABLE IF EXISTS search_results;
    CREATE TEMPORARY TABLE search_results (
        table_name VARCHAR(255),
        column_name VARCHAR(255),
        matched_value TEXT
    );

    OPEN col_cursor;

    read_loop: LOOP
        FETCH col_cursor INTO tbl_name, col_name;
        IF done THEN
            LEAVE read_loop;
        END IF;

        -- Build and run a search for the current table + column
        SET @sql = CONCAT(
            'INSERT INTO search_results (table_name, column_name, matched_value) ',
            'SELECT \'', tbl_name, '\', \'', col_name, '\', `', col_name, '` ',
            'FROM `', tbl_name, '` ',
            'WHERE `', col_name, '` LIKE CONCAT(\'%\', ?, \'%\')'
        );
        
        SET @search_param = search_val;
        PREPARE stmt FROM @sql;
        EXECUTE stmt USING @search_param;
        DEALLOCATE PREPARE stmt;
    END LOOP;

    CLOSE col_cursor;

    -- Show the final results
    SELECT DISTINCT table_name, column_name, matched_value 
    FROM search_results;
    
    DROP TEMPORARY TABLE search_results;
END //

DELIMITER ;
```

**Important reminder:**  
Before running this, change `'your_database_name'` to the real name of your database (most likely `flibusta`).

---

## Method 2: Using mysqldump (quick search under WSL2)

This method dumps the whole database into text and then searches for the number.

```bash
mysqldump -h 127.0.0.1 --protocol=TCP -P 3306 -u root flibusta --skip-extended-insert | grep "578275"
```

This is useful when you just want a fast overview of where the number appears.

---

## Method 3: Fully Manual Approach (recommended if you want full control)

This is the slowest but safest method. You look at the database table by table yourself.

### Step-by-step instructions

1. **Connect to the database**
   ```bash
   mysql -h 127.0.0.1 --protocol=TCP -P 3306 -u root flibusta
   ```

2. **See the list of all tables**
   ```sql
   SHOW TABLES;
   ```

3. **Look at the structure of one table**
   ```sql
   DESCRIBE table_name;
   ```
   or
   ```sql
   SHOW COLUMNS FROM table_name;
   ```

4. **Search for the book ID in a specific column**
   ```sql
   SELECT * FROM table_name WHERE column_name = 578275;
   ```
   or (if the column is text)
   ```sql
   SELECT * FROM table_name WHERE column_name LIKE '%578275%';
   ```

5. **Repeat** steps 3 and 4 for every table that looks related to books.

6. **Helpful extra command** – get a list of columns that might contain book IDs:
   ```sql
   SELECT TABLE_NAME, COLUMN_NAME 
   FROM information_schema.COLUMNS 
   WHERE TABLE_SCHEMA = 'flibusta' 
     AND (COLUMN_NAME LIKE '%book%' 
       OR COLUMN_NAME LIKE '%id%' 
       OR COLUMN_NAME LIKE '%lib%')
   ORDER BY TABLE_NAME;
   ```

---

## Useful MySQL Commands

### Start an interactive MySQL session (under WSL2)

```bash
mysql -h 127.0.0.1 --protocol=TCP -P 3306 -u root flibusta
```

### Run a whole .sql file from the command line

```bash
mysql -h 127.0.0.1 --protocol=TCP -P 3306 -u root flibusta < /path/to/your/file.sql
```

### Run a .sql file while you are already inside MySQL

```sql
USE database_name;
SOURCE /path/to/your/file.sql;
```

---

## Official Documentation (RTFM)

[MySQL Batch Commands Documentation](https://dev.mysql.com/doc/refman/9.7/en/mysql-batch-commands.html)
