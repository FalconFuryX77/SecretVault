import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/device_file_service.dart';

/// Provider managing active browsing state for the native Android Files app.
class DeviceFilesProvider extends ChangeNotifier {
  final DeviceFileService _service;

  DeviceFilesProvider({DeviceFileService? service})
      : _service = service ?? DeviceFileService();

  Directory? _currentDirectory;
  Directory? get currentDirectory => _currentDirectory;

  final List<Directory> _directoryHistory = [];
  bool get canNavigateUp => _directoryHistory.isNotEmpty;

  List<FileSystemEntity> _currentEntities = [];
  List<FileSystemEntity> get currentEntities => _currentEntities;

  DeviceFileCategory? _selectedCategory;
  DeviceFileCategory? get selectedCategory => _selectedCategory;

  List<File> _categoryFiles = [];
  List<File> get categoryFiles => _categoryFiles;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  bool _isSearching = false;
  bool get isSearching => _isSearching;

  String _searchQuery = '';
  String get searchQuery => _searchQuery;

  List<File> _searchResults = [];
  List<File> get searchResults => _searchResults;

  FileSortBy _sortBy = FileSortBy.nameAsc;
  FileSortBy get sortBy => _sortBy;

  bool _isGridView = false;
  bool get isGridView => _isGridView;

  bool _hasPermission = false;
  bool get hasPermission => _hasPermission;

  Map<String, Directory> _standardDirs = {};
  Map<String, Directory> get standardDirs => _standardDirs;

  Map<DeviceFileCategory, int> _categoryCounts = {};
  Map<DeviceFileCategory, int> get categoryCounts => _categoryCounts;

  Future<void> init() async {
    _isLoading = true;
    notifyListeners();

    await requestPermissions();
    _standardDirs = await _service.getStandardDirectories();

    final root = await _service.getDefaultRootDirectory();
    _currentDirectory = root;
    _directoryHistory.clear();

    await _loadCurrentDirectory();
    _refreshCategoryCounts();

    _isLoading = false;
    notifyListeners();
  }

  Future<void> requestPermissions() async {
    if (Platform.isAndroid) {
      // For Android 13+ (API 33+)
      final photos = await Permission.photos.request();
      final videos = await Permission.videos.request();
      final audio = await Permission.audio.request();
      final storage = await Permission.storage.request();
      final manageStorage = await Permission.manageExternalStorage.request();

      _hasPermission = photos.isGranted ||
          videos.isGranted ||
          audio.isGranted ||
          storage.isGranted ||
          manageStorage.isGranted;
    } else {
      _hasPermission = true;
    }
    notifyListeners();
  }

  Future<void> openDirectory(Directory dir) async {
    if (_currentDirectory != null) {
      _directoryHistory.add(_currentDirectory!);
    }
    _currentDirectory = dir;
    _selectedCategory = null;
    _isSearching = false;
    _searchQuery = '';

    await _loadCurrentDirectory();
  }

  Future<bool> navigateUp() async {
    if (_directoryHistory.isEmpty) return false;

    _currentDirectory = _directoryHistory.removeLast();
    _selectedCategory = null;
    _isSearching = false;
    _searchQuery = '';

    await _loadCurrentDirectory();
    return true;
  }

  Future<void> openCategory(DeviceFileCategory category) async {
    _selectedCategory = category;
    _isSearching = false;
    _searchQuery = '';
    _isLoading = true;
    notifyListeners();

    _categoryFiles = await _service.getFilesByCategory(category);
    _isLoading = false;
    notifyListeners();
  }

  void clearCategory() {
    _selectedCategory = null;
    _categoryFiles = [];
    notifyListeners();
  }

  Future<void> setSearchQuery(String query) async {
    _searchQuery = query;
    if (query.trim().isEmpty) {
      _isSearching = false;
      _searchResults = [];
      notifyListeners();
      return;
    }

    _isSearching = true;
    _isLoading = true;
    notifyListeners();

    _searchResults = await _service.searchFiles(
      query,
      rootDir: _currentDirectory,
    );

    _isLoading = false;
    notifyListeners();
  }

  void clearSearch() {
    _isSearching = false;
    _searchQuery = '';
    _searchResults = [];
    notifyListeners();
  }

  void setSortBy(FileSortBy sort) {
    _sortBy = sort;
    if (_selectedCategory != null) {
      openCategory(_selectedCategory!);
    } else if (_currentDirectory != null) {
      _loadCurrentDirectory();
    }
  }

  void toggleViewMode() {
    _isGridView = !_isGridView;
    notifyListeners();
  }

  Future<void> _loadCurrentDirectory() async {
    if (_currentDirectory == null) return;
    _isLoading = true;
    notifyListeners();

    _currentEntities = await _service.listDirectory(
      _currentDirectory!,
      sortBy: _sortBy,
    );

    _isLoading = false;
    notifyListeners();
  }

  Future<void> refresh() async {
    if (_selectedCategory != null) {
      await openCategory(_selectedCategory!);
    } else {
      await _loadCurrentDirectory();
    }
    _refreshCategoryCounts();
  }

  Future<void> _refreshCategoryCounts() async {
    try {
      final img = await _service.getFilesByCategory(DeviceFileCategory.images, maxResults: 100);
      final doc = await _service.getFilesByCategory(DeviceFileCategory.documents, maxResults: 100);
      final aud = await _service.getFilesByCategory(DeviceFileCategory.audio, maxResults: 100);
      final vid = await _service.getFilesByCategory(DeviceFileCategory.videos, maxResults: 100);
      final arc = await _service.getFilesByCategory(DeviceFileCategory.archives, maxResults: 100);
      final dwn = await _service.getFilesByCategory(DeviceFileCategory.downloads, maxResults: 100);

      _categoryCounts = {
        DeviceFileCategory.downloads: dwn.length,
        DeviceFileCategory.images: img.length,
        DeviceFileCategory.documents: doc.length,
        DeviceFileCategory.audio: aud.length,
        DeviceFileCategory.videos: vid.length,
        DeviceFileCategory.archives: arc.length,
      };
      notifyListeners();
    } catch (_) {}
  }

  Future<bool> deleteEntity(FileSystemEntity entity) async {
    final success = await _service.deleteEntity(entity);
    if (success) {
      await refresh();
    }
    return success;
  }

  Future<bool> renameEntity(FileSystemEntity entity, String newName) async {
    final res = await _service.renameEntity(entity, newName);
    if (res != null) {
      await refresh();
      return true;
    }
    return false;
  }

  Future<bool> createFolder(String folderName) async {
    if (_currentDirectory == null) return false;
    final res = await _service.createFolder(_currentDirectory!, folderName);
    if (res != null) {
      await refresh();
      return true;
    }
    return false;
  }

  Future<bool> createTextFile(String fileName, String content) async {
    if (_currentDirectory == null) return false;
    final res = await _service.createTextFile(_currentDirectory!, fileName, content);
    if (res != null) {
      await refresh();
      return true;
    }
    return false;
  }
}
