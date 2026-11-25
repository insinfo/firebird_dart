import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../auth/srp.dart';
import '../auth/unix_crypt.dart';
import '../charset.dart';
import '../crypto/hash.dart';
import '../exceptions.dart';
import '../settings.dart';
import 'constants.dart';
import 'xdr.dart';

/// Generic `op_response` packet.
class FbResponse {
  final int handle;
  final Uint8List blobId;
  final Uint8List data;
  final FbException? error;
  final List<FbStatusEntry> warnings;

  FbResponse(this.handle, this.blobId, this.data, this.error, this.warnings);

  /// Throws the server error carried by this response, if any.
  FbResponse check() {
    final e = error;
    if (e != null) throw e;
    return this;
  }
}

/// Transport level of a Firebird attachment: socket, protocol negotiation,
/// authentication and packet framing. Not safe for concurrent use; the
/// connection serialises access.
class FbWire {
  final FbConnectionSettings settings;
  Socket? _socket;
  StreamSubscription<Uint8List>? _subscription;
  final InputBuffer input = InputBuffer();

  /// Negotiated protocol version without the Firebird flag (10..13).
  int protocolVersion = 0;
  int acceptType = 0;
  int dbHandle = 0;
  String? authPlugin;
  bool wireEncrypted = false;

  Arc4? _encrypt;
  Arc4? _decrypt;

  /// Packets already sent whose `op_response` has not been read yet.
  int _deferred = 0;
  bool _closed = false;

  late final FbCharset charset = settings.fbCharset;

  /// Codec of the connection character set (SQL text, parameters, text
  /// columns transliterated by the server).
  late final Encoding textCodec = charset.encoding ??
      settings.noneEncoding ??
      const Utf8Codec(allowMalformed: true);

  /// Codec for `CHARACTER SET NONE` columns.
  late final Encoding noneCodec = settings.noneEncoding ??
      charset.encoding ??
      const Utf8Codec(allowMalformed: true);

  /// Codec for metadata (names, messages). Firebird stores metadata as
  /// UNICODE_FSS; with lc_ctype NONE it arrives untransliterated.
  late final Encoding metaCodec =
      (charset == FbCharset.none || charset == FbCharset.octets)
          ? const Utf8Codec(allowMalformed: true)
          : textCodec;

  FbWire(this.settings);

  bool get isClosed => _closed;
  bool get isProtocol13 => protocolVersion >= 13;

  // -------------------------------------------------------------------------
  // Socket.
  // -------------------------------------------------------------------------

  /// Opens the socket, authenticates and attaches to (or, with [create],
  /// creates) the database.
  Future<void> open({bool create = false, int? pageSize}) async {
    try {
      _socket = await Socket.connect(settings.host, settings.port,
          timeout: settings.connectTimeout);
    } on SocketException catch (e) {
      throw FbConnectionException(
          'Unable to connect to ${settings.host}:${settings.port}',
          cause: e);
    }
    _socket!.setOption(SocketOption.tcpNoDelay, true);
    _subscription = _socket!.listen(
      (data) {
        final d = _decrypt;
        input.add(d == null ? data : d.process(data));
      },
      onError: (Object e, StackTrace st) {
        _closed = true;
        input.close(
            FbConnectionException('Connection to the server failed', cause: e),
            st);
      },
      onDone: () {
        _closed = true;
        input.close(FbConnectionException('Connection closed by the server'));
      },
      cancelOnError: true,
    );
    try {
      await _connectAndAuthenticate().timeout(settings.connectTimeout);
      await _attach(create: create, pageSize: pageSize);
    } catch (_) {
      await destroy();
      rethrow;
    }
  }

  void send(Uint8List data) {
    if (_closed) throw FbConnectionException('Connection is closed');
    final e = _encrypt;
    _socket!.add(e == null ? data : e.process(data));
  }

  /// Sends a packet whose `op_response` will be read (and its error
  /// ignored) before the next response.
  void sendDeferred(Uint8List data) {
    send(data);
    _deferred++;
  }

  /// Number of deferred responses still pending.
  int get deferredCount => _deferred;

  Future<void> destroy() async {
    _closed = true;
    try {
      await _subscription?.cancel();
    } catch (_) {}
    try {
      _socket?.destroy();
    } catch (_) {}
    input.close(FbConnectionException('Connection is closed'));
  }

  /// Detaches from the database and closes the socket.
  Future<void> detach() async {
    if (_closed) return;
    try {
      final w = XdrWriter(16)
        ..int32(op_detach)
        ..int32(dbHandle);
      send(w.takeBytes());
      await readResponse();
      send((XdrWriter(8)..int32(op_disconnect)).takeBytes());
      await _socket?.flush();
    } finally {
      await destroy();
    }
  }

