import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'charset.dart';
import 'exceptions.dart';
import 'result.dart';
import 'settings.dart';
import 'types.dart';
import 'wire/constants.dart';
import 'wire/message.dart';
import 'wire/wire.dart';
import 'wire/xdr.dart';

/// FIFO asynchronous mutex.
class AsyncLock {
  Future<void> _tail = Future<void>.value();
  int _waiting = 0;

  bool get isLocked => _waiting > 0;

  Future<T> run<T>(Future<T> Function() action) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    _waiting++;
    return previous.then((_) => action()).whenComplete(() {
      _waiting--;
      done.complete();
    });
  }
}

/// A statement prepared on the server.
class StatementHandle {
  int handle;
  final String sql;
  FbStatementType type = FbStatementType.unknown;
  List<FbColumn> columns = const [];
  List<FbColumn> params = const [];
  late Uint8List outBlr;
  bool cursorOpen = false;
  bool inUse = false;
  bool cached = false;
  bool dropped = false;

  /// Whether any output column needs a BLOB read after fetching.
  bool hasBlobColumns = false;

  late final FbResultSchema schema = FbResultSchema(columns);

  StatementHandle(this.handle, this.sql);

  bool get returnsCursor => type.returnsCursor;
  bool get hasOutput => columns.isNotEmpty;
}

/// Rows from one `op_fetch` round trip.
class FetchBatch {
  final List<List<Object?>> rows;
  final bool eof;
  FetchBatch(this.rows, this.eof);
}

/// Result of an execute: affected rows and, for `EXECUTE PROCEDURE`/
/// `RETURNING`, the single output row.
class ExecOutcome {
  final int affectedRows;
  final List<Object?>? outputRow;
  final FetchBatch? firstBatch;
  ExecOutcome(this.affectedRows, {this.outputRow, this.firstBatch});
}

const List<int> _describeItems = [
  isc_info_sql_sqlda_seq,
  isc_info_sql_type,
  isc_info_sql_sub_type,
  isc_info_sql_scale,
  isc_info_sql_length,
  isc_info_sql_null_ind,
  isc_info_sql_field,
  isc_info_sql_relation,
  isc_info_sql_owner,
  isc_info_sql_alias,
  isc_info_sql_describe_end,
];

final Uint8List _prepareItems = Uint8List.fromList([
  isc_info_sql_stmt_type,
  isc_info_sql_select,
  isc_info_sql_describe_vars,
  ..._describeItems,
  isc_info_sql_bind,
  isc_info_sql_describe_vars,
  ..._describeItems,
]);

final Uint8List _recordsItems =
    Uint8List.fromList([isc_info_sql_records, isc_info_end]);

const int _infoBufferLength = 65535;
const int _segmentRequest = 32767;
const int _segmentWrite = 32000;
const int _blobPipelineChunk = 128;

/// Protocol operations of one attachment. Callers must hold [lock] around
/// every sequence of calls that sends and reads packets.
class Engine {
  final FbConnectionSettings settings;
  final FbWire wire;
  late final MessageCodec codec = MessageCodec(wire,
      trimChar: settings.trimChar, numericMode: settings.numericMode);
  final AsyncLock lock = AsyncLock();
  final LinkedHashMap<String, StatementHandle> _cache = LinkedHashMap();
  bool _broken = false;

  Engine._(this.settings, this.wire);

  static Future<Engine> open(FbConnectionSettings settings,
      {bool create = false, int? pageSize}) async {
    final wire = FbWire(settings);
    await wire.open(create: create, pageSize: pageSize);
    return Engine._(settings, wire);
  }

  bool get isClosed => wire.isClosed || _broken;

  /// Marks the attachment unusable after a transport failure.
  Never fail(Object error, StackTrace st) {
    if (error is FbConnectionException || error is StateError) {
      _broken = true;
      wire.destroy();
    }
    Error.throwWithStackTrace(error, st);
  }

  /// Runs [action] under the lock, turning transport failures into a
  /// broken connection. With a [timeout] (or the configured
  /// `commandTimeout`), an overdue request is cancelled on the server and a
  /// [TimeoutException] is thrown.
  Future<T> guarded<T>(Future<T> Function() action, [Duration? timeout]) =>
      lock.run(() async {
        if (isClosed) throw FbConnectionException('Connection is closed');
        final limit = timeout ?? settings.commandTimeout;
        try {
          if (limit == null) return await action();
          return await _withTimeout(action(), limit);
        } catch (e, st) {
          fail(e, st);
        }
      });

