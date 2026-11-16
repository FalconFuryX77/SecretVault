import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Copying text out of the vault.
///
/// Android lets an app mark a clip as *sensitive*: keyboards then leave it
/// out of their clipboard history, and the system's "copied" preview hides
/// it. Vault text is always copied that way, and it's cleared from the
/// clipboard a minute later or when the vault locks, whichever comes first.
///
/// Vault text fields use [vaultContextMenu], which copies through here and
/// drops the menu items that would hand the text to another app (Share,
/// web search, look up).
class VaultClipboard {
  static const MethodChannel _channel = MethodChannel('com.example.secretvault/security');
  static const Duration clearAfter = Duration(minutes: 1);
  static Timer? _timer;

  /// Copies [text] as a sensitive clip and schedules its removal.
  static Future<void> copy(String text) async {
    try {
      await _channel.invokeMethod('copySensitive', {'text': text});
    } on MissingPluginException {
      await Clipboard.setData(ClipboardData(text: text));
    }
    _timer?.cancel();
    _timer = Timer(clearAfter, clear);
  }

  /// Removes a clip copied from the vault (if one was copied since the last
  /// clear). Called on lock.
  static Future<void> clear() async {
    _timer?.cancel();
    _timer = null;
    try {
      await _channel.invokeMethod('clearSensitive');
    } on MissingPluginException {
      // Not Android: nothing marked, nothing tracked.
    }
  }
}

/// The text selection menu for vault text: Copy and Cut go through
/// [VaultClipboard]; nothing that sends the text to another app.
Widget vaultContextMenu(BuildContext context, EditableTextState state) {
  final value = state.textEditingValue;
  final selection = value.selection;
  final selected = selection.isValid ? selection.textInside(value.text) : '';
  final items = <ContextMenuButtonItem>[];
  for (final item in state.contextMenuButtonItems) {
    switch (item.type) {
      case ContextMenuButtonType.copy:
        items.add(ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: () {
            unawaited(VaultClipboard.copy(selected));
            state.hideToolbar();
          },
        ));
      case ContextMenuButtonType.cut:
        items.add(ContextMenuButtonItem(
          type: ContextMenuButtonType.cut,
          onPressed: () {
            unawaited(VaultClipboard.copy(selected));
            state.userUpdateTextEditingValue(
              value.replaced(selection, '').copyWith(selection: TextSelection.collapsed(offset: selection.start)),
              SelectionChangedCause.toolbar,
            );
            state.hideToolbar();
          },
        ));
      case ContextMenuButtonType.paste:
      case ContextMenuButtonType.selectAll:
        items.add(item);
      default:
        // Share, look up, web search, live text, custom: they hand the text
        // (or the field) to something outside the vault.
        break;
    }
  }
  return AdaptiveTextSelectionToolbar.buttonItems(anchors: state.contextMenuAnchors, buttonItems: items);
}
