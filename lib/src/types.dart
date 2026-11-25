import 'charset.dart';
import 'wire/constants.dart';

/// Exact decimal value of a Firebird `NUMERIC`/`DECIMAL` column:
/// `unscaled × 10^-scale`.
///
/// Firebird stores these types as scaled integers, so they are returned
/// without going through `double`. `NUMERIC(15,2)` 12.34 is
/// `FbDecimal(1234, 2)`; [toScaledInt] gives the amount in cents.
///
/// Values that fit 64 bits (every NUMERIC up to precision 18) are kept as
/// a plain `int`; `BigInt` is only used for INT128-based values.
class FbDecimal implements Comparable<FbDecimal> {
  final int _small;
  final BigInt? _big;
  final int scale;

  FbDecimal(int unscaled, this.scale)
      : _small = unscaled,
        _big = null {
    if (scale < 0) throw ArgumentError.value(scale, 'scale', 'must be >= 0');
  }

  FbDecimal.big(BigInt unscaled, this.scale)
      : _small = unscaled.isValidInt ? unscaled.toInt() : 0,
        _big = unscaled.isValidInt ? null : unscaled {
    if (scale < 0) throw ArgumentError.value(scale, 'scale', 'must be >= 0');
  }

  /// Parses decimal text such as `-123.4500`, `12` or `+0.5`.
  factory FbDecimal.parse(String text) {
    final s = text.trim();
    final m = _decimalPattern.firstMatch(s);
    if (m == null || (m.group(2)!.isEmpty && (m.group(3) ?? '').isEmpty)) {
      throw FormatException('Invalid decimal', text);
    }
    final intPart = m.group(2)!.isEmpty ? '0' : m.group(2)!;
    final frac = m.group(3) ?? '';
    var value = BigInt.parse(intPart + frac);
    if (m.group(1) == '-') value = -value;
    return FbDecimal.big(value, frac.length);
  }

  static final RegExp _decimalPattern = RegExp(r'^([+-]?)(\d*)(?:\.(\d*))?$');

  /// Converts [value] by its shortest decimal representation.
  factory FbDecimal.fromDouble(double value) {
    if (!value.isFinite) {
      throw ArgumentError.value(value, 'value', 'must be finite');
    }
    var text = value.toString();
    if (text.contains('e') || text.contains('E')) {
      text = value.toStringAsFixed(20);
    }
    return FbDecimal.parse(text);
  }

  static final BigInt _ten = BigInt.from(10);

  /// Unscaled value as a BigInt.
  BigInt get unscaled => _big ?? BigInt.from(_small);

  /// Whether the unscaled value fits a signed 64-bit integer.
  bool get fitsInt64 => _big == null;

  /// Unscaled value as an int. Throws when it does not fit 64 bits.
  int get unscaledInt {
    if (_big != null) throw StateError('$this does not fit in 64 bits');
    return _small;
  }

  bool get isNegative => _big?.isNegative ?? _small < 0;

  /// Value rescaled to [newScale]. Increasing the scale is exact; reducing
  /// it rounds half away from zero.
  FbDecimal rescale(int newScale) {
    if (newScale == scale) return this;
    final u = unscaled;
    if (newScale > scale) {
      return FbDecimal.big(u * _ten.pow(newScale - scale), newScale);
    }
    final div = _ten.pow(scale - newScale);
    var q = u ~/ div;
    final r = (u - q * div).abs();
    if (r * BigInt.two >= div) q += u.isNegative ? -BigInt.one : BigInt.one;
    return FbDecimal.big(q, newScale);
  }

  /// Integer of the value at [targetScale] (2 → cents). Throws when the
  /// conversion would lose digits, unless [round] is true.
  int toScaledInt(int targetScale, {bool round = false}) {
    if (targetScale == scale && _big == null) return _small;
    if (!round && targetScale < scale) {
      final div = _ten.pow(scale - targetScale);
      if (unscaled % div != BigInt.zero) {
        throw StateError('$this cannot be represented with scale '
            '$targetScale without rounding');
      }
    }
    final v = rescale(targetScale).unscaled;
    if (!v.isValidInt) throw StateError('$this does not fit in an int');
    return v.toInt();
  }