  static const Duration _cancelGrace = Duration(seconds: 10);

  Future<T> _withTimeout<T>(Future<T> future, Duration limit) async {
    try {
      return await future.timeout(limit);
    } on TimeoutException {
      if (wire.protocolVersion < 12) {
        // No out-of-band cancel before Firebird 2.5: drop the connection.
        _broken = true;
        await wire.destroy();
        future.ignore();
        throw TimeoutException('Firebird request exceeded $limit', limit);
      }
      wire.cancelOperation(fb_cancel_raise);
      try {
        await future.timeout(_cancelGrace);
      } on TimeoutException {
        _broken = true;
        await wire.destroy();
        future.ignore();
        throw TimeoutException(
            'Firebird request exceeded $limit and did not stop after '
            'cancellation; the connection was closed',
            limit);
      } catch (_) {
        // Expected: isc_cancelled.
      }
      // A cancel that arrived after the request ended stays pending on the
      // attachment; absorb it with a harmless round trip.
      try {
        await wire.infoDatabase(const [isc_info_ods_version, isc_info_end]);
      } on FbException catch (e) {
        if (e is FbConnectionException) rethrow;
      }
      throw TimeoutException(
          'Firebird request exceeded $limit and was cancelled', limit);
    }
  }

  // -------------------------------------------------------------------------
  // Transactions.
  // -------------------------------------------------------------------------

  Future<int> startTransaction(FbTransactionOptions options) async {
    final w = XdrWriter(64)
      ..int32(op_transaction)
      ..int32(wire.dbHandle)
      ..buffer(options.toTpb());
    wire.send(w.takeBytes());
    return (await wire.readResponse()).handle;
  }

  Future<void> commit(int tr) => wire.simpleRequest(op_commit, tr);
  Future<void> rollback(int tr) => wire.simpleRequest(op_rollback, tr);
  Future<void> commitRetaining(int tr) =>
      wire.simpleRequest(op_commit_retaining, tr);
  Future<void> rollbackRetaining(int tr) =>
      wire.simpleRequest(op_rollback_retaining, tr);

  /// Sends a commit whose response is read later (read-only work only).
  void commitDeferred(int tr) {
    wire.sendDeferred((XdrWriter(16)
          ..int32(op_commit)
          ..int32(tr))
        .takeBytes());
  }

  // -------------------------------------------------------------------------
  // Statements.
  // -------------------------------------------------------------------------

  /// Returns a prepared statement for [sql], from the cache when possible.
  Future<StatementHandle> acquireStatement(int tr, String sql) async {
    final cached = _cache.remove(sql);
    if (cached != null && !cached.inUse) {
      _cache[sql] = cached; // most recently used
      cached.inUse = true;
      return cached;
    }
    if (cached != null) _cache[sql] = cached;
    final st = await prepare(tr, sql);
    st.inUse = true;
    if (settings.statementCacheSize > 0 && cached == null) {
      st.cached = true;
      _cache[sql] = st;
      while (_cache.length > settings.statementCacheSize) {
        final oldest = _cache.keys.first;
        final victim = _cache.remove(oldest)!;
        victim.cached = false;
        if (!victim.inUse) dropStatement(victim);
      }
    }
    return st;
  }

  /// Type of [sql] if it is in the statement cache.
  FbStatementType? cachedType(String sql) => _cache[sql]?.type;

  /// Returns a statement taken with [acquireStatement].
  void releaseStatement(StatementHandle st) {
    st.inUse = false;
    if (st.cursorOpen) closeCursor(st);
    if (!st.cached) dropStatement(st);
  }

  /// Frees all cached statements (after DDL, metadata may have changed).
  void clearStatementCache() {
    for (final st in _cache.values) {
      st.cached = false;
      if (!st.inUse) dropStatement(st);
    }
    _cache.clear();
  }

  void dropStatement(StatementHandle st) {
    if (st.dropped || wire.isClosed) return;
    st.dropped = true;
    wire.sendDeferred((XdrWriter(16)
          ..int32(op_free_statement)
          ..int32(st.handle)
          ..int32(DSQL_drop))
        .takeBytes());
  }

