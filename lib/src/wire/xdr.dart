import 'dart:async';
import 'dart:typed_data';

/// Number of padding bytes needed to align [length] to 4 bytes (XDR).
int xdrPad(int length) => (4 - (length & 3)) & 3;

/// Builds outgoing XDR data: big-endian 32/64-bit words, opaque data padded
/// to a 4-byte boundary.
class XdrWriter {
  Uint8List _buf;
  late ByteData _view;
  int _len = 0;

  XdrWriter([int initialCapacity = 256])
      : _buf = Uint8List(initialCapacity < 16 ? 16 : initialCapacity) {
    _view = ByteData.sublistView(_buf);
  }

  int get length => _len;

  void _ensure(int extra) {
    final needed = _len + extra;
    if (needed <= _buf.length) return;
    var cap = _buf.length * 2;
    while (cap < needed) {
      cap *= 2;
    }
    final next = Uint8List(cap)..setRange(0, _len, _buf);
    _buf = next;
    _view = ByteData.sublistView(_buf);
  }

  void int32(int value) {
    _ensure(4);
    _view.setInt32(_len, value.toSigned(32));
    _len += 4;
  }

  void int64(int value) {
    _ensure(8);
    _view.setInt64(_len, value);
    _len += 8;
  }

  void float64(double value) {
    _ensure(8);
    _view.setFloat64(_len, value);
    _len += 8;
  }

  void float32(double value) {
    _ensure(4);
    _view.setFloat32(_len, value);
    _len += 4;
  }

  /// Raw bytes followed by XDR padding (no length prefix).
  void opaque(List<int> bytes) {
    final pad = xdrPad(bytes.length);
    _ensure(bytes.length + pad);
    _buf.setRange(_len, _len + bytes.length, bytes);
    _len += bytes.length;
    for (var i = 0; i < pad; i++) {
      _buf[_len++] = 0;
    }
  }

  /// Raw bytes without padding.
  void raw(List<int> bytes) {
    _ensure(bytes.length);
    _buf.setRange(_len, _len + bytes.length, bytes);
    _len += bytes.length;
  }

  /// Length-prefixed opaque data (XDR `string`/`buffer`).
  void buffer(List<int> bytes) {
    int32(bytes.length);
    opaque(bytes);
  }

  /// Pads the current content to a 4-byte boundary.
  void align() {
    final pad = xdrPad(_len);
    _ensure(pad);
    for (var i = 0; i < pad; i++) {
      _buf[_len++] = 0;
    }
  }

  Uint8List takeBytes() {
    final out = Uint8List.sublistView(_buf, 0, _len);
    _buf = Uint8List(64);
    _view = ByteData.sublistView(_buf);
    _len = 0;
    return out;
  }

  Uint8List toBytes() =>
      Uint8List.fromList(Uint8List.sublistView(_buf, 0, _len));
}

/// Little-endian blocks (DPB/TPB/BPB, info requests).
class ParamBlockBuilder {
  final BytesBuilder _b = BytesBuilder(copy: false);

  ParamBlockBuilder([int? version]) {
    if (version != null) _b.addByte(version);
  }

  void byte(int value) => _b.addByte(value & 0xFF);

  void tag(int tag) => _b.addByte(tag);

  /// tag, 1-byte length, data.
  void bytes(int tag, List<int> value) {
    if (value.length > 255) {
      throw ArgumentError('Parameter block value for tag $tag is longer '
          'than 255 bytes');
    }
    _b.addByte(tag);
    _b.addByte(value.length);
    _b.add(value);
  }

  /// tag, length 4, little-endian 32-bit integer.
  void int32(int tag, int value) {
    _b.addByte(tag);
    _b.addByte(4);
    final d = ByteData(4)..setInt32(0, value, Endian.little);
    _b.add(d.buffer.asUint8List());
  }

  Uint8List build() => _b.toBytes();
}

