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
      title: Text('Export a decrypted copy?'),
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
          child: Text('Export', style: AppFonts.ui(color: Ui.ink2, fontWeight: FontWeight.w500)),
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
        content: Text('Exported to ${res.path}'),
      ));
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(
      content: Text('Export failed: $e'),
    ));
  }
}

/// Deleting from the vault shreds the file: it has to be held, the same way
/// from everywhere, so a mis-tap under pressure can't destroy material.
Future<bool> confirmShred(BuildContext context, String title) => confirmByHolding(
      context,
      title: 'Shred "$title"?',
      message: 'Its key is destroyed and its data overwritten. It cannot be recovered from this phone.',
      action: 'Hold to shred',
    );
