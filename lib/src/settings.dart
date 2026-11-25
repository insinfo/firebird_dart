import 'dart:convert';

import 'charset.dart';
import 'wire/constants.dart';
import 'wire/xdr.dart';

/// Transaction isolation levels.
enum FbIsolation {
  /// `READ COMMITTED`: sees changes committed by others after it started.
  readCommitted,

  /// `SNAPSHOT` (concurrency): a stable view from the transaction start.
  snapshot,

  /// `SNAPSHOT TABLE STABILITY` (consistency): snapshot plus table locks.
  snapshotTableStability,
}

/// Lock mode of a reserved table.
enum FbLockMode {
  /// Others may read and, with write reservations, write too.
  shared,

  /// Others may read but not write.
  protected,

  /// Only this transaction may access the table (snapshot table
  /// stability).
  exclusive,
}

/// A table reserved when the transaction starts (`RESERVING ... FOR`),
/// so lock conflicts surface at start instead of mid-transaction.
class FbTableReservation {
  final String table;
  final bool write;
  final FbLockMode mode;

  const FbTableReservation(this.table,
      {this.write = false, this.mode = FbLockMode.shared});
}

/// Options used to start a transaction (the TPB).
class FbTransactionOptions {
  final FbIsolation isolation;
  final bool readOnly;

  /// Wait for locks held by other transactions instead of failing at once.
  final bool wait;

  /// Maximum wait in seconds when [wait] is true (Firebird 2.0+).
  final int? lockTimeout;

  /// For [FbIsolation.readCommitted]: read the latest committed version
  /// (`RECORD_VERSION`) instead of waiting on uncommitted ones.
  final bool recordVersion;

  /// Disables the automatic undo log (`NO AUTO UNDO`), useful for bulk
  /// loads.
  final bool noAutoUndo;

  /// Tables locked at transaction start.
  final List<FbTableReservation> reserving;

  /// Ignore records of transactions in limbo (two-phase commit).
  final bool ignoreLimbo;

  const FbTransactionOptions({
    this.isolation = FbIsolation.readCommitted,
    this.readOnly = false,
    this.wait = true,
    this.lockTimeout,
    this.recordVersion = true,
    this.noAutoUndo = false,
    this.reserving = const [],
    this.ignoreLimbo = false,
  });

  /// Read-only read-committed transaction. Firebird does not let these hold
  /// back garbage collection, so they suit long reads.
  static const readOnlyCommitted = FbTransactionOptions(
      readOnly: true, isolation: FbIsolation.readCommitted);

  static const snapshotReadOnly =
      FbTransactionOptions(readOnly: true, isolation: FbIsolation.snapshot);

  List<int> toTpb() {
    final b = ParamBlockBuilder(isc_tpb_version3);
    b.tag(readOnly ? isc_tpb_read : isc_tpb_write);
    switch (isolation) {
      case FbIsolation.readCommitted:
        b.tag(isc_tpb_read_committed);
        b.tag(recordVersion ? isc_tpb_rec_version : isc_tpb_no_rec_version);
      case FbIsolation.snapshot:
        b.tag(isc_tpb_concurrency);
      case FbIsolation.snapshotTableStability:
        b.tag(isc_tpb_consistency);
    }
    b.tag(wait ? isc_tpb_wait : isc_tpb_nowait);
    if (wait && lockTimeout != null) {
      b.int32(isc_tpb_lock_timeout, lockTimeout!);
    }
    if (noAutoUndo) b.tag(isc_tpb_no_auto_undo);
    if (ignoreLimbo) b.tag(isc_tpb_ignore_limbo);
    for (final r in reserving) {
      b.bytes(r.write ? isc_tpb_lock_write : isc_tpb_lock_read,
          utf8.encode(r.table));
      b.tag(switch (r.mode) {
        FbLockMode.shared => isc_tpb_shared,
        FbLockMode.protected => isc_tpb_protected,
        FbLockMode.exclusive => isc_tpb_exclusive,
      });
    }
    return b.build();
  }
}

/// Authentication methods for Firebird 3+ servers. Firebird 2.x always uses
/// the legacy method.
enum FbAuthPlugin { srp256, srp, legacyAuth }

/// Wire encryption policy for Firebird 3+ servers.
enum FbWireCrypt {
  /// Encrypt when the server supports it (Firebird default).
  enabled,

  /// Fail unless the traffic can be encrypted.
  required,

  /// Never encrypt.
  disabled,
}

/// How BLOB columns are returned.
enum FbBlobMode {
  /// Read the whole BLOB: `String` for text blobs (sub_type 1), `Uint8List`
  /// otherwise.
  materialize,

  /// Return an [FbBlobId] that can be read later inside the same
  /// transaction.
  id,
}

/// How `NUMERIC`/`DECIMAL` columns with decimals are returned.
enum FbNumericMode {
  /// [FbDecimal] (exact; default).
  decimal,

  /// Exact decimal text, e.g. `"12.50"` (what postgres_fork/eloquent use).
  string,

  /// `double` (may lose precision).
  double,
}

/// Connection parameters.
class FbConnectionSettings {
  final String host;
  final int port;

  /// Database path on the server, or an alias from aliases.conf /
  /// databases.conf.
  final String database;
  final String user;
  final String password;
  final String? role;

  /// Connection character set (`lc_ctype`): UTF8, WIN1252, ISO8859_1,
  /// ASCII, UNICODE_FSS, NONE or OCTETS.
  final String charset;

  /// Codec for columns declared with `CHARACTER SET NONE`, whose bytes the
  /// server passes through unchanged. Defaults to the codec of [charset],
  /// or UTF-8 when [charset] is NONE.
  final Encoding? noneEncoding;

