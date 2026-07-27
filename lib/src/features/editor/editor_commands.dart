import '../../domain/commands/document_command.dart';
import '../../domain/commands/document_commands.dart';
import '../../domain/grouping/ink_grouping_engine.dart';
import '../../domain/model/board_object.dart';
import '../../domain/model/document.dart';
import '../../domain/model/ink.dart';
import '../../domain/model/scene_order.dart';

final class AddStrokeAndRegroupCommand implements DocumentCommand {
  AddStrokeAndRegroupCommand({
    required this.pageId,
    required this.stroke,
    required this.grouping,
    this.objectId,
    this.pdfPageIndex,
  });

  final String pageId;
  final InkStroke stroke;
  final String? objectId;
  final int? pdfPageIndex;
  final InkGroupingEngine grouping;

  @override
  String get label =>
      objectId == null ? 'Strich hinzufügen' : 'Objekt annotieren';

  @override
  WhiteboardDocument apply(WhiteboardDocument document) {
    final page = document.pageById(pageId);
    if (page == null) throw StateError('Seite $pageId existiert nicht.');
    if (objectId != null) {
      final target = page.objectById(objectId!);
      if (target == null) {
        throw StateError('Annotationsziel $objectId existiert nicht.');
      }
      final layers = page.annotationLayers.toList();
      var index = layers.indexWhere(
        (layer) =>
            layer.objectId == objectId && layer.pdfPageIndex == pdfPageIndex,
      );
      if (index < 0 && pdfPageIndex != null) {
        index = layers.indexWhere(
          (layer) => layer.objectId == objectId && layer.pdfPageIndex == null,
        );
      }
      if (index < 0) {
        layers.add(
          ObjectInkLayer(
            id: pdfPageIndex == null
                ? '${objectId!}.annotations'
                : '${objectId!}.pdf.$pdfPageIndex.annotations',
            objectId: objectId!,
            pdfPageIndex: pdfPageIndex,
            strokes: [stroke.copyWith(zIndex: 0)],
          ),
        );
      } else {
        final layer = layers[index];
        final maximum = layer.strokes.fold<int>(
          -1,
          (value, candidate) =>
              candidate.zIndex > value ? candidate.zIndex : value,
        );
        layers[index] = layers[index].copyWith(
          pdfPageIndex: pdfPageIndex,
          strokes: [
            ...layer.strokes,
            stroke.copyWith(zIndex: maximum + 1),
          ],
        );
      }
      return document.replacePage(page.copyWith(annotationLayers: layers));
    }
    if (page.strokes.any((candidate) => candidate.id == stroke.id)) {
      throw StateError('Strich-ID ${stroke.id} existiert bereits.');
    }
    final topmost = stroke.copyWith(
      zIndex: nextBoardSceneZIndex(
        objects: page.objects,
        strokes: page.strokes,
      ),
    );
    final withStroke = page.copyWith(strokes: [...page.strokes, topmost]);
    final groups = grouping.regroupIncrementally(
      page: withStroke,
      changedStrokeIds: [topmost.id],
      dirtyRegion: topmost.bounds,
      pageBeforeAppend: page,
      appendedStroke: topmost,
    );
    return document.replacePage(withStroke.copyWith(groups: groups.groups));
  }
}

final class ReplaceDocumentCommand implements DocumentCommand {
  const ReplaceDocumentCommand(this.next, this.label);

  final WhiteboardDocument next;
  @override
  final String label;

  @override
  WhiteboardDocument apply(WhiteboardDocument document) {
    if (document.id != next.id) {
      throw StateError('Dokument-ID darf nicht geändert werden.');
    }
    return next.copyWith(
      updatedAt: DateTime.now().toUtc(),
      revision: document.revision + 1,
    );
  }
}

final class ImportObjectCommand implements DocumentCommand {
  const ImportObjectCommand({
    required this.pageId,
    required this.asset,
    required this.object,
  });

  final String pageId;
  final DocumentAsset asset;
  final BoardObject object;

  @override
  String get label => 'Datei einfügen';

  @override
  WhiteboardDocument apply(WhiteboardDocument document) {
    final page = document.pageById(pageId);
    if (page == null) throw StateError('Seite $pageId existiert nicht.');
    if (document.assets.any((candidate) => candidate.id == asset.id)) {
      throw StateError('Asset ${asset.id} existiert bereits.');
    }
    final withAsset = document.copyWith(
      assets: [...document.assets, asset],
      updatedAt: DateTime.now().toUtc(),
      revision: document.revision + 1,
    );
    final topmost = copyBoardObjectWithZIndex(
      object,
      nextBoardSceneZIndex(objects: page.objects, strokes: page.strokes),
    );
    return withAsset.replacePage(
      page.copyWith(objects: [...page.objects, topmost]),
    );
  }
}

