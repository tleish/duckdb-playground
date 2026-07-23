# Avro

Setup once per CLI session:

```sql
INSTALL avro;
LOAD avro;
```

## Read

```sql
SELECT * FROM read_avro('data/events.avro');
SELECT * FROM read_avro('data/events_*.avro');  -- glob across files, same as CSV/Parquet
```

Avro is schema-carrying like Parquet, so `DESCRIBE`/`SUMMARIZE` reflect the
real embedded schema — nested/union types show up as `STRUCT`/`UNION`
columns. Check `DESCRIBE` before assuming a column is a flat scalar,
especially for fields that were optional (nullable union) in the original
Avro schema.