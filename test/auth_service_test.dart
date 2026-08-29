import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gesture_unlock/models/gesture.dart';
import 'package:gesture_unlock/services/auth_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AuthService Security & Salt Tests', () {
    late AuthService authService;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      authService = AuthService(storage: const FlutterSecureStorage());
    });

    test('Initial state indicates setup is not complete', () async {
      final isComplete = await authService.isSetupComplete();
      expect(isComplete, isFalse);
    });

    test('saveCredentials stores salted hashes and completes setup', () async {
      final pattern = [Gesture.left, Gesture.up, Gesture.shake, Gesture.down];
      const pin = '4321';

      await authService.saveCredentials(pattern: pattern, pin: pin);

      expect(await authService.isSetupComplete(), isTrue);

      final patternValid = await authService.verifyPattern(pattern);
      expect(patternValid, isTrue);

      final pinValid = await authService.verifyPin(pin);
      expect(pinValid, isTrue);
    });

    test('verifyPattern rejects incorrect gesture sequence', () async {
      final pattern = [Gesture.left, Gesture.up, Gesture.shake, Gesture.down];
      final wrongPattern = [Gesture.right, Gesture.up, Gesture.shake, Gesture.down];
      const pin = '1234';

      await authService.saveCredentials(pattern: pattern, pin: pin);

      expect(await authService.verifyPattern(wrongPattern), isFalse);
      expect(await authService.verifyPattern(pattern), isTrue);
    });

    test('verifyPin rejects incorrect PIN', () async {
      final pattern = [Gesture.left, Gesture.up, Gesture.shake, Gesture.down];
      const pin = '9876';

      await authService.saveCredentials(pattern: pattern, pin: pin);

      expect(await authService.verifyPin('0000'), isFalse);
      expect(await authService.verifyPin('9875'), isFalse);
      expect(await authService.verifyPin('9876'), isTrue);
    });

    test('updatePattern and updatePin successfully update credentials', () async {
      final pattern1 = [Gesture.left, Gesture.left, Gesture.left, Gesture.left];
      const pin1 = '1111';

      await authService.saveCredentials(pattern: pattern1, pin: pin1);

      final pattern2 = [Gesture.right, Gesture.right, Gesture.right, Gesture.right];
      const pin2 = '2222';

      await authService.updatePattern(pattern2);
      await authService.updatePin(pin2);

      expect(await authService.verifyPattern(pattern1), isFalse);
      expect(await authService.verifyPattern(pattern2), isTrue);

      expect(await authService.verifyPin(pin1), isFalse);
      expect(await authService.verifyPin(pin2), isTrue);
    });

    test('Failed attempts and lockout timestamps are persisted properly', () async {
      expect(await authService.getFailedAttempts(), equals(0));

      await authService.setFailedAttempts(3);
      expect(await authService.getFailedAttempts(), equals(3));

      final futureLockout = DateTime.now().add(const Duration(seconds: 30));
      await authService.setLockoutEndTime(futureLockout);

      final retrievedLockout = await authService.getLockoutEndTime();
      expect(retrievedLockout, isNotNull);
      expect(retrievedLockout!.isAfter(DateTime.now()), isTrue);

      await authService.clearLockout();
      expect(await authService.getLockoutEndTime(), isNull);
      expect(await authService.getFailedAttempts(), equals(0));
    });

    test('Auto-lock and inactivity settings persist correctly', () async {
      expect(await authService.getAutoLockOnSwitch(), isTrue); // Default true
      expect(await authService.getInactivityTimeout(), equals(30)); // Default 30

      await authService.setAutoLockOnSwitch(false);
      await authService.setInactivityTimeout(120);

      expect(await authService.getAutoLockOnSwitch(), isFalse);
      expect(await authService.getInactivityTimeout(), equals(120));
    });
  });
}
