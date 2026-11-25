import 'dart:async';
import 'dart:collection';

import 'connection.dart';
import 'exceptions.dart';
import 'result.dart';
import 'settings.dart';

/// Pool settings.
class FbPoolSettings {
  /// Maximum open connections.
  final int maxConnections;

  /// Connections opened by [FbPool.start] and kept open.
  final int minConnections;

  /// Maximum wait for a free connection; null waits indefinitely.
  final Duration? acquireTimeout;

  /// Idle connections older than this are closed instead of reused.
  final Duration? idleTimeout;

  /// Connections are closed after this lifetime, when returned.
  final Duration? maxLifetime;

  /// A connection idle for longer than this is pinged before being handed
  /// out; a failed ping replaces it.
  final Duration? validateAfterIdle;

  /// Maximum callers waiting for a connection; further callers fail fast.
  final int maxQueueLength;

  const FbPoolSettings({
    this.maxConnections = 10,
    this.minConnections = 0,
    this.acquireTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(minutes: 10),
    this.maxLifetime = const Duration(hours: 1),
    this.validateAfterIdle = const Duration(seconds: 30),
    this.maxQueueLength = 10000,
  });
}

class _Slot {
  final FbConnection connection;
  final DateTime created = DateTime.now();
  DateTime lastUsed = DateTime.now();
  _Slot(this.connection);
}

/// Bounded pool of [FbConnection]s for concurrent servers.
///
/// Each call leases a connection, so requests from different callers run in
/// parallel on different attachments. [runInTransaction] keeps the same
/// connection for the whole transaction.
class FbPool with FbExecutor {
  final FbConnectionSettings settings;
  final FbPoolSettings poolSettings;

  final List<_Slot> _idle = [];
  final Set<_Slot> _leased = {};
  final Queue<Completer<_Slot>> _waiters = Queue();
  int _opening = 0;
  bool _closed = false;

  FbPool(this.settings, [this.poolSettings = const FbPoolSettings()]) {
    if (poolSettings.maxConnections < 1) {
      throw ArgumentError.value(poolSettings.maxConnections, 'maxConnections');
    }
  }

  /// Opens [FbPoolSettings.minConnections] connections up front.
  Future<void> start() async {
    final n = poolSettings.minConnections - _total;
    if (n <= 0) return;
    final slots = await Future.wait([for (var i = 0; i < n; i++) _open()]);
    for (final s in slots) {
      _release(s);
    }
  }

  int get _total => _idle.length + _leased.length + _opening;

  /// Open connections (idle + leased).
  int get size => _idle.length + _leased.length;
  int get idleCount => _idle.length;
  int get leasedCount => _leased.length;
  int get waitingCount => _waiters.length;
  bool get isClosed => _closed;

  Future<_Slot> _open() async {
    _opening++;
    try {
      return _Slot(await FbConnection.connect(settings));
    } finally {
      _opening--;
    }
  }

  bool _expired(_Slot s, DateTime now) {
    final idle = poolSettings.idleTimeout;
    final life = poolSettings.maxLifetime;
    return (idle != null && now.difference(s.lastUsed) > idle) ||
        (life != null && now.difference(s.created) > life);
  }

  Future<_Slot> _acquire() async {
    if (_closed) throw FbUsageException('Pool is closed');
    while (_idle.isNotEmpty) {
      final s = _idle.removeLast(); // most recently used: warm caches
      final now = DateTime.now();
      if (s.connection.isClosed || _expired(s, now)) {
        unawaited(s.connection.close());
        continue;
      }
      final validate = poolSettings.validateAfterIdle;
      if (validate != null && now.difference(s.lastUsed) > validate) {
        _leased.add(s);
        if (!await s.connection.checkHealth()) {
          _leased.remove(s);
          unawaited(s.connection.close());
          continue;
        }
        return s;
      }
      _leased.add(s);
      return s;
    }
    if (_total < poolSettings.maxConnections) {
      final s = await _open();
      if (_closed) {
        await s.connection.close();
        throw FbUsageException('Pool is closed');
      }
      _leased.add(s);
      return s;
    }
    if (_waiters.length >= poolSettings.maxQueueLength) {
      throw FbUsageException('Connection pool queue is full');
    }
    final c = Completer<_Slot>();
    _waiters.add(c);
    final timeout = poolSettings.acquireTimeout;
    if (timeout == null) return c.future;
    return c.future.timeout(timeout, onTimeout: () {
      _waiters.remove(c);
      throw TimeoutException(
          'No Firebird connection available within $timeout', timeout);
    });
  }

