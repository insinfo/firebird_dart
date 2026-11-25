@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:firebird_dart/firebird_dart.dart';
import 'package:test/test.dart';

import 'config.dart';

void main() {
  late String dbPath;
  late FbConnection conn;

  setUpAll(() async {
    dbPath = scratchDatabasePath();
    conn =
        await FbConnection.createDatabase(testSettings(dbPath), pageSize: 8192);
    await conn.execute('''
      create table all_types (
        id integer not null primary key,
        c_small smallint,
        c_int integer,
        c_big bigint,
        c_num numeric(15,2),
        c_num4 numeric(18,4),
        c_dec decimal(9,3),
        c_num_small numeric(4,1),
        c_float float,
        c_double double precision,
        c_date date,
        c_time time,
        c_ts timestamp,
        c_char char(10),
        c_varchar varchar(100),
        c_win varchar(50) character set win1252,
        c_none varchar(50) character set none,
        c_octets char(4) character set octets,
        c_text blob sub_type 1,
        c_bin blob sub_type 0
      )''');
    await conn.execute(
        'create table items (id integer not null primary key, name varchar(60) not null unique)');
    await conn.execute('create generator gen_items');
    await conn.execute('''
      create procedure p_sum (a integer, b integer)
      returns (total integer, label varchar(20))
      as begin
        total = a + b;
        label = 'sum';
      end''');
    await conn.execute('''
      create procedure p_range (n integer)
      returns (i integer)
      as begin
        i = 1;
        while (i <= n) do begin
          suspend;
          i = i + 1;
        end
      end''');
  });

  tearDownAll(() async {
    await conn.dropDatabase();
  });

  setUp(() async {
    await conn.execute('delete from all_types');
    await conn.execute('delete from items');
  });

  test('server info and ping', () async {
    final info = await conn.serverInfo();
    expect(info.serverVersion, contains('Firebird'));
    expect(info.sqlDialect, 3);
    expect(conn.protocolVersion, greaterThanOrEqualTo(10));
    print('server: $info');
    if (expectedAuth != null) expect(info.authPlugin, expectedAuth);
    if (expectedEncrypted != null) {
      expect(info.wireEncrypted, expectedEncrypted);
    }
    await conn.ping();
    expect(await conn.checkHealth(), isTrue);
  });

  test('every type round-trips through parameters', () async {
    final bigText = 'Ação, coração — ✓ ' * 5000;
    final bin = Uint8List.fromList(List.generate(300000, (i) => i % 251));
    final values = <Object?>[
      1,
      -32768,
      2147483647,
      -9223372036854775808,
      FbDecimal.parse('1234567890123.45'),
      FbDecimal.parse('-12345678901234.5678'),
      FbDecimal.parse('-123456.789'),
      FbDecimal.parse('-999.9'),
      1.5,
      3.141592653589793,
      DateTime.utc(1858, 11, 17),
      const Duration(hours: 23, minutes: 59, seconds: 59, milliseconds: 999),
      DateTime.utc(2024, 2, 29, 13, 45, 30, 123, 400),
      'abc',
      'Olá, mundo 🌍',
      'Ação € Œ',
      'Joãozinho',
      Uint8List.fromList([0, 255, 1, 128]),
      bigText,
      bin,
    ];
    final n = await conn.execute(
        'insert into all_types values (${List.filled(values.length, '?').join(', ')})',
        values);
    expect(n, 1);

    final row =
        (await conn.query('select * from all_types where id = ?', [1])).single;
    expect(row['ID'], 1);
    expect(row['C_SMALL'], -32768);
    expect(row['C_INT'], 2147483647);
    expect(row['C_BIG'], -9223372036854775808);
    expect(row['C_NUM'], FbDecimal.parse('1234567890123.45'));
    expect((row['C_NUM'] as FbDecimal).toScaledInt(2), 123456789012345);
    expect(row['C_NUM4'].toString(), '-12345678901234.5678');
    expect(row['C_DEC'].toString(), '-123456.789');
    expect(row['C_NUM_SMALL'].toString(), '-999.9');
    expect(row['C_FLOAT'], 1.5);
    expect(row['C_DOUBLE'], 3.141592653589793);
    expect(row['C_DATE'], DateTime.utc(1858, 11, 17));
    expect(row['C_TIME'],
        const Duration(hours: 23, minutes: 59, seconds: 59, milliseconds: 999));
    expect(row['C_TS'], DateTime.utc(2024, 2, 29, 13, 45, 30, 123, 400));
    expect(row['C_CHAR'], 'abc'.padRight(10));
    expect(row['C_VARCHAR'], 'Olá, mundo 🌍');
    expect(row['C_WIN'], 'Ação € Œ');
    expect(row['C_NONE'], 'Joãozinho');
    expect(row['C_OCTETS'], [0, 255, 1, 128]);
    expect(row['C_TEXT'], bigText);
    expect(row['C_BIN'], bin);
  });

  test('nulls in every column', () async {
    await conn.execute('insert into all_types (id) values (?)', [2]);
    final row = (await conn.query('select * from all_types')).single;
    expect(row.values.skip(1), everyElement(isNull));
    await conn.execute(
        'update all_types set c_int = ?, c_text = ?, c_date = ? where id = 2',
        [null, null, null]);
  });

  test('numeric modes', () async {
    await conn
        .execute('insert into all_types (id, c_num) values (3, ?)', ['10.5']);
    for (final (mode, expected) in [
      (FbNumericMode.string, '10.50'),
      (FbNumericMode.double, 10.5),
    ]) {
      final c = await FbConnection.connect(
          testSettings(dbPath).copyWith(numericMode: mode));
      expect(await c.queryScalar('select c_num from all_types'), expected);
      await c.close();
    }
  });

  test('named parameters and maps', () async {
    await conn.execute(
        'insert into items values (@id, @name)', {'id': 1, 'name': 'um'});
    await conn.execute('insert into items values (@id:int4, @name:text)',
        {'id': 2, 'name': 'dois'});
    final maps = await conn.queryMaps(
        'select id, name as nome from items where id >= @min order by id',
        {'min': 1});
    expect(maps, [
      {'ID': 1, 'NOME': 'um'},
      {'ID': 2, 'NOME': 'dois'},
    ]);
    expect(await conn.queryFirstMap('select * from items where id = ?', [9]),
        isNull);
    final mapped = await conn.mappedResultsQuery(
        'select i.id, i.name, 1 + 1 as two from items i where i.id = 1');
    expect(mapped.single['ITEMS'], {'ID': 1, 'NAME': 'um'});
    expect(mapped.single[''], {'TWO': 2});
  });

  test('affected rows, RETURNING and procedures', () async {
    await conn.execute('insert into items values (1, ?)', ['a']);
    await conn.execute('insert into items values (2, ?)', ['b']);
    expect(await conn.execute('update items set name = name || ?', ['!']), 2);
    final ret = await conn.query(
        'insert into items values (gen_id(gen_items, 1) + 100, ?) returning id, name',
        ['c']);
    expect(ret.single['NAME'], 'c');
    expect(ret.single['ID'], greaterThan(100));
    expect(await conn.execute('delete from items'), 3);

    final sum = await conn.query('execute procedure p_sum(?, ?)', [2, 3]);
    expect(sum.single.toMap(), {'TOTAL': 5, 'LABEL': 'sum'});
    final range = await conn.query('select i from p_range(?)', [5]);
    expect(range.map((r) => r[0]), [1, 2, 3, 4, 5]);
  });

  test('server errors carry codes and connection stays usable', () async {
    await conn.execute('insert into items values (1, ?)', ['x']);
    try {
      await conn.execute('insert into items values (1, ?)', ['y']);
      fail('expected unique violation');
    } on FbException catch (e) {
      expect(e.errorCodes.any(FbErrorCode.uniqueViolations.contains), isTrue);
      expect(e.message, contains('ITEMS'));
    }
    try {
      await conn.query('selec 1 from rdb\$database');
      fail('expected syntax error');
    } on FbException catch (e) {
      expect(e.sqlCode, -104);
      expect(e.hasCode(FbErrorCode.tokenUnknown), isTrue);
    }
    await expectLater(
        conn.query('select * from no_such_table'),
        throwsA(isA<FbException>().having(
            (e) => e.hasCode(FbErrorCode.tableUnknown), 'table', true)));
    await expectLater(
        conn.query('select cast(? as integer) from rdb\$database', [1, 2]),
        throwsA(isA<FbUsageException>()));
    expect(await conn.queryScalar<int>('select count(*) from items'), 1);
  });

  test('explicit transactions, rollback and savepoints', () async {
    final tx = await conn.beginTransaction();
    await tx.execute('insert into items values (1, ?)', ['a']);
    // Not visible to other transactions before commit.
    final other = await FbConnection.connect(testSettings(dbPath));
    expect(await other.queryScalar<int>('select count(*) from items'), 0);
    await tx.rollback();
    expect(tx.isActive, isFalse);
    expect(await conn.queryScalar<int>('select count(*) from items'), 0);

    await expectLater(conn.runInTransaction((tx) async {
      await tx.execute('insert into items values (2, ?)', ['b']);
      throw StateError('boom');
    }), throwsStateError);
    expect(await conn.queryScalar<int>('select count(*) from items'), 0);

    await conn.transaction((tx) async {
      await tx.execute('insert into items values (3, ?)', ['c']);
      await expectLater(tx.savepoint((sp) async {
        await sp.execute('insert into items values (4, ?)', ['d']);
        await sp.execute('insert into items values (3, ?)', ['dup']);
      }), throwsA(isA<FbException>()));
      await tx.savepoint(
          (sp) => sp.execute('insert into items values (5, ?)', ['e']));
    });
    expect(
        (await other.query('select id from items order by id'))
            .map((r) => r[0]),
        [3, 5]);
    await other.close();
  });

  test('streaming with small batches and early cancel', () async {
    final stmt = await conn.prepare('insert into items values (?, ?)');
    final n = await stmt.executeBatch([
      for (var i = 1; i <= 2500; i++) [i, 'item $i']
    ]);
    expect(n, 2500);
    await stmt.close();

    var count = 0;
    await for (final row
        in conn.stream('select id, name from items order by id', null, 7)) {
      expect(row['NAME'], 'item ${row['ID']}');
      count++;
    }
    expect(count, 2500);

    // Breaking out closes the cursor and ends the implicit transaction.
    await for (final _ in conn.stream('select * from items', null, 10)) {
      break;
    }
    // Other requests can run while a stream is open.
    final iterator = StreamIterator(
        conn.stream('select id from items order by id', null, 50));
    expect(await iterator.moveNext(), isTrue);
    expect(await conn.queryScalar<int>('select count(*) from items'), 2500);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current[0], 2);
    await iterator.cancel();
    expect(await conn.queryScalar<int>('select max(id) from items'), 2500);

    var sum = 0;
    await conn.queryEach(
        'select id from items', null, (r) => sum += r[0] as int);
    expect(sum, 2500 * 2501 ~/ 2);
  });

  test('concurrent calls on one connection are queued', () async {
    final results = await Future.wait([
      for (var i = 0; i < 200; i++)
        conn.queryScalar<int>(
            'select cast(? as integer) * 2 from rdb\$database', [i]),
    ]);
    expect(results, [for (var i = 0; i < 200; i++) i * 2]);
  });

  test('prepared statements', () async {
    final ins =
        await conn.prepare('insert into items (id, name) values (?, ?)');
    expect(ins.type, FbStatementType.insert);
    expect(ins.parameters, hasLength(2));
    for (var i = 0; i < 10; i++) {
      expect(await ins.execute([i, 'n$i']), 1);
    }
    await ins.close();
    final sel = await conn.prepare('select name from items where id = ?');
    expect(sel.columns.single.typeName, 'VARCHAR(240)');
    expect((await sel.query([3])).single[0], 'n3');
    final tx = await conn.beginTransaction();
    expect((await sel.query([4], tx)).single[0], 'n4');
    await tx.commit();
    await sel.close();
    await expectLater(sel.query([1]), throwsA(isA<FbUsageException>()));
  });

  test('timeouts cancel the request on the server', () async {
    final sw = Stopwatch()..start();
    await expectLater(
        conn.query(
            'select count(*) from rdb\$fields a, rdb\$fields b, rdb\$fields c, rdb\$fields d',
            null,
            const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>()));
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    // The connection is still usable and no cancel is left pending.
    expect(await conn.queryScalar<int>('select 1 from rdb\$database'), 1);
    expect(await conn.queryScalar<int>('select 2 from rdb\$database'), 2);
  });

  test('pool runs requests in parallel and bounds connections', () async {
    final pool =
        FbPool(testSettings(dbPath), const FbPoolSettings(maxConnections: 4));
    final results = await Future.wait([
      for (var i = 0; i < 40; i++)
        pool.queryScalar<int>(
            'select cast(? as integer) from rdb\$database', [i]),
    ]);
    expect(results, List.generate(40, (i) => i));
    expect(pool.size, lessThanOrEqualTo(4));
    await pool
        .runTx((tx) => tx.execute('insert into items values (1, ?)', ['p']));
    expect(await pool.queryScalar<int>('select count(*) from items'), 1);
    var rows = 0;
    await for (final _
        in pool.stream('select * from rdb\$relations', null, 5)) {
      rows++;
    }
    expect(rows, greaterThan(10));
    await pool.close();
  });

  test('BLOB ids mode', () async {
    await conn.execute(
        'insert into all_types (id, c_text) values (?, ?)', [5, 'blob text']);
    final c = await FbConnection.connect(
        testSettings(dbPath).copyWith(blobMode: FbBlobMode.id));
    final id = await c.queryScalar<FbBlobId>('select c_text from all_types');
    expect(String.fromCharCodes(await c.readBlob(id!)), 'blob text');
    await c.close();
  });

  test('wrong password is reported as a login error', () async {
    await expectLater(
        FbConnection.connect(
            testSettings(dbPath).copyWith(password: 'wrong-password')),
        throwsA(isA<FbException>()
            .having((e) => e.hasCode(FbErrorCode.login), 'login', true)));
  });
}
