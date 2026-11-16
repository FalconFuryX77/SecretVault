import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../navigation/vault_routes.dart';
import '../services/vault_service.dart';
import '../theme/app_fonts.dart';
import '../viewers/file_kind.dart';
import 'export_dialog.dart';
import 'camera_screen.dart';
import 'recorder_screen.dart';
import 'package:provider/provider.dart';
import '../models/vault_state.dart';
import '../models/vault_item.dart';
import '../providers/unlock_provider.dart';
import '../providers/vault_provider.dart';
import '../util/format.dart';
import 'file_viewer_screen.dart';
import 'note_editor_screen.dart';
import 'settings_screen.dart';

/// SecretVault Unlocked File Safe Dashboard Screen.
/// Provides a native Android file safe experience (Documents, Media, Audio, Archives, Notes).
class VaultHomeScreen extends StatefulWidget {
  final VaultType vaultType;

  const VaultHomeScreen({super.key, required this.vaultType});

  @override
  State<VaultHomeScreen> createState() => _VaultHomeScreenState();
}

class _VaultHomeScreenState extends State<VaultHomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _isGridView = false;
  StreamSubscription? _panicSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<VaultProvider>().loadVault(widget.vaultType);
      _warnIfRolledBack();
    });
  }

  /// The container is older than the last version this phone saved: an
  /// earlier copy of it was put back (see RollbackGuard).
  void _warnIfRolledBack() {
    final session = context.read<VaultService>().session;
    if (session == null || !session.rolledBack) return;
    session.rolledBack = false;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: Text('This vault was rolled back',
            style: AppFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Text(
          'The vault file is older than the last version this phone saved. Someone may have put back '
          'an earlier copy of it, which would undo recent changes (new files, deletions, a PIN change). '
          'Check that nothing is missing, and that files you deleted are gone.',
          key: const Key('rollback-warning'),
          style: AppFonts.outfit(fontSize: 13, color: Colors.white70),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _panicSub?.cancel();
    super.dispose();
  }

  // Vault screens are removed at once, not animated out: the exit animation
  // would draw the vault for a few hundred milliseconds after the lock, with
  // screenshot protection already being lifted.
  void _lockAndExit() {
    context.read<VaultProvider>().clearVaultSession();
    context.read<UnlockProvider>().lockVault();
    vaultRoutes.removeAllAboveFirst();
  }

  void _triggerPanicLock() {
    context.read<VaultProvider>().clearVaultSession();
    context.read<UnlockProvider>().triggerPanicLock();
    vaultRoutes.removeAllAboveFirst();
  }

  void _showImportOptions() {
    showModalBottomSheet(
      context: context,
      // A plain sheet is capped at 9/16 of the screen, which cut off the
      // last option on smaller phones; let it size to its content and
      // scroll if the screen is shorter still.
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Add File to Encrypted Safe',
                style: AppFonts.outfit(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              _buildModalTile(
                icon: Icons.description_rounded,
                color: const Color(0xFF38BDF8),
                title: 'Import Document',
                subtitle: 'Encrypt PDFs, Word, Excel, text files',
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndImportFile(FileType.custom, [
                    'pdf',
                    'doc',
                    'docx',
                    'txt',
                    'csv',
                    'xlsx',
                    'pptx',
                  ], VaultCategory.document);
                },
              ),
              _buildModalTile(
                icon: Icons.photo_library_rounded,
                color: const Color(0xFFF472B6),
                title: 'Import Photos & Videos',
                subtitle: 'Encrypt personal photos and media gallery items',
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndImportFile(FileType.media, null, VaultCategory.image);
                },
              ),
              _buildModalTile(
                icon: Icons.folder_zip_rounded,
                color: const Color(0xFFFBBF24),
                title: 'Import Archive / Any File',
                subtitle: 'Encrypt ZIPs, APKs, or binary backups',
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndImportFile(
                    FileType.any,
                    null,
                    VaultCategory.document,
                  );
                },
              ),
              _buildModalTile(
                icon: Icons.photo_camera_rounded,
                color: const Color(0xFF38BDF8),
                title: 'Camera',
                subtitle: 'Photos and video straight into the vault, never the gallery',
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      settings: const RouteSettings(name: '${vaultRoutePrefix}camera'),
                      builder: (_) => const CameraScreen(),
                    ),
                  );
                },
              ),
              _buildModalTile(
                icon: Icons.mic_rounded,
                color: const Color(0xFFF43F5E),
                title: 'Record Audio',
                subtitle: 'Recorded straight into the vault, encrypted as it goes',
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const RecorderScreen()),
                  );
                },
              ),
              _buildModalTile(
                icon: Icons.note_add_rounded,
                color: const Color(0xFFA78BFA),
                title: 'Create Encrypted Secret Note',
                subtitle: 'Store passwords, backup seeds, and text memos',
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          const NoteEditorScreen(category: VaultCategory.note),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickAndImportFile(
    FileType fileType,
    List<String>? allowedExtensions,
    VaultCategory category,
  ) async {
    final result = await context.read<UnlockProvider>().withoutAutoLock(
      () => FilePicker.platform.pickFiles(
        type: fileType,
        allowedExtensions: allowedExtensions,
        allowMultiple: false,
      ),
    );

    if (result == null || result.files.single.path == null) return;

    final pickedFile = File(result.files.single.path!);
    final fileName = result.files.single.name;

    if (mounted) {
      final ext = fileName.split('.').last.toLowerCase();
      final cat =
          (ext == 'jpg' ||
              ext == 'jpeg' ||
              ext == 'png' ||
              ext == 'webp' ||
              ext == 'gif')
          ? VaultCategory.image
          : (ext == 'mp4' || ext == 'mov' || ext == 'mkv')
          ? VaultCategory.video
          : category;

      final mimeType = mimeForName(fileName);

      try {
        await context.read<VaultProvider>().importFile(
          sourceFile: pickedFile,
          title: fileName,
          category: cat,
          mimeType: mimeType,
        );
      } finally {
        // The picker hands us a plaintext *copy* in the app cache. Remove it.
        try {
          await pickedFile.delete();
        } catch (_) {}
        try {
          await FilePicker.platform.clearTemporaryFiles();
        } catch (_) {}
      }

      if (!mounted) return;
      // The picker can't delete the original for us; be honest about it.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF059669),
          duration: const Duration(seconds: 6),
          content: Text(
            'Encrypted "$fileName". The original is still in your phone storage: '
            'delete it there if it should not exist outside the vault.',
            style: AppFonts.outfit(color: Colors.white),
          ),
        ),
      );
    }
  }

  Widget _buildModalTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      onTap: onTap,
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: color, size: 24),
      ),
      title: Text(
        title,
        style: AppFonts.outfit(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: AppFonts.outfit(fontSize: 12, color: Colors.white54),
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 4),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vault = context.watch<VaultProvider>();
    final unlockProvider = context.watch<UnlockProvider>();

    // Listen for panic or lock events to auto exit
    if (unlockProvider.state != UnlockState.unlocked) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        vaultRoutes.removeAllAboveFirst();
      });
    }

    final totalBytes = vault.allItems.fold<int>(
      0,
      (sum, item) => sum + item.fileSizeBytes,
    );
    final sizeFormatted = formatBytes(totalBytes);
    final count = vault.allItems.length;

    return Scaffold(
      backgroundColor: const Color(0xFF090D16),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.lock_outline_rounded,
            color: Color(0xFFA78BFA),
          ),
          tooltip: 'Lock Safe',
          onPressed: _lockAndExit,
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFFA78BFA).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.shield_rounded,
                color: Color(0xFFA78BFA),
                size: 18,
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Encrypted Safe',
                  style: AppFonts.outfit(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                Text(
                  'AES-256 GCM • Active',
                  style: AppFonts.outfit(
                    fontSize: 10,
                    color: const Color(0xFF34D399),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              _isGridView ? Icons.view_list_rounded : Icons.grid_view_rounded,
              color: Colors.white70,
            ),
            tooltip: _isGridView ? 'List View' : 'Grid View',
            onPressed: () => setState(() => _isGridView = !_isGridView),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Colors.white70),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(
              Icons.power_settings_new_rounded,
              color: Color(0xFFFB7185),
            ),
            tooltip: 'Instant Panic Lock',
            onPressed: _triggerPanicLock,
          ),
        ],
      ),
      body: Column(
        children: [
          // Storage Overview & Status Banner
          Container(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF1E1B4B).withValues(alpha: 0.6),
                  const Color(0xFF161B22),
                ],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFFA78BFA).withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFA78BFA).withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.lock_rounded,
                    color: Color(0xFFA78BFA),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$count protected ${count == 1 ? 'item' : 'items'} ($sizeFormatted)',
                        style: AppFonts.outfit(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Shake hard anytime to trigger Panic Lock',
                        style: AppFonts.outfit(
                          fontSize: 11,
                          color: Colors.white60,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Search Bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: TextField(
              enableIMEPersonalizedLearning: false, // keep vault text out of keyboard learning
              controller: _searchController,
              onChanged: (q) => vault.setSearchQuery(q),
              style: AppFonts.outfit(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search encrypted files, notes, tags...',
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
                          vault.setSearchQuery('');
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
          ),

          // Category Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                _buildCategoryChip(null, 'All (${vault.allItems.length})'),
                _buildCategoryChip(
                  VaultCategory.document,
                  'Documents (${vault.documents.length})',
                ),
                _buildCategoryChip(
                  VaultCategory.image,
                  'Media (${vault.media.length})',
                ),
                _buildCategoryChip(
                  VaultCategory.note,
                  'Notes (${vault.notes.length})',
                ),
                _buildCategoryChip(
                  VaultCategory.keySecret,
                  'Keys (${vault.keySecrets.length})',
                ),
              ],
            ),
          ),

          const SizedBox(height: 4),

          // Main Content List / Grid
          Expanded(
            child: vault.isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFFA78BFA)),
                  )
                : vault.filteredItems.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.folder_open_rounded,
                          size: 56,
                          color: Colors.white.withValues(alpha: 0.15),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Safe is Empty',
                          style: AppFonts.outfit(
                            fontSize: 16,
                            color: Colors.white60,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Tap + Add File below to import encrypted files.',
                          style: AppFonts.outfit(
                            fontSize: 13,
                            color: Colors.white38,
                          ),
                        ),
                      ],
                    ),
                  )
                : _isGridView
                ? _buildGridView(vault.filteredItems)
                : _buildListView(vault.filteredItems),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFFA78BFA),
        foregroundColor: const Color(0xFF090D16),
        elevation: 4,
        onPressed: _showImportOptions,
        icon: const Icon(Icons.add_rounded, size: 22),
        label: Text(
          'Add File',
          style: AppFonts.outfit(fontWeight: FontWeight.bold, fontSize: 14),
        ),
      ),
    );
  }

  Widget _buildCategoryChip(VaultCategory? category, String label) {
    final vault = context.read<VaultProvider>();
    final isSelected = vault.selectedCategory == category;

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        selected: isSelected,
        label: Text(label),
        labelStyle: AppFonts.outfit(
          fontSize: 12,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: isSelected ? Colors.white : Colors.white60,
        ),
        backgroundColor: const Color(0xFF161B22),
        selectedColor: const Color(0xFF1E1B4B),
        side: BorderSide(
          color: isSelected
              ? const Color(0xFFA78BFA)
              : Colors.white.withValues(alpha: 0.08),
        ),
        onSelected: (_) => vault.setCategoryFilter(category),
      ),
    );
  }

  Widget _buildListView(List<VaultItem> items) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: items.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final item = items[index];
        return _buildVaultItemCard(item);
      },
    );
  }

  Widget _buildGridView(List<VaultItem> items) {
    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.1,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return _buildVaultGridTile(item);
      },
    );
  }

  Widget _buildVaultGridTile(VaultItem item) {
    final (icon, color) = _getItemIconAndColor(item);
    return InkWell(
      onTap: () => _openItem(item),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(
                    Icons.more_vert_rounded,
                    color: Colors.white38,
                    size: 18,
                  ),
                  color: const Color(0xFF21262D),
                  onSelected: (val) => _handleItemAction(val, item),
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'open',
                      child: Text(
                        'Open File',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'export',
                      child: Text(
                        'Export File',
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
                        'Shred / Delete',
                        style: TextStyle(color: Color(0xFFFB7185)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: AppFonts.outfit(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  item.content != null
                      ? '${item.content!.length} chars'
                      : formatBytes(item.fileSizeBytes),
                  style: AppFonts.outfit(
                    fontSize: 11,
                    color: Colors.white54,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVaultItemCard(VaultItem item) {
    final (icon, color) = _getItemIconAndColor(item);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: ListTile(
        onTap: () => _openItem(item),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        title: Text(
          item.title,
          style: AppFonts.outfit(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          item.content != null
              ? (item.content!.split('\n').first)
              : '${formatBytes(item.fileSizeBytes)} • Encrypted',
          style: AppFonts.outfit(fontSize: 12, color: Colors.white54),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: PopupMenuButton<String>(
          icon: const Icon(
            Icons.more_vert_rounded,
            color: Colors.white38,
            size: 18,
          ),
          color: const Color(0xFF21262D),
          onSelected: (val) => _handleItemAction(val, item),
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'open',
              child: Text('Open File', style: TextStyle(color: Colors.white)),
            ),
            const PopupMenuItem(
              value: 'export',
              child: Text('Export File', style: TextStyle(color: Colors.white)),
            ),
            const PopupMenuItem(
              value: 'rename',
              child: Text('Rename', style: TextStyle(color: Colors.white)),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: Text(
                'Shred / Delete',
                style: TextStyle(color: Color(0xFFFB7185)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  (IconData, Color) _getItemIconAndColor(VaultItem item) {
    switch (item.category) {
      case VaultCategory.document:
        return (Icons.picture_as_pdf_rounded, const Color(0xFF38BDF8));
      case VaultCategory.image:
        return (Icons.image_rounded, const Color(0xFFF472B6));
      case VaultCategory.video:
        return (Icons.movie_rounded, const Color(0xFFFBBF24));
      case VaultCategory.keySecret:
        return (Icons.key_rounded, const Color(0xFF34D399));
      case VaultCategory.note:
        return (Icons.description_rounded, const Color(0xFFA78BFA));
    }
  }

  void _openItem(VaultItem item) {
    if (item.category == VaultCategory.note ||
        item.category == VaultCategory.keySecret) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              NoteEditorScreen(existingItem: item, category: item.category),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => FileViewerScreen(item: item)),
      );
    }
  }

  void _handleItemAction(String action, VaultItem item) async {
    if (action == 'open') {
      _openItem(item);
    } else if (action == 'export') {
      await exportWithConfirmation(context, item);
    } else if (action == 'rename') {
      final controller = TextEditingController(text: item.title);
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
            enableIMEPersonalizedLearning: false, // keep vault text out of keyboard learning
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
                backgroundColor: const Color(0xFFA78BFA),
                foregroundColor: const Color(0xFF090D16),
              ),
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text(
                'Save',
                style: AppFonts.outfit(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (newName != null && newName.isNotEmpty) {
        await context.read<VaultProvider>().renameItem(item, newName);
      }
    } else if (action == 'delete') {
      if (!mounted || !await confirmShred(context, item.title) || !mounted) return;
      await context.read<VaultProvider>().deleteItem(item);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFFE11D48),
          content: Text(
            'File shredded and deleted.',
            style: AppFonts.outfit(color: Colors.white),
          ),
        ),
      );
    }
  }
}
