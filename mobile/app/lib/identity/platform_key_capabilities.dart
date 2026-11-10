/// G2-D platform key-capability facts and the rule that protects them.
///
/// These are **documented platform expectations**, not probe results. The Android
/// Keystore does not offer Ed25519 as a key algorithm before Android 13 (API 33),
/// and does not offer X25519 as a key algorithm at all across the supported API
/// range. Those two facts decide whether an identity key can ever be
/// hardware-bound on a given device.
///
/// The rule this file enforces is narrow and important: **a record may only claim
/// hardware binding when a real probe said so on that device.** The API level can
/// *deny* a hardware claim (API 27 cannot have a Keystore Ed25519 key, and no
/// supported API level has a Keystore X25519 key); it can never *grant* one.
///
/// See `docs/mobile/G2-D-IDENTITY-KEY-MANAGEMENT.md` for the probe contract.
library;

import 'identity_models.dart';

/// What a record may claim about key protection on a given Android API level.
class G2dAndroidKeyCapabilities {
  const G2dAndroidKeyCapabilities(this.apiLevel);

  /// Lowest API level this project supports for G2-D (Android 8.1).
  static const int minimumSupportedApiLevel = 27;

  /// First API level where the Android Keystore can generate an Ed25519 key.
  static const int ed25519KeystoreApiLevel = 33;

  /// First API level where `KeyGenParameterSpec`-backed wrapping keys exist. The
  /// Keystore provider itself predates the G2-D floor.
  static const int keystoreAesApiLevel = 23;

  /// Resolves capabilities for an API level, rejecting values below the floor.
  factory G2dAndroidKeyCapabilities.forApi(int apiLevel) {
    if (apiLevel < minimumSupportedApiLevel) {
      throw const FormatException('Android API level is below the G2-D floor.');
    }
    return G2dAndroidKeyCapabilities(apiLevel);
  }

  final int apiLevel;

  /// Whether a non-exportable AES wrapping key can be created. Always true at or
  /// above [minimumSupportedApiLevel].
  bool get canCreateWrappingKey => apiLevel >= keystoreAesApiLevel;

  /// Whether a Keystore-native Ed25519 key is possible on this API level.
  bool get ed25519HardwareKeyPossible => apiLevel >= ed25519KeystoreApiLevel;

  /// X25519 is not a Keystore key algorithm on any supported API level, so an
  /// exchange key is always software-held and wrapped.
  bool get x25519HardwareKeyPossible => false;

  /// Whether the algorithm *could* be hardware-bound on this API level, ignoring
  /// what a specific device reports.
  bool isHardwarePossible(G2dIdentityAlgorithm algorithm) => switch (algorithm) {
        G2dIdentityAlgorithm.ed25519 => ed25519HardwareKeyPossible,
        G2dIdentityAlgorithm.curve25519Xeddsa => false,
        G2dIdentityAlgorithm.x25519 => false,
      };

  /// The strongest protection this API level can justify for [algorithm], given
  /// the outcome of a device probe.
  ///
  /// [hardwareProbeSucceeded] must come from an actual sign/verify or key-creation
  /// probe on the device. [wrappedByKeystore] must come from an actual wrapping
  /// key creation. Anything else yields [G2dKeyProtection.unknown], which the
  /// identity model refuses for an active identity.
  G2dKeyProtection resolveProtection({
    required G2dIdentityAlgorithm algorithm,
    required bool hardwareProbeSucceeded,
    required bool wrappedByKeystore,
  }) {
    if (hardwareProbeSucceeded && isHardwarePossible(algorithm)) {
      return G2dKeyProtection.hardwareBound;
    }
    if (wrappedByKeystore && canCreateWrappingKey) {
      return G2dKeyProtection.softwareKeystoreWrapped;
    }
    return G2dKeyProtection.unknown;
  }

  /// Returns a non-null reason when [record] claims protection this API level
  /// cannot provide. Used as a fail-closed check after loading a record, so a
  /// hand-edited, migrated or restored record cannot inflate its protection.
  String? describeProtectionMismatch(G2dIdentityRecord record) {
    final claimsHardware = record.keyHandle.protection == G2dKeyProtection.hardwareBound;
    if (claimsHardware && !isHardwarePossible(record.algorithm)) {
      return 'hardware-bound claim for an algorithm this API level cannot hold';
    }
    if (record.keyHandle.protection == G2dKeyProtection.unknown) {
      return 'unknown key protection is not usable';
    }
    return null;
  }
}

/// Human-readable description of what is and is not protected, for diagnostics.
///
/// Uses deliberately narrow wording: "software-protected, wrapped at rest" is not
/// "hardware-backed", and the phrase "hardware-backed" appears only for a
/// hardware-bound key.
String describeKeyProtection(G2dKeyProtection protection) => switch (protection) {
      G2dKeyProtection.hardwareBound =>
        'Private key held in secure hardware; key material does not leave it.',
      G2dKeyProtection.softwareKeystoreWrapped =>
        'Software key, encrypted at rest by a non-exportable platform key; '
            'key bytes exist in app memory while in use.',
      G2dKeyProtection.unknown =>
        'Protection not verified. Not usable for an active identity.',
    };
