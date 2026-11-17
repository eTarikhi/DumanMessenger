/// Composition root for the Android identity foundation.
///
/// This wires the three pieces that must never be wired by hand at a call site:
/// measured capability evidence, the probed capability rules and the encrypted
/// store. Assembling them anywhere else invites the two mistakes the G2-D
/// foundation exists to prevent — assuming protection instead of measuring it,
/// and using a store whose wrapping key was never proven to work.
///
/// It creates no identity. [G2dIdentityService.createIdentity] still requires a
/// public fingerprint and a key handle from a crypto provider, and no provider is
/// integrated yet, so nothing here can invent an identity at startup.
library;

import 'identity_android_store.dart';
import 'identity_channel.dart';
import 'identity_key_material.dart';
import 'identity_key_material_store.dart';
import 'identity_key_provider.dart';
import 'identity_models.dart';
import 'identity_probe_capabilities.dart';
import 'identity_service.dart';
import 'key_binding.dart';
import 'key_binding_service.dart';
import 'key_binding_store.dart';
import 'identity_store.dart';

/// The Android identity stack, assembled from measured facts.
class G2dAndroidIdentityRuntime {
  G2dAndroidIdentityRuntime._({
    required this.evidence,
    required this.capabilities,
    required this.store,
    required this.service,
    required this.keyProvider,
    required this.keyMaterialStore,
    this.bindings,
  });

  /// Probes the device and assembles the stack.
  ///
  /// Throws [G2dIdentityStoreUnavailable] when the device's Keystore could not be
  /// proven to encrypt and decrypt with an AES-GCM key. That is a refusal, not a
  /// downgrade: there is deliberately no code path that continues with a store
  /// whose protection is unknown.
  static Future<G2dAndroidIdentityRuntime> initialize({
    G2dIdentityChannel? channel,
  }) async {
    final resolved = channel ?? G2dIdentityChannel();
    final raw = await resolved.capabilities();
    final evidence = G2dAndroidCapabilityEvidence.fromMap(raw);
    final capabilities = G2dProbedKeyCapabilities(evidence);
    if (!evidence.verifiedWrapRoundTrip) {
      throw G2dIdentityStoreUnavailable(evidence.describeWrappingProtection());
    }
    final store = G2dKeystoreIdentityStore(
      channel: resolved,
      protectionVerified: evidence.verifiedWrapRoundTrip,
    );
    final keyMaterialStore = G2dKeystoreKeyMaterialStore(
      channel: resolved,
      protectionVerified: evidence.verifiedWrapRoundTrip,
    );
    final keyProvider = G2dIdentityKeyProvider();
    // The signed binding lives in its own slot, under its own alias, and is issued with
    // the same provider that generated the keys.
    final bindings = G2dIdentityBindingService(
      store: G2dKeystoreKeyBindingStore(channel: resolved),
      provider: keyProvider,
    );
    return G2dAndroidIdentityRuntime._(
      evidence: evidence,
      capabilities: capabilities,
      store: store,
      service: G2dIdentityService(store: store, platform: capabilities),
      keyProvider: keyProvider,
      keyMaterialStore: keyMaterialStore,
      bindings: bindings,
    );
  }

  /// What the device measured about its own Keystore.
  final G2dAndroidCapabilityEvidence evidence;

  /// Capability rules narrowed by that measurement.
  final G2dProbedKeyCapabilities capabilities;

  /// Encrypted, crash-safe record storage.
  final G2dKeystoreIdentityStore store;

  /// The identity lifecycle. The only supported way to change identity state.
  final G2dIdentityService service;

  /// Non-secret description of at-rest protection, for diagnostics.
  String get protectionSummary => evidence.describeWrappingProtection();

  /// Whether a StrongBox key was actually created on this device.
  ///
  /// Reported for diagnostics only: no identity key is bound to StrongBox in this
  /// milestone, and this value must never be presented as identity-key protection.
  bool get strongBoxVerified => evidence.strongBoxVerified;

  /// Whether the AES key that protects identity data is measured hardware-backed.
  bool get wrapKeyHardwareBacked => evidence.wrapKeyHardwareBacked;

  /// Reads the current identity through the service, never through the store.
  Future<G2dIdentitySnapshot> load() => service.load();

  /// Generates and uses the real Curve25519 identity keys.
  final G2dIdentityKeyProvider keyProvider;

  /// The wrapped slot the private identity keys live in, when they exist.
  final G2dKeystoreKeyMaterialStore keyMaterialStore;

  /// Issues and re-checks the Ed25519 -> X25519 binding for this installation.
  final G2dIdentityBindingService? bindings;

  /// The binding that verified during this session, if one did.
  ///
  /// Public keys and a signature only — nothing here is private, and nothing here has
  /// been shown to another device, because no transport exists.
  G2dKeyBinding? lastKeyBinding;

  /// Why the binding could not be issued, when it could not.
  ///
  /// A binding failure never fails identity creation: the keys are already generated and
  /// the record already points at them, so failing at that point would invite a rollback
  /// that deletes keys. It is recorded here instead of being swallowed.
  String? lastKeyBindingError;

