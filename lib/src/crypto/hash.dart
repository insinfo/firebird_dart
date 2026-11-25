import 'dart:typed_data';

/// Minimal SHA-1 / SHA-256 implementations (FIPS 180-4), enough for SRP
/// authentication. Inputs are small, so the code favours clarity.
abstract class Digest {
  void add(List<int> data);
  Uint8List close();

  static Uint8List sha1(List<int> data) => (Sha1()..add(data)).close();
  static Uint8List sha256(List<int> data) => (Sha256()..add(data)).close();
}

int _rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF;
int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

abstract class _Md32 implements Digest {
  final BytesBuilder _data = BytesBuilder();
  bool _closed = false;

  @override
  void add(List<int> data) {
    if (_closed) throw StateError('Digest already closed');
    _data.add(data);
  }

  void _block(Uint32List block);
  Uint8List _result();

  @override
  Uint8List close() {
    _closed = true;
    final msg = _data.takeBytes();
    final bitLen = msg.length * 8;
    var padded = msg.length + 1 + 8;
    padded += (64 - padded % 64) % 64;
    final buf = Uint8List(padded)..setRange(0, msg.length, msg);
    buf[msg.length] = 0x80;
    final bd = ByteData.sublistView(buf);
    bd.setUint32(padded - 8, (bitLen ~/ 0x100000000) & 0xFFFFFFFF);
    bd.setUint32(padded - 4, bitLen & 0xFFFFFFFF);
    final w = Uint32List(16);
    for (var off = 0; off < padded; off += 64) {
      for (var i = 0; i < 16; i++) {
        w[i] = bd.getUint32(off + i * 4);
      }
      _block(w);
    }
    return _result();
  }
}

class Sha1 extends _Md32 {
  int _h0 = 0x67452301,
      _h1 = 0xEFCDAB89,
      _h2 = 0x98BADCFE,
      _h3 = 0x10325476,
      _h4 = 0xC3D2E1F0;

  @override
  void _block(Uint32List block) {
    final w = Uint32List(80)..setRange(0, 16, block);
    for (var i = 16; i < 80; i++) {
      w[i] = _rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    var a = _h0, b = _h1, c = _h2, d = _h3, e = _h4;
    for (var i = 0; i < 80; i++) {
      int f, k;
      if (i < 20) {
        f = (b & c) | ((~b & 0xFFFFFFFF) & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      final t = (_rotl(a, 5) + f + e + k + w[i]) & 0xFFFFFFFF;
      e = d;
      d = c;
      c = _rotl(b, 30);
      b = a;
      a = t;
    }
    _h0 = (_h0 + a) & 0xFFFFFFFF;
    _h1 = (_h1 + b) & 0xFFFFFFFF;
    _h2 = (_h2 + c) & 0xFFFFFFFF;
    _h3 = (_h3 + d) & 0xFFFFFFFF;
    _h4 = (_h4 + e) & 0xFFFFFFFF;
  }

  @override
  Uint8List _result() {
    final out = ByteData(20);
    final hs = [_h0, _h1, _h2, _h3, _h4];
    for (var i = 0; i < 5; i++) {
      out.setUint32(i * 4, hs[i]);
    }
    return out.buffer.asUint8List();
  }
}

const List<int> _k256 = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

class Sha256 extends _Md32 {
  final Uint32List _h = Uint32List.fromList([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);

  @override
  void _block(Uint32List block) {
    final w = Uint32List(64)..setRange(0, 16, block);
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }
    var a = _h[0], b = _h[1], c = _h[2], d = _h[3];
    var e = _h[4], f = _h[5], g = _h[6], h = _h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final t1 = (h + s1 + ch + _k256[i] + w[i]) & 0xFFFFFFFF;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xFFFFFFFF;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }
    _h[0] += a;
    _h[1] += b;
    _h[2] += c;
    _h[3] += d;
    _h[4] += e;
    _h[5] += f;
    _h[6] += g;
    _h[7] += h;
  }

  @override
  Uint8List _result() {
    final out = ByteData(32);
    for (var i = 0; i < 8; i++) {
      out.setUint32(i * 4, _h[i]);
    }
    return out.buffer.asUint8List();
  }
}

/// RC4 stream cipher used by Firebird's `Arc4` wire encryption plugin.
class Arc4 {
  final Uint8List _s = Uint8List(256);
  int _i = 0;
  int _j = 0;

  Arc4(List<int> key) {
    for (var i = 0; i < 256; i++) {
      _s[i] = i;
    }
    var j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j + _s[i] + key[i % key.length]) & 0xFF;
      final t = _s[i];
      _s[i] = _s[j];
      _s[j] = t;
    }
  }

  Uint8List process(List<int> input) {
    final out = Uint8List(input.length);
    var i = _i, j = _j;
    final s = _s;
    for (var n = 0; n < input.length; n++) {
      i = (i + 1) & 0xFF;
      j = (j + s[i]) & 0xFF;
      final t = s[i];
      s[i] = s[j];
      s[j] = t;
      out[n] = input[n] ^ s[(s[i] + s[j]) & 0xFF];
    }
    _i = i;
    _j = j;
    return out;
  }
}
