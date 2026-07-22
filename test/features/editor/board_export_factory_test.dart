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

    await expectLater(
      prepared.snapshot.pages.single.rasterize(_request),
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
