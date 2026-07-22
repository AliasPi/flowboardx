import 'dart:convert';
import 'dart:io';

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/domain/serialization/document_codec.dart';
import 'package:flowboard_x/src/features/board/engine/input_policy.dart';
import 'package:flowboard_x/src/features/editor/editor_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PDF import placement', () {
    test('bundled pages create one undoable multi-page object', () async {
      final fixture = await _Fixture.create('bundled');
      addTearDown(fixture.dispose);

      await fixture.controller.importPdf(
        fixture.source.path,
        mode: PdfImportMode.pageRange,
        placement: PdfPlacementMode.bundledObject,
        pageIndices: const <int>[4, 0, 2, 2],
      );

      expect(fixture.controller.document.assets, hasLength(1));
      final pdf = fixture.controller.page.objects.single as PdfObject;
      expect(pdf.pageIndices, const <int>[0, 2, 4]);
      expect(pdf.importMode, PdfImportMode.pageRange);
      expect(pdf.placementMode, PdfPlacementMode.bundledObject);
      expect(fixture.controller.tool, BoardTool.selectRectangle);
      expect(fixture.controller.selectedIds, <String>{pdf.id});

      fixture.controller.undo();
      expect(fixture.controller.page.objects, isEmpty);
      expect(fixture.controller.document.assets, isEmpty);
      fixture.controller.redo();
      expect(fixture.controller.page.objects, hasLength(1));
      expect(fixture.controller.document.assets, hasLength(1));
    });

    test('separate placement creates one object per selected page', () async {
      final fixture = await _Fixture.create('separate');
      addTearDown(fixture.dispose);

      await fixture.controller.importPdf(
        fixture.source.path,
        mode: PdfImportMode.pageRange,
        placement: PdfPlacementMode.separateObjects,
        pageIndices: const <int>[1, 3, 7],
      );

      final pdfs = fixture.controller.page.objects.whereType<PdfObject>();
      expect(pdfs, hasLength(3));
      expect(pdfs.map((pdf) => pdf.pageIndices.single), const <int>[1, 3, 7]);
      expect(pdfs.map((pdf) => pdf.placementMode).toSet(), <PdfPlacementMode>{
        PdfPlacementMode.separateObjects,
      });
      expect(pdfs.map((pdf) => pdf.importMode).toSet(), <PdfImportMode>{
        PdfImportMode.singlePage,
      });
      expect(fixture.controller.tool, BoardTool.selectRectangle);
      expect(fixture.controller.selectedIds, pdfs.map((pdf) => pdf.id).toSet());
      final restored = const DocumentCodec().decode(
        const DocumentCodec().encode(fixture.controller.document),
      );
      expect(
        restored.currentPage.objects
            .whereType<PdfObject>()
            .map((pdf) => pdf.placementMode)
            .toSet(),
        <PdfPlacementMode>{PdfPlacementMode.separateObjects},
      );
    });

    test(
      'the same source can be imported repeatedly as independent assets',
      () async {
        final fixture = await _Fixture.create('repeat-same-file');
        addTearDown(fixture.dispose);

        await fixture.controller.importPdf(
          fixture.source.path,
          placement: PdfPlacementMode.bundledObject,
          pageIndices: const <int>[0],
        );
        await fixture.controller.importPdf(
          fixture.source.path,
          placement: PdfPlacementMode.bundledObject,
          pageIndices: const <int>[0],
        );

        final pdfs = fixture.controller.page.objects
            .whereType<PdfObject>()
            .toList();
        expect(pdfs, hasLength(2));
        expect(pdfs.map((pdf) => pdf.assetId).toSet(), hasLength(2));
        expect(fixture.controller.document.assets, hasLength(2));
        for (final asset in fixture.controller.document.assets) {
          expect(
            await File(
              fixture.controller.assetResolver.localPath(asset.id)!,
            ).exists(),
            isTrue,
          );
        }

        fixture.controller.undo();
        expect(
          fixture.controller.page.objects.whereType<PdfObject>(),
          hasLength(1),
        );
        fixture.controller.redo();
        expect(
          fixture.controller.page.objects.whereType<PdfObject>(),
          hasLength(2),
        );
      },
    );

    test(
      'large separate imports stay inside the writable export world',
      () async {
        final fixture = await _Fixture.create('separate-large');
        addTearDown(fixture.dispose);

        await fixture.controller.importPdf(
          fixture.source.path,
          mode: PdfImportMode.pageRange,
          placement: PdfPlacementMode.separateObjects,
          pageIndices: List<int>.generate(100, (index) => index),
        );

        final world = fixture.controller.viewport.worldBounds;
        final pdfs = fixture.controller.page.objects.whereType<PdfObject>();
        expect(pdfs, hasLength(100));
        for (final pdf in pdfs) {
          final bounds = pdf.transform.bounds;
          expect(bounds.left, greaterThanOrEqualTo(world.left - .001));
          expect(bounds.top, greaterThanOrEqualTo(world.top - .001));
          expect(bounds.right, lessThanOrEqualTo(world.right + .001));
          expect(bounds.bottom, lessThanOrEqualTo(world.bottom + .001));
        }
      },
    );

    test(
      'new-page placement creates one whiteboard page per PDF page',
      () async {
        final fixture = await _Fixture.create('pages');
        addTearDown(fixture.dispose);

        await fixture.controller.importPdf(
          fixture.source.path,
          mode: PdfImportMode.pageRange,
          placement: PdfPlacementMode.newWhiteboardPages,
          pageIndices: const <int>[2, 5],
        );

        expect(fixture.controller.document.pages, hasLength(3));
        final imported = fixture.controller.document.pages.skip(1).toList();
        expect(imported.map((page) => page.name), <String>[
          'PDF-Seite 3',
          'PDF-Seite 6',
        ]);
        expect(
          imported.map(
            (page) => (page.objects.single as PdfObject).pageIndices.single,
          ),
          const <int>[2, 5],
        );
        expect(fixture.controller.document.currentPageIndex, 2);
        expect(fixture.controller.tool, BoardTool.selectRectangle);
        expect(fixture.controller.selectedIds, <String>{
          fixture.controller.page.objects.single.id,
        });

        fixture.controller.undo();
        expect(fixture.controller.document.pages, hasLength(1));
        expect(fixture.controller.document.assets, isEmpty);
      },
    );

    test('page-limit rejection happens before copying the PDF asset', () async {
      final fixture = await _Fixture.create('page-limit');
      addTearDown(fixture.dispose);
      for (var index = 1; index < WhiteboardDocument.maxPageCount; index++) {
        fixture.controller.addPage();
      }

      await expectLater(
        fixture.controller.importPdf(
          fixture.source.path,
          placement: PdfPlacementMode.newWhiteboardPages,
          pageIndices: const <int>[0],
        ),
        throwsStateError,
      );

      expect(fixture.controller.document.pages, hasLength(100));
      expect(fixture.controller.document.assets, isEmpty);
      expect(await fixture.controller.assetDirectory.list().toList(), isEmpty);
    });
  });

  test('cancel path restores the configured pen instead of rectangle', () {
    final controller = EditorController(
      document: WhiteboardDocument.create(id: 'pdf-cancel'),
      repository: _TestRepository(Directory.current),
      assetDirectory: Directory.current,
    );
    addTearDown(() async {
      await controller.close();
      controller.dispose();
    });
    controller.updatePen(type: InkToolType.marker, width: 18);
    controller.armShape(ShapeKind.rectangle);

    // This is the restoration used immediately before both PDF dialogs. A
    // cancelled file picker or preview therefore leaves this state intact.
    controller.resumeConfiguredInkTool();

    expect(controller.tool, BoardTool.marker);
    expect(controller.penStyle.type, InkToolType.marker);
    expect(controller.penStyle.width, 18);
  });

  test('bundled PDF annotations follow their active source page', () async {
    final base = WhiteboardDocument.create(id: 'pdf-annotation');
    final pdf = PdfObject(
      id: 'pdf',
      transform: const ObjectTransform(x: 100, y: 200, width: 400, height: 200),
      assetId: 'asset',
      pageIndices: const <int>[2, 5],
      importMode: PdfImportMode.pageRange,
    );
    final controller = EditorController(
      document: base.copyWith(
        pages: <BoardPage>[
          base.currentPage.copyWith(objects: <BoardObject>[pdf]),
        ],
      ),
      repository: _TestRepository(Directory.current),
      assetDirectory: Directory.current,
    );
    addTearDown(() async {
      await controller.close();
      controller.dispose();
    });

    _writeStroke(controller, pointer: 1, start: const Offset(160, 240));
    final firstLayer = controller.page.annotationFor(pdf.id, pdfPageIndex: 2);
    expect(firstLayer, isNotNull);
    expect(firstLayer!.pdfPageIndex, 2);
    expect(
      activeObjectInkLayer(
        controller.selectedPdf ?? pdf,
        controller.page.annotationLayers,
      ),
      firstLayer,
    );

    controller.setPdfActivePage(pdf.id, 1);
    final pageFivePdf = controller.page.objectById(pdf.id)! as PdfObject;
    expect(pageFivePdf.activeSourcePageIndex, 5);
    expect(
      activeObjectInkLayer(pageFivePdf, controller.page.annotationLayers),
      isNull,
    );
    _writeStroke(controller, pointer: 2, start: const Offset(220, 260));
    final secondLayer = controller.page.annotationFor(pdf.id, pdfPageIndex: 5);
    expect(secondLayer, isNotNull);
    expect(secondLayer, isNot(same(firstLayer)));
    expect(
      activeObjectInkLayer(
        controller.page.objectById(pdf.id)!,
        controller.page.annotationLayers,
      ),
      same(secondLayer),
    );

    controller.setPdfActivePage(pdf.id, 0);
    expect(
      activeObjectInkLayer(
        controller.page.objectById(pdf.id)!,
        controller.page.annotationLayers,
      ),
      isNotNull,
    );
    expect(
      activeObjectInkLayer(
        controller.page.objectById(pdf.id)!,
        controller.page.annotationLayers,
      )!.pdfPageIndex,
      2,
    );
    expect(
      activeObjectInkLayer(
        controller.page.objectById(pdf.id)!,
        controller.page.annotationLayers,
      )!.strokes.single.id,
      firstLayer.strokes.single.id,
    );

    const codec = DocumentCodec();
    final restored = codec.decode(codec.encode(controller.document));
    expect(restored.currentPage.annotationLayers, hasLength(2));
    expect(
      restored.currentPage.annotationLayers.map((layer) => layer.pdfPageIndex),
      unorderedEquals(<int>[2, 5]),
    );

    controller.undo(); // active page switch
    controller.undo(); // second-page stroke
    expect(controller.page.annotationFor(pdf.id, pdfPageIndex: 5), isNull);
    expect(controller.page.annotationFor(pdf.id, pdfPageIndex: 2), isNotNull);
  });

  test('schema 3 PDF ink migrates to the formerly active source page', () {
    final now = DateTime.utc(2026, 7, 22).toIso8601String();
    final source = jsonEncode(<String, Object?>{
      'schemaVersion': 3,
      'id': 'legacy-pdf',
      'title': 'Legacy PDF',
      'createdAt': now,
      'updatedAt': now,
      'currentPageIndex': 0,
      'pages': <Object?>[
        <String, Object?>{
          'id': 'page',
          'name': 'Seite',
          'objects': <Object?>[
            <String, Object?>{
              'id': 'pdf',
              'type': 'pdf',
              'assetId': 'asset',
              'pageIndices': <int>[1, 4],
              'activePageIndex': 1,
              'transform': <String, Object?>{
                'x': 0,
                'y': 0,
                'width': 100,
                'height': 100,
              },
            },
          ],
          'annotationLayers': <Object?>[
            <String, Object?>{
              'id': 'legacy-ink',
              'objectId': 'pdf',
              'strokes': <Object?>[],
              'visible': true,
            },
          ],
        },
      ],
    });

    final restored = const DocumentCodec().decode(source);
    final pdf = restored.currentPage.objects.single as PdfObject;
    final layer = restored.currentPage.annotationLayers.single;
    expect(pdf.placementMode, PdfPlacementMode.bundledObject);
    expect(layer.pdfPageIndex, 4);
  });
}

