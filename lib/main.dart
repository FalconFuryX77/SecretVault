import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'providers/gesture_unlock_provider.dart';
import 'providers/notes_provider.dart';
import 'services/auth_service.dart';
import 'screens/lock_screen.dart';
import 'screens/setup_screen.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Check if first-time setup is needed
  final authService = AuthService();
  final isSetup = await authService.isSetupComplete();

  runApp(GestureUnlockApp(isSetupComplete: isSetup));
}

class GestureUnlockApp extends StatelessWidget {
  final bool isSetupComplete;

  const GestureUnlockApp({super.key, required this.isSetupComplete});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => GestureUnlockProvider()),
        ChangeNotifierProvider(create: (_) => NotesProvider()),
      ],
      child: Builder(
        builder: (context) {
          return MaterialApp(
            navigatorKey: rootNavigatorKey,
            title: 'SV Notes',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: Brightness.dark,
              scaffoldBackgroundColor: const Color(0xFF0F0C29),
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
                  // Any user touch activity resets the auto-lock inactivity timer
                  ctx.read<GestureUnlockProvider>().onUserActivity();
                },
                child: child ?? const SizedBox(),
              );
            },
            home: isSetupComplete ? const LockScreen() : const SetupScreen(),
          );
        },
      ),
    );
  }
}