  void closeCursor(StatementHandle st) {
    if (!st.cursorOpen) return;
    st.cursorOpen = false;
    wire.sendDeferred((XdrWriter(16)
          ..int32(op_free_statement)
          ..int32(st.handle)
          ..int32(DSQL_close))
        .takeBytes());
  }

  /// Allocates and prepares a statement in one round trip (protocol 11+
  /// lets op_prepare_statement refer to the statement just allocated).
  Future<StatementHandle> prepare(int tr, String sql) async {
    final lazy = wire.protocolVersion >= 11;
    wire.send((XdrWriter(16)
          ..int32(op_allocate_statement)
          ..int32(wire.dbHandle))
        .takeBytes());
    int handle;
    if (lazy) {
      _sendPrepare(tr, INVALID_OBJECT, sql);
      handle = (await wire.readResponse()).handle;
    } else {
      handle = (await wire.readResponse()).handle;
      _sendPrepare(tr, handle, sql);
    }
    final st = StatementHandle(handle, sql);
    final FbResponse r;
    try {
      r = await wire.readResponse();
    } on FbException catch (e) {
      if (e is FbConnectionException) rethrow;
      dropStatement(st);
      rethrow;
    }
    await _describe(st, r.data);
    final type = st.type;
    if (type == FbStatementType.startTransaction ||
        type == FbStatementType.commit ||
        type == FbStatementType.rollback) {
      dropStatement(st);
      throw FbUsageException('Transaction control statements are not '
          'allowed; use the transaction API instead');
    }
    st.outBlr = MessageCodec.outputBlr(st.columns);
    st.hasBlobColumns = st.columns.any((c) => c.sqlType == SQL_BLOB);
    return st;
  }

  void _sendPrepare(int tr, int handle, String sql) {
    final w = XdrWriter(64 + sql.length * 2)
      ..int32(op_prepare_statement)
      ..int32(tr)
      ..int32(handle)
      ..int32(settings.dialect)
      ..buffer(wire.textCodec.encode(sql))
      ..buffer(_prepareItems)
      ..int32(_infoBufferLength);
    wire.send(w.takeBytes());
  }

  Future<void> _describe(StatementHandle st, Uint8List data) async {
    final state = _DescribeState();
    _parseDescribe(data, state);
    while (!state.selectDone || !state.bindDone) {
      final selectPart = !state.selectDone;
      final start = selectPart ? state.selectNext : state.bindNext;
      final items = <int>[
        isc_info_sql_sqlda_start,
        2,
        start & 0xFF,
        start >> 8,
        selectPart ? isc_info_sql_select : isc_info_sql_bind,
        isc_info_sql_describe_vars,
        ..._describeItems,
      ];
      final w = XdrWriter(64)
        ..int32(op_info_sql)
        ..int32(st.handle)
        ..int32(0)
        ..buffer(items)
        ..int32(_infoBufferLength);
      wire.send(w.takeBytes());
      final before = selectPart ? state.selectNext : state.bindNext;
      _parseDescribe((await wire.readResponse()).data, state,
          onlySelect: selectPart, onlyBind: !selectPart);
      final after = selectPart ? state.selectNext : state.bindNext;
      final done = selectPart ? state.selectDone : state.bindDone;
      if (!done && after <= before) {
        throw FbConnectionException('Statement description does not fit '
            'the info buffer');
      }
    }
    st.type = FbStatementType.fromCode(state.stmtType);
    st.columns = state.select ?? const [];
    st.params = state.bind ?? const [];
  }

