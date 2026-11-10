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

import 'dart:async';
import 'dart:math';

import 'identity_models.dart';
import 'identity_store.dart';
import 'platform_key_capabilities.dart';

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

  /// The record failed validation before it could be written. Nothing was
  /// persisted and the previous state is unchanged.
  invalidRecord,

  /// An explicit reset was requested for a record that is not corrupt.
  notCorrupt,

  /// The requested identity id belongs to an identity this installation already
  /// removed. A new identity must use a fresh id.
  identityIdRetired,

  /// The stored record claims a key protection this platform cannot provide.
  /// Treated as untrustworthy, and recoverable only through an explicit reset.
  protectionInvalid,
}

/// Result of a lifecycle operation.
class G2dIdentityActionResult {
  const G2dIdentityActionResult.success(G2dIdentityRecord this.record)
      : failure = null,
        detail = null;

  const G2dIdentityActionResult.failure(G2dIdentityFailure this.failure, [this.detail])
      : record = null;

  /// Success for an operation that removed the record (an explicit reset).
  ///
  /// It deliberately carries no record: reporting the deleted identity as the
  /// current one invites a caller to keep using it.
  const G2dIdentityActionResult.successEmpty()
      : record = null,
        failure = null,
        detail = null;

  final G2dIdentityRecord? record;
  final G2dIdentityFailure? failure;
  final String? detail;

  bool get isSuccess => failure == null;
}

/// Orchestrates identity records over a [G2dIdentityStore].
class G2dIdentityService {
  /// Builds the service over [store] and the device's platform facts.
  ///
  /// [allowInsecureStore] exists because the only stores that exist today are a
  /// fail-closed placeholder and a test double, and neither protects anything at
  /// rest. Production construction therefore refuses them by default: passing
  /// `true` is an explicit acknowledgement that this wiring cannot persist a
  /// protected identity, and no UI may present it as persistent or secure.
  G2dIdentityService({
    required this.store,
    required this.platform,
    bool allowInsecureStore = false,
    int Function()? nowMillis,
    String Function()? newIdentityId,
  })  : _nowMillis = nowMillis ?? _systemMillis,
        _newIdentityId = newIdentityId ?? _randomIdentityId {
    if (!store.isSecureAtRest && !allowInsecureStore) {
      throw ArgumentError.value(
        store.storeKind,
        'store',
        'store does not protect the record at rest; pass allowInsecureStore: true '
            'only for tests or an explicitly non-persistent build',
      );
    }
  }

  final G2dIdentityStore store;

  /// Verified platform facts this service checks protection claims against.
  final G2dPlatformKeyCapabilities platform;

  /// API level the injected platform facts describe, for diagnostics only.
  int get apiLevel => platform.apiLevel;

  /// Mutations are serialized: a read-modify-write that interleaves with another
  /// mutation could otherwise commit a record derived from a state that no
  /// longer exists (two concurrent creations both observing "absent", for
  /// example). Reads are not serialized; a store that honours the interface
  /// contract returns a whole record per read.
  Future<void> _tail = Future<void>.value();

  Future<T> _serialize<T>(Future<T> Function() action) async {
    final previous = _tail;
    final gate = Completer<void>();
    _tail = gate.future;
    await previous;
    try {
      return await action();
    } finally {
      gate.complete();
    }
  }

  /// Creates the first identity for this installation (serialized).
  Future<G2dIdentityActionResult> createIdentity({
    required G2dIdentityAlgorithm algorithm,
    required String publicKeyFingerprint,
    required G2dKeyHandle keyHandle,
    String? identityId,
  }) =>
      _serialize(() => _createIdentityImpl(
            algorithm: algorithm,
            publicKeyFingerprint: publicKeyFingerprint,
            keyHandle: keyHandle,
            identityId: identityId,
          ));

  /// Starts a key rotation (serialized).
  Future<G2dIdentityActionResult> beginRotation({
    required G2dIdentityAlgorithm algorithm,
    required String newPublicKeyFingerprint,
    required G2dKeyHandle newKeyHandle,
  }) =>
      _serialize(() => _beginRotationImpl(
            algorithm: algorithm,
            newPublicKeyFingerprint: newPublicKeyFingerprint,
            newKeyHandle: newKeyHandle,
          ));

  /// Promotes a pending rotation to active (serialized).
  Future<G2dIdentityActionResult> completeRotation() =>
      _serialize(_completeRotationImpl);

  /// Revokes the identity (serialized).
  Future<G2dIdentityActionResult> revoke(G2dRevocationReason reason) =>
      _serialize(() => _revokeImpl(reason));

  /// Deletes a readable revoked record (serialized).
  Future<G2dIdentityActionResult> resetRevokedIdentity() =>
      _serialize(_resetRevokedIdentityImpl);

  /// Deletes an untrustworthy record (serialized).
  Future<G2dIdentityActionResult> resetCorruptIdentity() =>
      _serialize(_resetCorruptIdentityImpl);
  final int Function() _nowMillis;
  final String Function() _newIdentityId;

