import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../models/vault_item.dart';
import '../providers/vault_provider.dart';
import '../theme/app_fonts.dart';

/// Export writes a decrypted copy outside the vault, which is the one thing
/// the vault otherwise never does, so it asks first and says where it goes.
Future<void> exportWithConfirmation(BuildContext context, VaultItem item) async {
  Directory? dir = await getDownloadsDirectory();
  dir ??= await getApplicationDocumentsDirectory();
  if (!context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF161B22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Export a decrypted copy?', style: AppFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold)),
      content: Text(
        'An unencrypted copy of "${item.title}" will be saved to:\n\n${dir!.path}\n\n'
        'It stays there until you delete it, and anyone who gets the phone, or connects it to a '
        'computer, can read it. Inside the vault it stays protected.',
        style: AppFonts.outfit(color: Colors.white70, fontSize: 13, height: 1.4),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text('Cancel', style: AppFonts.outfit(color: Colors.white54)),
        ),
        TextButton(
          key: const Key('export-confirm'),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text('Export', style: AppFonts.outfit(color: const Color(0xFF38BDF8), fontWeight: FontWeight.bold)),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final res = await context.read<VaultProvider>().exportFile(item, dir);
    if (res != null) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: const Color(0xFF059669),
        content: Text('Exported to ${res.path}', style: AppFonts.outfit(color: Colors.white)),
      ));
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(
      backgroundColor: const Color(0xFFE11D48),
      content: Text('Export failed: $e', style: AppFonts.outfit(color: Colors.white)),
    ));
  }
}

/// Deleting from the vault shreds the file: ask once, the same way from
/// everywhere, so a mis-tap under pressure can't destroy material.
Future<bool> confirmShred(BuildContext context, String title) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF161B22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Shred & Delete File', style: AppFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold)),
      content: Text(
        'Permanently wipe "$title" from encrypted storage? This action cannot be undone.',
        style: AppFonts.outfit(color: Colors.white70, fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text('Cancel', style: AppFonts.outfit(color: Colors.white54)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE11D48)),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text('Shred Permanently', style: AppFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold)),
        ),
      ],
    ),
  );
  return ok == true;
}
