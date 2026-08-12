import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../data/document_repository.dart';
import '../domain/model/document.dart';
import '../features/editor/editor_screen.dart';
import '../features/editor/selected_pages_document_creator.dart';
import '../features/library/document_library.dart';
import '../platform/android_widget_bridge.dart';
import '../platform/smart_board_compatibility.dart';
import 'app_theme.dart';

class FlowboardApp extends StatelessWidget {
  const FlowboardApp({
    required this.repository,
    this.smartBoardCompatibility,
    this.clock,
    this.androidWidgetBridge,
    super.key,
  });

  final DocumentRepository repository;
  final SmartBoardCompatibility? smartBoardCompatibility;
  final DocumentLibraryClock? clock;
  final AndroidWidgetBridge? androidWidgetBridge;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flowboard X',
      debugShowCheckedModeBanner: false,
      theme: buildFlowboardTheme(),
      home: FlowboardHome(
        repository: repository,
        smartBoardCompatibility: smartBoardCompatibility,
        clock: clock,
        androidWidgetBridge: androidWidgetBridge,
      ),
    );
  }
}

class FlowboardHome extends StatefulWidget {
  const FlowboardHome({
    required this.repository,
    this.smartBoardCompatibility,
    this.clock,
    this.androidWidgetBridge,
    super.key,
  });

  final DocumentRepository repository;
  final SmartBoardCompatibility? smartBoardCompatibility;
  final DocumentLibraryClock? clock;
  final AndroidWidgetBridge? androidWidgetBridge;

  @override
  State<FlowboardHome> createState() => _FlowboardHomeState();
}

class _FlowboardHomeState extends State<FlowboardHome>
    with WidgetsBindingObserver {
  StreamSubscription<WidgetLaunchAction>? _widgetActions;
  int _libraryGeneration = 0;
  bool _drainingWidgetActions = false;
  bool _smartBoardDialogVisible = false;
  bool _waitingForSmartBoardSettings = false;

  SmartBoardCompatibility get _smartBoardCompatibility =>
      widget.smartBoardCompatibility ?? SmartBoardCompatibilityBridge.instance;

  AndroidWidgetBridge get _androidWidgetBridge =>
      widget.androidWidgetBridge ?? AndroidWidgetBridge.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _widgetActions = _androidWidgetBridge.launchActions.listen(
      (_) => unawaited(_drainWidgetActions()),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_drainWidgetActions());
      unawaited(_syncAndroidWidget());
      unawaited(_showSmartBoardSetupIfNeeded());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_widgetActions?.cancel());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed ||
        !_waitingForSmartBoardSettings ||
        _smartBoardDialogVisible) {
      return;
    }
    _waitingForSmartBoardSettings = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_confirmSmartBoardSetup());
    });
  }

  @override
  Widget build(BuildContext context) {
    return DocumentLibraryScreen(
      key: ValueKey(_libraryGeneration),
      repository: widget.repository,
      title: 'Flowboard X',
      clock: widget.clock,
      onOpen: _openEditor,
      onDocumentsChanged: _syncAndroidWidget,
    );
  }

  Future<void> _openEditor(
    WhiteboardDocument document,
    Directory assetDirectory,
  ) async {
    var nextDocument = document;
    var nextAssetDirectory = assetDirectory;
    while (mounted) {
      final routeDocument = nextDocument;
      final routeAssetDirectory = nextAssetDirectory;
      final result = await Navigator.of(context).push<Object?>(
        MaterialPageRoute(
          builder: (_) => EditorScreen(
            document: routeDocument,
            repository: widget.repository,
            assetDirectory: routeAssetDirectory,
          ),
        ),
      );
      if (result is! CreatedPagesDocument || !mounted) break;
      // The previous route has completed before the new route is pushed. Its
      // editor and timer controllers therefore cannot remain stacked below the
      // newly created whiteboard.
      nextDocument = result.document;
      nextAssetDirectory = result.assetDirectory;
    }
    if (!mounted) return;
    setState(() => _libraryGeneration++);
    await _syncAndroidWidget();
  }

  Future<void> _drainWidgetActions() async {
    if (_drainingWidgetActions || !mounted) return;
    _drainingWidgetActions = true;
    try {
      while (mounted) {
        final action = _androidWidgetBridge.consumePendingLaunchAction();
        if (action == null) break;
        await _handleWidgetAction(action);
      }
    } finally {
      _drainingWidgetActions = false;
    }
  }

  Future<void> _handleWidgetAction(WidgetLaunchAction action) async {
    try {
      WhiteboardDocument? document;
      switch (action.type) {
        case WidgetLaunchActionType.newWhiteboard:
          document = WhiteboardDocument.create(
            id: const Uuid().v4(),
            now: widget.clock?.call(),
          );
          await widget.repository.save(document);
        case WidgetLaunchActionType.openDocument:
          final id = action.documentId;
          if (id != null) {
            document = await widget.repository.recover(id);
            document ??= await widget.repository.load(id);
          }
      }
      if (document == null || !mounted) return;
      final assets = await widget.repository.assetDirectory(document.id);
      if (mounted) await _openEditor(document, assets);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Widget-Aktion konnte nicht geöffnet werden: $error'),
            backgroundColor: FlowboardColors.danger,
          ),
        );
      }
    }
  }

  Future<void> _syncAndroidWidget() async {
    try {
      final summaries = await widget.repository.list();
      await _androidWidgetBridge.updateRecentDocuments(
        summaries.map(
          (summary) => WidgetDocument(
            id: summary.id,
            title: summary.title,
            modifiedAt: summary.updatedAt,
          ),
        ),
      );
    } on Object {
      // Widget synchronization is best-effort and never blocks document use.
    }
  }

  Future<void> _showSmartBoardSetupIfNeeded() async {
    if (_smartBoardDialogVisible || !mounted) return;
    final status = await _smartBoardCompatibility.getStatus();
    if (!mounted || !status.isSmartBoard || status.setupAcknowledged) return;
    _smartBoardDialogVisible = true;
    final action = await showDialog<_SmartBoardSetupAction>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _SmartBoardSetupDialog(status: status),
    );
    _smartBoardDialogVisible = false;
    if (!mounted) return;
    switch (action) {
      case _SmartBoardSetupAction.openSettings:
        await _openSmartBoardSettings();
      case _SmartBoardSetupAction.completed:
        await _acknowledgeSmartBoardSetup();
      case _SmartBoardSetupAction.later || null:
        break;
    }
  }

  Future<void> _openSmartBoardSettings() async {
    _waitingForSmartBoardSettings = true;
    final opened = await _smartBoardCompatibility.openSettings();
    if (opened || !mounted) return;
    _waitingForSmartBoardSettings = false;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Die SMART-Einstellungen konnten nicht automatisch geöffnet werden. '
          'Bitte öffnen Sie am Board Einstellungen → Annotation.',
        ),
        backgroundColor: FlowboardColors.warning,
      ),
    );
  }

  Future<void> _confirmSmartBoardSetup() async {
    if (_smartBoardDialogVisible || !mounted) return;
    _smartBoardDialogVisible = true;
    final action = await showDialog<_SmartBoardSetupAction>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const _SmartBoardSetupConfirmationDialog(),
    );
    _smartBoardDialogVisible = false;
    if (!mounted) return;
    switch (action) {
      case _SmartBoardSetupAction.openSettings:
        await _openSmartBoardSettings();
      case _SmartBoardSetupAction.completed:
        await _acknowledgeSmartBoardSetup();
      case _SmartBoardSetupAction.later || null:
        break;
    }
  }

  Future<void> _acknowledgeSmartBoardSetup() async {
    final stored = await _smartBoardCompatibility.acknowledgeSetup();
    if (!mounted || stored) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Die Bestätigung konnte nicht gespeichert werden. Die Einrichtung '
          'wird beim nächsten Start erneut angezeigt.',
        ),
        backgroundColor: FlowboardColors.warning,
      ),
    );
  }
}

