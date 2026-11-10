import 'dart:convert';

import 'package:duman_messenger/identity/identity_android_store.dart';
import 'package:duman_messenger/identity/identity_channel.dart';
import 'package:duman_messenger/identity/identity_models.dart';
import 'package:duman_messenger/identity/identity_probe_capabilities.dart';
import 'package:duman_messenger/identity/identity_service.dart';
import 'package:duman_messenger/identity/identity_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'identity_fake_platform.dart';

/// A fingerprint-shaped value for the first identity.
final String firstFingerprint = List<String>.filled(64, 'a').join();

/// A different fingerprint, for a rotation.
final String secondFingerprint = List<String>.filled(64, 'b').join();

G2dKeyHandle handleWith(G2dKeyProtection protection) => G2dKeyHandle(
      provider: 'android_keystore',
      alias: 'g2d.identity.key.v1',
      protection: protection,
      probeVerified: true,
    );

G2dIdentityRecord sampleRecord({String fingerprint = ''}) {
  final resolved = fingerprint.isEmpty ? firstFingerprint : fingerprint;
  return G2dIdentityRecord(
    identityId: 'identity-1',
    keyVersion: 1,
    algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
    publicKeyFingerprint: resolved,
    keyHandle: handleWith(G2dKeyProtection.softwareKeystoreWrapped),
    state: G2dIdentityState.active,
    createdAtMillis: 1000,
  );
}

