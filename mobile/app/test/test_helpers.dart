import 'package:duman_messenger/app.dart';
import 'package:duman_messenger/ble/ble_diagnostic_bridge.dart';
import 'package:duman_messenger/ble/ble_discovery_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> showConversations(
  WidgetTester tester, {
  BleDiagnosticApi? bleDiagnosticApi,
  BleDiscoveryApi? bleDiscoveryApi,
}) async {
  final app = bleDiagnosticApi == null && bleDiscoveryApi == null
      ? const DumanMessengerApp()
      : DumanMessengerApp(
          bleDiagnosticApi: bleDiagnosticApi,
          bleDiscoveryApi: bleDiscoveryApi,
        );
  await tester.pumpWidget(app);
  await tester.ensureVisible(find.byKey(const Key('onboarding-continue')));
  await tester.tap(find.byKey(const Key('onboarding-continue')));
  await tester.pumpAndSettle();
}
