import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/gesture.dart';
import '../models/vault_item.dart';
import '../providers/gesture_unlock_provider.dart';
import '../providers/vault_provider.dart';
import 'file_viewer_screen.dart';
import 'note_editor_screen.dart';
import 'settings_screen.dart';

/// SecretVault Unlocked Dashboard Screen.
/// Manages encrypted Documents (PDFs), Media (Photos & Videos), Notes, and Seeds.
class VaultHomeScreen extends StatefulWidget {
  final VaultType vaultType;

  const VaultHomeScreen({super.key, required this.vaultType});

  @override
  State<VaultHomeScreen> createState() => _VaultHomeScreenState();
}

class _VaultHomeScreenState extends State<VaultHomeScreen> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<VaultProvider>().loadVault(widget.vaultType);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _lockAndExit() {
    context.read<GestureUnlockProvider>().lockVault();
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _showImportOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
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
                'Add to Encrypted Vault',
                style: GoogleFonts.outfit(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              _buildModalTile(
                icon: Icons.picture_as_pdf_rounded,
                color: const Color(0xFFFB7185),
                title: 'Import Document / PDF',
                subtitle: 'Encrypt PDFs, contracts, tax files into sandbox',
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndImportFile(FileType.custom, ['pdf', 'doc', 'docx', 'txt', 'csv'], VaultCategory.document);
                },
              ),
              _buildModalTile(
                icon: Icons.photo_library_rounded,
                color: const Color(0xFFF472B6),
                title: 'Import Photo or Video',
                subtitle: 'Encrypt media and remove from public gallery',
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndImportFile(FileType.media, null, VaultCategory.image);
                },
              ),
              _buildModalTile(
                icon: Icons.note_add_rounded,
                color: const Color(0xFFA78BFA),
                title: 'New Encrypted Note',
                subtitle: 'Create rich encrypted text memo',
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const NoteEditorScreen(category: VaultCategory.note),
                    ),
                  );
                },
              ),
              _buildModalTile(
                icon: Icons.key_rounded,
                color: const Color(0xFF38BDF8),
                title: 'New Crypto Recovery Seed',
                subtitle: 'Secure 12/24 word secret backup phrase',
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const NoteEditorScreen(category: VaultCategory.keySecret),
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
    final result = await FilePicker.platform.pickFiles(
      type: fileType,
      allowedExtensions: allowedExtensions,
      allowMultiple: false,
    );

    if (result == null || result.files.single.path == null) return;

    final pickedFile = File(result.files.single.path!);
    final fileName = result.files.single.name;

    bool deleteOriginal = false;

    // Prompt user whether to delete original unencrypted copy
    if (mounted) {
      final shouldDelete = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF161B22),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text('Delete Original File?', style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold)),
          content: Text(
            'Would you like to automatically delete the unencrypted original from device storage to prevent shoulder-surfing or gallery snooping?',
            style: GoogleFonts.outfit(fontSize: 13, color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Keep Original', style: GoogleFonts.outfit(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE11D48),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Delete Original', style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
      deleteOriginal = shouldDelete ?? false;
    }

    if (mounted) {
      final mimeType = category == VaultCategory.document
          ? 'application/pdf'
          : category == VaultCategory.image
              ? 'image/jpeg'
              : 'application/octet-stream';

      await context.read<VaultProvider>().importFile(
            sourceFile: pickedFile,
            title: fileName,
            category: category,
            mimeType: mimeType,
            deleteOriginal: deleteOriginal,
          );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF059669),
          content: Text(
            'Successfully encrypted "$fileName" into vault.',
            style: GoogleFonts.outfit(color: Colors.white),
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
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: color, size: 24),
      ),
      title: Text(
        title,
        style: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
      ),
      subtitle: Text(
        subtitle,
        style: GoogleFonts.outfit(fontSize: 12, color: Colors.white54),
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 4),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vault = context.watch<VaultProvider>();
    final isDecoy = widget.vaultType == VaultType.decoy;

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.lock_rounded, color: Color(0xFFA78BFA)),
          tooltip: 'Lock Vault',
          onPressed: _lockAndExit,
        ),
        title: Row(
          children: [
            Text(
              isDecoy ? 'Files Safe' : 'Secret Vault',
              style: GoogleFonts.outfit(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: isDecoy ? const Color(0xFF38BDF8).withOpacity(0.2) : const Color(0xFF34D399).withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                isDecoy ? 'STANDARD' : 'AES-256',
                style: GoogleFonts.outfit(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: isDecoy ? const Color(0xFF38BDF8) : const Color(0xFF34D399),
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Colors.white70),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.power_settings_new_rounded, color: Color(0xFFFB7185)),
            tooltip: 'Panic Lock',
            onPressed: () {
              context.read<GestureUnlockProvider>().triggerPanicLock();
              Navigator.of(context).popUntil((route) => route.isFirst);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Search Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              onChanged: (q) => vault.setSearchQuery(q),
              style: GoogleFonts.outfit(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search encrypted documents, notes, seeds...',
                hintStyle: GoogleFonts.outfit(color: Colors.white38, fontSize: 13),
                prefixIcon: const Icon(Icons.search_rounded, color: Colors.white38, size: 20),
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
                _buildCategoryChip(VaultCategory.document, 'Documents (${vault.documents.length})'),
                _buildCategoryChip(VaultCategory.image, 'Media (${vault.media.length})'),
                _buildCategoryChip(VaultCategory.note, 'Notes (${vault.notes.length})'),
                _buildCategoryChip(VaultCategory.keySecret, 'Crypto Seeds (${vault.keySecrets.length})'),
              ],
            ),
          ),

          const SizedBox(height: 8),

          // Items Grid / List
          Expanded(
            child: vault.isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFFA78BFA)))
                : vault.filteredItems.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.shield_rounded, size: 56, color: Colors.white.withOpacity(0.15)),
                            const SizedBox(height: 12),
                            Text(
                              'Vault is Empty',
                              style: GoogleFonts.outfit(fontSize: 16, color: Colors.white60, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Tap + to import documents, media, or notes.',
                              style: GoogleFonts.outfit(fontSize: 13, color: Colors.white38),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        itemCount: vault.filteredItems.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final item = vault.filteredItems[index];
                          return _buildVaultItemCard(item);
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFFA78BFA),
        onPressed: _showImportOptions,
        icon: const Icon(Icons.add_rounded, color: Colors.black),
        label: Text(
          'Add Item',
          style: GoogleFonts.outfit(fontWeight: FontWeight.bold, color: Colors.black),
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
        labelStyle: GoogleFonts.outfit(
          fontSize: 12,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: isSelected ? Colors.white : Colors.white60,
        ),
        backgroundColor: const Color(0xFF161B22),
        selectedColor: const Color(0xFF1E1B4B),
        side: BorderSide(
          color: isSelected ? const Color(0xFFA78BFA) : Colors.white.withOpacity(0.06),
        ),
        onSelected: (_) => vault.setCategoryFilter(category),
      ),
    );
  }

  Widget _buildVaultItemCard(VaultItem item) {
    IconData icon;
    Color color;

    switch (item.category) {
      case VaultCategory.document:
        icon = Icons.picture_as_pdf_rounded;
        color = const Color(0xFFFB7185);
        break;
      case VaultCategory.image:
        icon = Icons.image_rounded;
        color = const Color(0xFFF472B6);
        break;
      case VaultCategory.video:
        icon = Icons.movie_rounded;
        color = const Color(0xFFFBBF24);
        break;
      case VaultCategory.keySecret:
        icon = Icons.key_rounded;
        color = const Color(0xFF38BDF8);
        break;
      case VaultCategory.note:
        icon = Icons.description_rounded;
        color = const Color(0xFFA78BFA);
        break;
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: ListTile(
        onTap: () {
          if (item.category == VaultCategory.note || item.category == VaultCategory.keySecret) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => NoteEditorScreen(
                  existingItem: item,
                  category: item.category,
                ),
              ),
            );
          } else {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => FileViewerScreen(item: item),
              ),
            );
          }
        },
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        title: Text(
          item.title,
          style: GoogleFonts.outfit(
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
              : '${(item.fileSizeBytes / 1024).toStringAsFixed(1)} KB • Encrypted',
          style: GoogleFonts.outfit(
            fontSize: 12,
            color: Colors.white54,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline_rounded, color: Colors.white30, size: 18),
          onPressed: () async {
            await context.read<VaultProvider>().deleteItem(item);
          },
        ),
      ),
    );
  }
}