/// Reads a little-endian unsigned/signed integer of [len] bytes as used by
/// info buffers.
int leInt(Uint8List b, int offset, int len) {
  var v = 0;
  for (var i = len - 1; i >= 0; i--) {
    v = (v << 8) | b[offset + i];
  }
  if (len == 4) return v.toSigned(32);
  if (len == 2) return v.toSigned(16);
  if (len == 1) return v.toSigned(8);
  return v;
}

/// Incoming byte buffer filled by the socket listener.
///
/// Reading methods are synchronous and assume that [need] has completed;
/// this lets row decoding avoid an `await` per value when the data is
/// already buffered.
class InputBuffer {
  Uint8List _buf = Uint8List(64 * 1024);
  late ByteData _view = ByteData.sublistView(_buf);
  int _r = 0;
  int _w = 0;

  Completer<void>? _waiter;
  int _need = 0;
  Object? _error;
  StackTrace? _errorStack;
  bool _closed = false;

  int get available => _w - _r;
  bool get isClosed => _closed;

  void add(List<int> data) {
    final n = data.length;
    if (_w + n > _buf.length) {
      final live = _w - _r;
      if (live + n <= _buf.length && _r > 0) {
        _buf.setRange(0, live, _buf, _r);
      } else {
        var cap = _buf.length;
        while (cap < live + n) {
          cap *= 2;
        }
        final next = Uint8List(cap)..setRange(0, live, _buf, _r);
        _buf = next;
        _view = ByteData.sublistView(_buf);
      }
      _r = 0;
      _w = live;
    }
    _buf.setRange(_w, _w + n, data);
    _w += n;
    final waiter = _waiter;
    if (waiter != null && available >= _need) {
      _waiter = null;
      waiter.complete();
    }
  }

  /// Marks the stream as finished; pending and future waits fail.
  void close(Object error, [StackTrace? stack]) {
    if (_closed) return;
    _closed = true;
    _error = error;
    _errorStack = stack;
    final waiter = _waiter;
    _waiter = null;
    waiter?.completeError(error, stack);
  }

  /// Returns null when [n] bytes are already available, otherwise a future
  /// that completes when they arrive.
  Future<void>? need(int n) {
    if (available >= n) return null;
    if (_closed) return Future.error(_error!, _errorStack);
    if (_waiter != null) {
      throw StateError('Concurrent read on the Firebird connection');
    }
    _need = n;
    final c = Completer<void>();
    _waiter = c;
    return c.future;
  }

  int readInt32() {
    final v = _view.getInt32(_r);
    _r += 4;
    return v;
  }

  int readUint32() {
    final v = _view.getUint32(_r);
    _r += 4;
    return v;
  }

  int readInt64() {
    final v = _view.getInt64(_r);
    _r += 8;
    return v;
  }

  double readFloat64() {
    final v = _view.getFloat64(_r);
    _r += 8;
    return v;
  }

  double readFloat32() {
    final v = _view.getFloat32(_r);
    _r += 4;
    return v;
  }

  int readByte() => _buf[_r++];

  /// Big-endian int32 at [offset] bytes ahead of the read position.
  int peekInt32(int offset) => _view.getInt32(_r + offset);

  /// Copies [n] bytes out of the buffer.
  Uint8List readBytes(int n) {
    final out = Uint8List(n)..setRange(0, n, _buf, _r);
    _r += n;
    return out;
  }

  /// A view of the next [n] bytes. Valid only until the next [add]; callers
  /// must consume it before awaiting.
  Uint8List peekView(int n) => Uint8List.sublistView(_buf, _r, _r + n);

  void skip(int n) {
    _r += n;
  }

  // Async helpers ----------------------------------------------------------

  Future<int> int32() async {
    final f = need(4);
    if (f != null) await f;
    return readInt32();
  }

  Future<Uint8List> bytes(int n) async {
    final f = need(n);
    if (f != null) await f;
    return readBytes(n);
  }

  /// Length-prefixed, padded opaque data.
  Future<Uint8List> xdrBuffer() async {
    final len = await int32();
    final padded = len + xdrPad(len);
    final f = need(padded);
    if (f != null) await f;
    final out = readBytes(len);
    skip(padded - len);
    return out;
  }
}
