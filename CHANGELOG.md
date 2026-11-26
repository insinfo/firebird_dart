# Changelog

## 0.1.0

First version.

- Firebird wire protocol 10–13 in pure Dart, without fbclient or FFI.
- Legacy authentication (Firebird 2.x); Srp/Srp256, Legacy_Auth and Arc4
  wire encryption for Firebird 3+.
- CI (GitHub Actions) runs the integration suite against Firebird 2.5, 3, 4
  and 5 in Docker.
- Connections, explicit and implicit transactions, savepoints, prepared
  statements with an LRU cache, pipelined batch execution, streaming, BLOB
  read/write, timeouts with server-side cancellation, connection pool.
- `?` and `@name` parameters; rows as `FbRow`, maps or table maps.
- Exact NUMERIC/DECIMAL (`FbDecimal`), Windows-1252 codec and
  `CHARACTER SET NONE` handling for legacy databases.
- Database creation and drop.
- Database events (`POST_EVENT`) through the auxiliary connection.
- Table reservation (`RESERVING`) and `ignoreLimbo` in transaction options.
- Two-phase commit: `FbTransaction.prepare` and `runDistributedTransaction`.
