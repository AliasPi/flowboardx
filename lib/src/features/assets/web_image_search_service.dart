import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'remote_host_resolver.dart';
import 'secure_http_client.dart';

/// A Google Images result. Google is the discovery provider; [sourceUrl]
/// points to the page which actually publishes the image.
final class ImageSearchResult {
  const ImageSearchResult({
    required this.title,
    required this.imageUrl,
    required this.thumbnailUrl,
    required this.sourceUrl,
    this.mimeType,
    this.creator,
    this.license,
    this.licenseUrl,
    this.provider = 'Google Bilder',
  });

  final String title;
  final Uri imageUrl;
  final Uri thumbnailUrl;
  final Uri sourceUrl;
  final String? mimeType;
  final String? creator;
  final String? license;
  final Uri? licenseUrl;
  final String provider;
}

/// Keyless Google Images search using Google's public HTML result page.
///
/// Google does not expose a supported, credential-free JSON image-search API.
/// Keeping the HTML integration in this service prevents markup changes,
/// consent pages and bot challenges from leaking into editor state. The parser
/// understands the classic `/imgres` cards, `data-iurl` cards and Google's
/// embedded result metadata, and fails explicitly when Google serves a consent
/// or verification page instead of silently returning an empty grid.
class WebImageSearchService {
  WebImageSearchService({
    http.Client? client,
    Uri? endpoint,
    Uri? fallbackEndpoint,
    Duration requestTimeout = const Duration(seconds: 10),
    RemoteHostResolver? hostResolver,
  }) : _client = client ?? createSecureHttpClient(),
       _endpoint = endpoint ?? Uri.https('www.google.com', '/search'),
       _fallbackEndpoint =
           fallbackEndpoint ?? Uri.https('images.google.com', '/images'),
       _requestTimeout = requestTimeout,
       _hostResolver = hostResolver ?? resolveRemoteHost;

  static const int pageSize = 24;
  static const int maximumDownloadBytes = 25 * 1024 * 1024;
  static const int _maximumSearchBytes = 6 * 1024 * 1024;

  final http.Client _client;
  final Uri _endpoint;
  final Uri _fallbackEndpoint;
  final Duration _requestTimeout;
  final RemoteHostResolver _hostResolver;

  /// Retained for the editor's capability gate. Google HTML search needs no
  /// API key or build-time secret.
  bool get isConfigured => true;

  String get providerName => 'Google Bilder';

  static String? detectImageMimeType(Uint8List bytes) =>
      _detectedImageMimeType(bytes);

  /// Validates a selection reported by the sandboxed Google WebView before it
  /// can enter the download path. JavaScript is treated as untrusted input in
  /// exactly the same way as parsed search HTML.
  static ImageSearchResult? resultFromBrowserSelection(
    Map<Object?, Object?> value,
  ) {
    final imageUri = _publicHttpsUri(value['imageUrl']);
    if (imageUri == null || _isGooglePageUri(imageUri)) return null;
    final thumbnailUri = _publicHttpsUri(value['thumbnailUrl']) ?? imageUri;
    final sourceUri =
        _publicHttpsUri(value['sourceUrl']) ?? _originOf(imageUri);
    if (!_isSafeThumbnail(thumbnailUri)) return null;
    final title = _plainText(value['title']?.toString());
    return ImageSearchResult(
      title: title?.isNotEmpty == true ? title! : _titleFromUri(imageUri),
      imageUrl: imageUri,
      thumbnailUrl: thumbnailUri,
      sourceUrl: sourceUri,
      mimeType: _mimeType(value['mimeType']?.toString(), imageUri),
      creator: sourceUri.host,
    );
  }

