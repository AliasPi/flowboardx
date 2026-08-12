import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/data/file_document_repository.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/editor/selected_pages_document_creator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late Directory sourceAssets;
  late FileDocumentRepository repository;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('flowboard-pages-copy-');
    sourceAssets = Directory(p.join(temporary.path, 'source-assets'));
    await sourceAssets.create(recursive: true);
    repository = FileDocumentRepository(
      Directory(p.join(temporary.path, 'library')),
      useBackgroundIsolate: false,
    );
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'copies ordered pages with fresh identities and only referenced assets',
    () async {
      final image = await _asset(sourceAssets, 'image', <int>[1, 2, 3]);
      final pdf = await _asset(sourceAssets, 'pdf', <int>[4, 5, 6, 7]);
      final thumbnail = await _asset(sourceAssets, 'thumbnail', <int>[8, 9]);
      final unused = await _asset(sourceAssets, 'unused', <int>[10, 11]);
      final stroke = InkStroke(
        id: 'stroke-source',
        points: const <InkPoint>[InkPoint(x: 1, y: 2), InkPoint(x: 3, y: 4)],
        pointerId: 42,
      );
      final text = TextObject(
        id: 'text-source',
        transform: _transform,
        text: 'Erkannt',
        sourceStrokeIds: <String>[stroke.id],
      );
      final imageObject = ImageObject(
        id: 'image-source',
        transform: _transform,
        assetId: image.id,
      );
      final pdfObject = PdfObject(
        id: 'pdf-source',
        transform: _transform,
        assetId: pdf.id,
        pageIndices: const <int>[2, 4],
        activePageIndex: 1,
      );
      final first = BoardPage(
        id: 'page-first',
        name: 'Erste Quellseite',
        strokes: <InkStroke>[stroke],
        objects: <BoardObject>[text, imageObject],
        annotationLayers: <ObjectInkLayer>[
          ObjectInkLayer(
            id: 'image-annotation',
            objectId: imageObject.id,
            strokes: <InkStroke>[
              InkStroke(
                id: 'image-annotation-stroke',
                points: const <InkPoint>[InkPoint(x: .2, y: .3)],
              ),
            ],
          ),
        ],
        groups: <InkGroup>[
          InkGroup(
            id: 'ink-group',
            kind: InkGroupKind.word,
            strokeIds: <String>[stroke.id],
            bounds: stroke.bounds,
          ),
        ],
        contentGroups: <ContentGroup>[
          ContentGroup(
            id: 'content-group',
            memberIds: <String>[stroke.id, text.id],
            bounds: const Rect2(left: 0, top: 0, width: 200, height: 100),
          ),
        ],
        selection: SelectionState(
          selectedItemIds: <String>[stroke.id, text.id],
        ),
        thumbnailAssetId: thumbnail.id,
      );
      final second = BoardPage(
        id: 'page-second',
        name: 'Zweite Quellseite',
        objects: <BoardObject>[pdfObject],
        annotationLayers: <ObjectInkLayer>[
          ObjectInkLayer(
            id: 'pdf-annotation',
            objectId: pdfObject.id,
            pdfPageIndex: 4,
            strokes: <InkStroke>[
              InkStroke(
                id: 'pdf-annotation-stroke',
                points: const <InkPoint>[InkPoint(x: .4, y: .5)],
              ),
            ],
          ),
        ],
      );
      final source = WhiteboardDocument(
        id: 'source-document',
        title: 'Quelle',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        pages: <BoardPage>[first, second],
        assets: <DocumentAsset>[image, pdf, thumbnail, unused],
        metadata: DocumentMetadata(
          author: 'Lehrkraft',
          deviceId: 'board-7',
          recoveredFromCrash: true,
          custom: const <String, String>{'source': 'old'},
        ),
      );

      final result =
          await SelectedPagesDocumentCreator(
            clock: () => DateTime.utc(2026, 8, 12, 12),
          ).create(
            sourceDocument: source,
            sourceAssetDirectory: sourceAssets,
            selectedPageIds: const <String>['page-second', 'page-first'],
            title: '  Auswahl  ',
            repository: repository,
          );

      expect(result.document.title, 'Auswahl');
      expect(result.document.pages.map((page) => page.name), <String>[
        'Zweite Quellseite',
        'Erste Quellseite',
      ]);
      expect(result.document.assets, hasLength(3));
      expect(
        result.document.assets.map((asset) => asset.type),
        containsAll(<DocumentAssetType>[
          DocumentAssetType.image,
          DocumentAssetType.pdf,
          DocumentAssetType.thumbnail,
        ]),
      );
      expect(
        result.document.assets.any(
          (asset) => asset.originalFileName == unused.originalFileName,
        ),
        false,
      );
      expect(result.document.metadata.author, 'Lehrkraft');
      expect(result.document.metadata.deviceId, 'board-7');
      expect(result.document.metadata.recoveredFromCrash, false);
      expect(result.document.metadata.custom, isEmpty);

      final clonedPdfPage = result.document.pages.first;
      final clonedPdf = clonedPdfPage.objects.single as PdfObject;
      expect(clonedPdf.id, isNot(pdfObject.id));
      expect(clonedPdf.assetId, isNot(pdf.id));
      final clonedPdfLayer = clonedPdfPage.annotationLayers.single;
      expect(clonedPdfLayer.objectId, clonedPdf.id);
      expect(clonedPdfLayer.pdfPageIndex, 4);
      expect(clonedPdfLayer.id, isNot('pdf-annotation'));

      final clonedFirst = result.document.pages.last;
      final clonedStroke = clonedFirst.strokes.single;
      final clonedText = clonedFirst.objects.whereType<TextObject>().single;
      final clonedImage = clonedFirst.objects.whereType<ImageObject>().single;
      expect(clonedStroke.id, isNot(stroke.id));
      expect(clonedStroke.pointerId, isNull);
      expect(clonedText.sourceStrokeIds, <String>[clonedStroke.id]);
      expect(clonedImage.assetId, isNot(image.id));
      expect(clonedFirst.annotationLayers.single.objectId, clonedImage.id);
      expect(clonedFirst.groups.single.strokeIds, <String>[clonedStroke.id]);
      expect(clonedFirst.contentGroups.single.memberIds, <String>[
        clonedStroke.id,
        clonedText.id,
      ]);
      expect(clonedFirst.selection.isEmpty, true);
      expect(clonedFirst.thumbnailAssetId, isNot(thumbnail.id));

      final sourceIds = _allPageIds(source.pages);
      final clonedIds = _allPageIds(result.document.pages);
      expect(sourceIds.intersection(clonedIds), isEmpty);
      expect(clonedIds.length, _allPageIds(result.document.pages).length);

      for (final asset in result.document.assets) {
        final copied = File(
          p.join(result.assetDirectory.path, asset.relativePath),
        );
        expect(await copied.exists(), true);
        expect((await copied.length()), asset.byteLength);
        expect(
          (await sha256.bind(copied.openRead()).first).toString(),
          asset.sha256,
        );
      }
      final persisted = await repository.load(result.document.id);
      expect(persisted?.pages.map((page) => page.name), <String>[
        'Zweite Quellseite',
        'Erste Quellseite',
      ]);
    },
  );

  test(
    'save failure rolls back copied files and destination document',
    () async {
      final image = await _asset(sourceAssets, 'image', <int>[1, 2, 3]);
      final source = WhiteboardDocument(
        id: 'source-document',
        title: 'Quelle',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        pages: <BoardPage>[
          BoardPage(
            id: 'page',
            name: 'Seite',
            objects: <BoardObject>[
              ImageObject(
                id: 'image-object',
                transform: _transform,
                assetId: image.id,
              ),
            ],
          ),
        ],
        assets: <DocumentAsset>[image],
      );
      final failing = _SaveFailingRepository(repository);

      await expectLater(
        SelectedPagesDocumentCreator().create(
          sourceDocument: source,
          sourceAssetDirectory: sourceAssets,
          selectedPageIds: const <String>['page'],
          title: 'Auswahl',
          repository: failing,
        ),
        throwsA(isA<DocumentStorageException>()),
      );

      expect(failing.deletedIds, hasLength(1));
      final documents = Directory(
        p.join(temporary.path, 'library', 'documents'),
      );
      expect(
        await documents.exists()
            ? await documents.list(followLinks: false).toList()
            : <FileSystemEntity>[],
        isEmpty,
      );
      expect(await repository.list(), isEmpty);
    },
  );
}

