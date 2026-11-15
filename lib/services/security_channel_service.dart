import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../config/features.dart';

/// Controls Android's FLAG_SECURE (no screenshots, blank in recent apps).
///
/// Protection is driven by *state*, not by which widgets happen to be alive:
///
/// * it is on whenever a vault is unlocked ([setVaultOpen], called by
///   VaultService on unlock/lock), so no vault screen can switch it off by
///   closing (e.g. leaving the file viewer while the vault list is showing);
/// * screens that show vault UI while the vault is still *locked* (the lock
///   screen) additionally hold it with `setSecureFlag(true/false)`.
///
/// The cover app itself never sets it, so it behaves like a normal app.
class SecurityChannelService {
  static const MethodChannel _channel = MethodChannel('com.example.secretvault/security');

  static int _holders = 0;
  static bool _vaultOpen = false;
  static bool? _applied;

  @visibleForTesting
  static int get holders => _holders;

  /// Whether the window is currently protected.
  static bool get isSecure => _vaultOpen || _holders > 0;

  /// Called by VaultService whenever a session opens or closes.
  static Future<void> setVaultOpen(bool open) async {
    _vaultOpen = open;
    await _apply();
  }

  /// `true` acquires a hold, `false` releases one (lock screen).
  static Future<void> setSecureFlag(bool hold) async {
    _holders = hold ? _holders + 1 : (_holders > 0 ? _holders - 1 : 0);
    await _apply();
  }

  /// Drops every screen hold (the cover screen is showing again). Does not
  /// affect protection for an unlocked vault.
  static Future<void> clearAll() async {
    _holders = 0;
    await _apply();
  }

  /// Keeps the screen on while a video plays. Audio doesn't: when the
  /// screen goes off the app is backgrounded, the vault locks and playback
  /// stops, which is the point.
  static Future<void> setKeepScreenOn(bool on) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('setKeepScreenOn', {'on': on});
    } catch (e) {
      debugPrint('SecurityChannelService error: $e');
    }
  }

  static Future<void> _apply() async {
    final enable = isSecure;
    if (_applied == enable) return;
    _applied = enable;
    if (!Platform.isAndroid) return;
    if (!Features.secureWindow) return;
    try {
      await _channel.invokeMethod('setSecureFlag', {'enable': enable});
    } catch (e) {
      debugPrint('SecurityChannelService error: $e');
    }
  }
}
