import 'dart:async';

import 'package:flowboard_x/src/features/editor/pdf_import_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'releases the native preview before importing the source file',
    () async {
      final coordinator = PdfImportCoordinator();
      final preview = _FakePreview();
      final events = <String>[];

      final result = await coordinator.run<_FakePreview, int, String>(
        openPreview: () async {
          events.add('open');
          return preview;
        },
        selectPages: (_) async {
          events.add('select');
          return 3;
        },
        disposePreview: (value) async {
          value.disposed = true;
          events.add('dispose');
        },
        importSelection: (releasedPreview, selection) async {
          expect(releasedPreview.disposed, isTrue);
          events.add('import-$selection');
          return 'done';
        },
      );

      expect(result, 'done');
      expect(events, <String>['open', 'select', 'dispose', 'import-3']);
      expect(coordinator.isRunning, isFalse);
    },
  );

  test('cancel closes the preview and a second import can start', () async {
    final coordinator = PdfImportCoordinator();
    final previews = <_FakePreview>[];

    Future<String?> run({required bool cancel}) {
      return coordinator.run<_FakePreview, int, String>(
        openPreview: () async {
          final preview = _FakePreview();
          previews.add(preview);
          return preview;
        },
        selectPages: (_) async => cancel ? null : 0,
        disposePreview: (preview) async => preview.disposed = true,
        importSelection: (preview, _) async {
          expect(preview.disposed, isTrue);
          return 'imported';
        },
      );
    }

    expect(await run(cancel: true), isNull);
    expect(coordinator.isRunning, isFalse);
    expect(await run(cancel: false), 'imported');
    expect(previews, hasLength(2));
    expect(previews.every((preview) => preview.disposed), isTrue);
  });

  test('exceptions release both preview and operation guard', () async {
    final coordinator = PdfImportCoordinator();
    final preview = _FakePreview();

    await expectLater(
      coordinator.run<_FakePreview, int, void>(
        openPreview: () async => preview,
        selectPages: (_) async => throw StateError('preview failed'),
        disposePreview: (value) async => value.disposed = true,
        importSelection: (_, _) async {},
      ),
      throwsStateError,
    );

    expect(preview.disposed, isTrue);
    expect(coordinator.isRunning, isFalse);
    expect(
      await coordinator.run<_FakePreview, int, bool>(
        openPreview: () async => _FakePreview(),
        selectPages: (_) async => 0,
        disposePreview: (value) async => value.disposed = true,
        importSelection: (value, _) async => value.disposed,
      ),
      isTrue,
    );
  });

  test('a failed native picker releases the operation guard', () async {
    final coordinator = PdfImportCoordinator();

    await expectLater(
      coordinator.run<_FakePreview, int, bool>(
        openPreview: () async => throw StateError('picker failed'),
        selectPages: (_) async => 0,
        disposePreview: (_) async {},
        importSelection: (_, _) async => true,
      ),
      throwsStateError,
    );

    expect(coordinator.isRunning, isFalse);
    expect(
      await coordinator.run<_FakePreview, int, bool>(
        openPreview: () async => _FakePreview(),
        selectPages: (_) async => 0,
        disposePreview: (value) async => value.disposed = true,
        importSelection: (value, _) async => value.disposed,
      ),
      isTrue,
    );
  });

  test('a second trigger cannot start while the picker is active', () async {
    final coordinator = PdfImportCoordinator();
    final picker = Completer<_FakePreview?>();
    final first = coordinator.run<_FakePreview, int, void>(
      openPreview: () => picker.future,
      selectPages: (_) async => 0,
      disposePreview: (value) async => value.disposed = true,
      importSelection: (_, _) async {},
    );

    expect(coordinator.isRunning, isTrue);
    final duplicate = await coordinator.run<_FakePreview, int, bool>(
      openPreview: () async => throw StateError('must not open'),
      selectPages: (_) async => 0,
      disposePreview: (_) async {},
      importSelection: (_, _) async => true,
    );
    expect(duplicate, isNull);

    picker.complete(null);
    await first;
    expect(coordinator.isRunning, isFalse);
  });
}

final class _FakePreview {
  bool disposed = false;
}
