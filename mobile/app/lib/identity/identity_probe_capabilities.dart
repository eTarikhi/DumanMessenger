/// Evidence-based platform capability facts for G2-D.
///
/// [G2dAndroidKeyCapabilities] states what an API level *permits*. This file
/// states what a device *did*. The difference matters: an API level can deny a
/// hardware claim (API 27 cannot hold a Keystore Ed25519 key) but it can never
/// grant one, so a hardware claim additionally needs a measurement — the
/// platform's own `KeyInfo.isInsideSecureHardware` answer for a key this process
/// actually created and used.
///
/// The evidence is never inferred, never defaulted and never upgraded:
///
/// * an unparsable or partial probe result is a `FormatException`, not a guess;
/// * "the Keystore exists" is availability, and availability is not protection;
/// * StrongBox is reported only when a StrongBox key was actually created;
/// * the wrapping protection is called hardware-backed only when the measurement
///   said so.
///
/// See `docs/mobile/G2-D-ANDROID-KEYSTORE-AND-STORAGE.md`.
library;

import 'identity_models.dart';
import 'platform_key_capabilities.dart';

/// What the Android adapter measured on this device.
///
/// Every field is a measurement or a dated platform fact. There are no defaults
/// and no "probably" values: a field the platform did not report is rejected at
/// decode rather than assumed.
class G2dAndroidCapabilityEvidence {
  const G2dAndroidCapabilityEvidence({
    required this.apiLevel,
    required this.keystoreProvider,
    required this.aesGcmSupported,
    required this.probeKeyGenerated,
    required this.roundTripVerified,
    required this.probeKeyHardwareBacked,
    required this.probeKeySizeBits,
    required this.strongBoxRequested,
    required this.strongBoxKeyCreated,
    required this.wrappingKeyPresent,
    required this.wrappingKeyHardwareBacked,
    required this.notes,
    this.failure,
  });

  /// Strict decoder for the adapter's `capabilities` response.
  ///
  /// Unknown extra keys are ignored so the platform may add facts later, but
  /// every key read here must have the documented type. A missing or mistyped
  /// field is a `FormatException`: silently substituting `false` would turn "the
  /// probe did not run" into "the device cannot", which is a different claim.
  factory G2dAndroidCapabilityEvidence.fromMap(Object? value) {
    if (value is! Map) {
      throw const FormatException('Android capability evidence must be a map.');
    }

    int requireInt(String key) {
      final raw = value[key];
      if (raw is! int) {
        throw FormatException('Capability evidence field "$key" must be an integer.');
      }
      return raw;
    }

    bool requireBool(String key) {
      final raw = value[key];
      if (raw is! bool) {
        throw FormatException('Capability evidence field "$key" must be a boolean.');
      }
      return raw;
    }

    String requireString(String key) {
      final raw = value[key];
      if (raw is! String || raw.isEmpty) {
        throw FormatException('Capability evidence field "$key" must be a non-empty string.');
      }
      return raw;
    }

    final apiLevel = requireInt('apiLevel');
    if (apiLevel < 1) {
      throw const FormatException('Capability evidence reports an invalid Android API level.');
    }

    final wrappingKeyHardwareBacked = value['wrappingKeyHardwareBacked'];
    if (wrappingKeyHardwareBacked != null && wrappingKeyHardwareBacked is! bool) {
      throw const FormatException(
        'Capability evidence field "wrappingKeyHardwareBacked" must be a boolean or null.',
      );
    }

    final failure = value['failure'];
    if (failure != null && failure is! String) {
      throw const FormatException('Capability evidence field "failure" must be a string or null.');
    }

    final rawNotes = value['notes'];
    final notes = <String>[];
    if (rawNotes != null) {
      if (rawNotes is! List) {
        throw const FormatException('Capability evidence field "notes" must be a list.');
      }
      for (final note in rawNotes) {
        if (note is! String) {
          throw const FormatException('Capability evidence notes must be strings.');
        }
        notes.add(note);
      }
    }

    return G2dAndroidCapabilityEvidence(
      apiLevel: apiLevel,
      keystoreProvider: requireString('keystoreProvider'),
      aesGcmSupported: requireBool('aesGcmSupported'),
      probeKeyGenerated: requireBool('probeKeyGenerated'),
      roundTripVerified: requireBool('roundTripVerified'),
      probeKeyHardwareBacked: requireBool('probeKeyHardwareBacked'),
      probeKeySizeBits: requireInt('probeKeySizeBits'),
      strongBoxRequested: requireBool('strongBoxRequested'),
      strongBoxKeyCreated: requireBool('strongBoxKeyCreated'),
      wrappingKeyPresent: requireBool('wrappingKeyPresent'),
      wrappingKeyHardwareBacked: wrappingKeyHardwareBacked as bool?,
      notes: List<String>.unmodifiable(notes),
      failure: failure as String?,
    );
  }

  /// API level the probe ran on.
  final int apiLevel;

  /// Keystore provider the facts came from, e.g. `AndroidKeyStore`.
  final String keystoreProvider;

  /// The device offers an AES key generator in the Keystore. Availability only.
  final bool aesGcmSupported;

  /// A probe key was actually created.
  final bool probeKeyGenerated;

  /// That key actually encrypted and decrypted the same bytes.
  final bool roundTripVerified;

  /// `KeyInfo.isInsideSecureHardware` for the probe key. The only hardware evidence.
  final bool probeKeyHardwareBacked;

  /// Size of the probe key in bits (0 when the platform would not describe it).
  final int probeKeySizeBits;

  /// A StrongBox attempt was made (API 28 and newer only).
  final bool strongBoxRequested;

