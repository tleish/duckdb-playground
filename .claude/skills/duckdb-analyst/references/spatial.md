# Spatial formats (Shapefile, GeoJSON, GeoPackage, GeoParquet)

Setup once per CLI session:

```sql
INSTALL spatial;
LOAD spatial;
```

## Read

`st_read` handles all of these through the same GDAL-backed interface —
point it at the file (or the `.shp` member of a Shapefile) and it infers the
driver from the extension:

```sql
SELECT * FROM st_read('data/parcels.shp');
SELECT * FROM st_read('data/parcels.geojson');
SELECT * FROM st_read('data/parcels.gpkg');       -- may have multiple layers, see below
SELECT * FROM st_read('data/parcels.parquet');    -- GeoParquet
```

GeoParquet can also be read with the plain `read_parquet` used for ordinary
Parquet files — the geometry column just comes back as a `BLOB`/`WKB`
value instead of a native `GEOMETRY` type. Use `st_read` when you need
spatial functions (`ST_Area`, `ST_Within`, …) on the result; use
`read_parquet` if you only need the non-spatial columns and want to avoid
loading the spatial extension.

## Multiple layers (GeoPackage)

Like Excel, a `.gpkg` can contain multiple layers. List them first:

```sql
SELECT unnest(layers).name AS layer_name
FROM st_read_meta('data/parcels.gpkg');
```

Then read a specific one with `st_read('data/parcels.gpkg', layer='...')`.

## The geometry column

`st_read` returns geometry as a `GEOMETRY` type, printed as WKB by default —
don't dump it raw in a summary table. Convert to a readable form for a
result the user will actually look at:

```sql
SELECT name, ST_AsText(geom) AS geom_wkt FROM st_read('data/parcels.shp') LIMIT 5;
```

Common spatial functions: `ST_Area`, `ST_Distance`, `ST_Within`,
`ST_Intersects`, `ST_Centroid`. Reach for these instead of trying to
reimplement geometry math in SQL by hand.
