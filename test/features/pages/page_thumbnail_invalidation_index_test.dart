import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/pages/page_thumbnail_invalidation_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final timestamp = DateTime.utc(2026, 7, 28);

  test('one stroke invalidates only its page in a large document', () {
    final index = PageThumbnailInvalidationIndex();
    final document = _document(
      timestamp,
      pages: List<BoardPage>.generate(
        100,
        (page) => BoardPage.empty(id: 'page-$page', name: 'Seite ${page + 1}'),
      ),
    );

    final initial = index.synchronize(document);
    expect(initial.dirtyPageIds, hasLength(100));
    final stableRevision = index.revisionFor('page-99');

    final pages = document.pages.toList(growable: false);
    pages[42] = pages[42].copyWith(
      strokes: <InkStroke>[
        InkStroke(
          id: 'new-stroke',
          points: const <InkPoint>[InkPoint(x: 1, y: 2), InkPoint(x: 3, y: 4)],
        ),
      ],
    );
    final changed = index.synchronize(document.copyWith(pages: pages));

    expect(changed.dirtyPageIds, const <String>{'page-42'});
    expect(changed.removedPageIds, isEmpty);
    expect(index.revisionFor('page-99'), stableRevision);
  });

  test('normal page replacement inspects one page instead of all 100', () {
    final index = PageThumbnailInvalidationIndex();
    final document = _document(
      timestamp,
      pages: List<BoardPage>.generate(
        100,
        (page) => BoardPage.empty(id: 'page-$page', name: 'Seite ${page + 1}'),
      ),
    );
    index.synchronize(document);
    expect(index.debugPageInspectionCount, 100);

    final sourcePage = document.pages[67];
    final changedDocument = document.replacePage(
      sourcePage.copyWith(
        strokes: <InkStroke>[
          InkStroke(
            id: 'single-append',
            points: const <InkPoint>[
              InkPoint(x: 12, y: 18),
              InkPoint(x: 30, y: 26),
            ],
          ),
        ],
      ),
      now: timestamp,
    );
    final changed = index.synchronize(changedDocument);

    expect(changed.dirtyPageIds, const <String>{'page-67'});
    expect(index.debugPageInspectionCount, 101);
    final replacementPages =
        changedDocument.pages as SingleReplacementModelList<BoardPage>;
    expect(replacementPages.singleReplacementIndexFrom(document.pages), 67);
    expect(document.pages[67].strokes, isEmpty);
    expect(changedDocument.pages[67].strokes, hasLength(1));
    expect(changedDocument.pageIndexById('page-67'), 67);
    expect(changedDocument.pageIndexById('missing'), isNull);
    expect(
      () => changedDocument.pages[67] = sourcePage,
      throwsUnsupportedError,
    );
  });

  test('viewport, selection, navigation and metadata do not rerender', () {
    final index = PageThumbnailInvalidationIndex();
    final page = BoardPage.empty(id: 'page');
    final document = _document(timestamp, pages: <BoardPage>[page]);
    index.synchronize(document);

    final viewportOnly = page.copyWith(
      viewport: const ViewportState(offsetX: 40, offsetY: 20, zoom: 2),
      selection: SelectionState(
        selectedItemIds: const <String>[],
        mode: SelectionMode.lasso,
      ),
    );
    final changed = index.synchronize(
      document.copyWith(
        pages: <BoardPage>[viewportOnly],
        metadata: document.metadata.copyWith(
          custom: const <String, String>{'radialMenuX': '.4'},
        ),
        revision: 2,
      ),
    );

    expect(changed.isEmpty, isTrue);
  });

  test('only pages referencing a materially changed asset invalidate', () {
    final index = PageThumbnailInvalidationIndex();
    final imageAsset = _asset(timestamp, id: 'image', sha256: 'old');
    final unrelated = _asset(timestamp, id: 'unrelated', sha256: 'same');
    final imagePage = BoardPage(
      id: 'image-page',
      name: 'Bild',
      objects: <BoardObject>[
        ImageObject(
          id: 'image-object',
          transform: const ObjectTransform(x: 0, y: 0, width: 400, height: 300),
          assetId: imageAsset.id,
        ),
      ],
    );
    final plainPage = BoardPage.empty(id: 'plain-page');
    final document = _document(
      timestamp,
      pages: <BoardPage>[imagePage, plainPage],
      assets: <DocumentAsset>[imageAsset],
    );
    index.synchronize(document);

    final unrelatedAdded = index.synchronize(
      document.copyWith(assets: <DocumentAsset>[imageAsset, unrelated]),
    );
    expect(unrelatedAdded.isEmpty, isTrue);

    final assetChanged = index.synchronize(
      document.copyWith(
        assets: <DocumentAsset>[
          _asset(timestamp, id: 'image', sha256: 'new'),
          unrelated,
        ],
      ),
    );
    expect(assetChanged.dirtyPageIds, const <String>{'image-page'});
  });

  test('removed pages lose their revision without dirtying survivors', () {
    final index = PageThumbnailInvalidationIndex();
    final document = _document(
      timestamp,
      pages: <BoardPage>[
        BoardPage.empty(id: 'keep'),
        BoardPage.empty(id: 'remove'),
      ],
    );
    index.synchronize(document);

    final changed = index.synchronize(
      document.copyWith(
        pages: <BoardPage>[document.pages.first],
        currentPageIndex: 0,
      ),
    );

    expect(changed.dirtyPageIds, isEmpty);
    expect(changed.removedPageIds, const <String>{'remove'});
    expect(index.revisionFor('remove'), isNull);
    expect(index.revisionFor('keep'), isNotNull);
  });
}

WhiteboardDocument _document(
  DateTime timestamp, {
  required List<BoardPage> pages,
  List<DocumentAsset> assets = const <DocumentAsset>[],
}) => WhiteboardDocument(
  id: 'document',
  title: 'Test',
  createdAt: timestamp,
  updatedAt: timestamp,
  pages: pages,
  assets: assets,
);

DocumentAsset _asset(
  DateTime timestamp, {
  required String id,
  required String sha256,
}) => DocumentAsset(
  id: id,
  type: DocumentAssetType.image,
  relativePath: 'assets/$id.png',
  mimeType: 'image/png',
  byteLength: 100,
  sha256: sha256,
  createdAt: timestamp,
);
