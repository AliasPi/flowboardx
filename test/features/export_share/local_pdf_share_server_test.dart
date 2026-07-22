import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flowboard_x/src/features/export_share/infrastructure/local_pdf_share_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late LocalPdfShareServer server;
  late HttpClient client;

  setUp(() {
    client = HttpClient();
    server = LocalPdfShareServer(
      addressResolver: () async => InternetAddress.loopbackIPv4,
      bindAddress: InternetAddress.loopbackIPv4,
      tokenGenerator: () => 'abcdefghijklmnopqrstuvwxyz123456',
    );
  });

  tearDown(() async {
    client.close(force: true);
    await server.close();
  });

  test('serves only the tokenized PDF URL with download headers', () async {
    final pdf = Uint8List.fromList('%PDF-1.7\nfixture'.codeUnits);
    final session = await server.start(
      SharedPdfSource.bytes(pdf, fileName: 'Mathe Übung.pdf'),
    );
    final downloaded = server.events.firstWhere(
      (event) => event.kind == LocalPdfShareEventKind.downloaded,
    );

    final request = await client.getUrl(session.url);
    final response = await request.close();
    final bytes = await _read(response);
    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, 'application/pdf');
    expect(
      response.headers.value('Content-Disposition'),
      contains('attachment;'),
    );
    expect(
      response.headers.value('Content-Disposition'),
      contains('filename*=UTF-8'),
    );
    expect(bytes, pdf);
    await downloaded;
    expect(server.session?.downloadCount, 1);

    final invalidUrl = session.url.replace(
      pathSegments: [
        'download',
        'wrong-token-that-is-long-enough',
        session.fileName,
      ],
    );
    final invalidRequest = await client.getUrl(invalidUrl);
    final invalidResponse = await invalidRequest.close();
    await invalidResponse.drain<void>();
    expect(invalidResponse.statusCode, HttpStatus.notFound);
  });

  test('supports HEAD without counting it as a download', () async {
    final session = await server.start(
      SharedPdfSource.bytes(
        Uint8List.fromList('%PDF-fixture'.codeUnits),
        fileName: 'board.pdf',
      ),
    );
    final request = await client.openUrl('HEAD', session.url);
    final response = await request.close();
    await response.drain<void>();

    expect(response.statusCode, HttpStatus.ok);
    expect(response.contentLength, session.fileLength);
    expect(server.session?.downloadCount, 0);
  });

  test(
    'serves a ZIP through the same tokenized download infrastructure',
    () async {
      final zip = Uint8List.fromList(<int>[0x50, 0x4B, 0x03, 0x04, 1, 2, 3]);
      final session = await server.start(
        SharedDownloadSource.bytes(
          zip,
          fileName: 'Klasse 7.zip',
          contentType: ContentType('application', 'zip'),
        ),
      );

      final request = await client.getUrl(session.url);
      final response = await request.close();
      final bytes = await _read(response);

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.contentType?.mimeType, 'application/zip');
      expect(session.fileName, 'Klasse 7.zip');
      expect(bytes, zip);
    },
  );

  test('expires after idle timeout', () async {
    await server.close();
    server = LocalPdfShareServer(
      idleTimeout: const Duration(milliseconds: 80),
      addressResolver: () async => InternetAddress.loopbackIPv4,
      bindAddress: InternetAddress.loopbackIPv4,
      tokenGenerator: () => 'abcdefghijklmnopqrstuvwxyz123456',
    );
    final stopped = server.events.firstWhere(
      (event) =>
          event.kind == LocalPdfShareEventKind.stopped &&
          event.stopReason == LocalPdfShareStopReason.expired,
    );
    await server.start(
      SharedPdfSource.bytes(Uint8List.fromList([1]), fileName: 'board.pdf'),
    );

    await expectLater(stopped, completes);
    expect(server.isRunning, isFalse);
  });

  test('a newer start safely supersedes an in-flight start', () async {
    await server.close();
    final firstResolverEntered = Completer<void>();
    final releaseFirstResolver = Completer<void>();
    var resolverCalls = 0;
    server = LocalPdfShareServer(
      addressResolver: () async {
        resolverCalls++;
        if (resolverCalls == 1) {
          firstResolverEntered.complete();
          await releaseFirstResolver.future;
        }
        return InternetAddress.loopbackIPv4;
      },
      bindAddress: InternetAddress.loopbackIPv4,
      tokenGenerator: () => 'abcdefghijklmnopqrstuvwxyz123456',
    );
    final firstStart = server.start(
      SharedPdfSource.bytes(Uint8List.fromList([1]), fileName: 'first.pdf'),
    );
    await firstResolverEntered.future;
    final secondStart = server.start(
      SharedPdfSource.bytes(Uint8List.fromList([2]), fileName: 'second.pdf'),
    );
    releaseFirstResolver.complete();

    await expectLater(firstStart, throwsStateError);
    final current = await secondStart;
    expect(server.session?.url, current.url);
    expect(server.session?.fileName, 'second.pdf');
  });
}

Future<Uint8List> _read(HttpClientResponse response) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}