  /// Creates this installation's first identity.
  ///
  /// The order is the safety property, not an implementation detail:
  ///
  /// 1. read the record first — an existing identity is never replaced, and a
  ///    store that cannot be read is never written over;
  /// 2. generate real Ed25519 + X25519 keys and prove them with the provider's
  ///    self-check;
  /// 3. write the material into its own Keystore-wrapped slot and read it back;
  /// 4. only then write the record that points at that material.
  ///
  /// If step 3 or 4 fails, the material is deleted, so a failed creation leaves
  /// neither private keys nor a record pointing at nothing. The step-3 round trip
  /// is also the probe behind `software_keystore_wrapped`: the claim is made only
  /// after these exact bytes survived the Keystore envelope on this exact device.
  Future<G2dIdentityActionResult> createIdentity() async {
    final G2dIdentitySnapshot current = await service.load();
    if (current is G2dIdentityCorrupt) {
      return G2dIdentityActionResult.failure(
        G2dIdentityFailure.storageCorrupt,
        current.reason,
      );
    }
    if (current is G2dIdentityStorageUnavailable) {
      return G2dIdentityActionResult.failure(
        G2dIdentityFailure.storageUnavailable,
        current.reason,
      );
    }
    if (current is! G2dIdentityAbsent) {
      return const G2dIdentityActionResult.failure(
        G2dIdentityFailure.identityExists,
      );
    }

    final G2dIdentityKeyMaterial material = await keyProvider.generate();
    final String fingerprint = await keyProvider.fingerprint(material);

    try {
      final bool materialVerified =
          await keyMaterialStore.writeAndVerify(material);
      if (!materialVerified) {
        await _discardKeyMaterial();
        return const G2dIdentityActionResult.failure(
          G2dIdentityFailure.storageWriteFailed,
          'the identity key material did not survive the Keystore round trip',
        );
      }

      final G2dIdentityActionResult result = await service.createIdentity(
        algorithm: G2dIdentityAlgorithm.ed25519,
        publicKeyFingerprint: fingerprint,
        keyHandle: G2dKeyHandle(
          provider: G2dIdentityKeyProvider.providerName,
          alias: G2dIdentityKeyProvider.keyAlias,
          // Software keys, wrapped at rest by a non-exportable Keystore AES key.
          // Never `hardwareBound`: no Keystore generation path for Ed25519 or
          // X25519 exists on this project's API floor, and claiming it without a
          // measurement is precisely what the record codec refuses to store.
          protection: G2dKeyProtection.softwareKeystoreWrapped,
          probeVerified: true,
        ),
      );
      if (!result.isSuccess) {
        await _discardKeyMaterial();
        return result;
      }
      // The identity exists and its keys are stored; now say which exchange key belongs
      // to it, in a signed record of its own.
      await _issueKeyBinding(material);
      return result;
    } catch (error) {
      await _discardKeyMaterialIfNoRecord();
      rethrow;
    }
  }

  /// Issues or re-checks the binding for the active identity, if one exists.
  ///
  /// Returns `null` when there is no binding service, no active identity, or no stored
  /// key material. Throws only for a failure the caller has to see; a binding that does
  /// not match is recorded in [lastKeyBindingError] and reported as `null`.
  Future<G2dKeyBinding?> ensureKeyBinding() async {
    final bindingService = bindings;
    if (bindingService == null) {
      return null;
    }
    final snapshot = await this.service.load();
    if (snapshot is! G2dIdentityActive) {
      return null;
    }
    final material = await keyMaterialStore.load();
    if (material == null) {
      lastKeyBindingError = 'no stored key material to bind';
      return null;
    }
    await _issueKeyBinding(material);
    return lastKeyBinding;
  }

  Future<void> _issueKeyBinding(G2dIdentityKeyMaterial material) async {
    final bindingService = bindings;
    if (bindingService == null) {
      return;
    }
    try {
      lastKeyBinding = await bindingService.ensureBound(material);
      lastKeyBindingError = null;
    } on G2dIdentityBindingException catch (error) {
      lastKeyBinding = null;
      lastKeyBindingError = error.message;
    } catch (error) {
      lastKeyBinding = null;
      lastKeyBindingError = error.toString();
    }
  }

  /// Removes the key material only when storage still reports no record.
  ///
  /// The asymmetry matters: if the record was written and something failed
  /// afterwards, deleting the keys would leave a record pointing at nothing, which
  /// is worse than an inert leftover. A leftover slot is overwritten by the next
  /// creation, and a record with missing keys is a state the service already
  /// reports and the user can reset deliberately.
  Future<void> _discardKeyMaterialIfNoRecord() async {
    try {
      if (await service.load() is G2dIdentityAbsent) {
        await _discardKeyMaterial();
      }
    } catch (_) {
      // Cannot tell what was written; leave the material alone on purpose.
    }
  }

  /// Best-effort removal of the key material after a failed creation.
  ///
  /// Failure to clean up is not reported upwards: the original error is the one
  /// the caller must see, and a leftover wrapped key material slot with no record
  /// pointing at it is inert — the next creation overwrites it.
  Future<void> _discardKeyMaterial() async {
    try {
      await keyMaterialStore.delete();
    } catch (_) {
      // Deliberately swallowed; see the comment above.
    }
  }
}