  void _parseDescribe(Uint8List b, _DescribeState s,
      {bool onlySelect = false, bool onlyBind = false}) {
    var i = 0;
    List<FbColumn>? current;
    var inSelect = false;
    FbColumn? v;
    var lastSeq = 0;
    final meta = wire.metaCodec;
    int readLen() {
      final l = b[i] | (b[i + 1] << 8);
      i += 2;
      return l;
    }

    int readIntItem() {
      final l = readLen();
      final value = leInt(b, i, l);
      i += l;
      return value;
    }

    String readStr() {
      final l = readLen();
      final value = meta.decode(Uint8List.sublistView(b, i, i + l));
      i += l;
      return value;
    }

    void markDone() {
      if (current == null) return;
      if (inSelect) {
        s.selectDone = true;
      } else {
        s.bindDone = true;
      }
    }

    loop:
    while (i < b.length) {
      final item = b[i++];
      switch (item) {
        case isc_info_end:
          markDone();
          break loop;
        case isc_info_truncated:
          if (current == null) {
            // Nothing described yet in this buffer: restart where we were.
            break loop;
          }
          if (inSelect) {
            s.selectNext = lastSeq == 0 ? 1 : lastSeq;
            if (!onlySelect) s.bindNext = 1;
          } else {
            s.bindNext = lastSeq == 0 ? 1 : lastSeq;
          }
          break loop;
        case isc_info_sql_stmt_type:
          s.stmtType = readIntItem();
        case isc_info_sql_select:
          markDone();
          inSelect = true;
          lastSeq = 0;
          current = null;
        case isc_info_sql_bind:
          markDone();
          inSelect = false;
          lastSeq = 0;
          current = null;
        case isc_info_sql_describe_vars:
          final count = readIntItem();
          if (inSelect) {
            s.select ??= List.generate(count, (_) => FbColumn());
            current = s.select;
          } else {
            s.bind ??= List.generate(count, (_) => FbColumn());
            current = s.bind;
          }
        case isc_info_sql_sqlda_seq:
          lastSeq = readIntItem();
          v = current![lastSeq - 1];
        case isc_info_sql_type:
          final t = readIntItem();
          v!.sqlType = t & ~1;
          v.nullable = (t & 1) != 0;
        case isc_info_sql_sub_type:
          v!.subType = readIntItem();
        case isc_info_sql_scale:
          v!.scale = readIntItem();
        case isc_info_sql_length:
          v!.length = readIntItem();
        case isc_info_sql_null_ind:
          readIntItem();
        case isc_info_sql_field:
          v!.fieldName = readStr();
        case isc_info_sql_relation:
          v!.relationName = readStr();
        case isc_info_sql_owner:
          v!.ownerName = readStr();
        case isc_info_sql_alias:
          v!.alias = readStr();
        case isc_info_sql_describe_end:
          break;
        case isc_info_error:
          throw FbConnectionException('Server could not describe statement');
        default:
          throw FbConnectionException(
              'Protocol error: unexpected describe item $item');
      }
    }
    // Blocks that were requested but never seen are complete when empty.
    if (s.select == null && !onlyBind && s.selectNext == 1) {
      // still pending; keep selectDone false
    }
  }

  // -------------------------------------------------------------------------
  // Execution.
  // -------------------------------------------------------------------------

  /// Converts BLOB parameter values into BLOB ids, creating the BLOBs.
  Future<List<Object?>> prepareParams(
      int tr, StatementHandle st, List<Object?> values) async {
    if (values.length != st.params.length) {
      throw FbUsageException('Statement expects ${st.params.length} '
          'parameter(s) but ${values.length} were given');
    }
    List<Object?>? out;
    for (var i = 0; i < values.length; i++) {
      final p = st.params[i];
      final v = values[i];
      if (p.sqlType != SQL_BLOB || v == null || v is FbBlobId) continue;
      final List<int> bytes;
      if (v is String) {
        bytes = _blobCodec(p).encode(v);
      } else if (v is List<int>) {
        bytes = v;
      } else {
        throw FbUsageException('BLOB parameter ${i + 1} accepts String or '
            'bytes, not ${v.runtimeType}');
      }
      out ??= List.of(values);
      out[i] = await createBlob(tr, bytes);
    }
    return out ?? values;
  }

  Encoding _blobCodec(FbColumn c) {
    final cs = c.scale & 0xFF;
    if (cs == FbCharset.none.id || cs == FbCharset.octets.id) {
      return wire.noneCodec;
    }
    return FbCharset.byId(cs)?.encoding ?? wire.textCodec;
  }

