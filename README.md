# firebird_dart

Pure-Dart asynchronous Firebird driver. It implements the Firebird wire
protocol directly over TCP: no `fbclient` library, no FFI, no runtime package
dependencies. MIT licensed.

Built for server-side Dart (web back ends, workers, migration tools):

- non-blocking I/O with a FIFO request queue per connection and a bounded
  connection pool for parallel work;
- request pipelining: allocate + prepare, execute + first fetch, execute +
  row count + commit, and BLOB open/read/close for a whole batch go out in a
  single round trip;
- per-connection LRU prepared-statement cache;
- row decoding without an `await` per value when the data is already
  buffered;
- streaming of large results with bounded memory;
- server-side cancellation on timeout.

## Status

| Server | Protocol | Authentication | Status |
|---|---|---|---|
| Firebird 2.1 / 2.5 | 10–12 | legacy (`crypt`, password never sent in clear text) | tested against Firebird 2.5.6 |
| Firebird 3 / 4 / 5 | 13 | `Srp256`, `Srp`, `Legacy_Auth`; `Arc4` wire encryption | implemented, **not yet tested against a server** |

Not implemented yet: events (`POST_EVENT`), the Services API (backup, user
management), ARRAY columns, wire compression, DECFLOAT decoding (returned as
raw IEEE 754 bytes), protocol 14+ features (batch API, inline BLOBs).

## Install

```yaml
dependencies:
  firebird_dart:
    git: https://github.com/insinfo/firebird_dart.git
```

```dart
import 'package:firebird_dart/firebird_dart.dart';
```

## Connecting

```dart
final conn = await FbConnection.connect(FbConnectionSettings(
  host: 'localhost',
  port: 3050,
  database: r'C:\data\legacy.fdb', // path on the server, or an alias
  user: 'SYSDBA',
  password: 'masterkey',
  charset: 'WIN1252',
));
// ...
await conn.close();
```

`FbConnectionSettings.fromDsn('server/3050:C:\\data\\legacy.fdb')` accepts the
usual Firebird connection strings.

Main settings:

| Setting | Default | Meaning |
|---|---|---|
| `charset` | `UTF8` | Connection character set: UTF8, WIN1252, ISO8859_1, ASCII, UNICODE_FSS, NONE, OCTETS |
| `noneEncoding` | codec of `charset` | Codec for `CHARACTER SET NONE` columns, whose bytes the server passes through unchanged |
| `fetchSize` | 400 | Rows per fetch round trip |
| `statementCacheSize` | 32 | Prepared statements kept per connection |
| `commandTimeout` | none | Default timeout of each request (cancelled on the server) |
| `numericMode` | `decimal` | NUMERIC/DECIMAL as `FbDecimal`, exact `String` or `double` |
| `blobMode` | `materialize` | BLOBs read with the row, or returned as `FbBlobId` |
| `autoCommitOptions` | read committed, write | Transaction of calls made outside an explicit transaction |
| `readOnlyAutoCommitSelects` | true | SELECTs outside a transaction run read-only, saving a round trip |
| `trimChar` | false | Remove trailing spaces of `CHAR(n)` |

### Legacy databases with `CHARACTER SET NONE`

Databases created by Delphi/IBExpert applications often declare no character
set while storing Windows-1252 text. Connect with `charset: 'WIN1252'`: text is
decoded as Windows-1252 and parameters are written back with the same bytes.
With `charset: 'UTF8'`, set `noneEncoding: windows1252` to decode those columns.

## Queries

Parameters are positional `?` (a `List`) or named `@name` (a `Map`).

```dart
final result = await conn.query(
    'select id, name from customers where state = ? and id > ?',
    ['RJ', 1000]);
for (final row in result) {
  print('${row['ID']} ${row[1]}');
}

final maps = await conn.queryMaps(
    'select * from customers where state = @state', {'state': 'RJ'});

final total = await conn.queryScalar<int>('select count(*) from customers');
final one = await conn.queryFirstMap('select * from customers where id = ?', [1]);

final changed = await conn.execute(
    'update customers set updated_at = ? where id = ?', [DateTime.now(), 42]);

// INSERT ... RETURNING and EXECUTE PROCEDURE return their row.
final inserted = await conn.query(
    'insert into t (name) values (?) returning id', ['x']);
```

`mappedResultsQuery` returns `{table: {column: value}}`; `@name:type` hints
are accepted and ignored, so SQL written for postgres_fork keeps working.

