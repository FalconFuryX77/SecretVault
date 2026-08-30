import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:gesture_unlock/models/gesture.dart';
import 'package:gesture_unlock/models/motion_point.dart';
import 'package:gesture_unlock/models/gesture_template.dart';
import 'package:gesture_unlock/models/vault_item.dart';
import 'package:gesture_unlock/services/auth_service.dart';
import 'package:gesture_unlock/services/dtw_matcher.dart';
import 'package:gesture_unlock/services/encryption_service.dart';
import 'package:gesture_unlock/services/database_service.dart';
import 'package:gesture_unlock/providers/vault_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('EXHAUSTIVE SECURITY & STRESS TESTS', () {
    late FlutterSecureStorage storage;
    late AuthService authService;
    late EncryptionService encryptionService;
    late DatabaseService dbService;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      storage = const FlutterSecureStorage();
      authService = AuthService(storage: storage);
      encryptionService = EncryptionService(storage: storage);
      dbService = DatabaseService(encryptionService: encryptionService);

      final dbPath = await getDatabasesPath();
      await deleteDatabase(p.join(dbPath, 'secretvault_primary.db'));
      await deleteDatabase(p.join(dbPath, 'secretvault_decoy.db'));
    });

    tearDown(() async {
      await dbService.close();
    });

    // ──────────────────────────────────────────────────────────────────────────
    // 1. DTW 6-DOF Trajectory Extreme Boundary & Noise Stress
    // ──────────────────────────────────────────────────────────────────────────
    group('1. DTW Spatial Motion Stress & Edge Cases', () {
      List<MotionPoint> makeTrajectory(int count, double Function(int i) fx, double Function(int i) fy) {
        return List.generate(count, (i) => MotionPoint(
          timestampMs: i * 25,
          gx: fx(i),
          gy: fy(i),
          gz: 0.2,
          ax: fx(i) * 1.5,
          ay: fy(i) * 1.5,
          az: 9.81,
        ));
      }

      final circlePoints = makeTrajectory(40, (i) => sin((i / 39) * 2 * pi) * 4.0, (i) => cos((i / 39) * 2 * pi) * 4.0);
      final template = GestureTemplate(
        id: 'tmpl-1',
        name: 'Master Circle',
        points: circlePoints,
        durationMs: 1000,
        createdAt: DateTime.now(),
      );

      test('Zero-length and sub-minimum candidates are safely rejected without throwing', () {
        final resEmpty = DtwMatcher.match(candidate: [], template: template);
        expect(resEmpty.isMatch, isFalse);
        expect(resEmpty.score, equals(double.infinity));
        expect(resEmpty.confidence, equals(0.0));

        final resShort = DtwMatcher.match(
          candidate: [const MotionPoint(timestampMs: 0, gx: 0, gy: 0, gz: 0, ax: 0, ay: 0, az: 9.8)],
          template: template,
        );
        expect(resShort.isMatch, isFalse);
      });

      test('Stationary / Flat line motion (phone sitting still) is strictly rejected', () {
        final flatMotion = makeTrajectory(40, (_) => 0.01, (_) => 0.01);
        final res = DtwMatcher.match(candidate: flatMotion, template: template);
        expect(res.isMatch, isFalse);
        expect(res.score, greaterThan(DtwMatcher.defaultMatchThreshold));
      });

      test('Opposite / Inverted direction trajectory is rejected', () {
        // Reverse direction (counter-clockwise vs clockwise)
        final reversed = makeTrajectory(40, (i) => -sin((i / 39) * 2 * pi) * 4.0, (i) => cos((i / 39) * 2 * pi) * 4.0);
        final res = DtwMatcher.match(candidate: reversed, template: template);
        expect(res.isMatch, isFalse);
      });

      test('Gaussian Noise injection tolerance test', () {
        final rng = Random(42);
        final noisyCandidate = makeTrajectory(40, (i) {
          final clean = sin((i / 39) * 2 * pi) * 4.0;
          final noise = (rng.nextDouble() - 0.5) * 0.4; // ±0.2 rad/s noise
          return clean + noise;
        }, (i) {
          final clean = cos((i / 39) * 2 * pi) * 4.0;
          final noise = (rng.nextDouble() - 0.5) * 0.4;
          return clean + noise;
        });

        final res = DtwMatcher.match(candidate: noisyCandidate, template: template);
        expect(res.isMatch, isTrue, reason: 'Realistic human sensor jitter should still recognize the gesture');
      });

      test('Extreme speeds: 0.4x ultra-fast and 2.5x ultra-slow strokes match correctly', () {
        final fastCandidate = makeTrajectory(16, (i) => sin((i / 15) * 2 * pi) * 4.0, (i) => cos((i / 15) * 2 * pi) * 4.0);
        final slowCandidate = makeTrajectory(90, (i) => sin((i / 89) * 2 * pi) * 4.0, (i) => cos((i / 89) * 2 * pi) * 4.0);

        final fastRes = DtwMatcher.match(candidate: fastCandidate, template: template);
        final slowRes = DtwMatcher.match(candidate: slowCandidate, template: template);

        expect(fastRes.isMatch, isTrue);
        expect(slowRes.isMatch, isTrue);
      });
    });

    // ──────────────────────────────────────────────────────────────────────────
    // 2. Cryptographic Security & Threat Model Stress
    // ──────────────────────────────────────────────────────────────────────────
    group('2. Cryptographic Security & Dual-Vault Isolation', () {
      test('Decryption of corrupt / randomized ciphertext returns original or empty safely', () async {
        const corruptCipher = 'abc123invalidIV:totallyfakebase64ciphertext==';
        final textRes = await encryptionService.decryptText(corruptCipher);
        expect(textRes, equals(corruptCipher));

        final corruptBytes = Uint8List.fromList(List.generate(64, (i) => (i * 13) % 256));
        final byteRes = await encryptionService.decryptBytes(corruptBytes);
        expect(byteRes, isNotNull);
      });

      test('Special unicode, emojis, multiline strings, and SQL injection strings', () async {
        const maliciousPayload = '''
          {"seed": "abandon 🚀 日本語 🔒 \n\r\t ' OR '1'='1'; DROP TABLE vault_items; --"}
        ''';

        final item = VaultItem(
          id: 'test-injection-id',
          title: 'Special 🔒 \' OR 1=1; -- Note',
          content: maliciousPayload,
          category: VaultCategory.note,
          mimeType: 'text/plain',
          fileSizeBytes: maliciousPayload.length,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          tags: ['crypto', '🔑 seed', '日本語'],
        );

        await dbService.insertVaultItem(item, VaultType.primary);

        final retrieved = await dbService.getVaultItemById('test-injection-id', VaultType.primary);
        expect(retrieved, isNotNull);
        expect(retrieved!.title, equals('Special 🔒 \' OR 1=1; -- Note'));
        expect(retrieved.content, equals(maliciousPayload));
        expect(retrieved.tags, contains('🔑 seed'));
        expect(retrieved.tags, contains('日本語'));
      });

      test('Large 1MB+ binary file encryption and decryption integrity', () async {
        // 1 Megabyte synthetic binary file
        final oneMbBytes = Uint8List.fromList(
          List<int>.generate(1024 * 1024, (i) => (i * 31 + 7) % 256),
        );

        final encrypted = await encryptionService.encryptBytes(oneMbBytes, VaultType.primary);
        expect(encrypted.length, greaterThan(oneMbBytes.length));

        final decrypted = await encryptionService.decryptBytes(encrypted, VaultType.primary);
        expect(decrypted.length, equals(oneMbBytes.length));
        expect(decrypted, equals(oneMbBytes));
      });

      test('Primary and Decoy keys cannot cross-decrypt each other data', () async {
        const primaryData = 'Top Secret Primary Contract';
        final encryptedWithPrimary = await encryptionService.encryptText(primaryData, VaultType.primary);

        // Attempt decrypt with Decoy key
        final decryptedWithDecoy = await encryptionService.decryptText(encryptedWithPrimary, VaultType.decoy);
        // It must NOT yield original primaryData
        expect(decryptedWithDecoy, isNot(equals(primaryData)));
      });
    });

    // ──────────────────────────────────────────────────────────────────────────
    // 3. Dual Authentication & Duress Routing
    // ──────────────────────────────────────────────────────────────────────────
    group('3. Dual Authentication & Duress Routing', () {
      setUp(() async {
        await authService.saveCredentials(
          pattern: [Gesture.up, Gesture.down, Gesture.left, Gesture.right],
          pin: '8844',
          decoyPin: '1122',
        );
      });

      test('Master PIN unlocks Primary Vault, Decoy PIN unlocks Decoy Vault', () async {
        final masterResult = await authService.verifyPinWithType('8844');
        expect(masterResult, equals(VaultType.primary));

        final decoyResult = await authService.verifyPinWithType('1122');
        expect(decoyResult, equals(VaultType.decoy));

        final invalidResult = await authService.verifyPinWithType('0000');
        expect(invalidResult, isNull);
      });

      test('Lockout persistence survives multiple re-reads', () async {
        final lockoutTime = DateTime.now().add(const Duration(seconds: 45));
        await authService.setLockoutEndTime(lockoutTime);
        await authService.setFailedAttempts(5);

        expect(await authService.getFailedAttempts(), equals(5));
        final activeLockout = await authService.getLockoutEndTime();
        expect(activeLockout, isNotNull);
        expect(activeLockout!.isAfter(DateTime.now()), isTrue);

        // Clearing lockout restores normal state
        await authService.clearLockout();
        expect(await authService.getLockoutEndTime(), isNull);
        expect(await authService.getFailedAttempts(), equals(0));
      });
    });

    // ──────────────────────────────────────────────────────────────────────────
    // 4. VaultProvider Reactive State & Filter Testing
    // ──────────────────────────────────────────────────────────────────────────
    group('4. VaultProvider State & Category Filtering', () {
      late VaultProvider vaultProvider;

      setUp(() {
        vaultProvider = VaultProvider(
          dbService: dbService,
        );
      });

      test('Decoy Vault auto-seeds realistic plausible decoy files when empty', () async {
        await vaultProvider.loadVault(VaultType.decoy);

        expect(vaultProvider.allItems.isNotEmpty, isTrue);
        expect(vaultProvider.allItems.every((i) => i.isDecoy), isTrue);
        expect(vaultProvider.notes.length, greaterThanOrEqualTo(2));
      });

      test('Search and category filters isolate documents, media, and notes correctly', () async {
        await vaultProvider.loadVault(VaultType.primary);

        // Add note, document, and crypto seed
        await vaultProvider.saveNote(title: 'Tax Notes 2026', content: 'Deductions...', category: VaultCategory.note);
        await vaultProvider.saveNote(title: 'Ledger Seed', content: 'word1 word2', category: VaultCategory.keySecret);

        // Category filter
        vaultProvider.setCategoryFilter(VaultCategory.keySecret);
        expect(vaultProvider.filteredItems.length, equals(1));
        expect(vaultProvider.filteredItems.first.title, equals('Ledger Seed'));

        // Query filter
        vaultProvider.setCategoryFilter(null);
        vaultProvider.setSearchQuery('Tax');
        expect(vaultProvider.filteredItems.length, equals(1));
        expect(vaultProvider.filteredItems.first.title, equals('Tax Notes 2026'));

        // Clear filter
        vaultProvider.clearFilters();
        expect(vaultProvider.filteredItems.length, equals(2));
      });
    });
  });
}
