import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../data/document_repository.dart';
import '../domain/model/document.dart';
import '../features/editor/editor_screen.dart';
import '../features/library/document_library.dart';
import '../platform/android_widget_bridge.dart';
import 'app_theme.dart';

class FlowboardApp extends StatelessWidget {
  const FlowboardApp({required this.repository, super.key});

  final DocumentRepository repository;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flowboard X',
      debugShowCheckedModeBanner: false,
      theme: buildFlowboardTheme(),
      home: FlowboardHome(repository: repository),
    );
  }
}

class FlowboardHome extends StatefulWidget {
  const FlowboardHome({required this.repository, super.key});

  final DocumentRepository repository;

  @override
  State<FlowboardHome> createState() => _FlowboardHomeState();
}

class _FlowboardHomeState extends State<FlowboardHome> {
  StreamSubscription<WidgetLaunchAction>? _widgetActions;
  int _libraryGeneration = 0;
  bool _drainingWidgetActions = false;

  @override
  void initState() {
    super.initState();
    _widgetActions = AndroidWidgetBridge.instance.launchActions.listen(
      (_) => unawaited(_drainWidgetActions()),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_drainWidgetActions());
      unawaited(_syncAndroidWidget());
    });
  }

  @override
  void dispose() {
    unawaited(_widgetActions?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DocumentLibraryScreen(
      key: ValueKey(_libraryGeneration),
      repository: widget.repository,
      title: 'Flowboard X',
      onOpen: _openEditor,
      onDocumentsChanged: _syncAndroidWidget,
    );
  }

  Future<void> _openEditor(
    WhiteboardDocument document,
    Directory assetDirectory,
  ) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EditorScreen(
          document: document,
          repository: widget.repository,
          assetDirectory: assetDirectory,
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _libraryGeneration++);
    await _syncAndroidWidget();
  }

  Future<void> _drainWidgetActions() async {
    if (_drainingWidgetActions || !mounted) return;
    _drainingWidgetActions = true;
    try {
      while (mounted) {
        final action = AndroidWidgetBridge.instance
            .consumePendingLaunchAction();
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
          document = WhiteboardDocument.create(id: const Uuid().v4());
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
      await AndroidWidgetBridge.instance.updateRecentDocuments(
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
}
