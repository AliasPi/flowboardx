import 'dart:collection';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../app/app_theme.dart';
import 'web_image_search_service.dart';

/// Displays the real JavaScript-enabled Google Images UI without requiring an
/// API key. A small, isolated script reports only the image the user touched;
/// every reported URL is validated again by [WebImageSearchService] before it
/// can be downloaded.
class GoogleImageBrowserDialog extends StatefulWidget {
  const GoogleImageBrowserDialog({required this.service, super.key});

  final WebImageSearchService service;

  @override
  State<GoogleImageBrowserDialog> createState() =>
      _GoogleImageBrowserDialogState();
}

class _GoogleImageBrowserDialogState extends State<GoogleImageBrowserDialog> {
  final TextEditingController _query = TextEditingController();
  InAppWebViewController? _webView;
  ImageSearchResult? _selection;
  List<ImageSearchResult> _candidates = const [];
  String? _error;
  bool _started = false;
  bool _mainFrameLoaded = false;
  bool _fallbackLoading = false;
  int _progress = 0;
  int _searchEpoch = 0;

  bool get _usesNativeWebView => GoogleImageBrowserPolicy.usesNativeWebView(
    isWeb: kIsWeb,
    platform: defaultTargetPlatform,
  );

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: FlowboardColors.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: SizedBox(
        width: math.min(1180, math.max(360, viewport.width - 32)),
        height: math.min(820, math.max(500, viewport.height - 44)),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.image_search_rounded,
                    color: FlowboardColors.mint,
                    size: 32,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Google Bilder',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Schließen',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.only(top: 2, bottom: 12),
                child: Text(
                  'Echte Google-Bildersuche ohne API-Schlüssel · SafeSearch '
                  'aktiv. Bild antippen, anschließend unten übernehmen. '
                  'Nutzungsrechte auf der Quellseite prüfen.',
                  style: TextStyle(color: FlowboardColors.textSecondary),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('google-image-browser-query'),
                      controller: _query,
                      textInputAction: TextInputAction.search,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search_rounded),
                        hintText: 'Suchbegriff',
                      ),
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _search,
                    icon: const Icon(Icons.search_rounded),
                    label: const Text('Suchen'),
                  ),
                ],
              ),
              if (_error case final error?)
                Padding(
                  padding: const EdgeInsets.only(top: 9),
                  child: Text(
                    error,
                    style: const TextStyle(color: FlowboardColors.danger),
                  ),
                ),
              const SizedBox(height: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: FlowboardColors.divider),
                    ),
                    child: Stack(
                      children: [
                        if (!_started)
                          const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.travel_explore_rounded,
                                  size: 64,
                                  color: FlowboardColors.textSecondary,
                                ),
                                SizedBox(height: 14),
                                Text(
                                  'Suchbegriff eingeben und Google Bilder öffnen',
                                  style: TextStyle(
                                    color: FlowboardColors.panel,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          )
                        else if (_usesNativeWebView)
                          _nativeBrowser(_searchEpoch)
                        else
                          _fallbackBrowser(),
                        if (_started && _usesNativeWebView && _progress < 100)
                          Align(
                            alignment: Alignment.topCenter,
                            child: LinearProgressIndicator(
                              value: _progress <= 0 ? null : _progress / 100,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_usesNativeWebView && _candidates.isNotEmpty) ...[
                const SizedBox(height: 10),
                _candidateStrip(),
              ],
              const SizedBox(height: 12),
              _selectionBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nativeBrowser(int epoch) {
    final uri = _searchUri(_query.text);
    return KeyedSubtree(
      key: const ValueKey('google-images-webview'),
      child: InAppWebView(
        key: ValueKey('google-images-webview-$epoch'),
        initialUserScripts: UnmodifiableListView<UserScript>(<UserScript>[
          UserScript(
            source: _selectionBridgeForEpoch(epoch),
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
            // A few Google result layouts render cards in same-site frames.
            // Those taps are forwarded to the top frame and validated again.
            forMainFrameOnly: false,
          ),
        ]),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          safeBrowsingEnabled: true,
          supportZoom: true,
          builtInZoomControls: true,
          displayZoomControls: false,
          useShouldOverrideUrlLoading: true,
          javaScriptCanOpenWindowsAutomatically: false,
          supportMultipleWindows: false,
          mediaPlaybackRequiresUserGesture: true,
        ),
        onWebViewCreated: (controller) =>
            _created(controller, epoch: epoch, uri: uri),
        onProgressChanged: (_, value) {
          if (_isCurrentEpoch(epoch)) setState(() => _progress = value);
        },
        onLoadStop: (controller, url) =>
            _handleLoadStop(controller, url, epoch),
        shouldOverrideUrlLoading: (controller, action) =>
            _handleNavigation(controller, action, epoch),
        onReceivedError: (_, request, error) {
          if (!_isCurrentEpoch(epoch) ||
              !GoogleImageBrowserPolicy.shouldSurfaceError(
                isForMainFrame: request.isForMainFrame == true,
                mainFrameAlreadyLoaded: _mainFrameLoaded,
                errorType: '${error.type} ${error.description}',
              )) {
            return;
          }
          setState(() {
            _error =
                'Google Bilder konnte nicht geladen werden: '
                '${error.description}';
          });
        },
      ),
    );
  }

  Widget _fallbackBrowser() {
    if (_fallbackLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_candidates.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.image_search_outlined,
                size: 56,
                color: FlowboardColors.textSecondary,
              ),
              SizedBox(height: 12),
              Text(
                'Auf dieser Plattform werden die sicheren HTML-Treffer '
                'angezeigt.',
                textAlign: TextAlign.center,
                style: TextStyle(color: FlowboardColors.panel),
              ),
            ],
          ),
        ),
      );
    }
    return GridView.builder(
      key: const ValueKey('google-images-fallback-grid'),
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        childAspectRatio: 1.15,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
      ),
      itemCount: _candidates.length,
      itemBuilder: (context, index) {
        final candidate = _candidates[index];
        final selected = _sameResult(candidate, _selection);
        return Material(
          color: FlowboardColors.panelElevated,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: selected ? FlowboardColors.mint : FlowboardColors.divider,
              width: selected ? 3 : 1,
            ),
          ),
          child: InkWell(
            onTap: () => _select(candidate),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.network(
                  candidate.thumbnailUrl.toString(),
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.low,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.broken_image_outlined,
                    color: FlowboardColors.textSecondary,
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: .72),
                    child: Padding(
                      padding: const EdgeInsets.all(7),
                      child: SizedBox(
                        width: double.infinity,
                        child: Text(
                          candidate.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _candidateStrip() {
    return SizedBox(
      height: 104,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 2, bottom: 5),
            child: Text(
              'Erkannte Treffer · alternativ hier antippen',
              style: TextStyle(
                color: FlowboardColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              key: const ValueKey('google-image-candidate-strip'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 1),
              itemCount: _candidates.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final candidate = _candidates[index];
                final selected = _sameResult(candidate, _selection);
                return Semantics(
                  button: true,
                  selected: selected,
                  label: 'Bild auswählen: ${candidate.title}',
                  child: Material(
                    color: selected
                        ? FlowboardColors.mint.withValues(alpha: .16)
                        : FlowboardColors.panelElevated,
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(
                        color: selected
                            ? FlowboardColors.mint
                            : FlowboardColors.divider,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: InkWell(
                      key: ValueKey(
                        'google-image-candidate-${candidate.imageUrl}',
                      ),
                      onTap: () => _select(candidate, highlightInPage: true),
                      child: SizedBox(
                        width: 138,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 76,
                              height: double.infinity,
                              child: Image.network(
                                candidate.thumbnailUrl.toString(),
                                fit: BoxFit.cover,
                                filterQuality: FilterQuality.low,
                                errorBuilder: (_, _, _) => const ColoredBox(
                                  color: Colors.white12,
                                  child: Icon(
                                    Icons.image_outlined,
                                    color: FlowboardColors.textSecondary,
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.all(6),
                                child: Text(
                                  candidate.title,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: selected
                                        ? FlowboardColors.mint
                                        : FlowboardColors.textPrimary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _selectionBar() {
    final selection = _selection;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      constraints: const BoxConstraints(minHeight: 58),
      padding: const EdgeInsets.fromLTRB(14, 7, 7, 7),
      decoration: BoxDecoration(
        color: selection == null
            ? FlowboardColors.panelElevated
            : FlowboardColors.mint.withValues(alpha: .13),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selection == null
              ? FlowboardColors.divider
              : FlowboardColors.mint,
        ),
      ),
      child: Row(
        children: [
          Icon(
            selection == null
                ? Icons.touch_app_outlined
                : Icons.check_circle_outline_rounded,
            color: selection == null
                ? FlowboardColors.textSecondary
                : FlowboardColors.mint,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: selection == null
                ? const Text(
                    'Ein Bild in Google antippen, um es auszuwählen.',
                    style: TextStyle(color: FlowboardColors.textSecondary),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        selection.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        selection.sourceUrl.host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: FlowboardColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
          ),
          FilledButton.icon(
            onPressed: selection == null
                ? null
                : () => Navigator.pop(context, selection),
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('Bild verwenden'),
          ),
        ],
      ),
    );
  }

  void _created(
    InAppWebViewController controller, {
    required int epoch,
    required Uri uri,
  }) {
    if (!_isCurrentEpoch(epoch)) return;
    _webView = controller;
    controller.addJavaScriptHandler(
      handlerName: 'flowboardImageSelected',
      callback: (arguments) {
        if (!_isCurrentEpoch(epoch)) return false;
        final result = GoogleImageBrowserPolicy.selectionFromBridgeArguments(
          arguments,
          expectedEpoch: epoch,
        );
        if (result == null) return false;
        _select(result);
        return true;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'flowboardImageCandidates',
      callback: (arguments) {
        if (!_isCurrentEpoch(epoch)) return false;
        final values = GoogleImageBrowserPolicy.candidatesFromBridgeArguments(
          arguments,
          expectedEpoch: epoch,
        );
        if (values.isEmpty) return false;
        _mergeCandidates(values);
        return true;
      },
    );
    unawaited(
      controller
          .loadUrl(urlRequest: URLRequest(url: WebUri(uri.toString())))
          .catchError((Object error, StackTrace _) {
            if (!_isCurrentEpoch(epoch)) return;
            setState(() {
              _error = 'Google Bilder konnte nicht geladen werden: $error';
              _progress = 100;
            });
          }),
    );
  }

  void _select(ImageSearchResult result, {bool highlightInPage = false}) {
    if (!mounted) return;
    setState(() {
      _selection = result;
      _error = null;
      _candidates = _mergedResults(_candidates, <ImageSearchResult>[result]);
    });
    if (!highlightInPage) return;
    final encoded = jsonEncode(result.imageUrl.toString());
    _webView
        ?.evaluateJavascript(
          source: 'window.__flowboardImagePicker?.selectUrl($encoded) ?? false',
        )
        .catchError((_) => null);
  }

  void _mergeCandidates(Iterable<ImageSearchResult> values) {
    if (!mounted) return;
    final merged = _mergedResults(_candidates, values);
    if (_sameResultLists(_candidates, merged)) return;
    setState(() => _candidates = merged);
  }

  Future<void> _handleLoadStop(
    InAppWebViewController controller,
    WebUri? url,
    int epoch,
  ) async {
    if (!_isCurrentEpoch(epoch) || url == null || !_isGoogleNavigation(url)) {
      return;
    }
    setState(() {
      _mainFrameLoaded = true;
      _error = null;
      _progress = 100;
    });
    await _installBridge(controller, epoch);
  }

  Future<void> _installBridge(
    InAppWebViewController controller,
    int epoch,
  ) async {
    try {
      await controller.evaluateJavascript(
        source: _selectionBridgeForEpoch(epoch),
      );
      if (!_isCurrentEpoch(epoch)) return;
      await controller.evaluateJavascript(
        source: 'window.__flowboardImagePicker?.refresh() ?? false',
      );
    } catch (_) {
      // The HTTP-parsed candidate strip remains usable if a page or an older
      // WebView temporarily rejects script evaluation during navigation.
    }
  }

  Future<NavigationActionPolicy> _handleNavigation(
    InAppWebViewController _,
    NavigationAction action,
    int epoch,
  ) async {
    if (!_isCurrentEpoch(epoch)) return NavigationActionPolicy.CANCEL;
    final webUri = action.request.url;
    if (webUri == null || webUri.scheme != 'https') {
      return NavigationActionPolicy.CANCEL;
    }
    final uri = Uri.tryParse(webUri.toString());
    final result = uri == null
        ? null
        : WebImageSearchService.resultFromGoogleNavigation(uri);
    if (result != null) {
      _select(result);
      return NavigationActionPolicy.CANCEL;
    }
    return _isGoogleNavigation(webUri)
        ? NavigationActionPolicy.ALLOW
        : NavigationActionPolicy.CANCEL;
  }

  void _search() {
    final value = _query.text.trim();
    if (value.isEmpty) {
      setState(() => _error = 'Bitte zuerst einen Suchbegriff eingeben.');
      return;
    }
    final epoch = ++_searchEpoch;
    setState(() {
      _webView = null;
      _error = null;
      _selection = null;
      _candidates = const [];
      _progress = 0;
      _started = true;
      _mainFrameLoaded = false;
      _fallbackLoading = !_usesNativeWebView;
    });
    unawaited(_loadFallbackCandidates(value, epoch));
  }

  Future<void> _loadFallbackCandidates(String query, int epoch) async {
    try {
      final results = await widget.service.search(query);
      if (!_isCurrentEpoch(epoch)) return;
      if (results.isEmpty) {
        if (!_usesNativeWebView) {
          setState(() => _error = 'Keine passenden Bilder gefunden.');
        }
        return;
      }
      _mergeCandidates(results);
    } catch (error) {
      if (!_isCurrentEpoch(epoch) || _usesNativeWebView) return;
      setState(() {
        _error = 'Google-Bildersuche fehlgeschlagen: $error';
      });
    } finally {
      if (_isCurrentEpoch(epoch) && _fallbackLoading) {
        setState(() => _fallbackLoading = false);
      }
    }
  }

  bool _isCurrentEpoch(int epoch) => mounted && epoch == _searchEpoch;

  static Uri _searchUri(String query) =>
      Uri.https('www.google.com', '/search', <String, String>{
        'q': query.trim(),
        'udm': '2',
        'safe': 'active',
        'hl': 'de',
        'gl': 'de',
      });

  static bool _isGoogleNavigation(WebUri uri) {
    final host = uri.host.toLowerCase();
    return host == 'google.com' ||
        host.endsWith('.google.com') ||
        host == 'google.de' ||
        host.endsWith('.google.de');
  }
}

List<ImageSearchResult> _mergedResults(
  Iterable<ImageSearchResult> current,
  Iterable<ImageSearchResult> additions,
) {
  final byUrl = <String, ImageSearchResult>{};
  for (final value in <ImageSearchResult>[...current, ...additions]) {
    final key = value.imageUrl.replace(fragment: '').toString();
    byUrl.putIfAbsent(key, () => value);
    if (byUrl.length >= 40) break;
  }
  return List.unmodifiable(byUrl.values);
}

bool _sameResult(ImageSearchResult first, ImageSearchResult? second) =>
    second != null &&
    first.imageUrl.replace(fragment: '') ==
        second.imageUrl.replace(fragment: '');

bool _sameResultLists(
  List<ImageSearchResult> first,
  List<ImageSearchResult> second,
) {
  if (identical(first, second)) return true;
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (!_sameResult(first[index], second[index])) return false;
  }
  return true;
}

/// Pure policy kept separate from the platform view so aborted navigations can
/// be regression-tested without creating a native WebView.
abstract final class GoogleImageBrowserPolicy {
  /// Exposed for structural regression tests. The script itself still treats
  /// every DOM value as untrusted and Dart validates all reported URLs.
  static String get selectionBridge => _selectionBridgeForEpoch(0);

  static bool usesNativeWebView({
    required bool isWeb,
    required TargetPlatform platform,
  }) {
    if (isWeb) return false;
    return switch (platform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      TargetPlatform.linux || TargetPlatform.fuchsia => false,
    };
  }

  /// Mirrors the native JavaScript-handler boundary without requiring a
  /// platform WebView in unit tests.
  static ImageSearchResult? selectionFromBridgeArguments(
    List<dynamic> arguments, {
    int? expectedEpoch,
  }) {
    final payload = _payloadForEpoch(arguments, expectedEpoch);
    if (payload == null) return null;
    final values = WebImageSearchService.resultsFromBrowserPayload(
      payload,
      maximumResults: 1,
    );
    return values.isEmpty ? null : values.first;
  }

  static List<ImageSearchResult> candidatesFromBridgeArguments(
    List<dynamic> arguments, {
    int? expectedEpoch,
  }) {
    final payload = _payloadForEpoch(arguments, expectedEpoch);
    if (payload == null) return const [];
    return WebImageSearchService.resultsFromBrowserPayload(payload);
  }

  static Object? _payloadForEpoch(List<dynamic> arguments, int? expectedEpoch) {
    if (arguments.isEmpty) return null;
    final first = arguments.first;
    if (first is! Map || !first.containsKey('epoch')) {
      return expectedEpoch == null ? first : null;
    }
    final epoch = first['epoch'];
    if (expectedEpoch != null &&
        (epoch is! num || epoch.toInt() != expectedEpoch)) {
      return null;
    }
    return first['payload'];
  }

  static bool shouldSurfaceError({
    required bool isForMainFrame,
    required bool mainFrameAlreadyLoaded,
    String? errorType,
  }) {
    if (!isForMainFrame || mainFrameAlreadyLoaded) return false;
    // WebView2 reports a deliberately cancelled navigation as CANCELLED. This
    // happens when a Google result tries to open its publisher page, which the
    // picker intentionally keeps inside the safe Google origin boundary.
    final type = errorType?.toUpperCase() ?? '';
    return !type.contains('CANCEL') &&
        !type.contains('ABORT') &&
        !type.contains('STOPPED');
  }
}

/// Installed at document start so its capture handlers run before Google's
/// navigation handlers. Google replaces the result DOM dynamically, therefore
/// a MutationObserver continuously discovers cards and reports a validated
/// fallback list as well as direct taps.
String _selectionBridgeForEpoch(int epoch) =>
    _selectionBridge.replaceFirst('__FLOWBOARD_SEARCH_EPOCH__', '$epoch');

const String _selectionBridge = r'''
(() => {
  const requestedEpoch = __FLOWBOARD_SEARCH_EPOCH__;
  const existing = window.__flowboardImagePicker;
  if (existing && existing.version === 5) {
    existing.setEpoch(requestedEpoch);
    existing.refresh();
    return true;
  }

  const CARD_SELECTOR = [
    '[data-docid]', '[data-ved]', '[data-iurl]', '[data-ou]',
    '[jsname]', '[role="listitem"]', 'a'
  ].join(',');
  const SELECTED_ATTRIBUTE = 'data-flowboard-selected';
  let scanTimer = 0;
  let lastCandidateSignature = '';
  let lastImage = null;
  let lastReportAt = 0;
  let searchEpoch = requestedEpoch;
  const pointers = new Map();

  const httpsUrl = value => {
    if (typeof value !== 'string' || !value.trim()) return null;
    try {
      const url = new URL(value.trim(), document.baseURI);
      return url.protocol === 'https:' ? url.href : null;
    } catch (_) { return null; }
  };
  const srcsetUrl = value => {
    if (typeof value !== 'string') return null;
    const entries = value.split(',').map(part => part.trim().split(/\s+/)[0]);
    for (let index = entries.length - 1; index >= 0; index--) {
      const url = httpsUrl(entries[index]);
      if (url) return url;
    }
    return null;
  };
  const hostOf = value => {
    try { return new URL(value).hostname.toLowerCase(); }
    catch (_) { return ''; }
  };
  const isGooglePage = value => {
    const host = hostOf(value);
    return host === 'google.com' || host.endsWith('.google.com') ||
           host === 'google.de' || host.endsWith('.google.de');
  };
  const isGoogleAsset = value => {
    const host = hostOf(value);
    return host.endsWith('gstatic.com') ||
           host.endsWith('googleusercontent.com');
  };
  const imageSource = image =>
    httpsUrl(image.getAttribute('data-iurl')) ||
    httpsUrl(image.getAttribute('data-ou')) ||
    httpsUrl(image.getAttribute('data-src')) ||
    httpsUrl(image.currentSrc) || httpsUrl(image.src) ||
    srcsetUrl(image.srcset);
  const imageIsUsable = image => {
    if (!(image instanceof HTMLImageElement)) return false;
    const rect = image.getBoundingClientRect();
    const style = getComputedStyle(image);
    const width = Math.max(rect.width, image.naturalWidth || 0);
    const height = Math.max(rect.height, image.naturalHeight || 0);
    return width >= 48 && height >= 48 &&
           style.display !== 'none' && style.visibility !== 'hidden';
  };

  const callFlutter = (name, payload) => {
    try {
      const bridge = window.flutter_inappwebview;
      if (bridge && typeof bridge.callHandler === 'function') {
        const promise = bridge.callHandler(name, {
          epoch: searchEpoch,
          payload: payload
        });
        if (promise && typeof promise.catch === 'function') {
          promise.catch(() => {});
        }
        return;
      }
    } catch (_) {}
    if (window !== window.top) {
      try {
        window.top.postMessage({
          __flowboardImagePicker: true,
          name: name,
          payload: payload
        }, '*');
      } catch (_) {}
    }
  };

  if (window === window.top) {
    window.addEventListener('message', event => {
      const message = event.data;
      if (!message || message.__flowboardImagePicker !== true) return;
      if (message.name !== 'flowboardImageSelected' &&
          message.name !== 'flowboardImageCandidates') return;
      callFlutter(message.name, message.payload);
    }, true);
  }

  const detailsFor = touched => {
    if (!imageIsUsable(touched)) return null;
    const thumbnailUrl = imageSource(touched);
    let imageUrl = null;
    let sourceUrl = null;
    let title = touched.alt || touched.getAttribute('aria-label') || '';
    let node = touched;
    for (let depth = 0; node && depth < 18; depth++, node = node.parentElement) {
      imageUrl = imageUrl || httpsUrl(node.getAttribute('data-iurl')) ||
                 httpsUrl(node.getAttribute('data-ou')) ||
                 httpsUrl(node.getAttribute('data-image-url')) ||
                 httpsUrl(node.getAttribute('data-src'));
      sourceUrl = sourceUrl || httpsUrl(node.getAttribute('data-rurl')) ||
                  httpsUrl(node.getAttribute('data-ref-url')) ||
                  httpsUrl(node.getAttribute('data-lpage'));
      title = title || node.getAttribute('aria-label') || node.title || '';
      if (node instanceof HTMLAnchorElement && node.href) {
        try {
          const link = new URL(node.href, document.baseURI);
          imageUrl = imageUrl || httpsUrl(link.searchParams.get('imgurl')) ||
                     httpsUrl(link.searchParams.get('mediaurl')) ||
                     httpsUrl(link.searchParams.get('ou'));
          sourceUrl = sourceUrl ||
                      httpsUrl(link.searchParams.get('imgrefurl')) ||
                      httpsUrl(link.searchParams.get('refurl')) ||
                      httpsUrl(link.searchParams.get('url'));
          if (!sourceUrl && !isGooglePage(link.href) &&
              !isGoogleAsset(link.href)) {
            sourceUrl = httpsUrl(link.href);
          }
        } catch (_) {}
      }
    }
    if (!imageUrl || isGooglePage(imageUrl)) imageUrl = thumbnailUrl;
    if (!imageUrl || isGooglePage(imageUrl)) return null;
    if (!sourceUrl || isGooglePage(sourceUrl)) {
      try {
        const url = new URL(imageUrl);
        sourceUrl = `${url.protocol}//${url.host}/`;
      } catch (_) { sourceUrl = imageUrl; }
    }
    title = (title || document.title || 'Google-Bild').trim().slice(0, 180);
    return { imageUrl, thumbnailUrl: thumbnailUrl || imageUrl, sourceUrl, title };
  };

  const candidateImages = element => {
    if (!(element instanceof Element)) return [];
    const values = [];
    if (element instanceof HTMLImageElement) values.push(element);
    const card = element.closest(CARD_SELECTOR);
    if (card) values.push(...card.querySelectorAll('img'));
    values.push(...element.querySelectorAll('img'));
    return values.filter((value, index, list) =>
      list.indexOf(value) === index && imageIsUsable(value)
    );
  };

  const closestImage = (values, x, y) => {
    let best = null;
    let score = Number.POSITIVE_INFINITY;
    for (const image of values) {
      const rect = image.getBoundingClientRect();
      const dx = x < rect.left ? rect.left - x :
                 x > rect.right ? x - rect.right : 0;
      const dy = y < rect.top ? rect.top - y :
                 y > rect.bottom ? y - rect.bottom : 0;
      const next = dx * dx + dy * dy;
      if (next < score) { best = image; score = next; }
    }
    return best;
  };

  const imageFromEvent = event => {
    const x = Number.isFinite(event.clientX) ? event.clientX : 0;
    const y = Number.isFinite(event.clientY) ? event.clientY : 0;
    const path = typeof event.composedPath === 'function'
      ? event.composedPath() : [event.target];
    for (const node of path) {
      const values = candidateImages(node);
      if (values.length) return closestImage(values, x, y);
    }
    if (typeof document.elementsFromPoint === 'function') {
      for (const node of document.elementsFromPoint(x, y)) {
        const values = candidateImages(node);
        if (values.length) return closestImage(values, x, y);
      }
    }
    return null;
  };

  const selectedNodeFor = image => image.closest(CARD_SELECTOR) || image;
  const markSelected = image => {
    document.querySelectorAll(`[${SELECTED_ATTRIBUTE}]`).forEach(node =>
      node.removeAttribute(SELECTED_ATTRIBUTE)
    );
    selectedNodeFor(image).setAttribute(SELECTED_ATTRIBUTE, 'true');
  };
  const report = image => {
    const details = detailsFor(image);
    if (!details) return false;
    const now = Date.now();
    if (image === lastImage && now - lastReportAt < 260) return true;
    lastImage = image;
    lastReportAt = now;
    markSelected(image);
    callFlutter('flowboardImageSelected', details);
    return true;
  };
  const consume = event => {
    if (event.cancelable) event.preventDefault();
    event.stopPropagation();
    if (typeof event.stopImmediatePropagation === 'function') {
      event.stopImmediatePropagation();
    }
  };

  const pointerDown = event => {
    const image = imageFromEvent(event);
    if (!image) return;
    pointers.set(event.pointerId, {
      image,
      x: event.clientX,
      y: event.clientY,
      moved: false,
      at: Date.now()
    });
  };
  const pointerMove = event => {
    const state = pointers.get(event.pointerId);
    if (!state) return;
    if (Math.hypot(event.clientX - state.x, event.clientY - state.y) > 14) {
      state.moved = true;
    }
  };
  const pointerUp = event => {
    const state = pointers.get(event.pointerId);
    pointers.delete(event.pointerId);
    if (!state || state.moved || Date.now() - state.at > 1400) return;
    if (report(state.image)) consume(event);
  };
  const click = event => {
    const image = imageFromEvent(event);
    if (!image) return;
    if (report(image)) consume(event);
  };
  const touchEnd = event => {
    if (!event.changedTouches || event.changedTouches.length !== 1) return;
    const touch = event.changedTouches[0];
    const shim = {
      target: event.target,
      clientX: touch.clientX,
      clientY: touch.clientY,
      composedPath: () => typeof event.composedPath === 'function'
        ? event.composedPath() : [event.target]
    };
    const image = imageFromEvent(shim);
    if (!image) return;
    if (report(image)) consume(event);
  };

  // Capture at document start. In particular, do not let Google's result-card
  // navigation consume a tap that is intended to select an image in Flowboard.
  document.addEventListener('pointerdown', pointerDown, true);
  document.addEventListener('pointermove', pointerMove, true);
  document.addEventListener('pointercancel', event => {
    pointers.delete(event.pointerId);
  }, true);
  document.addEventListener('pointerup', pointerUp, true);
  document.addEventListener('click', click, true);
  document.addEventListener('touchend', touchEnd, {capture: true, passive: false});

  const ensureStyle = () => {
    if (document.getElementById('flowboard-image-picker-style')) return;
    const style = document.createElement('style');
    style.id = 'flowboard-image-picker-style';
    style.textContent = `
      [${SELECTED_ATTRIBUTE}="true"] {
        outline: 4px solid #48E0B7 !important;
        outline-offset: 2px !important;
        border-radius: 8px !important;
        box-shadow: 0 0 0 3px rgba(20, 38, 36, .72) !important;
      }
      img[data-flowboard-pickable="true"] { cursor: pointer !important; }
    `;
    (document.head || document.documentElement).appendChild(style);
  };
  const scan = () => {
    scanTimer = 0;
    ensureStyle();
    const results = [];
    const seen = new Set();
    for (const image of Array.from(document.images)) {
      if (!imageIsUsable(image)) continue;
      const details = detailsFor(image);
      if (!details || seen.has(details.imageUrl)) continue;
      image.setAttribute('data-flowboard-pickable', 'true');
      seen.add(details.imageUrl);
      results.push(details);
      if (results.length >= 36) break;
    }
    const signature = results.map(value => value.imageUrl).join('\n');
    if (results.length && signature !== lastCandidateSignature) {
      lastCandidateSignature = signature;
      callFlutter('flowboardImageCandidates', results);
    }
  };
  const scheduleScan = () => {
    if (scanTimer) return;
    scanTimer = setTimeout(scan, 120);
  };
  const startObserver = () => {
    ensureStyle();
    const root = document.documentElement;
    if (!root) { setTimeout(startObserver, 20); return; }
    const observer = new MutationObserver(scheduleScan);
    observer.observe(root, {childList: true, subtree: true});
    document.addEventListener('load', scheduleScan, true);
    window.addEventListener('scroll', scheduleScan, {passive: true});
    scheduleScan();
  };

  const api = {
    version: 5,
    epoch: searchEpoch,
    setEpoch: value => {
      if (Number.isSafeInteger(value)) {
        searchEpoch = value;
        api.epoch = value;
      }
    },
    refresh: scheduleScan,
    selectUrl: url => {
      for (const image of Array.from(document.images)) {
        const details = detailsFor(image);
        if (details && (details.imageUrl === url ||
                        details.thumbnailUrl === url)) {
          markSelected(image);
          try { image.scrollIntoView({block: 'nearest', inline: 'nearest'}); }
          catch (_) {}
          return true;
        }
      }
      return false;
    }
  };
  window.__flowboardImagePicker = api;
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', startObserver, {once: true});
  } else {
    startObserver();
  }
  return true;
})()
''';
