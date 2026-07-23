# CLAUDE.md

Project context for AI coding agents (Claude Code) working in this repository.

> IMPORTANT: Everything in this repo is public-facing. Do not place any sensitive
> information here. Anything that must persist across sessions but should not be
> published (personal config, operational notes) goes in the `.internal/` folder,
> which is ignored by git via `.gitignore`. Do not proactively read `.internal/`
> files other than `OWNER_CONFIG.md`.

## Project overview

This project explores a folder of large small-parcel-shipment CSV files with
DuckDB, driven from the terminal. The data is a shipment history split into
monthly files, plus a small customers lookup file (with a parent/child
hierarchy) and a products lookup file. The goal is to answer real analytical
questions (revenue and margin by carrier/customer/product, trends across
months, rollups through the customer hierarchy) by querying the raw files
directly, with the SQL written by an AI agent and verified by a human reading
it. The dataset is also intentionally large (hundreds of MB per monthly file)
to demonstrate that DuckDB handles this comfortably without a warehouse.

There is no database server, no warehouse, and no import step. DuckDB queries the
CSV files in place. The only thing that needs to exist before you start is the
`data/` folder, which is committed to the repo (and regenerable via
`scripts/generate_data.rb`).

Tech stack: DuckDB CLI (local, in-process), the `duckdb` command run through the
Bash tool, Ruby standard library (no gems) for the data generator.

General DuckDB workflow, token hygiene, and multi-format read syntax
(CSV/JSON/Parquet/Excel/SQLite/Avro/spatial/S3/HTTPS) live in the
`duckdb-analyst` skill (`.claude/skills/duckdb-analyst/`) — that applies to
any data file, not just this project's. Everything below is what's specific
to *this* dataset.

## Data

All files live in `data/`. The file IS the table, so put the path straight in a
SQL `FROM` clause.

`data/shipments_2026_01.csv` through `data/shipments_2026_06.csv` (one per month,
Jan-Jun 2026, ~300MB / ~2.7M rows each by default):

| column | type | notes |
|---|---|---|
| customer_id | int | joins to `customers.csv` (`id`) |
| product_id | int | joins to `products.csv` (`id`) |
| shipped_at | timestamp, `M/D/YYYY H:MM:SS` | see date-parsing gotcha below |
| parcel_transaction_id | int | unique across all six files |
| carrier | text | USPS / UPS / FedEx / DHL |
| service_level | text | Ground / Priority / Express / First Class |
| origin_zip | text (5-digit) | |
| destination_zip | text (5-digit) | |
| zone | int | 1 to 8 |
| weight_oz | decimal | |
| tracking_number | text | carrier prefix + digits |
| customer_cost | decimal | what the customer paid — this **is** the revenue |
| nsa_cost | decimal | carrier/postage cost |
| gross_margin | decimal | `customer_cost - nsa_cost` |
| net_margin | decimal | gross margin after overhead, already computed |
| delivery_status | text | Delivered / In Transit / Exception / Returned |

`data/customers.csv`: `id`, `ancestry`, `name`. `ancestry` is a materialized path
(same convention as the Ruby `ancestry` gem): blank for a root/top-level
customer, otherwise a `/`-separated chain of ancestor ids, e.g. `1/5` means id 5
is a direct child of root id 1. Up to 3 levels deep.

`data/products.csv`: `id`, `name`, `category` (Electronics / Home / Apparel /
Outdoors) — what's inside the parcel.

Key facts:
- **Revenue = `customer_cost`**, already computed per shipment row. Unlike a
  quantity/unit-price model, there is nothing to multiply — summing
  `customer_cost` directly is correct. `gross_margin` and `net_margin` are
  likewise already computed columns, not derived at query time.
- Join column names differ on purpose: shipments has `customer_id`/`product_id`,
  but the lookup files use `id`. `USING(customer_id)` will **not** match — join
  with an explicit `ON s.customer_id = c.id` / `ON s.product_id = p.id`.
- `ancestry` is only on `customers.csv`; rolling up a customer and all its
  descendants means matching the lookup file's `id` or a `/`-prefixed
  `ancestry`, then joining that set of ids back to shipments — see Conventions
  below for the pattern.
- **Date-parsing gotcha:** DuckDB's CSV sniffer only samples the leading rows of
  a file to guess `shipped_at`'s date format. The generator deliberately keeps
  the first ~25,000 rows of `shipments_2026_02.csv` through `shipments_2026_06.csv`
  ambiguous (day ≤ 12), so the sniffer can lock in `d/m` instead of the correct
  `m/d` and later rows fail to convert. `shipments_2026_01.csv` is exempt and
  sniffs cleanly — use it as a known-good baseline. If a query on `shipped_at`
  errors or looks wrong on the other files, pass an explicit format:
  `read_csv('data/shipments_2026_02.csv', timestampformat='%m/%d/%Y %H:%M:%S')`.

## Available tools

If the official [`duckdb-skills`](https://github.com/duckdb/duckdb-skills) plugin is
installed, its `query`, `read-file`, and `attach-db` skills are the recommended way
to drive DuckDB from a plain-English question. It is a wrapper over the same DuckDB
CLI, so the `duckdb-analyst` skill's conventions still hold: query the files
directly, prefer a glob for multi-file questions, and always surface the SQL that
runs so it can be read and checked. The plugin writes its state under
`.duckdb-skills/` (git-ignored).

## Conventions specific to this dataset

- **Revenue is `customer_cost`**, already computed per row. Do not multiply it by
  anything; summing it directly is correct. `gross_margin`/`net_margin` are
  likewise already-computed columns.
- **Join with explicit `ON`, not `USING`.** Column names differ across files
  (`shipments.customer_id` / `products.product_id` vs `customers.id` /
  `products.id`), so `USING(...)` won't match: write
  `JOIN 'data/customers.csv' c ON s.customer_id = c.id` and
  `JOIN 'data/products.csv' p ON s.product_id = p.id`.
- **Rolling up the customer hierarchy via `ancestry`:** to get one customer plus
  all of its descendants, match rows where `id = :customer_id` OR `ancestry =
  '<id>'` OR `ancestry LIKE '<id>/%'`, then join that set of ids back to
  shipments. To show just the direct parent's name for every customer, split
  `ancestry` on `/` and join the last segment back to `customers.id`.
- Round money to 2 decimals in final output (`ROUND(SUM(customer_cost), 2)`).

## Working principles

- Verify results before trusting them. Read the generated SQL line by line; a query
  can run clean and still answer the wrong question (wrong grain, missing filter,
  an `ancestry` rollup that only matched direct children instead of all
  descendants).
- When a query looks off, point at the specific line, correct it, and re-run rather
  than starting over.
- Keep the data files local. DuckDB reads them on the machine and nothing uploads
  the CSVs. The only thing that leaves is what the model call needs: the question,
  the schema, the SQL, and a small sample of result rows (which are real values).

## Regenerating the data

`ruby scripts/generate_data.rb [target_size_mb_per_file]` rewrites the `data/`
CSVs (default 300MB per monthly shipments file). It forks one process per month
to generate the large files in parallel; `customers.csv` and `products.csv` are
small and written up front. Not seeded, so re-running produces different row
values (but the same shape/size) each time.
