import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../domain/export_snapshot.dart';
import '../infrastructure/local_pdf_share_server.dart';
import 'pdf_exporter.dart';

enum PdfSharePhase { idle, exporting, startingServer, sharing, expired, failed }

@immutable
final class PdfShareState {
  const PdfShareState._({
    required this.phase,
    this.exportProgress,
    this.pdfFile,
    this.session,
    this.message,
    this.error,
    this.stackTrace,
  });

  const PdfShareState.idle() : this._(phase: PdfSharePhase.idle);

  const PdfShareState.exporting(PdfExportProgress progress)
    : this._(phase: PdfSharePhase.exporting, exportProgress: progress);

  const PdfShareState.startingServer(File pdfFile)
    : this._(phase: PdfSharePhase.startingServer, pdfFile: pdfFile);

  const PdfShareState.sharing(File pdfFile, LocalPdfShareSession session)
    : this._(phase: PdfSharePhase.sharing, pdfFile: pdfFile, session: session);

  const PdfShareState.expired(File? pdfFile)
    : this._(
        phase: PdfSharePhase.expired,
        pdfFile: pdfFile,
        message: 'Die lokale Freigabe ist abgelaufen.',
      );

  const PdfShareState.failed(
    Object error,
    StackTrace stackTrace, {
    String? message,
  }) : this._(
         phase: PdfSharePhase.failed,
         error: error,
         stackTrace: stackTrace,
         message: message,
       );

  final PdfSharePhase phase;
  final PdfExportProgress? exportProgress;
  final File? pdfFile;
  final LocalPdfShareSession? session;
  final String? message;
  final Object? error;
  final StackTrace? stackTrace;

  Uri? get shareUrl => session?.url;
  int get downloadCount => session?.downloadCount ?? 0;
  bool get isBusy =>
      phase == PdfSharePhase.exporting || phase == PdfSharePhase.startingServer;
}

/// Coordinates a crash-safe PDF export and its short-lived LAN share server.
final class PdfShareController extends ChangeNotifier {
  PdfShareController({PdfExporter? exporter, LocalPdfShareServer? server})
    : _exporter = exporter ?? const PdfExporter(),
      _server = server ?? LocalPdfShareServer(),
      _ownsServer = server == null {
    _serverSubscription = _server.events.listen(_onServerEvent);
  }

  final PdfExporter _exporter;
  final LocalPdfShareServer _server;
  final bool _ownsServer;
  late final StreamSubscription<LocalPdfShareEvent> _serverSubscription;
  PdfShareState _state = const PdfShareState.idle();
  int _operation = 0;
  bool _disposed = false;
  Future<void>? _shutdownFuture;

  PdfShareState get state => _state;

  /// Exports [document] and begins sharing the completed file.
  ///
  /// Returns false for a cancelled/replaced operation or a runtime failure. In
  /// the latter case [state] contains the original error and stack trace.
  Future<bool> exportAndShare(
    ExportDocumentSnapshot document,
    File destination, {
    bool overwrite = true,
  }) async {
    _ensureUsable();
    final operation = ++_operation;
    await _server.stop(reason: LocalPdfShareStopReason.replaced);
    if (!_isCurrent(operation)) return false;

    _setState(
      PdfShareState.exporting(
        PdfExportProgress(
          pageIndex: 0,
          pageCount: document.pages.length,
          stage: PdfExportStage.rasterizing,
        ),
      ),
    );
    try {
      final pdfFile = await _exporter.exportToFile(
        document,
        destination,
        overwrite: overwrite,
        isCancelled: () => !_isCurrent(operation),
        onProgress: (progress) {
          if (_isCurrent(operation)) {
            _setState(PdfShareState.exporting(progress));
          }
        },
      );
      if (!_isCurrent(operation)) return false;
      return _shareFileForOperation(pdfFile, operation);
    } on PdfExportCancelled {
      if (_isCurrent(operation)) _setState(const PdfShareState.idle());
      return false;
    } catch (error, stackTrace) {
      if (_isCurrent(operation)) {
        _setState(
          PdfShareState.failed(
            error,
            stackTrace,
            message: _friendlyMessage(error),
          ),
        );
      }
      return false;
    }
  }

