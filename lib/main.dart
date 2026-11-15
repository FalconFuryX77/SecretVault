import 'package:flutter/material.dart';
import 'dart:async';
import 'theme/app_fonts.dart';
import 'package:provider/provider.dart';
import 'providers/device_files_provider.dart';
import 'providers/unlock_provider.dart';
import 'providers/vault_provider.dart';
import 'models/vault_state.dart';
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
          create: (_) => UnlockProvider(vaultService: vaultService),
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
            navigatorObservers: [vaultRoutes],
            title: 'Files',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: Brightness.dark,
              scaffoldBackgroundColor: const Color(0xFF090D16),
              textTheme: AppFonts.outfitTextTheme(
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
                    ctx.read<UnlockProvider>().onUserActivity();
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

/// Tracks the root navigator's routes, so locking can remove every vault
/// screen at once.
class VaultRouteObserver extends NavigatorObserver {
  final List<Route<dynamic>> stack = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => stack.add(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => stack.remove(route);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => stack.remove(route);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : stack.indexOf(oldRoute);
    if (i >= 0 && newRoute != null) {
      stack[i] = newRoute;
    } else if (newRoute != null) {
      stack.add(newRoute);
    }
  }

  /// Removes everything above the first route, without any transition, so
  /// the very next frame is the cover app. (popUntil animates each route
  /// out, and that animation would show the vault on wake.)
  void removeAllAboveFirst() {
    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;
    for (final r in stack.skip(1).toList().reversed) {
      if (r.isActive) nav.removeRoute(r);
    }
  }
}

final VaultRouteObserver vaultRoutes = VaultRouteObserver();

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
      // "enter your PIN" inside the Files app.
      if (unlock.state != UnlockState.unlocked) vaultRoutes.removeAllAboveFirst();
    } else if (state == AppLifecycleState.resumed) {
      unlock.onAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