void main() {
  late FakeIdentityPlatform platform;

  setUp(() {
    platform = FakeIdentityPlatform();
    platform.install();
  });

  tearDown(() {
    platform.uninstall();
  });

  G2dKeystoreIdentityStore buildStore({bool verified = true}) =>
      G2dKeystoreIdentityStore(
        channel: G2dIdentityChannel(),
        protectionVerified: verified,
      );

  /// A service over a fresh store, as a new process would build it.
  G2dIdentityService buildService({bool verified = true}) => G2dIdentityService(
        store: buildStore(verified: verified),
        platform: G2dProbedKeyCapabilities(
          G2dAndroidCapabilityEvidence.fromMap(measuredEvidence()),
        ),
      );

  group('store identity', () {
    test('reports a stable, non-secret store kind', () {
      expect(buildStore().storeKind, 'android_keystore_v1');
      expect(G2dKeystoreIdentityStore.kind, 'android_keystore_v1');
    });

    test('is secure at rest only when the probe verified the wrapping key', () {
      expect(buildStore(verified: true).isSecureAtRest, isTrue);
      expect(buildStore(verified: false).isSecureAtRest, isFalse);
    });
  });

  group('load', () {
    test('returns no record when the platform holds nothing', () async {
      expect(await buildStore().load(), isNull);
      expect(platform.calls.single.method, 'load');
    });

    test('decodes a stored record', () async {
      final record = sampleRecord();
      platform.storedPayload = jsonEncode(record.toMap());
      final loaded = await buildStore().load();
      expect(loaded, isNotNull);
      expect(loaded!.identityId, record.identityId);
      expect(loaded.publicKeyFingerprint, record.publicKeyFingerprint);
      expect(loaded.keyHandle, record.keyHandle);
      expect(loaded.isUsable, isTrue);
    });

    test('reports a payload that is not JSON as corrupt', () async {
      platform.storedPayload = 'not json at all';
      await expectLater(
        buildStore().load(),
        throwsA(isA<G2dIdentityStoreCorrupt>()),
      );
    });

    test('reports a payload that parsed but is not a valid record as corrupt', () async {
      platform.storedPayload = jsonEncode(<String, Object?>{
        'recordVersion': G2dIdentityRecord.currentRecordVersion,
        'identityId': 'identity-1',
        'keyVersion': 1,
        'algorithm': 'curve25519_xeddsa',
        'publicKeyFingerprint': 'not-a-fingerprint',
        'keyHandle': handleWith(G2dKeyProtection.softwareKeystoreWrapped).toMap(),
        'state': 'active',
        'createdAtMillis': 1000,
      });
      await expectLater(
        buildStore().load(),
        throwsA(isA<G2dIdentityStoreCorrupt>()),
      );
    });

    test('reports a revoked record without a reason as corrupt', () async {
      platform.storedPayload = jsonEncode(<String, Object?>{
        'recordVersion': G2dIdentityRecord.currentRecordVersion,
        'identityId': 'identity-1',
        'keyVersion': 1,
        'algorithm': 'curve25519_xeddsa',
        'publicKeyFingerprint': firstFingerprint,
        'keyHandle': handleWith(G2dKeyProtection.softwareKeystoreWrapped).toMap(),
        'state': 'revoked',
        'createdAtMillis': 1000,
      });
      await expectLater(
        buildStore().load(),
        throwsA(isA<G2dIdentityStoreCorrupt>()),
      );
    });
  });

  group('save', () {
    test('writes exactly the validated record payload', () async {
      await buildStore().save(sampleRecord());
      expect(platform.saveCount, 1);
      final payload = platform.savedPayloads.single;
      expect(payload['identityId'], 'identity-1');
      expect(payload['publicKeyFingerprint'], firstFingerprint);
      expect(payload['recordVersion'], G2dIdentityRecord.currentRecordVersion);
      expect(payload['state'], 'active');
    });

    test('refuses to write an invalid record without calling the platform', () async {
      final invalid = G2dIdentityRecord(
        identityId: 'identity-1',
        keyVersion: 1,
        algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
        publicKeyFingerprint: firstFingerprint,
        keyHandle: handleWith(G2dKeyProtection.softwareKeystoreWrapped),
        state: G2dIdentityState.revoked,
        createdAtMillis: 1000,
      );
      await expectLater(
        buildStore().save(invalid),
        throwsA(isA<G2dIdentityStoreWriteFailed>()),
      );
      expect(platform.saveCount, 0);
      expect(platform.storedPayload, isNull);
    });

    test('surfaces a platform write failure as a write failure', () async {
      platform.failSaveOnce = true;
      await expectLater(
        buildStore().save(sampleRecord()),
        throwsA(isA<G2dIdentityStoreWriteFailed>()),
      );
      expect(platform.storedPayload, isNull);
    });
  });

  group('delete', () {
    test('removes the stored payload', () async {
      platform.storedPayload = jsonEncode(sampleRecord().toMap());
      await buildStore().delete();
      expect(platform.storedPayload, isNull);
      expect(await buildStore().load(), isNull);
    });

    test('is idempotent when nothing is stored', () async {
      await buildStore().delete();
      await buildStore().delete();
      expect(
        platform.calls.where((MethodCall call) => call.method == 'delete').length,
        2,
      );
      expect(platform.storedPayload, isNull);
    });
  });

  group('platform error mapping', () {
    const unavailableCodes = <String>[
      G2dIdentityChannelError.keystoreUnavailable,
      G2dIdentityChannelError.keyGenerationFailed,
      G2dIdentityChannelError.ioUnavailable,
      G2dIdentityChannelError.keyUnusable,
    ];

    for (final code in unavailableCodes) {
      test('maps $code to unavailable', () async {
        platform.failNext = PlatformException(code: code, message: 'detail');
        await expectLater(
          buildStore().load(),
          throwsA(isA<G2dIdentityStoreUnavailable>()),
        );
      });
    }

    // Every code here proves the stored bytes cannot be used on this device, so
    // an explicit reset is the only recovery. Nothing is regenerated silently.
    const corruptCodes = <String>[
      G2dIdentityChannelError.authFailed,
      G2dIdentityChannelError.keyMissing,
      G2dIdentityChannelError.keyInvalidated,
      G2dIdentityChannelError.keyIdMismatch,
      G2dIdentityChannelError.ciphertextMalformed,
      G2dIdentityChannelError.staleRecord,
    ];

    for (final code in corruptCodes) {
      test('maps $code to corrupt', () async {
        platform.failNext = PlatformException(code: code, message: 'detail');
        await expectLater(
          buildStore().load(),
          throwsA(isA<G2dIdentityStoreCorrupt>()),
        );
      });
    }

    test('maps write_failed to a write failure', () async {
      platform.failNext = PlatformException(
        code: G2dIdentityChannelError.writeFailed,
        message: 'detail',
      );
      await expectLater(
        buildStore().save(sampleRecord()),
        throwsA(isA<G2dIdentityStoreWriteFailed>()),
      );
    });

    test('maps an unrecognised code to unavailable, never to corrupt', () async {
      // Corrupt is the only state that permits a destructive reset, so an
      // unknown failure must not claim it.
      platform.failNext = PlatformException(
        code: 'some_future_failure',
        message: 'detail',
      );
      await expectLater(
        buildStore().load(),
        throwsA(isA<G2dIdentityStoreUnavailable>()),
      );
    });

    test('maps a missing channel to unavailable', () async {
      platform.uninstall();
      await expectLater(
        buildStore().load(),
        throwsA(isA<G2dIdentityStoreUnavailable>()),
      );
    });
  });

  group('lifecycle over the adapter', () {
    test('creates an identity and keeps it in the platform store', () async {
      final service = buildService();
      final result = await service.createIdentity(
        algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
        publicKeyFingerprint: firstFingerprint,
        keyHandle: handleWith(G2dKeyProtection.softwareKeystoreWrapped),
      );
      expect(result.isSuccess, isTrue);
      expect(platform.storedPayload, isNotNull);

      final snapshot = await service.load();
      expect(snapshot, isA<G2dIdentityActive>());
      expect(
        (snapshot as G2dIdentityActive).record.publicKeyFingerprint,
        firstFingerprint,
      );
      expect(service.isSecureAtRest, isTrue);
    });

    test('an identity survives service reconstruction', () async {
      await buildService().createIdentity(
        algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
        publicKeyFingerprint: firstFingerprint,
        keyHandle: handleWith(G2dKeyProtection.softwareKeystoreWrapped),
      );

      // A new store, channel and service over the same platform state: this is
      // what the next app start does.
      final restarted = await buildService().load();
      expect(restarted, isA<G2dIdentityActive>());
      expect(
        (restarted as G2dIdentityActive).record.publicKeyFingerprint,
        firstFingerprint,
      );
    });

    test('a rotation survives a restart only once it is completed', () async {
      final service = buildService();
      await service.createIdentity(
        algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
        publicKeyFingerprint: firstFingerprint,
        keyHandle: handleWith(G2dKeyProtection.softwareKeystoreWrapped),
      );
      await service.beginRotation(
        algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
        newPublicKeyFingerprint: secondFingerprint,
        newKeyHandle: handleWith(G2dKeyProtection.softwareKeystoreWrapped),
      );

      final restartedPending = await buildService().load();
      expect(restartedPending, isA<G2dIdentityRotationPending>());

      await buildService().completeRotation();
      final restartedActive = await buildService().load();
      expect(restartedActive, isA<G2dIdentityActive>());
      expect(
        (restartedActive as G2dIdentityActive).record.publicKeyFingerprint,
        secondFingerprint,
      );
    });

    test('corruption is reported and never silently repaired', () async {
      await buildService().createIdentity(
        algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
        publicKeyFingerprint: firstFingerprint,
        keyHandle: handleWith(G2dKeyProtection.softwareKeystoreWrapped),
      );
      platform.storedPayload = 'tampered';

      final snapshot = await buildService().load();
      expect(snapshot, isA<G2dIdentityCorrupt>());
      // Nothing was rewritten and nothing was recreated.
      expect(platform.storedPayload, 'tampered');
      expect(platform.saveCount, 1);
    });

    test('a missing wrapping key is corruption, not a fresh identity', () async {
      platform.storedPayload = 'ciphertext-of-the-old-record';
      platform.persistentLoadFailure = PlatformException(
        code: G2dIdentityChannelError.keyMissing,
        message: 'encrypted identity data exists but its wrapping key is missing',
      );
      final snapshot = await buildService().load();
      expect(snapshot, isA<G2dIdentityCorrupt>());

      // Creating a new identity on top must be refused: the old record still
      // occupies storage and was never proven unusable.
      final created = await buildService().createIdentity(
        algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
        publicKeyFingerprint: firstFingerprint,
        keyHandle: handleWith(G2dKeyProtection.softwareKeystoreWrapped),
      );
      expect(created.isSuccess, isFalse);
    });

    test('corruption is cleared only by an explicit reset', () async {
      platform.storedPayload = 'tampered';
      final service = buildService();
      expect(await service.load(), isA<G2dIdentityCorrupt>());

      final reset = await service.resetCorruptIdentity();
      expect(reset.isSuccess, isTrue);
      expect(reset.record, isNull);
      expect(platform.storedPayload, isNull);
      expect(await service.load(), isA<G2dIdentityAbsent>());
    });

    test('a reset allows a deliberate new identity', () async {
      platform.storedPayload = 'tampered';
      final service = buildService();
      await service.resetCorruptIdentity();

      final created = await service.createIdentity(
        algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
        publicKeyFingerprint: firstFingerprint,
        keyHandle: handleWith(G2dKeyProtection.softwareKeystoreWrapped),
      );
      expect(created.isSuccess, isTrue);
      expect(await service.load(), isA<G2dIdentityActive>());
    });

    test('a failed write leaves the previous record current', () async {
      final service = buildService();
      await service.createIdentity(
        algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
        publicKeyFingerprint: firstFingerprint,
        keyHandle: handleWith(G2dKeyProtection.softwareKeystoreWrapped),
      );
      platform.failSaveOnce = true;

      final rotation = await service.beginRotation(
        algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
        newPublicKeyFingerprint: secondFingerprint,
        newKeyHandle: handleWith(G2dKeyProtection.softwareKeystoreWrapped),
      );
      expect(rotation.isSuccess, isFalse);
      expect(rotation.failure, G2dIdentityFailure.storageWriteFailed);

      final snapshot = await buildService().load();
      expect(snapshot, isA<G2dIdentityActive>());
      expect(
        (snapshot as G2dIdentityActive).record.publicKeyFingerprint,
        firstFingerprint,
      );
    });

    test('the persisted payload carries no key material', () async {
      await buildService().createIdentity(
        algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
        publicKeyFingerprint: firstFingerprint,
        keyHandle: handleWith(G2dKeyProtection.softwareKeystoreWrapped),
      );
      final payload = platform.savedPayloads.single;
      expect(
        payload.keys.toSet(),
        <String>{
          'recordVersion',
          'identityId',
          'keyVersion',
          'algorithm',
          'publicKeyFingerprint',
          'keyHandle',
          'state',
          'createdAtMillis',
        },
      );
      final handle = payload['keyHandle']! as Map<String, Object?>;
      expect(
        handle.keys.toSet(),
        <String>{'provider', 'alias', 'protection', 'probeVerified'},
      );
      // A handle is a lookup name; nothing in the payload may look like bytes.
      for (final value in payload.values) {
        expect(value, isNot(isA<List<int>>()));
      }
      final stored = platform.storedPayload;
      expect(stored, isNotNull);
      expect(stored!, isNot(contains('private')));
      expect(stored, isNot(contains('secret')));
    });
  });
}
