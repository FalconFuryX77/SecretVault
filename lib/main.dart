import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'providers/device_files_provider.dart';
import 'providers/gesture_unlock_provider.dart';
import 'providers/vault_provider.dart';
import 'services/vault_service.dart';
import 'screens/normal_files_screen.dart';
import 'screens/setup_screen.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // cryptography_flutter registers itself, routing AES-GCM to native code.
  final vaultService = VaultService();
  final isSetup = await vaultService.isSetUp();

  runApp(SecretVaultApp(isSetupComplete: isSetup, vaultService: vaultService));
}

class SecretVaultApp extends StatelessWidget {
  final bool isSetupComplete;
  final VaultService vaultService;

  const SecretVaultApp({
    super.key,
    required this.isSetupComplete,
    required this.vaultService,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<VaultService>.value(value: vaultService),
        ChangeNotifierProvider(
          create: (_) => GestureUnlockProvider(vaultService: vaultService),
        ),
        ChangeNotifierProvider(
          create: (_) => VaultProvider(vaultService: vaultService),
        ),
        ChangeNotifierProvider(create: (_) => DeviceFilesProvider()),
      ],
      child: Builder(
        builder: (context) {
          return MaterialApp(
            navigatorKey: rootNavigatorKey,
            title: 'Files',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: Brightness.dark,
              scaffoldBackgroundColor: const Color(0xFF090D16),
              textTheme: GoogleFonts.outfitTextTheme(
                ThemeData.dark().textTheme,
              ),
              useMaterial3: true,
              colorSchemeSeed: const Color(0xFFA78BFA),
            ),
            builder: (ctx, child) {
              return AppLifecycleScope(
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (_) {
                    ctx.read<GestureUnlockProvider>().onUserActivity();
                  },
                  child: child ?? const SizedBox(),
                ),
              );
            },
            home: isSetupComplete
                ? const NormalFilesScreen()
                : const SetupScreen(),
          );
        },
      ),
    );
  }
}

class AppLifecycleScope extends StatefulWidget {
  final Widget child;
  const AppLifecycleScope({super.key, required this.child});

  @override
  State<AppLifecycleScope> createState() => _AppLifecycleScopeState();
}

class _AppLifecycleScopeState extends State<AppLifecycleScope>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final unlock = context.read<GestureUnlockProvider>();
    // Only lock when the app is really backgrounded. `inactive` also fires
    // for the fingerprint dialog and the notification shade, and locking
    // there would cut off biometric enrolment mid-way. FLAG_SECURE keeps the
    // vault out of the recent-apps thumbnail in the meantime.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unlock.onAppPaused();
    } else if (state == AppLifecycleState.resumed) {
      unlock.onAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
