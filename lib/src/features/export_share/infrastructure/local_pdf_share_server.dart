import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

typedef LanAddressResolver = Future<InternetAddress> Function();
typedef ShareTokenGenerator = String Function();

enum LocalPdfShareStopReason {
  requested,
  replaced,
  expired,
  serverError,
  closed,
}

enum LocalPdfShareEventKind { started, downloaded, stopped }

final class LocalPdfShareEvent {
  const LocalPdfShareEvent({
    required this.kind,
    required this.session,
    this.stopReason,
    this.error,
    this.stackTrace,
  });

  final LocalPdfShareEventKind kind;
  final LocalPdfShareSession session;
  final LocalPdfShareStopReason? stopReason;
  final Object? error;
  final StackTrace? stackTrace;
}

final class LocalPdfShareSession {
  const LocalPdfShareSession({
    required this.url,
    required this.fileName,
    required this.fileLength,
    required this.startedAt,
    required this.downloadCount,
  });

  final Uri url;
  final String fileName;
  final int fileLength;
  final DateTime startedAt;
  final int downloadCount;

  LocalPdfShareSession copyWith({int? downloadCount}) => LocalPdfShareSession(
    url: url,
    fileName: fileName,
    fileLength: fileLength,
    startedAt: startedAt,
    downloadCount: downloadCount ?? this.downloadCount,
  );
}

final class ShareNetworkUnavailableException implements Exception {
  const ShareNetworkUnavailableException();

  @override
  String toString() => 'No usable local IPv4 network address was found.';
}

/// A repeatable source for one file served by the local download server.
///
/// [SharedPdfSource] remains the convenient PDF-specialized API. ZIP bundles
/// and future offline exports use this interface without duplicating the
/// hardened token, timeout and request handling used for PDF sharing.
abstract interface class SharedDownloadSource {
  String get fileName;
  ContentType get contentType;
  Future<int> get length;
  Stream<List<int>> openRead();

  factory SharedDownloadSource.file(
    File file, {
    String? fileName,
    ContentType? contentType,
  }) = _FileDownloadSource;

  factory SharedDownloadSource.bytes(
    Uint8List bytes, {
    required String fileName,
    ContentType? contentType,
  }) = _MemoryDownloadSource;
}

/// A repeatable PDF source retained for backwards compatibility.
abstract interface class SharedPdfSource implements SharedDownloadSource {
  factory SharedPdfSource.file(File file, {String? fileName}) = _FilePdfSource;

  factory SharedPdfSource.bytes(Uint8List bytes, {required String fileName}) =
      _MemoryPdfSource;
}

final class _FilePdfSource implements SharedPdfSource {
  _FilePdfSource(this.file, {String? fileName})
    : fileName = _safePdfFileName(fileName ?? _basename(file.path));

  final File file;

  @override
  final String fileName;

  @override
  ContentType get contentType => ContentType('application', 'pdf');

  @override
  Future<int> get length async {
    if (!await file.exists()) {
      throw FileSystemException(
        'The PDF to share no longer exists.',
        file.path,
      );
    }
    return file.length();
  }

  @override
  Stream<List<int>> openRead() => file.openRead();
}

final class _MemoryPdfSource implements SharedPdfSource {
  _MemoryPdfSource(Uint8List bytes, {required String fileName})
    : _bytes = Uint8List.fromList(bytes),
      fileName = _safePdfFileName(fileName);

  final Uint8List _bytes;

  @override
  final String fileName;

  @override
  ContentType get contentType => ContentType('application', 'pdf');

  @override
  Future<int> get length async => _bytes.length;

  @override
  Stream<List<int>> openRead() => Stream<List<int>>.value(_bytes);
}

final class _FileDownloadSource implements SharedDownloadSource {
  _FileDownloadSource(this.file, {String? fileName, ContentType? contentType})
    : fileName = _safeDownloadFileName(fileName ?? _basename(file.path)),
      contentType = contentType ?? ContentType.binary;

