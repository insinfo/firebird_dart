import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'engine.dart';
import 'exceptions.dart';
import 'wire/constants.dart';
import 'wire/xdr.dart';

/// A database event (`POST_EVENT 'name'`) delivered after the posting
/// transaction committed. [count] is how many times it was posted since the
/// previous notification.
class FbEvent {
  final String name;
  final int count;
  const FbEvent(this.name, this.count);

  @override
  String toString() => 'FbEvent($name x$count)';
}

/// Registration for a set of event names on one connection.
class FbEventSubscription {
  final List<String> names;
  final EventManager _manager;
  final int _id;
  final StreamController<FbEvent> _controller =
      StreamController<FbEvent>.broadcast();
  final Map<String, int> _counts;
  final Completer<void> _ready = Completer<void>();
  bool _cancelled = false;

  FbEventSubscription._(this._manager, this._id, this.names)
      : _counts = {for (final n in names) n: 0};

  /// Events as they arrive.
  Stream<FbEvent> get events => _controller.stream;

  /// Completes when the server has registered the interest; events posted
  /// before that are not reported.
  Future<void> get ready => _ready.future;

  bool get isCancelled => _cancelled;

  /// Stops listening.
  Future<void> cancel() => _manager._cancel(this);
}

/// Event channel of one attachment: the auxiliary socket the server opens
/// for asynchronous notifications plus the registrations queued on it.
class EventManager {
  final Engine engine;
  Socket? _socket;
  final InputBuffer _input = InputBuffer();
  final Map<int, FbEventSubscription> _subs = {};
  int _nextId = 0;
  bool _closed = false;

  EventManager(this.engine);

  /// Registers interest in [names]. Must be called with the engine lock
  /// held.
  Future<FbEventSubscription> subscribe(List<String> names) async {
    if (names.isEmpty) throw FbUsageException('No event names given');
    if (_closed) throw FbUsageException('Event channel is closed');
    for (final n in names) {
      if (engine.wire.textCodec.encode(n).length > 255) {
        throw FbUsageException('Event name too long: $n');
      }
    }
    await _ensureSocket();
    final sub =
        FbEventSubscription._(this, ++_nextId, List.unmodifiable(names));
    _subs[sub._id] = sub;
    await _queue(sub);
    return sub;
  }

  Future<void> _ensureSocket() async {
    if (_socket != null) return;
    final wire = engine.wire;
    wire.send((XdrWriter(16)
          ..int32(op_connect_request)
          ..int32(1) // P_REQ_async
          ..int32(wire.dbHandle)
          ..int32(0))
        .takeBytes());
    final r = await wire.readResponse();
    final d = r.data;
    if (d.length < 8) {
      throw FbConnectionException('Invalid auxiliary connection address');
    }
    final port = (d[2] << 8) | d[3];
    // The address the server reports is often 0.0.0.0 or an internal one;
    // the host used for the main connection reaches the same server.
    try {
      _socket = await Socket.connect(engine.settings.host, port,
          timeout: engine.settings.connectTimeout);
    } on SocketException catch (e) {
      throw FbConnectionException(
          'Unable to open the event channel on port $port (check '
          'RemoteAuxPort and firewalls)',
          cause: e);
    }
    _socket!.setOption(SocketOption.tcpNoDelay, true);
    _socket!.listen(
      _input.add,
      onError: (Object e, StackTrace st) => _input.close(
          FbConnectionException('Event channel failed', cause: e), st),
      onDone: () => _input.close(FbConnectionException('Event channel closed')),
      cancelOnError: true,
    );
    unawaited(_readLoop());
  }

  Uint8List _epb(FbEventSubscription sub) {
    final b = BytesBuilder()..addByte(1); // EPB_version1
    for (final name in sub.names) {
      final bytes = engine.wire.textCodec.encode(name);
      b
        ..addByte(bytes.length)
        ..add(bytes)
        ..add((ByteData(4)..setUint32(0, sub._counts[name]!, Endian.little))
            .buffer
            .asUint8List());
    }
    return b.toBytes();
  }

  /// Sends op_que_events with the last known counts (engine lock held).
  Future<void> _queue(FbEventSubscription sub) async {
    final wire = engine.wire;
    wire.send((XdrWriter(64)
          ..int32(op_que_events)
          ..int32(wire.dbHandle)
          ..buffer(_epb(sub))
          ..int32(0) // AST
          ..int32(0) // AST argument
          ..int32(sub._id))
        .takeBytes());
    await wire.readResponse();
  }

  Future<void> _readLoop() async {
    try {
      while (true) {
        final op = await _input.int32();
        if (op == op_dummy) continue;
        if (op == op_exit || op == op_disconnect) break;
        if (op != op_event) {
          throw FbConnectionException('Unexpected op $op on event channel');
        }
        await _input.int32(); // database handle
        final epb = await _input.xdrBuffer();
        await _input.bytes(8); // AST address and argument
        final id = await _input.int32();
        _deliver(id, epb);
      }
      _closeAll(null);
    } catch (e) {
      _closeAll(_closed ? null : e);
    }
  }

  void _deliver(int id, Uint8List epb) {
    final sub = _subs[id];
    if (sub == null || sub._cancelled) return;
    final codec = engine.wire.textCodec;
    final firstNotification = !sub._ready.isCompleted;
    var i = 1; // skip EPB version
    while (i < epb.length) {
      final len = epb[i];
      final name = codec.decode(epb.sublist(i + 1, i + 1 + len));
      final count = ByteData.sublistView(epb, i + 1 + len, i + 5 + len)
          .getUint32(0, Endian.little);
      i += 5 + len;
      final previous = sub._counts[name];
      if (previous == null) continue;
      sub._counts[name] = count;
      // The first notification only reports the current counters.
      if (!firstNotification && count > previous) {
        sub._controller.add(FbEvent(name, count - previous));
      }
    }
    if (firstNotification) sub._ready.complete();
    // Notifications are one-shot: queue again with the new counters.
    unawaited(engine.guarded(() async {
      if (!sub._cancelled && !_closed) await _queue(sub);
    }).then((_) {}, onError: (Object e) => _fail(sub, e)));
  }

  void _fail(FbEventSubscription sub, Object error) {
    if (sub._cancelled) return;
    sub._cancelled = true;
    _subs.remove(sub._id);
    if (!sub._ready.isCompleted) sub._ready.completeError(error);
    sub._controller.addError(error);
    sub._controller.close();
  }

  Future<void> _cancel(FbEventSubscription sub) async {
    if (sub._cancelled) return;
    sub._cancelled = true;
    _subs.remove(sub._id);
    if (!sub._ready.isCompleted) sub._ready.complete();
    await sub._controller.close();
    if (engine.isClosed) return;
    await engine.guarded(() async {
      final wire = engine.wire;
      wire.send((XdrWriter(16)
            ..int32(op_cancel_events)
            ..int32(wire.dbHandle)
            ..int32(sub._id))
          .takeBytes());
      await wire.readResponse();
    });
  }

  void _closeAll(Object? error) {
    for (final sub in _subs.values.toList()) {
      if (error != null) {
        _fail(sub, error);
      } else {
        sub._cancelled = true;
        if (!sub._ready.isCompleted) sub._ready.complete();
        sub._controller.close();
      }
    }
    _subs.clear();
  }

  /// Closes the channel (connection shutdown).
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _closeAll(null);
    _socket?.destroy();
  }
}
