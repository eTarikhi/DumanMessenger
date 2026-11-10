/// G2-D identity lifecycle service.
///
/// The service owns *record* transitions: create, rotate, revoke, reset. It owns
/// no key material — key generation and fingerprinting belong to the crypto
/// provider, which is selected separately (see the architecture decision).
///
/// Failure policy: every public operation returns a typed result and never
/// throws for an expected condition. A failed write is never treated as a
/// success, and a corrupt record is never repaired or replaced implicitly.
library;

import 'dart:math';

import 'identity_models.dart';
import 'identity_store.dart';

/// State of the local identity as observed by the app.
sealed class G2dIdentitySnapshot {
  const G2dIdentitySnapshot();
}

/// No identity exists yet. Nothing is implied about peers or sessions.
class G2dIdentityAbsent extends G2dIdentitySnapshot {
  const G2dIdentityAbsent();
}

/// An active identity exists and may be used to open sessions.
class G2dIdentityActive extends G2dIdentitySnapshot {
  const G2dIdentityActive(this.record);

  final G2dIdentityRecord record;
}

/// A rotation was started and must be completed (or the identity revoked)
/// before any session is opened.
class G2dIdentityRotationPending extends G2dIdentitySnapshot {
  const G2dIdentityRotationPending(this.record);

  final G2dIdentityRecord record;
}

/// The identity is revoked. It is terminal; creating a new identity requires
/// [G2dIdentityService.resetRevokedIdentity] first.
class G2dIdentityRevoked extends G2dIdentitySnapshot {
  const G2dIdentityRevoked(this.record);

  final G2dIdentityRecord record;
}

/// Storage cannot be read on this build/device. No identity is assumed.
class G2dIdentityStorageUnavailable extends G2dIdentitySnapshot {
  const G2dIdentityStorageUnavailable(this.reason);

  final String reason;
}

/// A record exists but cannot be trusted. The app must not continue as if an
/// identity were usable, and must not create a replacement silently.
class G2dIdentityCorrupt extends G2dIdentitySnapshot {
  const G2dIdentityCorrupt(this.reason);

  final String reason;
}

/// Why an identity operation was refused.
enum G2dIdentityFailure {
  identityExists,
  revokedNeedsReset,
  noIdentity,
  notActive,
  notRotationPending,
  notRevoked,
  fingerprintUnchanged,
  invalidFingerprint,
  unverifiedProtection,
  storageUnavailable,
  storageCorrupt,
  storageWriteFailed,
}

/// Result of a lifecycle operation.
class G2dIdentityActionResult {
  const G2dIdentityActionResult.success(G2dIdentityRecord this.record)
      : failure = null,
        detail = null;

  const G2dIdentityActionResult.failure(G2dIdentityFailure this.failure, [this.detail])
      : record = null;

  final G2dIdentityRecord? record;
  final G2dIdentityFailure? failure;
  final String? detail;

  bool get isSuccess => failure == null;
}

/// Orchestrates identity records over a [G2dIdentityStore].
class G2dIdentityService {
  G2dIdentityService({
    required this.store,
    int Function()? nowMillis,
    String Function()? newIdentityId,
  })  : _nowMillis = nowMillis ?? _systemMillis,
        _newIdentityId = newIdentityId ?? _randomIdentityId;

  final G2dIdentityStore store;
  final int Function() _nowMillis;
  final String Function() _newIdentityId;

  /// Description of the backing store, for diagnostics. Not a security claim.
  String get storeKind => store.storeKind;

  /// Whether the backing store protects the record at rest. Test doubles and the
  /// unavailable placeholder both report `false`.
  bool get isSecureAtRest => store.isSecureAtRest;

  /// Reads the current identity. Never throws for storage problems: those are
  /// reported as typed snapshots so callers cannot mistake an error for success.
  Future<G2dIdentitySnapshot> load() async {
    final loaded = await _load();
    if (loaded.failure != null) {
      final reason = loaded.failure!.detail ?? loaded.failure!.failure!.name;
      return switch (loaded.failure!.failure) {
        G2dIdentityFailure.storageUnavailable => G2dIdentityStorageUnavailable(reason),
        _ => G2dIdentityCorrupt(reason),
      };
    }
    final record = loaded.record;
    if (record == null) {
      return const G2dIdentityAbsent();
    }
    return switch (record.state) {
      G2dIdentityState.active => G2dIdentityActive(record),
      G2dIdentityState.rotationPending => G2dIdentityRotationPending(record),
      G2dIdentityState.revoked => G2dIdentityRevoked(record),
    };
  }

