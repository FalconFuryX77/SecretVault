import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/app_fonts.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../providers/device_files_provider.dart';
import '../providers/unlock_provider.dart';
import '../services/device_file_service.dart';
import '../services/security_channel_service.dart';
import 'device_file_viewer_screen.dart';
import 'lock_screen.dart';
import 'setup_screen.dart';
import 'vault_home_screen.dart';

/// Full-featured Native Android Files App.
/// Serves as a real, working file manager for device storage while housing
/// the encrypted vault behind a covert trigger and a PIN.
class NormalFilesScreen extends StatefulWidget {
  const NormalFilesScreen({super.key});

  @override
  State<NormalFilesScreen> createState() => _NormalFilesScreenState();
}

class _NormalFilesScreenState extends State<NormalFilesScreen> {
  int _headerTapCount = 0;
  DateTime _lastHeaderTap = DateTime(0);
  final TextEditingController _searchController = TextEditingController();

  // Multi-select batch encryption state
  bool _isMultiSelect = false;
  final Set<FileSystemEntity> _selectedEntities = {};
  StreamSubscription? _unlockSub;

  @override
  void initState() {
    super.initState();
    SecurityChannelService.clearAll();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Permission prompts open system screens, which pause the app. Right
      // after setup the vault is open, and that pause must not lock it.
      final files = context.read<DeviceFilesProvider>();
      context.read<UnlockProvider>().withoutAutoLock(files.init);
    });

    _unlockSub = context.read<UnlockProvider>().onVaultUnlocked.listen((
      vaultType,
    ) {
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.popUntil((route) => route.isFirst);
      nav.push(
        MaterialPageRoute(
          builder: (_) => VaultHomeScreen(vaultType: vaultType),
        ),
      );
    });
  }

  @override
  void dispose() {
    _unlockSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _toggleSelection(FileSystemEntity entity) {
    setState(() {
      if (_selectedEntities.contains(entity)) {
        _selectedEntities.remove(entity);
        if (_selectedEntities.isEmpty) {
          _isMultiSelect = false;
        }
      } else {
        _selectedEntities.add(entity);
        _isMultiSelect = true;
      }
    });
  }

  void _selectAll(List<FileSystemEntity> entities) {
    setState(() {
      _selectedEntities.addAll(entities);
      _isMultiSelect = true;
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedEntities.clear();
      _isMultiSelect = false;
    });
  }

  Future<void> _deleteSelected() async {
    final targets = _selectedEntities.toList();
    if (targets.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: Text(
          'Delete ${targets.length} items?',
          style: AppFonts.outfit(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Color(0xFFFB7185)),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final provider = context.read<DeviceFilesProvider>();
    for (final e in targets) {
      await provider.deleteEntity(e);
    }
    _clearSelection();
    await provider.refresh();
  }

  void _onHeaderTap() {
    final now = DateTime.now();
    if (now.difference(_lastHeaderTap).inMilliseconds > 800) {
      _headerTapCount = 1;
    } else {
      _headerTapCount++;
    }
    _lastHeaderTap = now;

    // Triple tap on header opens vault portal
    if (_headerTapCount >= 3) {
      _headerTapCount = 0;
      _openVaultPortal();
    }
  }

  void _openVaultPortal() {
    final provider = context.read<UnlockProvider>();
    if (!provider.isSetupComplete) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SetupScreen()),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const LockScreen()),
      );
    }
  }

  void _showNewFolderDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'New Folder',
          style: AppFonts.outfit(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: AppFonts.outfit(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Folder name...',
            hintStyle: AppFonts.outfit(color: Colors.white38),
            filled: true,
            fillColor: const Color(0xFF21262D),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: AppFonts.outfit(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF58A6FF),
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                Navigator.pop(ctx);
                await context.read<DeviceFilesProvider>().createFolder(name);
              }
            },
            child: Text(
              'Create',
              style: AppFonts.outfit(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _showNewFileDialog() {
    final nameController = TextEditingController();
    final contentController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'New Text File',
          style: AppFonts.outfit(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              style: AppFonts.outfit(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'filename.txt',
                hintStyle: AppFonts.outfit(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF21262D),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: contentController,
              maxLines: 3,
              style: AppFonts.firaCode(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Content...',
                hintStyle: AppFonts.outfit(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF21262D),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: AppFonts.outfit(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF58A6FF),
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              var name = nameController.text.trim();
              if (name.isNotEmpty) {
                if (!name.contains('.')) name += '.txt';
                Navigator.pop(ctx);
                await context.read<DeviceFilesProvider>().createTextFile(
                  name,
                  contentController.text,
                );
              }
            },
            child: Text(
              'Create',
              style: AppFonts.outfit(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _handleEntityAction(String action, FileSystemEntity entity) async {
    final provider = context.read<DeviceFilesProvider>();
    final fileName = p.basename(entity.path);

    if (action == 'open') {
      if (entity is Directory) {
        provider.openDirectory(entity);
      } else if (entity is File) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => DeviceFileViewerScreen(file: entity),
          ),
        );
      }
    } else if (action == 'system_open' && entity is File) {
      await OpenFilex.open(entity.path);
    } else if (action == 'rename') {
      final controller = TextEditingController(text: fileName);
      final newName = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF161B22),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            'Rename',
            style: AppFonts.outfit(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: AppFonts.outfit(color: Colors.white),
            decoration: InputDecoration(
              filled: true,
              fillColor: const Color(0xFF21262D),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                'Cancel',
                style: AppFonts.outfit(color: Colors.white54),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF58A6FF),
              ),
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text(
                'Rename',
                style: AppFonts.outfit(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      );
      if (newName != null && newName.isNotEmpty && newName != fileName) {
        await provider.renameEntity(entity, newName);
      }
    } else if (action == 'delete') {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF161B22),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            'Delete File',
            style: AppFonts.outfit(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            'Permanently delete "$fileName" from storage?',
            style: AppFonts.outfit(color: Colors.white70, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(
                'Cancel',
                style: AppFonts.outfit(color: Colors.white54),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE11D48),
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                'Delete',
                style: AppFonts.outfit(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      );
      if (confirm == true) {
        await provider.deleteEntity(entity);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filesProvider = context.watch<DeviceFilesProvider>();

    return PopScope(
      canPop:
          !filesProvider.canNavigateUp &&
          filesProvider.selectedCategory == null &&
          !filesProvider.isSearching,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (filesProvider.isSearching) {
          filesProvider.clearSearch();
          _searchController.clear();
        } else if (filesProvider.selectedCategory != null) {
          filesProvider.clearCategory();
        } else if (filesProvider.canNavigateUp) {
          await filesProvider.navigateUp();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0D1117),
        appBar: _isMultiSelect
            ? AppBar(
                backgroundColor: const Color(0xFF161B22),
                elevation: 0,
                leading: IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                  onPressed: _clearSelection,
                ),
                title: Text(
                  '${_selectedEntities.length} Selected',
                  style: AppFonts.outfit(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      final all = filesProvider.selectedCategory != null
                          ? filesProvider.categoryFiles
                          : filesProvider.isSearching
                          ? filesProvider.searchResults
                          : filesProvider.currentEntities;
                      _selectAll(all);
                    },
                    child: Text(
                      'Select All',
                      style: AppFonts.outfit(color: const Color(0xFF58A6FF)),
                    ),
                  ),
                  if (_selectedEntities.isNotEmpty)
                    IconButton(
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        color: Color(0xFFFB7185),
                      ),
                      tooltip: 'Delete',
                      onPressed: _deleteSelected,
                    ),
                ],
              )
            : AppBar(
                backgroundColor: const Color(0xFF161B22),
                elevation: 0,
                leading:
                    filesProvider.canNavigateUp ||
                        filesProvider.selectedCategory != null ||
                        filesProvider.isSearching
                    ? IconButton(
                        icon: const Icon(
                          Icons.arrow_back_rounded,
                          color: Colors.white,
                        ),
                        onPressed: () {
                          if (filesProvider.isSearching) {
                            filesProvider.clearSearch();
                            _searchController.clear();
                          } else if (filesProvider.selectedCategory != null) {
                            filesProvider.clearCategory();
                          } else {
                            filesProvider.navigateUp();
                          }
                        },
                      )
                    : GestureDetector(
                        onTap: _onHeaderTap,
                        child: Container(
                          margin: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF21262D),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.folder_rounded,
                            color: Color(0xFF58A6FF),
                            size: 20,
                          ),
                        ),
                      ),
                title: GestureDetector(
                  onTap: _onHeaderTap,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        filesProvider.selectedCategory != null
                            ? _getCategoryTitle(filesProvider.selectedCategory!)
                            : 'Files',
                        style: AppFonts.outfit(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        filesProvider.currentDirectory != null && filesProvider.canNavigateUp
                            ? p.basename(filesProvider.currentDirectory!.path)
                            : 'Internal Storage',
                        style: AppFonts.outfit(
                          fontSize: 11,
                          color: Colors.white54,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                actions: [
                  IconButton(
                    icon: Icon(
                      filesProvider.isGridView
                          ? Icons.view_list_rounded
                          : Icons.grid_view_rounded,
                      color: Colors.white70,
                    ),
                    tooltip: filesProvider.isGridView
                        ? 'List View'
                        : 'Grid View',
                    onPressed: () => filesProvider.toggleViewMode(),
                  ),
                  PopupMenuButton<FileSortBy>(
                    icon: const Icon(Icons.sort_rounded, color: Colors.white70),
                    tooltip: 'Sort by',
                    color: const Color(0xFF21262D),
                    onSelected: (sort) => filesProvider.setSortBy(sort),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: FileSortBy.nameAsc,
                        child: Text(
                          'Name (A to Z)',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const PopupMenuItem(
                        value: FileSortBy.nameDesc,
                        child: Text(
                          'Name (Z to A)',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const PopupMenuItem(
                        value: FileSortBy.dateDesc,
                        child: Text(
                          'Date (Newest)',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const PopupMenuItem(
                        value: FileSortBy.dateAsc,
                        child: Text(
                          'Date (Oldest)',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const PopupMenuItem(
                        value: FileSortBy.sizeDesc,
                        child: Text(
                          'Size (Largest)',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const PopupMenuItem(
                        value: FileSortBy.sizeAsc,
                        child: Text(
                          'Size (Smallest)',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
        body: RefreshIndicator(
          color: const Color(0xFF58A6FF),
          backgroundColor: const Color(0xFF161B22),
          onRefresh: () => filesProvider.refresh(),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              // Search Bar
              TextField(
                controller: _searchController,
                onChanged: (q) => filesProvider.setSearchQuery(q),
                style: AppFonts.outfit(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search files and folders...',
                  hintStyle: AppFonts.outfit(
                    color: Colors.white38,
                    fontSize: 13,
                  ),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    color: Colors.white38,
                    size: 20,
                  ),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(
                            Icons.clear_rounded,
                            color: Colors.white38,
                            size: 18,
                          ),
                          onPressed: () {
                            _searchController.clear();
                            filesProvider.clearSearch();
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: const Color(0xFF161B22),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),

              const SizedBox(height: 14),

              // Categories Grid (when not inside subfolder and not searching)
              if (!filesProvider.canNavigateUp &&
                  filesProvider.selectedCategory == null &&
                  !filesProvider.isSearching) ...[
                // Storage Overview Card
                _buildStorageOverviewCard(filesProvider.storage),
                const SizedBox(height: 16),

                Text(
                  'Categories',
                  style: AppFonts.outfit(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 10),

                _buildCategoryGrid(filesProvider),
                const SizedBox(height: 18),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Folders & Files',
                      style: AppFonts.outfit(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.create_new_folder_outlined,
                            color: Color(0xFF58A6FF),
                            size: 20,
                          ),
                          tooltip: 'New Folder',
                          onPressed: _showNewFolderDialog,
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.note_add_outlined,
                            color: Color(0xFF58A6FF),
                            size: 20,
                          ),
                          tooltip: 'New Text File',
                          onPressed: _showNewFileDialog,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],

              // Searching results view
              if (filesProvider.isSearching) ...[
                Text(
                  'Search Results (${filesProvider.searchResults.length})',
                  style: AppFonts.outfit(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 10),
                if (filesProvider.isLoading)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(
                        color: Color(0xFF58A6FF),
                      ),
                    ),
                  )
                else if (filesProvider.searchResults.isEmpty)
                  _buildEmptyState(
                    'No files matching "${filesProvider.searchQuery}"',
                  )
                else
                  _buildFilesList(
                    filesProvider.searchResults,
                    filesProvider.isGridView,
                  ),
              ]
              // Category files view
              else if (filesProvider.selectedCategory != null) ...[
                if (filesProvider.isLoading)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(
                        color: Color(0xFF58A6FF),
                      ),
                    ),
                  )
                else if (filesProvider.categoryFiles.isEmpty)
                  _buildEmptyState(
                    'No files found in ${_getCategoryTitle(filesProvider.selectedCategory!)}',
                  )
                else
                  _buildFilesList(
                    filesProvider.categoryFiles,
                    filesProvider.isGridView,
                  ),
              ]
              // Standard Directory Browsing
              else ...[
                if (filesProvider.canNavigateUp) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              const Icon(
                                Icons.folder_open_rounded,
                                color: Color(0xFF58A6FF),
                                size: 18,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                filesProvider.currentDirectory?.path ?? '',
                                style: AppFonts.firaCode(
                                  fontSize: 12,
                                  color: Colors.white70,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.create_new_folder_outlined,
                          color: Color(0xFF58A6FF),
                          size: 20,
                        ),
                        tooltip: 'New Folder',
                        onPressed: _showNewFolderDialog,
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.note_add_outlined,
                          color: Color(0xFF58A6FF),
                          size: 20,
                        ),
                        tooltip: 'New Text File',
                        onPressed: _showNewFileDialog,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],

                if (filesProvider.isLoading)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(
                        color: Color(0xFF58A6FF),
                      ),
                    ),
                  )
                else if (filesProvider.currentEntities.isEmpty)
                  _buildEmptyState('This folder is empty.')
                else
                  _buildEntitiesList(
                    filesProvider.currentEntities,
                    filesProvider.isGridView,
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStorageOverviewCard(StorageSpaceInfo? storage) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1F2937), Color(0xFF111827)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Internal Storage',
                style: AppFonts.outfit(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const Icon(
                Icons.storage_rounded,
                color: Color(0xFF58A6FF),
                size: 18,
              ),
            ],
          ),
          // Real figures from the system, or nothing: never invented ones.
          if (storage != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: storage.usedFraction,
                minHeight: 8,
                backgroundColor: const Color(0xFF21262D),
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF58A6FF)),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${storage.usedLabel} used',
                  style: AppFonts.outfit(fontSize: 12, color: Colors.white70),
                ),
                Text(
                  '${storage.totalLabel} total',
                  style: AppFonts.outfit(fontSize: 12, color: Colors.white38),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _withThousands(int n) {
    final digits = n.toString();
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }

  Widget _buildCategoryGrid(DeviceFilesProvider provider) {
    final categories = [
      (
        DeviceFileCategory.downloads,
        'Downloads',
        Icons.download_rounded,
        const Color(0xFF38BDF8),
      ),
      (
        DeviceFileCategory.images,
        'Images',
        Icons.image_rounded,
        const Color(0xFFF472B6),
      ),
      (
        DeviceFileCategory.documents,
        'Documents',
        Icons.description_rounded,
        const Color(0xFF34D399),
      ),
      (
        DeviceFileCategory.audio,
        'Audio',
        Icons.audiotrack_rounded,
        const Color(0xFFA78BFA),
      ),
      (
        DeviceFileCategory.videos,
        'Videos',
        Icons.movie_rounded,
        const Color(0xFFFBBF24),
      ),
      (
        DeviceFileCategory.archives,
        'Archives',
        Icons.folder_zip_rounded,
        const Color(0xFFFB7185),
      ),
    ];

    return GridView.builder(
      padding: EdgeInsets.zero,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 2.2,
      ),
      itemCount: categories.length,
      itemBuilder: (context, index) {
        final (cat, title, icon, color) = categories[index];
        // Null until the first count finishes: show nothing, not a made-up 0.
        final count = provider.categoryCounts[cat];

        return InkWell(
          onTap: () => provider.openCategory(cat),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        style: AppFonts.outfit(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        count == null ? '' : (count == 1 ? '1 file' : '${_withThousands(count)} files'),
                        style: AppFonts.outfit(
                          fontSize: 11,
                          color: Colors.white54,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildEntitiesList(List<FileSystemEntity> entities, bool isGrid) {
    if (isGrid) {
      return GridView.builder(
        padding: EdgeInsets.zero,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.2,
        ),
        itemCount: entities.length,
        itemBuilder: (context, index) => _buildEntityGridTile(entities[index]),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: entities.length,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _buildEntityListTile(entities[index]),
    );
  }

  Widget _buildFilesList(List<File> files, bool isGrid) {
    return _buildEntitiesList(files, isGrid);
  }

  Widget _buildEntityListTile(FileSystemEntity entity) {
    final isDir = entity is Directory;
    final name = p.basename(entity.path);
    final (icon, color) = _getEntityIconAndColor(entity);
    final isSelected = _selectedEntities.contains(entity);

    String subtitle = 'Folder';
    if (isDir) {
      try {
        final count = DeviceFileService.getChildCount(entity);
        final stat = entity.statSync();
        subtitle =
            '$count ${count == 1 ? 'item' : 'items'} • ${stat.modified.day.toString().padLeft(2, '0')}/${stat.modified.month.toString().padLeft(2, '0')}/${stat.modified.year}';
      } catch (_) {
        subtitle = 'Folder';
      }
    } else if (entity is File) {
      try {
        final stat = entity.statSync();
        subtitle =
            '${DeviceFileService.formatBytes(stat.size)} • ${stat.modified.day.toString().padLeft(2, '0')}/${stat.modified.month.toString().padLeft(2, '0')}/${stat.modified.year}';
      } catch (_) {
        subtitle = 'File';
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFF1E1B4B) : const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSelected
              ? const Color(0xFFA78BFA)
              : Colors.white.withValues(alpha: 0.05),
          width: isSelected ? 1.5 : 1.0,
        ),
      ),
      child: ListTile(
        onTap: _isMultiSelect
            ? () => _toggleSelection(entity)
            : () => _handleEntityAction('open', entity),
        onLongPress: () => _toggleSelection(entity),
        leading: _isMultiSelect
            ? Checkbox(
                value: isSelected,
                activeColor: const Color(0xFFA78BFA),
                checkColor: const Color(0xFF090D16),
                onChanged: (_) => _toggleSelection(entity),
              )
            : Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
        title: Text(
          name,
          style: AppFonts.outfit(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isSelected ? const Color(0xFFA78BFA) : Colors.white,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          subtitle,
          style: AppFonts.outfit(fontSize: 11, color: Colors.white54),
        ),
        trailing: _isMultiSelect
            ? null
            : PopupMenuButton<String>(
                icon: const Icon(
                  Icons.more_vert_rounded,
                  color: Colors.white38,
                  size: 18,
                ),
                color: const Color(0xFF21262D),
                onSelected: (act) => _handleEntityAction(act, entity),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'open',
                    child: Text('Open', style: TextStyle(color: Colors.white)),
                  ),
                  if (!isDir)
                    const PopupMenuItem(
                      value: 'system_open',
                      child: Text(
                        'Open with App',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  const PopupMenuItem(
                    value: 'rename',
                    child: Text(
                      'Rename',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      'Delete',
                      style: TextStyle(color: Color(0xFFFB7185)),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildEntityGridTile(FileSystemEntity entity) {
    final isDir = entity is Directory;
    final name = p.basename(entity.path);
    final (icon, color) = _getEntityIconAndColor(entity);
    final isSelected = _selectedEntities.contains(entity);

    return InkWell(
      onTap: _isMultiSelect
          ? () => _toggleSelection(entity)
          : () => _handleEntityAction('open', entity),
      onLongPress: () => _toggleSelection(entity),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF1E1B4B) : const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected
                ? const Color(0xFFA78BFA)
                : Colors.white.withValues(alpha: 0.06),
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _isMultiSelect
                    ? Icon(
                        isSelected
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: isSelected
                            ? const Color(0xFFA78BFA)
                            : Colors.white38,
                        size: 22,
                      )
                    : Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(icon, color: color, size: 20),
                      ),
                if (!_isMultiSelect)
                  PopupMenuButton<String>(
                    icon: const Icon(
                      Icons.more_vert_rounded,
                      color: Colors.white38,
                      size: 16,
                    ),
                    color: const Color(0xFF21262D),
                    onSelected: (act) => _handleEntityAction(act, entity),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'open',
                        child: Text(
                          'Open',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'rename',
                        child: Text(
                          'Rename',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text(
                          'Delete',
                          style: TextStyle(color: Color(0xFFFB7185)),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            Text(
              name,
              style: AppFonts.outfit(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isSelected ? const Color(0xFFA78BFA) : Colors.white,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              isDir
                  ? '${DeviceFileService.getChildCount(entity)} items'
                  : (entity is File
                        ? DeviceFileService.formatBytes(entity.lengthSync())
                        : ''),
              style: AppFonts.outfit(fontSize: 10, color: Colors.white54),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  (IconData, Color) _getEntityIconAndColor(FileSystemEntity entity) {
    if (entity is Directory) {
      return (Icons.folder_rounded, const Color(0xFF58A6FF));
    }

    final ext = p.extension(entity.path).replaceAll('.', '').toLowerCase();
    if (DeviceFileService.imageExtensions.contains(ext)) {
      return (Icons.image_rounded, const Color(0xFFF472B6));
    } else if (DeviceFileService.videoExtensions.contains(ext)) {
      return (Icons.movie_rounded, const Color(0xFFFBBF24));
    } else if (DeviceFileService.audioExtensions.contains(ext)) {
      return (Icons.audiotrack_rounded, const Color(0xFFA78BFA));
    } else if (DeviceFileService.documentExtensions.contains(ext)) {
      return (Icons.description_rounded, const Color(0xFF34D399));
    } else if (DeviceFileService.archiveExtensions.contains(ext)) {
      return (Icons.folder_zip_rounded, const Color(0xFFFB7185));
    }
    return (Icons.insert_drive_file_rounded, const Color(0xFF94A3B8));
  }

  String _getCategoryTitle(DeviceFileCategory cat) {
    switch (cat) {
      case DeviceFileCategory.downloads:
        return 'Downloads';
      case DeviceFileCategory.images:
        return 'Images';
      case DeviceFileCategory.documents:
        return 'Documents';
      case DeviceFileCategory.audio:
        return 'Audio';
      case DeviceFileCategory.videos:
        return 'Videos';
      case DeviceFileCategory.archives:
        return 'Archives';
      case DeviceFileCategory.all:
        return 'All Files';
    }
  }

  Widget _buildEmptyState(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Column(
          children: [
            Icon(
              Icons.folder_open_rounded,
              size: 48,
              color: Colors.white.withValues(alpha: 0.2),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: AppFonts.outfit(fontSize: 14, color: Colors.white54),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
