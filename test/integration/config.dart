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
///   tests (skipped when unset);
/// - `FB_AUTH`: authentication plugins to offer, comma separated
///   (`srp256,srp,legacy`; default all three);
/// - `FB_WIRE_CRYPT`: `enabled` (default), `required` or `disabled`;
/// - `FB_EXPECT_AUTH` / `FB_EXPECT_ENCRYPTED`: when set, the tests check the
///   negotiated plugin name and whether the traffic is encrypted.
final env = Platform.environment;

String get testHost => env['FB_HOST'] ?? 'localhost';
int get testPort => int.parse(env['FB_PORT'] ?? '3050');
String get testUser => env['FB_USER'] ?? 'SYSDBA';
String get testPassword => env['FB_PASSWORD'] ?? 'masterkey';
String? get legacyDb => env['FB_LEGACY_DB'];
String? get expectedAuth => env['FB_EXPECT_AUTH'];
bool? get expectedEncrypted => switch (env['FB_EXPECT_ENCRYPTED']) {
      'true' => true,
      'false' => false,
      _ => null,
    };

List<FbAuthPlugin> get testAuthPlugins {
  final raw = env['FB_AUTH'];
  if (raw == null || raw.trim().isEmpty) {
    return const [
      FbAuthPlugin.srp256,
      FbAuthPlugin.srp,
      FbAuthPlugin.legacyAuth
    ];
  }
  return [
    for (final p in raw.split(','))
      switch (p.trim().toLowerCase()) {
        'srp256' => FbAuthPlugin.srp256,
        'srp' => FbAuthPlugin.srp,
        'legacy' || 'legacy_auth' => FbAuthPlugin.legacyAuth,
        final other => throw ArgumentError('Unknown FB_AUTH plugin: $other'),
      },
  ];
}

FbWireCrypt get testWireCrypt => switch (env['FB_WIRE_CRYPT']) {
      'required' => FbWireCrypt.required,
      'disabled' => FbWireCrypt.disabled,
      _ => FbWireCrypt.enabled,
    };

String scratchDatabasePath() {
  final dir = env['FB_TEST_DIR'] ?? Directory.systemTemp.path;
  // The path is resolved by the server, which may run another OS.
  final separator = dir.contains(r'\') ? r'\' : '/';
  final id =
      '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 30)}';
  return '$dir${dir.endsWith(separator) ? '' : separator}'
      'firebird_dart_test_$id.fdb';
}

FbConnectionSettings testSettings(String database, {String charset = 'UTF8'}) =>
    FbConnectionSettings(
      host: testHost,
      port: testPort,
      database: database,
      user: testUser,
      password: testPassword,
      charset: charset,
      authPlugins: testAuthPlugins,
      wireCrypt: testWireCrypt,
    );
