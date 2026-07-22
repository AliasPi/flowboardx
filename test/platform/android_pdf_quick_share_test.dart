import 'dart:io';

import 'package:flowboard_x/src/platform/android_pdf_quick_share.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flowboard_test/pdf_quick_share');
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'flowboard_quick_share_test_',
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await temporary.delete(recursive: true);
  });

  test('passes a validated PDF to the Android system sharesheet', () async {
    final file = File('${temporary.path}${Platform.pathSeparator}source.pdf');
    await file.writeAsBytes(const [
      0x25,
      0x50,
      0x44,
      0x46,
      0x2D,
      0x31,
      0x2E,
      0x37,
    ]);
    MethodCall? invocation;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          invocation = call;
          return true;
        });

    final share = AndroidPdfQuickShare(channel: channel, isSupported: true);
    await share.share(
      file,
      suggestedName: r'Klasse/7',
      chooserTitle: 'An Lernende teilen',
    );

    expect(invocation?.method, 'sharePdf');
    expect(
      invocation?.arguments,
      containsPair('suggestedName', 'Klasse_7.pdf'),
    );
    expect(
      invocation?.arguments,
      containsPair('chooserTitle', 'An Lernende teilen'),
    );
  });

  test('rejects a non-PDF before invoking Android', () async {
    final file = File('${temporary.path}${Platform.pathSeparator}source.pdf');
    await file.writeAsString('not a pdf');
    var invoked = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          invoked = true;
          return true;
        });

    final share = AndroidPdfQuickShare(channel: channel, isSupported: true);
    await expectLater(
      share.share(file, suggestedName: 'Board.pdf'),
      throwsA(isA<FormatException>()),
    );
    expect(invoked, isFalse);
  });

  test('maps native failures to a stable domain exception', () async {
    final file = File('${temporary.path}${Platform.pathSeparator}source.pdf');
    await file.writeAsBytes(const [0x25, 0x50, 0x44, 0x46, 0x2D]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'sharesheet_unavailable',
            message: 'Keine Freigabe verfügbar.',
          );
        });

    final share = AndroidPdfQuickShare(channel: channel, isSupported: true);
    await expectLater(
      share.share(file, suggestedName: 'Board.pdf'),
      throwsA(
        isA<AndroidPdfQuickShareException>()
            .having((error) => error.code, 'code', 'sharesheet_unavailable')
            .having((error) => error.toString(), 'message', contains('Keine')),
      ),
    );
  });
}
