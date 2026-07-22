import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flowboard_x/src/features/export_share/application/pdf_exporter.dart';
import 'package:flowboard_x/src/features/export_share/application/pdf_share_controller.dart';
import 'package:flowboard_x/src/features/export_share/domain/export_snapshot.dart';
import 'package:flowboard_x/src/features/export_share/infrastructure/local_pdf_share_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exports, shares, observes a download, and stops cleanly', () async {
    final directory = await Directory.systemTemp.createTemp(
      'flowboard-share-controller-',
    );
    final server = LocalPdfShareServer(
      addressResolver: () async => InternetAddress.loopbackIPv4,
      bindAddress: InternetAddress.loopbackIPv4,
      tokenGenerator: () => 'abcdefghijklmnopqrstuvwxyz123456',
    );
    final controller = PdfShareController(
      exporter: const PdfExporter(maxPixelsPerPage: 100),
      server: server,
    );
    addTearDown(() async {
      controller.dispose();
      await server.close();
      await directory.delete(recursive: true);
    });

    final snapshot = ExportDocumentSnapshot(
      title: 'Test',
      pages: [
        ExportPageSnapshot(
          widthPoints: 100,
          heightPoints: 100,
          rasterize: (_) async => ExportRaster(
            width: 1,
            height: 1,
            rgbaBytes: Uint8List.fromList([0, 0, 0, 255]),
          ),
        ),
      ],
    );
    final destination = File('${directory.path}/test.pdf');

    final started = await controller.exportAndShare(snapshot, destination);
    expect(
      started,
      isTrue,
      reason: '${controller.state.error}\n${controller.state.stackTrace}',
    );
    expect(controller.state.phase, PdfSharePhase.sharing);
    expect(await destination.exists(), isTrue);

    final downloaded = Completer<void>();
    void observeDownload() {
      if (controller.state.downloadCount == 1 && !downloaded.isCompleted) {
        downloaded.complete();
      }
    }

    controller.addListener(observeDownload);
    addTearDown(() => controller.removeListener(observeDownload));
    final client = HttpClient();
    final response = await (await client.getUrl(
      controller.state.shareUrl!,
    )).close();
    await response.drain<void>();
    client.close();
    await downloaded.future;
    expect(controller.state.downloadCount, 1);

    await controller.stop();
    expect(controller.state.phase, PdfSharePhase.idle);
    expect(server.isRunning, isFalse);
  });

  test('rejects a non-PDF before starting the server', () async {
    final directory = await Directory.systemTemp.createTemp(
      'flowboard-invalid-pdf-',
    );
    final file = File('${directory.path}/invalid.pdf');
    await file.writeAsString('not a PDF');
    final server = LocalPdfShareServer(
      addressResolver: () async => InternetAddress.loopbackIPv4,
      bindAddress: InternetAddress.loopbackIPv4,
      tokenGenerator: () => 'abcdefghijklmnopqrstuvwxyz123456',
    );
    final controller = PdfShareController(server: server);
    addTearDown(() async {
      controller.dispose();
      await server.close();
      await directory.delete(recursive: true);
    });

    expect(await controller.shareExisting(file), isFalse);
    expect(controller.state.phase, PdfSharePhase.failed);
    expect(server.isRunning, isFalse);
  });
}
