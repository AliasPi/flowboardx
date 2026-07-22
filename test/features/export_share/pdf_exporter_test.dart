import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flowboard_x/src/features/export_share/application/pdf_exporter.dart';
import 'package:flowboard_x/src/features/export_share/domain/export_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ExportDocumentSnapshot snapshot({String title = 'Tafel – Mathematik'}) =>
      ExportDocumentSnapshot(
        title: title,
        author: 'Klasse 4a',
        createdAt: DateTime.utc(2026, 7, 21, 10, 30),
        modifiedAt: DateTime.utc(2026, 7, 21, 10, 45),
        pages: [
          ExportPageSnapshot(
            widthPoints: 800,
            heightPoints: 450,
            rasterize: (request) async {
              expect(request.maxPixels, greaterThan(0));
              return ExportRaster(
                width: 2,
                height: 1,
                rgbaBytes: Uint8List.fromList([255, 0, 0, 128, 0, 0, 255, 255]),
              );
            },
          ),
        ],
      );

  test('writes a valid cross-reference table and lossless RGB page', () async {
    final bytes = await const PdfExporter(
      maxPixelsPerPage: 100,
    ).exportToBytes(snapshot());
    expect(bytes.sublist(0, 8), ascii.encode('%PDF-1.7'));

    final text = latin1.decode(bytes, allowInvalid: true);
    expect(RegExp(r'/Type /Page\b').allMatches(text), hasLength(1));
    expect(text, contains('/MediaBox [0 0 800 450]'));
    expect(
      text,
      contains(
        '<FEFF0054006100660065006C002020130020004D0061007400680065006D006100740069006B>',
      ),
    );

    final startXref = RegExp(r'startxref\n(\d+)\n%%EOF').firstMatch(text)!;
    final xrefOffset = int.parse(startXref.group(1)!);
    expect(latin1.decode(bytes.sublist(xrefOffset, xrefOffset + 4)), 'xref');

    final imageHeader = RegExp(
      r'/Filter /FlateDecode /Length (\d+) >>\nstream\n',
    ).firstMatch(text)!;
    final compressedLength = int.parse(imageHeader.group(1)!);
    final compressedStart = imageHeader.end;
    final rgb = zlib.decode(
      bytes.sublist(compressedStart, compressedStart + compressedLength),
    );
    expect(rgb, [255, 127, 127, 0, 0, 255]);
  });

  test('atomically replaces an existing destination when requested', () async {
    final directory = await Directory.systemTemp.createTemp(
      'flowboard-pdf-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final destination = File('${directory.path}/Unterricht.pdf');
    await destination.writeAsString('old');

    final result = await const PdfExporter(maxPixelsPerPage: 100).exportToFile(
      snapshot(title: 'Neue Version'),
      destination,
      overwrite: true,
    );

    expect(result.path, destination.path);
    final writtenBytes = await destination.readAsBytes();
    expect(writtenBytes.take(8), ascii.encode('%PDF-1.7'));
    expect(
      directory.listSync().where((entry) => entry.path.endsWith('.part')),
      isEmpty,
    );
  });

  test('rejects a page raster that exceeds the memory budget', () async {
    final oversized = ExportDocumentSnapshot(
      title: 'Oversized',
      pages: [
        ExportPageSnapshot(
          widthPoints: 100,
          heightPoints: 100,
          rasterize: (_) async =>
              ExportRaster(width: 2, height: 2, rgbaBytes: Uint8List(16)),
        ),
      ],
    );

    await expectLater(
      const PdfExporter(maxPixelsPerPage: 3).exportToBytes(oversized),
      throwsStateError,
    );
  });
}
