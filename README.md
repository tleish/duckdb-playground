# Claude Code + DuckDB: Query Very Large CSV Files Without a Warehouse

Query a folder of CSV files in plain English, with no warehouse to set up and no
database to connect to. You ask the question, an AI agent writes the DuckDB SQL,
and you read every line so you actually trust the answer.

This repo is aimed at Ruby developers who haven't used DuckDB before. It ships a
mock small-parcel shipping dataset that's deliberately large (~1.8GB, 16M+ rows
across six monthly files) so you feel DuckDB handle a file size that would choke
Excel and make a naive Ruby CSV-parsing script crawl — plus two small lookup
files so you can practice joins.

## Why this exists

You have a pile of CSV files too big to comfortably open, the kind of size that
turns Excel sluggish and makes a plain `CSV.foreach` loop slow. The usual reflex
is to stand up a cloud warehouse, which means an account, a login, and a bill you
did not want.

DuckDB removes that step. It is an in-process analytical database (think SQLite,
but built for analytics) that queries CSV, Parquet, and JSON files directly on
your machine. There is no server to run and nothing to connect to. The file is
the table.

Pair it with Claude Code and you describe what you want in plain English. The
agent writes the SQL, runs it, and shows you both the query and the result. You
stay in control by reading the SQL, not by memorizing DuckDB's dialect first.

## Getting Started

You need three tools. Install them, then clone and verify.