  /// Identity ids that this service instance retired. A new identity may not
  /// reuse one: a peer keyed on the id would otherwise see the revoked identity
  /// "return" with a different key. In-memory only for now; a durable tombstone
  /// is part of the deferred peer/identity store work.
  final Set<String> _retiredIdentityIds = <String>{};

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
  Future<G2dIdentityActionResult> _createIdentityImpl({
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

    final capabilityRefusal =
        platform.describeProtectionFor(algorithm, keyHandle.protection);
    if (capabilityRefusal != null) {
      // The caller may assert that a probe succeeded; this only checks that the
      // claim is possible on this platform at all.
      return G2dIdentityActionResult.failure(
        G2dIdentityFailure.unverifiedProtection,
        capabilityRefusal,
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

    final id = identityId ?? _newIdentityId();
    if (_retiredIdentityIds.contains(id)) {
      return G2dIdentityActionResult.failure(
        G2dIdentityFailure.identityIdRetired,
        'a removed identity already used this id',
      );
    }

    final record = G2dIdentityRecord(
      identityId: id,
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
  Future<G2dIdentityActionResult> _beginRotationImpl({
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
    final capabilityRefusal =
        platform.describeProtectionFor(algorithm, newKeyHandle.protection);
    if (capabilityRefusal != null) {
      return G2dIdentityActionResult.failure(
        G2dIdentityFailure.unverifiedProtection,
        capabilityRefusal,
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
  Future<G2dIdentityActionResult> _completeRotationImpl() async {
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
  Future<G2dIdentityActionResult> _revokeImpl(G2dRevocationReason reason) async {
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
    final result = await _commit(existing.copyWith(
      state: G2dIdentityState.revoked,
      revokedAtMillis: _nowMillis(),
      revocationReason: reason,
    ));
    if (result.isSuccess) {
      _retiredIdentityIds.add(existing.identityId);
    }
    return result;
  }

  /// Deletes a revoked record so that a new identity can be created.
  ///
  /// Only valid for revoked identities: deleting an active record would let a
  /// restart look like a fresh install and silently discard a live identity.
  Future<G2dIdentityActionResult> _resetRevokedIdentityImpl() async {
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
    final deleted = await _deleteRecord();
    if (deleted != null) {
      return deleted;
    }
    _retiredIdentityIds.add(existing.identityId);
    return const G2dIdentityActionResult.successEmpty();
  }

  /// Deletes a record that is positively classified as untrustworthy.
  ///
  /// This is the only recovery path from corruption. It is deliberately narrow:
  ///
  /// - a readable record is refused ([G2dIdentityFailure.notCorrupt]), so a valid
  ///   active or revoked identity can never be discarded here;
  /// - unavailable storage is **not** corruption and is reported as unavailable;
  /// - nothing is recreated: the caller must perform an explicit
  ///   [createIdentity] afterwards, which is where a new key is generated.
  ///
  /// A protection claim that this device cannot satisfy is treated the same way:
  /// the record cannot be trusted here, and the same explicit recovery applies.
  Future<G2dIdentityActionResult> _resetCorruptIdentityImpl() async {
    final loaded = await _load();
    if (loaded.failure == null) {
      return G2dIdentityActionResult.failure(
        loaded.record == null ? G2dIdentityFailure.noIdentity : G2dIdentityFailure.notCorrupt,
        loaded.record == null
            ? 'there is no identity record to reset'
            : 'the stored identity is readable and must not be discarded here',
      );
    }
    final failure = loaded.failure!.failure;
    if (!_isCorruptClass(failure)) {
      // storageUnavailable in particular must never delete anything: an IO error
      // is not evidence that the record is bad.
      return loaded.failure!;
    }
    final deleted = await _deleteRecord();
    return deleted ?? const G2dIdentityActionResult.successEmpty();
  }

  /// Failures after which the record cannot be trusted and an explicit reset is
  /// the only safe recovery. Kept narrow on purpose: storageUnavailable is not
  /// here, because an IO error is not evidence that the record is bad.
  static bool _isCorruptClass(G2dIdentityFailure? failure) =>
      failure == G2dIdentityFailure.storageCorrupt ||
      failure == G2dIdentityFailure.protectionInvalid;

  /// Runs the store's delete and maps its failures to typed results.
  ///
  /// Returns `null` on success, so callers can distinguish "deleted" from
  /// "refused" without treating a failure object as success.
  Future<G2dIdentityActionResult?> _deleteRecord() async {
    try {
      await store.delete();
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
    } on Exception catch (error) {
      return G2dIdentityActionResult.failure(
        G2dIdentityFailure.storageWriteFailed,
        error.toString(),
      );
    }
    return null;
  }

  Future<_Loaded> _load() async {
    try {
      final record = await store.load();
      if (record != null) {
        // A record restored from another device, edited, or created when the
        // platform could do more than it can now must not be treated as usable.
        final mismatch = platform.describeProtectionMismatch(record);
        if (mismatch != null) {
          return _Loaded.failure(G2dIdentityActionResult.failure(
            G2dIdentityFailure.protectionInvalid,
            mismatch,
          ));
        }
      }
      return _Loaded.record(record);
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
    } on Exception catch (error) {
      return _Loaded.failure(G2dIdentityActionResult.failure(
        G2dIdentityFailure.storageUnavailable,
        error.toString(),
      ));
    }
  }

  /// Validates and persists [record].
  ///
  /// The record is round-tripped through the wire format before the write: the
  /// bytes that get stored must be exactly the bytes a later [load] will accept,
  /// so an inconsistent record can never be written successfully and then be
  /// reported as corruption on the next read. Validation failure writes nothing.
  Future<G2dIdentityActionResult> _commit(G2dIdentityRecord record) async {
    final G2dIdentityRecord validated;
    try {
      validated = G2dIdentityRecord.fromMap(record.toMap());
    } on FormatException catch (error) {
      return G2dIdentityActionResult.failure(
        G2dIdentityFailure.invalidRecord,
        error.message,
      );
    }
    try {
      await store.save(validated);
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
    } on Exception catch (error) {
      // A future MethodChannel adapter reports platform failures as their own
      // exception types. They must surface as a typed storage failure rather
      // than escaping as an unhandled error.
      return G2dIdentityActionResult.failure(
        G2dIdentityFailure.storageWriteFailed,
        error.toString(),
      );
    }
    return G2dIdentityActionResult.success(validated);
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
