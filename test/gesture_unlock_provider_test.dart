import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gesture_unlock/models/gesture.dart';
import 'package:gesture_unlock/providers/gesture_unlock_provider.dart';
import 'package:gesture_unlock/services/auth_service.dart';
import 'package:gesture_unlock/services/gesture_detector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GestureUnlockProvider Tests', () {
    late AuthService authService;
    late GestureDetectorService detector;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      authService = AuthService();
      detector = GestureDetectorService(eventStream: const Stream.empty());
      await authService.saveCredentials(
        pattern: [Gesture.left, Gesture.right, Gesture.up, Gesture.down],
        pin: '1234',
      );
    });

    test('Initial parameters match security specification', () {
      expect(GestureUnlockProvider.patternLength, equals(4));
      expect(GestureUnlockProvider.maxFailedAttempts, equals(5));
      expect(GestureUnlockProvider.lockoutDurationSeconds, equals(30));
    });

    test('verifyPin unlocks when PIN is correct', () async {
      final provider = GestureUnlockProvider(
        authService: authService,
        detector: detector,
      );
      await Future.delayed(const Duration(milliseconds: 50));

      final result = await provider.verifyPin('1234');
      expect(result, isTrue);
      expect(provider.state, equals(UnlockState.unlocked));
      expect(provider.failedAttempts, equals(0));
      expect(provider.isBiometricVerified, isTrue);
    });

    test('verifyPin rate-limits and triggers lockout on 5 failed attempts', () async {
      final provider = GestureUnlockProvider(
        authService: authService,
        detector: detector,
      );
      await Future.delayed(const Duration(milliseconds: 50));

      for (int i = 1; i <= 4; i++) {
        final res = await provider.verifyPin('9999');
        expect(res, isFalse);
        expect(provider.failedAttempts, equals(i));
        expect(provider.state, isNot(equals(UnlockState.lockout)));
      }

      // 5th attempt triggers lockout
      final res5 = await provider.verifyPin('9999');
      expect(res5, isFalse);
      expect(provider.failedAttempts, equals(5));
      expect(provider.state, equals(UnlockState.lockout));
      expect(provider.lockoutRemaining, greaterThan(0));
    });

    test('lock resets unlock state and clears biometric verification', () async {
      final provider = GestureUnlockProvider(
        authService: authService,
        detector: detector,
      );
      await Future.delayed(const Duration(milliseconds: 50));

      await provider.verifyPin('1234');
      expect(provider.state, equals(UnlockState.unlocked));

      provider.lock();
      expect(provider.state, equals(UnlockState.locked));
      expect(provider.isBiometricVerified, isFalse);
    });
  });
}
