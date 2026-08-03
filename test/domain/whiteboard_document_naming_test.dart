import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new whiteboard title uses padded local creation minute', () {
    final localTime = DateTime(2026, 7, 30, 15, 57, 42);

    expect(formatNewWhiteboardTitle(localTime), '20260730-15_57');
    expect(
      formatNewWhiteboardTitle(DateTime(2026, 1, 2, 3, 4)),
      '20260102-03_04',
    );
  });

  test(
    'document factory defaults to the timestamp title deterministically',
    () {
      final localTime = DateTime(2026, 7, 30, 15, 57);

      final document = WhiteboardDocument.create(
        id: 'time-named',
        now: localTime,
      );

      expect(document.title, '20260730-15_57');
      expect(document.createdAt, localTime.toUtc());
      expect(document.updatedAt, localTime.toUtc());
    },
  );

  test('an explicitly supplied document title is preserved', () {
    final document = WhiteboardDocument.create(
      id: 'explicitly-named',
      title: 'Bereits benannt',
      now: DateTime(2026, 7, 30, 15, 57),
    );

    expect(document.title, 'Bereits benannt');
  });
}
