import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'engine.dart';
import 'exceptions.dart';
import 'result.dart';
import 'settings.dart';
import 'sql_params.dart';
import 'types.dart';
import 'wire/constants.dart';

/// Operations shared by connections, transactions and pools.
///
/// `params` is a `List` for `?` placeholders or a `Map<String, Object?>`
/// for `@name` placeholders. `timeout` overrides the connection's
/// `commandTimeout`; an overdue request is cancelled on the server and a
/// [TimeoutException] is thrown.
abstract mixin class FbExecutor {
  /// Runs [sql] and returns every row.
  Future<FbResult> query(String sql, [Object? params, Duration? timeout]);

  /// Runs [sql] and returns one map per row, keyed by column alias.
  Future<List<Map<String, Object?>>> queryMaps(String sql,
      [Object? params, Duration? timeout]);

  /// Calls [onRow] for each row without keeping the rows in memory. The
  /// row object must not be retained after the call.
  Future<void> queryEach(
      String sql, Object? params, void Function(FbRow row) onRow,
      [Duration? timeout]);

  /// Streams rows, fetching [fetchSize] rows per round trip as the
  /// listener consumes them (memory stays bounded).
  Stream<FbRow> stream(String sql, [Object? params, int? fetchSize]);

  /// Runs a statement and returns the number of affected rows.
  Future<int> execute(String sql, [Object? params, Duration? timeout]);

  /// First row as a map, or null.
  Future<Map<String, Object?>?> queryFirstMap(String sql,
      [Object? params, Duration? timeout]) async {
    final rows = await queryMaps(sql, params, timeout);
    return rows.isEmpty ? null : rows.first;
  }

  /// First column of the first row, or null.
  Future<T?> queryScalar<T>(String sql,
      [Object? params, Duration? timeout]) async {
    final r = await query(sql, params, timeout);
    return r.isEmpty ? null : r.first.values.first as T?;
  }

  /// Rows as `{table: {column: value}}`; expressions go under the key `''`.
  Future<List<Map<String, Map<String, Object?>>>> mappedResultsQuery(String sql,
      [Object? params, Duration? timeout]) async {
    final r = await query(sql, params, timeout);
    return r.toTableMaps();
  }
}

/// Server and database details.
class FbServerInfo {
  final String serverVersion;
  final int odsMajor;
  final int odsMinor;
  final int pageSize;
  final int sqlDialect;
  final int protocolVersion;
  final String authPlugin;
  final bool wireEncrypted;

  FbServerInfo({
    required this.serverVersion,
    required this.odsMajor,
    required this.odsMinor,
    required this.pageSize,
    required this.sqlDialect,
    required this.protocolVersion,
    required this.authPlugin,
    required this.wireEncrypted,
  });

  @override
  String toString() => 'Firebird $serverVersion (ODS $odsMajor.$odsMinor, '
      'page $pageSize, dialect $sqlDialect, protocol $protocolVersion, '
      'auth $authPlugin${wireEncrypted ? ', encrypted' : ''})';
}

/// A single attachment to a Firebird database.
///
/// Requests are serialised on the socket and queued in FIFO order. Use
/// `FbPool` to run requests in parallel.
class FbConnection with FbExecutor {
  final FbConnectionSettings settings;
  final Engine _engine;
  final Set<FbTransaction> _transactions = {};
  bool _closing = false;

  FbConnection._(this.settings, this._engine);

  /// Opens a connection.
  static Future<FbConnection> connect(FbConnectionSettings settings) async =>
      FbConnection._(settings, await Engine.open(settings));

  /// Creates a new database file and returns a connection to it.
  /// [FbConnectionSettings.charset] becomes the default character set.
  static Future<FbConnection> createDatabase(FbConnectionSettings settings,
          {int pageSize = 8192}) async =>
      FbConnection._(settings,
          await Engine.open(settings, create: true, pageSize: pageSize));

  bool get isClosed => _closing || _engine.isClosed;

  /// Whether an explicit transaction is open on this connection.
  bool get inTransaction => _transactions.isNotEmpty;

  /// Negotiated wire protocol version (10..13).
  int get protocolVersion => _engine.wire.protocolVersion;

