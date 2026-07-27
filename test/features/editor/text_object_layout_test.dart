import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/editor/editor_controller.dart';
import 'package:flowboard_x/src/features/editor/inline_text_editing_engine.dart';
import 'package:flowboard_x/src/features/editor/text_object_layout.dart';
import 'package:flowboard_x/src/features/board/presentation/board_object_layer.dart';
import 'package:flowboard_x/src/features/board/presentation/board_surface.dart';
import 'package:flowboard_x/src/features/handwriting/handwriting_recognition_service.dart';
import 'package:flutter/material.dart';
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
      handwritingRecognition: const _Recognition(
        'Heute prüfen wir die Verantwortungsübernahmedokumentation',
      ),
    );
    expect(await controller.convertSelectedHandwritingToText(), isTrue);
    final converted = controller.page.objects.whereType<TextObject>().single;
    final measured = TextObjectLayout.fit(value: converted, maximumWidth: 520);

    expect(converted.transform, measured);
    expect(converted.transform.height, greaterThan(stroke.bounds.height));
    _expectVisibleTextFits(converted);
    expect(controller.page.strokes, isEmpty);
    expect(controller.selectedTextObject?.id, converted.id);
    await controller.close();
    controller.dispose();
  });

  test(
    'handwriting conversion is single-flight and locks ink transforms',
    () async {
      final recognition = _DeferredRecognition();
      final controller = _controllerWithSelectedStroke(
        documentId: 'ocr-single-flight',
        recognition: recognition,
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });

      final conversion = controller.convertSelectedHandwritingToText();
      expect(controller.isHandwritingConversionInProgress, isTrue);
      await recognition.started.future;

      expect(await controller.convertSelectedHandwritingToText(), isFalse);
      expect(recognition.recognizeCalls, 1);
      expect(
        controller.claimSelectionInteraction('parallel-transform'),
        isFalse,
      );
      expect(
        controller.beginInk(
          const PointerDownEvent(pointer: 91, position: Offset(160, 160)),
          const Offset(160, 160),
        ),
        isFalse,
      );

      recognition.complete('Einmal');
      expect(await conversion, isTrue);
      expect(controller.isHandwritingConversionInProgress, isFalse);
      expect(recognition.recognizeCalls, 1);
      expect(controller.page.strokes, isEmpty);
      expect(controller.selectedTextObject?.text, 'Einmal');
    },
  );

  test(
    'valid dense handwriting snapshots reuse stroke and point storage',
    () async {
      final recognition = _DeferredRecognition();
      final base = WhiteboardDocument.create(id: 'ocr-dense-snapshot');
      final source = InkStroke(
        id: 'dense-ink',
        width: 8,
        points: List<InkPoint>.generate(
          12000,
          (index) => InkPoint(
            x: index / 4,
            y: 120 + math.sin(index / 20) * 24,
            pressure: .6,
            timestampMicros: index,
          ),
          growable: false,
        ),
      );
      final controller = EditorController(
        document: base.copyWith(
          pages: <BoardPage>[
            base.currentPage.copyWith(
              strokes: <InkStroke>[source],
              selection: SelectionState(
                selectedItemIds: const <String>['dense-ink'],
              ),
            ),
          ],
        ),
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
        handwritingRecognition: recognition,
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });

      final conversion = controller.convertSelectedHandwritingToText();
      await recognition.started.future;
      final captured = recognition.requests.single.strokes.single;
      expect(captured, same(source));
      expect(captured.points, same(source.points));
      expect(captured.points.first, same(source.points.first));
      expect(captured.points.last, same(source.points.last));

      recognition.complete('Speichergebunden');
      expect(await conversion, isTrue);
    },
  );

  test(
    'snapshot capture failures stay inside the conversion boundary',
    () async {
      final recognition = _DeferredRecognition();
      final controller = _controllerWithSelectedStroke(
        documentId: 'ocr-capture-failure',
        recognition: recognition,
        debugBeforeHandwritingSnapshotCapture: () {
          throw StateError('Beschädigter Snapshot');
        },
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });

      expect(await controller.convertSelectedHandwritingToText(), isFalse);
      expect(controller.isHandwritingConversionInProgress, isFalse);
      expect(controller.page.strokes, hasLength(1));
      expect(recognition.recognizeCalls, 0);
      expect(controller.lastError, contains('Beschädigter Snapshot'));
    },
  );

  test(
    'typed recognition failures release the conversion busy state',
    () async {
      final recognition = _DeferredRecognition();
      final controller = _controllerWithSelectedStroke(
        documentId: 'ocr-timeout-state',
        recognition: recognition,
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });

      final conversion = controller.convertSelectedHandwritingToText();
      await recognition.started.future;
      expect(controller.isHandwritingConversionInProgress, isTrue);
      recognition.fail(
        const HandwritingRecognitionFailure(
          HandwritingRecognitionFailureKind.engineFailure,
          'Die lokale Handschrifterkennung hat das Zeitlimit überschritten.',
        ),
      );

      expect(await conversion, isFalse);
      expect(controller.isHandwritingConversionInProgress, isFalse);
      expect(controller.page.strokes, hasLength(1));
      expect(controller.lastError, contains('Zeitlimit'));
    },
  );

  testWidgets('conversion action is disabled while recognition is pending', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 700);
    final recognition = _DeferredRecognition();
    final controller = _controllerWithSelectedStroke(
      documentId: 'ocr-disabled-action',
      recognition: recognition,
    );
    addTearDown(() async {
      await controller.close();
      controller.dispose();
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BoardSurface(controller: controller)),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('Handschrift in Text umwandeln'), findsOneWidget);

    final conversion = controller.convertSelectedHandwritingToText();
    await recognition.started.future;
    await tester.pump();

    final busyTooltip = find.byTooltip('Handschrift wird umgewandelt');
    expect(busyTooltip, findsOneWidget);
    final button = tester.widget<IconButton>(
      find.descendant(of: busyTooltip, matching: find.byType(IconButton)),
    );
    expect(button.onPressed, isNull);

    recognition.complete('Fertig');
    expect(await conversion, isTrue);
    await tester.pump();
    expect(find.byTooltip('Handschrift wird umgewandelt'), findsNothing);
    await controller.flush();
  });

  test(
    'selection changes invalidate an awaiting handwriting conversion',
    () async {
      final recognition = _DeferredRecognition();
      final controller = _controllerWithSelectedStroke(
        documentId: 'ocr-selection-race',
        recognition: recognition,
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });

      final source = controller.page.strokes.single;
      final conversion = controller.convertSelectedHandwritingToText();
      await recognition.started.future;
      controller.clearSelection();
      recognition.complete('Veraltet');

      expect(await conversion, isFalse);
      expect(controller.isHandwritingConversionInProgress, isFalse);
      expect(controller.page.strokeById(source.id), same(source));
      expect(controller.page.objects, isEmpty);
      expect(controller.selectedIds, isEmpty);
    },
  );

  test(
    'stroke mutation invalidates an awaiting handwriting conversion',
    () async {
      final recognition = _DeferredRecognition();
      final controller = _controllerWithSelectedStroke(
        documentId: 'ocr-stroke-race',
        recognition: recognition,
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });

      final source = controller.page.strokes.single;
      final conversion = controller.convertSelectedHandwritingToText();
      await recognition.started.future;
      controller.moveSelection(const Offset(80, 0));
      final moved = controller.page.strokeById(source.id)!;
      expect(moved, isNot(same(source)));
      recognition.complete('Veraltet');

      expect(await conversion, isFalse);
      expect(controller.page.strokeById(source.id), same(moved));
      expect(controller.page.objects, isEmpty);
      expect(controller.selectedIds, contains(source.id));
    },
  );

  test(
    'failed conversion command never leaves a stale text selection',
    () async {
      final recognition = _DeferredRecognition();
      final controller = _controllerWithSelectedStroke(
        documentId: 'ocr-command-failure',
        recognition: recognition,
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });

      final source = controller.page.strokes.single;
      final conversion = controller.convertSelectedHandwritingToText();
      await recognition.started.future;
      await controller.history.dispose();
      recognition.complete('Nicht gespeichert');

      expect(await conversion, isFalse);
      expect(controller.isHandwritingConversionInProgress, isFalse);
      expect(controller.page.strokeById(source.id), same(source));
      expect(controller.page.objects, isEmpty);
      expect(controller.selectedIds, <String>{source.id});
      expect(controller.lastError, isNotNull);
    },
  );

  test(
    'closing the controller safely invalidates pending recognition',
    () async {
      final recognition = _DeferredRecognition();
      final controller = _controllerWithSelectedStroke(
        documentId: 'ocr-close-race',
        recognition: recognition,
      );
      var disposed = false;
      addTearDown(() async {
        if (disposed) return;
        await controller.close();
        controller.dispose();
      });

      final source = controller.page.strokes.single;
      final conversion = controller.convertSelectedHandwritingToText();
      await recognition.started.future;
      await controller.close();
      controller.dispose();
      disposed = true;
      recognition.complete('Zu spät');

      expect(await conversion, isFalse);
      expect(controller.isHandwritingConversionInProgress, isFalse);
      expect(controller.page.strokeById(source.id), same(source));
      expect(controller.page.objects, isEmpty);
    },
  );

  test(
    'conversion uses one finite canonical stroke for OCR and layout',
    () async {
      final recognition = _DeferredRecognition();
      final base = WhiteboardDocument.create(id: 'ocr-finite-snapshot');
      final source = InkStroke(
        id: 'mixed-ink',
        width: double.infinity,
        points: const <InkPoint>[
          InkPoint(
            x: 100,
            y: 100,
            pressure: double.nan,
            tiltX: double.infinity,
            tiltY: double.negativeInfinity,
          ),
          InkPoint(x: double.nan, y: 112),
          InkPoint(x: 118, y: double.infinity),
          InkPoint(x: 10000001, y: 120),
          InkPoint(x: 164, y: 132, pressure: .7, tiltX: .2, tiltY: -.3),
        ],
      );
      final controller = EditorController(
        document: base.copyWith(
          pages: <BoardPage>[
            base.currentPage.copyWith(
              strokes: <InkStroke>[source],
              selection: SelectionState(
                selectedItemIds: const <String>['mixed-ink'],
              ),
            ),
          ],
        ),
        repository: _MemoryRepository(),
        assetDirectory: Directory.current,
        handwritingRecognition: recognition,
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });

      final conversion = controller.convertSelectedHandwritingToText();
      await recognition.started.future;
      final requestStroke = recognition.requests.single.strokes.single;
      expect(requestStroke.points, hasLength(2));
      expect(requestStroke.width, 4);
      expect(requestStroke.points.last, same(source.points.last));
      expect(
        requestStroke.points.every(
          (point) =>
              point.x.isFinite &&
              point.y.isFinite &&
              point.pressure.isFinite &&
              point.tiltX.isFinite &&
              point.tiltY.isFinite,
        ),
        isTrue,
      );
      recognition.complete('Sicher');

      expect(await conversion, isTrue);
      final converted = controller.page.objects.whereType<TextObject>().single;
      expect(
        <double>[
          converted.transform.x,
          converted.transform.y,
          converted.transform.width,
          converted.transform.height,
          converted.fontSize,
        ].every((value) => value.isFinite),
        isTrue,
      );
      expect(converted.transform.width, greaterThan(0));
      expect(converted.transform.height, greaterThan(0));
    },
  );

  test('active ink prevents handwriting conversion from starting', () async {
    final recognition = _DeferredRecognition();
    final controller = _controllerWithSelectedStroke(
      documentId: 'ocr-active-ink',
      recognition: recognition,
    );
    addTearDown(() async {
      controller.cancelInk(92);
      await controller.close();
      controller.dispose();
    });

    controller.clearSelection();
    expect(
      controller.beginInk(
        const PointerDownEvent(pointer: 92, position: Offset(200, 200)),
        const Offset(200, 200),
      ),
      isTrue,
    );
    controller.selectAll();

    expect(await controller.convertSelectedHandwritingToText(), isFalse);
    expect(recognition.recognizeCalls, 0);
    expect(controller.isHandwritingConversionInProgress, isFalse);
  });

  test(
    'legacy text frames migrate once without clipping or becoming undoable',
    () async {
      final base = WhiteboardDocument.create(
        id: 'legacy-text-layout',
        now: DateTime.utc(2026, 7, 1),
      );
      final legacy = TextObject.fromJson(<String, Object?>{
        'id': 'legacy-text',
        'transform': <String, Object?>{
          'x': 180,
          'y': 240,
          'width': 290,
          'height': 40,
          'rotationRadians': .35,
          'flipX': true,
          'flipY': false,
        },
        'text': 'Bestehender Text mit Verantwortungsübernahmedokumentation',
        'fontSize': 34,
        'colorArgb': 0xFF101010,
      });
      final anchor = ShapeObject(
        id: 'anchor',
        transform: const ObjectTransform(x: 40, y: 60, width: 50, height: 50),
        shape: ShapeKind.circle,
      );
      final repository = _MemoryRepository();
      final controller = EditorController(
        document: base.copyWith(
          revision: 7,
          pages: <BoardPage>[
            base.currentPage.copyWith(
              objects: <BoardObject>[legacy, anchor],
              contentGroups: <ContentGroup>[
                ContentGroup(
                  id: 'legacy-group',
                  memberIds: const <String>['legacy-text', 'anchor'],
                  bounds: const Rect2(left: 0, top: 0, width: 1, height: 1),
                ),
              ],
            ),
          ],
        ),
        repository: repository,
        assetDirectory: Directory.current,
      );

      final migrated = controller.page.objectById(legacy.id)! as TextObject;
      expect(legacy.textLayoutVersion, 1);
      expect(migrated.textLayoutVersion, TextObject.currentLayoutVersion);
      expect(migrated.transform.x, legacy.transform.x);
      expect(migrated.transform.y, legacy.transform.y);
      expect(
        migrated.transform.rotationRadians,
        legacy.transform.rotationRadians,
      );
      expect(migrated.transform.flipX, legacy.transform.flipX);
      expect(migrated.transform.flipY, legacy.transform.flipY);
      expect(
        migrated.transform.width,
        greaterThanOrEqualTo(legacy.transform.width),
      );
      expect(
        migrated.transform.height,
        greaterThanOrEqualTo(legacy.transform.height),
      );
      expect(controller.document.revision, 7);
      expect(controller.canUndo, isFalse);
      _expectVisibleTextFits(migrated);
      expect(
        controller.page.contentGroups.single.bounds,
        migrated.transform.bounds.union(anchor.transform.bounds),
      );

      await controller.autosave.flush();
      expect(repository.saved, hasLength(1));
      final persisted = repository.saved.single;
      final reopenedRepository = _MemoryRepository();
      final reopened = EditorController(
        document: persisted,
        repository: reopenedRepository,
        assetDirectory: Directory.current,
      );
      final reopenedText = reopened.page.objectById(legacy.id)! as TextObject;
      expect(reopenedText.transform, migrated.transform);
      expect(reopened.autosave.hasPendingChanges, isFalse);
      expect(reopened.canUndo, isFalse);

      await reopened.close();
      reopened.dispose();
      await controller.close();
      controller.dispose();
    },
  );

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
        handwritingRecognition: const _Recognition(
          'WWWWeitergeschriebenerAbschlussbericht',
        ),
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
      expect(edited.text, endsWith(' WWWWeitergeschriebenerAbschlussbericht'));
      expect(edited.transform.width, greaterThan(original.transform.width));
      _expectVisibleTextFits(edited);
      controller.undo();
      expect(
        (controller.page.objectById(original.id)! as TextObject).text,
        original.text,
      );
    },
  );

  test(
    'repeated handwriting append uses real metrics and never shrinks the box',
    () async {
      final base = WhiteboardDocument.create(id: 'inline-repeat-append');
      var original = _text('Projektstatus').copyWith(
        fontSize: 36,
        italic: true,
        transform: const ObjectTransform(
          x: 80,
          y: 120,
          width: 260,
          height: 64,
          rotationRadians: .2,
          flipX: true,
        ),
      );
      original = original.copyWith(
        transform: TextObjectLayout.fit(
          value: original,
          minimumObjectWidth: original.transform.width,
        ),
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
        handwritingRecognition: _RecognitionSequence(<String>[
          'WWWAbschlussdokumentation',
          'Qualitätssicherungsbericht',
        ]),
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
      });

      final firstWidth = original.transform.width;
      expect(
        await controller.applyInlineTextHandwriting(
          objectId: original.id,
          localStrokes: <List<Offset>>[_appendStrokeAfterCaret(original)],
        ),
        isTrue,
      );
      final firstAppend = controller.selectedTextObject!;
      expect(firstAppend.transform.width, greaterThanOrEqualTo(firstWidth));
      expect(
        firstAppend.transform.rotationRadians,
        original.transform.rotationRadians,
      );
      expect(firstAppend.transform.flipX, isTrue);
      _expectVisibleTextFits(firstAppend);

      expect(
        await controller.applyInlineTextHandwriting(
          objectId: original.id,
          localStrokes: <List<Offset>>[_appendStrokeAfterCaret(firstAppend)],
        ),
        isTrue,
      );
      final secondAppend = controller.selectedTextObject!;
      expect(
        secondAppend.text,
        'Projektstatus WWWAbschlussdokumentation Qualitätssicherungsbericht',
      );
      expect(
        secondAppend.transform.width,
        greaterThanOrEqualTo(firstAppend.transform.width),
      );
      _expectVisibleTextFits(secondAppend);
    },
  );

  testWidgets(
    'board text rendering is independent from theme metrics at every zoom',
    (tester) async {
      var value = _text(
        'Breiter Abschlusstext mit Verantwortungsübernahmedokumentation',
      ).copyWith(fontSize: 42, bold: true, italic: true);
      value = value.copyWith(
        transform: TextObjectLayout.fit(value: value, maximumWidth: 520),
      );

      for (final scale in const <double>[.55, 1, 2]) {
        await tester.pumpWidget(
          MaterialApp(
            home: DefaultTextStyle(
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 9,
                letterSpacing: 18,
                wordSpacing: 24,
                height: 2.8,
              ),
              child: SizedBox(
                width: 800,
                height: 600,
                child: BoardObjectLayer(
                  objects: <BoardObject>[value],
                  annotationLayers: const <ObjectInkLayer>[],
                  scale: scale,
                  offset: Offset.zero,
                  assets: const _NoAssets(),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final paint = tester.widget<CustomPaint>(
          find.byKey(ValueKey<String>('board-text-${value.id}')),
        );
        final painter = paint.painter! as BoardTextPainter;
        expect(painter.text.text, value.text);
        expect(painter.displayScale, scale);
        expect(
          find.descendant(
            of: find.byKey(ValueKey<String>('board-object-${value.id}')),
            matching: find.text(value.text),
          ),
          findsNothing,
        );

        final recorder = ui.PictureRecorder();
        painter.paint(
          Canvas(recorder),
          Size(value.transform.width * scale, value.transform.height * scale),
        );
        recorder.endRecording().dispose();
        expect(tester.takeException(), isNull);
      }
    },
  );
}

void _expectVisibleTextFits(TextObject value) {
  final insets = TextObjectLayout.contentInsetsFor(value);
  final contentWidth = value.transform.width - insets.horizontal;
  final painter = TextObjectLayout.createPainter(value)
    ..layout(maxWidth: contentWidth);
  final x = switch (value.alignment) {
    BoardTextAlign.left => insets.left,
    BoardTextAlign.center => insets.left + contentWidth / 2 - painter.width / 2,
    BoardTextAlign.right =>
      value.transform.width - insets.right - painter.width,
  };
  final lastWord = RegExp(r'\S+').allMatches(value.text).last;
  final boxes = painter.getBoxesForSelection(
    TextSelection(baseOffset: lastWord.start, extentOffset: lastWord.end),
  );
  expect(boxes, isNotEmpty);
  for (final box in boxes) {
    expect(x + box.left, greaterThanOrEqualTo(insets.left - .5));
    expect(
      x + box.right,
      lessThanOrEqualTo(value.transform.width - insets.right + .5),
    );
    expect(insets.top + box.top, greaterThanOrEqualTo(insets.top - .5));
    expect(
      insets.top + box.bottom,
      lessThanOrEqualTo(value.transform.height - insets.bottom + .5),
    );
  }
  expect(
    painter.height + insets.vertical,
    lessThanOrEqualTo(value.transform.height + .5),
  );
  painter.dispose();
}

List<Offset> _appendStrokeAfterCaret(TextObject value) {
  final insets = TextObjectLayout.contentInsetsFor(value);
  final painter = TextObjectLayout.createPainter(value)
    ..layout(maxWidth: value.transform.width - insets.horizontal);
  final caret =
      painter.getOffsetForCaret(
        TextPosition(offset: value.text.length),
        Rect.zero,
      ) +
      Offset(insets.left, insets.top);
  painter.dispose();
  final start = Offset(
    caret.dx + math.max(8, value.fontSize * .2),
    caret.dy + value.fontSize * .4,
  );
  return <Offset>[
    start,
    start + Offset(value.fontSize * .7, value.fontSize * .35),
    start + Offset(value.fontSize * 1.4, -.1 * value.fontSize),
  ];
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

final class _RecognitionSequence implements HandwritingRecognitionService {
  _RecognitionSequence(Iterable<String> values)
    : _values = values.toList(growable: true);

  final List<String> _values;

  @override
  Future<bool> isAvailable() async => _values.isNotEmpty;

  @override
  Future<HandwritingRecognitionResult> recognize(
    HandwritingRecognitionRequest request,
  ) async => HandwritingRecognitionResult(text: _values.removeAt(0));
}

final class _DeferredRecognition implements HandwritingRecognitionService {
  final Completer<void> started = Completer<void>();
  final Completer<HandwritingRecognitionResult> _result =
      Completer<HandwritingRecognitionResult>();
  final List<HandwritingRecognitionRequest> requests =
      <HandwritingRecognitionRequest>[];
  int recognizeCalls = 0;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<HandwritingRecognitionResult> recognize(
    HandwritingRecognitionRequest request,
  ) {
    recognizeCalls++;
    requests.add(request);
    if (!started.isCompleted) started.complete();
    return _result.future;
  }

  void complete(String text) {
    if (!_result.isCompleted) {
      _result.complete(HandwritingRecognitionResult(text: text));
    }
  }

  void fail(Object error, [StackTrace? stackTrace]) {
    if (!_result.isCompleted) {
      _result.completeError(error, stackTrace ?? StackTrace.current);
    }
  }
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
  final List<WhiteboardDocument> saved = <WhiteboardDocument>[];

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
  Future<void> save(WhiteboardDocument document) async => saved.add(document);
}

final class _NoAssets implements BoardAssetResolver {
  const _NoAssets();

  @override
  String? localPath(String assetId) => null;

  @override
  Future<Uint8List?> readBytes(String assetId) async => null;
}

EditorController _controllerWithSelectedStroke({
  required String documentId,
  required HandwritingRecognitionService recognition,
  VoidCallback? debugBeforeHandwritingSnapshotCapture,
}) {
  final base = WhiteboardDocument.create(id: documentId);
  final stroke = InkStroke(
    id: 'ink',
    width: 8,
    points: const <InkPoint>[
      InkPoint(x: 100, y: 100),
      InkPoint(x: 132, y: 118),
    ],
  );
  return EditorController(
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
    handwritingRecognition: recognition,
    debugBeforeHandwritingSnapshotCapture:
        debugBeforeHandwritingSnapshotCapture,
  );
}
