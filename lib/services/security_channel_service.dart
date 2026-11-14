import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Service interfacing with platform-specific anti-forensic security controls (FLAG_SECURE).
class SecurityChannelService {
  static const MethodChannel _channel = MethodChannel('com.example.secretvault/security');

  /// Toggles window security flags to prevent screenshots and task-switcher previews.
  static Future<void> setSecureFlag(bool enable) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('setSecureFlag', {'enable': enable});
    } catch (e) {
      debugPrint('SecurityChannelService error: $e');
    }
  }
}
