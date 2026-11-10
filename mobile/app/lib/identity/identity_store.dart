/// G2-D identity storage contract.
///
/// The contract is deliberately small and total: a store either returns a
/// validated record, returns "no record", or fails with a typed error. It never
/// falls back to a different (weaker) backing store, and it never silently
/// repairs or regenerates anything.
///
/// The app has no verified secure store yet. The default instance is
/// [G2dUnavailableIdentityStore], which fails closed rather than writing key
/// metadata to plaintext preferences. See
/// `docs/mobile/G2-D-IDENTITY-KEY-MANAGEMENT.md` for the Android adapter that
/// must be implemented and validated before any identity is persisted.
library;

import 'identity_models.dart';

/// Thrown when identity storage is not available on this build/device.
class G2dIdentityStoreUnavailable implements Exception {
  const G2dIdentityStoreUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'G2dIdentityStoreUnavailable($reason)';
}

/// Thrown when stored identity data cannot be trusted.
///
/// Corruption is terminal for the record: the caller must not "repair" it,
/// re-key around it, or fall back to a default identity. The only safe next
/// step is an explicit user-driven identity reset that discards the old record.
class G2dIdentityStoreCorrupt implements Exception {
  const G2dIdentityStoreCorrupt(this.reason);

  final String reason;

  @override
  String toString() => 'G2dIdentityStoreCorrupt($reason)';
}

/// Thrown when a write could not be completed durably.
///
/// The caller must treat the previous record as still current unless a reload
/// proves otherwise; a failed write never means "the new identity is active".
class G2dIdentityStoreWriteFailed implements Exception {
  const G2dIdentityStoreWriteFailed(this.reason);

  final String reason;

  @override
  String toString() => 'G2dIdentityStoreWriteFailed($reason)';
}

/// Durable identity storage.
///
/// Implementations must provide these properties; each is tested against the
/// in-memory double and must be re-tested against any real adapter:
///
/// 1. **Atomicity** — [save] either commits the whole record or leaves the
///    previous state intact. A half-written record must never be observable.
/// 2. **Single record** — at most one local identity exists at a time.
/// 3. **No silent fallback** — if the protected backing store is unavailable,
///    fail with [G2dIdentityStoreUnavailable] instead of using a weaker store.
/// 4. **No repair** — a record that fails validation is reported as
///    [G2dIdentityStoreCorrupt]; it is never patched or regenerated.
abstract interface class G2dIdentityStore {
  /// Stable, non-secret description used in diagnostics and tests.
  String get storeKind;

  /// Whether the record is protected at rest by a verified mechanism. A store
  /// that returns `false` may only be used in tests.
  bool get isSecureAtRest;

  /// Returns the stored record, or `null` when no identity exists yet.
  ///
  /// Throws [G2dIdentityStoreCorrupt] when a record exists but cannot be
  /// validated, and [G2dIdentityStoreUnavailable] when storage cannot be read.
  Future<G2dIdentityRecord?> load();

  /// Durably writes [record], replacing any previous record.
  ///
  /// Throws [G2dIdentityStoreWriteFailed] if the write did not commit.
  Future<void> save(G2dIdentityRecord record);

  /// Removes the stored record. Must be idempotent.
  Future<void> delete();
}

/// The production default: identity storage is not implemented yet.
///
/// Every operation fails closed. This exists so that no code path can
/// accidentally persist identity metadata to an unprotected store; the failure
/// is explicit and visible rather than a silent downgrade.
class G2dUnavailableIdentityStore implements G2dIdentityStore {
  const G2dUnavailableIdentityStore([
    this.reason = 'no verified secure identity store on this build',
  ]);

  final String reason;

  @override
  String get storeKind => 'unavailable';

  @override
  bool get isSecureAtRest => false;

  @override
  Future<G2dIdentityRecord?> load() async =>
      throw G2dIdentityStoreUnavailable(reason);

  @override
  Future<void> save(G2dIdentityRecord record) async =>
      throw G2dIdentityStoreUnavailable(reason);

  @override
  Future<void> delete() async => throw G2dIdentityStoreUnavailable(reason);
}

/// Test double. **Not secure at rest** — never construct this in app code.
///
/// It models the failure modes a real adapter must handle, so the lifecycle can
/// be tested before the Android adapter exists:
/// - [failNextWrite] simulates a write that does not commit;
/// - [corruptStoredValue] simulates undecodable bytes;
/// - [simulatePartialWrite] leaves the store in a state where a previous write
///   is only half present.
class G2dInMemoryIdentityStore implements G2dIdentityStore {
  G2dInMemoryIdentityStore();

  Object? _stored;
  bool _hasRecord = false;

  /// Set to `true` to make the next [save] throw without changing stored state.
  bool failNextWrite = false;

  /// Set to `true` to make the next [save] throw *after* destroying the
  /// previous record, modelling a non-atomic adapter.
  bool destructiveNextWrite = false;

  /// Number of committed writes, for tests that assert on persistence attempts.
  int committedWrites = 0;

  @override
  String get storeKind => 'in_memory_test_only';

  @override
  bool get isSecureAtRest => false;

  @override
  Future<G2dIdentityRecord?> load() async {
    if (!_hasRecord) {
      return null;
    }
    final stored = _stored;
    if (stored == null) {
      throw const G2dIdentityStoreCorrupt('stored identity bytes are missing');
    }
    try {
      return G2dIdentityRecord.fromMap(stored);
    } on FormatException catch (error) {
      throw G2dIdentityStoreCorrupt(error.message);
    }
  }

  @override
  Future<void> save(G2dIdentityRecord record) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw const G2dIdentityStoreWriteFailed('simulated write failure');
    }
    if (destructiveNextWrite) {
      destructiveNextWrite = false;
      _hasRecord = true;
      _stored = null;
      throw const G2dIdentityStoreWriteFailed('simulated non-atomic write failure');
    }
    _stored = record.toMap();
    _hasRecord = true;
    committedWrites += 1;
  }

  @override
  Future<void> delete() async {
    _stored = null;
    _hasRecord = false;
  }

  /// Replaces the stored bytes with an unparsable value.
  void corruptStoredValue([Object? value = 'not-a-record']) {
    _stored = value;
    _hasRecord = true;
  }

  /// Leaves a partially written record: the previous record is gone and the new
  /// one is incomplete.
  void simulatePartialWrite() {
    _stored = <String, Object?>{'recordVersion': G2dIdentityRecord.currentRecordVersion};
    _hasRecord = true;
  }
}
