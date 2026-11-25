import 'dart:convert';
import 'dart:typed_data';

/// Windows-1252 (Western European) codec.
///
/// Bytes 0x00-0x7F and 0xA0-0xFF match Latin-1; 0x80-0x9F carry the
/// Windows punctuation and symbols. The five undefined bytes (0x81, 0x8D,
/// 0x8F, 0x90, 0x9D) decode to the same C1 code point, as Windows does, so
/// every byte round-trips.
class Windows1252Codec extends Encoding {
  const Windows1252Codec();

  @override
  String get name => 'windows-1252';

  @override
  Converter<List<int>, String> get decoder => const _Win1252Decoder();

  @override
  Converter<String, List<int>> get encoder => const _Win1252Encoder();
}

const Windows1252Codec windows1252 = Windows1252Codec();

const List<int> _win1252High = [
  0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
  0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
];

final Map<int, int> _win1252Reverse = {
  for (var i = 0; i < 32; i++) _win1252High[i]: 0x80 + i,
};

class _Win1252Decoder extends Converter<List<int>, String> {
  const _Win1252Decoder();

  @override
  String convert(List<int> input) {
    // Fast path: pure ASCII/Latin-1 range without 0x80-0x9F.
    var plain = true;
    for (final b in input) {
      if (b >= 0x80 && b < 0xA0) {
        plain = false;
        break;
      }
    }
    if (plain) return String.fromCharCodes(input);
    final codes = Uint16List(input.length);
    for (var i = 0; i < input.length; i++) {
      final b = input[i] & 0xFF;
      codes[i] = (b >= 0x80 && b < 0xA0) ? _win1252High[b - 0x80] : b;
    }
    return String.fromCharCodes(codes);
  }
}

class _Win1252Encoder extends Converter<String, List<int>> {
  const _Win1252Encoder();

  @override
  List<int> convert(String input) {
    final out = Uint8List(input.length);
    for (var i = 0; i < input.length; i++) {
      final c = input.codeUnitAt(i);
      if (c < 0x80 || (c >= 0xA0 && c <= 0xFF)) {
        out[i] = c;
      } else {
        out[i] = _win1252Reverse[c] ?? 0x3F; // '?'
      }
    }
    return out;
  }
}

/// A Firebird character set and the Dart codec used for it.
class FbCharset {
  final int id;
  final String name;

  /// Maximum bytes per character.
  final int bytesPerChar;

  /// Null for OCTETS (binary) and for character sets without a codec.
  final Encoding? encoding;

  const FbCharset(this.id, this.name, this.bytesPerChar, this.encoding);

  static const none = FbCharset(0, 'NONE', 1, null);
  static const octets = FbCharset(1, 'OCTETS', 1, null);
  static const ascii = FbCharset(2, 'ASCII', 1, AsciiCodec(allowInvalid: true));
  static const unicodeFss =
      FbCharset(3, 'UNICODE_FSS', 3, Utf8Codec(allowMalformed: true));
  static const utf8 = FbCharset(4, 'UTF8', 4, Utf8Codec(allowMalformed: true));
  static const iso8859_1 =
      FbCharset(21, 'ISO8859_1', 1, Latin1Codec(allowInvalid: true));
  static const win1252 = FbCharset(53, 'WIN1252', 1, windows1252);

  static const List<FbCharset> supported = [
    none,
    octets,
    ascii,
    unicodeFss,
    utf8,
    iso8859_1,
    win1252,
  ];

  /// Character sets known to Firebird (id → name). Those without a Dart
  /// codec can still be read as raw bytes through `OCTETS`-style handling.
  static const Map<int, String> names = {
    0: 'NONE', 1: 'OCTETS', 2: 'ASCII', 3: 'UNICODE_FSS', 4: 'UTF8', //
    5: 'SJIS_0208', 6: 'EUCJ_0208', 9: 'DOS737', 10: 'DOS437',
    11: 'DOS850', 12: 'DOS865', 13: 'DOS860', 14: 'DOS863', 15: 'DOS775',
    16: 'DOS858', 17: 'DOS862', 18: 'DOS864', 19: 'NEXT', 21: 'ISO8859_1',
    22: 'ISO8859_2', 23: 'ISO8859_3', 34: 'ISO8859_4', 35: 'ISO8859_5',
    36: 'ISO8859_6', 37: 'ISO8859_7', 38: 'ISO8859_8', 39: 'ISO8859_9',
    40: 'ISO8859_13', 44: 'KSC_5601', 45: 'DOS852', 46: 'DOS857',
    47: 'DOS861', 48: 'DOS866', 49: 'DOS869', 50: 'CYRL', 51: 'WIN1250',
    52: 'WIN1251', 53: 'WIN1252', 54: 'WIN1253', 55: 'WIN1254',
    56: 'BIG_5', 57: 'GB_2312', 58: 'WIN1255', 59: 'WIN1256',
    60: 'WIN1257', 63: 'KOI8R', 64: 'KOI8U', 65: 'WIN1258', 66: 'TIS620',
    67: 'GBK', 68: 'CP943C', 69: 'GB18030',
  };

  static FbCharset? byId(int id) {
    for (final c in supported) {
      if (c.id == id) return c;
    }
    return null;
  }

  static FbCharset byName(String name) {
    final upper = name.toUpperCase().replaceAll('-', '');
    final alias = switch (upper) {
      'UTF8' || 'UTF_8' => 'UTF8',
      'LATIN1' || 'ISO88591' => 'ISO8859_1',
      'WINDOWS1252' || 'CP1252' => 'WIN1252',
      _ => upper,
    };
    for (final c in supported) {
      if (c.name == alias) return c;
    }
    throw ArgumentError.value(
        name,
        'charset',
        'unsupported connection character set; use one of '
            '${supported.map((c) => c.name).join(', ')}');
  }

  @override
  String toString() => name;
}
