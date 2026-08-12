import 'dart:typed_data';

import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/features/board/presentation/board_object_layer.dart';
import 'package:flowboard_x/src/features/editor/board_export_factory.dart';
import 'package:flowboard_x/src/features/export_share/domain/export_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('PDF render failure aborts export with an actionable error', (
    tester,
  ) async {
    final document = _documentWithPdf(
      pageIndices: const <int>[1, 4],
      activePageIndex: 1,
    );
    final nativeFailure = StateError('PDFium render failed');
    final factory = BoardExportFactory(
      pdfPageRenderer: (path, object) async {
        expect(path, r'C:\assets\lesson.pdf');
        expect(object.activeSourcePageIndex, 4);
        throw nativeFailure;
      },
    );

    final prepared = await factory.prepare(
      document,
      const _PdfResolver(r'C:\assets\lesson.pdf'),
    );
    addTearDown(prepared.dispose);

    expect(prepared.snapshot.pages, hasLength(2));

    await expectLater(
      prepared.snapshot.pages[1].rasterize(_request),
      throwsA(
        isA<BoardExportException>()
            .having(
              (error) => error.message,
              'message',
              allOf(
                contains('PDF-Seite 5'),
                contains('Whiteboard-Seite „Physik“'),
                contains('konnte nicht gerendert werden'),
              ),
            )
            .having((error) => error.cause, 'cause', same(nativeFailure)),
      ),
    );
  });

  testWidgets('missing PDF asset aborts instead of exporting a placeholder', (
    tester,
  ) async {
    var rendererCalled = false;
    final factory = BoardExportFactory(
      pdfPageRenderer: (_, _) async {
        rendererCalled = true;
        throw StateError('must not be called');
      },
    );
    final prepared = await factory.prepare(
      _documentWithPdf(),
      const _PdfResolver(null),
    );
    addTearDown(prepared.dispose);

    await expectLater(
      prepared.snapshot.pages.single.rasterize(_request),
      throwsA(
        isA<BoardExportException>().having(
          (error) => error.message,
          'message',
          allOf(contains('nicht mehr verfügbar'), contains('Datei erneut ein')),
        ),
      ),
    );
    expect(rendererCalled, isFalse);
  });

  testWidgets(
    'bundled multi-page PDF exports every imported source page in order',
    (tester) async {
      final renderedSourcePages = <int>[];
      final factory = BoardExportFactory(
        pdfPageRenderer: (_, object) async {
          renderedSourcePages.add(object.activeSourcePageIndex);
          throw StateError('page probe');
        },
      );
      final prepared = await factory.prepare(
        _documentWithPdf(pageIndices: const <int>[2, 5, 9], activePageIndex: 1),
        const _PdfResolver(r'C:\assets\lesson.pdf'),
      );
      addTearDown(prepared.dispose);

      expect(prepared.snapshot.pages, hasLength(3));
      expect(prepared.snapshot.pages.map((page) => page.label), <String>[
        'Physik · PDF-Seite 3',
        'Physik · PDF-Seite 6',
        'Physik · PDF-Seite 10',
      ]);

      for (final page in prepared.snapshot.pages) {
        await expectLater(
          page.rasterize(_request),
          throwsA(isA<BoardExportException>()),
        );
      }
      expect(renderedSourcePages, <int>[2, 5, 9]);
    },
  );

  testWidgets(
    'multiple bundled PDFs cover every source page without Cartesian growth',
    (tester) async {
      final prepared = await const BoardExportFactory().prepare(
        _documentWithPdf(
          pageIndices: const <int>[1, 4, 8],
          activePageIndex: 1,
          additionalObjects: <BoardObject>[
            PdfObject(
              id: 'second-pdf',
              transform: const ObjectTransform(
                x: 1000,
                y: 0,
                width: 800,
                height: 540,
              ),
              assetId: 'second-pdf-asset',
              pageIndices: const <int>[3, 7, 11],
              activePageIndex: 1,
            ),
          ],
        ),
        const _PdfResolver(r'C:\assets\lesson.pdf'),
      );
      addTearDown(prepared.dispose);

      // Three views driven by the first PDF, plus the two non-active variants
      // of the second PDF; a 3 x 3 Cartesian export would incorrectly make 9.
      expect(prepared.snapshot.pages, hasLength(5));
      expect(prepared.snapshot.pages.map((page) => page.label), <String>[
        'Physik · PDF 1, Seite 2',
        'Physik · PDF 1, Seite 5',
        'Physik · PDF 1, Seite 9',
        'Physik · PDF 2, Seite 4',
        'Physik · PDF 2, Seite 12',
      ]);
    },
  );
}

const _request = ExportRasterRequest(
  logicalWidth: 1920,
  logicalHeight: 1080,
  pixelRatio: 0.1,
  maxPixels: 100000,
);

WhiteboardDocument _documentWithPdf({
  List<int> pageIndices = const <int>[0],
  int activePageIndex = 0,
  List<BoardObject> additionalObjects = const <BoardObject>[],
}) {
  final timestamp = DateTime.utc(2026, 7, 22);
  return WhiteboardDocument(
    id: 'document',
    title: 'Unterricht',
    createdAt: timestamp,
    updatedAt: timestamp,
    pages: <BoardPage>[
      BoardPage(
        id: 'page',
        name: 'Physik',
        objects: <BoardObject>[
          PdfObject(
            id: 'pdf',
            transform: const ObjectTransform(
              x: 0,
              y: 0,
              width: 960,
              height: 540,
            ),
            assetId: 'pdf-asset',
            pageIndices: pageIndices,
            activePageIndex: activePageIndex,
          ),
          ...additionalObjects,
        ],
      ),
    ],
  );
}

final class _PdfResolver implements BoardAssetResolver {
  const _PdfResolver(this.path);

  final String? path;

  @override
  String? localPath(String assetId) => path;

  @override
  Future<Uint8List?> readBytes(String assetId) async => null;
}