  /// Shares an already exported PDF after checking its signature.
  Future<bool> shareExisting(File pdfFile) async {
    _ensureUsable();
    final operation = ++_operation;
    await _server.stop(reason: LocalPdfShareStopReason.replaced);
    try {
      await _verifyPdf(pdfFile);
      if (!_isCurrent(operation)) return false;
      return _shareFileForOperation(pdfFile, operation);
    } catch (error, stackTrace) {
      if (_isCurrent(operation)) {
        _setState(
          PdfShareState.failed(
            error,
            stackTrace,
            message: _friendlyMessage(error),
          ),
        );
      }
      return false;
    }
  }

  Future<void> stop() async {
    if (_disposed) return;
    ++_operation;
    await _server.stop(reason: LocalPdfShareStopReason.requested);
    if (!_disposed) _setState(const PdfShareState.idle());
  }

  Future<bool> _shareFileForOperation(File pdfFile, int operation) async {
    _setState(PdfShareState.startingServer(pdfFile));
    try {
      final session = await _server.start(SharedPdfSource.file(pdfFile));
      if (!_isCurrent(operation)) {
        if (_server.session?.url == session.url) {
          await _server.stop(reason: LocalPdfShareStopReason.replaced);
        }
        return false;
      }
      _setState(PdfShareState.sharing(pdfFile, session));
      return true;
    } catch (error, stackTrace) {
      if (_isCurrent(operation)) {
        _setState(
          PdfShareState.failed(
            error,
            stackTrace,
            message: _friendlyMessage(error),
          ),
        );
      }
      return false;
    }
  }

  void _onServerEvent(LocalPdfShareEvent event) {
    if (_disposed) return;
    switch (event.kind) {
      case LocalPdfShareEventKind.started:
        break;
      case LocalPdfShareEventKind.downloaded:
        final pdfFile = _state.pdfFile;
        if (pdfFile != null) {
          _setState(PdfShareState.sharing(pdfFile, event.session));
        }
        break;
      case LocalPdfShareEventKind.stopped:
        if (event.stopReason == LocalPdfShareStopReason.expired) {
          _setState(PdfShareState.expired(_state.pdfFile));
        } else if (event.stopReason == LocalPdfShareStopReason.serverError) {
          final error =
              event.error ?? StateError('The local share server stopped.');
          _setState(
            PdfShareState.failed(
              error,
              event.stackTrace ?? StackTrace.current,
              message: _friendlyMessage(error),
            ),
          );
        }
        break;
    }
  }

  bool _isCurrent(int operation) => !_disposed && operation == _operation;

  void _setState(PdfShareState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('PdfShareController has been disposed.');
  }

  static Future<void> _verifyPdf(File file) async {
    if (!await file.exists()) {
      throw FileSystemException('PDF file does not exist.', file.path);
    }
    final input = await file.open();
    try {
      final signature = await input.read(5);
      if (signature.length != 5 ||
          signature[0] != 0x25 ||
          signature[1] != 0x50 ||
          signature[2] != 0x44 ||
          signature[3] != 0x46 ||
          signature[4] != 0x2D) {
        throw const FormatException('The selected file is not a PDF.');
      }
    } finally {
      await input.close();
    }
  }

  static String _friendlyMessage(Object error) => switch (error) {
    ShareNetworkUnavailableException() =>
      'Kein lokales Netzwerk gefunden. Verbinde beide Geräte mit demselben WLAN.',
    SocketException() =>
      'Der lokale Download-Server konnte nicht gestartet werden.',
    FileSystemException() =>
      'Die PDF-Datei konnte nicht gelesen oder geschrieben werden.',
    _ => 'Die PDF-Freigabe konnte nicht gestartet werden.',
  };

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_operation;
    _shutdownFuture = Future.wait<void>([
      _serverSubscription.cancel(),
      if (_ownsServer)
        _server.close()
      else
        _server.stop(reason: LocalPdfShareStopReason.requested),
    ]);
    unawaited(_shutdownFuture);
    super.dispose();
  }

  /// Disposes the controller and waits until its socket and subscriptions are
  /// fully closed. Prefer this in service owners and tests.
  Future<void> close() {
    dispose();
    return _shutdownFuture ?? Future<void>.value();
  }
}