  final File file;

  @override
  final String fileName;

  @override
  final ContentType contentType;

  @override
  Future<int> get length async {
    if (!await file.exists()) {
      throw FileSystemException(
        'The file to share no longer exists.',
        file.path,
      );
    }
    return file.length();
  }

  @override
  Stream<List<int>> openRead() => file.openRead();
}

final class _MemoryDownloadSource implements SharedDownloadSource {
  _MemoryDownloadSource(
    Uint8List bytes, {
    required String fileName,
    ContentType? contentType,
  }) : _bytes = Uint8List.fromList(bytes),
       fileName = _safeDownloadFileName(fileName),
       contentType = contentType ?? ContentType.binary;

  final Uint8List _bytes;

  @override
  final String fileName;

  @override
  final ContentType contentType;

  @override
  Future<int> get length async => _bytes.length;

  @override
  Stream<List<int>> openRead() => Stream<List<int>>.value(_bytes);
}

/// Serves exactly one download at a cryptographically random URL on the LAN.
///
/// Only GET and HEAD are accepted. The server has no directory listing and
/// automatically stops after [idleTimeout] without an authorized request.
final class LocalPdfShareServer {
  LocalPdfShareServer({
    this.idleTimeout = const Duration(minutes: 15),
    LanAddressResolver? addressResolver,
    ShareTokenGenerator? tokenGenerator,
    InternetAddress? bindAddress,
  }) : _addressResolver = addressResolver ?? findPreferredLanAddress,
       _tokenGenerator = tokenGenerator ?? _secureToken,
       _bindAddress = bindAddress ?? InternetAddress.anyIPv4 {
    if (idleTimeout <= Duration.zero) {
      throw ArgumentError.value(idleTimeout, 'idleTimeout', 'must be positive');
    }
  }

  final Duration idleTimeout;
  final LanAddressResolver _addressResolver;
  final ShareTokenGenerator _tokenGenerator;
  final InternetAddress _bindAddress;
  final StreamController<LocalPdfShareEvent> _events =
      StreamController<LocalPdfShareEvent>.broadcast(sync: true);

  HttpServer? _server;
  SharedDownloadSource? _source;
  LocalPdfShareSession? _session;
  Timer? _idleTimer;
  bool _closed = false;
  int _operation = 0;
  int _activeTransfers = 0;

  Stream<LocalPdfShareEvent> get events => _events.stream;
  LocalPdfShareSession? get session => _session;
  bool get isRunning => _server != null;

  Future<LocalPdfShareSession> start(SharedDownloadSource source) async {
    if (_closed) {
      throw StateError('The share server has already been closed.');
    }
    final operation = ++_operation;
    await _stopCurrent(reason: LocalPdfShareStopReason.replaced);

    final fileLength = await source.length;
    if (fileLength <= 0) {
      throw StateError('Cannot share an empty file.');
    }
    final advertisedAddress = await _addressResolver();
    if (operation != _operation || _closed) {
      throw StateError('The share operation was replaced.');
    }
    final server = await HttpServer.bind(_bindAddress, 0, shared: false);
    if (operation != _operation || _closed) {
      await server.close(force: true);
      throw StateError('The share operation was replaced.');
    }
    final token = _tokenGenerator();
    if (!RegExp(r'^[A-Za-z0-9_-]{20,}$').hasMatch(token)) {
      await server.close(force: true);
      throw StateError(
        'The token generator returned an unsafe or too-short token.',
      );
    }

    final fileName = _safeDownloadFileName(source.fileName);
    final uri = Uri(
      scheme: 'http',
      host: advertisedAddress.address,
      port: server.port,
      pathSegments: <String>['download', token, fileName],
    );
    final currentSession = LocalPdfShareSession(
      url: uri,
      fileName: fileName,
      fileLength: fileLength,
      startedAt: DateTime.now(),
      downloadCount: 0,
    );
    _source = source;
    _session = currentSession;
    _server = server;
    _armIdleTimer();
    server.listen(
      (request) => _handleRequest(request, operation),
      onError: (Object error, StackTrace stackTrace) {
        if (_server != server || operation != _operation) return;
        final activeSession = _session;
        if (activeSession != null && !_events.isClosed) {
          _events.add(
            LocalPdfShareEvent(
              kind: LocalPdfShareEventKind.stopped,
              session: activeSession,
              stopReason: LocalPdfShareStopReason.serverError,
              error: error,
              stackTrace: stackTrace,
            ),
          );
        }
        unawaited(
          stop(reason: LocalPdfShareStopReason.serverError, emitEvent: false),
        );
      },
      cancelOnError: false,
    );
    _events.add(
      LocalPdfShareEvent(
        kind: LocalPdfShareEventKind.started,
        session: currentSession,
      ),
    );
    return currentSession;
  }

