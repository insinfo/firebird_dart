import 'dart:convert';
import 'dart:typed_data';

import 'package:firebird_dart/firebird_dart.dart';
import 'package:firebird_dart/src/auth/srp.dart';
import 'package:firebird_dart/src/auth/unix_crypt.dart';
import 'package:firebird_dart/src/crypto/hash.dart';
import 'package:firebird_dart/src/sql_params.dart';
import 'package:firebird_dart/src/types.dart';
import 'package:firebird_dart/src/wire/xdr.dart';
import 'package:test/test.dart';

void main() {
  group('XDR', () {
    test('writer pads opaque data and buffers', () {
      final w = XdrWriter(4)
        ..int32(-1)
        ..buffer([1, 2, 3])
        ..int64(0x0102030405060708);
      expect(w.toBytes(), [
        0xFF, 0xFF, 0xFF, 0xFF, //
        0, 0, 0, 3, 1, 2, 3, 0,
        1, 2, 3, 4, 5, 6, 7, 8,
      ]);
    });

    test('input buffer waits for data across chunks', () async {
      final b = InputBuffer();
      final f = b.xdrBuffer();
      b.add([0, 0, 0, 5, 104, 101]);
      b.add([108, 108, 111, 0, 0, 0]);
      expect(utf8.decode(await f), 'hello');
      expect(b.available, 0);
    });

    test('input buffer grows and compacts', () async {
      final b = InputBuffer();
      final big = Uint8List(200000)..[199999] = 7;
      b.add([0, 3, 13, 64]); // int 200000
      b.add(big);
      final len = await b.int32();
      expect(len, 200000);
      final data = await b.bytes(len);
      expect(data[199999], 7);
    });

    test('closed input fails pending reads', () async {
      final b = InputBuffer();
      final f = b.int32();
      b.close(FbConnectionException('gone'));
      await expectLater(f, throwsA(isA<FbConnectionException>()));
    });

    test('little-endian info integers', () {
      expect(leInt(Uint8List.fromList([0x34, 0x12]), 0, 2), 0x1234);
      expect(leInt(Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF]), 0, 4), -1);
    });
  });

  group('legacy authentication', () {
    test('crypt(3) known vectors', () {
      expect(unixCrypt('test', 'aa'), 'aaqPiZY5xR5l.');
      expect(unixCrypt('password', 'ab'), 'abJnggxhB/yWI');
    });

    test('only 8 characters are significant', () {
      expect(unixCrypt('masterkey', '9z'), unixCrypt('masterke', '9z'));
      expect(firebirdLegacyPasswordHash('masterkey'), hasLength(11));
    });
  });

  group('crypto', () {
    test('SHA-1 and SHA-256 vectors', () {
      expect(bytesToHex(Digest.sha1(utf8.encode('abc'))),
          'a9993e364706816aba3e25717850c26c9cd0d89d');
      expect(bytesToHex(Digest.sha256(utf8.encode('abc'))),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(
          bytesToHex(Digest.sha256(utf8.encode(
              'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))),
          '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
      expect(bytesToHex(Digest.sha1(const [])),
          'da39a3ee5e6b4b0d3255bfef95601890afd80709');
    });

    test('ARC4 vector', () {
      expect(
          bytesToHex(
              Arc4(utf8.encode('Key')).process(utf8.encode('Plaintext'))),
          'bbf316e8d940af0ad3');
    });

    test('SRP group constants match Firebird', () {
      expect(SrpClient.prime.bitLength, 1024);
      expect(SrpClient.multiplier.toString(),
          '1277432915985975349439481660349303019122249719989');
    });

    test('SRP proof is deterministic for a fixed private key', () {
      final c = SrpClient(BigInt.from(123456789));
      final serverKey =
          BigInt.two.modPow(BigInt.from(987654321), SrpClient.prime);
      final a = c.clientProof(
          user: 'SYSDBA',
          password: 'masterkey',
          salt: List.filled(32, 1),
          serverPublicKey: serverKey,
          sha256Proof: true);
      final b = c.clientProof(
          user: 'SYSDBA',
          password: 'masterkey',
          salt: List.filled(32, 1),
          serverPublicKey: serverKey,
          sha256Proof: true);
      expect(a.proof, hasLength(32));
      expect(a.sessionKey, hasLength(20));
      expect(a.proof, b.proof);
    });
  });

  group('FbDecimal', () {
    test('formats scaled values', () {
      expect(FbDecimal(1234, 2).toString(), '12.34');
      expect(FbDecimal(-5, 2).toString(), '-0.05');
      expect(FbDecimal(0, 4).toString(), '0.0000');
      expect(FbDecimal(7, 0).toString(), '7');
    });

    test('parses and compares', () {
      expect(FbDecimal.parse('12.50'), FbDecimal(125, 1));
      expect(FbDecimal.parse('-0.5').toString(), '-0.5');
      expect(FbDecimal.parse('3').scale, 0);
      expect(() => FbDecimal.parse('1e3'), throwsFormatException);
      expect(FbDecimal(100, 2).compareTo(FbDecimal(2, 0)) < 0, isTrue);
    });

    test('cents conversion is exact or explicit', () {
      expect(FbDecimal(1234, 2).toScaledInt(2), 1234);
      expect(FbDecimal(12, 0).toScaledInt(2), 1200);
      expect(() => FbDecimal(12345, 3).toScaledInt(2), throwsStateError);
      expect(FbDecimal(12345, 3).toScaledInt(2, round: true), 1235);
      expect(FbDecimal(-12345, 3).toScaledInt(2, round: true), -1235);
    });

    test('big values', () {
      final d =
          FbDecimal.big(BigInt.parse('123456789012345678901234567890'), 4);
      expect(d.fitsInt64, isFalse);
      expect(d.toString(), '12345678901234567890123456.7890');
    });
  });

  group('date and time', () {
    test('Firebird day numbers', () {
      expect(encodeFbDate(1858, 11, 17), 0);
      expect(encodeFbDate(1970, 1, 1), 40587);
      expect(decodeFbDate(40587), DateTime.utc(1970));
      expect(
          decodeFbDate(encodeFbDate(1600, 2, 29)), DateTime.utc(1600, 2, 29));
      expect(
          decodeFbDate(encodeFbDate(9999, 12, 31)), DateTime.utc(9999, 12, 31));
    });

    test('time ticks are 1/10000 s', () {
      expect(encodeFbTime(23, 59, 59, 999900), 863999999);
      expect(
          decodeFbTime(863999999),
          const Duration(
              hours: 23, minutes: 59, seconds: 59, microseconds: 999900));
      expect(
          decodeFbTimestamp(40587, 10000), DateTime.utc(1970, 1, 1, 0, 0, 1));
    });
  });

  group('named parameters', () {
    test('rewrites @name outside literals and comments', () {
      final n = parseNamedSql(
          "select '@no', \"@x\" from t -- @c\n where a = @a and b = @b /* @d */ and c = @a");
      expect(n.sql,
          "select '@no', \"@x\" from t -- @c\n where a = ? and b = ? /* @d */ and c = ?");
      expect(n.names, ['a', 'b', 'a']);
      expect(n.bind({'a': 1, 'b': 2}), [1, 2, 1]);
    });

    test('ignores postgres_fork type hints and keeps PSQL :vars', () {
      final n = parseNamedSql('insert into t values (@id:int4, :local)');
      expect(n.sql, 'insert into t values (?, :local)');
    });

    test('missing values fail', () {
      expect(() => parseNamedSql('select @x from t').bind({}),
          throwsA(isA<FbUsageException>()));
    });

    test('resolveParams accepts lists and maps', () {
      expect(resolveParams('select ?', [1]).$2, [1]);
      expect(resolveParams('select @v', {'v': 2}).$1, 'select ?');
      expect(() => resolveParams('x', 3), throwsA(isA<FbUsageException>()));
    });
  });

  group('charsets', () {
    test('Windows-1252 round trip', () {
      const text = 'Ação € “aspas” – Œ ž';
      final bytes = windows1252.encode(text);
      expect(bytes.length, text.length);
      expect(bytes[text.indexOf('€')], 0x80);
      expect(windows1252.decode(bytes), text);
      final all = List<int>.generate(256, (i) => i);
      expect(windows1252.encode(windows1252.decode(all)), all);
    });

    test('charset lookup', () {
      expect(FbCharset.byName('utf-8'), FbCharset.utf8);
      expect(FbCharset.byName('win1252'), FbCharset.win1252);
      expect(() => FbCharset.byName('KOI8R'), throwsArgumentError);
    });
  });

  group('settings', () {
    test('DSN parsing', () {
      final a = FbConnectionSettings.fromDsn(
          r'10.0.0.5:c:\data\app.fdb');
      expect(a.host, '10.0.0.5');
      expect(a.port, 3050);
      expect(a.database, r'c:\data\app.fdb');
      final b = FbConnectionSettings.fromDsn('srv/3051:/data/x.fdb');
      expect((b.host, b.port, b.database), ('srv', 3051, '/data/x.fdb'));
      final c = FbConnectionSettings.fromDsn(r'C:\db\x.fdb');
      expect((c.host, c.database), ('localhost', r'C:\db\x.fdb'));
    });

    test('TPB encoding', () {
      expect(const FbTransactionOptions().toTpb(), [3, 9, 15, 17, 6]);
      expect(
          const FbTransactionOptions(
                  isolation: FbIsolation.snapshot, readOnly: true, wait: false)
              .toTpb(),
          [3, 8, 2, 7]);
      expect(const FbTransactionOptions(lockTimeout: 5).toTpb(),
          [3, 9, 15, 17, 6, 21, 4, 5, 0, 0, 0]);
    });
  });

  group('errors', () {
    test('formats status entries with arguments', () {
      final e = FbException.fromStatus([
        const FbStatusEntry(335544569, []),
        const FbStatusEntry(335544436, [-104]),
        const FbStatusEntry(335544634, [1, 8]),
      ]);
      expect(e.sqlCode, -104);
      expect(e.message,
          'Dynamic SQL Error\nSQL error code = -104\nToken unknown - line 1, column 8');
      expect(e.errorCode, 335544569);
      expect(e.hasCode(FbErrorCode.tokenUnknown), isTrue);
    });

    test('unknown codes fall back to the symbolic name', () {
      expect(
          const FbStatusEntry(335544322, ['x']).format(), 'isc_bad_dbkey: x');
    });
  });
}
