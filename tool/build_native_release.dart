import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'android_offline_model_verifier.dart';

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
  _GeneratedFileBackup? androidRegistrantBackup;
  try {
    cleanupAttempted = true;
    await _run('dart', const <String>['run', 'pdfrx:remove_wasm_modules']);
    await _clearFlutterAssetCache();
    await _removeStaleNativeWasmArtifacts(target);
    if (target == 'apk' || target == 'appbundle') {
      androidRegistrantBackup =
          await _stripDevOnlyAndroidPluginsFromRegistrant();
    }
    await _run('flutter', <String>[
      'build',
      target,
      '--release',
      '--no-pub',
      ...arguments.skip(1),
    ]);
    if (target == 'apk' || target == 'appbundle') {
      await _verifyAndroidOfflineModels(
        target,
        splitPerAbi: arguments.skip(1).contains('--split-per-abi'),
      );
    }
    final stale = await _nativeWasmArtifacts(target);
    if (stale.isNotEmpty) {
      throw StateError(
        'Der native Build enthÃ¤lt weiterhin PDFium-Webmodule:\n'
        '${stale.join('\n')}',
      );
    }
  } finally {
    try {
      if (cleanupAttempted) {
        await _run('dart', const <String>[
          'run',
          'pdfrx:remove_wasm_modules',
          '--revert',
        ]);
      }
    } finally {
      final backup = androidRegistrantBackup;
      if (backup != null) {
        await backup.file.writeAsString(backup.contents);
      }
    }
  }
}

/// Fails the production build if any emitted Android artifact lost the
/// statically linked Latin recognition model.
Future<void> _verifyAndroidOfflineModels(
  String target, {
  required bool splitPerAbi,
}) async {
  final buildRoot = p.normalize(p.absolute('build', 'app', 'outputs'));
  final outputDirectory = switch (target) {
    'apk' => Directory(p.join(buildRoot, 'flutter-apk')),
    'appbundle' => Directory(p.join(buildRoot, 'bundle', 'release')),
    _ => throw ArgumentError.value(target, 'target'),
  };
  if (!p.isWithin(buildRoot, p.normalize(outputDirectory.absolute.path))) {
    throw StateError(
      'Unsicherer Android-Ausgabepfad: ${outputDirectory.absolute.path}',
    );
  }
  final extension = target == 'apk' ? '.apk' : '.aab';
  final expectedNames = target == 'appbundle'
      ? const <String>{'app-release.aab'}
      : splitPerAbi
      ? const <String>{
          'app-armeabi-v7a-release.apk',
          'app-arm64-v8a-release.apk',
          'app-x86_64-release.apk',
        }
      : const <String>{'app-release.apk'};
  final artifacts = outputDirectory.existsSync()
      ? outputDirectory
            .listSync(followLinks: false)
            .whereType<File>()
            .where(
              (file) =>
                  p.extension(file.path).toLowerCase() == extension &&
                  expectedNames.contains(p.basename(file.path).toLowerCase()),
            )
            .toList(growable: false)
      : const <File>[];
  final foundNames = artifacts
      .map((artifact) => p.basename(artifact.path).toLowerCase())
      .toSet();
  if (!foundNames.containsAll(expectedNames)) {
    final missing = expectedNames.difference(foundNames).toList()..sort();
    throw StateError(
      'Android-Releaseartefakte zur Modellprüfung fehlen: '
      '${missing.join(', ')} (${outputDirectory.path})',
    );
  }
  const verifier = AndroidOfflineModelVerifier();
  for (final artifact in artifacts) {
    final report = verifier.verifyArchive(artifact);
    stdout.writeln(
      '> Offline-Handschriftmodell geprüft: ${report.artifactName}, '
      '${report.modelFileCount} Dateien, '
      '${report.uncompressedModelBytes} Byte ML Kit; '
      '${report.handwritingAssetCount} PP-OCRv5-Assets, '
      '${report.handwritingAssetBytes} Byte; '
      '${report.onnxRuntimeLibraryCount} ONNX-Runtime-Bibliotheken; '
      '${report.onnxRuntimeJavaTypeCount} JNI-Java-Typen',
    );
  }
}

