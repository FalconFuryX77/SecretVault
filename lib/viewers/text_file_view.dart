import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/vault_item.dart';
import '../providers/unlock_provider.dart';
import '../providers/vault_provider.dart';
import '../services/vault_clipboard.dart';
import '../theme/app_fonts.dart';
import '../theme/ui.dart';

/// Reads and edits a plain-text file stored in the vault. Saving writes a
/// new encrypted copy and shreds the old one; nothing goes to storage in
/// the clear, and the keyboard is asked not to learn what is typed.
class TextFileView extends StatefulWidget {
  final VaultItem item;
  final String text;

  /// Called with the updated item after a save.
  final ValueChanged<VaultItem> onSaved;

  const TextFileView({super.key, required this.item, required this.text, required this.onSaved});

  /// Decodes [bytes] as text, or null if they aren't valid UTF-8.
  static String? decode(Uint8List bytes) {
    try {
      final start = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? 3 : 0;
      return utf8.decode(Uint8List.sublistView(bytes, start));
    } on FormatException {
      return null;
    }
  }

  @override
  State<TextFileView> createState() => _TextFileViewState();
}

class _TextFileViewState extends State<TextFileView> {
  late String _saved = widget.text;
  late final TextEditingController _edit = TextEditingController(text: widget.text);
  bool _editing = false;
  bool _saving = false;
  double _fontSize = 13;
  bool _wrap = true;

  bool get _dirty => _editing && _edit.text != _saved;

  late final UnlockProvider _unlock;
  late final VaultProvider _vault;

  @override
  void initState() {
    super.initState();
    _unlock = context.read<UnlockProvider>()..addBeforeLock(_saveOnLock);
    _vault = context.read<VaultProvider>();
  }

  /// The vault is locking with unsaved edits: write them while it can.
  void _saveOnLock() {
    if (_dirty && !_saving) {
      _vault.saveFileContent(widget.item, Uint8List.fromList(utf8.encode(_edit.text))).ignore();
    }
  }

  @override
  void dispose() {
    _unlock.removeBeforeLock(_saveOnLock);
    _edit.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    // What is saved is what was on screen when Save was pressed; typing
    // during the save isn't marked as saved.
    final text = _edit.text;
    setState(() => _saving = true);
    try {
      final item = await _vault.saveFileContent(
            widget.item,
            Uint8List.fromList(utf8.encode(text)),
          );
      if (!mounted) return;
      setState(() {
        _saved = text;
        _editing = _edit.text != text;
      });
      widget.onSaved(item);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved', style: AppFonts.ui(color: Colors.white)),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not save: $e', style: AppFonts.ui(color: Colors.white)),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Discard changes?'),
        content: Text('Your edits to this file have not been saved.',
            style: AppFonts.ui(color: Colors.white70, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Keep editing', style: AppFonts.ui(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Discard', style: AppFonts.ui(color: Ui.alert)),
          ),
        ],
      ),
    );
    return discard == true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) {
          setState(() {
            _edit.text = _saved;
            _editing = false;
          });
          Navigator.of(context).pop();
        }
      },
      child: Column(
        children: [
          _toolbar(),
          Expanded(child: _editing ? _editor() : _reader()),
        ],
      ),
    );
  }

  Widget _toolbar() {
    final lines = '\n'.allMatches(_editing ? _edit.text : _saved).length + 1;
    return Container(
      color: Ui.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: [
          Text('$lines lines', style: AppFonts.firaCode(fontSize: 11, color: Colors.white54)),
          const Spacer(),
          if (!_editing) ...[
            IconButton(
              tooltip: 'Smaller text',
              icon: const Icon(Icons.text_decrease_rounded, color: Colors.white70, size: 18),
              onPressed: () => setState(() => _fontSize = max(10, _fontSize - 1)),
            ),
            IconButton(
              tooltip: 'Larger text',
              icon: const Icon(Icons.text_increase_rounded, color: Colors.white70, size: 18),
              onPressed: () => setState(() => _fontSize = min(22, _fontSize + 1)),
            ),
            IconButton(
              tooltip: 'Wrap lines',
              icon: Icon(_wrap ? Icons.wrap_text_rounded : Icons.view_headline_rounded, color: Colors.white70, size: 18),
              onPressed: () => setState(() => _wrap = !_wrap),
            ),
            TextButton.icon(
              key: const Key('text-edit'),
              onPressed: () => setState(() => _editing = true),
              icon: const Icon(Icons.edit_rounded, size: 16, color: Ui.signal),
              label: Text('Edit', style: AppFonts.ui(color: Ui.signal, fontWeight: FontWeight.w500)),
            ),
          ] else ...[
            TextButton(
              onPressed: _saving
                  ? null
                  : () async {
                      if (!_dirty || await _confirmDiscard()) {
                        setState(() {
                          _edit.text = _saved;
                          _editing = false;
                        });
                      }
                    },
              child: Text('Cancel', style: AppFonts.ui(color: Colors.white54)),
            ),
            const SizedBox(width: 4),
            FilledButton(
              key: const Key('text-save'),
              style: FilledButton.styleFrom(
                backgroundColor: Ui.signal,
                foregroundColor: Ui.canvas,
              ),
              onPressed: _saving || !_dirty ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save', style: AppFonts.ui(fontWeight: FontWeight.w500)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _editor() {
    return Container(
      color: Ui.surface,
      padding: const EdgeInsets.all(12),
      child: TextField(
        key: const Key('text-editor'),
        controller: _edit,
        contextMenuBuilder: vaultContextMenu,
        autofocus: true,
        readOnly: _saving,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        // Keep vault text out of the keyboard's learned words and suggestions.
        enableIMEPersonalizedLearning: false,
        enableSuggestions: false,
        autocorrect: false,
        onChanged: (_) {
          context.read<UnlockProvider>().onUserActivity();
          setState(() {});
        },
        style: AppFonts.firaCode(fontSize: 13.5, color: Colors.white, height: 1.45),
        decoration: const InputDecoration(border: InputBorder.none, isCollapsed: true),
      ),
    );
  }

  Widget _reader() {
    final lines = _saved.split('\n');
    final body = ListView.builder(
      key: const Key('text-lines'),
      padding: const EdgeInsets.all(12),
      itemCount: lines.length,
      itemBuilder: (context, i) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 38,
            child: Text(
              '${i + 1}',
              textAlign: TextAlign.right,
              style: AppFonts.firaCode(fontSize: _fontSize - 2, color: Colors.white24),
            ),
          ),
          const SizedBox(width: 12),
          _wrap
              ? Expanded(child: _line(lines[i]))
              : _line(lines[i]),
        ],
      ),
    );
    return Container(
      color: Ui.surface,
      child: SelectionArea(
        child: _wrap
            ? body
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(width: max(800, MediaQuery.of(context).size.width * 2), child: body),
              ),
      ),
    );
  }

  Widget _line(String s) => Text(
        s,
        softWrap: _wrap,
        style: AppFonts.firaCode(fontSize: _fontSize, color: Colors.white.withValues(alpha: 0.9), height: 1.4),
      );
}
