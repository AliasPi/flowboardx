import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'src/app/app.dart';
import 'src/app/app_theme.dart';
import 'src/data/file_document_repository.dart';
import 'src/platform/android_widget_bridge.dart';

File? _crashLogFile;
Future<void> _crashWrite = Future<void>.value();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    developer.log(
      'Unbehandelter Flutter-Fehler',
      name: 'flowboard_x',
      error: details.exception,
      stackTrace: details.stack,
      level: 1000,
    );
    _appendCrashLog('Flutter', details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    developer.log(
      'Unbehandelter Isolate-Fehler',
      name: 'flowboard_x',
      error: error,
      stackTrace: stack,
      level: 1000,
    );
    _appendCrashLog('Isolate', error, stack);
    return true;
  };
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

  await _bootstrapApplication();
}

Future<void> _bootstrapApplication() async {
  try {
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
    final support = await getApplicationSupportDirectory();
    final storage = Directory(p.join(support.path, 'FlowboardX'));
    await storage.create(recursive: true);
    _crashLogFile = File(p.join(storage.path, 'flowboard_crash.log'));
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
    runApp(FlowboardApp(repository: FileDocumentRepository(storage)));
  } catch (error, stack) {
    developer.log(
      'Flowboard konnte den lokalen Speicher nicht initialisieren',
      name: 'flowboard_x',
      error: error,
      stackTrace: stack,
      level: 1000,
    );
    runApp(
      _StartupFailureApp(
        error: error.toString(),
        onRetry: _bootstrapApplication,
      ),
    );
  }
}

void _appendCrashLog(String source, Object error, StackTrace? stack) {
  final target = _crashLogFile;
  if (target == null) return;
  final entry = StringBuffer()
    ..writeln('--- ${DateTime.now().toUtc().toIso8601String()} [$source] ---')
    ..writeln(error)
    ..writeln(stack ?? 'Kein Stacktrace verfügbar.');
  _crashWrite = _crashWrite.then((_) async {
    try {
      if (await target.exists() && await target.length() > 2 * 1024 * 1024) {
        final rotated = File('${target.path}.previous');
        if (await rotated.exists()) await rotated.delete();
        await target.rename(rotated.path);
      }
      await target.writeAsString(
        entry.toString(),
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Logging must never turn a recoverable render failure into another one.
    }
  });
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
