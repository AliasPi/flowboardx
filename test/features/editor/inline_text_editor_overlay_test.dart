import 'dart:io';

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/features/board/presentation/board_surface.dart';
import 'package:flowboard_x/src/features/board/presentation/inline_text_editor_overlay.dart';
import 'package:flowboard_x/src/features/editor/editor_controller.dart';
import 'package:flowboard_x/src/features/editor/inline_text_editing_engine.dart';
import 'package:flowboard_x/src/features/handwriting/handwriting_recognition_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('selected text is corrected directly on the board by pen', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 700);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final base = WhiteboardDocument.create(id: 'inline-overlay');
    final value = TextObject(
      id: 'text',
      transform: const ObjectTransform(x: 180, y: 240, width: 520, height: 80),
      text: 'Heute ist Montag',
      fontSize: 36,
    );
    final controller = EditorController(
      document: base.copyWith(
        pages: <BoardPage>[
          base.currentPage.copyWith(
            objects: <BoardObject>[value],
            selection: SelectionState(selectedItemIds: const <String>['text']),
          ),
        ],
      ),
      repository: _MemoryRepository(),
      assetDirectory: Directory.current,
    );
    addTearDown(() async {
      await controller.close();
      controller.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BoardSurface(controller: controller)),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Text mit Stift korrigieren'));
    await tester.pump();

    expect(find.textContaining('Über ein Wort schreiben'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Text direkt mit dem Stift korrigieren'),
      findsOneWidget,
    );

    final token = InlineTextEditingEngine.tokensFor(value).last;
    final start = Offset(
      value.transform.x + token.bounds.left - 4,
      value.transform.y + token.bounds.center.dy,
    );
    final end = Offset(
      value.transform.x + token.bounds.right + 4,
      value.transform.y + token.bounds.center.dy,
    );
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.stylus,
    );
    await gesture.moveTo(end);
    await gesture.up();
    await tester.pump();

    expect(controller.selectedTextObject?.text, 'Heute ist');
    expect(find.textContaining('Über ein Wort schreiben'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Drain the controller's fake-time autosave checkpoints before the widget
    // test binding verifies that no timers escaped the test.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
  });

  testWidgets('off-screen edited text exits without negative constraints', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 260);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final base = WhiteboardDocument.create(id: 'inline-offscreen');
    final value = TextObject(
      id: 'text',
      transform: const ObjectTransform(
        x: 9000,
        y: 9000,
        width: 400,
        height: 80,
      ),
      text: 'Außerhalb',
    );
    final controller = EditorController(
      document: base.copyWith(
        pages: <BoardPage>[
          base.currentPage.copyWith(objects: <BoardObject>[value]),
        ],
      ),
      repository: _MemoryRepository(),
      assetDirectory: Directory.current,
    );
    addTearDown(() async {
      await controller.close();
      controller.dispose();
    });
    var ended = false;

    await tester.pumpWidget(
      MaterialApp(
        home: InlineTextEditorOverlay(
          controller: controller,
          objectId: value.id,
          onDone: () => ended = true,
        ),
      ),
    );
    await tester.pump();

    expect(ended, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending handwriting is recognized before an off-screen exit', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 700);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final base = WhiteboardDocument.create(id: 'inline-pending-offscreen');
    final value = TextObject(
      id: 'text',
      transform: const ObjectTransform(x: 180, y: 240, width: 420, height: 80),
      text: 'Heute',
      fontSize: 36,
    );
    final controller = EditorController(
      document: base.copyWith(
        pages: <BoardPage>[
          base.currentPage.copyWith(objects: <BoardObject>[value]),
        ],
      ),
      repository: _MemoryRepository(),
      assetDirectory: Directory.current,
      handwritingRecognition: const _Recognition('Dienstag'),
    );
    addTearDown(() async {
      await controller.close();
      controller.dispose();
    });
    var ended = false;

    Widget editor() => MaterialApp(
      home: InlineTextEditorOverlay(
        controller: controller,
        objectId: value.id,
        onDone: () => ended = true,
      ),
    );

    await tester.pumpWidget(editor());
    final gesture = await tester.startGesture(
      const Offset(630, 265),
      kind: PointerDeviceKind.stylus,
    );
    await gesture.moveTo(const Offset(670, 292));
    await gesture.moveTo(const Offset(710, 258));
    await gesture.up();
    await tester.pump();

    // Move the object outside the viewport before the normal 760 ms debounce
    // fires, then rebuild as BoardSurface would after a viewport notification.
    controller.viewport.restore(scale: 1, offset: const Offset(-5000, -5000));
    await tester.pumpWidget(editor());
    await tester.pump();
    await tester.pump();

    expect(ended, isTrue);
    expect(controller.page.objectById(value.id), isA<TextObject>());
    expect(
      (controller.page.objectById(value.id)! as TextObject).text,
      'Heute Dienstag',
    );
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
  });
}

final class _Recognition implements HandwritingRecognitionService {
  const _Recognition(this.text);
  final String text;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<HandwritingRecognitionResult> recognize(
    HandwritingRecognitionRequest request,
  ) async => HandwritingRecognitionResult(text: text);
}

final class _MemoryRepository implements DocumentRepository {
  @override
  Future<void> delete(String documentId) async {}

  @override
  Future<Directory> assetDirectory(String documentId) async =>
      Directory.current;

  @override
  Future<List<DocumentSummary>> list() async => const <DocumentSummary>[];

  @override
  Future<WhiteboardDocument?> load(String documentId) async => null;

  @override
  Future<WhiteboardDocument?> recover(String documentId) async => null;

  @override
  Future<void> save(WhiteboardDocument document) async {}
}
