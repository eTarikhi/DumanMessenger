import 'package:duman_messenger/identity/identity_models.dart';
import 'package:duman_messenger/identity/identity_service.dart';
import 'package:duman_messenger/identity/identity_store.dart';
import 'package:duman_messenger/identity/platform_key_capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

String fingerprint(String nibble) => List<String>.filled(64, nibble).join();

const G2dKeyHandle probedHandle = G2dKeyHandle(
  provider: 'android_keystore',
  alias: 'g2d.identity.v1',
  protection: G2dKeyProtection.softwareKeystoreWrapped,
  probeVerified: true,
);

const G2dKeyHandle unprobedHandle = G2dKeyHandle(
  provider: 'android_keystore',
  alias: 'g2d.identity.v1',
  protection: G2dKeyProtection.softwareKeystoreWrapped,
);

/// A handle that claims secure hardware. Whether that claim is *possible* is a
/// platform question, which the service asks the injected capabilities.
const G2dKeyHandle hardwareHandle = G2dKeyHandle(
  provider: 'android_keystore',
  alias: 'g2d.identity.hardware',
  protection: G2dKeyProtection.hardwareBound,
  probeVerified: true,
);

const G2dKeyHandle unknownProtectionHandle = G2dKeyHandle(
  provider: 'android_keystore',
  alias: 'g2d.identity.v1',
  protection: G2dKeyProtection.unknown,
);

class Harness {
  Harness({G2dIdentityStore? store, int apiLevel = 27})
      : store = store ?? G2dInMemoryIdentityStore() {
    service = G2dIdentityService(
      store: this.store,
      platform: G2dAndroidKeyCapabilities(apiLevel),
      // The double persists nothing and protects nothing; tests must say so.
      allowInsecureStore: true,
      nowMillis: () => now,
      newIdentityId: () => 'identity-${++_ids}',
    );
  }

  final G2dIdentityStore store;
  late final G2dIdentityService service;
  int _ids = 0;

  /// Clock the service reads. Tests move it to model a clock rollback.
  int now = 5000;

  Future<G2dIdentityActionResult> create({
    String fp = 'a',
    G2dKeyHandle handle = probedHandle,
  }) =>
      service.createIdentity(
        algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
        publicKeyFingerprint: fingerprint(fp),
        keyHandle: handle,
      );

  Future<G2dIdentityActionResult> rotate({String fp = 'b', G2dKeyHandle handle = probedHandle}) =>
      service.beginRotation(
        algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
        newPublicKeyFingerprint: fingerprint(fp),
        newKeyHandle: handle,
      );
}

