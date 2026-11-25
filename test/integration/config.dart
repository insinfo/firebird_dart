import 'dart:io';
import 'dart:math';

import 'package:firebird_dart/firebird_dart.dart';

/// Integration tests need a running Firebird server. Configure with:
///
/// - `FB_HOST` (localhost), `FB_PORT` (3050), `FB_USER` (SYSDBA),
///   `FB_PASSWORD` (masterkey);
/// - `FB_TEST_DIR`: server-side directory where a scratch database is
///   created and dropped (default: the system temp directory, which works
///   when the server runs on this machine);
/// - `FB_LEGACY_DB`: optional path of an existing database, read-only
///   tests (skipped when unset).
final env = Platform.environment;

String get testHost => env['FB_HOST'] ?? 'localhost';
int get testPort => int.parse(env['FB_PORT'] ?? '3050');
String get testUser => env['FB_USER'] ?? 'SYSDBA';
String get testPassword => env['FB_PASSWORD'] ?? 'masterkey';
String? get legacyDb => env['FB_LEGACY_DB'];

String scratchDatabasePath() {
  final dir = env['FB_TEST_DIR'] ?? Directory.systemTemp.path;
  final id =
      '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 30)}';
  return '$dir${Platform.pathSeparator}firebird_dart_test_$id.fdb';
}

FbConnectionSettings testSettings(String database, {String charset = 'UTF8'}) =>
    FbConnectionSettings(
      host: testHost,
      port: testPort,
      database: database,
      user: testUser,
      password: testPassword,
      charset: charset,
    );
