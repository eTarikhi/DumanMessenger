import 'package:duman_messenger/identity/identity_android_runtime.dart';
import 'package:duman_messenger/identity/identity_channel.dart';
import 'package:duman_messenger/identity/identity_runtime_controller.dart';
import 'package:duman_messenger/screens/diagnostics_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'identity_fake_platform.dart';

/// The diagnostics surface must report the identity runtime as measured, and must
/// never display identity data, a fingerprint or key material.
void main() {
  late FakeIdentityPlatform platform;

  setUp(() {
    platform = FakeIdentityPlatform();
    platform.install();
  });

  tearDown(() {
    platform.uninstall();
  });

  testWidgets('reports a runtime that was never wired', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: DiagnosticsScreen()),
    );

    expect(find.text('Identity runtime'), findsOneWidget);
    expect(find.text('not wired'), findsOneWidget);
  });

  testWidgets('reports measured protection and enables the read action',
      (WidgetTester tester) async {
    final controller = G2dIdentityRuntimeController(
      supportedPlatform: true,
      runtimeFactory: () => G2dAndroidIdentityRuntime.initialize(
        channel: G2dIdentityChannel(),
      ),
    );
    await controller.ensureInitialized();

    await tester.pumpWidget(
      MaterialApp(home: DiagnosticsScreen(identityRuntime: controller)),
    );

    expect(find.text('ready'), findsOneWidget);
    expect(find.textContaining('software-backed'), findsOneWidget);
    expect(find.text('Wrapping key hardware-backed'), findsOneWidget);
    expect(find.text('no'), findsOneWidget);

    final Finder readButton = find.byKey(const Key('diagnostics-read-identity'));
    expect(readButton, findsOneWidget);

    await tester.tap(readButton);
    await tester.pumpAndSettle();

    expect(find.text('none stored'), findsOneWidget);
  });

  testWidgets('an unavailable runtime reports why and disables reading',
      (WidgetTester tester) async {
    platform.capabilities = measuredEvidence(roundTripVerified: false);
    final controller = G2dIdentityRuntimeController(
      supportedPlatform: true,
      runtimeFactory: () => G2dAndroidIdentityRuntime.initialize(
        channel: G2dIdentityChannel(),
      ),
    );
    await controller.ensureInitialized();

    await tester.pumpWidget(
      MaterialApp(home: DiagnosticsScreen(identityRuntime: controller)),
    );

    expect(find.text('unavailable'), findsOneWidget);
    expect(find.text('Unavailable because'), findsOneWidget);
    expect(find.textContaining('No verified'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('diagnostics-read-identity')))
          .onPressed,
      isNull,
    );
  });
}
