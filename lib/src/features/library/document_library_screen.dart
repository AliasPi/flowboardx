import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../data/document_repository.dart';
import '../../domain/model/document.dart';
import '../../domain/model/library_organization.dart';
import '../export_share/infrastructure/local_pdf_share_server.dart';
import 'document_library_controller.dart';
import 'document_preview.dart';
import 'library_archive_service.dart';

typedef DocumentLibraryOpenCallback =
    FutureOr<void> Function(
      WhiteboardDocument document,
      Directory assetDirectory,
    );

@immutable
class DocumentLibraryThemeData {
  const DocumentLibraryThemeData({
    this.background = const Color(0xFF111416),
    this.surface = const Color(0xFF1A1F22),
    this.surfaceRaised = const Color(0xFF252B2F),
    this.outline = const Color(0xFF343B40),
    this.primary = const Color(0xFF4DE2B1),
    this.text = const Color(0xFFF4F7F8),
    this.mutedText = const Color(0xFFAAB4BA),
    this.warning = const Color(0xFFFFC857),
    this.danger = const Color(0xFFFF6B72),
  });

  final Color background;
  final Color surface;
  final Color surfaceRaised;
  final Color outline;
  final Color primary;
  final Color text;
  final Color mutedText;
  final Color warning;
  final Color danger;
}

/// Responsive, touch-first overview for local whiteboard documents.
class DocumentLibraryScreen extends StatefulWidget {
  const DocumentLibraryScreen({
    required this.repository,
    required this.onOpen,
    super.key,
    this.title = 'Whiteboards',
    this.theme = const DocumentLibraryThemeData(),
    this.documentIdFactory,
    this.folderIdFactory,
    this.clock,
    this.onDocumentsChanged,
    this.archiveService,
    this.archiveShareServerFactory,
  });

  final DocumentRepository repository;
  final DocumentLibraryOpenCallback onOpen;
  final String title;
  final DocumentLibraryThemeData theme;
  final DocumentIdFactory? documentIdFactory;
  final FolderIdFactory? folderIdFactory;
  final DocumentLibraryClock? clock;
  final FutureOr<void> Function()? onDocumentsChanged;
  final LibraryArchiveService? archiveService;
  final LocalPdfShareServer Function()? archiveShareServerFactory;

  @override
  State<DocumentLibraryScreen> createState() => _DocumentLibraryScreenState();
}