  /// Validates a batch reported by the browser bridge. Google mutates its
  /// result grid frequently, so the JavaScript side reports the currently
  /// visible cards as an untrusted list. Keeping validation and de-duplication
  /// here makes the Flutter fallback strip subject to the same SSRF rules as a
  /// direct tap.
  static List<ImageSearchResult> resultsFromBrowserPayload(
    Object? payload, {
    int maximumResults = 40,
  }) {
    if (maximumResults <= 0) return const [];
    final values = payload is List ? payload : <Object?>[payload];
    final results = <ImageSearchResult>[];
    final seen = <String>{};
    var inspected = 0;
    for (final value in values) {
      if (++inspected > 160) break;
      if (value is! Map) continue;
      final result = resultFromBrowserSelection(
        Map<Object?, Object?>.from(value),
      );
      if (result == null) continue;
      final identity = result.imageUrl.replace(fragment: '').toString();
      if (!seen.add(identity)) continue;
      results.add(result);
      if (results.length >= maximumResults) break;
    }
    return List.unmodifiable(results);
  }

  /// Some Google layouts still expose a classic `/imgres` navigation instead
  /// of keeping the preview in the result page. The native navigation delegate
  /// sees that URL even if page JavaScript is prevented from navigating. This
  /// provides a second, independently validated selection path.
  static ImageSearchResult? resultFromGoogleNavigation(Uri uri) {
    if (!_isGooglePageUri(uri)) return null;
    final query = uri.queryParameters;
    final image =
        query['imgurl'] ??
        query['mediaurl'] ??
        query['image_url'] ??
        query['ou'];
    if (image == null) return null;
    return resultFromBrowserSelection(<Object?, Object?>{
      'title': query['q'] ?? query['title'] ?? 'Google-Bild',
      'imageUrl': image,
      'thumbnailUrl': query['tbnurl'] ?? query['thumb'] ?? image,
      'sourceUrl':
          query['imgrefurl'] ?? query['refurl'] ?? query['url'] ?? image,
    });
  }

  Future<List<ImageSearchResult>> search(String query, {int start = 1}) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return const [];
    final offset = (start - 1).clamp(0, 1000);

    final modernUri = _endpoint.replace(
      queryParameters: {
        ..._endpoint.queryParameters,
        'q': normalized,
        'udm': '2',
        'safe': 'active',
        'hl': 'de',
        'gl': 'de',
        'filter': '1',
        if (offset > 0) 'start': '$offset',
      },
    );

    final first = await _fetchSearchPage(modernUri, _browserHeaders);
    var results = parseGoogleImagesHtml(first, requestUri: modernUri);
    if (results.isNotEmpty) return results;

    // In the EEA Google can answer with a consent document. Retrying a basic
    // result page with its non-personalised consent cookie is deterministic,
    // does not create a Google account/session and keeps SafeSearch enabled.
    final blocked = _googleBlockKind(first);
    final basicUri = _fallbackEndpoint.replace(
      queryParameters: {
        ..._fallbackEndpoint.queryParameters,
        'q': normalized,
        'tbm': 'isch',
        'gbv': '1',
        'safe': 'active',
        'hl': 'de',
        'gl': 'de',
        if (offset > 0) 'start': '$offset',
      },
    );
    final fallback = await _fetchSearchPage(basicUri, const {
      ..._browserHeaders,
      'Cookie': 'SOCS=CAESHAgBEhIaAB',
    });
    results = parseGoogleImagesHtml(fallback, requestUri: basicUri);
    if (results.isNotEmpty) return results;

