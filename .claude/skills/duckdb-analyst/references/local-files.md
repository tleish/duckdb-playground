# CSV / JSON / Parquet — no extension needed

These three are built into DuckDB. Reference the path directly, or use the
explicit read function when you need to pass options (delimiter, date
format, schema hints).

## CSV

```sql
-- bare path in FROM: DuckDB sniffs delimiter, header, and column types
SELECT * FROM 'data/orders.csv' LIMIT 5;

-- explicit function when you need options
SELECT * FROM read_csv('data/orders.csv', timestampformat='%m/%d/%Y %H:%M:%S');
```

The CSV sniffer only samples a file's leading rows to guess column types and
date formats. On a large file, or one where the early rows are ambiguous
(e.g. dates where day ≤ 12 could be `d/m` or `m/d`), it can lock in the
wrong format and later rows fail to convert or silently parse wrong. If a
date/timestamp column errors out or the values look off after `DESCRIBE`,
pass the format explicitly via `read_csv(..., timestampformat='...')` rather
than trusting the sniffer.

## JSON / NDJSON

```sql
SELECT * FROM read_json('data/events.ndjson');
SELECT * FROM read_json_auto('data/events.json');  -- format/shape auto-detected
```

`read_json` handles both newline-delimited JSON and a single JSON array of
objects. Nested objects/arrays become `STRUCT`/`LIST` columns — use
`DESCRIBE` first to see the shape before writing a query that assumes flat
columns.

## Parquet

```sql
SELECT * FROM 'data/events.parquet' LIMIT 5;
SELECT * FROM read_parquet('data/events_*.parquet');  -- glob across files
```

Parquet is already columnar and typed, so `DESCRIBE`/`SUMMARIZE` are
essentially free even on very large files — there's no reason to skip
checking the schema first.

## Multi-file glob (any of the three)

```sql
FROM 'data/shipments_*.csv'      -- all matching files as one table
FROM 'data/events_*.parquet'
```

Prefer a glob over `UNION ALL` across files — same result, less SQL to read
and verify.