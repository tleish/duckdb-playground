# Walkthrough: Exploring Shipment Data with DuckDB

This is a hands-on tour of the dataset, starting from the raw CSV files and
building up to joins, rollups, and pivots. Run each block in order — later
steps assume the data from `scripts/generate_data.rb` already exists.

## 1. Generate the sample data

Creates `data/customers.csv`, `data/products.csv`, and six monthly
`data/shipments_2026_*.csv` files (~300MB each by default).

```sh
ruby scripts/generate_data.rb
```

## 2. Read a CSV file directly — no import step

DuckDB reads the CSV file straight from disk; there's nothing to load first.

```sh
duckdb -c "SELECT * FROM 'data/customers.csv'"
```

The shipments files are much bigger, so a few more commands are worth trying:
a raw line count for comparison, DuckDB's own count, a peek at the first rows,
and the inferred schema.

```sh
cat data/shipments_2026_01.csv | wc -l
duckdb -c "SELECT COUNT(*) FROM 'data/shipments_2026_01.csv'"
duckdb -c "SELECT * FROM 'data/shipments_2026_01.csv' LIMIT 10"
duckdb -c "DESCRIBE 'data/shipments_2026_01.csv'"
duckdb -c "SUMMARIZE 'data/shipments_2026_01.csv'"

duckdb -c "SELECT * FROM 'data/shipments_2026_01.csv'"
```

## 3. Export query output to different formats

The same query works with different output formats depending on whether you
want it human-readable, scriptable, or pasted into another tool.

```sh
# default: a formatted table for reading in the terminal
duckdb -c "SELECT * FROM 'data/customers.csv'"

duckdb -csv -c "SELECT * FROM 'data/customers.csv'"
duckdb -json -c "SELECT * FROM 'data/customers.csv'"
duckdb -markdown -c "SELECT * FROM 'data/customers.csv'"
```

## 4. A CSV type-sniffing gotcha

`shipments_2026_01.csv` reads cleanly, but the second month does not:

```sh
duckdb -c "SELECT * FROM 'data/shipments_2026_02.csv'"
# ...
#=> Error when converting column "shipped_at". Could not convert string "02/26/2026 09:30:29" to 'TIMESTAMP'
```

DuckDB infers each column's type by sampling the first few thousand rows. In
January, those early rows happened to be ambiguous enough that it guessed the
timestamp format was `DD/MM/YYYY` instead of `MM/DD/YYYY`. That guess holds up
until it hits a day-of-month above 12 (`02/26/2026`), which can't be a day in
`DD/MM` — and the whole read fails.

A quick brute-force fix is to skip type inference entirely and treat every
column as text:

```sh
duckdb -c "SELECT * FROM read_csv('data/shipments_2026_01.csv', all_varchar=true)"
```

The better fix is to tell DuckDB the timestamp format up front so it never has
to guess:

```sh
duckdb -c "SELECT * FROM read_csv('data/shipments_2026_01.csv', timestampformat = '%m/%d/%Y %H:%M:%S')"
```

## 5. Combine multiple CSV files into one result

Once the date format is pinned down, the same trick lets you query several
months at once. DuckDB gives you three equivalent ways to do this.

**Array** — pass a list of paths to `read_csv`:
```sh
duckdb -c "SELECT * FROM read_csv(['data/shipments_2026_01.csv', 'data/shipments_2026_02.csv'], timestampformat = '%m/%d/%Y %H:%M:%S')"
```

**Union** — read each file separately and stack the results:
```sh
duckdb -c "SELECT * FROM 
           read_csv('data/shipments_2026_01.csv', timestampformat = '%m/%d/%Y %H:%M:%S')
           UNION ALL
           SELECT * FROM read_csv('data/shipments_2026_02.csv', timestampformat = '%m/%d/%Y %H:%M:%S')"
```

**Glob** — the simplest option when you want every matching file, present or
future:
```sh
duckdb -c "SELECT * FROM read_csv('data/shipments*.csv', timestampformat = '%m/%d/%Y %H:%M:%S')"
```

## 6. Work in the interactive CLI

So far every command has been a one-shot `duckdb -c "..."` from the shell.
For a series of related queries, it's more convenient to drop into DuckDB's
own REPL and keep typing SQL directly.

```sh
duckdb
```

```sql
SELECT COUNT(*) FROM 'data/shipments*.csv';
SELECT * FROM 'data/shipments*.csv' LIMIT 5;

SELECT COUNT(*) FROM 'data/shipments_2026_01.csv';
SELECT * FROM 'data/shipments_2026_01.csv';

SELECT * FROM read_csv(
    'data/shipments*.csv',
    timestampformat = '%m/%d/%Y %H:%M:%S'
);
```

## 7. Tables vs. views

Typing the full `read_csv(...)` glob with its timestamp format every time
gets old fast. DuckDB lets you name a query once and reuse that name for the
rest of the session — either as a **table** (data copied into memory) or a
**view** (just a saved query, re-read from disk each time).

A table materializes the data — useful for repeated heavy queries against a
session, but it's a snapshot and uses memory:

```sql
CREATE TABLE shipments AS SELECT * FROM read_csv(
        'data/shipments*.csv',
        timestampformat = '%m/%d/%Y %H:%M:%S');
DROP TABLE shipments;
```

A view is just a saved query — no data is copied, so it always reflects the
current CSV contents. This is the pattern the rest of this walkthrough uses:

```sql
CREATE VIEW shipments AS
SELECT *
FROM read_csv(
    'data/shipments*.csv',
    timestampformat = '%m/%d/%Y %H:%M:%S'
);
CREATE VIEW customers AS SELECT * FROM 'data/customers.csv';
CREATE VIEW products AS SELECT * FROM 'data/products.csv';

-- DROP VIEW shipments;
-- DROP VIEW customers;
-- DROP VIEW products;
```