  Future<void> stop({
    LocalPdfShareStopReason reason = LocalPdfShareStopReason.requested,
    bool emitEvent = true,
  }) async {
    ++_operation;
    await _stopCurrent(reason: reason, emitEvent: emitEvent);
  }

  Future<void> _stopCurrent({
    required LocalPdfShareStopReason reason,
    bool emitEvent = true,
  }) async {
    _idleTimer?.cancel();
    _idleTimer = null;
    final server = _server;
    final stoppedSession = _session;
    _server = null;
    _session = null;
    _source = null;
    if (server != null) {
      await server.close(force: true);
    }
    if (emitEvent && stoppedSession != null && !_events.isClosed) {
      _events.add(
        LocalPdfShareEvent(
          kind: LocalPdfShareEventKind.stopped,
          session: stoppedSession,
          stopReason: reason,
        ),
      );
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    ++_operation;
    await _stopCurrent(reason: LocalPdfShareStopReason.closed);
    await _events.close();
  }

  Future<void> _handleRequest(HttpRequest request, int operation) async {
    if (operation != _operation) {
      await _closeWithStatus(request.response, HttpStatus.serviceUnavailable);
      return;
    }
    final source = _source;
    final activeSession = _session;
    if (source == null || activeSession == null) {
      await _closeWithStatus(request.response, HttpStatus.serviceUnavailable);
      return;
    }

    final segments = request.uri.pathSegments;
    final expectedSegments = activeSession.url.pathSegments;
    final authorized =
        segments.length == 3 &&
        expectedSegments.length == 3 &&
        _constantTimeEquals(segments[1], expectedSegments[1]) &&
        segments[0] == 'download' &&
        segments[2] == activeSession.fileName;
    if (!authorized) {
      await _closeWithStatus(request.response, HttpStatus.notFound);
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await _closeWithStatus(request.response, HttpStatus.methodNotAllowed);
      return;
    }

    _armIdleTimer();
    final response = request.response;
    late final int currentLength;
    try {
      currentLength = await source.length;
    } on FileSystemException {
      await _closeWithStatus(response, HttpStatus.gone);
      return;
    }
    try {
      response.statusCode = HttpStatus.ok;
      response.headers
        ..contentType = source.contentType
        ..contentLength = currentLength
        ..set(HttpHeaders.cacheControlHeader, 'no-store, private')
        ..set('X-Content-Type-Options', 'nosniff')
        ..set(
          'Content-Disposition',
          _contentDisposition(activeSession.fileName),
        );
      if (request.method == 'GET') {
        _activeTransfers++;
        try {
          await response.addStream(source.openRead());
        } finally {
          _activeTransfers = max(0, _activeTransfers - 1);
          _armIdleTimer();
        }
      }
      await response.close();
      final latest = _session;
      if (latest != null && request.method == 'GET') {
        final updated = latest.copyWith(
          downloadCount: latest.downloadCount + 1,
        );
        _session = updated;
        if (!_events.isClosed) {
          _events.add(
            LocalPdfShareEvent(
              kind: LocalPdfShareEventKind.downloaded,
              session: updated,
            ),
          );
        }
      }
    } on SocketException {
      await response.close().catchError((_) {});
    } catch (_) {
      await response.close().catchError((_) {});
    }
  }

  void _armIdleTimer() {
    _idleTimer?.cancel();
    final operation = _operation;
    _idleTimer = Timer(idleTimeout, () {
      if (operation == _operation) {
        if (_activeTransfers > 0) {
          _armIdleTimer();
        } else {
          unawaited(stop(reason: LocalPdfShareStopReason.expired));
        }
      }
    });
  }
}

Future<InternetAddress> findPreferredLanAddress() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    includeLinkLocal: false,
    type: InternetAddressType.IPv4,
  );
  final addresses = <({InternetAddress address, String interfaceName})>[];
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      final value = address.address;
      if (address.type == InternetAddressType.IPv4 &&
          !address.isLoopback &&
          !value.startsWith('169.254.')) {
        addresses.add((address: address, interfaceName: interface.name));
      }
    }
  }
  if (addresses.isEmpty) {
    throw const ShareNetworkUnavailableException();
  }
  addresses.sort(
    (a, b) => _addressScore(
      b.address.address,
      b.interfaceName,
    ).compareTo(_addressScore(a.address.address, a.interfaceName)),
  );
  return addresses.first.address;
}

