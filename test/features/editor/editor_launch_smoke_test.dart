import 'dart:async';
import 'dart:io';

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/board/presentation/board_surface.dart';
import 'package:flowboard_x/src/features/editor/editor_pen_quick_controls.dart';
import 'package:flowboard_x/src/features/editor/editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final size in <Size>[
    const Size(432, 960),
    const Size(1920, 1080),
    const Size(3840, 2160),
  ]) {
    testWidgets(
      'blank editor renders its first frame at ${size.width}x${size.height}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('flowboard-editor-launch-'),
        ))!;
        final document = WhiteboardDocument.create(
          id: 'editor-launch-${size.width.round()}',
          now: DateTime.utc(2026, 8, 3, 12),
        );
        final repository = _MemoryRepository(directory, document);
        addTearDown(() async {
          tester.view.resetDevicePixelRatio();
          tester.view.resetPhysicalSize();
          await tester.runAsync(() async {
            if (await directory.exists()) {
              await directory.delete(recursive: true);
            }
          });
        });

        await tester.pumpWidget(
          MaterialApp(
            home: EditorScreen(
              document: document,
              repository: repository,
              assetDirectory: directory,
            ),
          ),
        );
        await tester.pump();

        expect(find.byType(EditorScreen), findsOneWidget);
        expect(find.byType(BoardSurface), findsOneWidget);
        expect(
          find.byKey(const ValueKey('solo-board-surface')),
          findsOneWidget,
        );
        expect(
          tester.getSize(find.byKey(const ValueKey('solo-board-surface'))),
          size,
          reason: 'The editor workspace must fill its route on first frame.',
        );
        expect(find.byTooltip('Übersicht'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('split top bar keeps right pen shortcuts participant-scoped', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1920, 1080);
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('flowboard-editor-split-pen-'),
    ))!;
    final document = WhiteboardDocument.create(
      id: 'editor-split-pen-controls',
      now: DateTime.utc(2026, 8, 3, 12),
    );
    final repository = _MemoryRepository(directory, document);
    addTearDown(() async {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
      await tester.runAsync(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
    });

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Dokumentübersicht'))),
    );
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          allowSnapshotting: false,
          builder: (_) => EditorScreen(
            document: document,
            repository: repository,
            assetDirectory: directory,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Zwei Personen'));
    await tester.pump();

    final primaryColorFinder = find.byKey(
      const ValueKey('editor-pen-color-quick-button-primary'),
    );
    final secondaryColorFinder = find.byKey(
      const ValueKey('editor-pen-color-quick-button-secondary'),
    );
    final primaryTypeFinder = find.byKey(
      const ValueKey('editor-pen-type-quick-button-primary'),
    );
    final secondaryTypeFinder = find.byKey(
      const ValueKey('editor-pen-type-quick-button-secondary'),
    );
    expect(primaryColorFinder, findsOneWidget);
    expect(secondaryColorFinder, findsOneWidget);
    expect(find.text('Links'), findsWidgets);
    expect(find.text('Rechts'), findsWidgets);

    await tester.tap(secondaryColorFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rot'));
    await tester.pumpAndSettle();
    await tester.tap(secondaryTypeFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gestrichelt'));
    await tester.pumpAndSettle();

    final primaryColorControl = find.ancestor(
      of: primaryColorFinder,
      matching: find.byType(EditorPenColorQuickButton),
    );
    final secondaryColorControl = find.ancestor(
      of: secondaryColorFinder,
      matching: find.byType(EditorPenColorQuickButton),
    );
    final primaryTypeControl = find.ancestor(
      of: primaryTypeFinder,
      matching: find.byType(EditorPenTypeQuickButton),
    );
    final secondaryTypeControl = find.ancestor(
      of: secondaryTypeFinder,
      matching: find.byType(EditorPenTypeQuickButton),
    );
    expect(
      tester.widget<EditorPenColorQuickButton>(primaryColorControl).color,
      Colors.black,
    );
    expect(
      tester.widget<EditorPenColorQuickButton>(secondaryColorControl).color,
      const Color(0xFFF44336),
    );
    expect(
      tester.widget<EditorPenTypeQuickButton>(primaryTypeControl).type,
      InkToolType.normal,
    );
    expect(
      tester.widget<EditorPenTypeQuickButton>(secondaryTypeControl).type,
      InkToolType.dashed,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Übersicht'));
    await tester.pumpAndSettle();
    expect(find.text('Dokumentübersicht'), findsOneWidget);
  });
}

final class _MemoryRepository implements DocumentRepository {
  _MemoryRepository(this.directory, WhiteboardDocument initial)
    : _document = initial;

  final Directory directory;
  WhiteboardDocument _document;

  @override
  Future<Directory> assetDirectory(String documentId) async => directory;

  @override
  Future<void> delete(String documentId) async {}

  @override
  Future<List<DocumentSummary>> list() async => <DocumentSummary>[
    DocumentSummary.fromDocument(_document),
  ];

  @override
  Future<WhiteboardDocument?> load(String documentId) async =>
      documentId == _document.id ? _document : null;

  @override
  Future<WhiteboardDocument?> recover(String documentId) async => null;

  @override
  Future<void> save(WhiteboardDocument document) async {
    _document = document;
  }
}
