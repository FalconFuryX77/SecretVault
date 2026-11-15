import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum DeviceFileCategory {
  downloads,
  images,
  documents,
  audio,
  videos,
  archives,
  all,
}

enum FileSortBy {
  nameAsc,
  nameDesc,
  dateDesc,
  dateAsc,
  sizeDesc,
  sizeAsc,
}

class StorageSpaceInfo {
  final int totalBytes;
  final int usedBytes;
  final int freeBytes;

  double get usedFraction => totalBytes <= 0 ? 0 : (usedBytes / totalBytes).clamp(0.0, 1.0);

  static const List<int> _marketedGb = [8, 16, 32, 64, 128, 256, 512, 1024, 2048];

  /// Bytes per displayed "GB". Phones are sold as 64 / 128 / 256 GB, but
  /// some report that capacity in decimal units (128 x 10^9 bytes) and
  /// others in binary (128 x 2^30). Pick the unit in which the total is a
  /// size phones are actually sold in, so the card reads "128 GB" like the
  /// system's own storage screen, and use the same unit for "used".
  double get _bytesPerGb {
    for (final unit in const [1e9, 1073741824.0]) {
      final gb = totalBytes / unit;
      if (_marketedGb.any((m) => (gb - m).abs() / m < 0.01)) return unit;
    }
    return 1e9;
  }

  String get totalLabel => formatGb(totalBytes, bytesPerGb: _bytesPerGb);
  String get usedLabel => formatGb(usedBytes, bytesPerGb: _bytesPerGb);

  static String formatGb(int bytes, {double bytesPerGb = 1e9}) {
    final gb = bytes / bytesPerGb;
    if (gb >= 100) return '${gb.round()} GB';
    final text = gb.toStringAsFixed(1);
    return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text} GB';
  }

  const StorageSpaceInfo({
    required this.totalBytes,
    required this.usedBytes,
    required this.freeBytes,
  });
}

/// Service managing real on-device storage browsing and file operations.
class DeviceFileService {
  static const Set<String> imageExtensions = {
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg', 'heic'
  };

  static const Set<String> videoExtensions = {
    'mp4', 'mkv', 'mov', 'webm', 'avi', '3gp', 'flv', 'wmv'
  };

  static const Set<String> audioExtensions = {
    'mp3', 'wav', 'm4a', 'aac', 'flac', 'ogg', 'wma', 'opus'
  };

  static const Set<String> documentExtensions = {
    'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'csv', 'md', 'json'
  };

  static const Set<String> archiveExtensions = {
    'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'apk', 'iso'
  };

