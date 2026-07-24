import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'src/app/app.dart';
import 'src/app/app_theme.dart';
import 'src/data/file_document_repository.dart';
import 'src/diagnostics/diagnostics.dart';
import 'src/platform/android_widget_bridge.dart';

DiagnosticLifecycleObserver? _diagnosticLifecycleObserver;

void main() {
  final diagnostics = DiagnosticLogService.instance;
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      _installGlobalErrorHandlers(diagnostics);
      _diagnosticLifecycleObserver = DiagnosticLifecycleObserver(diagnostics);
      WidgetsBinding.instance.addObserver(_diagnosticLifecycleObserver!);
      _installErrorWidget();
      await _bootstrapApplication(diagnostics);
    },
    (error, stack) {
      diagnostics.recordException(
        event: 'zone.unhandled',
        error: error,
        stackTrace: stack,
        fatal: true,
      );
    },
  );
}

void _installGlobalErrorHandlers(DiagnosticLogService diagnostics) {
  final previousFlutterHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    diagnostics.recordFlutterError(details);
    if (previousFlutterHandler != null) {
      previousFlutterHandler(details);
    } else {
      FlutterError.presentError(details);
    }
  };
  final previousPlatformHandler = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    diagnostics.recordException(
      event: 'platform.unhandled',
      error: error,
      stackTrace: stack,
      fatal: true,
    );
    return previousPlatformHandler?.call(error, stack) ?? true;
  };
}

void _installErrorWidget() {
  ErrorWidget.builder = (details) => const Material(
    color: FlowboardColors.background,
    child: Center(
      child: SizedBox(
        width: 520,
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 56,
                color: FlowboardColors.warning,
              ),
              SizedBox(height: 18),
              Text(
                'Dieser Bereich konnte nicht dargestellt werden. Das Dokument bleibt durch Auto-Save geschützt.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: FlowboardColors.textPrimary,
                  fontSize: 18,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _bootstrapApplication(DiagnosticLogService diagnostics) async {
  try {
    final support = await getApplicationSupportDirectory();
    final storage = Directory(p.join(support.path, 'FlowboardX'));
    await storage.create(recursive: true);
    await diagnostics.initialize(
      directory: Directory(p.join(storage.path, 'diagnostics')),
      metadata: await DiagnosticSessionMetadata.resolve(),
    );
    diagnostics.info('bootstrap.started');
    try {
      await pdfrxFlutterInitialize(dismissPdfiumWasmWarnings: true);
    } catch (error, stack) {
      // PDF support is important but must not prevent recovery and ordinary
      // whiteboard work when a platform PDFium module is damaged.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'pdfrx initialization',
        ),
      );
    }
    try {
      await AndroidWidgetBridge.instance.initialize();
    } catch (error, stack) {
      // The home-screen widget is best-effort. A damaged launcher/plugin must
      // never prevent the whiteboard and its recovery files from opening.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Flowboard Android widget bridge',
        ),
      );
    }
    diagnostics.info('bootstrap.ready');
    runApp(FlowboardApp(repository: FileDocumentRepository(storage)));
  } catch (error, stack) {
    diagnostics.recordException(
      event: 'bootstrap.failed',
      error: error,
      stackTrace: stack,
      fatal: true,
    );
    runApp(
      _StartupFailureApp(
        error: error.toString(),
        onRetry: () => _bootstrapApplication(diagnostics),
      ),
    );
  }
}

class _StartupFailureApp extends StatefulWidget {
  const _StartupFailureApp({required this.error, required this.onRetry});

  final String error;
  final Future<void> Function() onRetry;

  @override
  State<_StartupFailureApp> createState() => _StartupFailureAppState();
}

class _StartupFailureAppState extends State<_StartupFailureApp> {
  bool _retrying = false;

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Flowboard X',
    debugShowCheckedModeBanner: false,
    theme: buildFlowboardTheme(),
    home: Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.storage_rounded,
                        size: 56,
                        color: FlowboardColors.warning,
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'Lokaler Speicher nicht verfügbar',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Flowboard hat kein Dokument geöffnet oder verändert. '
                        'Prüfe den freien Speicher und versuche es erneut.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        widget.error,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: FlowboardColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 22),
                      FilledButton.icon(
                        onPressed: _retrying ? null : _retry,
                        icon: _retrying
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded),
                        label: const Text('Erneut versuchen'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