    final fallbackBlock = _googleBlockKind(fallback);
    if (fallbackBlock != null || blocked != null) {
      throw http.ClientException(
        _blockMessage(fallbackBlock ?? blocked!),
        basicUri,
      );
    }
    return const [];
  }

  Future<String> _fetchSearchPage(Uri uri, Map<String, String> headers) async {
    _validateGoogleSearchUri(uri);
    final response = await _client
        .get(uri, headers: headers)
        .timeout(_requestTimeout);
    if (response.statusCode == 429) {
      throw http.ClientException(
        'Google Bilder ist vorübergehend ausgelastet. Bitte kurz warten.',
        uri,
      );
    }
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Google-Bildersuche fehlgeschlagen (${response.statusCode}).',
        uri,
      );
    }
    if (response.bodyBytes.length > _maximumSearchBytes) {
      throw const FormatException(
        'Die Google-Suchantwort ist unerwartet groß.',
      );
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  /// Parses a Google Images HTML response without network access. Kept public
  /// so markup variants can be regression-tested from captured, sanitised
  /// fixtures.
  static List<ImageSearchResult> parseGoogleImagesHtml(
    String html, {
    required Uri requestUri,
  }) {
    if (html.isEmpty || html.length > _maximumSearchBytes) return const [];
    final decodedHtml = _decodeHtmlEntities(html);
    final results = <ImageSearchResult>[];
    final seen = <String>{};

    void add({
      required Object? image,
      required Object? thumbnail,
      required Object? source,
      Object? title,
      Object? type,
    }) {
      if (results.length >= pageSize) return;
      final imageUri = _publicHttpsUri(image);
      if (imageUri == null || _isGooglePageUri(imageUri)) return;
      final sourceUri = _publicHttpsUri(source) ?? _originOf(imageUri);
      final thumbnailUri = _publicHttpsUri(thumbnail) ?? imageUri;
      if (!_isSafeThumbnail(thumbnailUri)) return;
      final identity = imageUri.replace(fragment: '').toString();
      if (!seen.add(identity)) return;
      final cleanTitle = _plainText(title?.toString());
      results.add(
        ImageSearchResult(
          title: cleanTitle?.isNotEmpty == true
              ? cleanTitle!
              : _titleFromUri(imageUri),
          imageUrl: imageUri,
          thumbnailUrl: thumbnailUri,
          sourceUrl: sourceUri,
          mimeType: _mimeType(type?.toString(), imageUri),
          // Google result HTML does not provide dependable licence metadata.
          // Showing the publisher host is still useful attribution in the UI.
          creator: sourceUri.host,
        ),
      );
    }

    // Basic/mobile Google Images result cards. These are the cleanest source
    // because imgurl and imgrefurl are explicit query parameters.
    final anchors = RegExp(
      r'<a\b([^>]*)>([\s\S]*?)</a\s*>',
      caseSensitive: false,
    );
    for (final match in anchors.allMatches(decodedHtml)) {
      final attributes = _attributes(match.group(1) ?? '');
      final href = _resolveGoogleHref(attributes['href'], requestUri);
      if (href == null || !href.path.toLowerCase().contains('imgres')) continue;
      final image = href.queryParameters['imgurl'];
      final source =
          href.queryParameters['imgrefurl'] ?? href.queryParameters['url'];
      final imageAttributes = _firstImageAttributes(match.group(2) ?? '');
      add(
        image: image,
        thumbnail: imageAttributes['data-src'] ?? imageAttributes['src'],
        source: source,
        title: imageAttributes['alt'] ?? href.queryParameters['q'],
      );
    }

    // Some modern cards expose original and publisher URLs as data fields.
    for (final match in RegExp(
      r'''<[^>]+\bdata-iurl\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)[^>]*>''',
      caseSensitive: false,
    ).allMatches(decodedHtml)) {
      final attributes = _attributes(match.group(0) ?? '');
      add(
        image: attributes['data-iurl'],
        thumbnail:
            attributes['data-turl'] ??
            attributes['data-src'] ??
            attributes['src'],
        source: attributes['data-rurl'] ?? attributes['data-ref-url'],
        title: attributes['data-title'] ?? attributes['alt'],
        type: attributes['data-ity'],
      );
    }

    // Classic desktop pages put one flat JSON object per result into rg_meta.
    // The bounded expression intentionally ignores arbitrary page JSON.
    final metadataObjects = RegExp(
      r'\{(?=[^{}]{0,8000}"ou"\s*:)[^{}]{1,8000}\}',
      caseSensitive: false,
    );
    for (final match in metadataObjects.allMatches(decodedHtml)) {
      try {
        final value = jsonDecode(match.group(0)!);
        if (value is! Map) continue;
        add(
          image: value['ou'],
          thumbnail: value['tu'],
          source: value['ru'],
          title: value['pt'] ?? value['s'],
          type: value['ity'],
        );
      } on FormatException {
        // A neighbouring script object can resemble result metadata. Other
        // parser paths remain available, so one malformed object is harmless.
      }
    }

    // Current pages also place result tuples in script arrays. Decode every
    // JavaScript/JSON string safely, then accept only non-Google HTTPS image
    // URLs. This deliberately remains the last, conservative fallback.
    if (results.length < pageSize) {
      final occurrences = _scriptUrlOccurrences(decodedHtml);
      for (final candidate in occurrences) {
        if (results.length >= pageSize) break;
        final uri = candidate.uri;
        if (_isGooglePageUri(uri) || !_looksLikeImageUri(uri)) continue;
        final thumbnail = _closestThumbnail(occurrences, candidate.offset);
        final source = _closestSource(occurrences, candidate);
        add(image: uri, thumbnail: thumbnail, source: source ?? _originOf(uri));
      }
    }

    return List.unmodifiable(results);
  }

  Future<Uint8List> download(ImageSearchResult result) async {
    final candidates = <Uri>[
      result.imageUrl,
      if (result.thumbnailUrl != result.imageUrl) result.thumbnailUrl,
    ];
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final candidate in candidates) {
      try {
        return await _downloadUri(candidate);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    Error.throwWithStackTrace(firstError!, firstStackTrace!);
  }

  Future<Uint8List> _downloadUri(Uri initialUri) async {
    var uri = initialUri;
    for (var redirect = 0; redirect <= 5; redirect++) {
      await _validateResolvedRemoteImageUri(uri);
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers.addAll(_downloadHeaders);
      final response = await _client.send(request).timeout(_requestTimeout);
      if (response.isRedirect || _isRedirectStatus(response.statusCode)) {
        final location = response.headers['location'];
        await _drain(response);
        if (location == null || redirect == 5) {
          throw http.ClientException('Ungültige Bildweiterleitung.', uri);
        }
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode != 200) {
        await _drain(response);
        throw http.ClientException('Bild konnte nicht geladen werden.', uri);
      }
      final contentType = response.headers['content-type']
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      if (contentType != null &&
          !contentType.startsWith('image/') &&
          contentType != 'application/octet-stream') {
        await _drain(response);
        throw const FormatException('Die Antwort ist keine Bilddatei.');
      }
      final announcedLength = response.contentLength;
      if (announcedLength != null && announcedLength > maximumDownloadBytes) {
        await _drain(response);
        throw const FormatException('Das Bild ist größer als 25 MB.');
      }
      final bytes = BytesBuilder(copy: false);
      var received = 0;
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 20),
      )) {
        received += chunk.length;
        if (received > maximumDownloadBytes) {
          throw const FormatException('Das Bild ist größer als 25 MB.');
        }
        bytes.add(chunk);
      }
      final data = bytes.takeBytes();
      if (!_hasSupportedImageSignature(data)) {
        throw const FormatException(
          'Die geladene Datei ist kein unterstütztes Bild.',
        );
      }
      return data;
    }
    throw http.ClientException('Zu viele Bildweiterleitungen.', uri);
  }

  Future<void> _validateResolvedRemoteImageUri(Uri uri) async {
    _validateRemoteImageUri(uri);
    final host = _normalizedHost(uri.host);
    late final List<ResolvedHostAddress> addresses;
    try {
      addresses = await _hostResolver(host).timeout(_requestTimeout);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException(
        'Die Bildadresse konnte nicht sicher aufgelöst werden.',
      );
    }
    if (addresses.isEmpty || addresses.any((address) => !address.isPublic)) {
      throw const FormatException(
        'Bilder dürfen nicht aus lokalen oder privaten Netzen geladen werden.',
      );
    }
  }

  Future<void> _drain(http.StreamedResponse response) async {
    final subscription = response.stream.listen(null);
    try {
      await subscription.asFuture<void>().timeout(_requestTimeout);
    } finally {
      await subscription.cancel();
    }
  }

  void dispose() => _client.close();
}

