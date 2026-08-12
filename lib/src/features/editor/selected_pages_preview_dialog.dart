import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../domain/model/document.dart';
import '../library/document_preview.dart';

final class SelectedPagesRequest {
  const SelectedPagesRequest({required this.pageIds, required this.title});

  /// Page IDs in the exact order in which the user selected them.
  final List<String> pageIds;
  final String title;
}

/// Pen-friendly preview for assembling a new whiteboard from existing pages.
class SelectedPagesPreviewDialog extends StatefulWidget {
  const SelectedPagesPreviewDialog({
    required this.pages,
    required this.thumbnails,
    required this.suggestedTitle,
    super.key,
  });

  final List<BoardPage> pages;
  final Map<String, ui.Image> thumbnails;
  final String suggestedTitle;

  static Future<SelectedPagesRequest?> show(
    BuildContext context, {
    required List<BoardPage> pages,
    required Map<String, ui.Image> thumbnails,
    required String suggestedTitle,
  }) => showDialog<SelectedPagesRequest>(
    context: context,
    builder: (_) => SelectedPagesPreviewDialog(
      pages: pages,
      thumbnails: thumbnails,
      suggestedTitle: suggestedTitle,
    ),
  );

  @override
  State<SelectedPagesPreviewDialog> createState() =>
      _SelectedPagesPreviewDialogState();
}

class _SelectedPagesPreviewDialogState
    extends State<SelectedPagesPreviewDialog> {
  late final TextEditingController _titleController = TextEditingController(
    text: widget.suggestedTitle,
  );
  final List<String> _orderedSelection = <String>[];

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final titleValid = _titleController.text.trim().isNotEmpty;
    return Dialog(
      backgroundColor: FlowboardColors.panel,
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: SizedBox(
        width: math.min(1180, math.max(0, viewport.width - 40)),
        height: math.min(780, math.max(0, viewport.height - 40)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.library_add_outlined,
                    color: FlowboardColors.mint,
                    size: 32,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Seiten in neues Whiteboard übernehmen',
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
              const SizedBox(height: 6),
              Text(
                _orderedSelection.isEmpty
                    ? 'Tippe die gewünschten Seiten in der gewünschten Reihenfolge an.'
                    : '${_orderedSelection.length} Seite${_orderedSelection.length == 1 ? '' : 'n'} ausgewählt · Die Nummern zeigen die neue Reihenfolge.',
                key: const ValueKey('selected-pages-order-help'),
                style: const TextStyle(color: FlowboardColors.textSecondary),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('selected-pages-title'),
                controller: _titleController,
                autofocus: false,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Name des neuen Whiteboards',
                  prefixIcon: Icon(Icons.edit_note_rounded),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = (constraints.maxWidth / 230).floor().clamp(
                      1,
                      5,
                    );
                    return GridView.builder(
                      key: const ValueKey('selected-pages-preview-grid'),
                      itemCount: widget.pages.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: 14,
                        crossAxisSpacing: 14,
                        mainAxisExtent: math.min(
                          190,
                          math.max(36, constraints.maxHeight),
                        ),
                      ),
                      itemBuilder: (context, index) {
                        final page = widget.pages[index];
                        final selectionIndex = _orderedSelection.indexOf(
                          page.id,
                        );
                        return _SelectablePagePreview(
                          key: ValueKey('selected-page-${page.id}'),
                          page: page,
                          pageNumber: index + 1,
                          selectionNumber: selectionIndex < 0
                              ? null
                              : selectionIndex + 1,
                          thumbnail: widget.thumbnails[page.id],
                          onTap: () => _toggle(page.id),
                        );
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  TextButton(
                    onPressed: _orderedSelection.length == widget.pages.length
                        ? null
                        : () => setState(() {
                            for (final page in widget.pages) {
                              if (!_orderedSelection.contains(page.id)) {
                                _orderedSelection.add(page.id);
                              }
                            }
                          }),
                    child: const Text('Alle ergänzen'),
                  ),
                  TextButton(
                    onPressed: _orderedSelection.isEmpty
                        ? null
                        : () => setState(_orderedSelection.clear),
                    child: const Text('Auswahl aufheben'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Abbrechen'),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('create-selected-pages-document'),
                    onPressed: _orderedSelection.isEmpty || !titleValid
                        ? null
                        : () => Navigator.pop(
                            context,
                            SelectedPagesRequest(
                              pageIds: List<String>.unmodifiable(
                                _orderedSelection,
                              ),
                              title: _titleController.text.trim(),
                            ),
                          ),
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('Neues Whiteboard erstellen'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _toggle(String pageId) {
    setState(() {
      if (!_orderedSelection.remove(pageId)) _orderedSelection.add(pageId);
    });
  }
}

class _SelectablePagePreview extends StatelessWidget {
  const _SelectablePagePreview({
    required this.page,
    required this.pageNumber,
    required this.selectionNumber,
    required this.thumbnail,
    required this.onTap,
    super.key,
  });

  final BoardPage page;
  final int pageNumber;
  final int? selectionNumber;
  final ui.Image? thumbnail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final selected = selectionNumber != null;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Seite $pageNumber, ${page.name}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: selected
                ? FlowboardColors.mint.withValues(alpha: .10)
                : FlowboardColors.panelElevated,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? FlowboardColors.mint : FlowboardColors.divider,
              width: selected ? 3 : 1,
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxHeight < 76;
              return Column(
                children: [
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(9),
                          child: ColoredBox(
                            color: Colors.white,
                            child: thumbnail == null
                                ? DocumentPagePreview(page: page)
                                : RawImage(image: thumbnail, fit: BoxFit.cover),
                          ),
                        ),
                        Positioned(
                          right: 8,
                          top: 8,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 120),
                            child: selected
                                ? CircleAvatar(
                                    key: ValueKey(selectionNumber),
                                    radius: 17,
                                    backgroundColor: FlowboardColors.mint,
                                    foregroundColor: Colors.black,
                                    child: Text(
                                      '$selectionNumber',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  )
                                : const CircleAvatar(
                                    key: ValueKey('not-selected'),
                                    radius: 17,
                                    backgroundColor: Color(0xAAFFFFFF),
                                    child: Icon(
                                      Icons.add_rounded,
                                      color: Colors.black54,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!compact) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          '$pageNumber',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            page.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
