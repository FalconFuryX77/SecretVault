import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/note.dart';
import '../providers/notes_provider.dart';
import '../services/database_service.dart';

class NoteEditorScreen extends StatefulWidget {
  final String noteId;

  const NoteEditorScreen({super.key, required this.noteId});

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _db = DatabaseService();

  Note? _note;
  bool _isLoading = true;
  Timer? _saveTimer;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _loadNote();
  }

  Future<void> _loadNote() async {
    final note = await _db.getNote(widget.noteId);
    if (note != null && mounted) {
      setState(() {
        _note = note;
        _titleController.text = note.title;
        _contentController.text = note.content;
        _isLoading = false;
      });
    }
  }

  void _onChanged() {
    _hasChanges = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _autoSave);
  }

  Future<void> _autoSave() async {
    if (!_hasChanges || _note == null) return;
    _note = _note!.copyWith(
      title: _titleController.text,
      content: _contentController.text,
      updatedAt: DateTime.now(),
    );
    await _db.updateNote(_note!);
    _hasChanges = false;
  }

  Future<void> _saveAndPop() async {
    _saveTimer?.cancel();
    if (_note != null) {
      _note = _note!.copyWith(
        title: _titleController.text,
        content: _contentController.text,
        updatedAt: DateTime.now(),
      );
      await _db.updateNote(_note!);
    }
    if (mounted) {
      context.read<NotesProvider>().loadNotes();
      Navigator.of(context).pop();
    }
  }

  Future<void> _deleteNote() async {
    if (_note == null) return;
    await context.read<NotesProvider>().deleteNote(_note!.id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _togglePin() async {
    if (_note == null) return;
    await context.read<NotesProvider>().togglePin(_note!);
    setState(() {
      _note = _note!.copyWith(isPinned: !_note!.isPinned);
    });
  }

  int get _wordCount {
    final text = _contentController.text.trim();
    if (text.isEmpty) return 0;
    return text.split(RegExp(r'\s+')).length;
  }

  int get _charCount => _contentController.text.length;

  @override
  void dispose() {
    _saveTimer?.cancel();
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF0F0C29),
                Color(0xFF1A1744),
                Color(0xFF24243E),
              ],
            ),
          ),
          child: const Center(
            child: CircularProgressIndicator(color: Color(0xFFA78BFA)),
          ),
        ),
      );
    }

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0F0C29), Color(0xFF1A1744), Color(0xFF24243E)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // App bar
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.white,
                      ),
                      onPressed: _saveAndPop,
                    ),
                    const Spacer(),
                    if (_note?.isPinned == true)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Icon(
                          Icons.push_pin_rounded,
                          size: 18,
                          color: const Color(0xFFFBBF24).withValues(alpha: 0.7),
                        ),
                      ),
                    PopupMenuButton<String>(
                      icon: Icon(
                        Icons.more_vert_rounded,
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                      color: const Color(0xFF1A1744),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.1),
                        ),
                      ),
                      onSelected: (val) {
                        if (val == 'pin') _togglePin();
                        if (val == 'delete') _confirmDelete();
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'pin',
                          child: Row(
                            children: [
                              Icon(
                                _note?.isPinned == true
                                    ? Icons.push_pin_outlined
                                    : Icons.push_pin_rounded,
                                size: 18,
                                color: Colors.white.withValues(alpha: 0.6),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                _note?.isPinned == true ? 'Unpin' : 'Pin Note',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.8),
                                ),
                              ),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(
                                Icons.delete_rounded,
                                size: 18,
                                color: const Color(0xFFF87171)
                                    .withValues(alpha: 0.8),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                'Delete',
                                style: TextStyle(
                                  color: const Color(0xFFF87171)
                                      .withValues(alpha: 0.8),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Title field
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: TextField(
                  controller: _titleController,
                  style: GoogleFonts.outfit(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Note Title',
                    hintStyle: GoogleFonts.outfit(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: Colors.white.withValues(alpha: 0.15),
                    ),
                    border: InputBorder.none,
                  ),
                  maxLines: 1,
                  onChanged: (_) => _onChanged(),
                ),
              ),

              // Content field
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
                  child: TextField(
                    controller: _contentController,
                    style: TextStyle(
                      fontSize: 15,
                      color: Colors.white.withValues(alpha: 0.75),
                      height: 1.7,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Start writing...',
                      hintStyle: TextStyle(
                        color: Colors.white.withValues(alpha: 0.15),
                        fontSize: 15,
                      ),
                      border: InputBorder.none,
                    ),
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    onChanged: (_) => _onChanged(),
                  ),
                ),
              ),

              // Bottom bar — word/char count
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: Colors.white.withValues(alpha: 0.06),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      '$_wordCount words',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.25),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      '$_charCount characters',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.25),
                      ),
                    ),
                    const Spacer(),
                    if (_hasChanges)
                      Text(
                        'Auto-saving...',
                        style: TextStyle(
                          fontSize: 12,
                          color: const Color(0xFFFBBF24)
                              .withValues(alpha: 0.5),
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDelete() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1744),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        title: Text(
          'Delete Note',
          style: GoogleFonts.outfit(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          'This action cannot be undone.',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF87171),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _deleteNote();
            },
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
