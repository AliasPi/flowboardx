import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/features/templates/template_factory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every template creates a populated, identifiable new page', () {
    final factory = TemplateFactory();
    for (final kind in TemplateKind.values) {
      final page = factory.createPage(kind, pageNumber: 2);
      expect(page.template?.kind, kind);
      expect(page.objects.isNotEmpty || page.strokes.isNotEmpty, isTrue);
      expect(page.name, contains('Seite 2'));
    }
  });
}