  // -------------------------------------------------------------------------
  // Reading.
  // -------------------------------------------------------------------------

  /// Reads the next operation code, skipping keep-alive packets.
  Future<int> readOp() async {
    while (true) {
      final op = await input.int32();
      if (op != op_dummy) return op;
    }
  }

  /// Reads and discards the responses of deferred packets.
  Future<void> drainDeferred() async {
    while (_deferred > 0) {
      _deferred--;
      final op = await readOp();
      if (op != op_response) {
        throw FbConnectionException(
            'Protocol error: expected deferred op_response, got op $op');
      }
      await readResponseBody();
    }
  }

  /// Reads an `op_response`, after any deferred responses. Server errors
  /// are thrown.
  Future<FbResponse> readResponse() async {
    await drainDeferred();
    final op = await readOp();
    if (op != op_response) {
      throw FbConnectionException(
          'Protocol error: expected op_response, got op $op');
    }
    return (await readResponseBody()).check();
  }

  /// Like [readResponse] but returns the error instead of throwing it.
  Future<FbResponse> readResponseUnchecked() async {
    await drainDeferred();
    final op = await readOp();
    if (op != op_response) {
      throw FbConnectionException(
          'Protocol error: expected op_response, got op $op');
    }
    return readResponseBody();
  }

  /// Body of `op_response` (after the opcode).
  Future<FbResponse> readResponseBody() async {
    final f = input.need(12);
    if (f != null) await f;
    final handle = input.readInt32();
    final blobId = input.readBytes(8);
    final data = await input.xdrBuffer();
    final status = await readStatusVector();
    return FbResponse(handle, blobId, data, status.error, status.warnings);
  }

  Future<({FbException? error, List<FbStatusEntry> warnings})>
      readStatusVector() async {
    final entries = <FbStatusEntry>[];
    String? sqlState;
    int? code;
    var args = <Object>[];
    var warning = false;
    void flush() {
      if (code != null && code != 0) {
        entries.add(FbStatusEntry(code!, args, isWarning: warning));
      }
      code = null;
      args = <Object>[];
      warning = false;
    }

    while (true) {
      final arg = await input.int32();
      if (arg == isc_arg_end) break;
      switch (arg) {
        case isc_arg_gds:
          flush();
          code = await input.int32();
        case isc_arg_warning:
          flush();
          code = await input.int32();
          warning = true;
        case isc_arg_string:
        case isc_arg_interpreted:
        case isc_arg_cstring:
          args.add(metaCodec.decode(await input.xdrBuffer()));
        case isc_arg_sql_state:
          sqlState = ascii.decode(await input.xdrBuffer(), allowInvalid: true);
        case isc_arg_number:
          args.add(await input.int32());
        default:
          // Operating-system specific codes (isc_arg_win32, isc_arg_unix...).
          args.add(await input.int32());
      }
    }
    flush();
    final errors = entries.where((e) => !e.isWarning).toList();
    return (
      error: errors.isEmpty
          ? null
          : FbException.fromStatus(entries, sqlState: sqlState),
      warnings: entries.where((e) => e.isWarning).toList(),
    );
  }

  // -------------------------------------------------------------------------
  // Connection negotiation and authentication.
  // -------------------------------------------------------------------------

  late final SrpClient _srp = SrpClient();

  String get _normalizedUser {
    final u = settings.user;
    if (u.length > 2 && u.startsWith('"') && u.endsWith('"')) {
      return u.substring(1, u.length - 1).replaceAll('""', '"');
    }
    return u.toUpperCase();
  }

  String _pluginName(FbAuthPlugin p) => switch (p) {
        FbAuthPlugin.srp256 => 'Srp256',
        FbAuthPlugin.srp => 'Srp',
        FbAuthPlugin.legacyAuth => 'Legacy_Auth',
      };

