import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../navigation/vault_routes.dart';
import '../services/vault_service.dart';
import '../theme/ui.dart';
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

/// The open vault: what's in it, and the way to add more.
class VaultHomeScreen extends StatefulWidget {
  const VaultHomeScreen({super.key});

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
      context.read<VaultProvider>().loadVault();
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
        title: const Text('This vault was rolled back'),
        content: const Text(
          'The vault file is older than the last version this phone saved. Someone may have put back '
          'an earlier copy of it, which would undo recent changes (new files, deletions, a PIN change). '
          'Check that nothing is missing, and that files you deleted are gone.',
          key: Key('rollback-warning'),
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
    void go(BuildContext ctx, VoidCallback then) {
      Navigator.pop(ctx);
      then();
    }

    showModalBottomSheet(
      context: context,
      // A plain sheet is capped at 9/16 of the screen, which cut off the
      // last option on smaller phones; let it size to its content and
      // scroll if the screen is shorter still.
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text('Add to the vault', style: Ui.heading()),
              ),
              UiRow(
                icon: Icons.photo_camera_outlined,
                title: 'Camera',
                detail: 'Photos and video, never in the gallery',
                chevron: false,
                onTap: () => go(ctx, () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      settings: const RouteSettings(name: '${vaultRoutePrefix}camera'),
                      builder: (_) => const CameraScreen(),
                    ),
                  );
                }),
              ),
              UiRow(
                icon: Icons.mic_none_rounded,
                title: 'Record audio',
                detail: 'Encrypted as it records',
                chevron: false,
                onTap: () => go(ctx, () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const RecorderScreen()));
                }),
              ),
              UiRow(
                icon: Icons.edit_note_rounded,
                title: 'Note',
                detail: 'Text, passwords, anything typed',
                chevron: false,
                onTap: () => go(ctx, () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const NoteEditorScreen(category: VaultCategory.note)),
                  );
                }),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Divider(),
              ),
              UiRow(
                icon: Icons.photo_library_outlined,
                title: 'Photos and videos',
                detail: 'From this phone',
                chevron: false,
                onTap: () => go(ctx, () => _pickAndImportFile(FileType.media, null, VaultCategory.image)),
              ),
              UiRow(
                icon: Icons.description_outlined,
                title: 'Document',
                detail: 'PDF, Word, spreadsheets, slides, text',
                chevron: false,
                onTap: () => go(
                  ctx,
                  () => _pickAndImportFile(
                    FileType.custom,
                    ['pdf', 'doc', 'docx', 'txt', 'csv', 'xlsx', 'pptx'],
                    VaultCategory.document,
                  ),
                ),
              ),
              UiRow(
                icon: Icons.folder_zip_outlined,
                title: 'Any other file',
                detail: 'Archives, backups, anything',
                chevron: false,
                onTap: () => go(ctx, () => _pickAndImportFile(FileType.any, null, VaultCategory.document)),
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
      final cat = (ext == 'jpg' || ext == 'jpeg' || ext == 'png' || ext == 'webp' || ext == 'gif')
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
          duration: const Duration(seconds: 6),
          content: Text(
            'Encrypted "$fileName". The original is still in your phone storage: '
            'delete it there if it should not exist outside the vault.',
          ),
        ),
      );
    }
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

    final items = vault.allItems;
    final totalBytes = items.fold<int>(0, (sum, item) => sum + item.fileSizeBytes);
    final count = items.length;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 4,
        leading: IconButton(
          icon: const Icon(Icons.lock_outline_rounded, size: 22),
          tooltip: 'Lock',
          onPressed: _lockAndExit,
        ),
        title: Text('Vault', style: Ui.heading()),
        actions: [
          IconButton(
            icon: Icon(_isGridView ? Icons.view_agenda_outlined : Icons.grid_view_outlined, size: 21),
            tooltip: _isGridView ? 'Show as a list' : 'Show as a grid',
            onPressed: () => setState(() => _isGridView = !_isGridView),
          ),
          IconButton(
            icon: const Icon(Icons.tune_rounded, size: 22),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
            },
          ),
          IconButton(
            icon: const Icon(Icons.power_settings_new_rounded, size: 22),
            tooltip: 'Panic lock',
            onPressed: _triggerPanicLock,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Ui.gutter, 8, Ui.gutter, 18),
            child: UiMeter(
              total: formatBytes(totalBytes),
              caption: '$count ${count == 1 ? 'item' : 'items'}',
              parts: _kinds(items),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Ui.gutter),
            child: TextField(
              enableIMEPersonalizedLearning: false, // keep vault text out of keyboard learning
              controller: _searchController,
              onChanged: (q) {
                vault.setSearchQuery(q);
                setState(() {});
              },
              style: Ui.body(size: 15),
              decoration: InputDecoration(
                hintText: 'Search',
                prefixIcon: const Icon(Icons.search_rounded, color: Ui.ink3, size: 20),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close_rounded, color: Ui.ink3, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          vault.setSearchQuery('');
                          setState(() {});
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(Ui.gutter - 4, 10, Ui.gutter, 2),
            child: Row(children: [
              _tab(vault, null, 'All', vault.allItems.length),
              _tab(vault, VaultCategory.document, 'Documents', vault.documents.length),
              _tab(vault, VaultCategory.image, 'Media', vault.media.length),
              _tab(vault, VaultCategory.note, 'Notes', vault.notes.length),
              if (vault.keySecrets.isNotEmpty) _tab(vault, VaultCategory.keySecret, 'Keys', vault.keySecrets.length),
            ]),
          ),
          const Divider(),
          Expanded(
            child: vault.isLoading
                ? const Center(child: CircularProgressIndicator())
                : vault.filteredItems.isEmpty
                    ? _empty(searching: _searchController.text.isNotEmpty || vault.selectedCategory != null)
                    : _isGridView
                        ? _buildGridView(vault.filteredItems)
                        : _buildListView(vault.filteredItems),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Ui.tick();
          _showImportOptions();
        },
        icon: const Icon(Icons.add_rounded, size: 22),
        label: const Text('Add'),
      ),
    );
  }

  /// Bytes by kind of file, for the meter.
  static List<(String, int)> _kinds(List<VaultItem> items) {
    var photos = 0, video = 0, audio = 0, docs = 0, notes = 0;
    for (final i in items) {
      final m = i.mimeType.toLowerCase();
      if (i.category == VaultCategory.note || i.category == VaultCategory.keySecret) {
        notes += i.fileSizeBytes;
      } else if (m.startsWith('image/')) {
        photos += i.fileSizeBytes;
      } else if (m.startsWith('video/')) {
        video += i.fileSizeBytes;
      } else if (m.startsWith('audio/')) {
        audio += i.fileSizeBytes;
      } else {
        docs += i.fileSizeBytes;
      }
    }
    return [('Video', video), ('Photos', photos), ('Audio', audio), ('Documents', docs), ('Notes', notes)];
  }

  Widget _tab(VaultProvider vault, VaultCategory? category, String label, int n) {
    final selected = vault.selectedCategory == category;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => vault.setCategoryFilter(category),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 14, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(label, style: Ui.body(size: 15, color: selected ? Ui.ink : Ui.ink2)),
            const SizedBox(width: 5),
            Text('$n', style: Ui.data(size: 11, color: selected ? Ui.signal : Ui.ink3)),
          ]),
          const SizedBox(height: 8),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: 2,
            width: selected ? 22 : 0,
            decoration: BoxDecoration(color: Ui.signal, borderRadius: BorderRadius.circular(1)),
          ),
        ]),
      ),
    );
  }

  Widget _empty({required bool searching}) => Padding(
        padding: const EdgeInsets.fromLTRB(Ui.gutter, 40, Ui.gutter, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(searching ? 'Nothing matches' : 'Nothing here yet', style: Ui.heading()),
          const SizedBox(height: 8),
          Text(
            searching
                ? 'Try another word, or another filter.'
                : 'Add photos, documents, notes or recordings. They stay encrypted on this phone.',
            style: Ui.detail(),
          ),
        ]),
      );

  Widget _buildListView(List<VaultItem> items) {
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: items.length,
      separatorBuilder: (context, index) => const Divider(indent: 64),
      itemBuilder: (context, index) => UiEnter(index: index, child: _buildRow(items[index])),
    );
  }

  Widget _buildGridView(List<VaultItem> items) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(Ui.gutter, 14, Ui.gutter, 96),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.15,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) => UiEnter(index: index, child: _buildTile(items[index])),
    );
  }

  Widget _menu(VaultItem item) => PopupMenuButton<String>(
        icon: const Icon(Icons.more_horiz_rounded, color: Ui.ink3, size: 20),
        tooltip: 'More',
        onSelected: (val) => _handleItemAction(val, item),
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'open', child: Text('Open')),
          const PopupMenuItem(value: 'export', child: Text('Export')),
          const PopupMenuItem(value: 'rename', child: Text('Rename')),
          const PopupMenuItem(value: 'delete', child: Text('Shred', style: TextStyle(color: Ui.alert))),
        ],
      );

  Widget _buildTile(VaultItem item) {
    return Material(
      color: Ui.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openItem(item),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 4, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(_icon(item), color: Ui.ink2, size: 22),
                const Spacer(),
                _menu(item),
              ]),
              const Spacer(),
              Text(item.title, style: Ui.body(size: 14), maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Text(_meta(item), style: Ui.data(size: 11), maxLines: 1),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRow(VaultItem item) {
    final isNote = item.content != null;
    return InkWell(
      onTap: () => _openItem(item),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Ui.gutter, 12, 8, 12),
        child: Row(children: [
          SizedBox(width: 30, child: Icon(_icon(item), color: Ui.ink2, size: 22)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.title, style: Ui.body(), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 3),
              isNote
                  ? Text(
                      item.content!.split('\n').first,
                      style: Ui.detail(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  : Text(_meta(item), style: Ui.data(), maxLines: 1),
            ]),
          ),
          _menu(item),
        ]),
      ),
    );
  }

  static IconData _icon(VaultItem item) {
    final m = item.mimeType.toLowerCase();
    if (item.category == VaultCategory.keySecret) return Icons.key_outlined;
    if (item.category == VaultCategory.note) return Icons.notes_rounded;
    if (m.startsWith('image/')) return Icons.image_outlined;
    if (m.startsWith('video/')) return Icons.movie_outlined;
    if (m.startsWith('audio/')) return Icons.graphic_eq_rounded;
    if (m == 'application/pdf') return Icons.picture_as_pdf_outlined;
    final name = item.title.toLowerCase();
    if (name.endsWith('.xlsx') || name.endsWith('.ods') || name.endsWith('.csv')) return Icons.table_chart_outlined;
    if (name.endsWith('.pptx') || name.endsWith('.odp')) return Icons.slideshow_outlined;
    if (name.endsWith('.docx') || name.endsWith('.doc') || name.endsWith('.odt') || name.endsWith('.txt')) {
      return Icons.article_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  /// "1.5 MB · 16 Nov", or the time for something from today.
  static String _meta(VaultItem item) {
    final t = item.updatedAt.toLocal();
    final now = DateTime.now();
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    String two(int n) => n.toString().padLeft(2, '0');
    final when = t.year == now.year && t.month == now.month && t.day == now.day
        ? '${two(t.hour)}:${two(t.minute)}'
        : t.year == now.year
            ? '${t.day} ${months[t.month - 1]}'
            : '${t.day} ${months[t.month - 1]} ${t.year}';
    return '${formatBytes(item.fileSizeBytes)} · $when';
  }

  void _openItem(VaultItem item) {
    if (item.category == VaultCategory.note || item.category == VaultCategory.keySecret) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => NoteEditorScreen(existingItem: item, category: item.category)),
      );
    } else {
      Navigator.push(context, MaterialPageRoute(builder: (_) => FileViewerScreen(item: item)));
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
          title: const Text('Rename'),
          content: TextField(
            enableIMEPersonalizedLearning: false, // keep vault text out of keyboard learning
            controller: controller,
            autofocus: true,
            style: Ui.body(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: Ui.ink2)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save'),
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
        const SnackBar(content: Text('Shredded. Its key is gone and its data overwritten.')),
      );
    }
  }
}
