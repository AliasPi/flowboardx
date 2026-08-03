import 'dart:io';

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/commands/document_commands.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/editor/editor_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('annotation eraser queries only spatially local strokes', () async {
    final base = WhiteboardDocument.create(id: 'annotation-index-locality');
    final objects = <BoardObject>[];
    final layers = <ObjectInkLayer>[];
    for (var index = 0; index < 240; index++) {
      final id = 'image-$index';
      objects.add(
        ImageObject(
          id: id,
          assetId: 'asset',
          transform: ObjectTransform(
            x: index * 400.0,
            y: 100,
            width: 100,
            height: 100,
          ),
        ),
      );
      layers.add(
        ObjectInkLayer(
          id: 'layer-$index',
          objectId: id,
          strokes: <InkStroke>[
            InkStroke(
              id: 'annotation-$index',
              points: const <InkPoint>[
                InkPoint(x: .1, y: .5),
                InkPoint(x: .9, y: .5),
              ],
              width: .04,
            ),
          ],
        ),
      );
    }
    final controller = _controller(
      base.copyWith(
        pages: <BoardPage>[
          base.currentPage.copyWith(objects: objects, annotationLayers: layers),
        ],
      ),
    );
    addTearDown(() => _dispose(controller));

    controller.eraseAt(const Offset(50, 150), radius: 8);

    expect(controller.debugIndexedAnnotationStrokeCount, 240);
    expect(controller.debugLastEraseAnnotationCandidateCount, 1);
    final preview = controller.renderAnnotationLayers;
    expect(preview.first.strokes, hasLength(2));
    expect(controller.renderAnnotationLayers, same(preview));
    expect(controller.renderStrokes, same(controller.page.strokes));
    expect(
      preview.skip(1),
      everyElement(
        predicate<ObjectInkLayer>(
          (layer) => layer.strokes.length == 1,
          'keeps every remote layer untouched',
        ),
      ),
    );
  });

  test(
    'erase render previews are reused until their revision changes',
    () async {
      final base = WhiteboardDocument.create(id: 'eraser-preview-cache');
      final strokes = <InkStroke>[
        InkStroke(
          id: 'target',
          points: const <InkPoint>[
            InkPoint(x: 100, y: 100),
            InkPoint(x: 500, y: 100),
          ],
          width: 8,
        ),
        for (var index = 0; index < 200; index++)
          InkStroke(
            id: 'remote-$index',
            points: <InkPoint>[
              InkPoint(x: 100, y: 1000.0 + index * 20),
              InkPoint(x: 500, y: 1000.0 + index * 20),
            ],
            width: 8,
          ),
      ];
      final controller = _controller(
        base.copyWith(
          pages: <BoardPage>[base.currentPage.copyWith(strokes: strokes)],
        ),
      );
      addTearDown(() => _dispose(controller));

      controller.eraseAt(const Offset(200, 100), radius: 12);
      final firstPreview = controller.renderStrokes;
      final repeatedPreview = controller.renderStrokes;

      expect(repeatedPreview, same(firstPreview));
      expect(
        controller.renderAnnotationLayers,
        same(controller.page.annotationLayers),
      );

      controller.eraseAt(const Offset(400, 100), radius: 12);
      final changedPreview = controller.renderStrokes;
      expect(changedPreview, isNot(same(firstPreview)));
      expect(controller.renderStrokes, same(changedPreview));

      controller.cancelErase();
      expect(controller.renderStrokes, same(controller.page.strokes));
    },
  );

  test(
    'top-level append extends an existing erase index incrementally',
    () async {
      final base = WhiteboardDocument.create(id: 'eraser-append-index');
      var page = base.currentPage;
      for (var index = 0; index < 1200; index++) {
        page = page.appendTopLevelStroke(
          InkStroke(
            id: 'existing-$index',
            points: <InkPoint>[
              InkPoint(x: index * 10.0, y: 100),
              InkPoint(x: index * 10.0 + 4, y: 100),
            ],
            zIndex: index,
          ),
        );
      }
      final initial = base.copyWith(pages: <BoardPage>[page]);
      final controller = _controller(initial);
      addTearDown(() => _dispose(controller));

      controller.eraseAt(const Offset(-200, -200), radius: 2);
      controller.cancelErase();
      expect(controller.debugEraseFullIndexBuildCount, 1);

      controller.execute(
        AddStrokeCommand(
          controller.page.id,
          InkStroke(
            id: 'appended',
            points: const <InkPoint>[
              InkPoint(x: 300, y: 800),
              InkPoint(x: 360, y: 800),
            ],
          ),
        ),
      );
      controller.eraseAt(const Offset(330, 800), radius: 4);

      expect(controller.debugEraseFullIndexBuildCount, 1);
      expect(controller.debugLastEraseStrokeCandidateCount, 1);
    },
  );

  test('sparse stroke preview preserves several deletions in order', () async {
    final base = WhiteboardDocument.create(id: 'sparse-eraser-order');
    final strokes = <InkStroke>[
      for (var index = 0; index < 5; index++)
        InkStroke(
          id: 'stroke-$index',
          points: <InkPoint>[InkPoint(x: 100.0 + index * 100, y: 100)],
          width: 4,
        ),
    ];
    final controller = _controller(
      base.copyWith(
        pages: <BoardPage>[base.currentPage.copyWith(strokes: strokes)],
      ),
    );
    addTearDown(() => _dispose(controller));

    controller.eraseSweeps(const <InkEraserSweep>[
      (start: Offset(100, 100), end: Offset(100, 100), radius: 8),
      (start: Offset(300, 100), end: Offset(300, 100), radius: 8),
      (start: Offset(500, 100), end: Offset(500, 100), radius: 8),
    ]);
    final preview = controller.renderStrokes;

    expect(preview.map((stroke) => stroke.id), <String>[
      'stroke-1',
      'stroke-3',
    ]);
    expect(preview[0].id, 'stroke-1');
    expect(preview[1].id, 'stroke-3');
    expect(() => preview[2], throwsRangeError);
  });

  test(
    'annotation index invalidates when an object transform changes',
    () async {
      final base = WhiteboardDocument.create(
        id: 'annotation-index-invalidation',
      );
      final image = ImageObject(
        id: 'image',
        assetId: 'asset',
        transform: const ObjectTransform(
          x: 100,
          y: 100,
          width: 100,
          height: 100,
        ),
      );
      final layer = ObjectInkLayer(
        id: 'layer',
        objectId: image.id,
        strokes: <InkStroke>[
          InkStroke(
            id: 'annotation',
            points: const <InkPoint>[
              InkPoint(x: .1, y: .5),
              InkPoint(x: .9, y: .5),
            ],
            width: .04,
          ),
        ],
      );
      final initialPage = base.currentPage.copyWith(
        objects: <BoardObject>[image],
        annotationLayers: <ObjectInkLayer>[layer],
      );
      final controller = _controller(
        base.copyWith(pages: <BoardPage>[initialPage]),
      );
      addTearDown(() => _dispose(controller));

      // Build the first index without changing the preview.
      controller.eraseAt(const Offset(50, 50), radius: 4);
      controller.cancelErase();

      final moved = image.copyWithTransform(
        const ObjectTransform(x: 1000, y: 100, width: 100, height: 100),
      );
      controller.execute(
        ReplacePageCommand(initialPage.copyWith(objects: <BoardObject>[moved])),
      );
      controller.eraseAt(const Offset(1050, 150), radius: 8);

      expect(controller.debugLastEraseAnnotationCandidateCount, 1);
      expect(controller.renderAnnotationLayers.single.strokes, hasLength(2));
    },
  );
}

EditorController _controller(WhiteboardDocument document) => EditorController(
  document: document,
  repository: _MemoryRepository(),
  assetDirectory: Directory.current,
);

Future<void> _dispose(EditorController controller) async {
  await controller.close();
  controller.dispose();
}

final class _MemoryRepository implements DocumentRepository {
  WhiteboardDocument? document;

  @override
  Future<void> delete(String documentId) async {
    if (document?.id == documentId) document = null;
  }

  @override
  Future<Directory> assetDirectory(String documentId) async =>
      Directory.current;

  @override
  Future<List<DocumentSummary>> list() async => document == null
      ? const <DocumentSummary>[]
      : <DocumentSummary>[DocumentSummary.fromDocument(document!)];

  @override
  Future<WhiteboardDocument?> load(String documentId) async =>
      document?.id == documentId ? document : null;

  @override
  Future<WhiteboardDocument?> recover(String documentId) => load(documentId);

  @override
  Future<void> save(WhiteboardDocument document) async {
    this.document = document;
  }
}
