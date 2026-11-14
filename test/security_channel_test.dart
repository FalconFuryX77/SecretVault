import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/services/security_channel_service.dart';

void main() {
  setUp(() async {
    await SecurityChannelService.setVaultOpen(false);
    await SecurityChannelService.clearAll();
  });

  test('an unlocked vault is protected regardless of screen holds', () async {
    await SecurityChannelService.setVaultOpen(true);
    // A child screen opening and closing (e.g. the file viewer) can't turn
    // protection off while the vault is open.
    await SecurityChannelService.setSecureFlag(true);
    await SecurityChannelService.setSecureFlag(false);
    await SecurityChannelService.setSecureFlag(false);
    expect(SecurityChannelService.isSecure, isTrue);
    await SecurityChannelService.setVaultOpen(false);
    expect(SecurityChannelService.isSecure, isFalse);
  });

  test('lock screen hold protects while locked; releases never go negative', () async {
    await SecurityChannelService.setSecureFlag(true);
    expect(SecurityChannelService.isSecure, isTrue);
    await SecurityChannelService.setSecureFlag(false);
    await SecurityChannelService.setSecureFlag(false);
    expect(SecurityChannelService.holders, 0);
    expect(SecurityChannelService.isSecure, isFalse);
    await SecurityChannelService.setSecureFlag(true);
    expect(SecurityChannelService.isSecure, isTrue, reason: 'an extra release must not cancel a later hold');
  });

  test('cover screen clears stale holds but not an open vault', () async {
    await SecurityChannelService.setSecureFlag(true);
    await SecurityChannelService.setVaultOpen(true);
    await SecurityChannelService.clearAll();
    expect(SecurityChannelService.isSecure, isTrue);
    await SecurityChannelService.setVaultOpen(false);
    expect(SecurityChannelService.isSecure, isFalse);
  });
}
