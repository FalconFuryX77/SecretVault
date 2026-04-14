import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/note.dart';
import '../services/database_service.dart';

enum SortMode { updatedAt, createdAtAsc, createdAtDesc }

class NotesProvider extends ChangeNotifier {
  final DatabaseService _db = DatabaseService();
  final Uuid _uuid = const Uuid();

  List<Note> _notes = [];
  List<Note> get notes => _filteredNotes;

  String _searchQuery = '';
  String get searchQuery => _searchQuery;

  SortMode _sortMode = SortMode.updatedAt;
  SortMode get sortMode => _sortMode;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  List<Note> get _filteredNotes {
    if (_searchQuery.isEmpty) return _notes;
    final q = _searchQuery.toLowerCase();
    return _notes
        .where((n) =>
            n.title.toLowerCase().contains(q) ||
            n.content.toLowerCase().contains(q))
        .toList();
  }

  /// Load all notes from SQLite.
  Future<void> loadNotes() async {
    _isLoading = true;
    notifyListeners();

    switch (_sortMode) {
      case SortMode.updatedAt:
        _notes = await _db.getAllNotes();
        break;
      case SortMode.createdAtAsc:
        _notes = await _db.getNotesByCreationDate(ascending: true);
        break;
      case SortMode.createdAtDesc:
        _notes = await _db.getNotesByCreationDate(ascending: false);
        break;
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Create a new note and return it.
  Future<Note> createNote() async {
    final now = DateTime.now();
    final note = Note(
      id: _uuid.v4(),
      title: '',
      content: '',
      createdAt: now,
      updatedAt: now,
    );
    await _db.insertNote(note);
    await loadNotes();
    return note;
  }

  /// Save/update an existing note.
  Future<void> saveNote(Note note) async {
    final updated = note.copyWith(updatedAt: DateTime.now());
    await _db.updateNote(updated);
    await loadNotes();
  }

  /// Delete a note.
  Future<void> deleteNote(String id) async {
    await _db.deleteNote(id);
    await loadNotes();
  }

  /// Toggle pin state.
  Future<void> togglePin(Note note) async {
    await _db.togglePin(note.id, !note.isPinned);
    await loadNotes();
  }

  /// Set search query.
  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  /// Set sort mode and reload.
  Future<void> setSortMode(SortMode mode) async {
    _sortMode = mode;
    await loadNotes();
  }

  /// Clear state on lock.
  void clear() {
    _notes = [];
    _searchQuery = '';
    notifyListeners();
  }
}