  /// Retrieves the default root browsing directory for the platform.
  Future<Directory> getDefaultRootDirectory() async {
    if (Platform.isAndroid) {
      final emulatedStorage = Directory('/storage/emulated/0');
      if (await emulatedStorage.exists()) {
        return emulatedStorage;
      }
    }

    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null && await downloads.exists()) {
        return downloads;
      }
    } catch (_) {}

    try {
      final appDocs = await getApplicationDocumentsDirectory();
      return appDocs;
    } catch (_) {
      return Directory.current;
    }
  }

  /// Retrieves common standard user storage directories.
  Future<Map<String, Directory>> getStandardDirectories() async {
    final Map<String, Directory> result = {};

    if (Platform.isAndroid) {
      final base = '/storage/emulated/0';
      final downloadDir = Directory('$base/Download');
      final documentsDir = Directory('$base/Documents');
      final dcimDir = Directory('$base/DCIM');
      final picturesDir = Directory('$base/Pictures');
      final musicDir = Directory('$base/Music');
      final moviesDir = Directory('$base/Movies');

      if (await downloadDir.exists()) result['Downloads'] = downloadDir;
      if (await documentsDir.exists()) result['Documents'] = documentsDir;
      if (await dcimDir.exists()) result['DCIM'] = dcimDir;
      if (await picturesDir.exists()) result['Pictures'] = picturesDir;
      if (await musicDir.exists()) result['Music'] = musicDir;
      if (await moviesDir.exists()) result['Movies'] = moviesDir;
    }

    if (result.isEmpty) {
      try {
        final down = await getDownloadsDirectory();
        if (down != null) result['Downloads'] = down;
      } catch (_) {}

      try {
        final docs = await getApplicationDocumentsDirectory();
        result['Documents'] = docs;
      } catch (_) {
        result['Documents'] = Directory.current;
      }
    }

    return result;
  }

  /// Lists directory contents with directory-first sorting and sorting rules.
  Future<List<FileSystemEntity>> listDirectory(
    Directory dir, {
    FileSortBy sortBy = FileSortBy.nameAsc,
    bool showHidden = false,
  }) async {
    try {
      if (!await dir.exists()) return [];

      final List<FileSystemEntity> entities = [];
      await for (final entity in dir.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (!showHidden && name.startsWith('.')) continue;
        entities.add(entity);
      }

      // Separate directories and files
      final directories = entities.whereType<Directory>().toList();
      final files = entities.whereType<File>().toList();

      void sortList<T extends FileSystemEntity>(List<T> list) {
        list.sort((a, b) {
          switch (sortBy) {
            case FileSortBy.nameAsc:
              return p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase());
            case FileSortBy.nameDesc:
              return p.basename(b.path).toLowerCase().compareTo(p.basename(a.path).toLowerCase());
            case FileSortBy.dateDesc:
              final aStat = a.statSync();
              final bStat = b.statSync();
              return bStat.modified.compareTo(aStat.modified);
            case FileSortBy.dateAsc:
              final aStat = a.statSync();
              final bStat = b.statSync();
              return aStat.modified.compareTo(bStat.modified);
            case FileSortBy.sizeDesc:
              final aSize = a is File ? a.lengthSync() : 0;
              final bSize = b is File ? b.lengthSync() : 0;
              return bSize.compareTo(aSize);
            case FileSortBy.sizeAsc:
              final aSize = a is File ? a.lengthSync() : 0;
              final bSize = b is File ? b.lengthSync() : 0;
              return aSize.compareTo(bSize);
          }
        });
      }

      sortList(directories);
      sortList(files);

      return [...directories, ...files];
    } catch (e) {
      debugPrint('Error listing directory: $e');
      return [];
    }
  }

  /// Returns the number of child files and subdirectories inside a directory.
  static int getChildCount(Directory dir) {
    try {
      if (!dir.existsSync()) return 0;
      int count = 0;
      for (final child in dir.listSync(followLinks: false)) {
        final name = p.basename(child.path);
        if (!name.startsWith('.')) {
          count++;
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  static const MethodChannel _platform = MethodChannel('com.example.secretvault/security');

  /// The phone's real storage totals, as the system reports them. Null where
  /// that isn't available (the card then shows no numbers rather than fake ones).
  Future<StorageSpaceInfo?> getStorageSpace() async {
    if (!Platform.isAndroid) return null;
    try {
      final m = await _platform.invokeMapMethod<String, dynamic>('storageStats');
      final total = (m?['total'] as num?)?.toInt() ?? 0;
      final free = (m?['free'] as num?)?.toInt() ?? 0;
      if (total <= 0) return null;
      return StorageSpaceInfo(totalBytes: total, usedBytes: total - free, freeBytes: free);
    } catch (_) {
      return null;
    }
  }

  /// Real per-category file counts across the user's shared folders. One
  /// walk, no cap: the numbers are whatever is actually on the phone, and
  /// they match what opening the category lists.
  Future<Map<DeviceFileCategory, int>> countByCategory() async {
    final counts = <DeviceFileCategory, int>{
      for (final c in DeviceFileCategory.values)
        if (c != DeviceFileCategory.all) c: 0,
    };
    final standardDirs = await getStandardDirectories();
    final roots = standardDirs.values.toList();
    if (roots.isEmpty) roots.add(await getDefaultRootDirectory());

    final visited = <String>{};
    for (final root in roots) {
      await _countDirectory(root, counts, visited, depth: _scanDepth);
    }

    final downloadDir = standardDirs['Downloads'];
    if (downloadDir != null && await downloadDir.exists()) {
      try {
        await for (final entity in downloadDir.list(followLinks: false)) {
          if (entity is File && !p.basename(entity.path).startsWith('.')) {
            counts[DeviceFileCategory.downloads] = counts[DeviceFileCategory.downloads]! + 1;
          }
        }
      } catch (_) {}
    }
    return counts;
  }

  static const int _scanDepth = 12;

  static DeviceFileCategory? _categoryForExtension(String ext) {
    if (imageExtensions.contains(ext)) return DeviceFileCategory.images;
    if (videoExtensions.contains(ext)) return DeviceFileCategory.videos;
    if (audioExtensions.contains(ext)) return DeviceFileCategory.audio;
    if (documentExtensions.contains(ext)) return DeviceFileCategory.documents;
    if (archiveExtensions.contains(ext)) return DeviceFileCategory.archives;
    return null;
  }

  Future<void> _countDirectory(
    Directory dir,
    Map<DeviceFileCategory, int> counts,
    Set<String> visited, {
    required int depth,
  }) async {
    if (depth <= 0 || !visited.add(dir.path)) return;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;
        if (entity is File) {
          final cat = _categoryForExtension(p.extension(entity.path).replaceAll('.', '').toLowerCase());
          if (cat != null) counts[cat] = counts[cat]! + 1;
        } else if (entity is Directory && !name.startsWith('Android')) {
          await _countDirectory(entity, counts, visited, depth: depth - 1);
        }
      }
    } catch (_) {}
  }

  /// Newest first, with one stat per file (a comparator that stats on every
  /// comparison gets very slow once there are thousands of files).
  static void _sortNewestFirst(List<File> files) {
    final modified = <String, DateTime>{};
    for (final f in files) {
      try {
        modified[f.path] = f.statSync().modified;
      } catch (_) {
        modified[f.path] = DateTime(0);
      }
    }
    files.sort((a, b) => modified[b.path]!.compareTo(modified[a.path]!));
  }

  /// Scans real directories for files matching a specific category.
  Future<List<File>> getFilesByCategory(DeviceFileCategory category, {int maxResults = 5000}) async {
    final List<File> matches = [];
    final standardDirs = await getStandardDirectories();

    if (category == DeviceFileCategory.downloads) {
      final downloadDir = standardDirs['Downloads'] ?? Directory('/storage/emulated/0/Download');
      if (await downloadDir.exists()) {
        try {
          await for (final entity in downloadDir.list(followLinks: false)) {
            if (matches.length >= maxResults) break;
            if (entity is File && !p.basename(entity.path).startsWith('.')) {
              matches.add(entity);
            }
          }
        } catch (_) {}
      }
      _sortNewestFirst(matches);
      return matches;
    }

    final roots = standardDirs.values.toList();
    if (roots.isEmpty) {
      roots.add(await getDefaultRootDirectory());
    }

    final allowedExts = _getExtensionsForCategory(category);

    for (final root in roots) {
      if (matches.length >= maxResults) break;
      await _scanDirectoryForExtensions(root, allowedExts, matches, maxResults: maxResults, depth: _scanDepth);
    }

    _sortNewestFirst(matches);

    return matches;
  }

  /// Searches files across storage matching query.
  Future<List<File>> searchFiles(String query, {Directory? rootDir, int maxResults = 100}) async {
    final cleanQuery = query.toLowerCase().trim();
    if (cleanQuery.isEmpty) return [];

    final root = rootDir ?? await getDefaultRootDirectory();
    final List<File> results = [];

    await _searchDirectory(root, cleanQuery, results, maxResults: maxResults, depth: 4);
    return results;
  }

  Future<void> _searchDirectory(
    Directory dir,
    String query,
    List<File> results, {
    required int maxResults,
    int depth = 3,
  }) async {
    if (depth <= 0 || results.length >= maxResults) return;

    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (results.length >= maxResults) break;
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;

        if (entity is File) {
          if (name.toLowerCase().contains(query)) {
            results.add(entity);
          }
        } else if (entity is Directory) {
          // Skip system/hidden folders
          if (!name.startsWith('Android') && !name.startsWith('.')) {
            await _searchDirectory(entity, query, results, maxResults: maxResults, depth: depth - 1);
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _scanDirectoryForExtensions(
    Directory dir,
    Set<String> extensions,
    List<File> results, {
    required int maxResults,
    int depth = 3,
  }) async {
    if (depth <= 0 || results.length >= maxResults) return;

    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (results.length >= maxResults) break;
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;

        if (entity is File) {
          final ext = p.extension(entity.path).replaceAll('.', '').toLowerCase();
          if (extensions.isEmpty || extensions.contains(ext)) {
            results.add(entity);
          }
        } else if (entity is Directory) {
          if (!name.startsWith('Android') && !name.startsWith('.')) {
            await _scanDirectoryForExtensions(entity, extensions, results, maxResults: maxResults, depth: depth - 1);
          }
        }
      }
    } catch (_) {}
  }

  Set<String> _getExtensionsForCategory(DeviceFileCategory category) {
    switch (category) {
      case DeviceFileCategory.images:
        return imageExtensions;
      case DeviceFileCategory.videos:
        return videoExtensions;
      case DeviceFileCategory.audio:
        return audioExtensions;
      case DeviceFileCategory.documents:
        return documentExtensions;
      case DeviceFileCategory.archives:
        return archiveExtensions;
      case DeviceFileCategory.downloads:
      case DeviceFileCategory.all:
        return {};
    }
  }

  /// Deletes a file or directory.
  Future<bool> deleteEntity(FileSystemEntity entity) async {
    try {
      if (entity is File) {
        await entity.delete();
      } else if (entity is Directory) {
        await entity.delete(recursive: true);
      }
      return true;
    } catch (e) {
      debugPrint('Error deleting entity: $e');
      return false;
    }
  }

  /// Renames a file or directory.
  Future<FileSystemEntity?> renameEntity(FileSystemEntity entity, String newName) async {
    try {
      final parent = entity.parent.path;
      final newPath = p.join(parent, newName);
      return await entity.rename(newPath);
    } catch (e) {
      debugPrint('Error renaming entity: $e');
      return null;
    }
  }

  /// Creates a new directory.
  Future<Directory?> createFolder(Directory parent, String folderName) async {
    try {
      final newDir = Directory(p.join(parent.path, folderName));
      return await newDir.create(recursive: true);
    } catch (e) {
      debugPrint('Error creating folder: $e');
      return null;
    }
  }

  /// Creates a new empty or initial text file.
  Future<File?> createTextFile(Directory parent, String fileName, String content) async {
    try {
      final file = File(p.join(parent.path, fileName));
      return await file.writeAsString(content);
    } catch (e) {
      debugPrint('Error creating text file: $e');
      return null;
    }
  }

  /// Formats byte size into human readable format (KB, MB, GB).
  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double count = bytes.toDouble();
    while (count >= 1024 && i < suffixes.length - 1) {
      count /= 1024;
      i++;
    }
    return '${count.toStringAsFixed(count < 10 && i > 0 ? 1 : 0)} ${suffixes[i]}';
  }
}
