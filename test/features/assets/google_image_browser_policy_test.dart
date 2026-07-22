import 'dart:io';

import 'package:flowboard_x/src/features/assets/google_image_browser_dialog.dart';
import 'package:flowboard_x/src/features/assets/web_image_search_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('surfaces only genuine errors before the result page loaded', () {
    expect(
      GoogleImageBrowserPolicy.shouldSurfaceError(
        isForMainFrame: false,
        mainFrameAlreadyLoaded: false,
        errorType: 'HOST_LOOKUP',
      ),
      isFalse,
    );
    expect(
      GoogleImageBrowserPolicy.shouldSurfaceError(
        isForMainFrame: true,
        mainFrameAlreadyLoaded: false,
        errorType: 'CANCELLED',
      ),
      isFalse,
    );
    expect(
      GoogleImageBrowserPolicy.shouldSurfaceError(
        isForMainFrame: true,
        mainFrameAlreadyLoaded: true,
        errorType: 'CONNECTION_ABORTED',
      ),
      isFalse,
    );
    expect(
      GoogleImageBrowserPolicy.shouldSurfaceError(
        isForMainFrame: true,
        mainFrameAlreadyLoaded: false,
        errorType: 'CONNECTION_ABORTED',
      ),
      isFalse,
    );
    expect(
      GoogleImageBrowserPolicy.shouldSurfaceError(
        isForMainFrame: true,
        mainFrameAlreadyLoaded: false,
        errorType: 'Indicates that the connection was stopped',
      ),
      isFalse,
    );
    expect(
      GoogleImageBrowserPolicy.shouldSurfaceError(
        isForMainFrame: true,
        mainFrameAlreadyLoaded: false,
        errorType: 'HOST_LOOKUP',
      ),
      isTrue,
    );
  });

  test('selection bridge captures taps and observes dynamic Google cards', () {
    final script = GoogleImageBrowserPolicy.selectionBridge;

    expect(script, contains("document.addEventListener('pointerdown'"));
    expect(script, contains("document.addEventListener('pointerup'"));
    expect(script, contains("document.addEventListener('touchend'"));
    expect(script, contains("document.addEventListener('click'"));
    expect(script, contains('stopImmediatePropagation'));
    expect(script, contains('elementsFromPoint'));
    expect(script, contains('MutationObserver'));
    expect(script, contains('flowboardImageCandidates'));
    expect(script, contains('data-flowboard-selected'));
    expect(script, contains('epoch: searchEpoch'));
    expect(script, contains('payload: payload'));
  });

  test('uses native WebViews only on supported application platforms', () {
    for (final platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ]) {
      expect(
        GoogleImageBrowserPolicy.usesNativeWebView(
          isWeb: false,
          platform: platform,
        ),
        isTrue,
      );
    }
    for (final platform in <TargetPlatform>[
      TargetPlatform.linux,
      TargetPlatform.fuchsia,
    ]) {
      expect(
        GoogleImageBrowserPolicy.usesNativeWebView(
          isWeb: false,
          platform: platform,
        ),
        isFalse,
      );
    }
    expect(
      GoogleImageBrowserPolicy.usesNativeWebView(
        isWeb: true,
        platform: TargetPlatform.windows,
      ),
      isFalse,
    );
  });

  test('rejects stale or unscoped WebView bridge callbacks', () {
    final payload = {
      'title': 'Tafel',
      'imageUrl': 'https://media.example.org/board.png',
    };

    expect(
      GoogleImageBrowserPolicy.selectionFromBridgeArguments([
        {'epoch': 6, 'payload': payload},
      ], expectedEpoch: 7),
      isNull,
    );
    expect(
      GoogleImageBrowserPolicy.selectionFromBridgeArguments([
        payload,
      ], expectedEpoch: 7),
      isNull,
    );
    expect(
      GoogleImageBrowserPolicy.selectionFromBridgeArguments([
        {'epoch': 7, 'payload': payload},
      ], expectedEpoch: 7),
      isNotNull,
    );
  });

  test('macOS sandbox permits outbound Google and image requests', () {
    for (final path in <String>[
      'macos/Runner/DebugProfile.entitlements',
      'macos/Runner/Release.entitlements',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains('com.apple.security.network.client'),
      );
    }
  });

  testWidgets('Linux searches with the HTML fallback without a platform view', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final service = WebImageSearchService(
      client: MockClient((_) async => http.Response('<html></html>', 200)),
    );
    addTearDown(service.dispose);

    await tester.pumpWidget(
      MaterialApp(home: GoogleImageBrowserDialog(service: service)),
    );
    await tester.enterText(
      find.byKey(const ValueKey('google-image-browser-query')),
      'Tafel',
    );
    await tester.tap(find.text('Suchen'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('google-images-webview')), findsNothing);
    expect(find.text('Keine passenden Bilder gefunden.'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