  /// Executes [st]. For cursor statements the first batch of rows is
  /// fetched in the same round trip. When [commitAfter] is given and the
  /// statement is not a cursor, the commit is pipelined after the execute.
  Future<ExecOutcome> execute(int tr, StatementHandle st, List<Object?> values,
      {bool commitAfter = false, int? fetchSize}) async {
    if (st.cursorOpen) closeCursor(st);
    final params = await prepareParams(tr, st, values);
    final useExecute2 =
        st.type == FbStatementType.execProcedure && st.hasOutput;
    final w = XdrWriter(128);
    w
      ..int32(useExecute2 ? op_execute2 : op_execute)
      ..int32(st.handle)
      ..int32(tr);
    if (st.params.isEmpty) {
      w
        ..buffer(const [])
        ..int32(0)
        ..int32(0);
    } else {
      final msg = codec.encodeParams(st.params, params);
      w
        ..buffer(msg.blr)
        ..int32(0)
        ..int32(1)
        ..raw(msg.data);
    }
    if (useExecute2) {
      w
        ..buffer(st.outBlr)
        ..int32(0);
    }

    if (st.returnsCursor) {
      _writeFetch(w, st, fetchSize);
      wire.send(w.takeBytes());
      final r = await wire.readResponseUnchecked();
      if (r.error != null) {
        await _skipFetchResponse();
        throw r.error!;
      }
      st.cursorOpen = true;
      final batch = await _readFetch(st);
      return ExecOutcome(0, firstBatch: batch);
    }

    final countRows = st.type == FbStatementType.insert ||
        st.type == FbStatementType.update ||
        st.type == FbStatementType.delete ||
        st.type == FbStatementType.execProcedure;
    if (countRows) {
      w
        ..int32(op_info_sql)
        ..int32(st.handle)
        ..int32(0)
        ..buffer(_recordsItems)
        ..int32(64);
    }
    final pipelineCommit = commitAfter && !st.hasBlobColumns;
    if (pipelineCommit) {
      w
        ..int32(op_commit)
        ..int32(tr);
    }
    wire.send(w.takeBytes());

    FbException? error;
    List<Object?>? output;
    if (useExecute2) {
      await wire.drainDeferred();
      final op = await wire.readOp();
      if (op == op_sql_response) {
        final count = await wire.input.int32();
        if (count > 0) output = await codec.readRow(st.columns);
        final r = await wire.readResponseUnchecked();
        error = r.error;
      } else if (op == op_response) {
        error = (await wire.readResponseBody()).error;
      } else {
        throw FbConnectionException('Protocol error: unexpected op $op');
      }
    } else {
      error = (await wire.readResponseUnchecked()).error;
    }
    var affected = 0;
    if (countRows) {
      final r = await wire.readResponseUnchecked();
      if (error == null && r.error == null) {
        affected = _parseRecords(r.data, st.type);
      }
    }
    if (pipelineCommit) {
      final r = await wire.readResponseUnchecked();
      error ??= r.error;
    }
    if (error != null) throw error;
    if (st.type == FbStatementType.ddl) clearStatementCache();
    if (output != null && st.hasBlobColumns) {
      await materializeBlobs(tr, st.columns, [output]);
      if (commitAfter) await commit(tr);
    } else if (commitAfter && !pipelineCommit) {
      await commit(tr);
    }
    return ExecOutcome(affected, outputRow: output);
  }

  /// Executes [st] once per parameter list, pipelining up to [chunk]
  /// executes per round trip. Statements with BLOB parameters or output
  /// rows run one by one. When one execute fails, the others already sent
  /// in the same chunk have run too: roll the transaction back on error.
  Future<int> executeMany(int tr, StatementHandle st, List<List<Object?>> batch,
      {int chunk = 256}) async {
    final sequential = st.returnsCursor ||
        st.hasOutput ||
        st.params.any((p) => p.sqlType == SQL_BLOB);
    var total = 0;
    if (sequential) {
      for (final values in batch) {
        total += (await execute(tr, st, values)).affectedRows;
      }
      return total;
    }
    final count = st.type == FbStatementType.insert ||
        st.type == FbStatementType.update ||
        st.type == FbStatementType.delete;
    for (var start = 0; start < batch.length; start += chunk) {
      final end = start + chunk > batch.length ? batch.length : start + chunk;
      final w = XdrWriter(4096);
      for (var i = start; i < end; i++) {
        final values = batch[i];
        if (values.length != st.params.length) {
          throw FbUsageException('Batch item $i has ${values.length} '
              'value(s); the statement expects ${st.params.length}');
        }
        w
          ..int32(op_execute)
          ..int32(st.handle)
          ..int32(tr);
        if (st.params.isEmpty) {
          w
            ..buffer(const [])
            ..int32(0)
            ..int32(0);
        } else {
          final msg = codec.encodeParams(st.params, values);
          w
            ..buffer(msg.blr)
            ..int32(0)
            ..int32(1)
            ..raw(msg.data);
        }
        if (count) {
          w
            ..int32(op_info_sql)
            ..int32(st.handle)
            ..int32(0)
            ..buffer(_recordsItems)
            ..int32(64);
        }
      }
      wire.send(w.takeBytes());
      FbException? error;
      for (var i = start; i < end; i++) {
        final r = await wire.readResponseUnchecked();
        error ??= r.error;
        if (count) {
          final info = await wire.readResponseUnchecked();
          if (r.error == null && info.error == null) {
            total += _parseRecords(info.data, st.type);
          }
        }
      }
      if (error != null) throw error;
    }
    if (st.type == FbStatementType.ddl) clearStatementCache();
    return total;
  }