  /// Creates the first identity for this installation.
  ///
  /// Refused when an active or rotation-pending identity already exists. A
  /// revoked identity is terminal for that identity, not for the installation:
  /// [resetRevokedIdentity] must run first so that a revocation is never
  /// silently replaced by a fresh key.
  Future<G2dIdentityActionResult> createIdentity({
    required G2dIdentityAlgorithm algorithm,
    required String publicKeyFingerprint,
    required G2dKeyHandle keyHandle,
    String? identityId,
  }) async {
    if (!G2dIdentityRecord.isValidFingerprint(publicKeyFingerprint)) {
      return const G2dIdentityActionResult.failure(G2dIdentityFailure.invalidFingerprint);
    }
    if (keyHandle.protection == G2dKeyProtection.unknown || !keyHandle.probeVerified) {
      // An identity whose protection we cannot state, or cannot evidence, is not
      // usable. Failing here stops "unknown" or an inference from ever becoming a
      // persisted active identity.
      return const G2dIdentityActionResult.failure(
        G2dIdentityFailure.unverifiedProtection,
        'key protection must be probed before an identity is created',
      );
    }

    final loaded = await _load();
    if (loaded.failure != null) {
      return loaded.failure!;
    }
    final existing = loaded.record;
    if (existing != null) {
      return G2dIdentityActionResult.failure(
        existing.state == G2dIdentityState.revoked
            ? G2dIdentityFailure.revokedNeedsReset
            : G2dIdentityFailure.identityExists,
        existing.state == G2dIdentityState.revoked
            ? 'revoked identity must be reset before a new one is created'
            : 'an identity already exists',
      );
    }

    final record = G2dIdentityRecord(
      identityId: identityId ?? _newIdentityId(),
      keyVersion: 1,
      algorithm: algorithm,
      publicKeyFingerprint: publicKeyFingerprint,
      keyHandle: keyHandle,
      state: G2dIdentityState.active,
      createdAtMillis: _nowMillis(),
    );
    return _commit(record);
  }

  /// Starts a key rotation. The identity becomes [G2dIdentityState.rotationPending]
  /// and is not usable until [completeRotation] runs.
  ///
  /// There is intentionally no "abort": once the provider may have replaced the
  /// old key, reverting would mean claiming an identity the device may no longer
  /// hold. Complete the rotation or revoke.
  Future<G2dIdentityActionResult> beginRotation({
    required G2dIdentityAlgorithm algorithm,
    required String newPublicKeyFingerprint,
    required G2dKeyHandle newKeyHandle,
  }) async {
    if (!G2dIdentityRecord.isValidFingerprint(newPublicKeyFingerprint)) {
      return const G2dIdentityActionResult.failure(G2dIdentityFailure.invalidFingerprint);
    }
    if (newKeyHandle.protection == G2dKeyProtection.unknown || !newKeyHandle.probeVerified) {
      return const G2dIdentityActionResult.failure(
        G2dIdentityFailure.unverifiedProtection,
        'key protection must be probed before rotating',
      );
    }
    final loaded = await _load();
    if (loaded.failure != null) {
      return loaded.failure!;
    }
    final existing = loaded.record;
    if (existing == null) {
      return const G2dIdentityActionResult.failure(G2dIdentityFailure.noIdentity);
    }
    if (existing.state != G2dIdentityState.active) {
      return const G2dIdentityActionResult.failure(G2dIdentityFailure.notActive);
    }
    if (existing.publicKeyFingerprint == newPublicKeyFingerprint) {
      return const G2dIdentityActionResult.failure(G2dIdentityFailure.fingerprintUnchanged);
    }

    final rotated = existing.copyWith(
      keyVersion: existing.keyVersion + 1,
      algorithm: algorithm,
      publicKeyFingerprint: newPublicKeyFingerprint,
      keyHandle: newKeyHandle,
      state: G2dIdentityState.rotationPending,
      previousKeyFingerprint: existing.publicKeyFingerprint,
      rotatedAtMillis: _nowMillis(),
    );
    return _commit(rotated);
  }