const _transform = ObjectTransform(x: 10, y: 20, width: 300, height: 200);

Future<DocumentAsset> _asset(
  Directory directory,
  String id,
  List<int> bytes,
) async {
  final extension = id == 'pdf' ? '.pdf' : '.png';
  final file = File(p.join(directory.path, '$id$extension'));
  await file.writeAsBytes(bytes, flush: true);
  return DocumentAsset(
    id: id,
    type: switch (id) {
      'pdf' => DocumentAssetType.pdf,
      'thumbnail' => DocumentAssetType.thumbnail,
      _ => DocumentAssetType.image,
    },
    relativePath: p.basename(file.path),
    mimeType: id == 'pdf' ? 'application/pdf' : 'image/png',
    originalFileName: p.basename(file.path),
    byteLength: bytes.length,
    sha256: sha256.convert(bytes).toString(),
  );
}

Set<String> _allPageIds(Iterable<BoardPage> pages) => <String>{
  for (final page in pages) ...<String>{
    page.id,
    for (final stroke in page.strokes) stroke.id,
    for (final object in page.objects) object.id,
    for (final layer in page.annotationLayers) ...<String>{
      layer.id,
      for (final stroke in layer.strokes) stroke.id,
    },
    for (final group in page.groups) group.id,
    for (final group in page.contentGroups) group.id,
  },
};

final class _SaveFailingRepository implements DocumentRepository {
  _SaveFailingRepository(this.delegate);

  final DocumentRepository delegate;
  final List<String> deletedIds = <String>[];

  @override
  Future<Directory> assetDirectory(String documentId) =>
      delegate.assetDirectory(documentId);

  @override
  Future<void> delete(String documentId) async {
    deletedIds.add(documentId);
    await delegate.delete(documentId);
  }

  @override
  Future<List<DocumentSummary>> list() => delegate.list();

  @override
  Future<WhiteboardDocument?> load(String documentId) =>
      delegate.load(documentId);

  @override
  Future<WhiteboardDocument?> recover(String documentId) =>
      delegate.recover(documentId);

  @override
  Future<void> save(WhiteboardDocument document) =>
      throw const DocumentStorageException('Absichtlicher Speicherfehler');
}
