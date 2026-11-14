import 'dart:async';
import 'package:flutter/services.dart';

/// Zero-Trace Clipboard Service that automatically overwrites system clipboard
/// after a configurable timeout (default: 30 seconds).
class ZeroTraceClipboardService {
  static Timer? _clearTimer;

  /// Copies sensitive text to clipboard and schedules automatic wipe after [timeoutSeconds].
  static Future<void> copyWithAutoClear(
    String text, {
    int timeoutSeconds = 30,
    void Function()? onCleared,
  }) async {
    _clearTimer?.cancel();
    await Clipboard.setData(ClipboardData(text: text));

    _clearTimer = Timer(Duration(seconds: timeoutSeconds), () async {
      await Clipboard.setData(const ClipboardData(text: ''));
      onCleared?.call();
    });
  }

  /// Immediately purges the clipboard buffer.
  static Future<void> clearImmediately() async {
    _clearTimer?.cancel();
    await Clipboard.setData(const ClipboardData(text: ''));
  }
}
