// import 'package:duman_messenger/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  testWidgets('navigates between screens and back', (tester) async {
    await showConversations(tester);

    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-open-diagnostics')));
    await tester.pumpAndSettle();
    expect(find.text('Local diagnostics'), findsOneWidget);
    expect(find.text('Platform'), findsOneWidget);

    await tester.tap(find.byKey(const Key('diagnostics-open-ble')));
    await tester.pumpAndSettle();
    expect(find.text('BLE diagnostic'), findsOneWidget);
    expect(find.text('Android BLE prerequisites'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Local diagnostics'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('No conversations yet'), findsOneWidget);
  });
}
