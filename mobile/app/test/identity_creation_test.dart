import 'package:duman_messenger/identity/identity_android_runtime.dart';
import 'package:duman_messenger/identity/identity_channel.dart';
import 'package:duman_messenger/identity/identity_key_material.dart';
import 'package:duman_messenger/identity/identity_runtime_controller.dart';
import 'package:duman_messenger/identity/identity_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'identity_fake_platform.dart';

/// Identity creation, exercised end to end through the real Dart stack against
/// the fake platform.
///
/// What this proves: real Curve25519 keys are generated, stored as a separate
/// payload, and only then described by a record whose fingerprint the stored
/// material actually produces; a second creation is refused; a wrap that does not
/// give the bytes back aborts with no record and no leftover material.
///
/// What this does not prove: anything about encryption at rest. The double stores
/// strings in the clear. AES-GCM, atomic writes and a missing Keystore key belong
/// to the Android instrumentation tests and to a physical device.
void main() {
  late FakeIdentityPlatform platform;

  setUp(() {
    platform = FakeIdentityPlatform();
    platform.install();
  });

  tearDown(() {
    platform.uninstall();
  });

  Future<G2dAndroidIdentityRuntime> assemble() =>
      G2dAndroidIdentityRuntime.initialize(channel: G2dIdentityChannel());

  test('creates a real identity and stores its keys in a separate slot', () async {
    final G2dAndroidIdentityRuntime runtime = await assemble();

    final G2dIdentityActionResult result = await runtime.createIdentity();
    expect(result.isSuccess, isTrue, reason: result.detail);

    expect(platform.storedKeyMaterial, isNotNull);
    expect(platform.storedPayload, isNotNull);

    final Map<String, Object?> record = decodeRecordPayload(platform.storedPayload!);
    final String fingerprint = record['publicKeyFingerprint']! as String;
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint), isTrue);

    // The fingerprint describes the stored keys: recomputing it from the material
    // that was actually written must give the same value.
    final G2dIdentityKeyMaterial material =
        G2dIdentityKeyMaterial.fromJson(platform.storedKeyMaterial!);
    expect(await runtime.keyProvider.fingerprint(material), fingerprint);

    // The record stays public metadata: no key material in the record payload.
    expect(platform.storedPayload, isNot(contains('Seed')));
    expect(platform.storedPayload, isNot(contains('x25519PublicKey')));

    final Map<Object?, Object?> handle = record['keyHandle']! as Map<Object?, Object?>;
    expect(handle['provider'], 'duman_software');
    expect(handle['protection'], 'software_keystore_wrapped');
    expect(handle['probeVerified'], isTrue);
    expect(record['algorithm'], 'ed25519');

    expect(await runtime.load(), isA<G2dIdentityActive>());
  });

  test('never replaces an identity that already exists', () async {
    final G2dAndroidIdentityRuntime runtime = await assemble();
    expect((await runtime.createIdentity()).isSuccess, isTrue);

    final int materialSaves = platform.keyMaterialSaveCount;
    final String? firstMaterial = platform.storedKeyMaterial;
    final String? firstRecord = platform.storedPayload;

    final G2dIdentityActionResult second = await runtime.createIdentity();

    expect(second.isSuccess, isFalse);
    expect(second.failure, G2dIdentityFailure.identityExists);
    expect(platform.keyMaterialSaveCount, materialSaves);
    expect(platform.storedKeyMaterial, firstMaterial);
    expect(platform.storedPayload, firstRecord);
  });

  test('a wrap that does not round-trip leaves no record and no key material',
      () async {
    final G2dAndroidIdentityRuntime runtime = await assemble();
    // Something else comes back from the slot than went in.
    platform.keyMaterialLoadOverride =
        (await runtime.keyProvider.generate()).toJson();

    final G2dIdentityActionResult result = await runtime.createIdentity();

    expect(result.isSuccess, isFalse);
    expect(result.failure, G2dIdentityFailure.storageWriteFailed);
    expect(platform.saveCount, 0);
    expect(platform.storedPayload, isNull);
    expect(platform.storedKeyMaterial, isNull);
    expect(
      platform.calls.map((MethodCall call) => call.method),
      contains('deleteKeyMaterial'),
    );
  });

  test('a stored record that is corrupt is never overwritten', () async {
    final G2dAndroidIdentityRuntime runtime = await assemble();
    platform.storedPayload = '{"recordVersion":1}';

    final G2dIdentityActionResult result = await runtime.createIdentity();

    expect(result.isSuccess, isFalse);
    expect(result.failure, G2dIdentityFailure.storageCorrupt);
    expect(platform.keyMaterialSaveCount, 0);
  });

  test('the controller offers creation only after a read proves absence', () async {
    final G2dIdentityRuntimeController controller = G2dIdentityRuntimeController(
      supportedPlatform: true,
      runtimeFactory: assemble,
    );
    await controller.ensureInitialized();

    // Nothing has been read, so nothing is claimed.
    expect(controller.canCreateIdentity, isFalse);

    await controller.reload();
    expect(controller.snapshot, isA<G2dIdentityAbsent>());
    expect(controller.canCreateIdentity, isTrue);

    final G2dIdentityActionResult? created = await controller.createIdentity();
    expect(created, isNotNull);
    expect(created!.isSuccess, isTrue);
    expect(controller.snapshot, isA<G2dIdentityActive>());
    expect(controller.keyProtection, 'software_keystore_wrapped');
    expect(controller.canCreateIdentity, isFalse);
    expect(controller.operationError, isNull);
  });

  test('a refused creation is reported, not swallowed', () async {
    final G2dIdentityRuntimeController controller = G2dIdentityRuntimeController(
      supportedPlatform: true,
      runtimeFactory: assemble,
    );
    await controller.ensureInitialized();
    await controller.reload();
    expect((await controller.createIdentity())!.isSuccess, isTrue);

    // Force the controller to try again over an existing identity.
    final G2dIdentityActionResult? second = await controller.createIdentity();

    expect(second, isNotNull);
    expect(second!.failure, G2dIdentityFailure.identityExists);
    expect(controller.operationError, contains('identityExists'));
    expect(controller.snapshot, isA<G2dIdentityActive>());
  });
}
