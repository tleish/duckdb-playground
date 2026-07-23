# Remote files (S3, HTTPS)

Setup once per CLI session:

```sql
INSTALL httpfs;
LOAD httpfs;
```

Once loaded, every read function used for local files works the same way
against a remote URL — the format (CSV/JSON/Parquet/etc.) determines the
function, `httpfs` just adds the transport. Nothing else about the workflow
changes: still `DESCRIBE`/`SUMMARIZE` first, still print the SQL, still cap
result size.

## HTTPS

```sql
SELECT * FROM read_csv('https://example.com/data/orders.csv');
SELECT * FROM read_parquet('https://example.com/data/events.parquet');
```

## S3

```sql
SELECT * FROM read_parquet('s3://my-bucket/events/2026/*.parquet');
SELECT * FROM read_csv('s3://my-bucket/orders.csv');
```

Credentials are assumed to already be configured in the environment — this
skill does not manage secrets. DuckDB's `httpfs` picks up the standard AWS
credential chain automatically (env vars `AWS_ACCESS_KEY_ID`/
`AWS_SECRET_ACCESS_KEY`, `~/.aws/credentials`, instance/role credentials).
If a query against an `s3://` path fails with an auth/access error, that's
an environment/credentials problem to raise with the user — not something
to work around by embedding keys in the SQL.

For a non-default region or endpoint (e.g. an S3-compatible store), a
`CREATE SECRET` can pin those explicitly instead of relying on the ambient
environment:

```sql
CREATE SECRET (
    TYPE s3,
    REGION 'us-west-2'
);
```

Only reach for `CREATE SECRET` if the ambient credential chain isn't
working or the user gives you specific region/endpoint values to use — it's
extra ceremony the default case doesn't need.

## Performance note

Remote reads pull data over the network on every query — DuckDB does push
down column/row filters where the format supports it (Parquet especially),
but there's no local cache between queries. If the user is going to ask
several questions against the same remote file, consider mentioning that a
local `COPY (FROM 's3://...') TO 'tmp/local_copy.parquet'` once up front
would make follow-up queries faster — but don't do this unprompted, since it
also means committing to a point-in-time copy of remote data.
