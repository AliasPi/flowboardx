import 'package:flutter/material.dart';

/// Compact, participant-scoped page navigation for the editor toolbar.
///
/// The widget deliberately owns no document state. Both one- and two-person
/// workspaces can therefore bind it to the appropriate [EditorController]
/// without page navigation leaking across participant views.
class EditorPageControls extends StatelessWidget {
  const EditorPageControls({
    required this.controlId,
    required this.currentPageIndex,
    required this.pageCount,
    required this.onPrevious,
    required this.onNext,
    required this.onAdd,
    required this.onDelete,
    this.participantLabel,
    this.canAdd = true,
    super.key,
  }) : assert(controlId != ''),
       assert(currentPageIndex >= 0),
       assert(pageCount > 0);

  final String controlId;
  final String? participantLabel;
  final int currentPageIndex;
  final int pageCount;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onAdd;
  final VoidCallback onDelete;
  final bool canAdd;

  String _tooltip(String action) =>
      participantLabel == null ? action : '$action (${participantLabel!})';

  @override
  Widget build(BuildContext context) {
    final canNavigate = pageCount > 1;
    final canDelete = pageCount > 1;
    final current = currentPageIndex.clamp(0, pageCount - 1) + 1;
    return Semantics(
      container: true,
      label: participantLabel == null
          ? 'Seitennavigation'
          : 'Seitennavigation ${participantLabel!}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest.withValues(alpha: .46),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (participantLabel != null)
              Padding(
                padding: const EdgeInsets.only(left: 9, right: 2),
                child: Text(
                  participantLabel!,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            _PageControlButton(
              key: ValueKey<String>('page-$controlId-previous'),
              tooltip: _tooltip('Vorherige Seite'),
              onPressed: canNavigate ? onPrevious : null,
              icon: Icons.chevron_left_rounded,
            ),
            Semantics(
              liveRegion: true,
              label: 'Seite $current von $pageCount',
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 48),
                child: ExcludeSemantics(
                  child: Text(
                    '$current / $pageCount',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
            _PageControlButton(
              key: ValueKey<String>('page-$controlId-next'),
              tooltip: _tooltip('Nächste Seite'),
              onPressed: canNavigate ? onNext : null,
              icon: Icons.chevron_right_rounded,
            ),
            _PageControlButton(
              key: ValueKey<String>('page-$controlId-add'),
              tooltip: _tooltip('Neue Seite'),
              onPressed: canAdd ? onAdd : null,
              icon: Icons.note_add_outlined,
            ),
            _PageControlButton(
              key: ValueKey<String>('page-$controlId-delete'),
              tooltip: canDelete
                  ? _tooltip('Aktuelle Seite löschen')
                  : 'Die letzte Seite kann nicht gelöscht werden',
              onPressed: canDelete ? onDelete : null,
              icon: Icons.delete_outline_rounded,
            ),
          ],
        ),
      ),
    );
  }
}

class _PageControlButton extends StatelessWidget {
  const _PageControlButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    super.key,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon, size: 21),
    visualDensity: VisualDensity.compact,
    padding: const EdgeInsets.all(7),
    constraints: const BoxConstraints.tightFor(width: 38, height: 40),
  );
}
