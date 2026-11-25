import 'dart:convert';
import 'dart:typed_data';

import '../charset.dart';
import '../exceptions.dart';
import '../settings.dart';
import '../types.dart';
import 'constants.dart';
import 'wire.dart';
import 'xdr.dart';

/// Encodes and decodes the messages exchanged by `op_execute`/`op_fetch`:
/// the BLR that describes them and their XDR data.
class MessageCodec {
  final FbWire wire;
  final bool trimChar;

  final FbNumericMode numericMode;

  MessageCodec(this.wire,
      {this.trimChar = false, this.numericMode = FbNumericMode.decimal});

  bool get _p13 => wire.isProtocol13;

  // -------------------------------------------------------------------------
  // Output messages (result rows).
  // -------------------------------------------------------------------------

  /// BLR describing [columns] as an output message.
  static Uint8List outputBlr(List<FbColumn> columns) {
    final n = columns.length * 2;
    final b = BytesBuilder()
      ..add([blr_version5, blr_begin, blr_message, 0, n & 0xFF, n >> 8]);
    for (final c in columns) {
      switch (c.sqlType) {
        case SQL_VARYING:
          b.add([blr_varying, c.length & 0xFF, c.length >> 8]);
        case SQL_TEXT:
          b.add([blr_text, c.length & 0xFF, c.length >> 8]);
        case SQL_SHORT:
          b.add([blr_short, c.scale & 0xFF]);
        case SQL_LONG:
          b.add([blr_long, c.scale & 0xFF]);
        case SQL_INT64:
          b.add([blr_int64, c.scale & 0xFF]);
        case SQL_INT128:
          b.add([blr_int128, c.scale & 0xFF]);
        case SQL_QUAD:
          b.add([blr_quad, c.scale & 0xFF]);
        case SQL_FLOAT:
          b.addByte(blr_float);
        case SQL_DOUBLE:
          b.addByte(blr_double);
        case SQL_D_FLOAT:
          b.addByte(blr_d_float);
        case SQL_TYPE_DATE:
          b.addByte(blr_sql_date);
        case SQL_TYPE_TIME:
          b.addByte(blr_sql_time);
        case SQL_TIMESTAMP:
          b.addByte(blr_timestamp);
        case SQL_BLOB:
        case SQL_ARRAY:
          b.add([blr_quad, 0]);
        case SQL_BOOLEAN:
          b.addByte(blr_bool);
        case SQL_DEC16:
          b.addByte(blr_dec64);
        case SQL_DEC34:
          b.addByte(blr_dec128);
        case SQL_TIME_TZ:
          b.addByte(blr_sql_time_tz);
        case SQL_TIMESTAMP_TZ:
          b.addByte(blr_timestamp_tz);
        case SQL_NULL:
          b.add([blr_text, 0, 0]);
        default:
          throw FbUsageException(
              'Unsupported column type ${c.sqlType} (${c.name})');
      }
      b.add([blr_short, 0]);
    }
    b.add([blr_end, blr_eoc]);
    return b.toBytes();
  }

  /// Bytes taken on the wire by a fixed-size value (padding included).
  static int fixedLength(FbColumn c) {
    switch (c.sqlType) {
      case SQL_TEXT:
        return c.length + xdrPad(c.length);
      case SQL_SHORT:
      case SQL_LONG:
      case SQL_FLOAT:
      case SQL_TYPE_DATE:
      case SQL_TYPE_TIME:
      case SQL_BOOLEAN:
        return 4;
      case SQL_INT64:
      case SQL_DOUBLE:
      case SQL_D_FLOAT:
      case SQL_TIMESTAMP:
      case SQL_BLOB:
      case SQL_ARRAY:
      case SQL_QUAD:
      case SQL_DEC16:
      case SQL_TIME_TZ:
        return 8;
      case SQL_INT128:
      case SQL_DEC34:
        return 16;
      case SQL_TIMESTAMP_TZ:
        return 12;
      case SQL_NULL:
        return 0;
      default:
        throw FbUsageException('Unsupported column type ${c.sqlType}');
    }
  }

  /// Decodes text bytes of column [c].
  Object decodeText(Uint8List bytes, FbColumn c) {
    final cs = c.charsetId;
    if (cs == FbCharset.octets.id) return Uint8List.fromList(bytes);
    final Encoding codec;
    if (cs == FbCharset.none.id) {
      codec = wire.noneCodec;
    } else {
      codec = FbCharset.byId(cs)?.encoding ?? wire.textCodec;
    }
    final s = codec.decode(bytes);
    if (c.sqlType == SQL_TEXT) {
      if (trimChar) return s.trimRight();
      // CHAR(n) in a multi-byte charset arrives padded to n * bytesPerChar
      // bytes; keep only the n declared characters.
      final bpc = _bytesPerChar(cs);
      if (bpc > 1) {
        final chars = c.length ~/ bpc;
        if (s.length > chars) {
          var end = s.length;
          while (end > chars && s.codeUnitAt(end - 1) == 0x20) {
            end--;
          }
          return end == s.length ? s : s.substring(0, end);
        }
      }
    }
    return s;
  }

