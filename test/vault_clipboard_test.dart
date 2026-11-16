import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/services/vault_clipboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.example.secretvault/security'),
      (call) async {
        calls.add(call);
        return true;
      },
    );
  });

  testWidgets('vault text menu copies as sensitive and offers nothing that leaves the vault', (t) async {
    final c = TextEditingController(text: 'the source is Alex');
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: TextField(controller: c, contextMenuBuilder: vaultContextMenu)),
    ));
    await t.tap(find.byType(TextField));
    await t.pump();
    c.selection = const TextSelection(baseOffset: 14, extentOffset: 18);
    final state = t.state<EditableTextState>(find.byType(EditableText));
    state.showToolbar();
    await t.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Share'), findsNothing);
    expect(find.textContaining('Search'), findsNothing);
    expect(find.text('Look Up'), findsNothing);

    await t.tap(find.text('Copy'));
    await t.pump();
    final copy = calls.singleWhere((m) => m.method == 'copySensitive');
    expect((copy.arguments as Map)['text'], 'Alex');

    // Cut removes the text and copies it the same way.
    c.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
    state.showToolbar();
    await t.pumpAndSettle();
    await t.tap(find.text('Cut'));
    await t.pump();
    expect(c.text, 'source is Alex');
    expect(calls.where((m) => m.method == 'copySensitive').map((m) => (m.arguments as Map)['text']), ['Alex', 'the ']);

    // Cleared on request (the lock calls this), and a minute after copying.
    await VaultClipboard.clear();
    expect(calls.last.method, 'clearSensitive');
    await VaultClipboard.copy('x');
    calls.clear();
    await t.pump(VaultClipboard.clearAfter + const Duration(seconds: 1));
    expect(calls.map((m) => m.method), contains('clearSensitive'));
  });
}
