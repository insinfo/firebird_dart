# Changelog

## 0.1.0

First version.

- Firebird wire protocol 10–13 in pure Dart, without fbclient or FFI.
- Legacy authentication (Firebird 2.x); SRP/SRP256 and Arc4 wire encryption
  for Firebird 3+ (not yet tested against a server).
- Connections, explicit and implicit transactions, savepoints, prepared
  statements with an LRU cache, pipelined batch execution, streaming, BLOB
  read/write, timeouts with server-side cancellation, connection pool.
- `?` and `@name` parameters; rows as `FbRow`, maps or table maps.
- Exact NUMERIC/DECIMAL (`FbDecimal`), Windows-1252 codec and
  `CHARACTER SET NONE` handling for legacy databases.
- Database creation and drop.