  final int dialect;
  final Duration connectTimeout;

  /// Name reported in `MON$ATTACHMENTS.MON$REMOTE_PROCESS`.
  final String applicationName;

  /// Rows requested per `op_fetch` round trip.
  final int fetchSize;

  /// Prepared statements kept per connection (0 disables the cache).
  final int statementCacheSize;

  /// Options of the implicit transaction used by calls made outside an
  /// explicit transaction (one transaction per call, committed at the end).
  final FbTransactionOptions autoCommitOptions;

  /// Run SELECTs made outside an explicit transaction in a read-only
  /// read-committed transaction whose commit is pipelined with the next
  /// request (one round trip less). A selectable procedure that writes
  /// then fails with "attempted update during read-only transaction"; run
  /// it inside an explicit transaction, or set this to false.
  final bool readOnlyAutoCommitSelects;

  final FbBlobMode blobMode;

  final FbNumericMode numericMode;

  /// Default timeout of each request. On expiry the request is cancelled on
  /// the server (Firebird 2.5+) and a `TimeoutException` is thrown.
  final Duration? commandTimeout;

  /// Authentication plugins tried, in order (Firebird 3+).
  final List<FbAuthPlugin> authPlugins;
  final FbWireCrypt wireCrypt;

  /// Remove trailing spaces from `CHAR(n)` values.
  final bool trimChar;

  const FbConnectionSettings({
    this.host = 'localhost',
    this.port = 3050,
    required this.database,
    this.user = 'SYSDBA',
    this.password = 'masterkey',
    this.role,
    this.charset = 'UTF8',
    this.noneEncoding,
    this.dialect = 3,
    this.connectTimeout = const Duration(seconds: 15),
    this.applicationName = 'firebird_dart',
    this.fetchSize = 400,
    this.statementCacheSize = 32,
    this.autoCommitOptions = const FbTransactionOptions(),
    this.readOnlyAutoCommitSelects = true,
    this.blobMode = FbBlobMode.materialize,
    this.numericMode = FbNumericMode.decimal,
    this.commandTimeout,
    this.authPlugins = const [
      FbAuthPlugin.srp256,
      FbAuthPlugin.srp,
      FbAuthPlugin.legacyAuth,
    ],
    this.wireCrypt = FbWireCrypt.enabled,
    this.trimChar = false,
  });

  /// Parses a Firebird connection string: `host[/port]:path`, or a bare
  /// path/alias for localhost. Windows drive letters are recognised, so
  /// `C:\db\x.fdb` is local and `server:C:\db\x.fdb` is remote.
  factory FbConnectionSettings.fromDsn(
    String dsn, {
    String user = 'SYSDBA',
    String password = 'masterkey',
    String? role,
    String charset = 'UTF8',
    Encoding? noneEncoding,
  }) {
    var host = 'localhost';
    var port = 3050;
    var path = dsn;
    final isDrive = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(dsn);
    final colon = dsn.indexOf(':');
    if (!isDrive && colon > 0) {
      var hostPart = dsn.substring(0, colon);
      path = dsn.substring(colon + 1);
      final slash = hostPart.indexOf('/');
      if (slash >= 0) {
        port = int.parse(hostPart.substring(slash + 1));
        hostPart = hostPart.substring(0, slash);
      }
      host = hostPart;
    }
    return FbConnectionSettings(
      host: host,
      port: port,
      database: path,
      user: user,
      password: password,
      role: role,
      charset: charset,
      noneEncoding: noneEncoding,
    );
  }

  FbCharset get fbCharset => FbCharset.byName(charset);

  FbConnectionSettings copyWith({
    String? host,
    int? port,
    String? database,
    String? user,
    String? password,
    String? role,
    String? charset,
    Encoding? noneEncoding,
    int? fetchSize,
    int? statementCacheSize,
    FbTransactionOptions? autoCommitOptions,
    bool? readOnlyAutoCommitSelects,
    FbBlobMode? blobMode,
    FbNumericMode? numericMode,
    Duration? commandTimeout,
    List<FbAuthPlugin>? authPlugins,
    FbWireCrypt? wireCrypt,
    bool? trimChar,
    String? applicationName,
    Duration? connectTimeout,
  }) =>
      FbConnectionSettings(
        host: host ?? this.host,
        port: port ?? this.port,
        database: database ?? this.database,
        user: user ?? this.user,
        password: password ?? this.password,
        role: role ?? this.role,
        charset: charset ?? this.charset,
        noneEncoding: noneEncoding ?? this.noneEncoding,
        dialect: dialect,
        connectTimeout: connectTimeout ?? this.connectTimeout,
        applicationName: applicationName ?? this.applicationName,
        fetchSize: fetchSize ?? this.fetchSize,
        statementCacheSize: statementCacheSize ?? this.statementCacheSize,
        autoCommitOptions: autoCommitOptions ?? this.autoCommitOptions,
        readOnlyAutoCommitSelects:
            readOnlyAutoCommitSelects ?? this.readOnlyAutoCommitSelects,
        blobMode: blobMode ?? this.blobMode,
        numericMode: numericMode ?? this.numericMode,
        commandTimeout: commandTimeout ?? this.commandTimeout,
        authPlugins: authPlugins ?? this.authPlugins,
        wireCrypt: wireCrypt ?? this.wireCrypt,
        trimChar: trimChar ?? this.trimChar,
      );
}

/// Opaque identifier of a BLOB, returned when [FbBlobMode.id] is used.
class FbBlobId {
  final List<int> bytes;
  const FbBlobId(this.bytes);

  @override
  bool operator ==(Object other) {
    if (other is! FbBlobId || other.bytes.length != bytes.length) return false;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != other.bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() =>
      'FbBlobId(${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()})';
}
