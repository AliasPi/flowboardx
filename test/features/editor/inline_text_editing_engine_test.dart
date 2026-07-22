import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/features/editor/inline_text_editing_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InlineTextEditingEngine', () {
    test('recognizes a deliberate horizontal strike through a word', () {
      final value = _text('Heute ist Montag');
      final token = InlineTextEditingEngine.tokensFor(value)[1];
      final points = <Offset>[
        Offset(token.bounds.left - 5, token.bounds.center.dy),
        Offset(token.bounds.center.dx, token.bounds.center.dy + 1),
        Offset(token.bounds.right + 5, token.bounds.center.dy),
      ];

      expect(InlineTextEditingEngine.isStrikeThrough(value, points), isTrue);
      expect(
        InlineTextEditingEngine.deleteAtStroke(value, points),
        'Heute Montag',
      );
    });

    test('does not treat ordinary short handwriting as deletion', () {
      final value = _text('Montag');
      final token = InlineTextEditingEngine.tokensFor(value).single;
      final points = <Offset>[
        token.bounds.centerLeft,
        token.bounds.topCenter,
        token.bounds.bottomCenter,
        token.bounds.centerRight,
      ];

      expect(InlineTextEditingEngine.isStrikeThrough(value, points), isFalse);
      expect(InlineTextEditingEngine.deleteAtStroke(value, points), 'Montag');
    });

    test('recognized handwriting replaces the word underneath it', () {
      final value = _text('Heute ist Montag');
      final token = InlineTextEditingEngine.tokensFor(value).last;
      final points = <Offset>[
        token.bounds.topLeft + const Offset(2, 3),
        token.bounds.center,
        token.bounds.bottomRight - const Offset(2, 3),
      ];

      expect(
        InlineTextEditingEngine.replaceOrInsert(
          value,
          inkPoints: points,
          recognizedText: 'Dienstag',
        ),
        'Heute ist Dienstag',
      );
    });

    test('recognized handwriting inserts at the nearest caret', () {
      final value = _text('Hallo');
      final points = <Offset>[
        Offset(value.transform.width + 30, 2),
        Offset(value.transform.width + 60, 24),
      ];

      expect(
        InlineTextEditingEngine.replaceOrInsert(
          value,
          inkPoints: points,
          recognizedText: 'Welt',
        ),
        'Hallo Welt',
      );
    });

    test('handwriting to the right of the final caret appends text', () {
      final value = _text('Heute ist Montag');
      final finalWord = InlineTextEditingEngine.tokensFor(value).last;
      final points = <Offset>[
        Offset(finalWord.bounds.right + 18, finalWord.bounds.center.dy - 6),
        Offset(finalWord.bounds.right + 36, finalWord.bounds.center.dy + 5),
      ];

      expect(InlineTextEditingEngine.isAppendAtEnd(value, points), isTrue);
      expect(
        InlineTextEditingEngine.replaceOrInsert(
          value,
          inkPoints: points,
          recognizedText: 'weiter',
        ),
        'Heute ist Montag weiter',
      );
    });
  });
}

TextObject _text(String text) => TextObject(
  id: 'text',
  transform: const ObjectTransform(x: 20, y: 30, width: 420, height: 60),
  text: text,
  fontSize: 32,
);
