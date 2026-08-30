import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/auth_service.dart';
import 'setup_screen.dart';

/// Security & Preferences Settings Screen.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final AuthService _authService = AuthService();
  bool _autoLockOnSwitch = true;
  int _inactivityTimeout = 30;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final autoLock = await _authService.getAutoLockOnSwitch();
    final timeout = await _authService.getInactivityTimeout();
    if (mounted) {
      setState(() {
        _autoLockOnSwitch = autoLock;
        _inactivityTimeout = timeout;
      });
    }
  }

  void _showChangePinDialog(bool isDecoy) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          isDecoy ? 'Update Decoy PIN' : 'Update Master PIN',
          style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isDecoy
                  ? 'Enter new 4–6 digit PIN for opening Decoy Vault.'
                  : 'Enter new 4–6 digit Master PIN for opening Primary Vault.',
              style: GoogleFonts.outfit(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 6,
              style: GoogleFonts.outfit(fontSize: 22, color: Colors.white, letterSpacing: 6),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                counterText: '',
                filled: true,
                fillColor: const Color(0xFF21262D),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: GoogleFonts.outfit(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFA78BFA),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              final newPin = controller.text.trim();
              if (newPin.length < 4) return;
              Navigator.pop(ctx);

              if (isDecoy) {
                await _authService.updateDecoyPin(newPin);
              } else {
                await _authService.updatePin(newPin);
              }

              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    backgroundColor: const Color(0xFF059669),
                    content: Text('PIN updated successfully.', style: GoogleFonts.outfit(color: Colors.white)),
                  ),
                );
              }
            },
            child: Text('Save', style: GoogleFonts.outfit(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF090D16),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white70, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Security & Settings',
          style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        children: [
          _buildSectionHeader('SPATIAL WAND & GESTURES'),
          _buildSettingCard(
            icon: Icons.auto_awesome_rounded,
            color: const Color(0xFFA78BFA),
            title: 'Recalibrate 3D Wand Gestures',
            subtitle: 'Re-record Master and Decoy 6-DOF air gestures',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SetupScreen()),
              );
            },
          ),
          const SizedBox(height: 8),
          _buildSettingCard(
            icon: Icons.pin_rounded,
            color: const Color(0xFF34D399),
            title: 'Change Master PIN',
            subtitle: 'Fallback PIN to unlock real vault',
            onTap: () => _showChangePinDialog(false),
          ),
          const SizedBox(height: 8),
          _buildSettingCard(
            icon: Icons.masks_rounded,
            color: const Color(0xFF38BDF8),
            title: 'Change Decoy Duress PIN',
            subtitle: 'Opens decoy vault under coercion',
            onTap: () => _showChangePinDialog(true),
          ),

          const SizedBox(height: 24),
          _buildSectionHeader('AUTO-LOCK & TIMEOUTS'),

          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.06)),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    'Auto-Lock on App Switch',
                    style: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
                  ),
                  subtitle: Text(
                    'Lock immediately and purge RAM when leaving app',
                    style: GoogleFonts.outfit(fontSize: 12, color: Colors.white54),
                  ),
                  value: _autoLockOnSwitch,
                  activeColor: const Color(0xFFA78BFA),
                  onChanged: (val) async {
                    setState(() => _autoLockOnSwitch = val);
                    await _authService.setAutoLockOnSwitch(val);
                  },
                ),
                const Divider(color: Colors.white10),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    'Inactivity Lockout Timeout',
                    style: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
                  ),
                  subtitle: Text(
                    '$_inactivityTimeout seconds of idle touch',
                    style: GoogleFonts.outfit(fontSize: 12, color: Colors.white54),
                  ),
                  trailing: DropdownButton<int>(
                    value: _inactivityTimeout,
                    dropdownColor: const Color(0xFF1F2937),
                    underline: const SizedBox(),
                    style: GoogleFonts.outfit(color: const Color(0xFFA78BFA), fontWeight: FontWeight.bold),
                    items: const [
                      DropdownMenuItem(value: 15, child: Text('15s')),
                      DropdownMenuItem(value: 30, child: Text('30s')),
                      DropdownMenuItem(value: 60, child: Text('60s')),
                      DropdownMenuItem(value: 120, child: Text('2m')),
                    ],
                    onChanged: (val) async {
                      if (val == null) return;
                      setState(() => _inactivityTimeout = val);
                      await _authService.setInactivityTimeout(val);
                    },
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),
          _buildSectionHeader('CRYPTOGRAPHY & THREAT MODEL'),

          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.06)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSecurityBadge('Encryption', 'AES-256-GCM / CBC with Unique IV'),
                const SizedBox(height: 10),
                _buildSecurityBadge('Plausible Deniability', 'Dual SQLite DBs with Isolated Salts'),
                const SizedBox(height: 10),
                _buildSecurityBadge('Panic Response', 'Volatile RAM Key Zeroization on Motion Snap'),
                const SizedBox(height: 10),
                _buildSecurityBadge('Air Recognition', 'Pure Dart 6-DOF Dynamic Time Warping (DTW)'),
              ],
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 4),
      child: Text(
        title,
        style: GoogleFonts.outfit(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: Colors.white38,
        ),
      ),
    );
  }

  Widget _buildSettingCard({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: ListTile(
        onTap: onTap,
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        title: Text(
          title,
          style: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
        ),
        subtitle: Text(
          subtitle,
          style: GoogleFonts.outfit(fontSize: 12, color: Colors.white54),
        ),
        trailing: const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white24, size: 14),
      ),
    );
  }

  Widget _buildSecurityBadge(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.check_circle_outline_rounded, color: Color(0xFF34D399), size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: GoogleFonts.outfit(fontSize: 12, color: Colors.white70),
              children: [
                TextSpan(text: '$label: ', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                TextSpan(text: value, style: const TextStyle(color: Colors.white60)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
