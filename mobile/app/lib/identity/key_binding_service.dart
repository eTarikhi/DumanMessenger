import 'identity_key_material.dart';
import 'identity_key_provider.dart';
import 'key_binding.dart';
import 'key_binding_store.dart';

/// What this installation can say about its own stored binding.
enum G2dBindingPresence {
  /// Nothing is stored. The identity may exist; the binding has not been issued.
  absent,

  /// A stored binding verifies and describes exactly these keys.
  verified,

  /// Something is stored, but it does not verify or does not describe these keys.
  /// Never repaired, never re-issued silently.
  mismatched,
}

/// The result of looking at the stored binding, for diagnostics and tests.
class G2dBindingStatus {
  const G2dBindingStatus({required this.presence, this.binding, this.reason});

  final G2dBindingPresence presence;
  final G2dKeyBinding? binding;
  final String? reason;

  bool get isUsable => presence == G2dBindingPresence.verified;
}

/// Issues, stores and re-checks this device's own signed key binding.
///
/// The gap this closes: the identity record names an Ed25519 fingerprint and a key
/// handle, but nothing said which X25519 exchange key belongs to it. After this runs
/// once, the device holds a signed statement over both public keys, in its own
/// encrypted slot.
///
/// What it deliberately does not do:
///
/// * it does not decide trust — that is [G2dIdentityBindingRecord]'s job, and it needs
///   a person;
/// * it does not rotate. A stored binding that no longer matches the keys is an error,
///   not something to overwrite; rotation needs a generation chain, a policy and a
///   decision about telling contacts, and none of those exist;
/// * it does not make the keys hardware-backed, or bind anything to a session.
class G2dIdentityBindingService {
  G2dIdentityBindingService({required this.store, required this.provider});

  final G2dKeyBindingStore store;
  final G2dIdentityKeyProvider provider;

  /// Whether the binding survives a restart, as the store reports.
  bool get isPersistent => store.isPersistent;

  /// Reads and checks the stored binding without writing anything.
  Future<G2dBindingStatus> status(G2dIdentityKeyMaterial material) async {
    final G2dKeyBinding? stored = await store.load();
    if (stored == null) {
      return const G2dBindingStatus(presence: G2dBindingPresence.absent);
    }
    return _check(stored, material);
  }

  /// Returns the stored binding, issuing and persisting one on first use.
  ///
  /// Throws [G2dIdentityBindingException] when the slot holds something that does not
  /// belong to these keys, and when a freshly written binding does not read back. The
  /// identity itself is untouched by any of these failures: the keys stay where they
  /// were, and no slot is overwritten to recover.
  Future<G2dKeyBinding> ensureBound(G2dIdentityKeyMaterial material) async {
    final G2dKeyBinding? stored = await store.load();
    if (stored != null) {
      final G2dBindingStatus status = await _check(stored, material);
      if (status.isUsable) {
        return stored;
      }
      throw G2dIdentityBindingException(
        'the stored key binding does not match this identity: ${status.reason}',
      );
    }

    // `signKeyBinding` verifies its own output before returning, so a binding that
    // reaches the store has already been checked once with the key that signed it.
    final G2dKeyBinding signed = await provider.signKeyBinding(material);
    await store.save(signed);

    // Read it back through the store: what matters is the bytes that survived, not the
    // object still in memory.
    final G2dKeyBinding? reloaded = await store.load();
    if (reloaded == null) {
      throw const G2dIdentityBindingException(
        'the key binding did not read back after it was written',
      );
    }
    final G2dBindingStatus check = await _check(reloaded, material);
    if (!check.isUsable || !_sameBytes(reloaded.toBytes(), signed.toBytes())) {
      throw G2dIdentityBindingException(
        'the stored key binding did not verify after the write: ${check.reason}',
      );
    }
    return reloaded;
  }

  Future<G2dBindingStatus> _check(
    G2dKeyBinding binding,
    G2dIdentityKeyMaterial material,
  ) async {
    final G2dBindingVerdict verdict = await binding.verify(
      expectedEd25519PublicKey: material.ed25519PublicKey,
    );
    if (!verdict.isValid) {
      // Distinguishes "signed by somebody else" from "these bytes are broken", which is
      // the same distinction the binding itself makes.
      return G2dBindingStatus(
        presence: G2dBindingPresence.mismatched,
        binding: binding,
        reason: verdict.name,
      );
    }
    if (!_sameBytes(binding.x25519PublicKey, material.x25519PublicKey)) {
      return G2dBindingStatus(
        presence: G2dBindingPresence.mismatched,
        binding: binding,
        reason: 'the binding names a different exchange key than this identity holds',
      );
    }
    return G2dBindingStatus(
      presence: G2dBindingPresence.verified,
      binding: binding,
    );
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var index = 0; index < a.length; index += 1) {
      if (a[index] != b[index]) {
        return false;
      }
    }
    return true;
  }
}
