import 'dart:async';
import 'package:flutter/material.dart';
import '../services/vault_clipboard.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/vault_item.dart';
import '../providers/unlock_provider.dart';
import '../providers/vault_provider.dart';
import '../theme/ui.dart';

/// Encrypted Note & Crypto Seed Editor.
class NoteEditorScreen extends StatefulWidget {
  final VaultItem? existingItem;
  final VaultCategory category;

  const NoteEditorScreen({
    super.key,
    this.existingItem,
    this.category = VaultCategory.note,
  });

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late TextEditingController _titleController;
  late TextEditingController _contentController;
  Timer? _autoSaveTimer;

  /// Fixed for the editor's lifetime, so autosaves of a *new* note update
  /// one note instead of creating a fresh copy on every pause in typing.
  late final String _noteId;

  @override
  void initState() {
    super.initState();
    _noteId = widget.existingItem?.id ?? const Uuid().v4();
    _titleController = TextEditingController(
      text: widget.existingItem?.title ?? '',
    );
    _contentController = TextEditingController(
      text: widget.existingItem?.content ?? '',
    );
    _unlock = context.read<UnlockProvider>()..addBeforeLock(_flush);
  }

  late final UnlockProvider _unlock;

  /// Saves pending typing now (system back, or the vault is locking).
  void _flush() {
    if (_autoSaveTimer?.isActive ?? false) {
      _autoSaveTimer!.cancel();
      _saveNote();
    }
  }

  @override
  void dispose() {
    _unlock.removeBeforeLock(_flush);
    _autoSaveTimer?.cancel();
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _onChanged() {
    // Typing is activity too: the inactivity auto-lock only sees taps, and
    // must not lock the vault in the middle of writing a note.
    context.read<UnlockProvider>().onUserActivity();
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 2), _saveNote);
  }

  Future<void> _saveNote() async {
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();

    if (title.isEmpty && content.isEmpty) return;
    if (!mounted) return;

    try {
      await context.read<VaultProvider>().saveNote(
        id: _noteId,
        title: title.isEmpty
            ? (widget.category == VaultCategory.keySecret
                  ? 'Secret Key Seed'
                  : 'Untitled Note')
            : title,
        content: content,
        category: widget.category,
      );
    } on StateError {
      // The vault locked (timeout / panic) before the autosave ran. The
      // keys are gone, so there is nothing to save to; drop it.
    }
  }

  Future<void> _saveAndPop() async {
    _autoSaveTimer?.cancel();
    await _saveNote();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isSeed = widget.category == VaultCategory.keySecret;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _flush();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded, size: 22),
            tooltip: 'Back',
            onPressed: _saveAndPop,
          ),
          title: Text(isSeed ? 'Recovery words' : 'Note'),
          actions: [
            IconButton(
              icon: const Icon(Icons.check_rounded, color: Ui.signal),
              tooltip: 'Save',
              onPressed: _saveAndPop,
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Ui.gutter, 4, Ui.gutter, 12),
            child: Column(
              children: [
                TextField(
                  enableIMEPersonalizedLearning: false, // keep vault text out of keyboard learning
                  contextMenuBuilder: vaultContextMenu,
                  controller: _titleController,
                  onChanged: (_) => _onChanged(),
                  style: Ui.title(),
                  decoration: InputDecoration(
                    hintText: isSeed ? 'Label (e.g. Ledger main)' : 'Title',
                    hintStyle: Ui.title(color: Ui.ink3),
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
                const Divider(),
                Expanded(
                  child: TextField(
                    enableIMEPersonalizedLearning: false, // keep vault text out of keyboard learning
                    contextMenuBuilder: vaultContextMenu,
                    controller: _contentController,
                    onChanged: (_) => _onChanged(),
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: isSeed ? Ui.data(size: 15, color: Ui.ink).copyWith(height: 1.7) : Ui.body(size: 17).copyWith(height: 1.5),
                    decoration: InputDecoration(
                      hintText: isSeed ? 'The 12 or 24 words, in order' : 'Write something',
                      hintStyle: Ui.body(size: 17, color: Ui.ink3),
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
