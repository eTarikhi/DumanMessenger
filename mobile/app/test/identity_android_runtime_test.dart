import 'package:duman_messenger/identity/identity_android_runtime.dart';
import 'package:duman_messenger/identity/identity_channel.dart';
import 'package:duman_messenger/identity/identity_models.dart';
import 'package:duman_messenger/identity/identity_probe_capabilities.dart';
import 'package:duman_messenger/identity/identity_service.dart';
import 'package:duman_messenger/identity/identity_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'identity_fake_platform.dart';

void main() {
  late FakeIdentityPlatform platform;

  setUp(() {
    platform = FakeIdentityPlatform();
    platform.install();
  });

  tearDown(() {
    platform.uninstall();
  });

  group('runtime assembly', () {
    test('builds the stack from measured evidence', () async {
      final runtime = await G2dAndroidIdentityRuntime.initialize(
        channel: G2dIdentityChannel(),
      );
      expect(runtime.evidence.apiLevel, 27);
      expect(runtime.evidence.roundTripVerified, isTrue);
      expect(runtime.store.isSecureAtRest, isTrue);
      expect(runtime.service.isSecureAtRest, isTrue);
      expect(runtime.protectionSummary, contains('software-backed'));
      expect(runtime.protectionSummary, contains('not exportable'));
    });

    test('creates no identity while initializing', () async {
      await G2dAndroidIdentityRuntime.initialize(channel: G2dIdentityChannel());
      expect(
        platform.calls.map((call) => call.method).toList(),
        <String>['capabilities'],
      );
      expect(platform.storedPayload, isNull);
    });

    test('loads an absent identity without writing one', () async {
      final runtime = await G2dAndroidIdentityRuntime.initialize(
        channel: G2dIdentityChannel(),
      );
      expect(await runtime.load(), isA<G2dIdentityAbsent>());
      expect(platform.storedPayload, isNull);
    });

    test('exposes the probed rules rather than the documented ones', () async {
      final runtime = await G2dAndroidIdentityRuntime.initialize(
        channel: G2dIdentityChannel(),
      );
      expect(runtime.capabilities.apiLevel, 27);
      expect(
        runtime.capabilities.describeProtectionFor(
          G2dIdentityAlgorithm.curve25519Xeddsa,
          G2dKeyProtection.softwareKeystoreWrapped,
        ),
        isNull,
      );
      expect(
        runtime.capabilities.describeProtectionFor(
          G2dIdentityAlgorithm.curve25519Xeddsa,
          G2dKeyProtection.hardwareBound,
        ),
        isNotNull,
      );
    });

    test('reports hardware backing only when the device measured it', () async {
      final software = await G2dAndroidIdentityRuntime.initialize(
        channel: G2dIdentityChannel(),
      );
      expect(software.wrapKeyHardwareBacked, isFalse);

      platform.capabilities = measuredEvidence(hardwareBacked: true);
      final hardware = await G2dAndroidIdentityRuntime.initialize(
        channel: G2dIdentityChannel(),
      );
      expect(hardware.wrapKeyHardwareBacked, isTrue);
      expect(hardware.protectionSummary, contains('hardware-backed'));
    });

    test('reports StrongBox only when a StrongBox key was created', () async {
      final absent = await G2dAndroidIdentityRuntime.initialize(
        channel: G2dIdentityChannel(),
      );
      expect(absent.strongBoxVerified, isFalse);

      platform.capabilities = measuredEvidence(
        apiLevel: 34,
        strongBoxRequested: true,
        strongBoxKeyCreated: true,
      );
      final present = await G2dAndroidIdentityRuntime.initialize(
        channel: G2dIdentityChannel(),
      );
      expect(present.strongBoxVerified, isTrue);
    });
  });

  group('refusals', () {
    test('refuses to build when the wrap round trip did not verify', () async {
      platform.capabilities = measuredEvidence(roundTripVerified: false);
      await expectLater(
        G2dAndroidIdentityRuntime.initialize(channel: G2dIdentityChannel()),
        throwsA(isA<G2dIdentityStoreUnavailable>()),
      );
    });

    test('refuses to build when the Keystore is unavailable', () async {
      platform.capabilities = measuredEvidence(
        aesGcmSupported: false,
        roundTripVerified: false,
      );
      await expectLater(
        G2dAndroidIdentityRuntime.initialize(channel: G2dIdentityChannel()),
        throwsA(isA<G2dIdentityStoreUnavailable>()),
      );
    });

    test('refuses to build when the channel is not registered', () async {
      platform.uninstall();
      await expectLater(
        G2dAndroidIdentityRuntime.initialize(channel: G2dIdentityChannel()),
        throwsA(isA<G2dIdentityStoreUnavailable>()),
      );
    });

    test('refuses capability evidence it cannot parse', () async {
      platform.capabilities = <String, Object?>{'apiLevel': 27};
      await expectLater(
        G2dAndroidIdentityRuntime.initialize(channel: G2dIdentityChannel()),
        throwsFormatException,
      );
    });

    test('refuses an API level below the G2-D floor', () async {
      platform.capabilities = measuredEvidence(apiLevel: 26);
      await expectLater(
        G2dAndroidIdentityRuntime.initialize(channel: G2dIdentityChannel()),
        throwsFormatException,
      );
    });
  });
}
