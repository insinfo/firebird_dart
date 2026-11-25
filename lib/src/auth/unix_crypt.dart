/// Traditional DES-based Unix `crypt(3)`.
///
/// Firebird's legacy authentication (Firebird 1.x/2.x and the
/// `Legacy_Auth` plugin) sends `crypt(password, "9z")` without the two salt
/// characters, so the password never crosses the network in clear text.
/// Only the first 8 characters of the password are significant.
library;

const List<int> _ip = [
  58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, //
  62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
  57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
  61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7,
];

const List<int> _fp = [
  40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31, //
  38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
  36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27,
  34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25,
];

const List<int> _pc1C = [
  57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, //
  10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36,
];

const List<int> _pc1D = [
  63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22, //
  14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4,
];

const List<int> _shifts = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];

const List<int> _pc2C = [
  14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, //
  23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2,
];

const List<int> _pc2D = [
  41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48, //
  44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32,
];

const List<int> _e = [
  32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, //
  8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17,
  16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25,
  24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1,
];

const List<List<int>> _s = [
  [
    14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, //
    0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
    4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
    15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13,
  ],
  [
    15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, //
    3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
    0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
    13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9,
  ],
  [
    10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, //
    13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
    13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
    1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12,
  ],
  [
    7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, //
    13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
    10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
    3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14,
  ],
  [
    2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, //
    14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
    4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
    11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3,
  ],
  [
    12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, //
    10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
    9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
    4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13,
  ],
  [
    4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, //
    13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
    1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
    6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12,
  ],
  [
    13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, //
    1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
    7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
    2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11,
  ],
];

const List<int> _p = [
  16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10, //
  2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25,
];

/// Computes the 13-character `crypt(3)` hash of [password] with [salt]
/// (two characters from `./0-9A-Za-z`).
String unixCrypt(String password, String salt) {
  if (salt.length < 2) {
    throw ArgumentError.value(salt, 'salt', 'must have two characters');
  }

  // Key: 7 bits of each of the first 8 characters, high bit first.
  final block = List<int>.filled(66, 0);
  final pw = password.codeUnits;
  for (var i = 0, n = 0; n < pw.length && i < 64; n++) {
    final c = pw[n];
    for (var j = 0; j < 7; j++, i++) {
      block[i] = (c >> (6 - j)) & 1;
    }
    i++;
  }

  // Key schedule.
  final c = List<int>.generate(28, (i) => block[_pc1C[i] - 1]);
  final d = List<int>.generate(28, (i) => block[_pc1D[i] - 1]);
  final ks = List<List<int>>.generate(16, (_) => List<int>.filled(48, 0));
  for (var i = 0; i < 16; i++) {
    for (var k = 0; k < _shifts[i]; k++) {
      final tc = c[0];
      final td = d[0];
      for (var j = 0; j < 27; j++) {
        c[j] = c[j + 1];
        d[j] = d[j + 1];
      }
      c[27] = tc;
      d[27] = td;
    }
    for (var j = 0; j < 24; j++) {
      ks[i][j] = c[_pc2C[j] - 1];
      ks[i][j + 24] = d[_pc2D[j] - 28 - 1];
    }
  }

  // The salt perturbs the expansion table.
  final e = List<int>.of(_e);
  final out = StringBuffer();
  for (var i = 0; i < 2; i++) {
    var ch = salt.codeUnitAt(i);
    out.writeCharCode(ch);
    if (ch > 0x5A) ch -= 6; // > 'Z'
    if (ch > 0x39) ch -= 7; // > '9'
    ch -= 0x2E; // '.'
    for (var j = 0; j < 6; j++) {
      if (((ch >> j) & 1) != 0) {
        final t = e[6 * i + j];
        e[6 * i + j] = e[6 * i + j + 24];
        e[6 * i + j + 24] = t;
      }
    }
  }

  // Encrypt a block of zeros 25 times.
  for (var i = 0; i < 66; i++) {
    block[i] = 0;
  }
  final l = List<int>.filled(32, 0);
  final r = List<int>.filled(32, 0);
  final tempL = List<int>.filled(32, 0);
  final preS = List<int>.filled(48, 0);
  final f = List<int>.filled(32, 0);
  for (var iter = 0; iter < 25; iter++) {
    for (var j = 0; j < 32; j++) {
      l[j] = block[_ip[j] - 1];
      r[j] = block[_ip[j + 32] - 1];
    }
    for (var round = 0; round < 16; round++) {
      for (var j = 0; j < 32; j++) {
        tempL[j] = r[j];
      }
      final key = ks[round];
      for (var j = 0; j < 48; j++) {
        preS[j] = r[e[j] - 1] ^ key[j];
      }
      for (var j = 0; j < 8; j++) {
        final t = 6 * j;
        final k = _s[j][(preS[t] << 5) +
            (preS[t + 1] << 3) +
            (preS[t + 2] << 2) +
            (preS[t + 3] << 1) +
            (preS[t + 4]) +
            (preS[t + 5] << 4)];
        final o = 4 * j;
        f[o] = (k >> 3) & 1;
        f[o + 1] = (k >> 2) & 1;
        f[o + 2] = (k >> 1) & 1;
        f[o + 3] = k & 1;
      }
      for (var j = 0; j < 32; j++) {
        r[j] = l[j] ^ f[_p[j] - 1];
      }
      for (var j = 0; j < 32; j++) {
        l[j] = tempL[j];
      }
    }
    // Pre-output is R16 L16.
    for (var j = 0; j < 64; j++) {
      final src = _fp[j] - 1;
      block[j] = src < 32 ? r[src] : l[src - 32];
    }
  }

  for (var i = 0; i < 11; i++) {
    var ch = 0;
    for (var j = 0; j < 6; j++) {
      ch = (ch << 1) | block[6 * i + j];
    }
    ch += 0x2E;
    if (ch > 0x39) ch += 7;
    if (ch > 0x5A) ch += 6;
    out.writeCharCode(ch);
  }
  return out.toString();
}

/// Password digest sent by Firebird legacy authentication.
String firebirdLegacyPasswordHash(String password) =>
    unixCrypt(password, '9z').substring(2);
