import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/services/device_file_service.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceFileService Unit Tests', () {
    late DeviceFileService service;
    late Directory tempDir;

    setUp(() async {
      service = DeviceFileService();
      tempDir = await Directory.systemTemp.createTemp('secretvault_test_fs_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('formatBytes formats binary sizes correctly', () {
      expect(DeviceFileService.formatBytes(0), equals('0 B'));
      expect(DeviceFileService.formatBytes(512), equals('512 B'));
      expect(DeviceFileService.formatBytes(1024), equals('1.0 KB'));
      expect(DeviceFileService.formatBytes(1024 * 1024 * 5), equals('5.0 MB'));
      expect(DeviceFileService.formatBytes(1024 * 1024 * 1024 * 2), equals('2.0 GB'));
    });

    test('listDirectory lists folders and files with proper sorting', () async {
      // Create subfolder and test files
      final subFolder = await service.createFolder(tempDir, 'FolderB');
      await service.createFolder(tempDir, 'FolderA');
      await service.createTextFile(tempDir, 'file_z.txt', 'Content Z');
      await service.createTextFile(tempDir, 'file_a.txt', 'Content A');

      expect(subFolder, isNotNull);

      final entities = await service.listDirectory(tempDir, sortBy: FileSortBy.nameAsc);
      expect(entities.length, equals(4));

      // Directories should appear first, sorted A->B
      expect(entities[0] is Directory, isTrue);
      expect(p.basename(entities[0].path), equals('FolderA'));
      expect(entities[1] is Directory, isTrue);
      expect(p.basename(entities[1].path), equals('FolderB'));

      // Files follow, sorted A->Z
      expect(entities[2] is File, isTrue);
      expect(p.basename(entities[2].path), equals('file_a.txt'));
      expect(entities[3] is File, isTrue);
      expect(p.basename(entities[3].path), equals('file_z.txt'));
    });

    test('renameEntity and deleteEntity operate accurately', () async {
      final file = await service.createTextFile(tempDir, 'original.txt', 'Hello World');
      expect(file, isNotNull);
      expect(await file!.exists(), isTrue);

      final renamed = await service.renameEntity(file, 'renamed.txt');
      expect(renamed, isNotNull);
      expect(await renamed!.exists(), isTrue);
      expect(await file.exists(), isFalse);

      final deleted = await service.deleteEntity(renamed);
      expect(deleted, isTrue);
      expect(await renamed.exists(), isFalse);
    });

    test('searchFiles finds matching files recursively', () async {
      final sub = await service.createFolder(tempDir, 'SubDir');
      await service.createTextFile(tempDir, 'invoice_2026.pdf', 'pdf data');
      await service.createTextFile(sub!, 'invoice_summary.txt', 'txt data');
      await service.createTextFile(sub, 'notes.md', 'markdown data');

      final searchResults = await service.searchFiles('invoice', rootDir: tempDir);
      expect(searchResults.length, equals(2));
      expect(searchResults.any((f) => p.basename(f.path) == 'invoice_2026.pdf'), isTrue);
      expect(searchResults.any((f) => p.basename(f.path) == 'invoice_summary.txt'), isTrue);
    });
  });
}