class _DocumentLibraryScreenState extends State<DocumentLibraryScreen> {
  late DocumentLibraryController _controller;
  late LibraryArchiveService _archiveService;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _createController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_controller.reload());
    });
  }

  void _createController() {
    _controller = DocumentLibraryController(
      repository: widget.repository,
      documentIdFactory: widget.documentIdFactory,
      folderIdFactory: widget.folderIdFactory,
      clock: widget.clock,
    )..addListener(_onControllerChanged);
    _archiveService =
        widget.archiveService ??
        LibraryArchiveService(repository: widget.repository);
  }

  @override
  void didUpdateWidget(covariant DocumentLibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.repository, widget.repository) ||
        oldWidget.documentIdFactory != widget.documentIdFactory ||
        oldWidget.folderIdFactory != widget.folderIdFactory ||
        oldWidget.clock != widget.clock) {
      _controller
        ..removeListener(_onControllerChanged)
        ..dispose();
      _createController();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_controller.reload());
      });
    } else if (!identical(oldWidget.archiveService, widget.archiveService)) {
      _archiveService =
          widget.archiveService ??
          LibraryArchiveService(repository: widget.repository);
    }
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onControllerChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.theme;
    return Theme(
      data: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: colors.primary,
          brightness: Brightness.dark,
          surface: colors.surface,
          error: colors.danger,
        ),
        scaffoldBackgroundColor: colors.background,
        splashFactory: InkSparkle.splashFactory,
      ),
      child: Scaffold(
        backgroundColor: colors.background,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final horizontalPadding = constraints.maxWidth >= 900
                  ? 40.0
                  : 20.0;
              return RefreshIndicator(
                color: colors.primary,
                backgroundColor: colors.surfaceRaised,
                onRefresh: _controller.reload,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: <Widget>[
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        22,
                        horizontalPadding,
                        18,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: _buildHeader(
                          colors,
                          compact: constraints.maxWidth < 650,
                        ),
                      ),
                    ),
                    if (_controller.operationError case final error?)
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          horizontalPadding,
                          0,
                          horizontalPadding,
                          18,
                        ),
                        sliver: SliverToBoxAdapter(
                          child: _OperationErrorBanner(
                            message: error,
                            theme: colors,
                            onDismiss: _controller.clearOperationError,
                          ),
                        ),
                      ),
                    if (_controller.loadError case final error?)
                      if (_controller.entries.isNotEmpty)
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(
                            horizontalPadding,
                            0,
                            horizontalPadding,
                            18,
                          ),
                          sliver: SliverToBoxAdapter(
                            child: _OperationErrorBanner(
                              message: error,
                              theme: colors,
                              onDismiss: _controller.clearLoadError,
                            ),
                          ),
                        ),
                    if (_controller.status == DocumentLibraryStatus.loading &&
                        _controller.entries.isNotEmpty)
                      SliverToBoxAdapter(
                        child: LinearProgressIndicator(
                          key: const ValueKey<String>('library-refreshing'),
                          color: colors.primary,
                          backgroundColor: colors.surface,
                          minHeight: 2,
                        ),
                      ),
                    ..._buildPinnedDropTargetSlivers(colors, horizontalPadding),
                    ..._buildContentSlivers(colors, horizontalPadding),
                    const SliverToBoxAdapter(child: SizedBox(height: 32)),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(
    DocumentLibraryThemeData colors, {
    required bool compact,
  }) {
    if (_controller.hasSelection) return _buildSelectionHeader(colors);
    final activeFolder = _controller.activeFolder;
    final identity = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        if (activeFolder != null)
          _LargeIconButton(
            key: const ValueKey<String>('folder-back-button'),
            tooltip: 'Zur Dokumentübersicht',
            icon: Icons.arrow_back_rounded,
            onPressed: () => _controller.openFolder(null),
            theme: colors,
          )
        else
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: colors.surfaceRaised,
              borderRadius: BorderRadius.circular(17),
              border: Border.all(color: colors.outline),
            ),
            child: Icon(Icons.gesture_rounded, color: colors.primary, size: 30),
          ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                activeFolder?.name ?? widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 28,
                  height: 1.05,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.6,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                activeFolder == null
                    ? (_controller.entries.isEmpty
                          ? 'Lokal und offline verfügbar'
                          : '${_controller.entries.length} ${_controller.entries.length == 1 ? 'Dokument' : 'Dokumente'}  •  ${_controller.folders.length} ${_controller.folders.length == 1 ? 'Ordner' : 'Ordner'}')
                    : '${_controller.visibleEntries.length} ${_controller.visibleEntries.length == 1 ? 'Dokument' : 'Dokumente'}',
                style: TextStyle(color: colors.mutedText, fontSize: 14),
              ),
            ],
          ),
        ),
        if (_controller.trashSupported) ...<Widget>[
          _LargeIconButton(
            key: const ValueKey<String>('library-trash-button'),
            tooltip: _controller.trashedDocuments.isEmpty
                ? 'Papierkorb'
                : 'Papierkorb (${_controller.trashedDocuments.length})',
            icon: _controller.trashedDocuments.isEmpty
                ? Icons.delete_outline_rounded
                : Icons.delete_rounded,
            onPressed: _showTrash,
            theme: colors,
          ),
          const SizedBox(width: 8),
        ],
        _LargeIconButton(
          tooltip: 'Dokumente neu laden',
          icon: Icons.refresh_rounded,
          onPressed: _controller.status == DocumentLibraryStatus.loading
              ? null
              : () => unawaited(_controller.reload()),
          theme: colors,
        ),
        if (activeFolder == null) ...<Widget>[
          const SizedBox(width: 8),
          _LargeIconButton(
            key: const ValueKey<String>('new-folder-button'),
            tooltip: 'Neuer Ordner',
            icon: Icons.create_new_folder_outlined,
            onPressed: _controller.isOrganizing ? null : _createFolder,
            theme: colors,
          ),
        ],
      ],
    );
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          identity,
          const SizedBox(height: 14),
          _buildNewDocumentButton(colors),
        ],
      );
    }
    return Row(
      children: <Widget>[
        Expanded(child: identity),
        const SizedBox(width: 10),
        _buildNewDocumentButton(colors),
      ],
    );
  }

  Widget _buildSelectionHeader(DocumentLibraryThemeData colors) {
    final count = _controller.selectedDocumentIds.length;
    return Container(
      key: const ValueKey<String>('document-selection-toolbar'),
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.primary.withValues(alpha: .55)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            _LargeIconButton(
              tooltip: 'Auswahl beenden',
              icon: Icons.close_rounded,
              onPressed: _sharing ? null : _controller.clearSelection,
              theme: colors,
            ),
            const SizedBox(width: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 150),
              child: Text(
                '$count ${count == 1 ? 'Dokument ausgewählt' : 'Dokumente ausgewählt'}',
                maxLines: 1,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            _LargeIconButton(
              tooltip: 'Alle sichtbaren auswählen',
              icon: Icons.select_all_rounded,
              onPressed: _sharing ? null : _controller.selectAllVisible,
              theme: colors,
            ),
            const SizedBox(width: 6),
            _LargeIconButton(
              key: const ValueKey<String>('move-selected-button'),
              tooltip: 'In Ordner verschieben',
              icon: Icons.drive_file_move_outline,
              onPressed: _sharing ? null : _moveSelectedDocuments,
              theme: colors,
            ),
            const SizedBox(width: 6),
            _LargeIconButton(
              key: const ValueKey<String>('share-selected-button'),
              tooltip: 'Als ZIP teilen',
              icon: _sharing
                  ? Icons.hourglass_top_rounded
                  : Icons.share_outlined,
              onPressed: _sharing ? null : _shareSelectedDocuments,
              theme: colors,
            ),
            const SizedBox(width: 6),
            _LargeIconButton(
              key: const ValueKey<String>('delete-selected-button'),
              tooltip: 'Ausgewählte löschen',
              icon: Icons.delete_outline_rounded,
              onPressed: _sharing ? null : _deleteSelectedDocuments,
              theme: colors,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNewDocumentButton(DocumentLibraryThemeData colors) {
    return FilledButton.icon(
      key: const ValueKey<String>('new-document-button'),
      onPressed:
          _controller.isCreating ||
              _controller.status == DocumentLibraryStatus.loading
          ? null
          : _createDocument,
      icon: _controller.isCreating
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.add_rounded),
      label: const Text('Neues Whiteboard'),
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 54),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        backgroundColor: colors.primary,
        foregroundColor: const Color(0xFF08241C),
        disabledBackgroundColor: colors.surfaceRaised,
        disabledForegroundColor: colors.mutedText,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    );
  }

  List<Widget> _buildPinnedDropTargetSlivers(
    DocumentLibraryThemeData colors,
    double horizontalPadding,
  ) {
    if (_controller.visibleEntries.isEmpty) return const <Widget>[];
    final activeFolder = _controller.activeFolder;
    final destinationFolders = activeFolder == null
        ? _controller.folders
        : _controller.folders
              .where((folder) => folder.id != activeFolder.id)
              .toList(growable: false);
    final showRootTarget = activeFolder != null;
    if (!showRootTarget && destinationFolders.isEmpty) {
      return const <Widget>[];
    }
    return <Widget>[
      SliverPersistentHeader(
        pinned: true,
        delegate: _PinnedFolderDropTargetDelegate(
          extent: 88,
          background: colors.background,
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            6,
            horizontalPadding,
            6,
          ),
          child: _FolderDropTargetStrip(
            key: const ValueKey<String>('folder-drop-target-strip'),
            folders: destinationFolders,
            showRootTarget: showRootTarget,
            theme: colors,
            busy: _controller.isOrganizing || _sharing,
            canAcceptRoot: (ids) =>
                ids.isNotEmpty &&
                ids.any((id) => _controller.folderIdForDocument(id) != null),
            canAcceptFolder: (ids, folder) =>
                ids.isNotEmpty &&
                ids.any(
                  (id) => _controller.folderIdForDocument(id) != folder.id,
                ),
            onAcceptRoot: _dropDocumentsIntoRoot,
            onAcceptFolder: _dropDocumentsIntoFolder,
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildContentSlivers(
    DocumentLibraryThemeData colors,
    double horizontalPadding,
  ) {
    if (_controller.status == DocumentLibraryStatus.loading &&
        _controller.entries.isEmpty) {
      return <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: _CenteredState(
            key: const ValueKey<String>('library-loading'),
            icon: Icons.folder_open_rounded,
            title: 'Dokumente werden geladen',
            message: 'Vorschauen werden sicher vorbereitet …',
            theme: colors,
            loading: true,
          ),
        ),
      ];
    }
    if (_controller.status == DocumentLibraryStatus.error &&
        _controller.entries.isEmpty) {
      return <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: _CenteredState(
            key: const ValueKey<String>('library-error'),
            icon: Icons.folder_off_outlined,
            title: 'Dokumente nicht verfügbar',
            message: _controller.loadError ?? 'Bitte versuche es erneut.',
            theme: colors,
            actionLabel: 'Erneut laden',
            onAction: () => unawaited(_controller.reload()),
          ),
        ),
      ];
    }
    if (_controller.status == DocumentLibraryStatus.ready &&
        _controller.entries.isEmpty &&
        _controller.folders.isEmpty) {
      return <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: _CenteredState(
            key: const ValueKey<String>('library-empty'),
            icon: Icons.space_dashboard_outlined,
            title: 'Noch kein Whiteboard',
            message:
                'Erstelle eine neue Fläche und beginne direkt zu schreiben.',
            theme: colors,
            actionLabel: 'Neues Whiteboard',
            onAction: _createDocument,
          ),
        ),
      ];
    }
    final entries = _controller.visibleEntries;
    if (_controller.activeFolder != null && entries.isEmpty) {
      return <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: _CenteredState(
            key: const ValueKey<String>('folder-empty'),
            icon: Icons.folder_open_rounded,
            title: 'Dieser Ordner ist leer',
            message:
                'Erstelle hier ein Whiteboard oder verschiebe Dokumente in diesen Ordner.',
            theme: colors,
            actionLabel: 'Neues Whiteboard',
            onAction: _createDocument,
          ),
        ),
      ];
    }

    return <Widget>[
      if (_controller.activeFolder == null &&
          _controller.folders.isNotEmpty) ...<Widget>[
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            0,
            horizontalPadding,
            10,
          ),
          sliver: SliverToBoxAdapter(
            child: Text(
              'Ordner',
              style: TextStyle(
                color: colors.text,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 430,
              mainAxisExtent: 126,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final folder = _controller.folders[index];
              return _FolderCard(
                key: ValueKey<String>('folder-card-${folder.id}'),
                folder: folder,
                documentCount: _controller.documentCountInFolder(folder.id),
                theme: colors,
                busy: _controller.isOrganizing || _sharing,
                onOpen: () => _controller.openFolder(folder.id),
                onRename: () => _renameFolder(folder),
                onShare: () => _shareFolder(folder),
                onDelete: () => _deleteFolder(folder),
                onAcceptDocuments: (ids) =>
                    _dropDocumentsIntoFolder(ids, folder),
                canAcceptDocuments: (ids) =>
                    !_controller.isOrganizing &&
                    !_sharing &&
                    ids.isNotEmpty &&
                    ids.any(
                      (id) => _controller.folderIdForDocument(id) != folder.id,
                    ),
              );
            }, childCount: _controller.folders.length),
          ),
        ),
        if (entries.isNotEmpty)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              24,
              horizontalPadding,
              10,
            ),
            sliver: SliverToBoxAdapter(
              child: Text(
                'Nicht abgelegt',
                style: TextStyle(
                  color: colors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
      if (entries.isNotEmpty)
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 430,
              mainAxisExtent: 304,
              mainAxisSpacing: 18,
              crossAxisSpacing: 18,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final entry = entries[index];
              final id = entry.summary.id;
              return _DocumentCard(
                key: ValueKey<String>('document-card-$id'),
                entry: entry,
                busy: _controller.isBusy(id),
                selected: _controller.selectedDocumentIds.contains(id),
                selectionMode: _controller.hasSelection,
                theme: colors,
                onOpen: () => _openDocument(id),
                onToggleSelection: () =>
                    _controller.toggleDocumentSelection(id),
                onSelect: () => _controller.selectOnlyDocument(id),
                onRename: () => _renameDocument(entry),
                onMove: () => _moveDocuments(<String>{id}),
                onShare: () => _shareDocuments(<String>{id}),
                onDelete: () => _deleteDocument(entry),
                dragDocumentIds: _controller.selectedDocumentIds.contains(id)
                    ? _controller.selectedDocumentIds
                    : <String>{id},
              );
            }, childCount: entries.length),
          ),
        ),
    ];
  }

  Future<void> _createDocument() async {
    final result = await _controller.createDocument();
    if (!mounted || result == null) return;
    await _dispatchOpen(result);
  }

  Future<void> _openDocument(String documentId) async {
    final result = await _controller.openDocument(documentId);
    if (!mounted || result == null) return;
    await _dispatchOpen(result);
  }

  Future<void> _dispatchOpen(DocumentLibraryOpenResult result) async {
    try {
      await widget.onOpen(result.document, result.assetDirectory);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Der Editor konnte nicht geöffnet werden.'),
        ),
      );
    }
  }

  Future<void> _renameDocument(DocumentLibraryEntry entry) async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDocumentDialog(initialTitle: entry.summary.title),
    );
    if (!mounted || title == null || title.trim().isEmpty) return;
    final renamed = await _controller.renameDocument(entry.summary.id, title);
    if (mounted && renamed) {
      unawaited(Future.sync(() => widget.onDocumentsChanged?.call()));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Whiteboard umbenannt.')));
    }
  }

  Future<void> _deleteDocument(DocumentLibraryEntry entry) async {
    final movesToTrash = _controller.trashSupported;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(Icons.delete_outline_rounded, color: widget.theme.danger),
        title: const Text('Whiteboard löschen?'),
        content: Text(
          movesToTrash
              ? '„${entry.summary.title}“ wird mit allen zugehörigen lokalen Dateien in den Papierkorb verschoben.'
              : '„${entry.summary.title}“ und alle zugehörigen lokalen Dateien werden dauerhaft gelöscht.',
        ),
        actions: <Widget>[
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            key: const ValueKey<String>('confirm-delete-button'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(64, 48),
              backgroundColor: widget.theme.danger,
              foregroundColor: const Color(0xFF2B080A),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(movesToTrash ? 'In Papierkorb' : 'Löschen'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final deleted = await _controller.deleteDocument(entry.summary.id);
    if (mounted && deleted) {
      unawaited(Future.sync(() => widget.onDocumentsChanged?.call()));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            movesToTrash
                ? 'Whiteboard in den Papierkorb verschoben.'
                : 'Whiteboard gelöscht.',
          ),
        ),
      );
    }
  }

  Future<void> _createFolder() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _FolderNameDialog(title: 'Neuer Ordner'),
    );
    if (!mounted || name == null) return;
    final folder = await _controller.createFolder(name);
    if (mounted && folder != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ordner „${folder.name}“ erstellt.')),
      );
    }
  }

  Future<void> _renameFolder(LibraryFolder folder) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _FolderNameDialog(
        title: 'Ordner umbenennen',
        initialName: folder.name,
      ),
    );
    if (!mounted || name == null) return;
    final renamed = await _controller.renameFolder(folder.id, name);
    if (mounted && renamed) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Ordner umbenannt.')));
    }
  }

  Future<void> _deleteFolder(LibraryFolder folder) async {
    final count = _controller.documentCountInFolder(folder.id);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(Icons.folder_delete_outlined, color: widget.theme.warning),
        title: const Text('Ordner entfernen?'),
        content: Text(
          count == 0
              ? 'Der leere Ordner „${folder.name}“ wird entfernt.'
              : 'Der Ordner „${folder.name}“ wird entfernt. Seine $count Dokumente bleiben erhalten und werden nach „Nicht abgelegt“ verschoben.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            key: const ValueKey<String>('confirm-delete-folder-button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Ordner entfernen'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final deleted = await _controller.deleteFolder(folder.id);
    if (mounted && deleted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ordner entfernt; Dokumente behalten.')),
      );
    }
  }

  Future<void> _deleteSelectedDocuments() async {
    final ids = _controller.selectedDocumentIds;
    if (ids.isEmpty) return;
    final count = ids.length;
    final movesToTrash = _controller.trashSupported;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(Icons.delete_outline_rounded, color: widget.theme.danger),
        title: Text(
          '$count ${count == 1 ? 'Whiteboard' : 'Whiteboards'} löschen?',
        ),
        content: Text(
          movesToTrash
              ? 'Die ausgewählten Dokumente werden mit ihren lokalen Dateien in den Papierkorb verschoben.'
              : 'Die ausgewählten Dokumente und ihre lokalen Dateien werden dauerhaft gelöscht.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            key: const ValueKey<String>('confirm-batch-delete-button'),
            style: FilledButton.styleFrom(
              backgroundColor: widget.theme.danger,
              foregroundColor: const Color(0xFF2B080A),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(movesToTrash ? 'In Papierkorb' : 'Endgültig löschen'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final deleted = await _controller.deleteDocuments(ids);
    if (!mounted || deleted.isEmpty) return;
    unawaited(Future.sync(() => widget.onDocumentsChanged?.call()));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          movesToTrash
              ? '${deleted.length} Dokumente in den Papierkorb verschoben.'
              : '${deleted.length} Dokumente gelöscht.',
        ),
      ),
    );
  }

  Future<void> _showTrash() async {
    if (!_controller.trashSupported) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _DocumentTrashDialog(
        controller: _controller,
        theme: widget.theme,
        onRestore: _restoreTrashedDocument,
        onDeletePermanently: _deleteTrashedDocumentPermanently,
      ),
    );
  }

  Future<void> _restoreTrashedDocument(TrashedDocumentSummary document) async {
    final restored = await _controller.restoreTrashedDocument(document.id);
    if (!mounted || !restored) return;
    unawaited(Future.sync(() => widget.onDocumentsChanged?.call()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Whiteboard wiederhergestellt.')),
    );
  }

  Future<void> _deleteTrashedDocumentPermanently(
    TrashedDocumentSummary document,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(Icons.delete_forever_rounded, color: widget.theme.danger),
        title: const Text('Endgültig löschen?'),
        content: Text(
          '„${document.title}“ wird unwiderruflich mit allen lokalen Dateien gelöscht.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            key: const ValueKey<String>('confirm-trash-delete-button'),
            style: FilledButton.styleFrom(
              backgroundColor: widget.theme.danger,
              foregroundColor: const Color(0xFF2B080A),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Endgültig löschen'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final deleted = await _controller.permanentlyDeleteTrashedDocument(
      document.id,
    );
    if (!mounted || !deleted) return;
    unawaited(Future.sync(() => widget.onDocumentsChanged?.call()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Whiteboard endgültig gelöscht.')),
    );
  }

  Future<void> _moveSelectedDocuments() =>
      _moveDocuments(_controller.selectedDocumentIds);

  Future<void> _moveDocuments(Set<String> ids) async {
    if (ids.isEmpty) return;
    final target = await showDialog<_MoveTarget>(
      context: context,
      builder: (_) => _MoveDocumentsDialog(
        folders: _controller.folders,
        currentFolderId: _controller.activeFolderId,
      ),
    );
    if (!mounted || target == null) return;
    final moved = await _controller.moveDocuments(ids, target.folderId);
    if (mounted && moved) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            target.folderId == null
                ? 'Dokumente nach „Nicht abgelegt“ verschoben.'
                : 'Dokumente in den Ordner verschoben.',
          ),
        ),
      );
    }
  }

  Future<void> _dropDocumentsIntoFolder(
    Set<String> ids,
    LibraryFolder folder,
  ) => _dropDocumentsIntoTarget(
    ids,
    folderId: folder.id,
    destination: 'in „${folder.name}“',
  );

  Future<void> _dropDocumentsIntoRoot(Set<String> ids) =>
      _dropDocumentsIntoTarget(ids, destination: 'nach „Nicht abgelegt“');

  Future<void> _dropDocumentsIntoTarget(
    Set<String> ids, {
    String? folderId,
    required String destination,
  }) async {
    if (_sharing || _controller.isOrganizing || ids.isEmpty) return;
    final moved = await _controller.moveDocuments(ids, folderId);
    if (!mounted || !moved) return;
    final count = ids.length;
    _showMessage(
      count == 1
          ? 'Dokument $destination verschoben.'
          : '$count Dokumente $destination verschoben.',
    );
  }

  Future<void> _shareSelectedDocuments() =>
      _shareDocuments(_controller.selectedDocumentIds);

  Future<void> _shareFolder(LibraryFolder folder) async {
    final ids = _controller.entries
        .where(
          (entry) =>
              _controller.folderIdForDocument(entry.summary.id) == folder.id,
        )
        .map((entry) => entry.summary.id)
        .toSet();
    if (ids.isEmpty) {
      _showMessage('Der leere Ordner enthält nichts zum Teilen.');
      return;
    }
    await _shareDocuments(ids, collectionName: folder.name);
  }

  Future<void> _shareDocuments(
    Set<String> ids, {
    String? collectionName,
  }) async {
    if (_sharing || ids.isEmpty) return;
    final target = await showDialog<_ArchiveShareTarget>(
      context: context,
      builder: (_) => const _ArchiveShareTargetDialog(),
    );
    if (!mounted || target == null) return;
    setState(() => _sharing = true);
    File? temporaryArchive;
    var deleteTemporaryArchive = true;
    try {
      temporaryArchive = await _archiveService.createArchive(
        documentIds: ids,
        collectionName: collectionName,
      );
      if (!mounted) return;
      switch (target) {
        case _ArchiveShareTarget.saveLocally:
          final saved = await _archiveService.saveArchiveLocally(
            temporaryArchive,
          );
          if (saved != null && identical(saved, temporaryArchive)) {
            deleteTemporaryArchive = false;
          }
          if (!mounted || saved == null) return;
          _showMessage('ZIP lokal gespeichert: ${saved.path}');
        case _ArchiveShareTarget.quickShare:
          await _archiveService.shareArchive(
            temporaryArchive,
            shareOrigin: _shareOrigin(),
          );
          if (!mounted) return;
          _showMessage('ZIP an Quick Share/Systemfreigabe übergeben.');
        case _ArchiveShareTarget.wlanQr:
          await _shareArchiveViaLan(temporaryArchive);
          if (!mounted) return;
      }
      _controller.clearSelection();
    } on Object catch (error) {
      if (!mounted) return;
      _showMessage(
        error is DocumentStorageException
            ? error.message
            : 'Das ZIP-Archiv konnte nicht geteilt werden.',
        error: true,
      );
    } finally {
      if (deleteTemporaryArchive && temporaryArchive != null) {
        try {
          if (await temporaryArchive.exists()) {
            await temporaryArchive.delete();
          }
        } on FileSystemException {
          // Temporary export cleanup is best-effort; a locked share target
          // must not turn an otherwise successful handoff into an error.
        }
      }
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _shareArchiveViaLan(File archive) async {
    final server =
        widget.archiveShareServerFactory?.call() ?? LocalPdfShareServer();
    try {
      final session = await server.start(
        SharedDownloadSource.file(
          archive,
          contentType: ContentType('application', 'zip'),
        ),
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => _ArchiveQrShareDialog(
          server: server,
          initialSession: session,
          onClose: () => Navigator.of(dialogContext).pop(),
        ),
      );
    } finally {
      await server.close();
    }
  }

  Rect? _shareOrigin() {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    final topLeft = renderObject.localToGlobal(Offset.zero);
    return topLeft & renderObject.size;
  }

  void _showMessage(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? widget.theme.danger : null,
      ),
    );
  }
}