  Uint8List _userIdentification() {
    final b = BytesBuilder();
    void param(int tag, List<int> value) {
      if (tag == CNCT_specific_data) {
        // Split into 254-byte chunks, each prefixed by a sequence number.
        var i = 0;
        var rest = value;
        while (rest.length > 254) {
          b
            ..addByte(tag)
            ..addByte(255)
            ..addByte(i++)
            ..add(rest.sublist(0, 254));
          rest = rest.sublist(254);
        }
        b
          ..addByte(tag)
          ..addByte(rest.length + 1)
          ..addByte(i)
          ..add(rest);
        return;
      }
      b
        ..addByte(tag)
        ..addByte(value.length)
        ..add(value);
    }

    final plugins = settings.authPlugins;
    final first = plugins.isEmpty ? FbAuthPlugin.legacyAuth : plugins.first;
    param(CNCT_login, utf8.encode(settings.user));
    param(CNCT_plugin_name, ascii.encode(_pluginName(first)));
    param(CNCT_plugin_list, ascii.encode(plugins.map(_pluginName).join(',')));
    if (first == FbAuthPlugin.legacyAuth) {
      param(CNCT_specific_data,
          ascii.encode(firebirdLegacyPasswordHash(settings.password)));
    } else {
      param(CNCT_specific_data, ascii.encode(_srp.publicKeyHex));
    }
    final crypt = switch (settings.wireCrypt) {
      FbWireCrypt.disabled => 0,
      FbWireCrypt.enabled => 1,
      FbWireCrypt.required => 2,
    };
    param(CNCT_client_crypt,
        (ByteData(4)..setInt32(0, crypt, Endian.little)).buffer.asUint8List());
    param(CNCT_user, utf8.encode(_osUser()));
    param(CNCT_host, utf8.encode(_hostName()));
    param(CNCT_user_verification, const []);
    return b.toBytes();
  }

  static String _osUser() =>
      Platform.environment['USERNAME'] ??
      Platform.environment['USER'] ??
      'firebird_dart';

