import 'package:duman_messenger/identity/identity_android_runtime.dart';
import 'package:duman_messenger/identity/identity_channel.dart';
import 'package:duman_messenger/identity/identity_runtime_controller.dart';
import 'package:duman_messenger/identity/identity_store.dart';
import 'package:duman_messenger/screens/diagnostics_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'identity_fake_platform.dart';

/// The diagnostics surface must report the identity runtime as measured, must
/// never display identity data, a fingerprint or key material, and must stay
/// readable when a failure description is long or the screen is narrow.
void main() {
  late FakeIdentityPlatform platform;

  setUp(() {
    platform = FakeIdentityPlatform();
    platform.install();
  });

  tearDown(() {
    platform.uninstall();
  });

  G2dIdentityRuntimeController controllerWith({
    Map<String, Object?>? capabilities,
    G2dIdentityRuntimeFactory? factory,
  }) {
    if (capabilities != null) {
      platform.capabilities = capabilities;
    }
    return G2dIdentityRuntimeController(
      supportedPlatform: true,
      runtimeFactory: factory ??
          () => G2dAndroidIdentityRuntime.initialize(
                channel: G2dIdentityChannel(),
              ),
    );
  }

  /// Reads the value rendered for one specific diagnostic row.
  ///
  /// Matching on the string alone is wrong here: `no` is a legitimate value for
  /// both "wrapping key hardware-backed" and "StrongBox key created", so a test
  /// that asserts `find.text('no')` cannot say which row it verified.
  String valueOf(WidgetTester tester, String key) {
    final Text text = tester.widget<Text>(find.byKey(Key(key)));
    return text.data!;
  }

  void useNarrowScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('reports a runtime that was never wired', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: DiagnosticsScreen()),
    );

    expect(find.text('Identity runtime'), findsOneWidget);
    expect(valueOf(tester, 'diagnostics-identity-status'), 'not wired');
    expect(tester.takeException(), isNull);
  });

  testWidgets('reports measured protection and enables the read action',
      (WidgetTester tester) async {
    final controller = controllerWith();
    await controller.ensureInitialized();

    await tester.pumpWidget(
      MaterialApp(home: DiagnosticsScreen(identityRuntime: controller)),
    );

    expect(valueOf(tester, 'diagnostics-identity-status'), 'ready');
    expect(
      valueOf(tester, 'diagnostics-identity-protection'),
      contains('software-backed'),
    );
    expect(find.text('Wrapping key hardware-backed'), findsOneWidget);
    expect(find.text('StrongBox key created'), findsOneWidget);

    final Finder readButton = find.byKey(const Key('diagnostics-read-identity'));
    expect(readButton, findsOneWidget);
    expect(tester.widget<OutlinedButton>(readButton).onPressed, isNotNull);

    await tester.tap(readButton);
    await tester.pumpAndSettle();

    expect(valueOf(tester, 'diagnostics-identity-state'), 'none stored');
    expect(tester.takeException(), isNull);
  });

  testWidgets('hardware-backed and StrongBox values are asserted independently',
      (WidgetTester tester) async {
    // A device whose probe key is inside secure hardware but which created no
    // StrongBox key: the two rows must disagree, and each must be read by key.
    final controller = controllerWith(
      capabilities: measuredEvidence(
        hardwareBacked: true,
        strongBoxRequested: true,
        strongBoxKeyCreated: false,
      ),
    );
    await controller.ensureInitialized();

    await tester.pumpWidget(
      MaterialApp(home: DiagnosticsScreen(identityRuntime: controller)),
    );

    expect(valueOf(tester, 'diagnostics-identity-hardware-backed'), 'yes');
    expect(valueOf(tester, 'diagnostics-identity-strongbox'), 'no');
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unavailable runtime reports why and disables reading',
      (WidgetTester tester) async {
    final controller = controllerWith(
      capabilities: measuredEvidence(roundTripVerified: false),
    );
    await controller.ensureInitialized();

    await tester.pumpWidget(
      MaterialApp(home: DiagnosticsScreen(identityRuntime: controller)),
    );

    expect(valueOf(tester, 'diagnostics-identity-status'), 'unavailable');
    expect(find.text('Unavailable because'), findsOneWidget);
    expect(
      valueOf(tester, 'diagnostics-identity-failure-reason'),
      contains('No verified'),
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('diagnostics-read-identity')))
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long failure reason wraps at 320 px without overflowing',
      (WidgetTester tester) async {
    useNarrowScreen(tester);

    const String longReason =
        'No verified Android Keystore wrapping key on this device; identity data '
        'must not be persisted here. The Keystore refused to prove an AES-256-GCM '
        'round trip, so the stored record could not be read back, and the store '
        'is reported unavailable rather than downgraded to a weaker fallback.';

    final controller = controllerWith(
      factory: () async => throw const G2dIdentityStoreUnavailable(longReason),
    );
    await controller.ensureInitialized();

    await tester.pumpWidget(
      MaterialApp(home: DiagnosticsScreen(identityRuntime: controller)),
    );

    // A RenderFlex overflow is reported as a framework exception; the test must
    // fail on it rather than merely finding the expected Text widgets.
    expect(tester.takeException(), isNull);
    expect(valueOf(tester, 'diagnostics-identity-status'), 'unavailable');
    // The whole reason is shown: no ellipsis, no clipping of the message.
    expect(valueOf(tester, 'diagnostics-identity-failure-reason'), longReason);
  });

  testWidgets('identity rows stay readable on a narrow screen',
      (WidgetTester tester) async {
    useNarrowScreen(tester);

    final controller = controllerWith();
    await controller.ensureInitialized();

    await tester.pumpWidget(
      MaterialApp(home: DiagnosticsScreen(identityRuntime: controller)),
    );

    expect(tester.takeException(), isNull);
    expect(valueOf(tester, 'diagnostics-identity-status'), 'ready');
    expect(valueOf(tester, 'diagnostics-identity-hardware-backed'), 'no');
    expect(valueOf(tester, 'diagnostics-identity-strongbox'), 'no');
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('diagnostics-read-identity')))
          .onPressed,
      isNotNull,
    );
  });
}
