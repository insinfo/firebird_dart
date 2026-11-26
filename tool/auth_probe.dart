// Diagnostic: opens many connections with the FB_* settings used by the
// integration tests and prints the handshake trace of each failure.
//
//   dart run tool/auth_probe.dart [attempts]
import 'dart:io';

import 'package:firebird_dart/firebird_dart.dart';
import 'package:firebird_dart/src/wire/wire.dart' show fbProtocolTrace;

import '../test/integration/config.dart';

Future<void> main(List<String> args) async {
  final attempts = args.isEmpty ? 40 : int.parse(args.first);
  final path = scratchDatabasePath();
  final trace = <String>[];
  fbProtocolTrace = trace.add;

  FbConnection? owner;
  for (var i = 0; i < 10 && owner == null; i++) {
    trace.clear();
    try {
      owner = await FbConnection.createDatabase(testSettings(path));
    } catch (e) {
      stdout.writeln('create attempt ${i + 1} failed: $e');
      for (final l in trace) {
        stdout.writeln("  $l");
      }
    }
  }
  if (owner == null) {
    stdout.writeln('could not create the probe database');
    exit(1);
  }
  stdout.writeln('server: ${await owner.serverInfo()}');

  var failures = 0;
  for (var i = 0; i < attempts; i++) {
    trace.clear();
    try {
      final c = await FbConnection.connect(testSettings(path));
      await c.close();
    } catch (e) {
      failures++;
      stdout.writeln('attempt ${i + 1} failed: $e');
      for (final l in trace) {
        stdout.writeln("  $l");
      }
    }
  }
  stdout.writeln('failures: $failures/$attempts');
  fbProtocolTrace = null;
  await owner.dropDatabase();
  exit(failures == 0 ? 0 : 1);
}
