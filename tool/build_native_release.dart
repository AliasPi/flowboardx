import 'dart:io';

import 'package:path/path.dart' as p;

/// Builds a native release without pdfrx's web-only PDFium WASM payload.
///
/// The official pdfrx cleanup is always reverted in `finally`, so subsequent
/// web/debug builds keep working even when a native build fails or is stopped.
Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty || arguments.first == 'web') {
    stderr.writeln(
      'Aufruf: dart run tool/build_native_release.dart '
      '<apk|appbundle|windows|linux|macos|ios> [flutter-build-optionen]',
    );
    exitCode = 64;
    return;
  }
  final target = arguments.first;
  const supported = <String>{
    'apk',
    'appbundle',
    'windows',
    'linux',
    'macos',
    'ios',
  };
  if (!supported.contains(target)) {
    stderr.writeln('Nicht unterstütztes natives Ziel: $target');
    exitCode = 64;
    return;
  }

  await _run('flutter', const <String>['pub', 'get']);
  var cleanupAttempted = false;
  try {
    cleanupAttempted = true;
    await _run('dart', const <String>['run', 'pdfrx:remove_wasm_modules']);
    await _clearFlutterAssetCache();
    await _removeStaleNativeWasmArtifacts(target);
    await _run('flutter', <String>[
      'build',
      target,
      '--release',
      '--no-pub',
      ...arguments.skip(1),
    ]);
    final stale = await _nativeWasmArtifacts(target);
    if (stale.isNotEmpty) {
      throw StateError(
        'Der native Build enthÃ¤lt weiterhin PDFium-Webmodule:\n'
        '${stale.join('\n')}',
      );
    }
  } finally {
    if (cleanupAttempted) {
      await _run('dart', const <String>[
        'run',
        'pdfrx:remove_wasm_modules',
        '--revert',
      ]);
    }
  }
}

/// Invalidates Flutter's generated asset manifest after pdfrx's package
/// manifest changed. Merely deleting the final runner directory is not enough:
/// Flutter can otherwise restore the removed files from this incremental
/// cache.
Future<void> _clearFlutterAssetCache() async {
  final dartToolRoot = p.normalize(p.absolute('.dart_tool'));
  final cachePath = p.normalize(p.join(dartToolRoot, 'flutter_build'));
  if (!p.isWithin(dartToolRoot, cachePath)) {
    throw StateError('Unsicherer Flutter-Cachepfad: $cachePath');
  }
  final cache = Directory(cachePath);
  if (!await cache.exists()) return;
  stdout.writeln('> invalidiere Flutter-Assetcache $cachePath');
  await cache.delete(recursive: true);
}

/// Removes only stale pdfrx web modules from the selected platform's output.
///
/// Flutter's incremental Windows copier does not delete assets that vanished
/// from a package manifest. Without this targeted cleanup, a PDFium WASM file
/// from an earlier web/debug build can survive in an otherwise valid native
/// release even though pdfrx's manifest was cleaned correctly.
Future<void> _removeStaleNativeWasmArtifacts(String target) async {
  final stale = await _nativeWasmArtifacts(target);
  for (final path in stale) {
    stdout.writeln('> entferne veraltetes Webmodul $path');
    await File(path).delete();
  }
}

Future<List<String>> _nativeWasmArtifacts(String target) async {
  final relative = switch (target) {
    'apk' || 'appbundle' => 'app',
    'windows' => 'windows',
    'linux' => 'linux',
    'macos' => 'macos',
    'ios' => 'ios',
    _ => throw ArgumentError.value(target, 'target'),
  };
  final buildRoot = p.normalize(p.absolute('build'));
  final outputPath = p.normalize(p.join(buildRoot, relative));
  if (!p.isWithin(buildRoot, outputPath)) {
    throw StateError('Unsicherer Build-Ausgabepfad: $outputPath');
  }
  // `build/flutter_assets` is Flutter's shared staging directory. Desktop
  // install steps copy it wholesale, so stale package files there would be
  // resurrected even after cleaning the final runner directory.
  final roots = <Directory>[
    Directory(p.join(buildRoot, 'flutter_assets')),
    Directory(outputPath),
  ];
  final stale = <String>{};
  for (final output in roots) {
    if (!await output.exists()) continue;
    await for (final entity in output.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final normalized = p.normalize(entity.path).replaceAll('\\', '/');
      if (!normalized.toLowerCase().contains('/packages/pdfrx/assets/')) {
        continue;
      }
      final name = p.basename(normalized).toLowerCase();
      if (name == 'pdfium.wasm' ||
          name == 'pdfium_client.js' ||
          name == 'pdfium_worker.js' ||
          name == 'pdfium_wasm_client.js') {
        stale.add(entity.path);
      }
    }
  }
  return stale.toList(growable: false)..sort();
}

Future<void> _run(String executable, List<String> arguments) async {
  stdout.writeln('> $executable ${arguments.join(' ')}');
  final process = await Process.start(
    executable,
    arguments,
    mode: ProcessStartMode.inheritStdio,
    runInShell: Platform.isWindows,
  );
  final code = await process.exitCode;
  if (code != 0) {
    throw ProcessException(executable, arguments, 'Exit-Code $code', code);
  }
}