void main() {
  group('creation', () {
    test('reports absence before any identity exists', () async {
      final harness = Harness();
      expect(await harness.service.load(), isA<G2dIdentityAbsent>());
    });

    test('creates a version 1 active identity and persists it', () async {
      final harness = Harness();
      final result = await harness.create();

      expect(result.isSuccess, isTrue);
      expect(result.record!.keyVersion, 1);
      expect(result.record!.state, G2dIdentityState.active);
      expect(result.record!.createdAtMillis, 5000);
      expect(result.record!.identityId, 'identity-1');

      final snapshot = await harness.service.load();
      expect(snapshot, isA<G2dIdentityActive>());
      expect((snapshot as G2dIdentityActive).record, result.record);
    });

    test('refuses an invalid fingerprint and stores nothing', () async {
      final harness = Harness();
      final result = await harness.service.createIdentity(
        algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
        publicKeyFingerprint: 'not-a-fingerprint',
        keyHandle: probedHandle,
      );

      expect(result.failure, G2dIdentityFailure.invalidFingerprint);
      expect(await harness.store.load(), isNull);
    });

    test('refuses an unprobed key protection claim', () async {
      final harness = Harness();
      final result = await harness.create(handle: unprobedHandle);

      expect(result.failure, G2dIdentityFailure.unverifiedProtection);
      expect(result.detail, contains('probed'));
      expect(await harness.store.load(), isNull);
    });

    test('refuses an unknown key protection', () async {
      final harness = Harness();
      final result = await harness.create(handle: unknownProtectionHandle);
      expect(result.failure, G2dIdentityFailure.unverifiedProtection);
    });

    test('refuses to replace an existing active identity', () async {
      final harness = Harness();
      await harness.create();
      final second = await harness.create(fp: 'b');

      expect(second.failure, G2dIdentityFailure.identityExists);
      expect((await harness.store.load())!.publicKeyFingerprint, fingerprint('a'));
    });

    test('refuses to silently replace a revoked identity', () async {
      final harness = Harness();
      await harness.create();
      await harness.service.revoke(G2dRevocationReason.userRequested);

      final second = await harness.create(fp: 'b');
      expect(second.failure, G2dIdentityFailure.revokedNeedsReset);
    });

    test('the app default store refuses to create anything', () async {
      final harness = Harness(store: const G2dUnavailableIdentityStore());
      final result = await harness.create();

      expect(result.failure, G2dIdentityFailure.storageUnavailable);
      expect(await harness.service.load(), isA<G2dIdentityStorageUnavailable>());
    });
  });

  group('rotation', () {
    test('moves to rotationPending with a recorded previous fingerprint', () async {
      final harness = Harness();
      await harness.create();

      final result = await harness.rotate();
      expect(result.isSuccess, isTrue);
      expect(result.record!.state, G2dIdentityState.rotationPending);
      expect(result.record!.keyVersion, 2);
      expect(result.record!.previousKeyFingerprint, fingerprint('a'));
      expect(result.record!.publicKeyFingerprint, fingerprint('b'));
      expect(result.record!.rotatedAtMillis, 5000);
      expect(result.record!.isUsable, isFalse);

      expect(await harness.service.load(), isA<G2dIdentityRotationPending>());
    });

    test('refuses a rotation that keeps the same fingerprint', () async {
      final harness = Harness();
      await harness.create();
      final result = await harness.rotate(fp: 'a');

      expect(result.failure, G2dIdentityFailure.fingerprintUnchanged);
    });

    test('refuses to rotate without an identity', () async {
      final harness = Harness();
      expect((await harness.rotate()).failure, G2dIdentityFailure.noIdentity);
    });

    test('refuses a second rotation while one is pending', () async {
      final harness = Harness();
      await harness.create();
      await harness.rotate();
      final second = await harness.rotate(fp: 'c');

      expect(second.failure, G2dIdentityFailure.notActive);
    });

    test('completes a rotation and makes the identity usable again', () async {
      final harness = Harness();
      await harness.create();
      await harness.rotate();

      final completed = await harness.service.completeRotation();
      expect(completed.isSuccess, isTrue);
      expect(completed.record!.state, G2dIdentityState.active);
      expect(completed.record!.isUsable, isTrue);
      expect(await harness.service.load(), isA<G2dIdentityActive>());
    });

    test('refuses to complete a rotation that is not pending', () async {
      final harness = Harness();
      await harness.create();
      expect(
        (await harness.service.completeRotation()).failure,
        G2dIdentityFailure.notRotationPending,
      );
    });

    test('refuses to rotate if the new key protection is unprobed', () async {
      final harness = Harness();
      await harness.create();
      final result = await harness.rotate(handle: unprobedHandle);

      expect(result.failure, G2dIdentityFailure.unverifiedProtection);
      expect((await harness.store.load())!.keyVersion, 1);
    });
  });

  group('revocation', () {
    test('revokes an active identity with reason and time', () async {
      final harness = Harness();
      await harness.create();

      final result = await harness.service.revoke(G2dRevocationReason.compromised);
      expect(result.isSuccess, isTrue);
      expect(result.record!.state, G2dIdentityState.revoked);
      expect(result.record!.revocationReason, G2dRevocationReason.compromised);
      expect(result.record!.revokedAtMillis, 5000);
      expect(result.record!.isUsable, isFalse);
      expect(await harness.service.load(), isA<G2dIdentityRevoked>());
    });

    test('revocation is idempotent', () async {
      final harness = Harness();
      await harness.create();
      final first = await harness.service.revoke(G2dRevocationReason.userRequested);
      final second = await harness.service.revoke(G2dRevocationReason.compromised);

      expect(second.isSuccess, isTrue);
      expect(second.record!.revocationReason, G2dRevocationReason.userRequested);
      expect(second.record, first.record);
    });

    test('can revoke an identity whose rotation is pending', () async {
      final harness = Harness();
      await harness.create();
      await harness.rotate();

      final result = await harness.service.revoke(G2dRevocationReason.userRequested);
      expect(result.record!.state, G2dIdentityState.revoked);
    });

    test('refuses to revoke without an identity', () async {
      final harness = Harness();
      expect(
        (await harness.service.revoke(G2dRevocationReason.userRequested)).failure,
        G2dIdentityFailure.noIdentity,
      );
    });

    test('reset is only allowed for a revoked identity', () async {
      final harness = Harness();
      await harness.create();
      expect(
        (await harness.service.resetRevokedIdentity()).failure,
        G2dIdentityFailure.notRevoked,
      );

      await harness.service.revoke(G2dRevocationReason.userRequested);
      final reset = await harness.service.resetRevokedIdentity();
      expect(reset.isSuccess, isTrue);
      expect(await harness.store.load(), isNull);
      expect(await harness.service.load(), isA<G2dIdentityAbsent>());
    });

    test('a new identity may be created after a reset', () async {
      final harness = Harness();
      await harness.create();
      await harness.service.revoke(G2dRevocationReason.userRequested);
      await harness.service.resetRevokedIdentity();

      final second = await harness.create(fp: 'c');
      expect(second.isSuccess, isTrue);
      expect(second.record!.identityId, 'identity-2');
      expect(second.record!.keyVersion, 1);
    });
  });

  group('store construction', () {
    test('refuses an insecure store unless the caller opts in', () {
      expect(
        () => G2dIdentityService(
          store: G2dInMemoryIdentityStore(),
          platform: const G2dAndroidKeyCapabilities(27),
        ),
        throwsArgumentError,
      );
    });

    test('refuses the fail-closed placeholder unless the caller opts in', () {
      expect(
        () => G2dIdentityService(
          store: const G2dUnavailableIdentityStore(),
          platform: const G2dAndroidKeyCapabilities(27),
        ),
        throwsArgumentError,
      );
    });

    test('accepts an insecure store only with an explicit acknowledgement', () {
      final service = G2dIdentityService(
        store: G2dInMemoryIdentityStore(),
        platform: const G2dAndroidKeyCapabilities(27),
        allowInsecureStore: true,
      );

      expect(service.isSecureAtRest, isFalse);
      expect(service.storeKind, 'in_memory_test_only');
      expect(service.apiLevel, 27);
    });
  });

  group('platform capabilities', () {
    test('refuses a hardware-bound Ed25519 claim at the API 27 floor', () async {
      final harness = Harness();
      final result = await harness.service.createIdentity(
        algorithm: G2dIdentityAlgorithm.ed25519,
        publicKeyFingerprint: fingerprint('a'),
        keyHandle: hardwareHandle,
      );

      expect(result.failure, G2dIdentityFailure.unverifiedProtection);
      expect(result.detail, contains('cannot hold'));
      expect(await harness.store.load(), isNull);
    });

    test('accepts a hardware-bound Ed25519 claim on API 33', () async {
      final harness = Harness(apiLevel: 33);
      final result = await harness.service.createIdentity(
        algorithm: G2dIdentityAlgorithm.ed25519,
        publicKeyFingerprint: fingerprint('a'),
        keyHandle: hardwareHandle,
      );

      expect(result.isSuccess, isTrue);
      expect(await harness.service.load(), isA<G2dIdentityActive>());
    });

    test('refuses a hardware-bound Curve25519 claim on any API level', () async {
      final harness = Harness(apiLevel: 34);
      final result = await harness.service.createIdentity(
        algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
        publicKeyFingerprint: fingerprint('a'),
        keyHandle: hardwareHandle,
      );

      expect(result.failure, G2dIdentityFailure.unverifiedProtection);
      expect(result.detail, contains('cannot hold'));
    });

    test('accepts a software-wrapped identity at the floor', () async {
      final harness = Harness();
      final result = await harness.create();
      expect(result.isSuccess, isTrue);
      expect(result.record!.keyHandle.protection,
          G2dKeyProtection.softwareKeystoreWrapped);
    });

    test('refuses an impossible hardware claim when rotating', () async {
      final harness = Harness();
      await harness.create();

      final result = await harness.service.beginRotation(
        algorithm: G2dIdentityAlgorithm.ed25519,
        newPublicKeyFingerprint: fingerprint('b'),
        newKeyHandle: hardwareHandle,
      );

      expect(result.failure, G2dIdentityFailure.unverifiedProtection);
      expect((await harness.store.load())!.keyVersion, 1);
      expect(await harness.service.load(), isA<G2dIdentityActive>());
    });

    test('a stored claim this platform cannot satisfy is rejected on load', () async {
      final harness = Harness();
      // Model a record restored from a stronger device: an Ed25519 identity that
      // claims secure hardware, now running at the API 27 floor.
      await harness.store.save(G2dIdentityRecord(
        identityId: 'identity-0',
        keyVersion: 1,
        algorithm: G2dIdentityAlgorithm.ed25519,
        publicKeyFingerprint: fingerprint('b'),
        keyHandle: hardwareHandle,
        state: G2dIdentityState.active,
        createdAtMillis: 1000,
      ));

      expect(await harness.service.load(), isA<G2dIdentityCorrupt>());
      expect(
        (await harness.create()).failure,
        G2dIdentityFailure.protectionInvalid,
      );

      expect((await harness.service.resetCorruptIdentity()).isSuccess, isTrue);
      expect(await harness.service.load(), isA<G2dIdentityAbsent>());
    });

    test('a platform limit and missing evidence are reported differently', () {
      const api27 = G2dAndroidKeyCapabilities(27);

      expect(
        api27.describeProtectionFor(
          G2dIdentityAlgorithm.x25519,
          G2dKeyProtection.hardwareBound,
        ),
        contains('cannot hold'),
      );
      expect(
        api27.describeProtectionFor(
          G2dIdentityAlgorithm.ed25519,
          G2dKeyProtection.unknown,
        ),
        contains('unknown'),
      );
      expect(
        api27.describeProtectionFor(
          G2dIdentityAlgorithm.ed25519,
          G2dKeyProtection.softwareKeystoreWrapped,
        ),
        isNull,
      );
      expect(api27.isHardwarePossible(G2dIdentityAlgorithm.ed25519), isFalse);
      expect(api27.isHardwarePossible(G2dIdentityAlgorithm.x25519), isFalse);
    });
  });

  group('corruption recovery', () {
    test('resetCorruptIdentity deletes an unreadable record and recreates nothing', () async {
      final harness = Harness();
      (harness.store as G2dInMemoryIdentityStore).corruptStoredValue();
      expect(await harness.service.load(), isA<G2dIdentityCorrupt>());

      final reset = await harness.service.resetCorruptIdentity();
      expect(reset.isSuccess, isTrue);
      expect(reset.record, isNull);
      expect(await harness.store.load(), isNull);

      // Recovery is deletion only: the next read must be absence, not a silently
      // regenerated identity.
      expect(await harness.service.load(), isA<G2dIdentityAbsent>());

      final created = await harness.create(fp: 'c');
      expect(created.isSuccess, isTrue);
      expect(created.record!.state, G2dIdentityState.active);
    });

    test('resetCorruptIdentity refuses a readable identity and keeps it', () async {
      final harness = Harness();
      await harness.create();

      final reset = await harness.service.resetCorruptIdentity();
      expect(reset.failure, G2dIdentityFailure.notCorrupt);
      expect((await harness.store.load())!.publicKeyFingerprint, fingerprint('a'));
      expect(await harness.service.load(), isA<G2dIdentityActive>());
    });

    test('resetCorruptIdentity refuses a revoked identity', () async {
      final harness = Harness();
      await harness.create();
      await harness.service.revoke(G2dRevocationReason.userRequested);

      // A revoked record is readable evidence; discarding it is a different
      // decision (resetRevokedIdentity), not corruption recovery.
      expect(
        (await harness.service.resetCorruptIdentity()).failure,
        G2dIdentityFailure.notCorrupt,
      );
    });

    test('resetCorruptIdentity never treats unavailable storage as corruption', () async {
      final harness = Harness(store: const G2dUnavailableIdentityStore());

      final reset = await harness.service.resetCorruptIdentity();
      expect(reset.failure, G2dIdentityFailure.storageUnavailable);
    });

    test('resetCorruptIdentity reports absence when there is no record', () async {
      final harness = Harness();
      expect(
        (await harness.service.resetCorruptIdentity()).failure,
        G2dIdentityFailure.noIdentity,
      );
    });

    test('a reset never reports the removed identity as the current one', () async {
      final harness = Harness();
      await harness.create();
      await harness.service.revoke(G2dRevocationReason.userRequested);

      final reset = await harness.service.resetRevokedIdentity();
      expect(reset.isSuccess, isTrue);
      expect(reset.record, isNull);
      expect(await harness.service.load(), isA<G2dIdentityAbsent>());
    });

    test('a removed identity id cannot be reused by a new identity', () async {
      final harness = Harness();
      await harness.create();
      await harness.service.revoke(G2dRevocationReason.userRequested);
      await harness.service.resetRevokedIdentity();

      final reuse = await harness.service.createIdentity(
        algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
        publicKeyFingerprint: fingerprint('c'),
        keyHandle: probedHandle,
        identityId: 'identity-1',
      );
      expect(reuse.failure, G2dIdentityFailure.identityIdRetired);
      expect(await harness.store.load(), isNull);
    });
  });

  group('commit validation', () {
    test('a rotation that would produce an inconsistent record is refused', () async {
      final harness = Harness();
      await harness.create();

      // Clock rollback: the rotation would be stamped before the creation time,
      // which the record invariants forbid.
      harness.now = 4000;
      final result = await harness.rotate();

      expect(result.failure, G2dIdentityFailure.invalidRecord);
      expect((await harness.store.load())!.keyVersion, 1);
      expect(await harness.service.load(), isA<G2dIdentityActive>());
    });

    test('nothing is written when validation fails', () async {
      final harness = Harness();
      await harness.create();
      final store = harness.store as G2dInMemoryIdentityStore;
      final writesBefore = store.committedWrites;

      harness.now = 1;
      await harness.rotate();

      expect(store.committedWrites, writesBefore);
    });

    test('a failed write during rotation leaves the previous identity usable', () async {
      final harness = Harness();
      await harness.create();
      (harness.store as G2dInMemoryIdentityStore).failNextWrite = true;

      final result = await harness.rotate();

      expect(result.failure, G2dIdentityFailure.storageWriteFailed);
      final snapshot = await harness.service.load();
      expect(snapshot, isA<G2dIdentityActive>());
      expect((snapshot as G2dIdentityActive).record.keyVersion, 1);
    });

    test('an unverified pending rotation is rejected at load and needs recovery', () async {
      final harness = Harness();
      // Model an adapter that accepted a record the service would have refused:
      // a pending rotation whose key protection was never probed.
      await harness.store.save(G2dIdentityRecord(
        identityId: 'identity-0',
        keyVersion: 2,
        algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
        publicKeyFingerprint: fingerprint('b'),
        keyHandle: const G2dKeyHandle(
          provider: 'android_keystore',
          alias: 'g2d.identity.v1',
          protection: G2dKeyProtection.unknown,
        ),
        state: G2dIdentityState.rotationPending,
        createdAtMillis: 1000,
        rotatedAtMillis: 2000,
        previousKeyFingerprint: fingerprint('a'),
      ));

      expect(await harness.service.load(), isA<G2dIdentityCorrupt>());
      expect(
        (await harness.service.completeRotation()).failure,
        G2dIdentityFailure.storageCorrupt,
      );
      expect((await harness.service.resetCorruptIdentity()).isSuccess, isTrue);
      expect(await harness.service.load(), isA<G2dIdentityAbsent>());
    });
  });

  group('storage failures', () {
    test('a failed write is reported and leaves no identity behind', () async {
      final harness = Harness();
      (harness.store as G2dInMemoryIdentityStore).failNextWrite = true;

      final result = await harness.create();
      expect(result.failure, G2dIdentityFailure.storageWriteFailed);
      expect(await harness.service.load(), isA<G2dIdentityAbsent>());
    });

    test('a non-atomic write is visible as corruption, not as a silent revert', () async {
      final harness = Harness();
      await harness.create();
      (harness.store as G2dInMemoryIdentityStore).destructiveNextWrite = true;

      final result = await harness.service.revoke(G2dRevocationReason.userRequested);
      expect(result.failure, G2dIdentityFailure.storageWriteFailed);
      expect(await harness.service.load(), isA<G2dIdentityCorrupt>());
    });

    test('corrupt storage is reported and blocks lifecycle changes', () async {
      final harness = Harness();
      (harness.store as G2dInMemoryIdentityStore).corruptStoredValue();

      expect(await harness.service.load(), isA<G2dIdentityCorrupt>());
      final result = await harness.create();
      expect(result.failure, G2dIdentityFailure.storageCorrupt);
    });

    test('a partial write is reported as corruption', () async {
      final harness = Harness();
      (harness.store as G2dInMemoryIdentityStore).simulatePartialWrite();

      final snapshot = await harness.service.load();
      expect(snapshot, isA<G2dIdentityCorrupt>());
      expect((snapshot as G2dIdentityCorrupt).reason, isNotEmpty);
    });

    test('store metadata is exposed for diagnostics without security claims', () {
      final harness = Harness();
      expect(harness.service.storeKind, 'in_memory_test_only');
      expect(harness.service.isSecureAtRest, isFalse);
    });
  });
}
