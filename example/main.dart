import 'package:firebird_dart/firebird_dart.dart';

/// Reads a Firebird 2.5 database whose text columns are WIN1252 /
/// CHARACTER SET NONE, then writes in a transaction.
///
///   dart run example/main.dart "localhost:C:\data\legacy.fdb"
Future<void> main(List<String> args) async {
  final settings = FbConnectionSettings.fromDsn(
    args.isNotEmpty ? args.first : r'localhost:C:\data\legacy.fdb',
    user: 'SYSDBA',
    password: 'masterkey',
    charset: 'WIN1252',
  );

  final conn = await FbConnection.connect(settings);
  try {
    print(await conn.serverInfo());

    // Positional parameters.
    final tables = await conn.query(
        'select trim(rdb\$relation_name) as name from rdb\$relations '
        'where rdb\$system_flag = ? order by 1',
        [0]);
    print('tables: ${tables.map((r) => r['NAME']).join(', ')}');

    // Named parameters, rows as maps.
    final rows = await conn.queryMaps(
        'select first 5 rdb\$relation_name as name, rdb\$relation_id as id '
        'from rdb\$relations where rdb\$relation_id >= @min',
        {'min': 0});
    rows.forEach(print);

    // Large results: streamed, constant memory.
    var count = 0;
    await for (final _
        in conn.stream('select * from rdb\$fields', null, 1000)) {
      count++;
    }
    print('rdb\$fields rows: $count');
  } finally {
    await conn.close();
  }

  // A pool for concurrent servers.
  final pool = FbPool(settings, const FbPoolSettings(maxConnections: 8));
  final counts = await Future.wait([
    for (var i = 0; i < 20; i++)
      pool.queryScalar<int>('select count(*) from rdb\$relations'),
  ]);
  print('parallel counts: ${counts.toSet()}');
  await pool.close();
}
