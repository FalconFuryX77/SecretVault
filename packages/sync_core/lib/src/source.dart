import 'dart:io';
import 'dart:typed_data';

/// Where the bytes to back up come from.
///
/// The engine never needs a file on disk: in the app, the source is an item
/// inside the encrypted vault, decrypted piece by piece in memory. Plaintext
/// is never written out in order to be synced.
abstract class SyncSource {
  /// The whole content, start to end, in blocks of any size.
  Stream<Uint8List> openRead();

  /// [length] bytes starting at [offset].
  Future<Uint8List> readRange(int offset, int length);
}

/// A plain file (the command-line client and tests).
class FileSyncSource implements SyncSource {
  final File file;
  FileSyncSource(this.file);

  @override
  Stream<Uint8List> openRead() => file.openRead().map((b) => b is Uint8List ? b : Uint8List.fromList(b));

  @override
  Future<Uint8List> readRange(int offset, int length) async {
    final raf = await file.open();
    try {
      raf.setPositionSync(offset);
      return raf.readSync(length);
    } finally {
      await raf.close();
    }
  }
}

/// Bytes already in memory (short notes).
class MemorySyncSource implements SyncSource {
  final Uint8List bytes;
  MemorySyncSource(this.bytes);

  @override
  Stream<Uint8List> openRead() => bytes.isEmpty ? const Stream.empty() : Stream.value(bytes);

  @override
  Future<Uint8List> readRange(int offset, int length) async => Uint8List.sublistView(bytes, offset, offset + length);
}
