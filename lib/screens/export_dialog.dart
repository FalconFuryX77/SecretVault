import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../models/vault_item.dart';
import '../providers/vault_provider.dart';
import '../theme/app_fonts.dart';
import '../theme/ui.dart';

/// Export writes a decrypted copy outside the vault, which is the one thing
/// the vault otherwise never does, so it asks first and says where it goes.
Future<void> exportWithConfirmation(BuildContext context, VaultItem item) async {
  Directory? dir = await getDownloadsDirectory();
  dir ??= await getApplicationDocumentsDirectory();
  if (!context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Ui.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Export a decrypted copy?', style: AppFonts.ui(color: Ui.ink, fontWeight: FontWeight.bold)),
      content: Text(
        'An unencrypted copy of "${item.title}" will be saved to:\n\n${dir!.path}\n\n'
        'It stays there until you delete it, and anyone who gets the phone, or connects it to a '
        'computer, can read it. Inside the vault it stays protected.',
        style: AppFonts.ui(color: Ui.ink2, fontSize: 13, height: 1.4),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text('Cancel', style: AppFonts.ui(color: Ui.ink2)),
        ),
        TextButton(
          key: const Key('export-confirm'),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text('Export', style: AppFonts.ui(color: Ui.ink2, fontWeight: FontWeight.bold)),
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
        backgroundColor: Ui.raised,
        content: Text('Exported to ${res.path}', style: AppFonts.ui(color: Ui.ink)),
      ));
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(
      backgroundColor: Ui.alert,
      content: Text('Export failed: $e', style: AppFonts.ui(color: Ui.ink)),
    ));
  }
}

/// Deleting from the vault shreds the file: ask once, the same way from
/// everywhere, so a mis-tap under pressure can't destroy material.
Future<bool> confirmShred(BuildContext context, String title) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Ui.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Shred & Delete File', style: AppFonts.ui(color: Ui.ink, fontWeight: FontWeight.bold)),
      content: Text(
        'Permanently wipe "$title" from encrypted storage? This action cannot be undone.',
        style: AppFonts.ui(color: Ui.ink2, fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text('Cancel', style: AppFonts.ui(color: Ui.ink2)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Ui.alert),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text('Shred Permanently', style: AppFonts.ui(color: Ui.ink, fontWeight: FontWeight.bold)),
        ),
      ],
    ),
  );
  return ok == true;
}