## Transactions and savepoints

```dart
await conn.runInTransaction((tx) async {
  await tx.execute('insert into items values (?, ?)', [1, 'a']);
  try {
    await tx.savepoint((sp) async {
      await sp.execute('insert into items values (?, ?)', [1, 'duplicate']);
    });
  } on FbException catch (e) {
    if (!e.errorCodes.any(FbErrorCode.uniqueViolations.contains)) rethrow;
    // only the savepoint was rolled back
  }
});

final tx = await conn.beginTransaction(const FbTransactionOptions(
  isolation: FbIsolation.snapshot,
  wait: true,
  lockTimeout: 10,
));
// tx.query / tx.execute / tx.stream ...
await tx.commit(); // or rollback(), commitRetaining(), rollbackRetaining()
```

## Large results

```dart
await for (final row in conn.stream('select * from payments', null, 2000)) {
  // rows arrive in batches of 2000; memory stays bounded
}

// Aggregate without materialising rows:
var sum = 0;
await conn.queryEach('select amount from payments', null, (r) => sum += r[0] as int);
```

While a stream is open, other requests can still run on the same connection
between batches.

## Prepared statements and bulk writes

```dart
final insert = await conn.prepare('insert into items (id, name) values (?, ?)');
final rows = await insert.executeBatch([
  for (var i = 0; i < 100000; i++) [i, 'item $i'],
]); // pipelined: up to 256 executes per round trip, one transaction
await insert.close();
```

## Pool

```dart
final pool = FbPool(settings, const FbPoolSettings(
  maxConnections: 10,
  acquireTimeout: Duration(seconds: 30),
));
final rows = await pool.queryMaps('select * from items where id = ?', [1]);
await pool.runTx((tx) => tx.execute('delete from items where id = ?', [1]));
await pool.close();
```

The pool reuses the most recently used connection, validates connections
idle for longer than `validateAfterIdle`, and discards broken ones and those
returned with an open transaction.

## Types

| Firebird | Dart |
|---|---|
| SMALLINT, INTEGER, BIGINT | `int` |
| NUMERIC/DECIMAL with scale | `FbDecimal` (exact; `toScaledInt(2)` gives cents), or `String`/`double` with `numericMode` |
| FLOAT, DOUBLE PRECISION | `double` |
| CHAR, VARCHAR | `String` (`Uint8List` for `CHARACTER SET OCTETS`) |
| DATE, TIMESTAMP | `DateTime` (UTC object holding the stored wall-clock value) |
| TIME | `Duration` since midnight |
| BLOB SUB_TYPE 1 | `String` |
| other BLOBs | `Uint8List` |
| BOOLEAN (FB3+) | `bool` |
| INT128 (FB4+) | `BigInt` / `FbDecimal` |

Parameters accept `int`, `BigInt`, `double`, `FbDecimal`, `String`, `bool`,
`DateTime`, `Duration`, `Uint8List` and `null`; the server converts them to
the column type. Values for BLOB parameters are written as BLOBs
automatically. Firebird dates are naive: a `DateTime` parameter is stored
by its own year/month/day/hour... fields, whether it is UTC or local.

## Timeouts and cancellation

```dart
await conn.query(sql, params, const Duration(seconds: 5));
```

When the time limit expires the request is cancelled on the server
(Firebird 2.5+), the driver waits for it to stop, and a `TimeoutException` is
thrown; the connection stays usable. `conn.cancel()` cancels the running
request explicitly.

## Errors

`FbException` carries the status vector: `message`, `errorCode`,
`errorCodes`, `hasCode(code)`, `sqlCode` and, on Firebird 3+, `sqlState`.
Common codes are in `FbErrorCode`. Network failures raise
`FbConnectionException` and leave the connection closed; API misuse raises
`FbUsageException`.

## Tests

```powershell
dart test test/unit
# integration: creates and drops a scratch database on the server
$env:FB_HOST = 'localhost'; $env:FB_PASSWORD = 'masterkey'
dart test test/integration
# optional, read-only check of an existing database (every row of every table)
$env:FB_LEGACY_DB = 'C:\copies\legacy.fdb'
dart test test/integration/legacy_test.dart
```

`FB_TEST_DIR` sets where the scratch database is created (a directory the
server can write to; defaults to the local temp directory).

Run the legacy check against a copy: the server updates the database header
even for read-only work.

## License

MIT. See [LICENSE](LICENSE).
