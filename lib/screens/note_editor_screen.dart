import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_fonts.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/vault_item.dart';
import '../providers/unlock_provider.dart';
import '../providers/vault_provider.dart';

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
  }

  @override
  void dispose() {
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

    return Scaffold(
      backgroundColor: const Color(0xFF090D16),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: Colors.white70,
            size: 18,
          ),
          onPressed: _saveAndPop,
        ),
        title: Row(
          children: [
            Icon(
              isSeed ? Icons.key_rounded : Icons.description_rounded,
              color: isSeed ? const Color(0xFF38BDF8) : const Color(0xFFA78BFA),
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              isSeed ? 'Crypto Seed' : 'Encrypted Note',
              style: AppFonts.outfit(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.check_rounded, color: Color(0xFF34D399)),
            onPressed: _saveAndPop,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            children: [
              TextField(
                enableIMEPersonalizedLearning: false, // keep vault text out of keyboard learning
                controller: _titleController,
                onChanged: (_) => _onChanged(),
                style: AppFonts.outfit(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                decoration: InputDecoration(
                  hintText: isSeed
                      ? 'Wallet / Key Label (e.g. Ledger Main)'
                      : 'Note Title...',
                  hintStyle: AppFonts.outfit(
                    fontSize: 22,
                    color: Colors.white30,
                    fontWeight: FontWeight.bold,
                  ),
                  border: InputBorder.none,
                ),
              ),
              const Divider(color: Colors.white12, height: 24),
              Expanded(
                child: TextField(
                  enableIMEPersonalizedLearning: false, // keep vault text out of keyboard learning
                  controller: _contentController,
                  onChanged: (_) => _onChanged(),
                  maxLines: null,
                  expands: true,
                  style: AppFonts.firaCode(
                    fontSize: 14,
                    color: Colors.white.withValues(alpha: 0.85),
                    height: 1.6,
                  ),
                  decoration: InputDecoration(
                    hintText: isSeed
                        ? 'Enter 12/24 recovery words (e.g. abandon ability able about...)'
                        : 'Type confidential note here...',
                    hintStyle: AppFonts.outfit(
                      fontSize: 14,
                      color: Colors.white24,
                    ),
                    border: InputBorder.none,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