  void _writeFetch(XdrWriter w, StatementHandle st, int? fetchSize) {
    w
      ..int32(op_fetch)
      ..int32(st.handle)
      ..buffer(st.outBlr)
      ..int32(0)
      ..int32(fetchSize ?? settings.fetchSize);
  }

  /// Fetches the next batch of an open cursor.
  Future<FetchBatch> fetch(StatementHandle st, [int? fetchSize]) async {
    if (!st.cursorOpen) return FetchBatch(const [], true);
    final w = XdrWriter(64);
    _writeFetch(w, st, fetchSize);
    wire.send(w.takeBytes());
    await wire.drainDeferred();
    return _readFetch(st);
  }

  Future<FetchBatch> _readFetch(StatementHandle st) async {
    final rows = <List<Object?>>[];
    final input = wire.input;
    while (true) {
      final op = await wire.readOp();
      if (op == op_response) {
        (await wire.readResponseBody()).check();
        throw FbConnectionException('Protocol error: unexpected op_response');
      }
      if (op != op_fetch_response) {
        throw FbConnectionException('Protocol error: unexpected op $op');
      }
      final f = input.need(8);
      if (f != null) await f;
      final status = input.readInt32();
      final count = input.readInt32();
      if (count == 0) {
        final eof = status == 100;
        if (eof) closeCursor(st);
        return FetchBatch(rows, eof);
      }
      rows.add(await codec.readRow(st.columns));
    }
  }

  /// Consumes the reply to an op_fetch sent after a failed execute.
  Future<void> _skipFetchResponse() async {
    while (true) {
      final op = await wire.readOp();
      if (op == op_response) {
        await wire.readResponseBody();
        return;
      }
      if (op != op_fetch_response) {
        throw FbConnectionException('Protocol error: unexpected op $op');
      }
      await wire.input.int32();
      final count = await wire.input.int32();
      if (count == 0) return;
      throw FbConnectionException('Protocol error: rows after failed execute');
    }
  }

  int _parseRecords(Uint8List b, FbStatementType type) {
    var i = 0;
    var total = 0;
    while (i < b.length) {
      final item = b[i++];
      if (item == isc_info_end) break;
      if (item == isc_info_sql_records) {
        i += 2;
        continue;
      }
      final l = b[i] | (b[i + 1] << 8);
      i += 2;
      final v = leInt(b, i, l);
      i += l;
      switch (item) {
        case isc_info_req_insert_count:
        case isc_info_req_update_count:
        case isc_info_req_delete_count:
          total += v;
      }
    }
    return total;
  }

  // -------------------------------------------------------------------------
  // BLOBs.
  // -------------------------------------------------------------------------

  /// Replaces [FbBlobId] values of BLOB columns with their content.
  Future<void> materializeBlobs(
      int tr, List<FbColumn> columns, List<List<Object?>> rows) async {
    final refs = <(List<Object?>, int, FbBlobId)>[];
    for (var c = 0; c < columns.length; c++) {
      if (columns[c].sqlType != SQL_BLOB) continue;
      for (final row in rows) {
        final v = row[c];
        if (v is FbBlobId) refs.add((row, c, v));
      }
    }
    for (var start = 0; start < refs.length; start += _blobPipelineChunk) {
      final end = start + _blobPipelineChunk > refs.length
          ? refs.length
          : start + _blobPipelineChunk;
      final chunk = refs.sublist(start, end);
      final contents = await readBlobs(tr, [for (final r in chunk) r.$3]);
      for (var i = 0; i < chunk.length; i++) {
        final (row, c, _) = chunk[i];
        final col = columns[c];
        row[c] = col.subType == 1
            ? _blobCodec(col).decode(contents[i])
            : contents[i];
      }
    }
  }

