import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/gesture.dart';
import '../models/vault_item.dart';
import 'encryption_service.dart';

/// Handles physical storage, encryption, decryption, and secure deletion
/// of files (documents, images, videos) in the app's sandboxed vault storage.
class FileVaultService {
  final EncryptionService _encryptionService;
  final Uuid _uuid;

  FileVaultService({
    EncryptionService? encryptionService,
    Uuid? uuid,
  })  : _encryptionService = encryptionService ?? EncryptionService(),
        _uuid = uuid ?? const Uuid();

  /// Gets the directory where encrypted vault files are stored.
  Future<Directory> _getVaultStorageDir(VaultType vaultType) async {
    final appDir = await getApplicationDocumentsDirectory();
    final subFolder = vaultType == VaultType.primary ? 'vault_storage' : 'decoy_storage';
    final vaultDir = Directory(p.join(appDir.path, subFolder));
    if (!await vaultDir.exists()) {
      await vaultDir.create(recursive: true);
    }
    return vaultDir;
  }

  /// Encrypts an external file and stores it securely in the sandbox.
  /// If [deleteOriginal] is true, deletes the cleartext original from the external storage.
  Future<VaultItem> importFile({
    required File sourceFile,
    required String title,
    required VaultCategory category,
    required String mimeType,
    VaultType vaultType = VaultType.primary,
    bool deleteOriginal = false,
    List<String> tags = const [],
  }) async {
    final bytes = await sourceFile.readAsBytes();
    final encryptedBytes = await _encryptionService.encryptBytes(bytes, vaultType);

    final storageDir = await _getVaultStorageDir(vaultType);
    final fileId = _uuid.v4();
    final encryptedFileName = '$fileId.enc';
    final destinationFile = File(p.join(storageDir.path, encryptedFileName));

    await destinationFile.writeAsBytes(encryptedBytes, flush: true);

    if (deleteOriginal) {
      try {
        await sourceFile.delete();
      } catch (_) {
        // Handled gracefully if permission denied
      }
    }

    final now = DateTime.now();
    return VaultItem(
      id: fileId,
      title: title,
      category: category,
      encryptedFilePath: encryptedFileName,
      mimeType: mimeType,
      fileSizeBytes: bytes.length,
      createdAt: now,
      updatedAt: now,
      isDecoy: vaultType == VaultType.decoy,
      tags: tags,
    );
  }

  /// Decrypts an encrypted file directly into an in-memory byte buffer for viewing.
  Future<Uint8List?> readDecryptedFileBytes(
    VaultItem item, [
    VaultType vaultType = VaultType.primary,
  ]) async {
    if (item.encryptedFilePath == null) return null;

    final storageDir = await _getVaultStorageDir(vaultType);
    final targetFile = File(p.join(storageDir.path, item.encryptedFilePath!));

    if (!await targetFile.exists()) return null;

    final encryptedBytes = await targetFile.readAsBytes();
    return await _encryptionService.decryptBytes(encryptedBytes, vaultType);
  }

  /// Permanently deletes an encrypted file from disk.
  Future<void> deleteEncryptedFile(
    VaultItem item, [
    VaultType vaultType = VaultType.primary,
  ]) async {
    if (item.encryptedFilePath == null) return;

    final storageDir = await _getVaultStorageDir(vaultType);
    final targetFile = File(p.join(storageDir.path, item.encryptedFilePath!));

    if (await targetFile.exists()) {
      await targetFile.delete();
    }
  }

  /// Exports a decrypted file to a target destination directory.
  Future<File?> exportFile({
    required VaultItem item,
    required Directory destinationDir,
    VaultType vaultType = VaultType.primary,
  }) async {
    final bytes = await readDecryptedFileBytes(item, vaultType);
    if (bytes == null) return null;

    final outputFile = File(p.join(destinationDir.path, item.title));
    await outputFile.writeAsBytes(bytes, flush: true);
    return outputFile;
  }
}
