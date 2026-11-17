import 'package:duman_messenger/identity/identity_android_runtime.dart';
import 'package:duman_messenger/identity/identity_channel.dart';
import 'package:duman_messenger/identity/identity_models.dart';
import 'package:duman_messenger/identity/identity_runtime_controller.dart';
import 'package:duman_messenger/identity/identity_store.dart';
import 'package:duman_messenger/screens/my_identity_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'identity_fake_platform.dart';

/// My identity as a user actually meets it.
///
/// These tests exercise the screen against the real controller, service and
/// key provider over the fake platform, so "create" really generates keys and
/// really writes a record. They do not prove encryption at rest: the double
/// stores strings in the clear, and the device-side proof lives in the
/// instrumentation suite.
void main() {
  late FakeIdentityPlatform platform;
  final List<String> clipboardWrites = <String>[];

  setUp(() {
    platform = FakeIdentityPlatform();
    platform.install();
    clipboardWrites.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
      if (call.method == 'Clipboard.setData') {
        final arguments = call.arguments as Map<Object?, Object?>;
        clipboardWrites.add(arguments['text']! as String);
      }
      return null;
    });
  });

  tearDown(() {
    platform.uninstall();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  G2dIdentityRuntimeController controllerFor({
    bool supportedPlatform = true,
    G2dIdentityRuntimeFactory? factory,
  }) =>
      G2dIdentityRuntimeController(
        supportedPlatform: supportedPlatform,
        runtimeFactory: factory ??
            () => G2dAndroidIdentityRuntime.initialize(
                  channel: G2dIdentityChannel(),
                ),
      );

  Future<G2dIdentityRuntimeController> readyController() async {
    final controller = controllerFor();
    await controller.ensureInitialized();
    await controller.reload();
    return controller;
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    G2dIdentityRuntimeController controller,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: MyIdentityScreen(identityRuntime: controller)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the stored fingerprint and copies only that value',
      (WidgetTester tester) async {
    final controller = await readyController();
    expect((await controller.createIdentity())!.isSuccess, isTrue);

    final Map<String, Object?> record =
        decodeRecordPayload(platform.storedPayload!);
    final String fingerprint = record['publicKeyFingerprint']! as String;

    await pumpScreen(tester, controller);

    expect(find.byKey(const Key('identity-present')), findsOneWidget);
    final SelectableText shown = tester.widget<SelectableText>(
      find.byKey(const Key('identity-fingerprint')),
    );
    expect(shown.data,
        G2dIdentityRecord.formatFingerprintForDisplay(fingerprint));
    expect(tester.takeException(), isNull);

    final Finder copy = find.byKey(const Key('identity-copy-fingerprint'));
    await tester.ensureVisible(copy);
    await tester.pumpAndSettle();
    await tester.tap(copy);
    await tester.pumpAndSettle();

    expect(clipboardWrites, <String>[fingerprint]);
    // Nothing but the public fingerprint may reach the clipboard.
    expect(clipboardWrites.single, isNot(contains('Seed')));
    expect(clipboardWrites.single.length, 64);
  });

  testWidgets('reports the protection level the record actually carries',
      (WidgetTester tester) async {
    final controller = await readyController();
    await controller.createIdentity();
    await pumpScreen(tester, controller);

    expect(
      tester.widget<Text>(find.byKey(const Key('identity-protection-level'))).data,
      'software_keystore_wrapped',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('identity-protection'))).data,
      contains('Software key'),
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('identity-protection'))).data,
      isNot(contains('hardware')),
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('identity-state'))).data,
      'active',
    );
  });

  testWidgets('creates an identity from the empty state, with confirmation',
      (WidgetTester tester) async {
    final controller = await readyController();
    await pumpScreen(tester, controller);

    expect(find.byKey(const Key('identity-absent')), findsOneWidget);
    expect(platform.storedPayload, isNull);

    final Finder create = find.byKey(const Key('identity-create'));
    await tester.ensureVisible(create);
    await tester.pumpAndSettle();
    await tester.tap(create);
    await tester.pumpAndSettle();

    // Cancelling must not create anything.
    await tester.tap(find.byKey(const Key('identity-create-cancel')));
    await tester.pumpAndSettle();
    expect(platform.storedPayload, isNull);
    expect(find.byKey(const Key('identity-absent')), findsOneWidget);

    await tester.ensureVisible(create);
    await tester.pumpAndSettle();
    await tester.tap(create);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('identity-create-confirm')));
    await tester.pumpAndSettle();

    expect(platform.storedPayload, isNotNull);
    expect(find.byKey(const Key('identity-present')), findsOneWidget);
    expect(find.byKey(const Key('identity-absent')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a corrupt record is reported and never auto-replaced',
      (WidgetTester tester) async {
    final controller = await readyController();
    platform.storedPayload = '{"recordVersion":1}';

    await pumpScreen(tester, controller);

    expect(find.byKey(const Key('identity-corrupt')), findsOneWidget);
    expect(find.byKey(const Key('identity-create')), findsNothing);
    expect(find.byKey(const Key('identity-present')), findsNothing);
    expect(platform.saveCount, 0);
    expect(platform.storedKeyMaterial, isNull);

    // Accessing the reason must be possible without exposing key material.
    final Text reason =
        tester.widget<Text>(find.byKey(const Key('identity-corrupt-reason')));
    expect(reason.data, isNotEmpty);
  });

  testWidgets('an unavailable runtime shows the platform reason and offers nothing',
      (WidgetTester tester) async {
    final controller = controllerFor(
      factory: () async =>
          throw const G2dIdentityStoreUnavailable('no verified wrap on this device'),
    );
    await controller.ensureInitialized();
    await pumpScreen(tester, controller);

    expect(find.byKey(const Key('identity-unavailable')), findsOneWidget);
    expect(find.textContaining('no verified wrap'), findsOneWidget);
    expect(find.byKey(const Key('identity-create')), findsNothing);
    expect(platform.storedPayload, isNull);
  });

  testWidgets('an unsupported platform is stated, not simulated',
      (WidgetTester tester) async {
    final controller = controllerFor(supportedPlatform: false);
    await controller.ensureInitialized();
    await pumpScreen(tester, controller);

    expect(find.byKey(const Key('identity-unsupported')), findsOneWidget);
    expect(find.byKey(const Key('identity-create')), findsNothing);
    expect(
      platform.calls.map((MethodCall call) => call.method),
      isEmpty,
      reason: 'an unsupported platform must not touch the channel',
    );
  });
}
