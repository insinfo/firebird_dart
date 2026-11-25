@Timeout(Duration(minutes: 3))
library;

import 'dart:async';

import 'package:firebird_dart/firebird_dart.dart';
import 'package:test/test.dart';

import 'config.dart';

/// Firebird-specific features exercised through the driver.
void main() {
  late String dbPath;
  late FbConnection conn;

  setUpAll(() async {
    dbPath = scratchDatabasePath();
    conn = await FbConnection.createDatabase(testSettings(dbPath));
    await conn.execute('create domain dm_money as numeric(15,2) '
        'default 0 check (value >= 0)');
    await conn.execute('create table acc (id integer not null primary key, '
        'name varchar(40), balance dm_money)');
    await conn.execute('create table audit_log (msg varchar(100))');
    await conn.execute('create table tree (id integer not null primary key, '
        'parent integer)');
    await conn.execute("create exception e_custom 'custom failure'");
    await conn.execute('''
      create procedure p_audit_then_fail (msg varchar(100))
      as begin
        in autonomous transaction do
          insert into audit_log values (:msg);
        exception e_custom;
      end''');
    await conn.execute('''
      create procedure p_partial (a integer, b integer)
      returns (ok integer)
      as begin
        ok = 0;
        insert into acc (id, name) values (:a, 'first');
        begin
          insert into acc (id, name) values (:b, 'second');
          insert into acc (id, name) values (:b, 'duplicate');
        when any do ok = -1;
        end
        suspend;
      end''');
    await conn.execute('''
      create trigger t_on_connect on connect
      as begin
        rdb\$set_context('USER_SESSION', 'CONNECTED_BY_TRIGGER', 'yes');
      end''');
  });

  tearDownAll(() async {
    await conn.dropDatabase();
  });

  setUp(() async {
    await conn.execute('delete from acc');
    await conn.execute('delete from audit_log');
    await conn.execute('delete from tree');
  });

  test('several transactions at once on one connection', () async {
    await conn.execute("insert into acc values (1, 'a', 10)");
    final reader = await conn.beginTransaction(const FbTransactionOptions(
        isolation: FbIsolation.snapshot, readOnly: true));
    final writer = await conn.beginTransaction();

    // Snapshot reader keeps its view while the writer changes and commits.
    expect(await reader.queryScalar<int>('select count(*) from acc'), 1);
    await writer.execute("insert into acc values (2, 'b', 20)");
    await writer.execute('update acc set balance = 99 where id = 1');
    expect(await writer.queryScalar<int>('select count(*) from acc'), 2);
    await writer.commit();
    expect(await reader.queryScalar<int>('select count(*) from acc'), 1);
    expect(
        (await reader
                .queryScalar<FbDecimal>('select balance from acc where id = 1'))
            .toString(),
        '10.00');

    // A cursor in one transaction interleaved with writes in another.
    final it = StreamIterator(
        reader.stream('select id from acc order by id', null, 1));
    final writer2 = await conn.beginTransaction();
    expect(await it.moveNext(), isTrue);
    await writer2.execute("insert into acc values (3, 'c', 30)");
    expect(await it.moveNext(), isFalse); // snapshot: still one row
    await it.cancel();
    await writer2.commit();
    await reader.commit();
    expect(await conn.queryScalar<int>('select count(*) from acc'), 3);
  });

  test('RESERVING locks tables at transaction start', () async {
    final other = await FbConnection.connect(testSettings(dbPath));
    final owner = await conn.beginTransaction(const FbTransactionOptions(
      isolation: FbIsolation.snapshot,
      reserving: [
        FbTableReservation('ACC', write: true, mode: FbLockMode.protected),
      ],
    ));
    await expectLater(
        other.beginTransaction(const FbTransactionOptions(
          isolation: FbIsolation.snapshot,
          wait: false,
          reserving: [FbTableReservation('ACC', write: true)],
        )),
        throwsA(isA<FbException>()));
    await owner.execute("insert into acc values (1, 'x', 1)");
    await owner.commit();
    final later = await other.beginTransaction(const FbTransactionOptions(
      isolation: FbIsolation.snapshot,
      wait: false,
      reserving: [FbTableReservation('ACC', write: true)],
    ));
    await later.rollback();
    await other.close();
  });

  test('two-phase commit across databases', () async {
    final path2 = scratchDatabasePath();
    final conn2 = await FbConnection.createDatabase(testSettings(path2));
    await conn2.execute('create table ledger (id integer, amount integer)');
    try {
      await runDistributedTransaction([conn, conn2], (txs) async {
        await txs[0].execute("insert into acc values (1, 'dist', 5)");
        await txs[1].execute('insert into ledger values (1, 5)');
      });
      expect(await conn.queryScalar<int>('select count(*) from acc'), 1);
      expect(await conn2.queryScalar<int>('select count(*) from ledger'), 1);

      await expectLater(
          runDistributedTransaction([conn, conn2], (txs) async {
            await txs[1].execute('insert into ledger values (2, 7)');
            await txs[0].execute("insert into acc values (1, 'dup', 7)");
          }),
          throwsA(isA<FbException>()));
      expect(await conn2.queryScalar<int>('select count(*) from ledger'), 1);

      final tx = await conn.beginTransaction();
      await tx.execute("insert into acc values (2, 'prepared', 1)");
      await tx.prepare('order 42'.codeUnits);
      await tx.commit();
      expect(await conn.queryScalar<int>('select count(*) from acc'), 2);
    } finally {
      await conn2.dropDatabase();
    }
  });

  test('database events (POST_EVENT)', () async {
    final listener = await FbConnection.connect(testSettings(dbPath));
    final sub =
        await listener.subscribeEvents(['ORDER_PAID', 'ORDER_CANCELLED']);
    await sub.ready;
    final received = <FbEvent>[];
    final listening = sub.events.listen(received.add);

    Future<void> waitFor(int n) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (received.length < n && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    await conn.execute("execute block as begin "
        "post_event 'ORDER_PAID'; post_event 'ORDER_PAID'; end");
    await waitFor(1);
    expect(received.single.name, 'ORDER_PAID');
    expect(received.single.count, 2);

    // Events of a rolled-back transaction are never delivered.
    final tx = await conn.beginTransaction();
    await tx
        .execute("execute block as begin post_event 'ORDER_CANCELLED'; end");
    await tx.rollback();
    await conn
        .execute("execute block as begin post_event 'ORDER_CANCELLED'; end");
    await waitFor(2);
    expect(received.map((e) => '${e.name}:${e.count}'),
        ['ORDER_PAID:2', 'ORDER_CANCELLED:1']);

    // The listening connection stays usable for queries.
    expect(await listener.queryScalar<int>('select 1 from rdb\$database'), 1);

    await sub.cancel();
    await listening.cancel();
    await conn.execute("execute block as begin post_event 'ORDER_PAID'; end");
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(received, hasLength(2));
    await listener.close();
  });

  test('EXECUTE BLOCK with parameters and output rows', () async {
    final rows = await conn.query('''
      execute block (n integer = ?, label varchar(10) = ?)
      returns (i integer, txt varchar(20))
      as begin
        i = 1;
        while (i <= n) do begin
          txt = label || i;
          suspend;
          i = i + 1;
        end
      end''', [3, 'row']);
    expect(rows.map((r) => r['TXT']), ['row1', 'row2', 'row3']);

    // A block with RETURNS is a cursor: rows come only from SUSPEND.
    final noSuspend = await conn.query('''
      execute block (x integer = ?) returns (doubled integer)
      as begin doubled = x * 2; end''', [21]);
    expect(noSuspend, isEmpty);
    final single = await conn.query('''
      execute block (x integer = ?) returns (doubled integer)
      as begin doubled = x * 2; suspend; end''', [21]);
    expect(single.single['DOUBLED'], 42);

    await conn.execute('''
      execute block (k integer = @k) as begin
        insert into acc (id, name) values (:k, 'from block');
      end''', {'k': 7});
    expect(await conn.queryScalar<String>('select name from acc where id = 7'),
        'from block');
  });

  test('recursive CTE', () async {
    final stmt = await conn.prepare('insert into tree values (?, ?)');
    await stmt.executeBatch([
      [1, null],
      [2, 1],
      [3, 1],
      [4, 2],
      [5, 4],
    ]);
    await stmt.close();
    final rows = await conn.query('''
      with recursive descendants (id, depth) as (
        select id, 0 from tree where id = ?
        union all
        select t.id, d.depth + 1 from tree t join descendants d on t.parent = d.id
      )
      select id, depth from descendants order by depth, id''', [2]);
    expect(rows.map((r) => [r[0], r[1]]), [
      [2, 0],
      [4, 1],
      [5, 2],
    ]);
  });

  test('RETURNING, UPDATE OR INSERT and MERGE', () async {
    await conn.execute("insert into acc values (1, 'a', 10)");
    final updated = await conn.query(
        'update acc set balance = balance + ? where id = ? returning old.balance, new.balance',
        [5, 1]);
    expect(updated.single.values.map((v) => v.toString()), ['10.00', '15.00']);

    final upsert = await conn.query('''
      update or insert into acc (id, name, balance) values (?, ?, ?)
      matching (id) returning id, name''', [2, 'new', 1]);
    expect(upsert.single.toMap(), {'ID': 2, 'NAME': 'new'});
    await conn.query('''
      update or insert into acc (id, name, balance) values (?, ?, ?)
      matching (id) returning id''', [2, 'renamed', 1]);
    expect(await conn.queryScalar<String>('select name from acc where id = 2'),
        'renamed');

    final merged = await conn.execute('''
      merge into acc a
      using (select cast(? as integer) id, cast(? as varchar(40)) name from rdb\$database) s
      on a.id = s.id
      when matched then update set a.name = s.name
      when not matched then insert (id, name, balance) values (s.id, s.name, 0)''',
        [3, 'merged']);
    expect(merged, 1);

    final deleted =
        await conn.query('delete from acc where id = ? returning name', [3]);
    expect(deleted.single[0], 'merged');
  });

  test('autonomous transaction survives the caller rollback', () async {
    final tx = await conn.beginTransaction();
    await expectLater(
        tx.execute('execute procedure p_audit_then_fail(?)', ['attempt 1']),
        throwsA(isA<FbException>()
            .having((e) => e.hasCode(FbErrorCode.userException), 'user', true)
            .having((e) => e.message, 'message', contains('custom failure'))));
    await tx.rollback();
    expect(await conn.queryScalar<String>('select msg from audit_log'),
        'attempt 1');
  });

  // Firebird undoes the statement that raised the handled exception; the
  // statements of the block that ran before it are kept.
  test('PSQL WHEN handler undoes only the failing statement', () async {
    // The selectable procedure writes, so it runs in a write transaction.
    final ok = await conn.runInTransaction((tx) =>
        tx.queryScalar<int>('select ok from p_partial(?, ?)', [10, 11]));
    expect(ok, -1);
    expect(
        (await conn.query('select id, name from acc order by id'))
            .map((r) => '${r[0]}:${r[1]}'),
        ['10:first', '11:second']);
  });

  test('domain constraints and defaults', () async {
    await conn.execute('insert into acc (id, name) values (?, ?)', [1, 'd']);
    expect(
        (await conn.queryScalar('select balance from acc')).toString(), '0.00');
    await expectLater(
        conn.execute('insert into acc values (?, ?, ?)', [2, 'neg', -1]),
        throwsA(isA<FbException>()
            .having((e) => e.hasCode(FbErrorCode.notValid), 'notValid', true)));
  });

  test('database trigger ON CONNECT', () async {
    final fresh = await FbConnection.connect(testSettings(dbPath));
    expect(
        await fresh.queryScalar<String>(
            "select rdb\$get_context('USER_SESSION', 'CONNECTED_BY_TRIGGER') "
            'from rdb\$database'),
        'yes');
    await fresh.close();
  });

  test('sequences', () async {
    await conn.execute('create sequence seq_test');
    try {
      final a = await conn.queryScalar<int>(
          'select next value for seq_test from rdb\$database');
      final b = await conn
          .queryScalar<int>('select gen_id(seq_test, 10) from rdb\$database');
      expect(b, a! + 10);
    } finally {
      await conn.execute('drop sequence seq_test');
    }
  });
}