  double toDouble() => double.parse(toString());

  /// Integer part, truncated toward zero.
  int toInt() => (unscaled ~/ _ten.pow(scale)).toInt();

  /// Same value without trailing fractional zeros.
  FbDecimal normalize() {
    var u = unscaled;
    var s = scale;
    while (s > 0 && u % _ten == BigInt.zero) {
      u = u ~/ _ten;
      s--;
    }
    return FbDecimal.big(u, s);
  }

  @override
  int compareTo(FbDecimal other) {
    if (scale == other.scale && _big == null && other._big == null) {
      return _small.compareTo(other._small);
    }
    final s = scale > other.scale ? scale : other.scale;
    return rescale(s).unscaled.compareTo(other.rescale(s).unscaled);
  }

  @override
  bool operator ==(Object other) => other is FbDecimal && compareTo(other) == 0;

  @override
  int get hashCode {
    final n = normalize();
    return Object.hash(n.unscaled, n.scale);
  }

  String toJson() => toString();

  @override
  String toString() {
    final digitsSigned = _big?.toString() ?? _small.toString();
    if (scale == 0) return digitsSigned;
    final neg = digitsSigned.startsWith('-');
    var digits = neg ? digitsSigned.substring(1) : digitsSigned;
    if (digits.length <= scale) digits = digits.padLeft(scale + 1, '0');
    final cut = digits.length - scale;
    return '${neg ? '-' : ''}${digits.substring(0, cut)}.${digits.substring(cut)}';
  }
}

/// Kind of a prepared statement, as reported by the server.
enum FbStatementType {
  select(isc_info_sql_stmt_select),
  insert(isc_info_sql_stmt_insert),
  update(isc_info_sql_stmt_update),
  delete(isc_info_sql_stmt_delete),
  ddl(isc_info_sql_stmt_ddl),
  getSegment(isc_info_sql_stmt_get_segment),
  putSegment(isc_info_sql_stmt_put_segment),
  execProcedure(isc_info_sql_stmt_exec_procedure),
  startTransaction(isc_info_sql_stmt_start_trans),
  commit(isc_info_sql_stmt_commit),
  rollback(isc_info_sql_stmt_rollback),
  selectForUpdate(isc_info_sql_stmt_select_for_upd),
  setGenerator(isc_info_sql_stmt_set_generator),
  savepoint(isc_info_sql_stmt_savepoint),
  unknown(0);

  final int code;
  const FbStatementType(this.code);

  static FbStatementType fromCode(int code) => FbStatementType.values
      .firstWhere((t) => t.code == code, orElse: () => FbStatementType.unknown);

  bool get returnsCursor =>
      this == FbStatementType.select || this == FbStatementType.selectForUpdate;
}

/// Description of a result column or of an input parameter (XSQLVAR).
class FbColumn {
  /// SQL type without the nullable bit (`SQL_VARYING`, `SQL_LONG`...).
  int sqlType = 0;
  int subType = 0;
  int scale = 0;
  int length = 0;
  bool nullable = true;
  String fieldName = '';
  String relationName = '';
  String ownerName = '';
  String alias = '';

  FbColumn();

  /// Name used for map keys: the alias, or the field name.
  String get name => alias.isNotEmpty ? alias : fieldName;

  /// Character set id of a text column (low byte of the subtype).
  int get charsetId => subType & 0xFF;

  bool get isText => sqlType == SQL_TEXT || sqlType == SQL_VARYING;
  bool get isBlob => sqlType == SQL_BLOB;
  bool get isTextBlob => sqlType == SQL_BLOB && subType == 1;

  /// Whether the column is an exact numeric with decimals.
  bool get isScaledNumeric =>
      scale < 0 &&
      (sqlType == SQL_SHORT ||
          sqlType == SQL_LONG ||
          sqlType == SQL_INT64 ||
          sqlType == SQL_INT128);