enum _ArchiveShareTarget { saveLocally, quickShare, wlanQr }

class _DocumentTrashDialog extends StatefulWidget {
  const _DocumentTrashDialog({
    required this.controller,
    required this.theme,
    required this.onRestore,
    required this.onDeletePermanently,
  });

  final DocumentLibraryController controller;
  final DocumentLibraryThemeData theme;
  final Future<void> Function(TrashedDocumentSummary document) onRestore;
  final Future<void> Function(TrashedDocumentSummary document)
  onDeletePermanently;

  @override
  State<_DocumentTrashDialog> createState() => _DocumentTrashDialogState();
}

class _DocumentTrashDialogState extends State<_DocumentTrashDialog> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant _DocumentTrashDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
    }
  }

  void _handleControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final height = (MediaQuery.sizeOf(context).height * .58)
        .clamp(260.0, 540.0)
        .toDouble();
    final error = controller.trashError ?? controller.operationError;
    return AlertDialog(
      icon: Icon(Icons.delete_outline_rounded, color: widget.theme.primary),
      title: Row(
        children: <Widget>[
          const Expanded(child: Text('Papierkorb')),
          IconButton(
            key: const ValueKey<String>('trash-refresh-button'),
            tooltip: 'Papierkorb neu laden',
            onPressed: controller.isTrashLoading
                ? null
                : () => unawaited(controller.reloadTrash()),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      content: SizedBox(
        width: 640,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (error != null) ...<Widget>[
              _OperationErrorBanner(
                message: error,
                theme: widget.theme,
                onDismiss: controller.trashError != null
                    ? controller.clearTrashError
                    : controller.clearOperationError,
              ),
              const SizedBox(height: 12),
            ],
            if (controller.isTrashLoading)
              LinearProgressIndicator(
                key: const ValueKey<String>('trash-loading'),
                color: widget.theme.primary,
                backgroundColor: widget.theme.surfaceRaised,
              ),
            if (controller.isTrashLoading) const SizedBox(height: 8),
            Expanded(child: _buildContents(controller)),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Schließen'),
        ),
      ],
    );
  }

  Widget _buildContents(DocumentLibraryController controller) {
    final documents = controller.trashedDocuments;
    if (documents.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.delete_sweep_outlined,
              size: 50,
              color: widget.theme.mutedText,
            ),
            const SizedBox(height: 14),
            Text(
              controller.isTrashLoading
                  ? 'Papierkorb wird geladen …'
                  : 'Der Papierkorb ist leer.',
              textAlign: TextAlign.center,
              style: TextStyle(color: widget.theme.mutedText, fontSize: 16),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: documents.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) => _buildDocument(documents[index]),
    );
  }

  Widget _buildDocument(TrashedDocumentSummary document) {
    final busy = widget.controller.isTrashBusy(document.id);
    final originalFolder = widget.controller.folderById(
      document.originalFolderId,
    );
    final folderDescription = originalFolder != null
        ? 'Ursprünglicher Ordner: ${originalFolder.name}'
        : document.originalFolderId != null
        ? 'Ursprünglicher Ordner existiert nicht mehr'
        : 'Ohne Ordner';
    final pageDescription = document.pageCount == 1
        ? '1 Seite'
        : document.pageCount > 1
        ? '${document.pageCount} Seiten'
        : 'Dokumentdaten nicht lesbar';
    return Container(
      key: ValueKey<String>('trash-item-${document.id}'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: widget.theme.surfaceRaised,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: document.recoverable
              ? widget.theme.outline
              : widget.theme.danger.withValues(alpha: .7),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  document.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: widget.theme.text,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(left: 12),
                  child: SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            'Gelöscht ${_formatUpdatedAt(document.deletedAt)}  •  $pageDescription\n$folderDescription',
            style: TextStyle(color: widget.theme.mutedText, height: 1.35),
          ),
          if (!document.recoverable) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              'Keine intakte Dokumentversion gefunden. Endgültiges Löschen bleibt möglich.',
              style: TextStyle(color: widget.theme.danger, fontSize: 13),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton.icon(
                key: ValueKey<String>('trash-delete-${document.id}'),
                onPressed: busy
                    ? null
                    : () => widget.onDeletePermanently(document),
                icon: const Icon(Icons.delete_forever_rounded),
                label: const Text('Endgültig löschen'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: widget.theme.danger,
                  minimumSize: const Size(64, 48),
                ),
              ),
              FilledButton.icon(
                key: ValueKey<String>('trash-restore-${document.id}'),
                onPressed: busy || !document.recoverable
                    ? null
                    : () => widget.onRestore(document),
                icon: const Icon(Icons.restore_rounded),
                label: const Text('Wiederherstellen'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(64, 48),
                  backgroundColor: widget.theme.primary,
                  foregroundColor: const Color(0xFF08241C),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ArchiveShareTargetDialog extends StatelessWidget {
  const _ArchiveShareTargetDialog();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('ZIP bereitstellen'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _ArchiveTargetTile(
            key: const ValueKey<String>('archive-share-save'),
            icon: Icons.save_alt_rounded,
            title: 'Lokal speichern',
            subtitle: 'Speicherort für die ZIP-Datei auswählen',
            onTap: () =>
                Navigator.of(context).pop(_ArchiveShareTarget.saveLocally),
          ),
          const SizedBox(height: 8),
          _ArchiveTargetTile(
            key: const ValueKey<String>('archive-share-quick'),
            icon: Icons.near_me_rounded,
            title: 'Quick Share',
            subtitle: 'Android- oder Systemfreigabe öffnen',
            onTap: () =>
                Navigator.of(context).pop(_ArchiveShareTarget.quickShare),
          ),
          const SizedBox(height: 8),
          _ArchiveTargetTile(
            key: const ValueKey<String>('archive-share-wlan'),
            icon: Icons.qr_code_2_rounded,
            title: 'WLAN / QR',
            subtitle: 'Direkter Download im lokalen Netzwerk',
            onTap: () => Navigator.of(context).pop(_ArchiveShareTarget.wlanQr),
          ),
        ],
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Abbrechen'),
      ),
    ],
  );
}

class _ArchiveTargetTile extends StatelessWidget {
  const _ArchiveTargetTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    borderRadius: BorderRadius.circular(16),
    clipBehavior: Clip.antiAlias,
    child: ListTile(
      minTileHeight: 72,
      leading: Icon(icon, size: 30),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    ),
  );
}