With the views in place, `DESCRIBE` and `SUMMARIZE` become much easier to read.

### DESCRIBE: show the schema

```sql
DESCRIBE shipments;
DESCRIBE customers;
DESCRIBE products;
```

### SUMMARIZE: show basic stats

DuckDB computes basic statistics for **every column** and returns a table that
looks roughly like:

```sql
SUMMARIZE shipments;
```

## 8. Analytical queries

With the views set up, everything downstream reads like ordinary SQL over
ordinary tables — no more `read_csv` boilerplate. These examples build from a
plain count up to grouped aggregates and joins.

```sql
SELECT COUNT(*) FROM shipments;

SELECT s.* FROM shipments s
    JOIN customers c ON s.customer_id = c.id
WHERE c.name = 'Acme Logistics';

-- File size and date coverage
SELECT
  count(*) AS shipments,
  min(shipped_at) AS first_shipment,
  max(shipped_at) AS last_shipment
FROM shipments;

-- Financial totals
SELECT
    round(sum(customer_cost), 2) AS revenue,
    round(sum(nsa_cost), 2) AS postage_cost,
    round(sum(gross_margin), 2) AS gross_margin,
    round(sum(net_margin), 2) AS net_margin
FROM shipments;

-- Customer performance
SELECT
    c.name AS customer_name,
    count(*) AS shipments,
    round(sum(s.customer_cost), 2) AS revenue,
    round(sum(s.gross_margin), 2) AS gross_margin,
    round(sum(s.net_margin), 2) AS net_margin,
    round(100 * sum(s.net_margin) / nullif(sum(s.customer_cost), 0), 2)
        AS net_margin_pct
FROM shipments s
JOIN customers c ON s.customer_id = c.id
GROUP BY c.name
ORDER BY net_margin_pct DESC;

-- Carrier performance
SELECT
    carrier,
    count(*) AS shipments,
    round(avg(weight_oz), 1) AS avg_weight_oz,
    round(sum(customer_cost), 2) AS revenue,
    round(sum(net_margin), 2) AS net_margin,
    round(100 * sum(net_margin) / nullif(sum(customer_cost), 0), 2)
        AS net_margin_pct
FROM shipments
GROUP BY carrier
ORDER BY net_margin_pct DESC;

-- Delivery outcomes by customer, service level, and zone
SELECT
    c.name AS customer_name,
    s.service_level,
    s.zone,
    count(*) AS shipments,
    round(100.0 * sum(CASE WHEN s.delivery_status = 'Delivered' THEN 1 ELSE 0 END) / count(*), 1)
        AS delivered_pct,
    round(100.0 * sum(CASE WHEN s.delivery_status = 'Exception' THEN 1 ELSE 0 END) / count(*), 1)
        AS exception_pct
FROM shipments s
JOIN customers c ON s.customer_id = c.id
GROUP BY c.name, s.service_level, s.zone
ORDER BY c.name, s.service_level, s.zone;
```

## 9. Pivoting: revenue by customer and carrier

The same result — revenue broken down by customer and carrier — shown two
ways: first as long-format rows, then reshaped so each carrier is its own
column.

### Long format (`GROUP BY`)

```sql
SELECT
    c.name AS customer_name,
    s.carrier,
    COALESCE(ROUND(SUM(s.customer_cost), 2), 0) AS revenue
FROM shipments s
JOIN customers c ON s.customer_id = c.id
GROUP BY c.name, s.carrier
ORDER BY c.name, s.carrier;
```

### Wide format (`PIVOT`)

```sql
PIVOT (
    SELECT c.name AS customer_name, s.carrier, s.customer_cost
    FROM shipments s
    JOIN customers c ON s.customer_id = c.id
)
ON carrier
USING COALESCE(ROUND(SUM(customer_cost), 2)::VARCHAR, '0')
GROUP BY customer_name
ORDER BY customer_name;
```

## 10. Joining across all three files

Bringing `products` into the mix, plus using the `customers.ancestry` column
to walk the parent/child hierarchy.

```sql
-- Revenue by product category (what's actually in the parcels)
SELECT
    p.category,
    count(*) AS shipments,
    round(sum(s.customer_cost), 2) AS revenue
FROM shipments s
    JOIN products p ON s.product_id = p.id
GROUP BY p.category
ORDER BY revenue DESC;

-- Every customer alongside its direct parent's name (ancestry is a
-- materialized path, e.g. "1/5" -> the parent is id 5)
SELECT
    c.name AS customer_name,
    c.ancestry,
    parent.name AS parent_name
FROM customers c
LEFT JOIN customers parent
    ON parent.id = TRY_CAST(SPLIT_PART(c.ancestry, '/', -1) AS INTEGER)
ORDER BY c.id;

-- Rollup: total revenue for a top-level customer plus all of its descendants
-- (root id 1 = Acme Logistics; ancestry = '1' or ancestry LIKE '1/%' covers
-- every descendant regardless of depth)
SELECT
    round(sum(s.customer_cost), 2) AS revenue
FROM shipments s
JOIN customers c ON s.customer_id = c.id
WHERE c.id = 1 OR c.ancestry = '1' OR c.ancestry LIKE '1/%';

-- Three-way join: revenue by customer and product category
SELECT
    c.name AS customer_name,
    p.category,
    round(sum(s.customer_cost), 2) AS revenue
FROM shipments s
JOIN customers c ON s.customer_id = c.id
JOIN products p ON s.product_id = p.id
GROUP BY c.name, p.category
ORDER BY c.name, p.category;
```

## 11. DuckDB UI

Everything above works from the CLI, but DuckDB also ships a local web UI for
browsing tables and query history visually:

```sh
duckdb -ui
```
