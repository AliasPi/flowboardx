import 'dart:io';

import '../domain/model/document.dart';
import '../domain/model/library_organization.dart';

abstract interface class DocumentRepository {
  Future<void> save(WhiteboardDocument document);
  Future<WhiteboardDocument?> load(String documentId);
  Future<WhiteboardDocument?> recover(String documentId);
  Future<List<DocumentSummary>> list();
  Future<void> delete(String documentId);
  Future<Directory> assetDirectory(String documentId);
}

/// Optional capability implemented by repositories that persist library
/// folders. Keeping it separate preserves compatibility with lightweight and
/// remote [DocumentRepository] implementations: documents simply appear in
/// the root library when this capability is absent.
abstract interface class DocumentOrganizationRepository {
  Future<LibraryOrganization> loadOrganization();
  Future<void> saveOrganization(LibraryOrganization organization);
}

final class DocumentSummary {
  const DocumentSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.pageCount,
    required this.revision,
    this.thumbnailAssetId,
    this.recoveryAvailable = false,
  });

  final String id;
  final String title;
  final DateTime updatedAt;
  final int pageCount;
  final int revision;
  final String? thumbnailAssetId;
  final bool recoveryAvailable;

  factory DocumentSummary.fromDocument(
    WhiteboardDocument document, {
    bool recoveryAvailable = false,
  }) => DocumentSummary(
    id: document.id,
    title: document.title,
    updatedAt: document.updatedAt,
    pageCount: document.pages.length,
    revision: document.revision,
    thumbnailAssetId: document.thumbnailAssetId,
    recoveryAvailable: recoveryAvailable,
  );
}

final class DocumentStorageException implements Exception {
  const DocumentStorageException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message ($cause)';
}