class _ArchiveQrShareDialog extends StatelessWidget {
  const _ArchiveQrShareDialog({
    required this.server,
    required this.initialSession,
    required this.onClose,
  });

  final LocalPdfShareServer server;
  final LocalPdfShareSession initialSession;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 540),
      child: StreamBuilder<LocalPdfShareEvent>(
        stream: server.events,
        builder: (context, snapshot) {
          final session = snapshot.data?.session ?? initialSession;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'ZIP im WLAN teilen',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  'QR-Code mit einem Gerät im selben WLAN scannen.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 22),
                Semantics(
                  image: true,
                  label: 'QR-Code zum Herunterladen des ZIP-Archivs',
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: QrImageView(
                        data: session.url.toString(),
                        size: 236,
                        padding: EdgeInsets.zero,
                        errorCorrectionLevel: QrErrorCorrectLevel.M,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SelectableText(
                  session.url.toString(),
                  maxLines: 3,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  session.downloadCount == 1
                      ? '1 Download'
                      : '${session.downloadCount} Downloads',
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  key: const ValueKey<String>('close-archive-wlan-share'),
                  onPressed: onClose,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Freigabe beenden'),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

class _RenameDocumentDialog extends StatefulWidget {
  const _RenameDocumentDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_RenameDocumentDialog> createState() => _RenameDocumentDialogState();
}

class _RenameDocumentDialogState extends State<_RenameDocumentDialog> {
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Whiteboard umbenennen'),
      content: TextField(
        key: const ValueKey<String>('rename-document-field'),
        controller: _textController,
        autofocus: true,
        maxLength: 120,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: 'Name',
          hintText: 'Whiteboard-Name',
        ),
        onSubmitted: _submit,
      ),
      actions: <Widget>[
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          key: const ValueKey<String>('confirm-rename-button'),
          style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
          onPressed: () => _submit(_textController.text),
          child: const Text('Speichern'),
        ),
      ],
    );
  }

  void _submit(String value) {
    final normalized = value.trim();
    if (normalized.isNotEmpty) Navigator.of(context).pop(normalized);
  }
}

class _FolderNameDialog extends StatefulWidget {
  const _FolderNameDialog({required this.title, this.initialName = ''});

  final String title;
  final String initialName;

  @override
  State<_FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<_FolderNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const ValueKey<String>('folder-name-field'),
      controller: _controller,
      autofocus: true,
      maxLength: 120,
      textInputAction: TextInputAction.done,
      decoration: const InputDecoration(
        labelText: 'Ordnername',
        hintText: 'z. B. Mathematik',
      ),
      onSubmitted: _submit,
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Abbrechen'),
      ),
      FilledButton(
        key: const ValueKey<String>('confirm-folder-name-button'),
        onPressed: () => _submit(_controller.text),
        child: const Text('Speichern'),
      ),
    ],
  );

  void _submit(String value) {
    final normalized = value.trim();
    if (normalized.isNotEmpty) Navigator.of(context).pop(normalized);
  }
}

