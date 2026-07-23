# Excel (.xlsx)

DuckDB reads Excel files through the `spatial` extension's GDAL-backed
`st_read`/`st_read_meta` functions — there is no native `read_xlsx`. Setup
once per CLI session:

```sql
INSTALL spatial;
LOAD spatial;
```

## List the sheets first

An `.xlsx` file can have multiple sheets; don't assume there's only one.
`st_read_meta` returns one row per file with a `layers` list — unnest it to
see sheet names before reading anything:

```sql
SELECT unnest(layers).name AS sheet_name
FROM st_read_meta('data/report.xlsx');
```

## Read a specific sheet

```sql
SELECT * FROM st_read('data/report.xlsx', layer='Sheet1');
```

Two things this driver does that a plain CSV read wouldn't:

- It adds an `OGC_FID` column (a GDAL row-id artifact) — exclude it in your
  `SELECT` list rather than reporting it as a real data column.
- The first row of the sheet is treated as the header by default. If a sheet
  has title rows or merged cells above the real header, `DESCRIBE` the
  result first — column names coming back as `field_1`, `field_2`, … is the
  signal that the header row wasn't where GDAL expected it.

## Multiple sheets at once

There's no glob-style "all sheets" read — loop over the sheet names from
`st_read_meta` and query each `layer=` individually, or use
`UNION ALL BY NAME` across a small known set of sheets if they share a
schema.
