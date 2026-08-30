import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'providers/gesture_unlock_provider.dart';
import 'providers/vault_provider.dart';
import 'providers/notes_provider.dart';
import 'services/auth_service.dart';
import 'screens/normal_files_screen.dart';
import 'screens/setup_screen.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final authService = AuthService();
  final isSetup = await authService.isSetupComplete();

  runApp(SecretVaultApp(isSetupComplete: isSetup));
}

class SecretVaultApp extends StatelessWidget {
  final bool isSetupComplete;

  const SecretVaultApp({super.key, required this.isSetupComplete});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => GestureUnlockProvider()),
        ChangeNotifierProvider(create: (_) => VaultProvider()),
        ChangeNotifierProvider(create: (_) => NotesProvider()),
      ],
      child: Builder(
        builder: (context) {
          return MaterialApp(
            navigatorKey: rootNavigatorKey,
            title: 'Files Explorer',
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
              return Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) {
                  ctx.read<GestureUnlockProvider>().onUserActivity();
                },
                child: child ?? const SizedBox(),
              );
            },
            home: isSetupComplete ? const NormalFilesScreen() : const SetupScreen(),
          );
        },
      ),
    );
  }
}