@immutable
class _MoveTarget {
  const _MoveTarget(this.folderId);

  final String? folderId;
}

class _MoveDocumentsDialog extends StatelessWidget {
  const _MoveDocumentsDialog({
    required this.folders,
    required this.currentFolderId,
  });

  final List<LibraryFolder> folders;
  final String? currentFolderId;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('In Ordner verschieben'),
    content: SizedBox(
      width: 420,
      height: ((folders.length + 1) * 64.0).clamp(96.0, 480.0),
      child: ListView(
        children: <Widget>[
          ListTile(
            key: const ValueKey<String>('move-target-root'),
            leading: const Icon(Icons.folder_off_outlined),
            title: const Text('Nicht abgelegt'),
            trailing: currentFolderId == null
                ? const Icon(Icons.check_rounded)
                : null,
            onTap: () => Navigator.of(context).pop(const _MoveTarget(null)),
          ),
          for (final folder in folders)
            ListTile(
              key: ValueKey<String>('move-target-${folder.id}'),
              leading: const Icon(Icons.folder_outlined),
              title: Text(
                folder.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: currentFolderId == folder.id
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () => Navigator.of(context).pop(_MoveTarget(folder.id)),
            ),
        ],
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Abbrechen'),
      ),
    ],
  );
}

class _PinnedFolderDropTargetDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedFolderDropTargetDelegate({
    required this.extent,
    required this.background,
    required this.padding,
    required this.child,
  });

  final double extent;
  final Color background;
  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => ColoredBox(
    color: background,
    child: Padding(padding: padding, child: child),
  );

  @override
  bool shouldRebuild(covariant _PinnedFolderDropTargetDelegate oldDelegate) =>
      extent != oldDelegate.extent ||
      background != oldDelegate.background ||
      padding != oldDelegate.padding ||
      child != oldDelegate.child;
}

