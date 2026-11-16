import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../navigation/vault_routes.dart';
import '../providers/unlock_provider.dart';
import '../services/vault_mover.dart';
import '../services/vault_service.dart';
import '../theme/app_fonts.dart';
import '../vault/vault_container.dart';
import '../cover/trimmer_home_screen.dart';
import 'vault_home_screen.dart';
import '../theme/ui.dart';

const _accent = Ui.signal;

/// First run on a new phone (or after reinstalling or renaming the app):
/// brings in a vault moved out with "Move to another phone or app". Pick the
/// file, enter the transfer code, set a PIN for each vault in it.
class MoveInScreen extends StatefulWidget {
  const MoveInScreen({super.key});

  @override
  State<MoveInScreen> createState() => _MoveInScreenState();
}

class _MoveInScreenState extends State<MoveInScreen> {
  final TextEditingController _code = TextEditingController();
  final List<TextEditingController> _pins = [];
  File? _copy;
  int? _vaults;
  bool _busy = false;
  double? _progress;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    for (final c in _pins) {
      c.dispose();
    }
    final copy = _copy;
    // Left without finishing: don't leave the copy behind.
    if (copy != null && _vaults != -1) copy.delete().catchError((Object _) => copy);
    super.dispose();
  }

  Future<void> _pick() async {
    final vaults = context.read<VaultService>();
    final unlock = context.read<UnlockProvider>();
    final uri = await unlock.withoutAutoLock(VaultMover.pickSource);
    if (uri == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _progress = null;
    });
    var copying = true;
    unawaited(() async {
      while (copying) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        try {
          final p = await VaultMover.progress();
          if (mounted && p.total > 0) setState(() => _progress = p.done / p.total);
        } catch (_) {}
      }
    }());
    try {
      final copy = await VaultMover.copyIn(vaults, uri);
      if (mounted) setState(() => _copy = copy);
    } catch (e) {
      if (mounted) setState(() => _error = 'That file could not be read: $e');
    } finally {
      copying = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkCode() async {
    final code = VaultMover.parseCode(_code.text);
    final copy = _copy;
    if (code == null || copy == null) {
      setState(() => _error = 'Enter the transfer code: 8 groups of 4 characters.');
      return;
    }
    try {
      final n = await VaultContainer.transferVaultCount(copy, code);
      setState(() {
        _vaults = n;
        _error = null;
        _pins
          ..clear()
          ..addAll([for (var i = 0; i < n; i++) TextEditingController()]);
      });
    } on FormatException {
      setState(() => _error = "That transfer code doesn't open this file.");
    } catch (e) {
      setState(() => _error = "This file isn't a moved vault, or it's damaged.");
    }
  }

  Future<void> _finish() async {
    final vaults = context.read<VaultService>();
    final unlock = context.read<UnlockProvider>();
    final code = VaultMover.parseCode(_code.text);
    final copy = _copy;
    if (code == null || copy == null) return;
    final pins = _pins.map((c) => c.text).toList();
    if (pins.any((p) => p.length < 6)) {
      setState(() => _error = 'Use at least 6 characters for each PIN.');
      return;
    }
    if (pins.toSet().length != pins.length) {
      setState(() => _error = 'Each vault needs its own PIN.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await VaultContainer.completeTransfer(copy, await vaults.containerFile(), vaults.crypto, code, pins);
      _vaults = -1; // done: the copy is now the container
      final session = await vaults.unlockWithPin(pins.first);
      for (final c in _pins) {
        c.clear();
      }
      _code.clear();
      await unlock.onSetupComplete();
      if (!mounted || session == null) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const TrimmerHomeScreen()),
        (_) => false,
      );
      rootNavigatorKey.currentState?.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '${vaultRoutePrefix}home'),
          builder: (_) => const VaultHomeScreen(),
        ),
      );
    } on CredentialInUseException {
      setState(() {
        _busy = false;
        _error = 'Each vault needs its own PIN.';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'The vault could not be moved in: $e';
        });
      }
    }
  }

  Widget _field(TextEditingController c, String hint, {String? key, bool obscure = false, int lines = 1}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          key: key == null ? null : Key(key),
          controller: c,
          enabled: !_busy,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          minLines: lines,
          maxLines: lines,
          keyboardType: obscure ? TextInputType.visiblePassword : TextInputType.text,
          style: AppFonts.firaCode(fontSize: 15, color: Ui.ink),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: AppFonts.ui(fontSize: 14, color: Ui.ink3),
            filled: true,
            fillColor: Ui.surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
          ),
        ),
      );

  Widget _button(String label, String key, VoidCallback? onPressed) => SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          key: Key(key),
          onPressed: _busy ? null : onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: _accent,
            foregroundColor: Ui.canvas,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: Text(label, style: AppFonts.ui(fontSize: 15, fontWeight: FontWeight.bold)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final n = _vaults ?? 0;
    return Scaffold(
      backgroundColor: Ui.canvas,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('Move a Vault Here', style: AppFonts.ui(fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _copy == null
                    ? 'Pick the file made with "Move to another phone or app" on the other phone or app.'
                    : (_vaults == null
                        ? 'Enter the transfer code that was shown when the file was made.'
                        : (n == 1
                            ? 'Choose a PIN for the vault on this phone (it can be the old one).'
                            : 'This file holds $n vaults: the one it was moved from, and its decoy. '
                                'Choose a PIN for each (they can be the old ones).')),
                style: AppFonts.ui(fontSize: 14, color: Ui.ink2),
              ),
              const SizedBox(height: 20),
              if (_copy == null)
                _button('Choose the file', 'move-in-pick', _pick)
              else if (_vaults == null) ...[
                _field(_code, 'xxxx xxxx xxxx xxxx …', key: 'move-in-code', lines: 2),
                _button('Continue', 'move-in-code-ok', _checkCode),
              ] else ...[
                for (var i = 0; i < n; i++)
                  _field(_pins[i], i == 0 ? 'PIN for the vault' : (i == 1 ? 'PIN for its decoy' : 'PIN for decoy $i'), key: 'move-in-pin-$i', obscure: true),
                _button('Move In', 'move-in-finish', _finish),
              ],
              if (_busy) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _progress, color: _accent),
              ],
              if (_error != null) ...[
                const SizedBox(height: 14),
                Text(_error!, key: const Key('move-in-error'), style: AppFonts.ui(fontSize: 13, color: Ui.alert)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
