import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/features/editor/pdf_import_dialog.dart';
import 'package:flowboard_x/src/features/radial_menu/radial_menu_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PDF selection normalizes duplicate unordered page indices', () {
    final selection = PdfImportSelection(
      mode: RadialPdfImportMode.pageRange,
      pageIndices: const <int>[4, 1, 4, 2],
    );

    expect(selection.pageIndices, <int>[1, 2, 4]);
    expect(selection.placement, PdfPlacementMode.bundledObject);
  });

  test('PDF selection keeps the preview-dialog placement decision', () {
    final selection = PdfImportSelection(
      mode: RadialPdfImportMode.pageRange,
      pageIndices: const <int>[0, 2],
      placement: PdfPlacementMode.newWhiteboardPages,
    );

    expect(selection.placement, PdfPlacementMode.newWhiteboardPages);
  });
}