void _writeStroke(
  EditorController controller, {
  required int pointer,
  required Offset start,
}) {
  final down = PointerDownEvent(
    pointer: pointer,
    device: 8,
    position: start,
    kind: PointerDeviceKind.stylus,
  );
  final move = PointerMoveEvent(
    pointer: pointer,
    device: 8,
    position: start + const Offset(50, 30),
    kind: PointerDeviceKind.stylus,
  );
  final up = PointerUpEvent(
    pointer: pointer,
    device: 8,
    position: start + const Offset(100, 50),
    kind: PointerDeviceKind.stylus,
  );
  expect(controller.beginInk(down, start), isTrue);
  controller.updateInk(move, move.position);
  controller.endInk(up, up.position);
}

final class _Fixture {
  _Fixture({
    required this.directory,
    required this.source,
    required this.controller,
  });

  final Directory directory;
  final File source;
  final EditorController controller;

  static Future<_Fixture> create(String suffix) async {
    final directory = await Directory.systemTemp.createTemp(
      'flowboard-pdf-$suffix-',
    );
    final assets = Directory(
      '${directory.path}${Platform.pathSeparator}assets',
    );
    await assets.create();
    final source = File(
      '${directory.path}${Platform.pathSeparator}source-$suffix.pdf',
    );
    await source.writeAsBytes('%PDF-1.7\nfixture'.codeUnits, flush: true);
    final repository = _TestRepository(assets);
    final controller = EditorController(
      document: WhiteboardDocument.create(id: 'pdf-$suffix'),
      repository: repository,
      assetDirectory: assets,
    );
    return _Fixture(
      directory: directory,
      source: source,
      controller: controller,
    );
  }

  Future<void> dispose() async {
    await controller.close();
    controller.dispose();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

final class _TestRepository implements DocumentRepository {
  _TestRepository(this.directory);

  final Directory directory;
  WhiteboardDocument? saved;

  @override
  Future<void> save(WhiteboardDocument document) async => saved = document;

  @override
  Future<WhiteboardDocument?> load(String documentId) async => saved;

  @override
  Future<WhiteboardDocument?> recover(String documentId) async => saved;

  @override
  Future<List<DocumentSummary>> list() async => const <DocumentSummary>[];

  @override
  Future<void> delete(String documentId) async => saved = null;

  @override
  Future<Directory> assetDirectory(String documentId) async => directory;
}