  /// Reads several BLOBs with pipelined requests.
  Future<List<Uint8List>> readBlobs(int tr, List<FbBlobId> ids) async {
    if (ids.isEmpty) return const [];
    final w = XdrWriter(32 * ids.length);
    for (final id in ids) {
      w
        ..int32(op_open_blob)
        ..int32(tr)
        ..raw(id.bytes);
    }
    wire.send(w.takeBytes());
    final handles = List<int>.filled(ids.length, -1);
    FbException? error;
    for (var i = 0; i < ids.length; i++) {
      final r = await wire.readResponseUnchecked();
      if (r.error != null) {
        error ??= r.error;
      } else {
        handles[i] = r.handle;
      }
    }
    if (error != null) {
      for (final h in handles) {
        if (h >= 0) _closeBlobDeferred(h);
      }
      throw error;
    }
    final builders =
        List.generate(ids.length, (_) => BytesBuilder(copy: false));
    var pending = List<int>.generate(ids.length, (i) => i);
    while (pending.isNotEmpty) {
      final req = XdrWriter(20 * pending.length);
      for (final i in pending) {
        req
          ..int32(op_get_segment)
          ..int32(handles[i])
          ..int32(_segmentRequest)
          ..int32(0);
      }
      wire.send(req.takeBytes());
      final next = <int>[];
      for (final i in pending) {
        final r = await wire.readResponseUnchecked();
        if (r.error != null) {
          error ??= r.error;
          continue;
        }
        final d = r.data;
        var p = 0;
        while (p + 2 <= d.length) {
          final l = d[p] | (d[p + 1] << 8);
          builders[i].add(Uint8List.sublistView(d, p + 2, p + 2 + l));
          p += 2 + l;
        }
        if (r.handle != 2) next.add(i); // 2 = isc_segstr_eof
      }
      if (error != null) break;
      pending = next;
    }
    for (final h in handles) {
      _closeBlobDeferred(h);
    }
    if (error != null) throw error;
    return [for (final b in builders) b.takeBytes()];
  }

  void _closeBlobDeferred(int handle) {
    wire.sendDeferred((XdrWriter(16)
          ..int32(op_close_blob)
          ..int32(handle))
        .takeBytes());
  }

  /// Creates a BLOB with [data] and returns its id.
  Future<FbBlobId> createBlob(int tr, List<int> data) async {
    final w = XdrWriter(32)
      ..int32(op_create_blob2)
      ..buffer(const [])
      ..int32(tr)
      ..raw(Uint8List(8));
    wire.send(w.takeBytes());
    final r = await wire.readResponse();
    final handle = r.handle;
    final id = FbBlobId(Uint8List.fromList(r.blobId));
    final out = XdrWriter(data.length + 64);
    var segments = 0;
    for (var off = 0; off < data.length; off += _segmentWrite) {
      final end =
          off + _segmentWrite > data.length ? data.length : off + _segmentWrite;
      final seg = data is Uint8List
          ? Uint8List.sublistView(data, off, end)
          : data.sublist(off, end);
      out
        ..int32(op_put_segment)
        ..int32(handle)
        ..int32(seg.length)
        ..buffer(seg);
      segments++;
    }
    out
      ..int32(op_close_blob)
      ..int32(handle);
    wire.send(out.takeBytes());
    FbException? error;
    for (var i = 0; i <= segments; i++) {
      final resp = await wire.readResponseUnchecked();
      error ??= resp.error;
    }
    if (error != null) throw error;
    return id;
  }

  // -------------------------------------------------------------------------
  // Database information and shutdown.
  // -------------------------------------------------------------------------

  Future<Map<int, Uint8List>> databaseInfo(List<int> items) async {
    final data = await wire.infoDatabase([...items, isc_info_end]);
    final out = <int, Uint8List>{};
    var i = 0;
    while (i < data.length) {
      final item = data[i++];
      if (item == isc_info_end || item == isc_info_truncated) break;
      final l = data[i] | (data[i + 1] << 8);
      i += 2;
      out[item] = Uint8List.sublistView(data, i, i + l);
      i += l;
    }
    return out;
  }

  Future<void> close() async {
    if (wire.isClosed) return;
    try {
      clearStatementCache();
      await wire.detach();
    } catch (_) {
      await wire.destroy();
    }
  }
}

class _DescribeState {
  int stmtType = 0;
  List<FbColumn>? select;
  List<FbColumn>? bind;
  bool selectDone = false;
  bool bindDone = false;
  int selectNext = 1;
  int bindNext = 1;
}
