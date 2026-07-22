import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../domain/model/board_object.dart';
import '../radial_menu/radial_menu_models.dart';

@immutable
class PdfImportSelection {
  PdfImportSelection({
    required this.mode,
    required Iterable<int> pageIndices,
    this.placement = PdfPlacementMode.bundledObject,
  }) : pageIndices = List<int>.unmodifiable(
         pageIndices.toSet().toList(growable: false)..sort(),
       );

  final RadialPdfImportMode mode;
  final PdfPlacementMode placement;

  /// Zero-based indices in ascending order.
  final List<int> pageIndices;
}

/// Shows real, lazily rendered PDF pages and lets the user import the complete
/// document, one page, or an arbitrary set of pages. This replaces the former
/// generic Ring-3 choices, which could not preview the selected file.
class PdfImportDialog extends StatefulWidget {
  const PdfImportDialog({
    required this.document,
    required this.fileName,
    super.key,
  });

  final PdfDocument document;
  final String fileName;

  static Future<PdfImportSelection?> show(
    BuildContext context, {
    required PdfDocument document,
    required String fileName,
  }) async {
    final route = DialogRoute<PdfImportSelection>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PdfImportDialog(document: document, fileName: fileName),
    );
    final result = await Navigator.of(
      context,
      rootNavigator: true,
    ).push<PdfImportSelection>(route);
    // Navigator.push completes when pop is requested, while pdfrx preview
    // widgets may still be disposing during the reverse route animation. The
    // caller owns and disposes [document], so do not return that ownership
    // until every PdfPageView has actually left the overlay.
    await route.completed;
    return result;
  }

  @override
  State<PdfImportDialog> createState() => _PdfImportDialogState();
}

class _PdfImportDialogState extends State<PdfImportDialog> {
  RadialPdfImportMode _mode = RadialPdfImportMode.allPages;
  PdfPlacementMode _placement = PdfPlacementMode.bundledObject;
  final Set<int> _selected = <int>{0};

  int get _pageCount => widget.document.pages.length;

  void _setMode(RadialPdfImportMode mode) {
    if (_mode == mode) return;
    setState(() {
      _mode = mode;
      if (_selected.isEmpty && _pageCount > 0) _selected.add(0);
      if (mode == RadialPdfImportMode.singlePage && _selected.length > 1) {
        final first = _selected.reduce(math.min);
        _selected
          ..clear()
          ..add(first);
      }
    });
  }

  void _togglePage(int index) {
    setState(() {
      switch (_mode) {
        case RadialPdfImportMode.allPages:
          // In whole-document mode the cards are previews, not checkboxes.
          return;
        case RadialPdfImportMode.singlePage:
          _selected
            ..clear()
            ..add(index);
        case RadialPdfImportMode.pageRange:
          if (!_selected.remove(index)) _selected.add(index);
      }
    });
  }

