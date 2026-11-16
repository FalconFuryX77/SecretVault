import 'package:flutter/material.dart';
import 'dart:async';
import 'navigation/vault_routes.dart';
import 'theme/ui.dart';
import 'package:provider/provider.dart';
import 'providers/unlock_provider.dart';
import 'providers/vault_provider.dart';
import 'models/vault_state.dart';
import 'services/vault_clipboard.dart';
import 'sync/auto_backup.dart';
import 'services/vault_service.dart';
import 'cover/trimmer_home_screen.dart';
import 'screens/setup_screen.dart';


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
        Provider<AutoBackup>(create: (_) => AutoBackup(vaults: vaultService), dispose: (_, a) => a.dispose(), lazy: false),
        ChangeNotifierProvider(
          create: (_) => UnlockProvider(vaultService: vaultService),
        ),
        ChangeNotifierProvider(
          create: (_) => VaultProvider(vaultService: vaultService),
        ),
      ],
      child: Builder(
        builder: (context) {
          return MaterialApp(
            navigatorKey: rootNavigatorKey,
            navigatorObservers: [vaultRoutes],
            title: coverName,
            debugShowCheckedModeBanner: false,
            theme: Ui.theme(),
            builder: (ctx, child) {
              return AppLifecycleScope(
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (_) {
                    ctx.read<UnlockProvider>().onUserActivity();
                  },
                  child: child ?? const SizedBox(),
                ),
              );
            },
            home: isSetupComplete
                ? const TrimmerHomeScreen()
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
  StreamSubscription<void>? _lockSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // On any lock (timeout, app switch, panic, lock button): drop every vault
    // screen and dialog at once, and any decoded images, before the next
    // frame can be drawn. Viewers dispose with their routes, which stops
    // playback and clears what they decrypted.
    _lockSub = context.read<VaultService>().onLocked.listen((_) {
      vaultRoutes.removeAllAboveFirst();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      unawaited(VaultClipboard.clear());
    });
  }

  @override
  void dispose() {
    _lockSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final unlock = context.read<UnlockProvider>();
    // Only lock when the app is really backgrounded. `inactive` also fires
    // for system dialogs and the notification shade, and locking there
    // would cut off whatever the user is doing. FLAG_SECURE keeps the
    // vault out of the recent-apps thumbnail in the meantime.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unlock.onAppPaused();
      // A lock screen left open would greet whoever wakes the phone with
      // "enter your PIN" inside the cover app. The cover app's own screens
      // stay, as a real app's would.
      if (unlock.state != UnlockState.unlocked) vaultRoutes.removeVaultScreens();
    } else if (state == AppLifecycleState.resumed) {
      unlock.onAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