  /// A StrongBox key was actually created.
  final bool strongBoxKeyCreated;

  /// The long-lived wrapping key that protects identity data exists.
  final bool wrappingKeyPresent;

  /// Measured hardware backing of the wrapping key; null when it does not exist
  /// or the platform would not describe it.
  final bool? wrappingKeyHardwareBacked;

  /// Non-secret device notes from the probe, for diagnostics.
  final List<String> notes;

  /// Non-secret description of the first probe failure, if any.
  final String? failure;

  /// True only when the Keystore produced a key *and* it round-tripped.
  bool get verifiedWrapRoundTrip =>
      aesGcmSupported && probeKeyGenerated && roundTripVerified;

  /// True only when a StrongBox key was actually created on this device.
  bool get strongBoxVerified => strongBoxRequested && strongBoxKeyCreated;

  /// Whether the AES key that protects identity data is hardware-backed.
  ///
  /// **Read the source of this value before it is quoted.** When a wrapping key
  /// exists, the answer is that key's own `KeyInfo.isInsideSecureHardware`. When
  /// no identity has been stored yet there is no wrapping key to read, and this
  /// falls back to the *probe* key's measurement — a different key, created
  /// moments earlier with the same provider and the same spec, then deleted.
  ///
  /// That fallback is a **proxy, not a measurement of the production wrapping
  /// key**. [wrappingKeyBackingMeasuredDirectly] distinguishes the two, and
  /// [describeWrappingKeyBackingEvidence] names which one is in force. Neither
  /// path infers anything from the OS version, and neither permits a claim about
  /// a key this process never read.
  bool get wrapKeyHardwareBacked {
    final measured = wrappingKeyHardwareBacked;
    if (measured != null) {
      return measured;
    }
    return probeKeyHardwareBacked;
  }

  /// Whether [wrapKeyHardwareBacked] comes from the stored wrapping key itself.
  ///
  /// False means the value is the probe key's measurement: a proxy, because no
  /// wrapping key existed to measure. This is deliberately a separate question
  /// from the value, so "the probe says software" cannot be read as "the stored
  /// key was measured as software".
  bool get wrappingKeyBackingMeasuredDirectly => wrappingKeyHardwareBacked != null;

  /// Label naming the source of [wrapKeyHardwareBacked], for diagnostics and records.
  ///
  /// Exists so that a caller cannot describe a proxy as though the production
  /// wrapping key had been read. It carries no key material.
  String describeWrappingKeyBackingEvidence() {
    if (wrappingKeyBackingMeasuredDirectly) {
      return 'measured directly on the stored wrapping key '
          '(KeyInfo.isInsideSecureHardware = $wrappingKeyHardwareBacked)';
    }
    return 'proxy: measured on a transient probe key, because no wrapping key '
        'exists yet; the production wrapping key has not been measured';
  }

  /// Human-readable, deliberately narrow description of at-rest protection.
  ///
  /// The phrase "hardware-backed" appears only when a measurement supports it.
  String describeWrappingProtection() {
    if (!verifiedWrapRoundTrip) {
      return 'No verified Android Keystore wrapping key on this device; '
          'identity data must not be persisted here.';
    }
    final backing = wrapKeyHardwareBacked
        ? 'a hardware-backed Keystore key (KeyInfo.isInsideSecureHardware = true)'
        : 'a software-backed Keystore key (KeyInfo.isInsideSecureHardware = false)';
    return 'AES-${probeKeySizeBits == 0 ? 256 : probeKeySizeBits}-GCM at rest under $backing; '
        'the wrapping key is not exportable.';
  }
}

/// Platform facts for the identity service, backed by measured evidence.
///
/// This replaces a caller-supplied API level as the source of truth. The
/// documented API-level rules still apply — measurement can only narrow them —
/// and a protection claim is refused unless the corresponding capability was
/// both permitted by the API level and measured on the device.
class G2dProbedKeyCapabilities implements G2dPlatformKeyCapabilities {
  G2dProbedKeyCapabilities(this.evidence)
      : documented = G2dAndroidKeyCapabilities.forApi(evidence.apiLevel);

  final G2dAndroidCapabilityEvidence evidence;

  /// API-level rules, unchanged, for the level the probe actually ran on.
  final G2dAndroidKeyCapabilities documented;

  @override
  int get apiLevel => evidence.apiLevel;

  /// A hardware claim needs both: an algorithm the API level can hold in
  /// hardware, and a Keystore key this device really did keep inside secure
  /// hardware. Measurement can only narrow the documented rule.
  @override
  bool isHardwarePossible(G2dIdentityAlgorithm algorithm) =>
      documented.isHardwarePossible(algorithm) && evidence.probeKeyHardwareBacked;

  @override
  String? describeProtectionFor(
    G2dIdentityAlgorithm algorithm,
    G2dKeyProtection protection,
  ) {
    switch (protection) {
      case G2dKeyProtection.unknown:
        return 'unknown key protection is not usable';
      case G2dKeyProtection.hardwareBound:
        if (!evidence.probeKeyHardwareBacked) {
          return 'no hardware-backed Android Keystore key was measured on this device';
        }
        return documented.describeProtectionFor(algorithm, protection);
      case G2dKeyProtection.softwareKeystoreWrapped:
        if (!evidence.verifiedWrapRoundTrip) {
          return 'no verified Android Keystore AES-GCM wrapping key on this device';
        }
        return null;
    }
  }

  @override
  String? describeProtectionMismatch(G2dIdentityRecord record) =>
      describeProtectionFor(record.algorithm, record.keyHandle.protection);
}
