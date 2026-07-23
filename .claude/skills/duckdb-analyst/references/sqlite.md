# SQLite (.db / .sqlite)

Setup once per CLI session:

```sql
INSTALL sqlite_scanner;
LOAD sqlite_scanner;
```

## Attach the database file

Unlike CSV/JSON/Parquet, a SQLite file isn't a single table — it's a whole
database with its own tables. `ATTACH` it under an alias, then query tables
through that alias:

```sql
ATTACH 'data/app.sqlite' AS app (TYPE sqlite);

SHOW ALL TABLES;                 -- see every table across attached DBs, with schema
SELECT * FROM app.users LIMIT 5;
```

`SHOW ALL TABLES` after attaching is the equivalent of `DESCRIBE`/`SUMMARIZE`
for the other formats here — it's the cheap first look that tells you what
tables exist and their columns before you write a real query. Run
`SUMMARIZE SELECT * FROM app.<table>` for per-column stats on a specific
table once you know which one you need.

## Joins across attached tables

Once attached, tables behave like any other DuckDB table — join across
multiple tables in the same SQLite file, or even join a SQLite table to a
CSV/Parquet file in the same query, with a normal `JOIN ... ON`.

## Read-only by default expectation

Treat an attached SQLite file as a read source unless the user has
specifically asked to write results back into it. If asked to persist a
result, `INSERT INTO app.<table> ...` or `CREATE TABLE app.<new_table> AS
SELECT ...` both work against the attached alias — but confirm this is
what's wanted, since it mutates the original file rather than an in-memory
copy.