/// Compact, sticky drop destinations for the root and opened folders.
///
/// Keeping the destinations in a horizontal strip leaves the document grid
/// large enough for classroom displays and makes every target reachable by a
/// finger swipe even after the document list has been scrolled vertically.
class _FolderDropTargetStrip extends StatelessWidget {
  const _FolderDropTargetStrip({
    required this.folders,
    required this.showRootTarget,
    required this.theme,
    required this.busy,
    required this.canAcceptRoot,
    required this.canAcceptFolder,
    required this.onAcceptRoot,
    required this.onAcceptFolder,
    super.key,
  });

  final List<LibraryFolder> folders;
  final bool showRootTarget;
  final DocumentLibraryThemeData theme;
  final bool busy;
  final bool Function(Set<String> documentIds) canAcceptRoot;
  final bool Function(Set<String> documentIds, LibraryFolder folder)
  canAcceptFolder;
  final ValueChanged<Set<String>> onAcceptRoot;
  final void Function(Set<String> documentIds, LibraryFolder folder)
  onAcceptFolder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 560;
      final targets = <Widget>[
        if (showRootTarget)
          _CompactFolderDropTarget(
            key: const ValueKey<String>('folder-drop-target-root'),
            label: 'Nicht abgelegt',
            icon: Icons.folder_off_outlined,
            theme: theme,
            busy: busy,
            canAcceptDocuments: canAcceptRoot,
            onAcceptDocuments: onAcceptRoot,
          ),
        for (final folder in folders)
          _CompactFolderDropTarget(
            key: ValueKey<String>('folder-drop-target-${folder.id}'),
            label: folder.name,
            icon: Icons.folder_rounded,
            theme: theme,
            busy: busy,
            canAcceptDocuments: (ids) => canAcceptFolder(ids, folder),
            onAcceptDocuments: (ids) => onAcceptFolder(ids, folder),
          ),
      ];
      return Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: theme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: theme.outline),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 8,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: <Widget>[
            Tooltip(
              message: 'Dokumente in einen Ordner ziehen',
              child: SizedBox(
                width: compact ? 46 : 190,
                child: Row(
                  mainAxisAlignment: compact
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      Icons.drive_file_move_outline,
                      color: theme.primary,
                      size: 25,
                    ),
                    if (!compact) ...<Widget>[
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          'Hierhin ziehen',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: theme.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey<String>('folder-drop-target-scroll'),
                scrollDirection: Axis.horizontal,
                physics: const ClampingScrollPhysics(),
                child: Row(
                  children: <Widget>[
                    for (
                      var index = 0;
                      index < targets.length;
                      index++
                    ) ...<Widget>[
                      if (index > 0) const SizedBox(width: 8),
                      targets[index],
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _CompactFolderDropTarget extends StatelessWidget {
  const _CompactFolderDropTarget({
    required this.label,
    required this.icon,
    required this.theme,
    required this.busy,
    required this.canAcceptDocuments,
    required this.onAcceptDocuments,
    super.key,
  });

  final String label;
  final IconData icon;
  final DocumentLibraryThemeData theme;
  final bool busy;
  final bool Function(Set<String> documentIds) canAcceptDocuments;
  final ValueChanged<Set<String>> onAcceptDocuments;

  @override
  Widget build(BuildContext context) => DragTarget<_DocumentDragPayload>(
    onWillAcceptWithDetails: (details) =>
        !busy && canAcceptDocuments(details.data.documentIds),
    onAcceptWithDetails: (details) =>
        onAcceptDocuments(details.data.documentIds),
    builder: (context, candidates, rejected) {
      final dropActive = candidates.isNotEmpty;
      return Semantics(
        label: 'Ablageziel $label',
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 184,
          height: 62,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            color: dropActive
                ? Color.alphaBlend(
                    theme.primary.withValues(alpha: .18),
                    theme.surfaceRaised,
                  )
                : theme.surfaceRaised,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: dropActive ? theme.primary : theme.outline,
              width: dropActive ? 3 : 1,
            ),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                dropActive ? Icons.move_to_inbox_rounded : icon,
                color: dropActive ? theme.primary : theme.mutedText,
                size: 29,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  dropActive ? 'Hier ablegen' : label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: dropActive ? theme.primary : theme.text,
                    fontSize: 15,
                    height: 1.15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

enum _FolderMenuAction { rename, share, delete }

class _FolderCard extends StatelessWidget {
  const _FolderCard({
    required this.folder,
    required this.documentCount,
    required this.theme,
    required this.busy,
    required this.onOpen,
    required this.onRename,
    required this.onShare,
    required this.onDelete,
    required this.canAcceptDocuments,
    required this.onAcceptDocuments,
    super.key,
  });

  final LibraryFolder folder;
  final int documentCount;
  final DocumentLibraryThemeData theme;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onShare;
  final VoidCallback onDelete;
  final bool Function(Set<String> documentIds) canAcceptDocuments;
  final ValueChanged<Set<String>> onAcceptDocuments;

  @override
  Widget build(BuildContext context) => DragTarget<_DocumentDragPayload>(
    onWillAcceptWithDetails: (details) =>
        !busy && canAcceptDocuments(details.data.documentIds),
    onAcceptWithDetails: (details) =>
        onAcceptDocuments(details.data.documentIds),
    builder: (context, candidates, rejected) =>
        _buildCard(context, candidates.isNotEmpty),
  );

  Widget _buildCard(BuildContext context, bool dropActive) => AnimatedContainer(
    duration: const Duration(milliseconds: 140),
    transform: Matrix4.diagonal3Values(
      dropActive ? 1.018 : 1,
      dropActive ? 1.018 : 1,
      1,
    ),
    transformAlignment: Alignment.center,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(20),
      boxShadow: dropActive
          ? <BoxShadow>[
              BoxShadow(
                color: theme.primary.withValues(alpha: .28),
                blurRadius: 18,
                spreadRadius: 2,
              ),
            ]
          : const <BoxShadow>[],
    ),
    child: Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: dropActive
          ? Color.alphaBlend(
              theme.primary.withValues(alpha: .14),
              theme.surface,
            )
          : theme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: dropActive ? theme.primary : theme.outline,
          width: dropActive ? 3 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 6, 14),
          child: Row(
            children: <Widget>[
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: theme.primary.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.folder_rounded,
                  color: theme.primary,
                  size: 34,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: theme.text,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      dropActive
                          ? 'Hier ablegen'
                          : '$documentCount ${documentCount == 1 ? 'Dokument' : 'Dokumente'}',
                      style: TextStyle(color: theme.mutedText, fontSize: 13),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<_FolderMenuAction>(
                key: ValueKey<String>('folder-menu-${folder.id}'),
                enabled: !busy,
                tooltip: 'Aktionen für ${folder.name}',
                color: theme.surfaceRaised,
                icon: Icon(Icons.more_vert_rounded, color: theme.mutedText),
                constraints: const BoxConstraints(minWidth: 52, minHeight: 52),
                onSelected: (action) {
                  switch (action) {
                    case _FolderMenuAction.rename:
                      onRename();
                    case _FolderMenuAction.share:
                      onShare();
                    case _FolderMenuAction.delete:
                      onDelete();
                  }
                },
                itemBuilder: (_) => <PopupMenuEntry<_FolderMenuAction>>[
                  const PopupMenuItem<_FolderMenuAction>(
                    value: _FolderMenuAction.rename,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.edit_outlined),
                      title: Text('Umbenennen'),
                    ),
                  ),
                  const PopupMenuItem<_FolderMenuAction>(
                    value: _FolderMenuAction.share,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.folder_zip_outlined),
                      title: Text('Ordner als ZIP teilen'),
                    ),
                  ),
                  PopupMenuItem<_FolderMenuAction>(
                    value: _FolderMenuAction.delete,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Icons.folder_delete_outlined,
                        color: theme.danger,
                      ),
                      title: Text(
                        'Ordner entfernen',
                        style: TextStyle(color: theme.danger),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

enum _DocumentMenuAction { rename, move, share, delete }

@immutable
class _DocumentDragPayload {
  const _DocumentDragPayload(this.documentIds);

  final Set<String> documentIds;
}

class _DocumentCard extends StatelessWidget {
  const _DocumentCard({
    required this.entry,
    required this.busy,
    required this.selected,
    required this.selectionMode,
    required this.theme,
    required this.onOpen,
    required this.onToggleSelection,
    required this.onSelect,
    required this.onRename,
    required this.onMove,
    required this.onShare,
    required this.onDelete,
    required this.dragDocumentIds,
    super.key,
  });

  final DocumentLibraryEntry entry;
  final bool busy;
  final bool selected;
  final bool selectionMode;
  final DocumentLibraryThemeData theme;
  final VoidCallback onOpen;
  final VoidCallback onToggleSelection;
  final VoidCallback onSelect;
  final VoidCallback onRename;
  final VoidCallback onMove;
  final VoidCallback onShare;
  final VoidCallback onDelete;
  final Set<String> dragDocumentIds;

  @override
  Widget build(BuildContext context) {
    final summary = entry.summary;
    final requiresRecovery = summary.recoveryAvailable;
    final page = entry.previewPage;
    final payload = _DocumentDragPayload(
      Set<String>.unmodifiable(dragDocumentIds),
    );
    final card = Semantics(
      button: true,
      label:
          '${summary.title}, ${summary.pageCount} ${summary.pageCount == 1 ? 'Seite' : 'Seiten'}${requiresRecovery ? ', Wiederherstellung verfügbar' : ''}',
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        elevation: 0,
        color: theme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: selected
                ? theme.primary
                : requiresRecovery
                ? theme.warning.withValues(alpha: .7)
                : theme.outline,
            width: selected ? 3 : (requiresRecovery ? 1.5 : 1),
          ),
        ),
        child: InkWell(
          onTap: busy
              ? null
              : selectionMode
              ? onToggleSelection
              : onOpen,
          hoverColor: theme.primary.withValues(alpha: .055),
          focusColor: theme.primary.withValues(alpha: .08),
          child: Stack(
            children: <Widget>[
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: ColoredBox(
                      color: const Color(0xFFF8F7F2),
                      child: page == null
                          ? _PreviewUnavailable(
                              recoveryAvailable: requiresRecovery,
                              theme: theme,
                            )
                          : DocumentPagePreview(page: page),
                    ),
                  ),
                  Container(
                    height: 106,
                    padding: const EdgeInsets.fromLTRB(18, 13, 8, 12),
                    decoration: BoxDecoration(
                      color: theme.surface,
                      border: Border(top: BorderSide(color: theme.outline)),
                    ),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              Text(
                                summary.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: theme.text,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 7),
                              Text(
                                '${summary.pageCount} ${summary.pageCount == 1 ? 'Seite' : 'Seiten'}  •  ${_formatUpdatedAt(summary.updatedAt)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: theme.mutedText,
                                  fontSize: 13,
                                ),
                              ),
                              if (entry.wasRecovered) ...<Widget>[
                                const SizedBox(height: 5),
                                Text(
                                  'Nach Absturz wiederhergestellt',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: theme.warning,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        PopupMenuButton<_DocumentMenuAction>(
                          key: ValueKey<String>('document-menu-${summary.id}'),
                          enabled: !busy,
                          tooltip: 'Aktionen für ${summary.title}',
                          icon: Icon(
                            Icons.more_vert_rounded,
                            color: theme.mutedText,
                          ),
                          iconSize: 26,
                          constraints: const BoxConstraints(
                            minWidth: 52,
                            minHeight: 52,
                          ),
                          color: theme.surfaceRaised,
                          onSelected: (action) {
                            switch (action) {
                              case _DocumentMenuAction.rename:
                                onRename();
                              case _DocumentMenuAction.move:
                                onMove();
                              case _DocumentMenuAction.share:
                                onShare();
                              case _DocumentMenuAction.delete:
                                onDelete();
                            }
                          },
                          itemBuilder: (context) =>
                              <PopupMenuEntry<_DocumentMenuAction>>[
                                PopupMenuItem<_DocumentMenuAction>(
                                  key: ValueKey<String>('rename-${summary.id}'),
                                  value: _DocumentMenuAction.rename,
                                  height: 54,
                                  child: const ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(Icons.edit_outlined),
                                    title: Text('Umbenennen'),
                                  ),
                                ),
                                PopupMenuItem<_DocumentMenuAction>(
                                  key: ValueKey<String>('move-${summary.id}'),
                                  value: _DocumentMenuAction.move,
                                  height: 54,
                                  child: const ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(
                                      Icons.drive_file_move_outline,
                                    ),
                                    title: Text('In Ordner verschieben'),
                                  ),
                                ),
                                PopupMenuItem<_DocumentMenuAction>(
                                  key: ValueKey<String>('share-${summary.id}'),
                                  value: _DocumentMenuAction.share,
                                  height: 54,
                                  child: const ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(Icons.share_outlined),
                                    title: Text('Als ZIP teilen'),
                                  ),
                                ),
                                PopupMenuItem<_DocumentMenuAction>(
                                  key: ValueKey<String>('delete-${summary.id}'),
                                  value: _DocumentMenuAction.delete,
                                  height: 54,
                                  child: ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(
                                      Icons.delete_outline,
                                      color: theme.danger,
                                    ),
                                    title: Text(
                                      'Löschen',
                                      style: TextStyle(color: theme.danger),
                                    ),
                                  ),
                                ),
                              ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (requiresRecovery && !selectionMode)
                Positioned(
                  left: 12,
                  top: 12,
                  child: _RecoveryBadge(theme: theme),
                ),
              if (selectionMode)
                Positioned(
                  left: 12,
                  top: 12,
                  child: Semantics(
                    checked: selected,
                    label: selected ? 'Ausgewählt' : 'Nicht ausgewählt',
                    child: Material(
                      color: selected ? theme.primary : theme.surfaceRaised,
                      shape: const CircleBorder(),
                      elevation: 2,
                      child: InkWell(
                        key: ValueKey<String>('select-document-${summary.id}'),
                        customBorder: const CircleBorder(),
                        onTap: busy ? null : onToggleSelection,
                        child: SizedBox.square(
                          dimension: 44,
                          child: Icon(
                            selected
                                ? Icons.check_rounded
                                : Icons.circle_outlined,
                            color: selected
                                ? const Color(0xFF08241C)
                                : theme.mutedText,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (busy)
                Positioned.fill(
                  child: ColoredBox(
                    color: theme.background.withValues(alpha: .62),
                    child: Center(
                      child: CircularProgressIndicator(
                        color: theme.primary,
                        strokeWidth: 3,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (busy) return card;
    Widget feedback() => _DocumentDragFeedback(
      title: summary.title,
      count: payload.documentIds.length,
      theme: theme,
    );
    final fadedCard = Opacity(opacity: .38, child: card);
    final touchDraggable = _TouchDocumentDraggable<_DocumentDragPayload>(
      data: payload,
      delay: const Duration(milliseconds: 420),
      hapticFeedbackOnStart: true,
      maxSimultaneousDrags: 1,
      onDragStarted: selected ? null : onSelect,
      feedback: feedback(),
      childWhenDragging: fadedCard,
      child: card,
    );
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: _DirectDocumentDraggable<_DocumentDragPayload>(
        key: ValueKey<String>('document-drag-${summary.id}'),
        data: payload,
        maxSimultaneousDrags: 1,
        onDragStarted: selected ? null : onSelect,
        feedback: feedback(),
        childWhenDragging: fadedCard,
        child: touchDraggable,
      ),
    );
  }
}

/// Starts a conventional drag after pointer slop for mouse and pen input.
/// Touch remains a long-press drag so vertical library scrolling is not stolen
/// from large interactive displays.
class _DirectDocumentDraggable<T extends Object> extends Draggable<T> {
  const _DirectDocumentDraggable({
    required super.child,
    required super.feedback,
    super.key,
    super.data,
    super.childWhenDragging,
    super.maxSimultaneousDrags,
    super.onDragStarted,
  });

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) => ImmediateMultiDragGestureRecognizer(
    supportedDevices: const <PointerDeviceKind>{
      PointerDeviceKind.mouse,
      PointerDeviceKind.stylus,
      PointerDeviceKind.invertedStylus,
    },
    allowedButtonsFilter: allowedButtonsFilter,
  )..onStart = onStart;
}

class _TouchDocumentDraggable<T extends Object> extends LongPressDraggable<T> {
  const _TouchDocumentDraggable({
    required super.child,
    required super.feedback,
    super.data,
    super.childWhenDragging,
    super.maxSimultaneousDrags,
    super.onDragStarted,
    super.hapticFeedbackOnStart,
    super.delay,
  });

  @override
  DelayedMultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) =>
      DelayedMultiDragGestureRecognizer(
          delay: delay,
          supportedDevices: const <PointerDeviceKind>{PointerDeviceKind.touch},
          allowedButtonsFilter: allowedButtonsFilter,
        )
        ..onStart = (position) {
          final result = onStart(position);
          if (result != null && hapticFeedbackOnStart) {
            HapticFeedback.selectionClick();
          }
          return result;
        };
}

class _DocumentDragFeedback extends StatelessWidget {
  const _DocumentDragFeedback({
    required this.title,
    required this.count,
    required this.theme,
  });

  final String title;
  final int count;
  final DocumentLibraryThemeData theme;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Container(
      width: 280,
      constraints: const BoxConstraints(minHeight: 82),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: theme.surfaceRaised.withValues(alpha: .97),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.primary, width: 2),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.description_outlined, color: theme.primary, size: 30),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  count == 1 ? title : '$count Dokumente',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Auf einen Ordner ziehen',
                  style: TextStyle(color: theme.mutedText, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _PreviewUnavailable extends StatelessWidget {
  const _PreviewUnavailable({
    required this.recoveryAvailable,
    required this.theme,
  });

  final bool recoveryAvailable;
  final DocumentLibraryThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            recoveryAvailable
                ? Icons.restore_page_outlined
                : Icons.insert_drive_file_outlined,
            color: const Color(0xFF66716B),
            size: 42,
          ),
          const SizedBox(height: 8),
          Text(
            recoveryAvailable
                ? 'Sicherung zum Wiederherstellen'
                : 'Vorschau nicht verfügbar',
            style: const TextStyle(color: Color(0xFF66716B), fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _RecoveryBadge extends StatelessWidget {
  const _RecoveryBadge({required this.theme});

  final DocumentLibraryThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Wiederherstellung verfügbar',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xE62A2417),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: theme.warning.withValues(alpha: .7)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.restore_rounded, size: 17, color: theme.warning),
              const SizedBox(width: 6),
              Text(
                'Wiederherstellen',
                style: TextStyle(
                  color: theme.warning,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OperationErrorBanner extends StatelessWidget {
  const _OperationErrorBanner({
    required this.message,
    required this.theme,
    required this.onDismiss,
  });

  final String message;
  final DocumentLibraryThemeData theme;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const ValueKey<String>('library-operation-error'),
        constraints: const BoxConstraints(minHeight: 58),
        padding: const EdgeInsets.only(left: 16, top: 8, bottom: 8),
        decoration: BoxDecoration(
          color: theme.danger.withValues(alpha: .1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: theme.danger.withValues(alpha: .55)),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.error_outline_rounded, color: theme.danger),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: theme.text, fontSize: 14),
              ),
            ),
            IconButton(
              tooltip: 'Fehlermeldung schließen',
              onPressed: onDismiss,
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _CenteredState extends StatelessWidget {
  const _CenteredState({
    required this.icon,
    required this.title,
    required this.message,
    required this.theme,
    super.key,
    this.loading = false,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final DocumentLibraryThemeData theme;
  final bool loading;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: theme.surfaceRaised,
                  shape: BoxShape.circle,
                  border: Border.all(color: theme.outline),
                ),
                child: loading
                    ? Padding(
                        padding: const EdgeInsets.all(27),
                        child: CircularProgressIndicator(
                          color: theme.primary,
                          strokeWidth: 3,
                        ),
                      )
                    : Icon(icon, size: 42, color: theme.primary),
              ),
              const SizedBox(height: 22),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: theme.text,
                  fontSize: 23,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 9),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: theme.mutedText,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
              if (actionLabel != null && onAction != null) ...<Widget>[
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: onAction,
                  icon: const Icon(Icons.add_rounded),
                  label: Text(actionLabel!),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(64, 54),
                    backgroundColor: theme.primary,
                    foregroundColor: const Color(0xFF08241C),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LargeIconButton extends StatelessWidget {
  const _LargeIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    required this.theme,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final DocumentLibraryThemeData theme;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon),
      color: theme.text,
      disabledColor: theme.mutedText.withValues(alpha: .5),
      iconSize: 26,
      style: IconButton.styleFrom(
        minimumSize: const Size(54, 54),
        backgroundColor: theme.surfaceRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
          side: BorderSide(color: theme.outline),
        ),
      ),
    );
  }
}

String _formatUpdatedAt(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  final date = DateTime(local.year, local.month, local.day);
  final today = DateTime(now.year, now.month, now.day);
  final time = '${_twoDigits(local.hour)}:${_twoDigits(local.minute)}';
  if (date == today) return 'Heute, $time';
  if (date == today.subtract(const Duration(days: 1))) {
    return 'Gestern, $time';
  }
  return '${_twoDigits(local.day)}.${_twoDigits(local.month)}.${local.year}, $time';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');
