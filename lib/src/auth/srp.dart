import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../crypto/hash.dart';

/// Client side of Firebird's SRP-6a authentication (plugins `Srp` and
/// `Srp256`, Firebird 3+).
///
/// The group parameters are the ones built into Firebird (1024-bit prime,
/// generator 2). The session key is always SHA-1 based; the plugin only
/// changes the hash used for the final proof.
class SrpClient {
  static final BigInt prime = BigInt.parse(
      'E67D2E994B2F900C3F41F08F5BB2627ED0D49EE1FE767A52EFCD565CD6E76881'
      '2C3E1E9CE8F0A8BEA6CB13CD29DDEBF7A96D4A93B55D488DF099A15C89DCB064'
      '0738EB2CBDD9A8F7BAB561AB1B0DC1C6CDABF303264A08D1BCA932D1F1EE428B'
      '619D970F342ABA9A65793B8B2F041AE5364350C16F735F56ECBCA87BD57B29E7',
      radix: 16);
  static final BigInt generator = BigInt.two;

  /// k = H(N, g), with g padded to the length of N.
  static final BigInt multiplier = bytesToBigInt(Digest.sha1([
    ...bigIntToBytes(prime),
    ...Uint8List(bigIntToBytes(prime).length - 1),
    ...bigIntToBytes(generator),
  ]));

  final BigInt privateKey;
  late final BigInt publicKey = generator.modPow(privateKey, prime);

  SrpClient([BigInt? privateKey])
      : privateKey = privateKey ?? _randomBigInt(128);

  static BigInt _randomBigInt(int bytes) {
    final r = Random.secure();
    final b = Uint8List(bytes);
    for (var i = 0; i < bytes; i++) {
      b[i] = r.nextInt(256);
    }
    return bytesToBigInt(b);
  }

  /// Public key as uppercase-free hex, as sent in the connect packet.
  String get publicKeyHex => publicKey.toRadixString(16);

  /// Computes the client proof (M) and the session key (K) from the
  /// server salt and public key.
  ({Uint8List proof, Uint8List sessionKey}) clientProof({
    required String user,
    required String password,
    required List<int> salt,
    required BigInt serverPublicKey,
    required bool sha256Proof,
  }) {
    final n = prime;
    final userBytes = utf8.encode(user);
    final u = bytesToBigInt(Digest.sha1([
      ..._pad(publicKey),
      ..._pad(serverPublicKey),
    ]));
    final inner = Digest.sha1([...userBytes, 0x3A, ...utf8.encode(password)]);
    final x = bytesToBigInt(Digest.sha1([...salt, ...inner]));
    final gx = generator.modPow(x, n);
    final kgx = (multiplier * gx) % n;
    final diff = (serverPublicKey - kgx) % n;
    // S = (B - k·g^x)^(a + u·x) mod N. The exponent must not be reduced
    // modulo N: that is only correct while a + u·x < N, and a 1024-bit
    // private key exceeds N about 10% of the time.
    final aux = privateKey + u * x;
    final secret = diff.modPow(aux, n);
    final k = Digest.sha1(bigIntToBytes(secret));

    var n1 = bytesToBigInt(Digest.sha1(bigIntToBytes(n)));
    final n2 = bytesToBigInt(Digest.sha1(bigIntToBytes(generator)));
    n1 = n1.modPow(n2, n);
    final hu = bytesToBigInt(Digest.sha1(userBytes));
    final data = <int>[
      ...bigIntToBytes(n1),
      ...bigIntToBytes(hu),
      ...salt,
      ...bigIntToBytes(publicKey),
      ...bigIntToBytes(serverPublicKey),
      ...k,
    ];
    final m = sha256Proof ? Digest.sha256(data) : Digest.sha1(data);
    return (proof: m, sessionKey: k);
  }

  static List<int> _pad(BigInt v) {
    final b = bigIntToBytes(v);
    return b.length > 128 ? b.sublist(b.length - 128) : b;
  }
}

BigInt bytesToBigInt(List<int> bytes) {
  var r = BigInt.zero;
  for (final b in bytes) {
    r = (r << 8) | BigInt.from(b & 0xFF);
  }
  return r;
}

/// Minimal big-endian representation (at least one byte).
Uint8List bigIntToBytes(BigInt v) {
  if (v == BigInt.zero) return Uint8List(1);
  var hex = v.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Uint8List hexToBytes(String hex) {
  var h = hex.trim();
  if (h.length.isOdd) h = '0$h';
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String bytesToHex(List<int> bytes) =>
    bytes.map((b) => (b & 0xFF).toRadixString(16).padLeft(2, '0')).join();
