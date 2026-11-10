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
import 'identity_probe_capabilities.dart';
import 'identity_service.dart';
import 'identity_store.dart';

/// The Android identity stack, assembled from measured facts.
class G2dAndroidIdentityRuntime {
  G2dAndroidIdentityRuntime._({
    required this.evidence,
    required this.capabilities,
    required this.store,
    required this.service,
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
    return G2dAndroidIdentityRuntime._(
      evidence: evidence,
      capabilities: capabilities,
      store: store,
      service: G2dIdentityService(store: store, platform: capabilities),
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
}
