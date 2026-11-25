import 'error_codes.dart';
import 'error_messages.dart';
import 'wire/constants.dart';

/// One entry of a Firebird status vector: a status code and its arguments.
class FbStatusEntry {
  final int code;
  final List<Object> args;
  final bool isWarning;

  const FbStatusEntry(this.code, this.args, {this.isWarning = false});

  String? get name => fbErrorCodeNames[code];

  String format() {
    final template = fbErrorMessages[code];
    if (template == null) {
      final label = name ?? 'Firebird error $code';
      return args.isEmpty ? label : '$label: ${args.join(', ')}';
    }
    var text = template;
    for (var i = args.length; i >= 1; i--) {
      text = text.replaceAll('@$i', '${args[i - 1]}');
    }
    return text;
  }

  @override
  String toString() => format();
}

/// Error reported by the Firebird server or raised by the driver.
class FbException implements Exception {
  /// Human-readable message, one line per status entry.
  final String message;

  /// Status entries in the order sent by the server.
  final List<FbStatusEntry> entries;

  /// SQLCODE taken from the `isc_sqlerr` entry, when the server sent one.
  final int? sqlCode;

  /// SQLSTATE (Firebird 3+ only).
  final String? sqlState;

  FbException(this.message,
      {this.entries = const [], this.sqlCode, this.sqlState});

  /// Builds the exception from a parsed status vector.
  factory FbException.fromStatus(List<FbStatusEntry> entries,
      {String? sqlState}) {
    int? sqlCode;
    final lines = <String>[];
    for (final e in entries) {
      if (e.isWarning) continue;
      if (e.code == isc_sqlerr && e.args.isNotEmpty && e.args.first is int) {
        sqlCode = e.args.first as int;
      }
      lines.add(e.format());
    }
    return FbException(lines.join('\n'),
        entries: entries, sqlCode: sqlCode, sqlState: sqlState);
  }

  /// First (primary) status code, or 0 for driver-side errors.
  int get errorCode => entries.isEmpty ? 0 : entries.first.code;

  /// All status codes in the vector.
  List<int> get errorCodes => [
        for (final e in entries)
          if (!e.isWarning) e.code
      ];

  /// Whether [code] appears anywhere in the status vector.
  bool hasCode(int code) => entries.any((e) => e.code == code);

  @override
  String toString() {
    final buf = StringBuffer('FbException');
    if (sqlCode != null) buf.write(' (SQLCODE $sqlCode)');
    if (sqlState != null) buf.write(' [SQLSTATE $sqlState]');
    buf.write(': $message');
    return buf.toString();
  }
}

/// Network failure, protocol violation or use of a closed connection.
/// The connection that raised it is no longer usable.
class FbConnectionException extends FbException {
  final Object? cause;

  FbConnectionException(super.message, {this.cause});

  @override
  String toString() =>
      'FbConnectionException: $message${cause == null ? '' : ' ($cause)'}';
}

/// Invalid use of the driver API (wrong parameter count, closed statement,
/// unsupported value type...).
class FbUsageException extends FbException {
  FbUsageException(super.message);

  @override
  String toString() => 'FbUsageException: $message';
}
