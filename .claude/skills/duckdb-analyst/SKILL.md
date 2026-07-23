---
name: duckdb-analyst
description: Use this skill to analyze ANY data file or remote dataset with DuckDB — CSV, JSON, Parquet, Avro, Excel (.xlsx), spatial formats (Shapefile, GeoJSON, GeoParquet), SQLite databases, or files sitting on S3/HTTPS. Trigger this whenever the user wants to query, summarize, describe, join, or explore a data file's contents, row count, schema, or stats — whether they name a specific file, point at a folder/glob, or paste a URL. Always use it in preference to writing raw pandas/Python or opening files in Excel, especially for files too large to comfortably open by hand. Covers both a technical audience (who wants the SQL) and a non-technical one (who wants a plain-English answer) — this skill always produces both.
---

# DuckDB Analyst

Answer questions about data files by querying them in place with DuckDB — no
import step, no warehouse, no persistent database. **The file is the table.**
This works identically whether the file is a 20-row CSV or a 300MB Parquet
file; DuckDB streams and pushes down filters instead of loading everything
into memory.

## Workflow

1. **Identify the format and location.** Look at the file extension (or ask,
   if it's genuinely ambiguous) and whether it's local or remote (`s3://`,
   `https://`). Use the table below to find which DuckDB extension (if any)
   is needed, then read the matching file under `references/` for exact
   syntax before writing SQL — don't guess at function names or flags.
2. **Load the file with `read_csv`/`read_json`/`read_parquet`/`st_read`/etc.,
   or reference the path directly in `FROM`.** Do not `CREATE TABLE ... AS
   SELECT` or otherwise import into a persistent `.duckdb` file unless the
   user specifically asks for a database to persist across sessions — a
   one-off `CREATE VIEW` in the current CLI session is fine if it makes
   several follow-up queries easier to read.
3. **Run `DESCRIBE` or `SUMMARIZE` before writing the real query.** Both are
   cheap regardless of file size — `DESCRIBE` gives column names/types,
   `SUMMARIZE` gives per-column min/max/approx-unique/nulls. This answers
   most "what's in this file" questions without touching row data, and
   catches schema surprises (wrong delimiter, nested JSON, an extra sheet)
   before they show up as a confusing query error.
4. **Print the SQL, then run it.** Always show the query in a fenced ```sql
   block immediately before executing it — this is what lets a technical
   reader trust the answer instead of taking it on faith, and it's how you
   (the agent) catch your own mistakes: a query can run clean and still
   answer the wrong question (wrong grain, dropped filter, join that only
   matched some rows).
5. **Pair every result with a plain-English summary.** One or two sentences
   stating the answer in words, not just a table dump — e.g. "There are
   2.7M shipments in this file, spanning Jan–Jun 2026" rather than only the
   raw `COUNT(*)` output. Do this even when the user seems technical; it's
   cheap and it's the fastest way for anyone to sanity-check the number
   against their own intuition.
6. **Never multiply a query's row cap.** DuckDB CLI's default table renderer
   caps at 40 rows — leave that alone. If you need more rows to actually
   answer the question, that's a signal to aggregate (`GROUP BY`, `LIMIT`
   on a sorted/ranked query) rather than to widen the cap.

## Format → extension lookup

| Format | Read with | Extension needed | Setup |
|---|---|---|---|
| CSV | `read_csv('path')` or bare `'path.csv'` in `FROM` | none (built in) | — |
| JSON / NDJSON | `read_json('path')` | none (built in) | — |
| Parquet | `read_parquet('path')` or bare `'path.parquet'` | none (built in) | — |
| Excel (`.xlsx`) | `st_read('path', layer='SheetName')` | `spatial` | `INSTALL spatial; LOAD spatial;` — see `references/excel.md` |
| SQLite (`.db`/`.sqlite`) | `ATTACH 'path' (TYPE sqlite)` then query tables directly | `sqlite_scanner` | `INSTALL sqlite_scanner; LOAD sqlite_scanner;` — see `references/sqlite.md` |
| Avro | `read_avro('path')` | `avro` | `INSTALL avro; LOAD avro;` — see `references/avro.md` |
| Spatial (Shapefile, GeoJSON, GeoParquet, GPKG) | `st_read('path')` | `spatial` | `INSTALL spatial; LOAD spatial;` — see `references/spatial.md` |
| S3 (`s3://...`) | same read function as the underlying format | `httpfs` | `INSTALL httpfs; LOAD httpfs;` — see `references/remote.md` |
| HTTPS (`https://...`) | same read function as the underlying format | `httpfs` | `INSTALL httpfs; LOAD httpfs;` — see `references/remote.md` |

Local CSV/JSON/Parquet need zero setup — that's the common case, try it
dir~~ectly. Everything else needs `INSTALL`/`LOAD` once per CLI session (a
fresh `duckdb` process needs it again; `INSTALL` itself only needs to run
once per machine, but `LOAD` is per-session).~~

For multi-file questions, glob instead of `UNION ALL`: `FROM 'data/*.parquet'`
reads every matching file as one table, same as CSV.

## Token hygiene

A data file's raw content or a large query result can flood the session
regardless of file size. There are two distinct ways that happens, and both
are prohibited:

1. **Bypassing DuckDB to read the file's raw bytes directly** — the `Read`
   tool, or an unbounded shell read like `cat`. Both put the file's actual
   content into the conversation no matter how large the file is.
   - **Bounded shell reads are fine** — `head -n 20 file.csv`,
     `tail -n 20 file.csv`, `wc -l file.csv`. Their output size is capped by
     construction regardless of the underlying file's size, so they don't
     carry the same risk. They're useful for a quick raw-structure sanity
     check (does this file have a header row? what does a raw line actually
     look like?), but prefer `DESCRIBE`/`SUMMARIZE` for anything beyond
     that — they return typed schema/stats instead of raw text and reflect
     the file's actual structure rather than its literal bytes.
2. **Letting DuckDB's own query output flood the session** — going through
   DuckDB isn't sufficient on its own if the *result* is uncapped. The
   default CLI output (no `-csv`/`-json`/`-markdown` flag) already handles
   this for you: it renders only the first 20 and last 20 rows (40 shown)
   with a `N rows (40 shown)` footer, no matter how many rows actually
   matched — as long as you don't override this, plain `duckdb -c "SELECT
   ...;"` is safe to run as-is. `-csv` and `-json` output are **not**
   capped this way — they print every row — so add your own `LIMIT` when
   using those formats for something you intend to show in the
   conversation, and reserve the uncapped formats for writing to `tmp/`
   (below).
   - Add `LIMIT` in the query to narrow *which* rows come back (e.g. top 10
     by revenue), not to fight the render cap — there's no flag to raise
     the default renderer's cap, and that's intentional.

**Full result sets go to `tmp/`, never into the session.** If the user
genuinely needs every matching row rather than a capped preview, export it
instead of trying to print it:
```bash
mkdir -p tmp
duckdb -csv -c "SELECT ... ;" > tmp/<description>.csv
# or, for a small formatted result worth keeping as a readable record:
duckdb -markdown -c "SELECT ... ;" > tmp/<description>.md
```
Other DuckDB output formats (`-json`, `-parquet` via `COPY ... TO`) work the
same way if the user asks for one specifically. After writing the file,
report only the row count and path — do not read the file back into the
session to "confirm" it; the write succeeding is the confirmation.
