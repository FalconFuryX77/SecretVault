import 'package:flutter/material.dart';
import '../models/gesture.dart';
import 'vault_home_screen.dart';

/// Backward-compatibility delegate forwarding to VaultHomeScreen.
class NotesListScreen extends StatelessWidget {
  final VaultType vaultType;

  const NotesListScreen({super.key, this.vaultType = VaultType.primary});

  @override
  Widget build(BuildContext context) {
    return VaultHomeScreen(vaultType: vaultType);
  }
}
