import 'dart:convert';
import 'dart:io';

import 'package:flowboard_x/src/diagnostics/diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sessionId = '11111111-1111-4111-8111-111111111111';
  const metadata = DiagnosticSessionMetadata(
    appVersion: '1.2.3',
    buildNumber: '42',
    platform: 'android',
    platformVersion: 'Android 15',
    buildMode: 'release',
  );

  late Directory temporaryRoot;

  setUp(() async {
    temporaryRoot = await Directory.systemTemp.createTemp(
      'flowboard-diagnostics-test-',
    );
  });

  tearDown(() async {
    if (await temporaryRoot.exists()) {
      await temporaryRoot.delete(recursive: true);
    }
  });

  test('writes session metadata and accepted structured fields', () async {
    final service = DiagnosticLogService(sessionId: sessionId);
    expect(
      await service.initialize(directory: temporaryRoot, metadata: metadata),
      isTrue,
    );

    service.info(
      'editor.opened',
      fields: {'page_count': 4, 'recovered': true, 'state': 'ready'},
    );
    await service.flush();

    final entries = await _readEntries(service);
    expect(entries.first['event'], 'session.start');
    expect(entries.first['session_id'], sessionId);
    expect(entries.first['app_version'], '1.2.3');
    expect(entries.first['build_number'], '42');
    expect(entries.first['platform'], 'android');
    expect(entries.first['build_mode'], 'release');
    expect(entries.last['event'], 'editor.opened');
    expect(entries.last['fields'], {
      'page_count': 4,
      'recovered': true,
      'state': 'ready',
    });
  });

  test('never persists exception messages paths or document content', () async {
    final service = DiagnosticLogService(sessionId: sessionId);
    await service.initialize(
      directory: temporaryRoot,
      metadata: const DiagnosticSessionMetadata(
        appVersion: '1.2.3',
        buildNumber: '42',
        platform: 'windows',
        platformVersion: r'Windows C:\Users\Private\device.txt',
        buildMode: 'debug',
      ),
    );

    service.recordException(
      event: 'handwriting.failed',
      error: const FormatException(
        r'SUPER_SECRET_TEXT C:\Users\Alice\Documents\board.flowboard',
      ),
      stackTrace: StackTrace.fromString(
        '#0 recognize '
        r'(C:\Users\Alice\FlowboardX\lib\src\features\handwriting.dart:42:7)'
        '\n#1 invoke (package:flowboard_x/src/editor.dart:9:3)'
        '\nleaked SUPER_SECRET_STACK_VALUE',
      ),
      fields: const {
        'document_title': 'Class 7 private notes',
        'stroke_points': [12, 14, 16],
        'unsafe': 'human readable private text',
        'payload': 'SECRET_TOKEN',
        'selection_count': 3,
        'phase': 'recognize',
      },
    );
    await service.flush();

    final file = (await service.logFiles()).single;
    final contents = await file.readAsString();
    expect(contents, isNot(contains('SUPER_SECRET')));
    expect(contents, isNot(contains('Alice')));
    expect(contents, isNot(contains('Class 7')));
    expect(contents, isNot(contains('stroke_points')));
    expect(contents, isNot(contains(r'C:\Users')));
    expect(contents, contains('FormatException'));
    expect(contents, contains('lib/src/features/handwriting.dart:42:7'));
    expect(contents, contains('package:flowboard_x/src/editor.dart:9:3'));

    final entries = await _readEntries(service);
    final fields = entries.last['fields']! as Map<String, dynamic>;
    expect(fields['selection_count'], 3);
    expect(fields['phase'], 'recognize');
    expect(fields['fingerprint'], hasLength(16));
    expect(fields, isNot(contains('document_title')));
    expect(fields, isNot(contains('unsafe')));
    expect(fields, isNot(contains('payload')));
  });

  test('rotates files and keeps the configured bounded count', () async {
    final service = DiagnosticLogService(
      sessionId: sessionId,
      maxFileBytes: 440,
      maxFiles: 3,
    );
    await service.initialize(directory: temporaryRoot, metadata: metadata);

    for (var index = 0; index < 20; index++) {
      service.info('board.operation', fields: {'sequence': index});
      await service.flush();
    }

    final files = await service.logFiles();
    expect(files, hasLength(3));
    expect(files.map((file) => file.path), everyElement(endsWith('.jsonl')));
    for (final file in files) {
      expect(await file.length(), greaterThan(0));
      for (final line in await file.readAsLines()) {
        expect(jsonDecode(line), isA<Map<String, dynamic>>());
      }
    }
  });

  test('bounded queue reports dropped records after pressure clears', () async {
    final service = DiagnosticLogService(
      sessionId: sessionId,
      maxQueuedRecords: 1,
    );
    await service.initialize(directory: temporaryRoot, metadata: metadata);

    for (var index = 0; index < 30; index++) {
      service.debug('pointer.sample', fields: {'sequence': index});
    }
    await service.flush();
    service.info('queue.recovered');
    await service.flush();

    final entries = await _readEntries(service);
    final overflow = entries.where(
      (entry) => entry['event'] == 'diagnostics.queue_overflow',
    );
    expect(overflow, hasLength(1));
    final fields = overflow.single['fields']! as Map<String, dynamic>;
    expect(fields['dropped_count'] as int, greaterThan(0));
    expect(entries.last['event'], 'queue.recovered');
  });

  test('buffers early failures and exports one chronological copy', () async {
    var tick = DateTime.utc(2026, 7, 23, 10, 20, 30);
    final service = DiagnosticLogService(
      sessionId: sessionId,
      now: () => tick,
      maxPreInitializationRecords: 2,
    );
    service.warning('early.one');
    tick = tick.add(const Duration(seconds: 1));
    service.warning('early.two');
    tick = tick.add(const Duration(seconds: 1));
    service.warning('early.three');
    await service.initialize(directory: temporaryRoot, metadata: metadata);

    final exportDirectory = Directory('${temporaryRoot.path}-exports');
    addTearDown(() async {
      if (await exportDirectory.exists()) {
        await exportDirectory.delete(recursive: true);
      }
    });
    final first = await service.createExportCopy(exportDirectory);
    final second = await service.createExportCopy(exportDirectory);

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(first!.path, isNot(second!.path));
    final exported = await first.readAsString();
    expect(exported, isNot(contains('early.one')));
    expect(exported, contains('early.two'));
    expect(exported, contains('early.three'));
    expect(exported, contains('diagnostics.queue_overflow'));
  });

  test('storage failure disables logging without throwing', () async {
    final blockingFile = File(
      '${temporaryRoot.path}${Platform.pathSeparator}x',
    );
    await blockingFile.writeAsString('not a directory');
    final blockedDirectory = Directory(blockingFile.path);
    final service = DiagnosticLogService();

    expect(
      await service.initialize(directory: blockedDirectory, metadata: metadata),
      isFalse,
    );
    expect(
      () => service.recordException(
        event: 'still.safe',
        error: StateError('private message'),
      ),
      returnsNormally,
    );
    await service.flush();
    expect(await service.logFiles(), isEmpty);
    expect(await service.createExportCopy(temporaryRoot), isNull);
  });

  test('broken log file cannot block or fail application startup', () async {
    await Directory(
      '${temporaryRoot.path}${Platform.pathSeparator}'
      '${DiagnosticLogService.currentFileName}',
    ).create();
    final service = DiagnosticLogService(sessionId: sessionId);

    expect(
      await service.initialize(directory: temporaryRoot, metadata: metadata),
      isTrue,
    );
    expect(() => service.info('startup.continues'), returnsNormally);
    await service.flush();
    expect(service.isInitialized, isTrue);
  });

  test('shutdown is idempotent and rejects later records', () async {
    final service = DiagnosticLogService(sessionId: sessionId);
    await service.initialize(directory: temporaryRoot, metadata: metadata);
    service.info('before.shutdown');

    await Future.wait([service.shutdown(), service.shutdown()]);
    service.info('after.shutdown');
    await service.flush();

    expect(service.isAcceptingRecords, isFalse);
    final entries = await _readEntries(service);
    expect(entries.map((entry) => entry['event']), [
      'session.start',
      'before.shutdown',
      'session.end',
    ]);
  });

  test('caller cannot inject identifying session value', () {
    final service = DiagnosticLogService(sessionId: 'student-secret-name');

    expect(service.sessionId, isNot('student-secret-name'));
    expect(
      service.sessionId,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
  });
}

Future<List<Map<String, dynamic>>> _readEntries(
  DiagnosticLogService service,
) async {
  final files = await service.logFiles();
  final result = <Map<String, dynamic>>[];
  for (final file in files.reversed) {
    for (final line in await file.readAsLines()) {
      result.add(jsonDecode(line) as Map<String, dynamic>);
    }
  }
  return result;
}
