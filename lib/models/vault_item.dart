import 'dart:convert';

enum VaultCategory {
  document,
  image,
  video,
  note,
  keySecret,
}

/// Model representing an encrypted file, photo, video, document, or secret note
/// stored inside SecretVault.
class VaultItem {
  final String id;
  final String title;
  final VaultCategory category;
  final String? encryptedFilePath; // Relative path in sandbox vault_storage/
  final String? content; // Encrypted text content for notes / keys
  final String mimeType;
  final int fileSizeBytes;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isDecoy;
  final String? thumbnailBase64;
  final List<String> tags;
  final bool isFavorite;

  const VaultItem({
    required this.id,
    required this.title,
    required this.category,
    this.encryptedFilePath,
    this.content,
    required this.mimeType,
    required this.fileSizeBytes,
    required this.createdAt,
    required this.updatedAt,
    this.isDecoy = false,
    this.thumbnailBase64,
    this.tags = const [],
    this.isFavorite = false,
  });

  VaultItem copyWith({
    String? id,
    String? title,
    VaultCategory? category,
    String? encryptedFilePath,
    String? content,
    String? mimeType,
    int? fileSizeBytes,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isDecoy,
    String? thumbnailBase64,
    List<String>? tags,
    bool? isFavorite,
  }) {
    return VaultItem(
      id: id ?? this.id,
      title: title ?? this.title,
      category: category ?? this.category,
      encryptedFilePath: encryptedFilePath ?? this.encryptedFilePath,
      content: content ?? this.content,
      mimeType: mimeType ?? this.mimeType,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDecoy: isDecoy ?? this.isDecoy,
      thumbnailBase64: thumbnailBase64 ?? this.thumbnailBase64,
      tags: tags ?? this.tags,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'category': category.name,
        'encryptedFilePath': encryptedFilePath,
        'content': content,
        'mimeType': mimeType,
        'fileSizeBytes': fileSizeBytes,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'isDecoy': isDecoy ? 1 : 0,
        'thumbnailBase64': thumbnailBase64,
        'tags': jsonEncode(tags),
        'isFavorite': isFavorite ? 1 : 0,
      };

  factory VaultItem.fromMap(Map<String, dynamic> map) {
    List<String> parsedTags = [];
    if (map['tags'] != null) {
      try {
        final decoded = jsonDecode(map['tags'] as String);
        if (decoded is List) {
          parsedTags = decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {}
    }

    return VaultItem(
      id: map['id'] as String,
      title: map['title'] as String,
      category: VaultCategory.values.firstWhere(
        (c) => c.name == map['category'],
        orElse: () => VaultCategory.note,
      ),
      encryptedFilePath: map['encryptedFilePath'] as String?,
      content: map['content'] as String?,
      mimeType: map['mimeType'] as String? ?? 'application/octet-stream',
      fileSizeBytes: (map['fileSizeBytes'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.parse(map['createdAt'] as String),
      updatedAt: DateTime.parse(map['updatedAt'] as String),
      isDecoy: (map['isDecoy'] as num?) == 1,
      thumbnailBase64: map['thumbnailBase64'] as String?,
      tags: parsedTags,
      isFavorite: (map['isFavorite'] as num?) == 1,
    );
  }
}