  PdfImportSelection _selection() {
    return switch (_mode) {
      RadialPdfImportMode.allPages => PdfImportSelection(
        mode: _mode,
        pageIndices: Iterable<int>.generate(_pageCount),
        placement: _placement,
      ),
      RadialPdfImportMode.singlePage => PdfImportSelection(
        mode: _mode,
        pageIndices: <int>[_selected.reduce(math.min)],
        placement: _placement,
      ),
      RadialPdfImportMode.pageRange => PdfImportSelection(
        mode: _mode,
        pageIndices: _selected,
        placement: _placement,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = math.max(260.0, math.min(1120.0, media.size.width - 32));
    final height = math.max(280.0, math.min(820.0, media.size.height - 32));
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 12, 12),
              child: Row(
                children: [
                  const Icon(Icons.picture_as_pdf_outlined, size: 30),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'PDF-Seiten auswählen',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          widget.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Abbrechen',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            SizedBox(
              height: (height * .24).clamp(84.0, 180.0),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Quellseiten',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _ModeChip(
                          label: 'Ganze PDF',
                          icon: Icons.library_books_outlined,
                          selected: _mode == RadialPdfImportMode.allPages,
                          onSelected: () =>
                              _setMode(RadialPdfImportMode.allPages),
                        ),
                        _ModeChip(
                          label: 'Eine Seite',
                          icon: Icons.looks_one_outlined,
                          selected: _mode == RadialPdfImportMode.singlePage,
                          onSelected: () =>
                              _setMode(RadialPdfImportMode.singlePage),
                        ),
                        _ModeChip(
                          label: 'Bestimmte Seiten',
                          icon: Icons.library_add_check_outlined,
                          selected: _mode == RadialPdfImportMode.pageRange,
                          onSelected: () =>
                              _setMode(RadialPdfImportMode.pageRange),
                        ),
                        if (_mode == RadialPdfImportMode.pageRange)
                          TextButton(
                            onPressed: _selected.isEmpty
                                ? null
                                : () => setState(_selected.clear),
                            child: const Text('Auswahl aufheben'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Platzierung',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        _ModeChip(
                          label: 'Gebündeltes Objekt',
                          icon: Icons.layers_outlined,
                          selected:
                              _placement == PdfPlacementMode.bundledObject,
                          onSelected: () => setState(
                            () => _placement = PdfPlacementMode.bundledObject,
                          ),
                        ),
                        _ModeChip(
                          label: 'Einzelne Objekte',
                          icon: Icons.grid_view_rounded,
                          selected:
                              _placement == PdfPlacementMode.separateObjects,
                          onSelected: () => setState(
                            () => _placement = PdfPlacementMode.separateObjects,
                          ),
                        ),
                        _ModeChip(
                          label: 'Als neue Whiteboard-Seiten',
                          icon: Icons.post_add_rounded,
                          selected:
                              _placement == PdfPlacementMode.newWhiteboardPages,
                          onSelected: () => setState(
                            () => _placement =
                                PdfPlacementMode.newWhiteboardPages,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const minimumCardWidth = 158.0;
                  final columns = math.max(
                    1,
                    (constraints.maxWidth / minimumCardWidth).floor(),
                  );
                  return GridView.builder(
                    key: const ValueKey('pdf-page-preview-grid'),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: _pageCount,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      childAspectRatio: .72,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                    ),
                    itemBuilder: (context, index) {
                      final selected =
                          _mode == RadialPdfImportMode.allPages ||
                          _selected.contains(index);
                      return _PdfPageCard(
                        key: ValueKey('pdf-page-${index + 1}'),
                        document: widget.document,
                        index: index,
                        selected: selected,
                        selectionEnabled: _mode != RadialPdfImportMode.allPages,
                        onTap: () => _togglePage(index),
                      );
                    },
                  );
                },
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _selectionSummary(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Abbrechen'),
                      ),
                      FilledButton.icon(
                        onPressed:
                            _pageCount == 0 ||
                                (_mode != RadialPdfImportMode.allPages &&
                                    _selected.isEmpty)
                            ? null
                            : () => Navigator.pop(context, _selection()),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Einfügen'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _selectionSummary() => switch (_mode) {
    RadialPdfImportMode.allPages =>
      'Alle $_pageCount Seiten werden ${_placementSummary()}.',
    RadialPdfImportMode.singlePage =>
      _selected.isEmpty
          ? 'Bitte eine Seite auswählen.'
          : 'Seite ${_selected.first + 1} wird ${_placementSummary()}.',
    RadialPdfImportMode.pageRange =>
      _selected.isEmpty
          ? 'Bitte mindestens eine Seite auswählen.'
          : '${_selected.length} Seiten werden ${_placementSummary()}: '
                '${(_selected.toList()..sort()).map((i) => i + 1).join(', ')}',
  };

  String _placementSummary() => switch (_placement) {
    PdfPlacementMode.bundledObject => 'in einem PDF-Objekt gebündelt',
    PdfPlacementMode.separateObjects => 'als einzelne Objekte eingefügt',
    PdfPlacementMode.newWhiteboardPages =>
      'als eigene Whiteboard-Seiten eingefügt',
  };
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      selected: selected,
      onSelected: (_) => onSelected(),
      avatar: Icon(icon, size: 19),
      label: Text(label),
    );
  }
}

class _PdfPageCard extends StatelessWidget {
  const _PdfPageCard({
    required this.document,
    required this.index,
    required this.selected,
    required this.selectionEnabled,
    required this.onTap,
    super.key,
  });

  final PdfDocument document;
  final int index;
  final bool selected;
  final bool selectionEnabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: 'PDF-Seite ${index + 1}',
      selected: selected,
      button: selectionEnabled,
      child: Material(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: selectionEnabled ? onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? colors.primary : colors.outlineVariant,
                width: selected ? 3 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ColoredBox(
                    color: Colors.white,
                    child: PdfPageView(
                      document: document,
                      pageNumber: index + 1,
                      maximumDpi: 110,
                      decoration: const BoxDecoration(color: Colors.white),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Expanded(child: Text('Seite ${index + 1}')),
                      if (selectionEnabled)
                        Icon(
                          selected
                              ? Icons.check_circle_rounded
                              : Icons.circle_outlined,
                          color: selected
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