| Tool | Version | Purpose |
|---|---|---|
| [Claude Code](https://claude.com/claude-code) | current | Writes and runs the SQL from plain-English prompts |
| [DuckDB CLI](https://duckdb.org/install) | 1.5.x | Runs the SQL locally against the CSV files. The plugin installs this if you do not have it |
| Ruby | 3.2+ | Only needed if you want to regenerate the sample data |

### 1. Install the DuckDB CLI

Pick the command for your OS/package manager from
[duckdb.org/install](https://duckdb.org/install) (e.g. `brew install duckdb` on
a Mac).

> **macOS note:** the latest release, 1.5.5, has known issues with the DuckDB UI
> (`duckdb -ui`) on macOS. If you plan to use the UI, install 1.4.5 instead — the
> install page lets you pick a specific version.

### 2. Clone the repo

```bash
git clone https://github.com/tleish/duckdb-playground.git
cd duckdb-playground
```

### 3. Generate large test csv files

```bash
ruby scripts/generate_data.rb
```

### 4. Run the tutorial

See [`TUTORIAL.md`](TUTORIAL.md) for a set of queries to run yourself that
walk through `DESCRIBE`/`SUMMARIZE`, views, and join patterns across all three
files — a good way to understand and validate how DuckDB behaves on this data
before asking Claude Code to write queries for you.

## The data

Everything lives in `data/`. The file IS the table, so put the path straight in a
SQL `FROM` clause.

| File | Columns | Notes |
|---|---|---|
| `shipments_2026_01.csv` … `shipments_2026_06.csv` | `customer_id`, `product_id`, `shipped_at`, `parcel_transaction_id`, `carrier`, `service_level`, `origin_zip`, `destination_zip`, `zone`, `weight_oz`, `tracking_number`, `customer_cost`, `nsa_cost`, `gross_margin`, `net_margin`, `delivery_status` | One file per month, January–June 2026, ~300MB / ~2.7M rows each by default |
| `customers.csv` | `id`, `ancestry`, `name` | 20 customers in a 3-level parent/child tree |
| `products.csv` | `id`, `name`, `category` | 20 products; category is Electronics, Home, Apparel, or Outdoors |

Things worth knowing:

- **Revenue is `customer_cost`**, already computed per shipment row — no
  quantity to multiply by, summing it directly is correct. `gross_margin` and
  `net_margin` are likewise already-computed columns.
- **Join column names differ on purpose.** Shipments has `customer_id` /
  `product_id`; the lookup files use plain `id`. `USING(...)` won't match —
  join with an explicit `ON s.customer_id = c.id`.
- **`customers.csv` is a tree, not a flat list.** `ancestry` is a materialized
  path (same convention as the Ruby `ancestry` gem): blank for a top-level
  customer, otherwise a `/`-separated chain of ancestor ids, e.g. `1/5` means
  id 5 is a direct child of root id 1.
- **Date-parsing gotcha:** DuckDB's CSV sniffer only samples a file's leading
  rows to guess `shipped_at`'s date format. Every file but the first
  deliberately keeps its first ~25,000 rows ambiguous (day ≤ 12), so the
  sniffer can lock in the wrong format and later rows fail to convert. If a
  query on `shipped_at` errors, pass an explicit format:
  `read_csv('data/shipments_2026_02.csv', timestampformat='%m/%d/%Y %H:%M:%S')`.

See `TUTORIAL.md` for a longer walkthrough of `DESCRIBE`/`SUMMARIZE`, views, and
join patterns across all three files.

## Try it yourself

The point is to ask in plain English and let the agent write the SQL. Open Claude
Code in this folder and try these, in order:

1. **"How many shipments are in the January file, and what's the total revenue?"**
   Reads `data/shipments_2026_01.csv` directly. The file is the table, no import
   step, and it's a ~300MB file — DuckDB doesn't care.

2. **"Now answer that across all six monthly files."**
   Uses a glob, `FROM 'data/shipments_*.csv'`, so the whole folder becomes one
   table.

3. **"Give me revenue by carrier and by product category."**
   Joins the shipments glob to `products.csv` on `product_id`.

4. **"Show me revenue for [a customer] rolled up with all of its child
   customers."**
   Uses `customers.ancestry` to find a customer's full subtree, then joins that
   back to shipments — the one query in this walkthrough that needs the
   hierarchy, not just a flat lookup.

Read the SQL it writes each time. A query can run clean and still be wrong (a
dropped filter, the wrong grain, an `ancestry` rollup that only matched direct
children). Reading the SQL is how you catch that, and it is also how you pick up
DuckDB's dialect without studying it.

## Challenge

`scripts/challenge/CHALLENGE.md` is a self-contained exercise once you're
comfortable with the basics: for every shipment, find the previous shipment for
that same customer and compare costs. It's a good excuse to learn DuckDB's
window functions (`LAG`), which don't have a direct Ruby-Enumerable analogue.

## The honest boundary

Your data files stay on your laptop. They are never uploaded. What does leave is
the question you typed, your schema (column names), the SQL the agent writes, and
a small sample of result rows so the agent can check its work. Those result rows
are real values from your data, so this is not fully private, and every question
is tokens, so it is cheap but not free. If you need fully offline, point the agent
at a local model and trade some quality to keep everything on your machine.

This earns a permanent spot for the everyday question you would otherwise spin up
a warehouse for. It is for your own local exploration, not a whole team writing
production dashboards against the same data at once. That stays warehouse
territory, and DuckDB is single-writer by design.

## Project structure

```
claude-code-duckdb/
├── data/                       # the sample CSVs (committed, query these directly)
│   ├── shipments_2026_01.csv   # one shipments file per month, Jan-Jun 2026
│   │   …
│   ├── shipments_2026_06.csv
│   ├── customers.csv
│   └── products.csv
├── scripts/
│   ├── generate_data.rb        # generator that rebuilds data/ (Ruby stdlib only)
│   └── challenge/
│       ├── CHALLENGE.md        # standalone DuckDB window-function exercise
│       ├── challenge.sql
│       └── challenge.rb
├── TUTORIAL.md                  # DuckDB CLI walkthrough: views, DESCRIBE, joins
├── CLAUDE.md                   # context for the AI agent
└── README.md
```

## Resources

- DuckDB: https://duckdb.org
- DuckDB concurrency (the single-writer boundary): https://duckdb.org/docs/stable/connect/concurrency
- `duckdb-skills` (official Claude Code plugin): https://github.com/duckdb/duckdb-skills
- Claude Code: https://claude.com/claude-code