  int _bytesPerChar(int charsetId) {
    if (charsetId == FbCharset.utf8.id) return 4;
    if (charsetId == FbCharset.unicodeFss.id) return 3;
    return FbCharset.byId(charsetId)?.bytesPerChar ?? 1;
  }

  /// Reads one row of [columns]; blob columns yield [FbBlobId].
  Future<List<Object?>> readRow(List<FbColumn> columns) async {
    final input = wire.input;
    final n = columns.length;
    final row = List<Object?>.filled(n, null);
    Uint8List? nullBitmap;
    if (_p13) {
      final len = (n + 7) >> 3;
      final padded = len + xdrPad(len);
      final f = input.need(padded);
      if (f != null) await f;
      nullBitmap = input.readBytes(len);
      input.skip(padded - len);
    }
    final indLen = _p13 ? 0 : 4;
    for (var i = 0; i < n; i++) {
      if (nullBitmap != null && (nullBitmap[i >> 3] & (1 << (i & 7))) != 0) {
        continue;
      }
      final c = columns[i];
      if (c.sqlType == SQL_VARYING) {
        var f = input.need(4);
        if (f != null) await f;
        final len = input.readInt32();
        final padded = len + xdrPad(len);
        f = input.need(padded + indLen);
        if (f != null) await f;
        if (!_p13 && input.peekInt32(padded) != 0) {
          input.skip(padded + 4);
          continue;
        }
        row[i] = decodeText(input.peekView(len), c);
        input.skip(padded + indLen);
        continue;
      }
      final size = fixedLength(c);
      final f = input.need(size + indLen);
      if (f != null) await f;
      if (!_p13 && input.peekInt32(size) != 0) {
        input.skip(size + 4);
        continue;
      }
      row[i] = _decodeFixed(c, size);
      if (indLen != 0) input.skip(4);
    }
    return row;
  }

  Object? _decodeFixed(FbColumn c, int size) {
    final input = wire.input;
    switch (c.sqlType) {
      case SQL_TEXT:
        final v = decodeText(input.peekView(c.length), c);
        input.skip(size);
        return v;
      case SQL_SHORT:
      case SQL_LONG:
        final v = input.readInt32();
        return c.scale < 0 ? _decimal(FbDecimal(v, -c.scale)) : v;
      case SQL_INT64:
        final v = input.readInt64();
        return c.scale < 0 ? _decimal(FbDecimal(v, -c.scale)) : v;
      case SQL_INT128:
        final bytes = input.readBytes(16);
        var v = BigInt.zero;
        for (final b in bytes) {
          v = (v << 8) | BigInt.from(b);
        }
        if (bytes[0] & 0x80 != 0) v -= BigInt.one << 128;
        return c.scale < 0 ? _decimal(FbDecimal.big(v, -c.scale)) : v;
      case SQL_FLOAT:
        return input.readFloat32();
      case SQL_DOUBLE:
      case SQL_D_FLOAT:
        return input.readFloat64();
      case SQL_TYPE_DATE:
        return decodeFbDate(input.readInt32());
      case SQL_TYPE_TIME:
        return decodeFbTime(input.readUint32());
      case SQL_TIMESTAMP:
        final days = input.readInt32();
        return decodeFbTimestamp(days, input.readUint32());
      case SQL_BLOB:
      case SQL_ARRAY:
      case SQL_QUAD:
        return FbBlobId(input.readBytes(8));
      case SQL_BOOLEAN:
        final v = input.readByte() != 0;
        input.skip(3);
        return v;
      case SQL_TIME_TZ:
        final t = decodeFbTime(input.readUint32());
        input.skip(4); // time zone id + padding
        return t;
      case SQL_TIMESTAMP_TZ:
        final days = input.readInt32();
        final ts = decodeFbTimestamp(days, input.readUint32());
        input.skip(4);
        return ts;
      case SQL_DEC16:
      case SQL_DEC34:
        // DECFLOAT values are returned in their IEEE 754 encoding.
        return input.readBytes(size);
      case SQL_NULL:
        return null;
    }
    throw FbUsageException('Unsupported column type ${c.sqlType}');
  }

  Object _decimal(FbDecimal d) => switch (numericMode) {
        FbNumericMode.decimal => d,
        FbNumericMode.string => d.toString(),
        FbNumericMode.double => d.toDouble(),
      };

  // -------------------------------------------------------------------------
  // Input messages (parameters).
  // -------------------------------------------------------------------------

