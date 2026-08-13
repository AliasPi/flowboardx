import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../domain/model/document.dart';
import '../library/document_preview.dart';
import 'editor_controller.dart';

/// Tablet-friendly page overview for durable document organization.
class PageOrganizerDialog extends StatefulWidget {
  const PageOrganizerDialog({
    required this.controller,
    required this.thumbnails,
    super.key,
  });

  final EditorController controller;
  final Map<String, ui.Image> thumbnails;

  static Future<void> show(
    BuildContext context, {
    required EditorController controller,
    required Map<String, ui.Image> thumbnails,
  }) => showDialog<void>(
    context: context,
    builder: (_) =>
        PageOrganizerDialog(controller: controller, thumbnails: thumbnails),
  );

  @override
  State<PageOrganizerDialog> createState() => _PageOrganizerDialogState();
}

class _PageOrganizerDialogState extends State<PageOrganizerDialog> {
  final Set<String> _selectedPageIds = <String>{};
  _PageReorderDrag? _reorderDrag;
  Timer? _reorderReleaseTimer;
  String? _error;

  EditorController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleControllerChanged);
  }

  @override
  void dispose() {
    _reorderReleaseTimer?.cancel();
    _controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    final liveIds = _controller.document.pages.map((page) => page.id).toSet();
    _selectedPageIds.removeWhere((pageId) => !liveIds.contains(pageId));
    // ReorderableListView moves one child into an overlay while dragging. A
    // rebuild with a changed child set during that interval duplicates its
    // internal GlobalKey. Keep the visual snapshot frozen and rebase the drag
    // against the live document only when the pointer is released.
    if (_reorderDrag != null) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final pages = _reorderDrag?.displayPages ?? _controller.document.pages;
    final selectedCount = _selectedPageIds.length;
    return Dialog(
      key: const ValueKey('page-organizer-dialog'),
      backgroundColor: FlowboardColors.panel,
      insetPadding: const EdgeInsets.all(12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: SizedBox(
        width: math.min(1120, math.max(0, viewport.width - 24)),
        height: math.min(820, math.max(0, viewport.height - 24)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(
                    Icons.view_carousel_outlined,
                    color: FlowboardColors.mint,
                    size: 32,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Seiten organisieren',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('page-organizer-close'),
                    tooltip: 'Schließen',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  FilledButton.tonalIcon(
                    key: const ValueKey('page-organizer-add'),
                    onPressed: pages.length >= WhiteboardDocument.maxPageCount
                        ? null
                        : _addPage,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Neue Seite'),
                  ),
                  TextButton.icon(
                    onPressed: selectedCount == pages.length
                        ? null
                        : () => setState(() {
                            _selectedPageIds.addAll(
                              pages.map((page) => page.id),
                            );
                          }),
                    icon: const Icon(Icons.select_all_rounded),
                    label: const Text('Alle auswählen'),
                  ),
                  TextButton(
                    onPressed: selectedCount == 0
                        ? null
                        : () => setState(_selectedPageIds.clear),
                    child: const Text('Auswahl aufheben'),
                  ),
                  Text(
                    '$selectedCount von ${pages.length} ausgewählt',
                    style: const TextStyle(
                      color: FlowboardColors.textSecondary,
                    ),
                  ),
                ],
              ),
              if (_error case final error?) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  error,
                  key: const ValueKey('page-organizer-error'),
                  style: const TextStyle(color: FlowboardColors.danger),
                ),
              ],
              const SizedBox(height: 8),
              Expanded(
                child: ReorderableListView.builder(
                  key: const ValueKey('page-organizer-list'),
                  buildDefaultDragHandles: false,
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: pages.length,
                  onReorder: _reorder,
                  onReorderStart: _latchReorderDrag,
                  onReorderEnd: (_) => _scheduleReorderDragRelease(),
                  proxyDecorator: (child, _, animation) => AnimatedBuilder(
                    animation: animation,
                    child: child,
                    builder: (context, child) => Material(
                      color: Colors.transparent,
                      elevation: 10 * animation.value,
                      borderRadius: BorderRadius.circular(16),
                      child: child,
                    ),
                  ),
                  itemBuilder: (context, index) {
                    final page = pages[index];
                    return Padding(
                      key: ValueKey<String>('page-organizer-item-${page.id}'),
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _OrganizerPageCard(
                        page: page,
                        pageNumber: index + 1,
                        reorderIndex: index,
                        active: page.id == _controller.page.id,
                        selected: _selectedPageIds.contains(page.id),
                        thumbnail: widget.thumbnails[page.id],
                        canDuplicate:
                            pages.length < WhiteboardDocument.maxPageCount,
                        onOpen: () => _openPage(page.id),
                        onToggleSelected: () => setState(() {
                          if (!_selectedPageIds.remove(page.id)) {
                            _selectedPageIds.add(page.id);
                          }
                        }),
                        onRename: () => _rename(page),
                        onDuplicate: () => _duplicate(page.id),
                        onReorderDragCancelled: _scheduleReorderDragRelease,
                      ),
                    );
                  },
                ),
              ),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  FilledButton.tonalIcon(
                    key: const ValueKey('page-organizer-delete-selected'),
                    onPressed: selectedCount == 0 ? null : _deleteSelected,
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: Text(
                      selectedCount == 1
                          ? 'Ausgewählte Seite löschen'
                          : '$selectedCount Seiten löschen',
                    ),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Fertig'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showControllerError(String fallback) {
    setState(() => _error = _controller.lastError ?? fallback);
  }

  void _openPage(String pageId) {
    final index = _controller.document.pageIndexById(pageId);
    if (index == null) {
      setState(() => _error = 'Die Seite existiert nicht mehr.');
      return;
    }
    _error = null;
    _controller.goToPage(index);
  }

  void _addPage() {
    final count = _controller.document.pages.length;
    _error = null;
    _controller.addPage();
    if (_controller.document.pages.length == count) {
      _showControllerError('Die Seite konnte nicht erstellt werden.');
    }
  }

  Future<void> _rename(BoardPage page) async {
    var draft = page.name;
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Seite umbenennen'),
        content: TextFormField(
          key: const ValueKey('page-organizer-rename-field'),
          initialValue: draft,
          autofocus: true,
          maxLength: 120,
          onChanged: (value) => draft = value,
          onFieldSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            key: const ValueKey('page-organizer-confirm-rename'),
            onPressed: () => Navigator.pop(dialogContext, draft),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (!mounted || name == null) return;
    if (!_controller.renamePage(page.id, name)) {
      _showControllerError('Die Seite konnte nicht umbenannt werden.');
    } else {
      setState(() => _error = null);
    }
  }

  void _duplicate(String pageId) {
    if (!_controller.duplicatePage(pageId)) {
      _showControllerError('Die Seite konnte nicht dupliziert werden.');
      return;
    }
    setState(() {
      _error = null;
      _selectedPageIds
        ..clear()
        ..add(_controller.page.id);
    });
  }

  void _reorder(int oldIndex, int newIndex) {
    _reorderReleaseTimer?.cancel();
    final drag = _reorderDrag;
    if (drag == null) {
      setState(
        () => _error =
            'Der Seiten-Drag konnte nicht sicher zugeordnet werden. '
            'Bitte erneut ziehen.',
      );
      return;
    }
    final sourceIndex = drag.sourcePageIds.indexOf(drag.pageId);
    if (sourceIndex < 0) {
      _reorderDrag = null;
      setState(() => _error = 'Die gezogene Seite ist nicht mehr bekannt.');
      return;
    }
    // ReorderableListView reports the slot from the list against which the
    // drag began. Never dereference [oldIndex] against today's live pages: an
    // inserted page could now occupy that stale slot.
    final reportedSourceIsPlausible =
        oldIndex == sourceIndex ||
        (_controller.document.pageIndexById(drag.pageId) == oldIndex);
    if (!reportedSourceIsPlausible) {
      _reorderDrag = null;
      setState(
        () => _error =
            'Die Seitenliste hat sich während des Ziehens unerwartet '
            'geändert. Bitte erneut ziehen.',
      );
      return;
    }
    if (newIndex > sourceIndex) newIndex--;
    if (newIndex < 0 || newIndex >= drag.sourcePageIds.length) {
      _reorderDrag = null;
      setState(() => _error = 'Die Zielposition ist nicht mehr gültig.');
      return;
    }
    final reordered = _controller.reorderPageFromDrag(
      pageId: drag.pageId,
      sourcePageIds: drag.sourcePageIds,
      insertionIndex: newIndex,
    );
    // Keep the snapshot latched through the synchronous history notification;
    // releasing it afterwards prevents the list from rebuilding mid-drop.
    _reorderDrag = null;
    if (!reordered) {
      _showControllerError('Die Seiten konnten nicht sortiert werden.');
    } else {
      setState(() => _error = null);
    }
  }

  void _latchReorderDrag(int index) {
    _reorderReleaseTimer?.cancel();
    final displayPages = _controller.document.pages;
    if (index < 0 || index >= displayPages.length) {
      _reorderDrag = null;
      return;
    }
    final pageId = displayPages[index].id;
    final sourcePageIds = displayPages
        .map((page) => page.id)
        .toList(growable: false);
    if (!sourcePageIds.contains(pageId)) {
      _reorderDrag = null;
      return;
    }
    _reorderDrag = _PageReorderDrag(
      pageId: pageId,
      sourcePageIds: List<String>.unmodifiable(sourcePageIds),
      displayPages: List<BoardPage>.unmodifiable(displayPages),
    );
  }

  void _scheduleReorderDragRelease() {
    if (_reorderDrag == null) return;
    _reorderReleaseTimer?.cancel();
    // Flutter finishes the proxy's drop animation after `onReorderEnd` and
    // invokes `onReorder` only afterwards. Keep the frozen child snapshot
    // alive through that 250 ms framework animation, while still guaranteeing
    // cleanup when a drag is cancelled or returns to its original slot.
    _reorderReleaseTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted || _reorderDrag == null) return;
      setState(() => _reorderDrag = null);
    });
  }

  Future<void> _deleteSelected() async {
    final pages = _controller.document.pages;
    final selected = pages
        .where((page) => _selectedPageIds.contains(page.id))
        .toList(growable: false);
    if (selected.isEmpty) return;
    if (selected.length >= pages.length) {
      setState(() => _error = 'Mindestens eine Seite muss erhalten bleiben.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          selected.length == 1
              ? 'Ausgewählte Seite löschen?'
              : '${selected.length} Seiten löschen?',
        ),
        content: const Text(
          'Die Seiten und ihr gesamter Inhalt werden entfernt. '
          'Die Aktion kann anschließend rückgängig gemacht werden.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton.tonalIcon(
            key: const ValueKey('page-organizer-confirm-delete'),
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final ids = selected.map((page) => page.id).toSet();
    if (!_controller.deletePages(ids)) {
      _showControllerError('Die Seiten konnten nicht gelöscht werden.');
      return;
    }
    setState(() {
      _error = null;
      _selectedPageIds.removeAll(ids);
    });
  }
}

enum _PageCardAction { rename, duplicate }

final class _PageReorderDrag {
  const _PageReorderDrag({
    required this.pageId,
    required this.sourcePageIds,
    required this.displayPages,
  });

  final String pageId;
  final List<String> sourcePageIds;
  final List<BoardPage> displayPages;
}

class _OrganizerPageCard extends StatelessWidget {
  const _OrganizerPageCard({
    required this.page,
    required this.pageNumber,
    required this.reorderIndex,
    required this.active,
    required this.selected,
    required this.thumbnail,
    required this.canDuplicate,
    required this.onOpen,
    required this.onToggleSelected,
    required this.onRename,
    required this.onDuplicate,
    required this.onReorderDragCancelled,
  });

  final BoardPage page;
  final int pageNumber;
  final int reorderIndex;
  final bool active;
  final bool selected;
  final ui.Image? thumbnail;
  final bool canDuplicate;
  final VoidCallback onOpen;
  final VoidCallback onToggleSelected;
  final VoidCallback onRename;
  final VoidCallback onDuplicate;
  final VoidCallback onReorderDragCancelled;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 600;
      return Material(
        color: selected
            ? FlowboardColors.mint.withValues(alpha: .09)
            : FlowboardColors.panelElevated,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Container(
            height: compact ? 116 : 142,
            decoration: BoxDecoration(
              border: Border.all(
                color: active || selected
                    ? FlowboardColors.mint
                    : FlowboardColors.divider,
                width: active || selected ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.all(8),
            child: Row(
              children: <Widget>[
                IconButton(
                  key: ValueKey<String>('page-organizer-select-${page.id}'),
                  tooltip: selected ? 'Auswahl aufheben' : 'Seite auswählen',
                  onPressed: onToggleSelected,
                  icon: Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    color: selected
                        ? FlowboardColors.mint
                        : FlowboardColors.textSecondary,
                  ),
                ),
                SizedBox(
                  width: compact ? 92 : 190,
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: ColoredBox(
                        color: Colors.white,
                        child: thumbnail == null
                            ? DocumentPagePreview(page: page)
                            : RawImage(image: thumbnail, fit: BoxFit.cover),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '$pageNumber',
                        style: const TextStyle(
                          color: FlowboardColors.textSecondary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        page.name,
                        maxLines: compact ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (active) ...<Widget>[
                        const SizedBox(height: 5),
                        const Text(
                          'Aktive Seite',
                          style: TextStyle(
                            color: FlowboardColors.mint,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (compact)
                  PopupMenuButton<_PageCardAction>(
                    key: ValueKey<String>('page-organizer-menu-${page.id}'),
                    tooltip: 'Seitenaktionen',
                    onSelected: (action) {
                      switch (action) {
                        case _PageCardAction.rename:
                          onRename();
                        case _PageCardAction.duplicate:
                          onDuplicate();
                      }
                    },
                    itemBuilder: (_) => <PopupMenuEntry<_PageCardAction>>[
                      const PopupMenuItem<_PageCardAction>(
                        value: _PageCardAction.rename,
                        child: ListTile(
                          leading: Icon(Icons.edit_outlined),
                          title: Text('Umbenennen'),
                        ),
                      ),
                      PopupMenuItem<_PageCardAction>(
                        value: _PageCardAction.duplicate,
                        enabled: canDuplicate,
                        child: const ListTile(
                          leading: Icon(Icons.copy_all_outlined),
                          title: Text('Duplizieren'),
                        ),
                      ),
                    ],
                  )
                else ...<Widget>[
                  IconButton(
                    key: ValueKey<String>('page-organizer-rename-${page.id}'),
                    tooltip: 'Seite umbenennen',
                    onPressed: onRename,
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    key: ValueKey<String>(
                      'page-organizer-duplicate-${page.id}',
                    ),
                    tooltip: 'Seite duplizieren',
                    onPressed: canDuplicate ? onDuplicate : null,
                    icon: const Icon(Icons.copy_all_outlined),
                  ),
                ],
                Listener(
                  key: ValueKey<String>('page-organizer-drag-${page.id}'),
                  behavior: HitTestBehavior.opaque,
                  onPointerUp: (_) => onReorderDragCancelled(),
                  onPointerCancel: (_) => onReorderDragCancelled(),
                  child: ReorderableDragStartListener(
                    index: reorderIndex,
                    child: const Tooltip(
                      message: 'Ziehen, um die Seite zu verschieben',
                      child: SizedBox.square(
                        dimension: 48,
                        child: Icon(Icons.drag_handle_rounded),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
