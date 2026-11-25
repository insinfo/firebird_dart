// Reads a large table several ways and prints rows/s.
//
//   dart run benchmark/read_benchmark.dart <database> [table] [charset]
import 'dart:io';

import 'package:firebird_dart/firebird_dart.dart';

Future<void> main(List<String> args) async {
  final db = args[0];
  final table = args.length > 1 ? args[1] : r'RDB$FIELDS';
  final charset = args.length > 2 ? args[2] : 'WIN1252';
  for (final fetch in [400, 2000]) {
    final conn = await FbConnection.connect(
        FbConnectionSettings(database: db, charset: charset, fetchSize: fetch));
    final count = await conn.queryScalar<int>('select count(*) from $table');
    for (final run in [1, 2]) {
      final sw = Stopwatch()..start();
      var n = 0;
      await conn.queryEach('select * from $table', null, (r) => n++);
      final ms = sw.elapsedMilliseconds;
      stdout.writeln('fetchSize=$fetch run=$run rows=$n/$count ${ms}ms '
          '${(n * 1000 / ms).round()} rows/s');
    }
    await conn.close();
  }
}