int _addressScore(String address, String interfaceName) {
  var score = 0;
  if (address.startsWith('192.168.')) score += 4;
  if (address.startsWith('10.')) score += 3;
  if (address.startsWith('172.')) {
    final second = int.tryParse(address.split('.')[1]) ?? 0;
    if (second >= 16 && second <= 31) score += 3;
  }
  final name = interfaceName.toLowerCase();
  if (name.contains('wlan') ||
      name.contains('wifi') ||
      name.startsWith('eth') ||
      name.startsWith('en')) {
    score += 8;
  }
  if (name.contains('tun') ||
      name.contains('vpn') ||
      name.contains('rmnet') ||
      name.contains('cell')) {
    score -= 12;
  }
  return score;
}

Future<void> _closeWithStatus(HttpResponse response, int status) async {
  response.statusCode = status;
  response.headers
    ..contentType = ContentType.text
    ..set(HttpHeaders.cacheControlHeader, 'no-store');
  await response.close();
}

String _contentDisposition(String fileName) {
  final asciiName = fileName
      .replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_')
      .replaceAll('"', '_')
      .replaceAll(RegExp(r'[\r\n]'), '_');
  return 'attachment; filename="$asciiName"; filename*=UTF-8\'\'${Uri.encodeComponent(fileName)}';
}

String _safePdfFileName(String value) {
  var result = value
      .replaceAll(RegExp(r'[\\/]'), '_')
      .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
      .trim();
  if (result.isEmpty) result = 'Flowboard.pdf';
  if (result.length > 120) result = result.substring(0, 120).trim();
  if (!result.toLowerCase().endsWith('.pdf')) result = '$result.pdf';
  return result;
}

String _safeDownloadFileName(String value) {
  var result = value
      .replaceAll(RegExp(r'[\\/]'), '_')
      .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
      .trim();
  if (result.isEmpty) result = 'Flowboard-Download';
  if (result.length > 120) result = result.substring(0, 120).trim();
  return result;
}

String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

bool _constantTimeEquals(String left, String right) {
  final leftBytes = utf8.encode(left);
  final rightBytes = utf8.encode(right);
  var difference = leftBytes.length ^ rightBytes.length;
  final length = max(leftBytes.length, rightBytes.length);
  for (var index = 0; index < length; index++) {
    final leftByte = index < leftBytes.length ? leftBytes[index] : 0;
    final rightByte = index < rightBytes.length ? rightBytes[index] : 0;
    difference |= leftByte ^ rightByte;
  }
  return difference == 0;
}

String _secureToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(
    24,
    (_) => random.nextInt(256),
    growable: false,
  );
  return base64UrlEncode(bytes).replaceAll('=', '');
}