  static String _hostName() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return 'localhost';
    }
  }

  Future<void> _connectAndAuthenticate() async {
    final w = XdrWriter(512)
      ..int32(op_connect)
      ..int32(op_attach)
      ..int32(CONNECT_VERSION3)
      ..int32(arch_generic)
      ..buffer(utf8.encode(settings.database));
    final protocols = <(int, int)>[
      (PROTOCOL_VERSION10, 2),
      (PROTOCOL_VERSION11, 4),
      (PROTOCOL_VERSION12, 6),
      (PROTOCOL_VERSION13, 8),
    ];
    w
      ..int32(protocols.length)
      ..buffer(_userIdentification());
    for (final (version, weight) in protocols) {
      w
        ..int32(version)
        ..int32(arch_generic)
        ..int32(0)
        ..int32(ptype_lazy_send)
        ..int32(weight);
    }
    send(w.takeBytes());

    final op = await readOp();
    if (op == op_reject) {
      throw FbConnectionException('Connection rejected by the server');
    }
    if (op == op_response) {
      (await readResponseBody()).check();
      throw FbConnectionException('Unexpected response to op_connect');
    }
    if (op != op_accept && op != op_cond_accept && op != op_accept_data) {
      throw FbConnectionException('Protocol error: unexpected op $op');
    }
    final f = input.need(12);
    if (f != null) await f;
    protocolVersion = input.readInt32() & FB_PROTOCOL_MASK;
    input.readInt32(); // architecture
    acceptType = input.readInt32() & ptype_MASK;

    if (op == op_accept) {
      // Firebird 2.x (or a 3+ server without plugin data): legacy login in
      // the attach DPB.
      authPlugin = 'Legacy_Auth';
      return;
    }

    var data = await input.xdrBuffer();
    final plugin = ascii.decode(await input.xdrBuffer());
    final isAuthenticated = await input.int32();
    await input.xdrBuffer(); // keys
    authPlugin = plugin;

    Uint8List authData = Uint8List(0);
    Uint8List? sessionKey;
    if (isAuthenticated == 0) {
      if (plugin == 'Srp' || plugin == 'Srp256') {
        if (data.isEmpty) {
          _sendContAuth(utf8.encode(_srp.publicKeyHex), plugin);
          final op2 = await readOp();
          if (op2 == op_response) {
            (await readResponseBody()).check();
          }
          if (op2 != op_cont_auth) {
            throw FbConnectionException(
                'Protocol error: expected op_cont_auth');
          }
          data = await input.xdrBuffer();
          await input.xdrBuffer(); // plugin name
          await input.xdrBuffer(); // plugin list
          await input.xdrBuffer(); // keys
        }
        final saltLen = data[0] | (data[1] << 8);
        final salt = data.sublist(2, 2 + saltLen);
        final keyLen = data[2 + saltLen] | (data[3 + saltLen] << 8);
        final keyHex =
            ascii.decode(data.sublist(4 + saltLen, 4 + saltLen + keyLen));
        final proof = _srp.clientProof(
          user: _normalizedUser,
          password: settings.password,
          salt: salt,
          serverPublicKey: bytesToBigInt(hexToBytes(keyHex)),
          sha256Proof: plugin == 'Srp256',
        );
        authData = proof.proof;
        sessionKey = proof.sessionKey;
      } else if (plugin == 'Legacy_Auth') {
        authData = ascii.encode(firebirdLegacyPasswordHash(settings.password));
      } else {
        throw FbConnectionException(
            'Unsupported authentication plugin $plugin');
      }
    }

    if (op == op_cond_accept) {
      _sendContAuth(
          plugin == 'Legacy_Auth'
              ? authData
              : utf8.encode(bytesToHex(authData)),
          plugin);
      await readResponse();
      _pendingAuthData = null;
    } else {
      _pendingAuthData = authData.isEmpty ? null : authData;
    }

    if (sessionKey != null && settings.wireCrypt != FbWireCrypt.disabled) {
      final w2 = XdrWriter(64)
        ..int32(op_crypt)
        ..buffer(ascii.encode('Arc4'))
        ..buffer(ascii.encode('Symmetric'));
      send(w2.takeBytes());
      _encrypt = Arc4(sessionKey);
      _decrypt = Arc4(sessionKey);
      wireEncrypted = true;
      await readResponse();
    } else if (settings.wireCrypt == FbWireCrypt.required) {
      throw FbConnectionException(
          'Wire encryption is required but was not negotiated');
    }
  }

  Uint8List? _pendingAuthData;

  void _sendContAuth(List<int> data, String plugin) {
    final w = XdrWriter(256)
      ..int32(op_cont_auth)
      ..buffer(data)
      ..buffer(ascii.encode(plugin))
      ..buffer(ascii.encode(settings.authPlugins.map(_pluginName).join(',')))
      ..buffer(const []);
    send(w.takeBytes());
  }

  Future<void> _attach({bool create = false, int? pageSize}) async {
    final dpb = ParamBlockBuilder(isc_dpb_version1);
    dpb.bytes(isc_dpb_lc_ctype, ascii.encode(charset.name));
    dpb.bytes(isc_dpb_user_name, utf8.encode(settings.user));
    if (!isProtocol13 ||
        (authPlugin == 'Legacy_Auth' && _pendingAuthData == null)) {
      if (protocolVersion == PROTOCOL_VERSION10) {
        dpb.bytes(isc_dpb_password, utf8.encode(settings.password));
      } else {
        dpb.bytes(isc_dpb_password_enc,
            ascii.encode(firebirdLegacyPasswordHash(settings.password)));
      }
    }
    final authData = _pendingAuthData;
    if (authData != null) {
      dpb.bytes(isc_dpb_specific_auth_data, ascii.encode(bytesToHex(authData)));
    }
    if (settings.role != null) {
      dpb.bytes(isc_dpb_sql_role_name, utf8.encode(settings.role!));
    }
    dpb.int32(isc_dpb_sql_dialect, settings.dialect);
    dpb.int32(isc_dpb_process_id, pid);
    dpb.bytes(isc_dpb_process_name, utf8.encode(settings.applicationName));
    dpb.tag(isc_dpb_utf8_filename);
    dpb.byte(0);
    if (create) {
      dpb.int32(isc_dpb_page_size, pageSize ?? 8192);
      dpb.bytes(isc_dpb_set_db_charset, ascii.encode(charset.name));
    }

    final w = XdrWriter(256)
      ..int32(create ? op_create : op_attach)
      ..int32(0)
      ..buffer(utf8.encode(settings.database))
      ..buffer(dpb.build());
    send(w.takeBytes());
    final r = await readResponse();
    dbHandle = r.handle;
  }

  /// Drops the attached database and closes the socket.
  Future<void> dropDatabase() async {
    try {
      await simpleRequest(op_drop_database, dbHandle);
    } finally {
      await destroy();
    }
  }

  // -------------------------------------------------------------------------
  // Generic requests.
  // -------------------------------------------------------------------------

  /// Sends `op` with a single handle argument and reads the response.
  Future<FbResponse> simpleRequest(int op, int handle) {
    final w = XdrWriter(16)
      ..int32(op)
      ..int32(handle);
    send(w.takeBytes());
    return readResponse();
  }

  Future<Uint8List> infoDatabase(List<int> items,
      [int bufferLength = 1024]) async {
    final w = XdrWriter(64)
      ..int32(op_info_database)
      ..int32(dbHandle)
      ..int32(0)
      ..buffer(items)
      ..int32(bufferLength);
    send(w.takeBytes());
    return (await readResponse()).data;
  }

  /// Requests a cancellation of the operation running on this attachment
  /// (protocol 12+). Sent out of band: it does not produce a response.
  void cancelOperation(int kind) {
    if (protocolVersion < 12) {
      throw FbUsageException('Cancellation requires Firebird 2.5 or later');
    }
    final w = XdrWriter(16)
      ..int32(op_cancel)
      ..int32(kind);
    send(w.takeBytes());
  }
}
