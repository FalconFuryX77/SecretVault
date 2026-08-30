import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/gesture_unlock_provider.dart';
import 'lock_screen.dart';
import 'setup_screen.dart';

/// Covert "Normal Files" Explorer screen.
/// Provides authentic plausible deniability by presenting a standard Android
/// file manager interface. The Secret Vault portal can be accessed via a covert
/// gesture, tapping the lock glyph in the top bar, or performing the 3D Wand stroke.
class NormalFilesScreen extends StatefulWidget {
  const NormalFilesScreen({super.key});

  @override
  State<NormalFilesScreen> createState() => _NormalFilesScreenState();
}

class _NormalFilesScreenState extends State<NormalFilesScreen> {
  int _headerTapCount = 0;
  DateTime _lastHeaderTap = DateTime(0);

  final List<Map<String, dynamic>> _storageCategories = [
    {
      'title': 'Downloads',
      'icon': Icons.download_rounded,
      'color': const Color(0xFF38BDF8),
      'count': '24 files',
      'size': '1.2 GB',
    },
    {
      'title': 'Images & Photos',
      'icon': Icons.image_rounded,
      'color': const Color(0xFFF472B6),
      'count': '142 photos',
      'size': '850 MB',
    },
    {
      'title': 'Documents',
      'icon': Icons.description_rounded,
      'color': const Color(0xFF34D399),
      'count': '18 items',
      'size': '45 MB',
    },
    {
      'title': 'Audio & Music',
      'icon': Icons.audiotrack_rounded,
      'color': const Color(0xFFA78BFA),
      'count': '32 tracks',
      'size': '280 MB',
    },
    {
      'title': 'Videos',
      'icon': Icons.movie_rounded,
      'color': const Color(0xFFFBBF24),
      'count': '9 clips',
      'size': '2.4 GB',
    },
    {
      'title': 'Archives (.zip)',
      'icon': Icons.folder_zip_rounded,
      'color': const Color(0xFFFB7185),
      'count': '5 files',
      'size': '310 MB',
    },
  ];

  final List<Map<String, dynamic>> _recentFiles = [
    {
      'name': 'Invoice_Q3_Travel_Expenses.pdf',
      'size': '2.4 MB',
      'date': 'Today, 10:15 AM',
      'icon': Icons.picture_as_pdf_rounded,
      'color': Colors.redAccent,
    },
    {
      'name': 'Project_Wireframe_Mockups_v2.png',
      'size': '4.1 MB',
      'date': 'Yesterday',
      'icon': Icons.image_rounded,
      'color': Colors.blueAccent,
    },
    {
      'name': 'Meeting_Notes_Architecture.txt',
      'size': '14 KB',
      'date': 'Aug 28',
      'icon': Icons.text_snippet_rounded,
      'color': Colors.tealAccent,
    },
    {
      'name': 'Client_Presentation_Deck.pdf',
      'size': '8.6 MB',
      'date': 'Aug 25',
      'icon': Icons.picture_as_pdf_rounded,
      'color': Colors.orangeAccent,
    },
  ];

  void _onHeaderTap() {
    final now = DateTime.now();
    if (now.difference(_lastHeaderTap).inMilliseconds > 800) {
      _headerTapCount = 1;
    } else {
      _headerTapCount++;
    }
    _lastHeaderTap = now;

    // Triple tap or single tap on lock triggers portal
    if (_headerTapCount >= 3) {
      _headerTapCount = 0;
      _openVaultPortal();
    }
  }

  void _openVaultPortal() {
    final provider = context.read<GestureUnlockProvider>();
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

  @override
  Widget build(BuildContext context) {
    final unlockProvider = context.watch<GestureUnlockProvider>();

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        title: GestureDetector(
          onTap: _onHeaderTap,
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: const Color(0xFF21262D),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.folder_open_rounded,
                  color: Color(0xFF58A6FF),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Files Explorer',
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    'Internal Storage • 42 GB Free',
                    style: GoogleFonts.outfit(
                      fontSize: 11,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search_rounded, color: Colors.white70),
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.shield_outlined, color: Colors.white30, size: 20),
            tooltip: 'Security Status',
            onPressed: _openVaultPortal,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        children: [
          // Storage Overview Card
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1F2937), Color(0xFF111827)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Device Storage',
                      style: GoogleFonts.outfit(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      '86 GB / 128 GB',
                      style: GoogleFonts.outfit(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF58A6FF),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: const LinearProgressIndicator(
                    value: 0.67,
                    minHeight: 8,
                    backgroundColor: Color(0xFF374151),
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF58A6FF)),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildStorageTag('Apps: 34 GB', const Color(0xFFA78BFA)),
                    _buildStorageTag('Media: 28 GB', const Color(0xFFF472B6)),
                    _buildStorageTag('System: 24 GB', const Color(0xFF34D399)),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Categories Grid
          Text(
            'Categories',
            style: GoogleFonts.outfit(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),

          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.7,
            ),
            itemCount: _storageCategories.length,
            itemBuilder: (context, index) {
              final cat = _storageCategories[index];
              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF161B22),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.06)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: (cat['color'] as Color).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        cat['icon'] as IconData,
                        color: cat['color'] as Color,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            cat['title'] as String,
                            style: GoogleFonts.outfit(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            cat['count'] as String,
                            style: GoogleFonts.outfit(
                              fontSize: 11,
                              color: Colors.white54,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

          const SizedBox(height: 24),

          // Recent Files List
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Recent Files',
                style: GoogleFonts.outfit(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              Text(
                'View All',
                style: GoogleFonts.outfit(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF58A6FF),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _recentFiles.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final file = _recentFiles[index];
              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF161B22),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white.withOpacity(0.04)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: (file['color'] as Color).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        file['icon'] as IconData,
                        color: file['color'] as Color,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            file['name'] as String,
                            style: GoogleFonts.outfit(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${file['size']} • ${file['date']}',
                            style: GoogleFonts.outfit(
                              fontSize: 11,
                              color: Colors.white54,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.more_vert_rounded, color: Colors.white38, size: 18),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildStorageTag(String text, Color color) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          text,
          style: GoogleFonts.outfit(
            fontSize: 11,
            color: Colors.white70,
          ),
        ),
      ],
    );
  }
}
