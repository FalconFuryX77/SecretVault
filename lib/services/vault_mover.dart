import 'dart:io';

import 'package:flutter/services.dart';

import '../vault/vault_container.dart';
import 'vault_service.dart';

/// Moving a vault (with its decoy) to another phone, or to a reinstalled or
/// renamed app, without a backup server: the encrypted vault file is copied
/// to a place the user picks, with a one-time transfer code; the other
/// install copies it in, opens it with the code and sets its own PINs.
/// See [VaultSession.exportForTransfer].
class VaultMover {
  static const MethodChannel _ch = MethodChannel('app.vault/move');

  /// Where to write the copy (Android's "save as"); null if cancelled.
  static Future<String?> pickDestination(String name) => _ch.invokeMethod<String>('create', {'name': name});

  /// The copy to move in (Android's "open"); null if cancelled.
  static Future<String?> pickSource() => _ch.invokeMethod<String>('open');

  static Future<({int done, int total})> progress() async {
    final m = (await _ch.invokeMapMethod<String, Object?>('progress'))!;
    return (done: (m['done'] as num).toInt(), total: (m['total'] as num).toInt());
  }

  /// Copies the open vault's container to [uri], with its transfer slot.
  /// Returns the transfer code.
  static Future<Uint8List> moveOut(VaultService vaults, String uri) async {
    final session = vaults.session ?? (throw StateError('vault is locked'));
    final path = (await vaults.containerFile()).path;
    return session.exportForTransfer((offset, slot) =>
        _ch.invokeMethod('copyOut', {'path': path, 'uri': uri, 'patchOffset': offset, 'patch': slot}));
  }

  /// Removes the copy (after a failed move).
  static Future<void> deleteCopy(String uri) => _ch.invokeMethod('delete', {'uri': uri});

  /// Copies a moved vault file in, next to where the container goes.
  static Future<File> copyIn(VaultService vaults, String uri) async {
    final dest = File('${(await vaults.containerFile()).path}.move');
    await _ch.invokeMethod('copyIn', {'uri': uri, 'path': dest.path});
    return dest;
  }

  /// 16 bytes as 8 groups of 4 hex characters.
  static String formatCode(Uint8List code) {
    final h = code.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return [for (var i = 0; i < h.length; i += 4) h.substring(i, i + 4)].join(' ');
  }

  static Uint8List? parseCode(String text) {
    final h = text.replaceAll(RegExp(r'[\s-]'), '').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(h)) return null;
    return Uint8List.fromList([for (var i = 0; i < 32; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);
  }
}
