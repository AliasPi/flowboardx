import 'package:flutter/foundation.dart';

/// A user-created container in the local document library.
///
/// Documents keep their own stable IDs and are never moved on disk when they
/// are assigned to a folder. This makes reorganizing the library atomic and
/// prevents folder renames from risking document or asset loss.
@immutable
final class LibraryFolder {
  const LibraryFolder({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  LibraryFolder copyWith({String? name, DateTime? updatedAt}) => LibraryFolder(
    id: id,
    name: name ?? this.name,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  factory LibraryFolder.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    final createdAt = json['createdAt'];
    final updatedAt = json['updatedAt'];
    if (id is! String ||
        id.trim().isEmpty ||
        name is! String ||
        name.trim().isEmpty ||
        createdAt is! String ||
        updatedAt is! String) {
      throw const FormatException('Der Ordnereintrag ist unvollständig.');
    }
    return LibraryFolder(
      id: id,
      name: name.trim(),
      createdAt: DateTime.parse(createdAt).toUtc(),
      updatedAt: DateTime.parse(updatedAt).toUtc(),
    );
  }
}

/// Small, separately persisted index for document-to-folder assignments.
/// Missing indexes decode to [empty], keeping all existing installations fully
/// backwards compatible.
@immutable
final class LibraryOrganization {
  const LibraryOrganization({
    this.folders = const <LibraryFolder>[],
    this.documentFolderIds = const <String, String>{},
  });

  static const empty = LibraryOrganization();

  final List<LibraryFolder> folders;
  final Map<String, String> documentFolderIds;

  LibraryOrganization normalized({Set<String>? existingDocumentIds}) {
    final uniqueFolders = <String, LibraryFolder>{};
    for (final folder in folders) {
      if (folder.id.trim().isEmpty || folder.name.trim().isEmpty) continue;
      uniqueFolders.putIfAbsent(folder.id, () => folder);
    }
    final assignments = <String, String>{};
    for (final entry in documentFolderIds.entries) {
      if (entry.key.trim().isEmpty ||
          !uniqueFolders.containsKey(entry.value) ||
          (existingDocumentIds != null &&
              !existingDocumentIds.contains(entry.key))) {
        continue;
      }
      assignments[entry.key] = entry.value;
    }
    final sortedFolders = uniqueFolders.values.toList(growable: false)
      ..sort((a, b) {
        final name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return name != 0 ? name : a.id.compareTo(b.id);
      });
    return LibraryOrganization(
      folders: List<LibraryFolder>.unmodifiable(sortedFolders),
      documentFolderIds: Map<String, String>.unmodifiable(assignments),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 1,
    'folders': folders.map((folder) => folder.toJson()).toList(growable: false),
    'documentFolderIds': documentFolderIds,
  };

  factory LibraryOrganization.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException(
        'Die Version der Bibliotheksordner wird nicht unterstützt.',
      );
    }
    final rawFolders = json['folders'];
    final rawAssignments = json['documentFolderIds'];
    if (rawFolders is! List || rawAssignments is! Map) {
      throw const FormatException('Der Bibliotheksindex ist ungültig.');
    }
    return LibraryOrganization(
      folders: rawFolders
          .map((item) {
            if (item is! Map) {
              throw const FormatException('Ein Ordnereintrag ist ungültig.');
            }
            return LibraryFolder.fromJson(Map<String, Object?>.from(item));
          })
          .toList(growable: false),
      documentFolderIds: rawAssignments.map<String, String>((key, value) {
        if (key is! String || value is! String) {
          throw const FormatException('Eine Ordnerzuordnung ist ungültig.');
        }
        return MapEntry<String, String>(key, value);
      }),
    ).normalized();
  }
}
