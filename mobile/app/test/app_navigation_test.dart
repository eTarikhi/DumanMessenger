// import 'package:duman_messenger/app.dart';
import 'package:duman_messenger/ble/ble_diagnostic_bridge.dart';
import 'package:duman_messenger/ble/ble_discovery_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  testWidgets('navigates between screens and back', (tester) async {
    await showConversations(
      tester,
      bleDiagnosticApi: BleDiagnosticBridge(isAndroid: false),
      bleDiscoveryApi: BleDiscoveryBridge(isAndroid: false),
    );

    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-open-diagnostics')));
    await tester.pumpAndSettle();
    expect(find.text('Local diagnostics'), findsOneWidget);
    expect(find.text('Platform'), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const Key('diagnostics-open-ble-discovery')),
    );
    await tester.tap(find.byKey(const Key('diagnostics-open-ble-discovery')));
    await tester.pumpAndSettle();
    expect(find.text('BLE discovery'), findsOneWidget);
    expect(find.text('Foreground BLE discovery'), findsOneWidget);
    expect(find.textContaining('available on Android only'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Local diagnostics'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('diagnostics-open-ble')));
    await tester.tap(find.byKey(const Key('diagnostics-open-ble')));
    await tester.pumpAndSettle();
    expect(find.text('BLE diagnostic'), findsOneWidget);
    expect(find.text('Android BLE prerequisites'), findsOneWidget);
    expect(find.text('Unsupported platform'), findsOneWidget);

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