  /// Builds the BLR and data of an input message. BLOB parameters must
  /// already be converted to [FbBlobId].
  ({Uint8List blr, Uint8List data}) encodeParams(
      List<FbColumn> params, List<Object?> values) {
    final n = params.length * 2;
    final blr = BytesBuilder()
      ..add([blr_version5, blr_begin, blr_message, 0, n & 0xFF, n >> 8]);
    final data = XdrWriter(64 + params.length * 16);
    if (_p13) {
      final len = (params.length + 7) >> 3;
      final bitmap = Uint8List(len);
      for (var i = 0; i < values.length; i++) {
        if (values[i] == null) bitmap[i >> 3] |= 1 << (i & 7);
      }
      data.opaque(bitmap);
    }
    for (var i = 0; i < params.length; i++) {
      final v = values[i];
      if (v == null) {
        blr.add([blr_text, 0, 0, blr_short, 0]);
        if (!_p13) data.int32(-1);
        continue;
      }
      _encodeValue(params[i], v, blr, data, i);
      blr.add([blr_short, 0]);
      if (!_p13) data.int32(0);
    }
    blr.add([blr_end, blr_eoc]);
    return (blr: blr.toBytes(), data: data.takeBytes());
  }

  void _encodeValue(
      FbColumn p, Object v, BytesBuilder blr, XdrWriter data, int index) {
    switch (v) {
      case FbBlobId():
        blr.add([blr_quad, 0]);
        data.raw(v.bytes);
      case bool():
        if (_p13) {
          blr.addByte(blr_bool);
          data.opaque([v ? 1 : 0]);
        } else {
          blr.add([blr_short, 0]);
          data.int32(v ? 1 : 0);
        }
      case int():
        _encodeInt(v, 0, blr, data);
      case BigInt():
        if (v.isValidInt) {
          _encodeInt(v.toInt(), 0, blr, data);
        } else {
          _encodeString(p, v.toString(), blr, data, index);
        }
      case double():
        blr.addByte(blr_double);
        data.float64(v);
      case FbDecimal():
        if (v.fitsInt64 && v.scale <= 18) {
          blr.add([blr_int64, (-v.scale) & 0xFF]);
          data.int64(v.unscaledInt);
        } else {
          _encodeString(p, v.toString(), blr, data, index);
        }
      case DateTime():
        switch (p.sqlType) {
          case SQL_TYPE_DATE:
            blr.addByte(blr_sql_date);
            data.int32(encodeFbDate(v.year, v.month, v.day));
          case SQL_TYPE_TIME:
            blr.addByte(blr_sql_time);
            data.int32(encodeFbTime(v.hour, v.minute, v.second,
                v.millisecond * 1000 + v.microsecond));
          default:
            blr.addByte(blr_timestamp);
            data.int32(encodeFbDate(v.year, v.month, v.day));
            data.int32(encodeFbTime(v.hour, v.minute, v.second,
                v.millisecond * 1000 + v.microsecond));
        }
      case Duration():
        final day = const Duration(days: 1).inMicroseconds;
        final us = v.inMicroseconds % day;
        blr.addByte(blr_sql_time);
        data.int32(us ~/ 100);
      case Uint8List():
        _encodeBytes(v, blr, data, index, charsetId: FbCharset.octets.id);
      case String():
        _encodeString(p, v, blr, data, index);
      default:
        throw FbUsageException('Unsupported parameter type '
            '${v.runtimeType} for parameter ${index + 1}');
    }
  }

  void _encodeInt(int v, int scale, BytesBuilder blr, XdrWriter data) {
    if (v >= -0x80000000 && v <= 0x7FFFFFFF) {
      blr.add([blr_long, scale & 0xFF]);
      data.int32(v);
    } else {
      blr.add([blr_int64, scale & 0xFF]);
      data.int64(v);
    }
  }

  void _encodeString(
      FbColumn p, String v, BytesBuilder blr, XdrWriter data, int index) {
    if (p.isText && p.charsetId == FbCharset.none.id) {
      _encodeBytes(wire.noneCodec.encode(v), blr, data, index,
          charsetId: FbCharset.none.id);
    } else {
      _encodeBytes(wire.textCodec.encode(v), blr, data, index);
    }
  }

  void _encodeBytes(
      List<int> bytes, BytesBuilder blr, XdrWriter data, int index,
      {int? charsetId}) {
    if (bytes.length > 32767) {
      throw FbUsageException('Parameter ${index + 1} is ${bytes.length} '
          'bytes long; values over 32767 bytes must go to a BLOB column');
    }
    final len = bytes.length;
    if (charsetId == null) {
      blr.add([blr_text, len & 0xFF, len >> 8]);
    } else {
      blr.add(
          [blr_text2, charsetId & 0xFF, charsetId >> 8, len & 0xFF, len >> 8]);
    }
    data.opaque(bytes);
  }
}