  void _release(_Slot s) {
    _leased.remove(s);
    final conn = s.connection;
    final discard = _closed ||
        conn.isClosed ||
        conn.inTransaction ||
        (poolSettings.maxLifetime != null &&
            DateTime.now().difference(s.created) > poolSettings.maxLifetime!);
    if (discard) {
      unawaited(conn.close());
      _replaceForWaiter();
      return;
    }
    s.lastUsed = DateTime.now();
    if (_waiters.isNotEmpty) {
      _leased.add(s);
      _waiters.removeFirst().complete(s);
      return;
    }
    _idle.add(s);
  }

  /// A connection was discarded: open a new one for the oldest waiter.
  void _replaceForWaiter() {
    if (_waiters.isEmpty || _closed) return;
    if (_total >= poolSettings.maxConnections) return;
    final waiter = _waiters.removeFirst();
    _open().then((s) {
      _leased.add(s);
      if (waiter.isCompleted) {
        _release(s);
      } else {
        waiter.complete(s);
      }
    }, onError: (Object e, StackTrace st) {
      if (!waiter.isCompleted) waiter.completeError(e, st);
    });
  }

  /// Leases a connection for [action].
  Future<T> withConnection<T>(
      Future<T> Function(FbConnection conn) action) async {
    final s = await _acquire();
    try {
      return await action(s.connection);
    } finally {
      _release(s);
    }
  }

  /// Runs [action] in a transaction on one leased connection.
  Future<T> runInTransaction<T>(Future<T> Function(FbTransaction tx) action,
          [FbTransactionOptions options = const FbTransactionOptions()]) =>
      withConnection((c) => c.runInTransaction(action, options));

  /// Same as [runInTransaction] (postgres_fork naming).
  Future<T> runTx<T>(Future<T> Function(FbTransaction tx) action,
          [FbTransactionOptions options = const FbTransactionOptions()]) =>
      runInTransaction(action, options);

  @override
  Future<FbResult> query(String sql, [Object? params, Duration? timeout]) =>
      withConnection((c) => c.query(sql, params, timeout));

  @override
  Future<List<Map<String, Object?>>> queryMaps(String sql,
          [Object? params, Duration? timeout]) =>
      withConnection((c) => c.queryMaps(sql, params, timeout));

  @override
  Future<void> queryEach(
          String sql, Object? params, void Function(FbRow row) onRow,
          [Duration? timeout]) =>
      withConnection((c) => c.queryEach(sql, params, onRow, timeout));

  @override
  Future<int> execute(String sql, [Object? params, Duration? timeout]) =>
      withConnection((c) => c.execute(sql, params, timeout));

  /// Streams rows; the connection stays leased until the stream ends or the
  /// subscription is cancelled.
  @override
  Stream<FbRow> stream(String sql, [Object? params, int? fetchSize]) async* {
    final s = await _acquire();
    try {
      yield* s.connection.stream(sql, params, fetchSize);
    } finally {
      _release(s);
    }
  }

  /// Closes idle connections now and leased ones when they are returned.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().completeError(FbUsageException('Pool is closed'));
    }
    final idle = List.of(_idle);
    _idle.clear();
    await Future.wait([for (final s in idle) s.connection.close()]);
  }
}