/// Removes dev-only Android plugins from Flutter's generated release source.
///
/// A preceding `flutter test integration_test/...` legitimately writes the
/// dev-only `integration_test` plugin into this generated source. Flutter 3.38
/// can otherwise reuse that debug registrant while excluding the corresponding
/// release dependency. Deleting the complete registrant is unsafe because
/// native plugins such as `jni` require their production registration.
Future<_GeneratedFileBackup?>
_stripDevOnlyAndroidPluginsFromRegistrant() async {
  final androidRoot = p.normalize(p.absolute('android'));
  final registrantPath = p.normalize(
    p.join(
      androidRoot,
      'app',
      'src',
      'main',
      'java',
      'io',
      'flutter',
      'plugins',
      'GeneratedPluginRegistrant.java',
    ),
  );
  if (!p.isWithin(androidRoot, registrantPath)) {
    throw StateError('Unsicherer Android-Registrant-Pfad: $registrantPath');
  }
  final dependencyFile = File(
    p.normalize(p.absolute('.flutter-plugins-dependencies')),
  );
  if (!await dependencyFile.exists()) {
    throw StateError('Flutter-Pluginmetadaten fehlen: ${dependencyFile.path}');
  }
  final metadata = jsonDecode(await dependencyFile.readAsString());
  if (metadata is! Map<String, dynamic> ||
      metadata['plugins'] is! Map<String, dynamic>) {
    throw const FormatException('Ungültige Flutter-Pluginmetadaten.');
  }
  final platformPlugins =
      (metadata['plugins'] as Map<String, dynamic>)['android'];
  if (platformPlugins is! List) {
    throw const FormatException('Android-Pluginmetadaten fehlen.');
  }
  final devPluginNames = <String>{
    for (final plugin in platformPlugins)
      if (plugin is Map<String, dynamic> &&
          plugin['dev_dependency'] == true &&
          plugin['name'] is String)
        plugin['name']! as String,
  };
  if (devPluginNames.isEmpty) return null;

  final registrant = File(registrantPath);
  if (!await registrant.exists()) {
    throw StateError('Android-Plugin-Registrant fehlt: $registrantPath');
  }
  final originalContents = await registrant.readAsString();
  final lines = originalContents.split('\n');
  final releaseLines = <String>[];
  final removed = <String>{};
  var index = 0;
  while (index < lines.length) {
    if (lines[index].trimRight() != '    try {') {
      releaseLines.add(lines[index]);
      index++;
      continue;
    }
    var end = index + 1;
    while (end < lines.length && lines[end].trimRight() != '    }') {
      end++;
    }
    if (end >= lines.length) {
      throw const FormatException(
        'Der Android-Plugin-Registrant enthält einen unvollständigen Block.',
      );
    }
    final block = lines.sublist(index, end + 1);
    final blockText = block.join('\n');
    String? devPlugin;
    for (final name in devPluginNames) {
      if (blockText.contains('Error registering plugin $name,')) {
        devPlugin = name;
        break;
      }
    }
    if (devPlugin == null) {
      releaseLines.addAll(block);
    } else {
      removed.add(devPlugin);
    }
    index = end + 1;
  }
  if (!removed.containsAll(devPluginNames)) {
    final unexpected = devPluginNames.difference(removed).toList()..sort();
    throw StateError(
      'Dev-Plugins konnten nicht aus dem Release-Registrant entfernt werden: '
      '${unexpected.join(', ')}',
    );
  }
  stdout.writeln(
    '> entferne Dev-Plugins aus Android-Release-Registrant: '
    '${removed.toList()..sort()}',
  );
  await registrant.writeAsString(releaseLines.join('\n'));
  return (file: registrant, contents: originalContents);
}

typedef _GeneratedFileBackup = ({File file, String contents});

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