const _browserHeaders = <String, String>{
  'Accept':
      'text/html,application/xhtml+xml,application/xml;q=0.9,'
      'image/webp,*/*;q=0.8',
  'Accept-Language': 'de-DE,de;q=0.9,en;q=0.7',
  'Cache-Control': 'no-cache',
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/126.0.0.0 Safari/537.36',
};

const _downloadHeaders = <String, String>{
  'Accept':
      'image/webp,image/apng,image/png,image/jpeg,image/gif,image/bmp,'
      'application/octet-stream;q=0.5',
  'Accept-Language': 'de-DE,de;q=0.9,en;q=0.7',
  'Referer': 'https://www.google.com/',
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/126.0.0.0 Safari/537.36',
};

enum _GoogleBlockKind { consent, verification, javascript }

_GoogleBlockKind? _googleBlockKind(String html) {
  final value = html.toLowerCase();
  if (value.contains('consent.google.') ||
      value.contains('before you continue to google') ||
      value.contains('bevor sie zu google weitergehen')) {
    return _GoogleBlockKind.consent;
  }
  if (value.contains('/sorry/') ||
      value.contains('challenge_version') ||
      value.contains('unusual traffic') ||
      value.contains('ungewöhnlichen datenverkehr') ||
      value.contains('g-recaptcha')) {
    return _GoogleBlockKind.verification;
  }
  if (value.contains('/httpservice/retry/enablejs') ||
      value.contains('browser aktualisieren') ||
      value.contains('enable javascript')) {
    return _GoogleBlockKind.javascript;
  }
  return null;
}