  /// SQL-like type name, e.g. `VARCHAR(60)`, `NUMERIC(18,2)`, `BLOB SUB_TYPE 1`.
  String get typeName {
    switch (sqlType) {
      case SQL_TEXT:
        return 'CHAR($length)';
      case SQL_VARYING:
        return 'VARCHAR($length)';
      case SQL_SHORT:
      case SQL_LONG:
      case SQL_INT64:
      case SQL_INT128:
        if (scale < 0 || subType == 1 || subType == 2) {
          // The wire protocol does not carry the declared precision; show
          // the maximum precision of the storage type.
          final precision = switch (sqlType) {
            SQL_SHORT => 4,
            SQL_LONG => 9,
            SQL_INT64 => 18,
            _ => 38,
          };
          return '${subType == 2 ? 'DECIMAL' : 'NUMERIC'}'
              '($precision,${-scale})';
        }
        return switch (sqlType) {
          SQL_SHORT => 'SMALLINT',
          SQL_LONG => 'INTEGER',
          SQL_INT64 => 'BIGINT',
          _ => 'INT128',
        };
      case SQL_FLOAT:
        return 'FLOAT';
      case SQL_DOUBLE:
      case SQL_D_FLOAT:
        return 'DOUBLE PRECISION';
      case SQL_TIMESTAMP:
        return 'TIMESTAMP';
      case SQL_TYPE_DATE:
        return 'DATE';
      case SQL_TYPE_TIME:
        return 'TIME';
      case SQL_BLOB:
        return 'BLOB SUB_TYPE $subType';
      case SQL_ARRAY:
        return 'ARRAY';
      case SQL_BOOLEAN:
        return 'BOOLEAN';
      case SQL_NULL:
        return 'NULL';
      case SQL_TIMESTAMP_TZ:
      case SQL_TIMESTAMP_TZ_EX:
        return 'TIMESTAMP WITH TIME ZONE';
      case SQL_TIME_TZ:
      case SQL_TIME_TZ_EX:
        return 'TIME WITH TIME ZONE';
      case SQL_DEC16:
        return 'DECFLOAT(16)';
      case SQL_DEC34:
        return 'DECFLOAT(34)';
      default:
        return 'UNKNOWN($sqlType)';
    }
  }

  /// Character set name of a text column.
  String get charsetName => FbCharset.names[charsetId] ?? 'id $charsetId';

  @override
  String toString() => 'FbColumn($name $typeName${nullable ? '' : ' NOT NULL'}'
      '${relationName.isEmpty ? '' : ' from $relationName.$fieldName'})';
}

// ---------------------------------------------------------------------------
// Date and time encoding.
//
// Firebird DATE is the number of days since 1858-11-17 (Modified Julian
// Day); TIME is the number of 1/10000 second units since midnight.
// Values are naive (no time zone): the driver returns them as UTC
// DateTime objects whose fields are the stored wall-clock values, and it
// encodes any DateTime by its own year/month/day/... fields.
// ---------------------------------------------------------------------------

const int _mjdOfUnixEpoch = 40587;
const int _msPerDay = 86400000;

int encodeFbDate(int year, int month, int day) {
  final ms = DateTime.utc(year, month, day).millisecondsSinceEpoch;
  return (ms ~/ _msPerDay) + _mjdOfUnixEpoch;
}

DateTime decodeFbDate(int days) =>
    DateTime.fromMillisecondsSinceEpoch((days - _mjdOfUnixEpoch) * _msPerDay,
        isUtc: true);

int encodeFbTime(int hour, int minute, int second, int microsecond) =>
    ((hour * 60 + minute) * 60 + second) * 10000 + microsecond ~/ 100;

Duration decodeFbTime(int ticks) => Duration(microseconds: ticks * 100);

DateTime decodeFbTimestamp(int days, int ticks) =>
    DateTime.fromMicrosecondsSinceEpoch(
        (days - _mjdOfUnixEpoch) * _msPerDay * 1000 + ticks * 100,
        isUtc: true);
