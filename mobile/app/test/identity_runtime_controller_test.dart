import 'package:duman_messenger/identity/identity_android_runtime.dart';
import 'package:duman_messenger/identity/identity_channel.dart';
import 'package:duman_messenger/identity/identity_runtime_controller.dart';
import 'package:duman_messenger/identity/identity_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'identity_fake_platform.dart';

/// These tests exercise the application composition: the controller in `main`
/// is built exactly this way, over the real `G2dIdentityChannel`.
///
/// The platform is a Dart double. A pass here proves the wiring, the contract
/// and the error mapping — it is not device verification.
void main() {
  late FakeIdentityPlatform platform;

  setUp(() {
    platform = FakeIdentityPlatform();
    platform.install();
  });

  tearDown(() {
    platform.uninstall();
  });

  G2dIdentityRuntimeController androidController() {
    return G2dIdentityRuntimeController(
      supportedPlatform: true,
      runtimeFactory: () => G2dAndroidIdentityRuntime.initialize(
        channel: G2dIdentityChannel(),
      ),
    );
  }

  List<String> methodsCalled() =>
      platform.calls.map((MethodCall call) => call.method).toList();

  group('composition root', () {
    test('assembles once against the real channel', () async {
      final controller = androidController();

      await Future.wait(<Future<void>>[
        controller.ensureInitialized(),
        controller.ensureInitialized(),
      ]);
      await controller.ensureInitialized();

      expect(controller.status, G2dIdentityRuntimeStatus.ready);
      expect(controller.runtime, isNotNull);
      expect(controller.failureReason, isNull);
      // Idempotent: one probe, no repeated Keystore work.
      expect(methodsCalled(), <String>['capabilities']);
      expect(controller.apiLevel, 27);
      expect(controller.protectionSummary, contains('software-backed'));
      expect(controller.isSecureAtRest, isTrue);
    });

    test('reports an unsupported platform without touching the channel', () async {
      final controller = G2dIdentityRuntimeController(supportedPlatform: false);

      await controller.ensureInitialized();

      expect(controller.status, G2dIdentityRuntimeStatus.unsupportedPlatform);
      expect(controller.runtime, isNull);
      expect(controller.failureReason, isNull);
      expect(platform.calls, isEmpty);
      expect(await controller.reload(), isNull);
    });

    test('reports unavailable when the wrap did not verify, with the reason', () async {
      platform.capabilities = measuredEvidence(roundTripVerified: false);
      final controller = androidController();

      await controller.ensureInitialized();

      expect(controller.status, G2dIdentityRuntimeStatus.unavailable);
      expect(controller.runtime, isNull);
      expect(controller.failureReason, contains('No verified'));
      expect(controller.isReady, isFalse);
      // A refused assembly must not fall back to a second, weaker store.
      expect(platform.storedPayload, isNull);
      expect(methodsCalled(), <String>['capabilities']);
    });
  });

  group('operations reach the native implementation', () {
    test('reload reads through the service, never through the store', () async {
      final controller = androidController();
      await controller.ensureInitialized();

      final snapshot = await controller.reload();

      expect(snapshot, isA<G2dIdentityAbsent>());
      expect(controller.snapshot, isA<G2dIdentityAbsent>());
      expect(methodsCalled(), <String>['capabilities', 'load']);
      expect(platform.saveCount, 0);
    });

    test('a missing wrapping key propagates as a typed corrupt state', () async {
      final controller = androidController();
      await controller.ensureInitialized();
      platform.persistentLoadFailure = PlatformException(
        code: G2dIdentityChannelError.keyMissing,
        message: 'wrapping key absent',
      );

      final snapshot = await controller.reload();

      expect(snapshot, isA<G2dIdentityCorrupt>());
      expect(controller.snapshot, isA<G2dIdentityCorrupt>());
      // Fail-closed: a read must never create or replace a key.
      expect(platform.saveCount, 0);
      expect(methodsCalled(), isNot(contains('delete')));
    });

    test('resetting an unreadable identity delegates delete to the platform', () async {
      final controller = androidController();
      await controller.ensureInitialized();
      platform.storedPayload = 'ciphertext-shaped placeholder';
      platform.persistentLoadFailure = PlatformException(
        code: G2dIdentityChannelError.keyMissing,
      );

      final snapshot = await controller.reload();
      expect(snapshot, isA<G2dIdentityCorrupt>());

      final result = await controller.resetCorruptIdentity();

      expect(result, isNotNull);
      expect(result!.isSuccess, isTrue);
      expect(methodsCalled(), contains('delete'));
      expect(platform.storedPayload, isNull);
    });

    test('busy is false and errors are surfaced, not swallowed', () async {
      final controller = androidController();
      await controller.ensureInitialized();
      platform.persistentLoadFailure = PlatformException(
        code: G2dIdentityChannelError.keyMissing,
      );

      await controller.reload();

      expect(controller.busy, isFalse);
      expect(controller.operationError, isNull);
    });
  });

  group('process recreation', () {
    test('a new controller re-reads the platform instead of reusing memory', () async {
      final first = androidController();
      await first.ensureInitialized();
      expect(await first.reload(), isA<G2dIdentityAbsent>());

      // Models the next process: new controller, no shared in-memory identity.
      final second = androidController();
      await second.ensureInitialized();
      final snapshot = await second.reload();

      expect(snapshot, isA<G2dIdentityAbsent>());
      expect(methodsCalled(), <String>['capabilities', 'load', 'capabilities', 'load']);
      expect(second.snapshot, isNotNull);
      expect(first.snapshot, isNotNull);
    });
  });
}