  /// Promotes a pending rotation to active.
  Future<G2dIdentityActionResult> completeRotation() async {
    final loaded = await _load();
    if (loaded.failure != null) {
      return loaded.failure!;
    }
    final existing = loaded.record;
    if (existing == null) {
      return const G2dIdentityActionResult.failure(G2dIdentityFailure.noIdentity);
    }
    if (existing.state != G2dIdentityState.rotationPending) {
      return const G2dIdentityActionResult.failure(G2dIdentityFailure.notRotationPending);
    }
    return _commit(existing.copyWith(state: G2dIdentityState.active));
  }

  /// Revokes the identity. Terminal: no operation can revive it.
  Future<G2dIdentityActionResult> revoke(G2dRevocationReason reason) async {
    final loaded = await _load();
    if (loaded.failure != null) {
      return loaded.failure!;
    }
    final existing = loaded.record;
    if (existing == null) {
      return const G2dIdentityActionResult.failure(G2dIdentityFailure.noIdentity);
    }
    if (existing.state == G2dIdentityState.revoked) {
      return G2dIdentityActionResult.success(existing);
    }
    return _commit(existing.copyWith(
      state: G2dIdentityState.revoked,
      revokedAtMillis: _nowMillis(),
      revocationReason: reason,
    ));
  }

  /// Deletes a revoked record so that a new identity can be created.
  ///
  /// Only valid for revoked identities: deleting an active record would let a
  /// restart look like a fresh install and silently discard a live identity.
  Future<G2dIdentityActionResult> resetRevokedIdentity() async {
    final loaded = await _load();
    if (loaded.failure != null) {
      return loaded.failure!;
    }
    final existing = loaded.record;
    if (existing == null) {
      return const G2dIdentityActionResult.failure(G2dIdentityFailure.noIdentity);
    }
    if (existing.state != G2dIdentityState.revoked) {
      return const G2dIdentityActionResult.failure(G2dIdentityFailure.notRevoked);
    }
    try {
      await store.delete();
    } on G2dIdentityStoreUnavailable catch (error) {
      return G2dIdentityActionResult.failure(
        G2dIdentityFailure.storageUnavailable,
        error.reason,
      );
    } on G2dIdentityStoreWriteFailed catch (error) {
      return G2dIdentityActionResult.failure(
        G2dIdentityFailure.storageWriteFailed,
        error.reason,
      );
    }
    return G2dIdentityActionResult.success(existing);
  }

  Future<_Loaded> _load() async {
    try {
      return _Loaded.record(await store.load());
    } on G2dIdentityStoreUnavailable catch (error) {
      return _Loaded.failure(G2dIdentityActionResult.failure(
        G2dIdentityFailure.storageUnavailable,
        error.reason,
      ));
    } on G2dIdentityStoreCorrupt catch (error) {
      return _Loaded.failure(G2dIdentityActionResult.failure(
        G2dIdentityFailure.storageCorrupt,
        error.reason,
      ));
    }
  }

  Future<G2dIdentityActionResult> _commit(G2dIdentityRecord record) async {
    try {
      await store.save(record);
    } on G2dIdentityStoreUnavailable catch (error) {
      return G2dIdentityActionResult.failure(
        G2dIdentityFailure.storageUnavailable,
        error.reason,
      );
    } on G2dIdentityStoreCorrupt catch (error) {
      return G2dIdentityActionResult.failure(
        G2dIdentityFailure.storageCorrupt,
        error.reason,
      );
    } on G2dIdentityStoreWriteFailed catch (error) {
      return G2dIdentityActionResult.failure(
        G2dIdentityFailure.storageWriteFailed,
        error.reason,
      );
    }
    return G2dIdentityActionResult.success(record);
  }

  static int _systemMillis() => DateTime.now().toUtc().millisecondsSinceEpoch;

  static String _randomIdentityId() {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var index = 0; index < 16; index += 1) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

class _Loaded {
  const _Loaded.record(this.record) : failure = null;

  const _Loaded.failure(this.failure) : record = null;

  final G2dIdentityRecord? record;
  final G2dIdentityActionResult? failure;
}
