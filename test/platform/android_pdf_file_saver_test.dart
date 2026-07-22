import 'dart:io';

import 'package:flowboard_x/src/platform/android_pdf_file_saver.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flowboard_test/pdf_saver');
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('flowboard_saf_test_');
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await temporary.delete(recursive: true);
  });

  test('passes a real temporary PDF to the native streaming saver', () async {
    final file = File('${temporary.path}${Platform.pathSeparator}source.pdf');
    await file.writeAsBytes(const [0x25, 0x50, 0x44, 0x46, 0x2D]);
    MethodCall? invocation;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          invocation = call;
          return 'content://documents/export.pdf';
        });

    final saver = AndroidPdfFileSaver(channel: channel, isSupported: true);
    final uri = await saver.save(file, suggestedName: r'Klasse/7.pdf');

    expect(uri.toString(), 'content://documents/export.pdf');
    expect(invocation?.method, 'savePdf');
    expect(
      invocation?.arguments,
      containsPair('suggestedName', 'Klasse_7.pdf'),
    );
  });
}
