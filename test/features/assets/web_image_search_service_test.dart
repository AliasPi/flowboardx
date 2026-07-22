import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flowboard_x/src/features/assets/google_image_browser_dialog.dart';
import 'package:flowboard_x/src/features/assets/resolved_host_address.dart';
import 'package:flowboard_x/src/features/assets/web_image_search_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late String classicFixture;
  late String embeddedFixture;
  late String scriptFixture;
  late String consentFixture;

  setUpAll(() async {
    classicFixture = await _fixture('google_images_classic.html');
    embeddedFixture = await _fixture('google_images_embedded.html');
    scriptFixture = await _fixture('google_images_script_tuple.html');
    consentFixture = await _fixture('google_images_consent.html');
  });

  test(
    'searches Google Images without credentials and forces SafeSearch',
    () async {
      late Uri requestedUri;
      late Map<String, String> requestedHeaders;
      final client = MockClient((request) async {
        requestedUri = request.url;
        requestedHeaders = request.headers;
        return http.Response(
          classicFixture,
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      });
      final service = WebImageSearchService(client: client);

      final results = await service.search('  Schultafel  ', start: 25);

      expect(service.isConfigured, isTrue);
      expect(service.providerName, 'Google Bilder');
      expect(requestedUri.host, 'www.google.com');
      expect(requestedUri.queryParameters['q'], 'Schultafel');
      expect(requestedUri.queryParameters['udm'], '2');
      expect(requestedUri.queryParameters['safe'], 'active');
      expect(requestedUri.queryParameters['start'], '24');
      expect(requestedUri.queryParameters, isNot(contains('key')));
      expect(requestedHeaders['user-agent'], contains('Mozilla'));
      expect(results, hasLength(2));
      expect(results.first.title, 'Grüne Schultafel im Klassenraum');
      expect(results.first.imageUrl.host, 'media.example.org');
      expect(results.first.thumbnailUrl.host, contains('gstatic.com'));
      expect(results.first.sourceUrl.path, '/unterricht/schultafel');
      expect(results.first.creator, 'schule.example.org');
      expect(results.first.provider, 'Google Bilder');
    },
  );

  test('retries a consent page using basic Google Images HTML', () async {
    var requests = 0;
    late http.Request fallbackRequest;
    final client = MockClient((request) async {
      requests++;
      if (requests == 1) return http.Response(consentFixture, 200);
      fallbackRequest = request;
      return http.Response.bytes(
        utf8.encode(classicFixture),
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    });

    final results = await WebImageSearchService(client: client).search('Tafel');

    expect(requests, 2);
    expect(fallbackRequest.url.host, 'images.google.com');
    expect(fallbackRequest.url.queryParameters['tbm'], 'isch');
    expect(fallbackRequest.url.queryParameters['safe'], 'active');
    expect(fallbackRequest.headers['cookie'], contains('SOCS='));
    expect(results, hasLength(2));
  });

  test('parses embedded Google metadata and filters unsafe entries', () {
    final results = WebImageSearchService.parseGoogleImagesHtml(
      embeddedFixture,
      requestUri: Uri.parse('https://www.google.com/search?q=board&udm=2'),
    );

    expect(results, hasLength(1));
    expect(results.single.title, 'Tafel mit Kreide');
    expect(results.single.mimeType, 'image/webp');
    expect(results.single.imageUrl.scheme, 'https');
    expect(results.single.sourceUrl.host, 'publisher.example.net');
  });

  test('parses escaped script tuples as a conservative fallback', () {
    final results = WebImageSearchService.parseGoogleImagesHtml(
      scriptFixture,
      requestUri: Uri.parse('https://www.google.com/search?q=board&udm=2'),
    );

    expect(results, hasLength(1));
    expect(results.single.imageUrl.path, '/photos/board.png');
    expect(results.single.thumbnailUrl.host, contains('gstatic.com'));
    expect(results.single.sourceUrl.path, '/school-board');
  });

  test('reports a verification response instead of an empty result list', () {
    final client = MockClient(
      (_) async => http.Response(
        '<html><script>var challenge_version = 4;</script></html>',
        200,
      ),
    );

    expect(
      WebImageSearchService(client: client).search('x'),
      throwsA(
        isA<http.ClientException>().having(
          (error) => error.message,
          'message',
          contains('eingeschränkt'),
        ),
      ),
    );
  });

  test(
    'downloads a signature-validated image from a public HTTPS host',
    () async {
      final png = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
      late Map<String, String> requestedHeaders;
      final client = MockClient((request) async {
        requestedHeaders = request.headers;
        expect(request.url.host, 'media.example.org');
        expect(request.headers['user-agent'], contains('Mozilla'));
        expect(request.headers['referer'], 'https://www.google.com/');
        return http.Response.bytes(
          png,
          200,
          headers: {'content-type': 'image/png'},
        );
      });
      final service = WebImageSearchService(
        client: client,
        hostResolver: _publicResolver,
      );

      expect(await service.download(_result()), png);
      expect(requestedHeaders['accept'], isNot(contains('avif')));
    },
  );

  test('rejects local, private and numeric shorthand destinations', () async {
    var requests = 0;
    final service = WebImageSearchService(
      client: MockClient((_) async {
        requests++;
        return http.Response('', 200);
      }),
    );
    for (final url in [
      'https://192.168.1.10/private.png',
      'https://127.1/private.png',
      'https://2130706433/private.png',
      'https://[::ffff:127.0.0.1]/private.png',
      'https://localhost./private.png',
    ]) {
      final privateResult = ImageSearchResult(
        title: 'Test',
        imageUrl: Uri.parse(url),
        thumbnailUrl: Uri.parse(url),
        sourceUrl: Uri.parse(url).replace(path: '/'),
      );
      await expectLater(service.download(privateResult), throwsFormatException);
    }
    expect(requests, 0);
  });

  test('validates every redirect before following it', () async {
    var requests = 0;
    final service = WebImageSearchService(
      client: MockClient((_) async {
        requests++;
        return http.Response(
          '',
          302,
          headers: {'location': 'https://localhost/x'},
        );
      }),
      hostResolver: _publicResolver,
    );

    await expectLater(service.download(_result()), throwsFormatException);
    expect(requests, 1);
  });

  test('rejects HTML disguised with an image content type', () async {
    final service = WebImageSearchService(
      client: MockClient(
        (_) async => http.Response.bytes(
          '<html>not an image</html>'.codeUnits,
          200,
          headers: {'content-type': 'image/png'},
        ),
      ),
      hostResolver: _publicResolver,
    );

    await expectLater(service.download(_result()), throwsFormatException);
  });

  test('falls back to the validated Google thumbnail', () async {
    final png = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    final service = WebImageSearchService(
      client: MockClient((request) async {
        if (request.url.host == 'publisher.example.org') {
          return http.Response('', 403);
        }
        expect(request.url.host, 'encrypted-tbn0.gstatic.com');
        return http.Response.bytes(
          png,
          200,
          headers: {'content-type': 'image/png'},
        );
      }),
      hostResolver: _publicResolver,
    );
    final result = ImageSearchResult(
      title: 'Tafel',
      imageUrl: Uri.parse('https://publisher.example.org/blocked.jpg'),
      thumbnailUrl: Uri.parse(
        'https://encrypted-tbn0.gstatic.com/images?q=tbn:test',
      ),
      sourceUrl: Uri.parse('https://publisher.example.org/article'),
    );

    expect(await service.download(result), png);
  });

  test('validates untrusted selections reported by the Google WebView', () {
    final result = WebImageSearchService.resultFromBrowserSelection({
      'title': '<b>Schultafel</b>',
      'imageUrl': 'https://media.example.org/board.jpg',
      'thumbnailUrl': 'https://encrypted-tbn0.gstatic.com/thumb.jpg',
      'sourceUrl': 'https://school.example.org/article',
    });

    expect(result, isNotNull);
    expect(result!.title, 'Schultafel');
    expect(result.imageUrl.host, 'media.example.org');
    expect(result.sourceUrl.host, 'school.example.org');
    expect(
      WebImageSearchService.resultFromBrowserSelection({
        'imageUrl': 'http://127.0.0.1/private.png',
      }),
      isNull,
    );
  });

  test('accepts an immediate Google thumbnail selection', () {
    final result = WebImageSearchService.resultFromBrowserSelection({
      'title': 'Tafel',
      'imageUrl': 'https://encrypted-tbn0.gstatic.com/images?q=tbn:test',
      'thumbnailUrl': 'https://encrypted-tbn0.gstatic.com/images?q=tbn:test',
      'sourceUrl': 'https://school.example.org/tafel',
    });

    expect(result, isNotNull);
    expect(result!.imageUrl.host, 'encrypted-tbn0.gstatic.com');
    expect(result.sourceUrl.host, 'school.example.org');
  });

  test(
    'WebView callback selection reaches signature-checked image bytes',
    () async {
      final png = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
      final result = GoogleImageBrowserPolicy.selectionFromBridgeArguments([
        {
          'title': 'Angetippte Tafel',
          'imageUrl': 'https://encrypted-tbn0.gstatic.com/images?q=tbn:board',
          'thumbnailUrl':
              'https://encrypted-tbn0.gstatic.com/images?q=tbn:board',
          'sourceUrl': 'https://school.example.org/tafel',
        },
      ]);
      expect(result, isNotNull);

      final service = WebImageSearchService(
        client: MockClient((request) async {
          expect(request.url, result!.imageUrl);
          return http.Response.bytes(
            png,
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
        hostResolver: _publicResolver,
      );

      expect(await service.download(result!), png);
    },
  );

  test('WebView bridge rejects blob, data and private redirect targets', () {
    for (final value in <String>[
      'blob:https://www.google.com/deadbeef',
      'data:image/png;base64,iVBORw0KGgo=',
      'http://media.example.org/insecure.png',
      'https://127.0.0.1/private.png',
    ]) {
      expect(
        GoogleImageBrowserPolicy.selectionFromBridgeArguments([
          {'imageUrl': value, 'thumbnailUrl': value},
        ]),
        isNull,
      );
    }
    expect(
      WebImageSearchService.resultFromGoogleNavigation(
        Uri.parse(
          'https://www.google.com/imgres?imgurl='
          'https%3A%2F%2F127.0.0.1%2Fprivate.png',
        ),
      ),
      isNull,
    );
  });

  test('validates and de-duplicates browser candidate batches', () {
    final results = WebImageSearchService.resultsFromBrowserPayload([
      {
        'title': 'Tafel A',
        'imageUrl': 'https://media.example.org/board.jpg#preview',
        'thumbnailUrl': 'https://encrypted-tbn0.gstatic.com/a.jpg',
        'sourceUrl': 'https://school.example.org/a',
      },
      {
        'title': 'Duplikat',
        'imageUrl': 'https://media.example.org/board.jpg',
        'thumbnailUrl': 'https://encrypted-tbn0.gstatic.com/b.jpg',
        'sourceUrl': 'https://school.example.org/b',
      },
      {'title': 'Unsicher', 'imageUrl': 'https://127.0.0.1/private.png'},
      'kein Treffer',
    ]);

    expect(results, hasLength(1));
    expect(results.single.title, 'Tafel A');
    expect(results.single.imageUrl.host, 'media.example.org');
  });

  test('extracts classic Google imgres navigation as a safe selection', () {
    final result = WebImageSearchService.resultFromGoogleNavigation(
      Uri.https('www.google.com', '/imgres', {
        'imgurl': 'https://media.example.org/board.png',
        'imgrefurl': 'https://school.example.org/article',
        'tbnurl': 'https://encrypted-tbn0.gstatic.com/thumb.jpg',
        'title': 'Schultafel',
      }),
    );

    expect(result, isNotNull);
    expect(result!.title, 'Schultafel');
    expect(result.imageUrl.host, 'media.example.org');
    expect(result.thumbnailUrl.host, 'encrypted-tbn0.gstatic.com');
    expect(result.sourceUrl.host, 'school.example.org');
    expect(
      WebImageSearchService.resultFromGoogleNavigation(
        Uri.parse(
          'https://evil.example/imgres?imgurl=https://media.example/a.png',
        ),
      ),
      isNull,
    );
  });

  test('rejects a hostname when any DNS answer is non-public', () async {
    var requests = 0;
    var lookups = 0;
    final service = WebImageSearchService(
      client: MockClient((_) async {
        requests++;
        return http.Response('', 200);
      }),
      hostResolver: (_) async {
        lookups++;
        return const [
          ResolvedHostAddress('93.184.216.34', isPublic: true),
          ResolvedHostAddress('127.0.0.1', isPublic: false),
        ];
      },
    );

    await expectLater(service.download(_result()), throwsFormatException);

    expect(lookups, 1);
    expect(requests, 0);
  });

  test('resolves again before following even a relative redirect', () async {
    var requests = 0;
    var lookups = 0;
    final service = WebImageSearchService(
      client: MockClient((_) async {
        requests++;
        return http.Response('', 302, headers: {'location': '/next.png'});
      }),
      hostResolver: (_) async {
        lookups++;
        return [
          ResolvedHostAddress(
            lookups == 1 ? '93.184.216.34' : '169.254.169.254',
            isPublic: lookups == 1,
          ),
        ];
      },
    );

    await expectLater(service.download(_result()), throwsFormatException);

    expect(lookups, 2);
    expect(requests, 1);
  });

  test('uses an absolute timeout while draining rejected responses', () async {
    for (final status in <int>[302, 500]) {
      late final Timer timer;
      final body = StreamController<List<int>>(onCancel: () => timer.cancel());
      timer = Timer.periodic(
        const Duration(milliseconds: 2),
        (_) => body.add(const [0]),
      );
      final service = WebImageSearchService(
        client: _StreamingClient(
          (_) async => http.StreamedResponse(
            body.stream,
            status,
            headers: status == 302
                ? {'location': 'https://media.example.org/next.png'}
                : const {},
          ),
        ),
        requestTimeout: const Duration(milliseconds: 30),
        hostResolver: _publicResolver,
      );

      await expectLater(
        service.download(_result()),
        throwsA(isA<TimeoutException>()),
      );
      expect(timer.isActive, isFalse);
      await body.close();
    }
  });

  test('does not percent-decode a generated title twice', () {
    final result = WebImageSearchService.resultFromBrowserSelection({
      'imageUrl': 'https://media.example.org/100%25-board.png',
    });

    expect(result, isNotNull);
    expect(result!.title, '100% board');
  });
}

Future<String> _fixture(String name) =>
    File('test/fixtures/$name').readAsString();

ImageSearchResult _result() => ImageSearchResult(
  title: 'Test',
  imageUrl: Uri.parse('https://media.example.org/test.png'),
  thumbnailUrl: Uri.parse('https://media.example.org/test.png'),
  sourceUrl: Uri.parse('https://publisher.example.org/test'),
);

Future<List<ResolvedHostAddress>> _publicResolver(String _) async => const [
  ResolvedHostAddress('93.184.216.34', isPublic: true),
];

final class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}