  /// Requests cancellation of the request running on this connection
  /// (Firebird 2.5+). It fails with `isc_cancelled` (335544794).
  void cancel() {
    if (_engine.isClosed) return;
    _engine.wire.cancelOperation(fb_cancel_raise);
  }

  /// Round trip to check the connection.
  Future<void> ping([Duration? timeout]) => _engine.guarded(
      () => _engine.databaseInfo([isc_info_ods_version]), timeout);

  /// Whether the connection answers a round trip.
  Future<bool> checkHealth([Duration? timeout]) async {
    if (isClosed) return false;
    try {
      await ping(timeout ?? const Duration(seconds: 5));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<FbServerInfo> serverInfo() => _engine.guarded(() async {
        final info = await _engine.databaseInfo([
          isc_info_firebird_version,
          isc_info_ods_version,
          isc_info_ods_minor_version,
          isc_info_page_size,
          isc_info_db_sql_dialect,
        ]);
        int intOf(int item) {
          final b = info[item];
          if (b == null || b.isEmpty) return 0;
          var v = 0;
          for (var i = b.length - 1; i >= 0; i--) {
            v = (v << 8) | b[i];
          }
          return v;
        }

        var version = '';
        final v = info[isc_info_firebird_version];
        if (v != null && v.length > 2) {
          version = latin1.decode(v.sublist(2, 2 + v[1]));
        }
        return FbServerInfo(
          serverVersion: version,
          odsMajor: intOf(isc_info_ods_version),
          odsMinor: intOf(isc_info_ods_minor_version),
          pageSize: intOf(isc_info_page_size),
          sqlDialect: intOf(isc_info_db_sql_dialect),
          protocolVersion: _engine.wire.protocolVersion,
          authPlugin: _engine.wire.authPlugin ?? '',
          wireEncrypted: _engine.wire.wireEncrypted,
        );
      });

  // -------------------------------------------------------------------------
  // Transactions.
  // -------------------------------------------------------------------------

  /// Starts an explicit transaction, ended by [FbTransaction.commit] or
  /// [FbTransaction.rollback].
  Future<FbTransaction> beginTransaction(
          [FbTransactionOptions options = const FbTransactionOptions()]) =>
      _engine.guarded(() async {
        final handle = await _engine.startTransaction(options);
        final tx = FbTransaction._(this, handle);
        _transactions.add(tx);
        return tx;
      });

  /// Runs [action] in a transaction committed when it completes and rolled
  /// back when it throws.
  Future<T> runInTransaction<T>(Future<T> Function(FbTransaction tx) action,
      [FbTransactionOptions options = const FbTransactionOptions()]) async {
    final tx = await beginTransaction(options);
    try {
      final result = await action(tx);
      if (tx.isActive) await tx.commit();
      return result;
    } catch (_) {
      if (tx.isActive && !isClosed) {
        try {
          await tx.rollback();
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// Same as [runInTransaction] (postgres_fork naming).
  Future<T> transaction<T>(Future<T> Function(FbTransaction tx) action,
          [FbTransactionOptions options = const FbTransactionOptions()]) =>
      runInTransaction(action, options);

  // -------------------------------------------------------------------------
  // Auto-commit execution.
  // -------------------------------------------------------------------------

  /// Runs [body] in an implicit transaction. Cursor statements are
  /// committed here; for the others [body] receives `commit = true` and
  /// pipelines the commit after the execute.
  Future<T> _auto<T>(String sql, StatementHandle? fixed, Duration? timeout,
      Future<T> Function(int tr, StatementHandle st, bool commit) body) {
    return _engine.guarded(() async {
      final known = fixed?.type ?? _engine.cachedType(sql);
      var readOnly = settings.readOnlyAutoCommitSelects &&
          (known == null || known.returnsCursor);
      var tr = await _engine.startTransaction(readOnly
          ? FbTransactionOptions.readOnlyCommitted
          : settings.autoCommitOptions);
      StatementHandle? st;
      var finished = false;
      try {
        st = fixed ?? await _engine.acquireStatement(tr, sql);
        if (readOnly && !st.returnsCursor) {
          _engine.commitDeferred(tr);
          readOnly = false;
          tr = await _engine.startTransaction(settings.autoCommitOptions);
        }
        final result = await body(tr, st, !st.returnsCursor);
        finished = !st.returnsCursor;
        if (st.returnsCursor) {
          if (readOnly) {
            _engine.commitDeferred(tr);
          } else {
            await _engine.commit(tr);
          }
          finished = true;
        }
        return result;
      } catch (e) {
        if (!finished && e is! FbConnectionException && !_engine.isClosed) {
          try {
            await _engine.rollback(tr);
          } on FbException catch (re) {
            // Already ended by a pipelined commit.
            if (re is FbConnectionException) rethrow;
          }
        }
        rethrow;
      } finally {
        if (st != null && fixed == null && !_engine.isClosed) {
          _engine.releaseStatement(st);
        }
      }
    }, timeout);
  }

  @override
  Future<FbResult> query(String sql, [Object? params, Duration? timeout]) {
    final (s, values) = resolveParams(sql, params);
    return _auto(s, null, timeout, (tr, st, c) => _collect(tr, st, values, c));
  }

  @override
  Future<List<Map<String, Object?>>> queryMaps(String sql,
      [Object? params, Duration? timeout]) {
    final (s, values) = resolveParams(sql, params);
    return _auto(
        s, null, timeout, (tr, st, c) => _collectMaps(tr, st, values, c));
  }

  @override
  Future<void> queryEach(
      String sql, Object? params, void Function(FbRow row) onRow,
      [Duration? timeout]) {
    final (s, values) = resolveParams(sql, params);
    return _auto(
        s, null, timeout, (tr, st, c) => _each(tr, st, values, c, onRow));
  }

  @override
  Future<int> execute(String sql, [Object? params, Duration? timeout]) async {
    final (s, values) = resolveParams(sql, params);
    final r = await _auto(
        s, null, timeout, (tr, st, c) => _collect(tr, st, values, c));
    return r.affectedRows;
  }

  @override
  Stream<FbRow> stream(String sql, [Object? params, int? fetchSize]) {
    final (s, values) = resolveParams(sql, params);
    return _stream(s, values, null, null, fetchSize);
  }

  /// Prepares [sql] for repeated execution with `?` parameters. Close it
  /// with [FbPreparedStatement.close].
  Future<FbPreparedStatement> prepare(String sql) => _engine.guarded(() async {
        final tr = await _engine
            .startTransaction(FbTransactionOptions.readOnlyCommitted);
        try {
          final st = await _engine.prepare(tr, sql);
          _engine.commitDeferred(tr);
          return FbPreparedStatement._(this, st);
        } catch (e) {
          if (e is! FbConnectionException) {
            try {
              await _engine.rollback(tr);
            } on FbException catch (_) {}
          }
          rethrow;
        }
      });

  /// Reads a BLOB returned with [FbBlobMode.id] in its own read-only
  /// transaction (the row must be committed).
  Future<Uint8List> readBlob(FbBlobId id) => _engine.guarded(() async {
        final tr = await _engine
            .startTransaction(FbTransactionOptions.readOnlyCommitted);
        try {
          final data = (await _engine.readBlobs(tr, [id])).single;
          _engine.commitDeferred(tr);
          return data;
        } catch (e) {
          if (e is! FbConnectionException) {
            try {
              await _engine.rollback(tr);
            } on FbException catch (_) {}
          }
          rethrow;
        }
      });

  /// Rolls back open transactions and detaches.
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    await _engine.lock.run(() async {
      if (_engine.isClosed) return;
      for (final tx in _transactions.toList()) {
        if (!tx.isActive) continue;
        try {
          await _engine.rollback(tx._handle);
        } catch (_) {}
        tx._active = false;
      }
      _transactions.clear();
      await _engine.close();
    });
  }

  /// Drops the database this connection is attached to. The connection is
  /// closed afterwards.
  Future<void> dropDatabase() async {
    _closing = true;
    await _engine.lock.run(() async {
      for (final tx in _transactions.toList()) {
        try {
          await _engine.rollback(tx._handle);
        } catch (_) {}
        tx._active = false;
      }
      _transactions.clear();
      _engine.clearStatementCache();
      await _engine.wire.dropDatabase();
    });
  }

  // -------------------------------------------------------------------------
  // Execution helpers (lock held).
  // -------------------------------------------------------------------------

  Future<FbResult> _collect(
      int tr, StatementHandle st, List<Object?> values, bool commit) async {
    if (!st.returnsCursor) {
      final out = await _engine.execute(tr, st, values, commitAfter: commit);
      final row = out.outputRow;
      return FbResult(st.schema, row == null ? [] : [FbRow(row, st.schema)],
          affectedRows: out.affectedRows);
    }
    final rows = <FbRow>[];
    await _cursor(tr, st, values, (batch) {
      for (final r in batch) {
        rows.add(FbRow(r, st.schema));
      }
    });
    return FbResult(st.schema, rows);
  }

  Future<List<Map<String, Object?>>> _collectMaps(
      int tr, StatementHandle st, List<Object?> values, bool commit) async {
    final names = st.schema.names;
    Map<String, Object?> toMap(List<Object?> r) =>
        {for (var i = 0; i < r.length; i++) names[i]: r[i]};
    if (!st.returnsCursor) {
      final out = await _engine.execute(tr, st, values, commitAfter: commit);
      final row = out.outputRow;
      return row == null ? [] : [toMap(row)];
    }
    final rows = <Map<String, Object?>>[];
    await _cursor(tr, st, values, (batch) {
      for (final r in batch) {
        rows.add(toMap(r));
      }
    });
    return rows;
  }

  Future<void> _each(int tr, StatementHandle st, List<Object?> values,
      bool commit, void Function(FbRow row) onRow) async {
    if (!st.returnsCursor) {
      final out = await _engine.execute(tr, st, values, commitAfter: commit);
      if (out.outputRow != null) onRow(FbRow(out.outputRow!, st.schema));
      return;
    }
    await _cursor(tr, st, values, (batch) {
      for (final r in batch) {
        onRow(FbRow(r, st.schema));
      }
    });
  }

  Future<void> _cursor(int tr, StatementHandle st, List<Object?> values,
      void Function(List<List<Object?>> batch) onBatch) async {
    final out = await _engine.execute(tr, st, values);
    var batch = out.firstBatch!;
    final blobs =
        st.hasBlobColumns && settings.blobMode == FbBlobMode.materialize;
    while (true) {
      if (blobs) await _engine.materializeBlobs(tr, st.columns, batch.rows);
      onBatch(batch.rows);
      if (batch.eof) break;
      batch = await _engine.fetch(st);
    }
  }

  /// Streams a cursor. The lock is held only during each round trip, so
  /// other requests can use the connection between batches.
  Stream<FbRow> _stream(String sql, List<Object?> values, FbTransaction? tx,
      StatementHandle? fixed, int? fetchSize) async* {
    final ownTx = tx == null;
    var tr = tx?._handle ?? 0;
    StatementHandle? st;
    var readOnly = false;
    var failed = false;
    var opened = false;
    final blobs = settings.blobMode == FbBlobMode.materialize;
    try {
      var batch = await _engine.guarded(() async {
        if (ownTx) {
          final known = fixed?.type ?? _engine.cachedType(sql);
          readOnly = settings.readOnlyAutoCommitSelects &&
              (known == null || known.returnsCursor);
          tr = await _engine.startTransaction(readOnly
              ? FbTransactionOptions.readOnlyCommitted
              : settings.autoCommitOptions);
          opened = true;
        } else {
          tx._checkActive();
        }
        if (fixed != null) {
          if (fixed.inUse) {
            throw FbUsageException('Prepared statement is busy');
          }
          fixed.inUse = true;
          st = fixed;
        } else {
          st = await _engine.acquireStatement(tr, sql);
        }
        if (!st!.returnsCursor) {
          throw FbUsageException('stream() needs a statement that returns '
              'rows; use execute() for: $sql');
        }
        final out =
            await _engine.execute(tr, st!, values, fetchSize: fetchSize);
        final b = out.firstBatch!;
        if (blobs && st!.hasBlobColumns) {
          await _engine.materializeBlobs(tr, st!.columns, b.rows);
        }
        return b;
      });
      final schema = st!.schema;
      while (true) {
        for (final r in batch.rows) {
          yield FbRow(r, schema);
        }
        if (batch.eof) break;
        batch = await _engine.guarded(() async {
          if (!ownTx) tx._checkActive();
          final b = await _engine.fetch(st!, fetchSize);
          if (blobs && st!.hasBlobColumns) {
            await _engine.materializeBlobs(tr, st!.columns, b.rows);
          }
          return b;
        });
      }
    } catch (_) {
      failed = true;
      rethrow;
    } finally {
      if (!_engine.isClosed && (st != null || opened)) {
        await _engine.lock.run(() async {
          if (_engine.isClosed) return;
          final s = st;
          if (s != null) {
            if (fixed == null) {
              _engine.releaseStatement(s);
            } else {
              s.inUse = false;
              _engine.closeCursor(s);
            }
          }
          if (ownTx && opened) {
            if (failed) {
              try {
                await _engine.rollback(tr);
              } on FbException catch (_) {}
            } else if (readOnly) {
              _engine.commitDeferred(tr);
            } else {
              await _engine.commit(tr);
            }
          }
        });
      }
    }
  }
}

/// An explicit transaction.
class FbTransaction with FbExecutor {
  final FbConnection connection;
  final int _handle;
  bool _active = true;
  int _savepointSeq = 0;

  FbTransaction._(this.connection, this._handle);

  bool get isActive => _active;
  Engine get _engine => connection._engine;

  void _checkActive() {
    if (!_active) throw FbUsageException('Transaction is no longer active');
  }

  Future<T> _run<T>(String sql, Duration? timeout,
      Future<T> Function(int tr, StatementHandle st) body) {
    return _engine.guarded(() async {
      _checkActive();
      final st = await _engine.acquireStatement(_handle, sql);
      try {
        return await body(_handle, st);
      } finally {
        if (!_engine.isClosed) _engine.releaseStatement(st);
      }
    }, timeout);
  }

  @override
  Future<FbResult> query(String sql, [Object? params, Duration? timeout]) {
    final (s, values) = resolveParams(sql, params);
    return _run(
        s, timeout, (tr, st) => connection._collect(tr, st, values, false));
  }

  @override
  Future<List<Map<String, Object?>>> queryMaps(String sql,
      [Object? params, Duration? timeout]) {
    final (s, values) = resolveParams(sql, params);
    return _run(
        s, timeout, (tr, st) => connection._collectMaps(tr, st, values, false));
  }

  @override
  Future<void> queryEach(
      String sql, Object? params, void Function(FbRow row) onRow,
      [Duration? timeout]) {
    final (s, values) = resolveParams(sql, params);
    return _run(
        s, timeout, (tr, st) => connection._each(tr, st, values, false, onRow));
  }

  @override
  Future<int> execute(String sql, [Object? params, Duration? timeout]) async {
    final (s, values) = resolveParams(sql, params);
    final r = await _run(
        s, timeout, (tr, st) => connection._collect(tr, st, values, false));
    return r.affectedRows;
  }

  @override
  Stream<FbRow> stream(String sql, [Object? params, int? fetchSize]) {
    final (s, values) = resolveParams(sql, params);
    return connection._stream(s, values, this, null, fetchSize);
  }

  // Savepoints ---------------------------------------------------------------

  static final RegExp _savepointName = RegExp(r'^[A-Za-z_][A-Za-z0-9_$]*$');

  String _checked(String name) {
    if (!_savepointName.hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'invalid savepoint name');
    }
    return name;
  }

  Future<void> createSavepoint(String name) =>
      execute('SAVEPOINT ${_checked(name)}');

  Future<void> rollbackToSavepoint(String name) =>
      execute('ROLLBACK TO SAVEPOINT ${_checked(name)}');

  Future<void> releaseSavepoint(String name) =>
      execute('RELEASE SAVEPOINT ${_checked(name)}');

  /// Runs [body] inside a savepoint: released when it completes, rolled
  /// back to (and the error rethrown) when it throws. The transaction
  /// remains usable either way.
  Future<T> savepoint<T>(Future<T> Function(FbTransaction sp) body,
      {String? name}) async {
    final sp = name ?? 'FBD_SP_${++_savepointSeq}';
    await createSavepoint(sp);
    final T result;
    try {
      result = await body(this);
    } catch (e, st) {
      if (_active && !connection.isClosed) {
        try {
          await rollbackToSavepoint(sp);
        } catch (_) {}
      }
      Error.throwWithStackTrace(e, st);
    }
    await releaseSavepoint(sp);
    return result;
  }

  // BLOBs ------------------------------------------------------------------

  /// Reads a BLOB returned with [FbBlobMode.id].
  Future<Uint8List> readBlob(FbBlobId id) => _engine.guarded(() async {
        _checkActive();
        return (await _engine.readBlobs(_handle, [id])).single;
      });

  /// Creates a BLOB and returns its id, to pass as a parameter.
  Future<FbBlobId> createBlob(List<int> data) => _engine.guarded(() async {
        _checkActive();
        return _engine.createBlob(_handle, data);
      });

  // End --------------------------------------------------------------------

  Future<void> commit() => _end(_engine.commit);
  Future<void> rollback() => _end(_engine.rollback);

  /// Commits and keeps the transaction open with the same context.
  Future<void> commitRetaining() => _engine.guarded(() async {
        _checkActive();
        await _engine.commitRetaining(_handle);
      });

  Future<void> rollbackRetaining() => _engine.guarded(() async {
        _checkActive();
        await _engine.rollbackRetaining(_handle);
      });

  Future<void> _end(Future<void> Function(int) op) => _engine.guarded(() async {
        _checkActive();
        try {
          await op(_handle);
        } finally {
          _active = false;
          connection._transactions.remove(this);
        }
      });
}

/// A statement prepared once and executed many times.
class FbPreparedStatement {
  final FbConnection connection;
  final StatementHandle _st;
  bool _closed = false;

  FbPreparedStatement._(this.connection, this._st);

  Engine get _engine => connection._engine;

  String get sql => _st.sql;
  FbStatementType get type => _st.type;
  List<FbColumn> get columns => _st.columns;
  List<FbColumn> get parameters => _st.params;

  void _check() {
    if (_closed) throw FbUsageException('Prepared statement is closed');
    if (_st.inUse) {
      throw FbUsageException('Prepared statement is busy (an open stream '
          'is using it)');
    }
  }

  List<Object?> _values(Object? params) {
    if (params == null) return const [];
    if (params is List) return params.cast<Object?>();
    throw FbUsageException('Prepared statements take positional parameters');
  }

  /// Runs the statement in [transaction], or in an implicit transaction.
  Future<FbResult> query(
      [Object? params, FbTransaction? transaction, Duration? timeout]) {
    final List<Object?> values;
    try {
      values = _values(params);
      _check();
    } catch (e, st) {
      return Future.error(e, st);
    }
    if (transaction != null) {
      return _engine.guarded(() async {
        transaction._checkActive();
        _check();
        return connection._collect(transaction._handle, _st, values, false);
      }, timeout);
    }
    return connection._auto(sql, _st, timeout,
        (tr, st, c) => connection._collect(tr, st, values, c));
  }

  Future<List<Map<String, Object?>>> queryMaps(
          [Object? params,
          FbTransaction? transaction,
          Duration? timeout]) async =>
      (await query(params, transaction, timeout)).toMaps();

  Future<int> execute(
          [Object? params,
          FbTransaction? transaction,
          Duration? timeout]) async =>
      (await query(params, transaction, timeout)).affectedRows;

  Stream<FbRow> stream(
      [Object? params, FbTransaction? transaction, int? fetchSize]) {
    if (_closed) throw FbUsageException('Prepared statement is closed');
    return connection._stream(
        sql, _values(params), transaction, _st, fetchSize);
  }

  /// Executes the statement once per parameter list inside one transaction
  /// ([transaction], or an implicit one committed at the end) and returns
  /// the total of affected rows. Executes are pipelined (up to 256 per
  /// round trip); if one fails, roll the transaction back — the implicit
  /// transaction does so automatically.
  Future<int> executeBatch(List<List<Object?>> batch,
      [FbTransaction? transaction]) async {
    if (transaction == null) {
      return connection.runInTransaction((tx) => executeBatch(batch, tx),
          connection.settings.autoCommitOptions);
    }
    return _engine.guarded(() async {
      transaction._checkActive();
      _check();
      return _engine.executeMany(transaction._handle, _st, batch);
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _engine.lock.run(() async {
      if (!_engine.isClosed) _engine.dropStatement(_st);
    });
  }
}