enum _SmartBoardSetupAction { openSettings, completed, later }

class _SmartBoardSetupDialog extends StatelessWidget {
  const _SmartBoardSetupDialog({required this.status});

  final SmartBoardCompatibilityStatus status;

  @override
  Widget build(BuildContext context) {
    final device = status.deviceLabel;
    return AlertDialog(
      icon: const Icon(Icons.draw_rounded, color: FlowboardColors.mint),
      title: const Text('SMART Board für Flowboard X einrichten'),
      content: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (device.isNotEmpty) ...[
                Text(
                  device,
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(color: FlowboardColors.mint),
                ),
                const SizedBox(height: 12),
              ],
              const Text(
                'SMART aktiviert für installierte Apps standardmäßig eine '
                'eigene Anmerkungsebene. Sie liegt über Flowboard X und fängt '
                'den Stift ab, bevor das Whiteboard ihn erhalten kann.',
              ),
              const SizedBox(height: 16),
              const Text(
                'Einmalige Einrichtung am Board:',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                '1. Einstellungen öffnen\n'
                '2. Annotation auswählen\n'
                '3. Unter „Alle Apps“ oder „Installierte Apps“ Flowboard X '
                'suchen\n'
                '4. Den Schalter für Flowboard X ausschalten\n'
                '5. Zu Flowboard X zurückkehren',
              ),
              const SizedBox(height: 12),
              const Text(
                'Ist die Einstellung gesperrt oder fehlt die App-Liste, muss '
                'ein Administrator die Einstellungen entsperren '
                'beziehungsweise iQ aktualisieren.',
                style: TextStyle(color: FlowboardColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _SmartBoardSetupAction.later),
          child: const Text('Später'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, _SmartBoardSetupAction.completed),
          child: const Text('Bereits erledigt'),
        ),
        FilledButton.icon(
          onPressed: () =>
              Navigator.pop(context, _SmartBoardSetupAction.openSettings),
          icon: const Icon(Icons.settings_rounded),
          label: const Text('Einstellungen öffnen'),
        ),
      ],
    );
  }
}

class _SmartBoardSetupConfirmationDialog extends StatelessWidget {
  const _SmartBoardSetupConfirmationDialog();

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.check_circle_outline_rounded),
    title: const Text('SMART-Anmerkung ausgeschaltet?'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 500),
      child: const Text(
        'Bestätigen Sie erst, wenn der Schalter für Flowboard X unter '
        'Einstellungen → Annotation → Alle Apps ausgeschaltet ist. Danach '
        'erhält die App den Stift direkt.',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, _SmartBoardSetupAction.later),
        child: const Text('Noch nicht'),
      ),
      TextButton.icon(
        onPressed: () =>
            Navigator.pop(context, _SmartBoardSetupAction.openSettings),
        icon: const Icon(Icons.settings_rounded),
        label: const Text('Einstellungen'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, _SmartBoardSetupAction.completed),
        child: const Text('Ja, erledigt'),
      ),
    ],
  );
}
