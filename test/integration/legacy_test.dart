@Timeout(Duration(minutes: 10))
library;

import 'package:firebird_dart/firebird_dart.dart';
import 'package:test/test.dart';

import 'config.dart';

/// Read-only checks against an existing database (`FB_LEGACY_DB`), e.g. a
/// copy of a legacy WIN1252 / charset NONE database. Every table is read
/// completely and its row count compared with `count(*)`.
void main() {
  final path = legacyDb;
  final skip = path == null ? 'FB_LEGACY_DB is not set' : null;

  test('reads every row of every table', () async {
    final conn = await FbConnection.connect(
        testSettings(path!, charset: 'WIN1252').copyWith(fetchSize: 1000));
    try {
      final tables = await conn.query(
          "select trim(rdb\$relation_name) from rdb\$relations "
          "where coalesce(rdb\$system_flag, 0) = 0 and rdb\$view_blr is null "
          "order by 1");
      expect(tables, isNotEmpty);
      for (final t in tables) {
        final name = '"${t[0]}"';
        final expected =
            await conn.queryScalar<int>('select count(*) from $name');
        var rows = 0;
        await for (final _ in conn.stream('select * from $name')) {
          rows++;
        }
        expect(rows, expected, reason: 'table $name');
      }
    } finally {
      await conn.close();
    }
  }, skip: skip);
}
