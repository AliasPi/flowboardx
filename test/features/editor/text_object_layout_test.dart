import 'dart:io';

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/editor/editor_controller.dart';
import 'package:flowboard_x/src/features/editor/inline_text_editing_engine.dart';
import 'package:flowboard_x/src/features/editor/text_object_layout.dart';
import 'package:flowboard_x/src/features/handwriting/handwriting_recognition_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fits short, multiline and wrapped board text', () {
    final short = _text('Kurz');
    final oneLine = TextObjectLayout.fit(value: short);
    final multiline = TextObjectLayout.fit(
      value: short.copyWith(text: 'Erste Zeile\nZweite Zeile'),
    );
    final wrapped = TextObjectLayout.fit(
      value: short.copyWith(
        text: List<String>.filled(80, 'langes Wort').join(' '),
      ),
      maximumWidth: 260,
    );

    expect(oneLine.width, lessThan(200));
    expect(multiline.height, greaterThan(oneLine.height));
    expect(wrapped.width, lessThanOrEqualTo(260));
    expect(wrapped.height, greaterThan(multiline.height));
    expect(
      <double>[
        oneLine.width,
        oneLine.height,
        multiline.width,
        multiline.height,
        wrapped.width,
        wrapped.height,
      ].every((value) => value.isFinite && value > 0),
      isTrue,
    );
  });

  test('handwriting conversion measures the recognized text', () async {
    final base = WhiteboardDocument.create(id: 'ocr-layout');
    final stroke = InkStroke(
      id: 'ink',
      width: 8,
      points: const <InkPoint>[
        InkPoint(x: 100, y: 100),
        InkPoint(x: 132, y: 118),
      ],
    );
    final controller = EditorController(
      document: base.copyWith(
        pages: <BoardPage>[
          base.currentPage.copyWith(
            strokes: <InkStroke>[stroke],
            selection: SelectionState(selectedItemIds: const <String>['ink']),
          ),
        ],
      ),
      repository: _MemoryRepository(),
      assetDirectory: Directory.current,
      handwritingRecognition: const _Recognition('Hallo Welt\nZweite Zeile'),
    );
    expect(await controller.convertSelectedHandwritingToText(), isTrue);
    final converted = controller.page.objects.whereType<TextObject>().single;
    final measured = TextObjectLayout.fit(value: converted, maximumWidth: 520);

    expect(converted.transform, measured);
    expect(converted.transform.height, greaterThan(stroke.bounds.height));
    expect(controller.page.strokes, isEmpty);
    expect(controller.selectedTextObject?.id, converted.id);
    await controller.close();
    controller.dispose();
  });

  test(
    'unrecognized handwriting remains ink and reports a friendly message',
    () async {
      final base = WhiteboardDocument.create(id: 'ocr-no-candidate');
      final stroke = InkStroke(
        id: 'ink',
        points: const <InkPoint>[
          InkPoint(x: 100, y: 100),
          InkPoint(x: 132, y: 118),
        ],
      );
      final controller = EditorController(
        document: base.copyWith(
          pages: <BoardPage>[
            base.currentPage.copyWith(
              strokes: <InkStroke>[stroke],
              selection: SelectionState(selectedItemIds: const <String>['ink']),
            ),
          ],
        ),
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
        handwritingRecognition: const _NoCandidateRecognition(),
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });

      expect(await controller.convertSelectedHandwritingToText(), isFalse);
      expect(controller.page.strokeById(stroke.id), same(stroke));
      expect(controller.page.objects, isEmpty);
      expect(controller.lastError, isNot(contains('FormatException')));
      expect(controller.lastError, contains('sicher erkannt'));
    },
  );

  test('editing text resizes it and remains undoable', () async {
    final base = WhiteboardDocument.create(id: 'edit-layout');
    final original = _text('Alt');
    final controller = EditorController(
      document: base.copyWith(
        pages: <BoardPage>[
          base.currentPage.copyWith(
            objects: <BoardObject>[original],
            selection: SelectionState(selectedItemIds: const <String>['text']),
          ),
        ],
      ),
      repository: _MemoryRepository(),
      assetDirectory: Directory.current,
    );
    expect(
      controller.updateTextObject(
        objectId: original.id,
        text: 'Eine deutlich längere erste Zeile\nund eine zweite Zeile',
        fontSize: 42,
        bold: true,
        alignment: BoardTextAlign.center,
      ),
      isTrue,
    );
    final edited = controller.page.objectById(original.id)! as TextObject;
    expect(edited.transform.width, isNot(original.transform.width));
    expect(edited.transform.height, greaterThan(40));
    expect(edited.bold, isTrue);
    expect(edited.alignment, BoardTextAlign.center);

    controller.undo();
    final restored = controller.page.objectById(original.id)! as TextObject;
    expect(restored.text, 'Alt');
    expect(restored.transform, original.transform);
    await controller.close();
    controller.dispose();
  });

  test('inline pen strike deletes a word and remains undoable', () async {
    final base = WhiteboardDocument.create(id: 'inline-strike');
    final original = _text('Heute ist Montag');
    final controller = EditorController(
      document: base.copyWith(
        pages: <BoardPage>[
          base.currentPage.copyWith(
            objects: <BoardObject>[original],
            selection: SelectionState(selectedItemIds: const <String>['text']),
          ),
        ],
      ),
      repository: _MemoryRepository(),
      assetDirectory: Directory.current,
    );
    final token = InlineTextEditingEngine.tokensFor(original)[1];
    final strike = <Offset>[
      Offset(token.bounds.left - 4, token.bounds.center.dy),
      Offset(token.bounds.right + 4, token.bounds.center.dy),
    ];

    expect(
      controller.applyInlineTextStrike(
        objectId: original.id,
        localPoints: strike,
      ),
      isTrue,
    );
    expect(controller.selectedTextObject?.text, 'Heute Montag');
    controller.undo();
    expect(
      (controller.page.objectById(original.id)! as TextObject).text,
      original.text,
    );
    await controller.close();
    controller.dispose();
  });

  test('inline handwriting replaces the word under the pen', () async {
    final base = WhiteboardDocument.create(id: 'inline-replace');
    final original = _text('Heute ist Montag');
    final controller = EditorController(
      document: base.copyWith(
        pages: <BoardPage>[
          base.currentPage.copyWith(
            objects: <BoardObject>[original],
            selection: SelectionState(selectedItemIds: const <String>['text']),
          ),
        ],
      ),
      repository: _MemoryRepository(),
      assetDirectory: Directory.current,
      handwritingRecognition: const _Recognition('Dienstag'),
    );
    final token = InlineTextEditingEngine.tokensFor(original).last;

    expect(
      await controller.applyInlineTextHandwriting(
        objectId: original.id,
        localStrokes: <List<Offset>>[
          <Offset>[
            token.bounds.topLeft,
            token.bounds.center,
            token.bounds.bottomRight,
          ],
        ],
      ),
      isTrue,
    );
    final edited = controller.selectedTextObject!;
    expect(edited.text, 'Heute ist Dienstag');
    expect(edited.transform, TextObjectLayout.fit(value: edited));
    await controller.close();
    controller.dispose();
  });

  test(
    'handwriting after the final caret grows a converted text field',
    () async {
      final base = WhiteboardDocument.create(id: 'inline-append-grows');
      final original = _text('Ein bereits ziemlich langer Satz').copyWith(
        transform: const ObjectTransform(x: 40, y: 60, width: 720, height: 48),
      );
      final controller = EditorController(
        document: base.copyWith(
          pages: <BoardPage>[
            base.currentPage.copyWith(
              objects: <BoardObject>[original],
              selection: SelectionState(
                selectedItemIds: const <String>['text'],
              ),
            ),
          ],
        ),
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
        handwritingRecognition: const _Recognition('weitergeschrieben'),
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });

      expect(
        await controller.applyInlineTextHandwriting(
          objectId: original.id,
          localStrokes: const <List<Offset>>[
            <Offset>[Offset(748, 8), Offset(790, 25), Offset(830, 10)],
          ],
        ),
        isTrue,
      );

      final edited = controller.selectedTextObject!;
      expect(edited.text, endsWith(' weitergeschrieben'));
      expect(edited.transform.width, greaterThan(original.transform.width));
      controller.undo();
      expect(
        (controller.page.objectById(original.id)! as TextObject).text,
        original.text,
      );
    },
  );
}

TextObject _text(String value) => TextObject(
  id: 'text',
  transform: const ObjectTransform(x: 40, y: 60, width: 500, height: 300),
  text: value,
  fontSize: 28,
);

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

final class _NoCandidateRecognition implements HandwritingRecognitionService {
  const _NoCandidateRecognition();

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<HandwritingRecognitionResult> recognize(
    HandwritingRecognitionRequest request,
  ) async => const HandwritingRecognitionResult.notRecognized(
    message: 'Die Handschrift wurde nicht sicher erkannt.',
  );
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