String _blockMessage(_GoogleBlockKind kind) => switch (kind) {
  _GoogleBlockKind.consent =>
    'Google verlangt derzeit eine Bestätigung der Datenschutzeinstellungen. '
        'Bitte die Suche erneut versuchen.',
  _GoogleBlockKind.verification =>
    'Google hat die automatische Bildsuche vorübergehend eingeschränkt. '
        'Bitte kurz warten und erneut suchen.',
  _GoogleBlockKind.javascript =>
    'Google liefert für dieses Gerät derzeit keine auswertbare '
        'Bilder-Ergebnisseite.',
};

Map<String, String> _attributes(String value) {
  final attributes = <String, String>{};
  final pattern = RegExp(
    r'''([:\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
    caseSensitive: false,
  );
  for (final match in pattern.allMatches(value)) {
    final name = match.group(1)!.toLowerCase();
    attributes[name] = _decodeHtmlEntities(
      match.group(2) ?? match.group(3) ?? match.group(4) ?? '',
    );
  }
  return attributes;
}

Map<String, String> _firstImageAttributes(String value) {
  final match = RegExp(
    r'<img\b([^>]*)>',
    caseSensitive: false,
  ).firstMatch(value);
  return match == null ? const {} : _attributes(match.group(1) ?? '');
}

Uri? _resolveGoogleHref(String? raw, Uri requestUri) {
  if (raw == null || raw.isEmpty) return null;
  final parsed = Uri.tryParse(raw);
  if (parsed == null) return null;
  return parsed.hasScheme ? parsed : requestUri.resolveUri(parsed);
}

String _decodeHtmlEntities(String value) {
  return value.replaceAllMapped(
    RegExp(
      r'&(#x[0-9a-f]+|#[0-9]+|amp|quot|apos|lt|gt);',
      caseSensitive: false,
    ),
    (match) {
      final entity = match.group(1)!.toLowerCase();
      if (entity.startsWith('#x')) {
        final code = int.tryParse(entity.substring(2), radix: 16);
        return code == null ? match.group(0)! : String.fromCharCode(code);
      }
      if (entity.startsWith('#')) {
        final code = int.tryParse(entity.substring(1));
        return code == null ? match.group(0)! : String.fromCharCode(code);
      }
      return switch (entity) {
        'amp' => '&',
        'quot' => '"',
        'apos' => "'",
        'lt' => '<',
        'gt' => '>',
        _ => match.group(0)!,
      };
    },
  );
}

String? _plainText(String? value) {
  if (value == null) return null;
  final result = _decodeHtmlEntities(
    value,
  ).replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return result.isEmpty ? null : result;
}

Uri? _publicHttpsUri(Object? raw) {
  final value = raw?.toString().trim() ?? '';
  final uri = Uri.tryParse(value.startsWith('//') ? 'https:$value' : value);
  if (uri == null) return null;
  try {
    _validateRemoteImageUri(uri);
    return uri;
  } on FormatException {
    return null;
  }
}

void _validateGoogleSearchUri(Uri uri) {
  final host = uri.host.toLowerCase();
  final googleHost =
      host == 'google.com' ||
      host.endsWith('.google.com') ||
      host == 'google.de' ||
      host.endsWith('.google.de');
  if (uri.scheme != 'https' ||
      !googleHost ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443)) {
    throw const FormatException(
      'Die Bildsuche darf nur verschlüsselt mit Google kommunizieren.',
    );
  }
}

void _validateRemoteImageUri(Uri uri) {
  final host = _normalizedHost(uri.host);
  if (uri.scheme != 'https' ||
      host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443) ||
      host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      _isPrivateIpLiteral(host)) {
    throw const FormatException(
      'Bilder dürfen nur von öffentlichen HTTPS-Adressen geladen werden.',
    );
  }
}

String _normalizedHost(String host) {
  var normalized = host.toLowerCase();
  while (normalized.endsWith('.')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

bool _isPrivateIpLiteral(String host) {
  final normalized = host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;
  // Literal IPv6 image hosts are exceptionally uncommon. Rejecting all of
  // them also covers IPv4-mapped loopback/private representations without a
  // second, subtly different IP parser.
  if (normalized.contains(':')) return true;
  final parts = normalized.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((part) => part == null)) {
    // Numeric shorthand such as 127.1 or 2130706433 can be interpreted as an
    // IPv4 address by some network stacks.
    return RegExp(r'^[0-9.]+$').hasMatch(normalized);
  }
  if (parts.any((part) => part! < 0 || part > 255)) return true;
  final a = parts[0]!;
  final b = parts[1]!;
  return a == 0 ||
      a == 10 ||
      a == 127 ||
      (a == 100 && b >= 64 && b <= 127) ||
      (a == 169 && b == 254) ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 0) ||
      (a == 192 && b == 168) ||
      (a == 198 && (b == 18 || b == 19)) ||
      a >= 224;
}

bool _isGooglePageUri(Uri uri) {
  final host = uri.host.toLowerCase();
  return host == 'google.com' ||
      host.endsWith('.google.com') ||
      host == 'google.de' ||
      host.endsWith('.google.de');
}

bool _isSafeThumbnail(Uri uri) {
  try {
    _validateRemoteImageUri(uri);
    return true;
  } on FormatException {
    return false;
  }
}

Uri _originOf(Uri uri) => Uri(scheme: 'https', host: uri.host);

String _titleFromUri(Uri uri) {
  if (uri.pathSegments.isNotEmpty) {
    // Uri.pathSegments is already percent-decoded. Decoding it again changes
    // literal percent sequences and can throw for otherwise valid filenames.
    final raw = uri.pathSegments.last
        .replaceAll(
          RegExp(r'\.(?:jpe?g|png|gif|webp|bmp)$', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'[-_]+'), ' ')
        .trim();
    if (raw.isNotEmpty) return raw;
  }
  return 'Bild von ${uri.host}';
}

String? _mimeType(String? type, Uri uri) {
  var normalized = type?.trim().toLowerCase() ?? '';
  if (normalized.startsWith('image/')) {
    normalized = normalized.substring('image/'.length);
  }
  if (normalized.isEmpty) {
    final match = RegExp(
      r'\.([a-z0-9]+)$',
      caseSensitive: false,
    ).firstMatch(uri.path);
    normalized = match?.group(1)?.toLowerCase() ?? '';
  }
  return switch (normalized) {
    'jpg' || 'jpeg' || 'pjpeg' => 'image/jpeg',
    'png' || 'x-png' || 'apng' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    _ => null,
  };
}

final class _UrlOccurrence {
  const _UrlOccurrence(this.uri, this.offset);

  final Uri uri;
  final int offset;
}

List<_UrlOccurrence> _scriptUrlOccurrences(String html) {
  final values = <_UrlOccurrence>[];
  final pattern = RegExp(r'"((?:\\.|[^"\\])*)"');
  for (final match in pattern.allMatches(html)) {
    final raw = match.group(1)!;
    if (!raw.contains('http') && !raw.startsWith(r'https:\/')) continue;
    String decoded;
    try {
      decoded = jsonDecode('"$raw"') as String;
    } on FormatException {
      continue;
    }
    final uri = _publicHttpsUri(decoded);
    if (uri != null) values.add(_UrlOccurrence(uri, match.start));
  }
  return values;
}

bool _looksLikeImageUri(Uri uri) {
  if (_isGoogleThumbnail(uri)) return false;
  final path = uri.path.toLowerCase();
  return RegExp(r'\.(?:jpe?g|png|gif|webp|bmp)$').hasMatch(path) ||
      uri.queryParameters.keys.any(
        (key) =>
            key.toLowerCase() == 'format' &&
            RegExp(
              r'jpe?g|png|gif|webp|bmp',
              caseSensitive: false,
            ).hasMatch(uri.queryParameters[key] ?? ''),
      );
}

bool _isGoogleThumbnail(Uri uri) {
  final host = uri.host.toLowerCase();
  return host.contains('gstatic.com') ||
      host.contains('googleusercontent.com') ||
      uri.query.contains('tbn:');
}

Uri? _closestThumbnail(List<_UrlOccurrence> values, int offset) {
  _UrlOccurrence? best;
  var distance = 4001;
  for (final candidate in values) {
    if (!_isGoogleThumbnail(candidate.uri)) continue;
    final nextDistance = (candidate.offset - offset).abs();
    if (nextDistance < distance) {
      best = candidate;
      distance = nextDistance;
    }
  }
  return best?.uri;
}

Uri? _closestSource(List<_UrlOccurrence> values, _UrlOccurrence image) {
  _UrlOccurrence? best;
  var distance = 2501;
  for (final candidate in values) {
    if (identical(candidate, image) ||
        _isGooglePageUri(candidate.uri) ||
        _isGoogleThumbnail(candidate.uri) ||
        _looksLikeImageUri(candidate.uri)) {
      continue;
    }
    final nextDistance = (candidate.offset - image.offset).abs();
    if (nextDistance < distance) {
      best = candidate;
      distance = nextDistance;
    }
  }
  return best?.uri;
}

bool _hasSupportedImageSignature(Uint8List bytes) {
  return _detectedImageMimeType(bytes) != null;
}

String? _detectedImageMimeType(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return 'image/jpeg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0d &&
      bytes[5] == 0x0a &&
      bytes[6] == 0x1a &&
      bytes[7] == 0x0a) {
    return 'image/png';
  }
  if (bytes.length >= 6) {
    final header = ascii.decode(bytes.sublist(0, 6), allowInvalid: true);
    if (header == 'GIF87a' || header == 'GIF89a') return 'image/gif';
  }
  if (bytes.length >= 12 &&
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
    return 'image/webp';
  }
  if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4d) {
    return 'image/bmp';
  }
  return null;
}

bool _isRedirectStatus(int statusCode) =>
    statusCode == 301 ||
    statusCode == 302 ||
    statusCode == 303 ||
    statusCode == 307 ||
    statusCode == 308;