/// Imports one PDF asset and materializes all requested objects/pages as one
/// undoable history entry. Keeping the asset and every scene mutation atomic
/// prevents partially imported documents after errors or undo.
final class ImportPdfContentCommand implements DocumentCommand {
  ImportPdfContentCommand({
    required this.asset,
    required this.currentPageId,
    Iterable<PdfObject> currentPageObjects = const [],
    Iterable<BoardPage> newPages = const [],
    this.activateLastImportedPage = true,
  }) : currentPageObjects = List<PdfObject>.unmodifiable(currentPageObjects),
       newPages = List<BoardPage>.unmodifiable(newPages);

  final DocumentAsset asset;
  final String currentPageId;
  final List<PdfObject> currentPageObjects;
  final List<BoardPage> newPages;
  final bool activateLastImportedPage;

  @override
  String get label => 'PDF einfügen';

  @override
  WhiteboardDocument apply(WhiteboardDocument document) {
    if (document.assets.any((candidate) => candidate.id == asset.id)) {
      throw StateError('Asset ${asset.id} existiert bereits.');
    }
    final current = document.pageById(currentPageId);
    if (current == null) {
      throw StateError('Seite $currentPageId existiert nicht.');
    }
    if (document.pages.length + newPages.length >
        WhiteboardDocument.maxPageCount) {
      throw StateError(
        'Der Import würde das Limit von '
        '${WhiteboardDocument.maxPageCount} Seiten überschreiten.',
      );
    }
    final allIds = <String>{
      ...document.pages.expand(
        (page) => <String>[page.id, ...page.objects.map((object) => object.id)],
      ),
    };
    for (final object in currentPageObjects) {
      if (!allIds.add(object.id)) {
        throw StateError('Objekt-ID ${object.id} existiert bereits.');
      }
    }
    for (final importedPage in newPages) {
      if (!allIds.add(importedPage.id)) {
        throw StateError('Seiten-ID ${importedPage.id} existiert bereits.');
      }
      for (final object in importedPage.objects) {
        if (!allIds.add(object.id)) {
          throw StateError('Objekt-ID ${object.id} existiert bereits.');
        }
      }
    }

    var next = document.copyWith(assets: [...document.assets, asset]);
    if (currentPageObjects.isNotEmpty) {
      var z = nextBoardSceneZIndex(
        objects: current.objects,
        strokes: current.strokes,
      );
      final layered = currentPageObjects
          .map((object) => copyBoardObjectWithZIndex(object, z++))
          .toList(growable: false);
      next = next.replacePage(
        current.copyWith(objects: [...current.objects, ...layered]),
      );
    }
    if (newPages.isNotEmpty) {
      // The user may navigate or start writing while a large PDF is copied.
      // Insert behind the initiating page, while retaining the active page by
      // identity unless the caller explicitly wants to open the import.
      final activePageId = next.currentPage.id;
      final insertAt =
          next.pages.indexWhere((page) => page.id == currentPageId) + 1;
      final pages = next.pages.toList()
        ..insertAll(insertAt, newPages.map((page) => page.sanitized()));
      final activeIndex = activateLastImportedPage
          ? insertAt + newPages.length - 1
          : pages.indexWhere((page) => page.id == activePageId);
      next = next.copyWith(
        pages: pages,
        currentPageIndex: activeIndex >= 0
            ? activeIndex
            : next.currentPageIndex.clamp(0, pages.length - 1),
      );
    }
    return next.copyWith(
      updatedAt: DateTime.now().toUtc(),
      revision: document.revision + 1,
    );
  }
}

/// Adds a materialized user-template page and all of its freshly copied files
/// as one undoable document operation.
final class AddTemplatePageCommand implements DocumentCommand {
  AddTemplatePageCommand({
    required this.page,
    required Iterable<DocumentAsset> assets,
    this.insertAt,
    this.selectNewPage = true,
  }) : assets = List<DocumentAsset>.unmodifiable(assets);

  final BoardPage page;
  final List<DocumentAsset> assets;
  final int? insertAt;
  final bool selectNewPage;

  @override
  String get label => 'Nutzervorlage einfügen';

  @override
  WhiteboardDocument apply(WhiteboardDocument document) {
    final existingIds = document.assets.map((asset) => asset.id).toSet();
    for (final asset in assets) {
      if (!existingIds.add(asset.id)) {
        throw StateError('Asset ${asset.id} existiert bereits.');
      }
    }
    for (final object in page.objects) {
      final assetId = switch (object) {
        final ImageObject image => image.assetId,
        final PdfObject pdf => pdf.assetId,
        _ => null,
      };
      if (assetId != null && !existingIds.contains(assetId)) {
        throw StateError(
          'Objekt ${object.id} verweist auf ein fehlendes Asset.',
        );
      }
    }
    final withAssets = document.copyWith(
      assets: [...document.assets, ...assets],
    );
    return AddPageCommand(
      page,
      insertAt: insertAt,
      selectNewPage: selectNewPage,
    ).apply(withAssets);
  }
}
