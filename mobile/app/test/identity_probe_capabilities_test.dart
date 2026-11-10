import 'package:duman_messenger/identity/identity_models.dart';
import 'package:duman_messenger/identity/identity_probe_capabilities.dart';
import 'package:duman_messenger/identity/platform_key_capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

import 'identity_fake_platform.dart';

/// A fingerprint-shaped value; the same one every record here uses.
final String testFingerprint = List<String>.filled(64, 'a').join();

G2dKeyHandle handleWith(G2dKeyProtection protection) => G2dKeyHandle(
      provider: 'android_keystore',
      alias: 'g2d.identity.key.v1',
      protection: protection,
      probeVerified: true,
    );

G2dIdentityRecord recordWith(G2dKeyHandle handle) => G2dIdentityRecord(
      identityId: 'identity-1',
      keyVersion: 1,
      algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
      publicKeyFingerprint: testFingerprint,
      keyHandle: handle,
      state: G2dIdentityState.active,
      createdAtMillis: 1000,
    );

void main() {
  group('capability evidence decoding', () {
    test('parses a measured probe result', () {
      final evidence = G2dAndroidCapabilityEvidence.fromMap(
        measuredEvidence(apiLevel: 27, wrappingKeyPresent: true),
      );
      expect(evidence.apiLevel, 27);
      expect(evidence.keystoreProvider, 'AndroidKeyStore');
      expect(evidence.aesGcmSupported, isTrue);
      expect(evidence.probeKeyGenerated, isTrue);
      expect(evidence.roundTripVerified, isTrue);
      expect(evidence.probeKeyHardwareBacked, isFalse);
      expect(evidence.probeKeySizeBits, 256);
      expect(evidence.wrappingKeyPresent, isTrue);
      expect(evidence.failure, isNull);
    });

    test('rejects a payload that is not a map', () {
      expect(
        () => G2dAndroidCapabilityEvidence.fromMap('AndroidKeyStore'),
        throwsFormatException,
      );
    });

    test('rejects a missing field instead of defaulting it', () {
      final map = measuredEvidence()..remove('roundTripVerified');
      expect(
        () => G2dAndroidCapabilityEvidence.fromMap(map),
        throwsFormatException,
      );
    });

    test('rejects a mistyped boolean', () {
      final map = measuredEvidence()..['probeKeyGenerated'] = 'yes';
      expect(
        () => G2dAndroidCapabilityEvidence.fromMap(map),
        throwsFormatException,
      );
    });

    test('rejects a mistyped integer', () {
      final map = measuredEvidence()..['apiLevel'] = '27';
      expect(
        () => G2dAndroidCapabilityEvidence.fromMap(map),
        throwsFormatException,
      );
    });

    test('rejects an unparsable API level', () {
      final map = measuredEvidence(apiLevel: 0);
      expect(
        () => G2dAndroidCapabilityEvidence.fromMap(map),
        throwsFormatException,
      );
    });

    test('rejects notes that are not a list of strings', () {
      final notAList = measuredEvidence()..['notes'] = 'StrongBox absent';
      expect(
        () => G2dAndroidCapabilityEvidence.fromMap(notAList),
        throwsFormatException,
      );
      final notStrings = measuredEvidence()..['notes'] = <Object?>[1, 2];
      expect(
        () => G2dAndroidCapabilityEvidence.fromMap(notStrings),
        throwsFormatException,
      );
    });

    test('reports a verified wrap only when the round trip actually happened', () {
      expect(
        G2dAndroidCapabilityEvidence.fromMap(measuredEvidence())
            .verifiedWrapRoundTrip,
        isTrue,
      );
      expect(
        G2dAndroidCapabilityEvidence.fromMap(
          measuredEvidence(roundTripVerified: false),
        ).verifiedWrapRoundTrip,
        isFalse,
      );
      expect(
        G2dAndroidCapabilityEvidence.fromMap(
          measuredEvidence(aesGcmSupported: false, roundTripVerified: false),
        ).verifiedWrapRoundTrip,
        isFalse,
      );
    });

    test('reports StrongBox only when a StrongBox key was created', () {
      expect(
        G2dAndroidCapabilityEvidence.fromMap(measuredEvidence())
            .strongBoxVerified,
        isFalse,
      );
      expect(
        G2dAndroidCapabilityEvidence.fromMap(
          measuredEvidence(strongBoxRequested: true, strongBoxKeyCreated: false),
        ).strongBoxVerified,
        isFalse,
      );
      expect(
        G2dAndroidCapabilityEvidence.fromMap(
          measuredEvidence(strongBoxRequested: true, strongBoxKeyCreated: true),
        ).strongBoxVerified,
        isTrue,
      );
    });

    test('describes software-backed wrapping without claiming hardware', () {
      final description = G2dAndroidCapabilityEvidence.fromMap(
        measuredEvidence(hardwareBacked: false),
      ).describeWrappingProtection();
      expect(description, contains('software-backed'));
      expect(description, isNot(contains('hardware-backed')));
      expect(description, contains('not exportable'));
    });

    test('describes hardware-backed wrapping only when it was measured', () {
      final description = G2dAndroidCapabilityEvidence.fromMap(
        measuredEvidence(hardwareBacked: true),
      ).describeWrappingProtection();
      expect(description, contains('hardware-backed'));
      expect(description, contains('isInsideSecureHardware = true'));
    });

    test('describes an unverified wrap as unusable for persistence', () {
      final description = G2dAndroidCapabilityEvidence.fromMap(
        measuredEvidence(roundTripVerified: false),
      ).describeWrappingProtection();
      expect(description, contains('No verified'));
      expect(description, contains('must not be persisted'));
    });

    test('uses the wrapping key measurement once a wrapping key exists', () {
      // The probe key landed in hardware but the real wrapping key did not: the
      // real key is what protects the record, so its measurement wins.
      final evidence = G2dAndroidCapabilityEvidence.fromMap(
        measuredEvidence(
          hardwareBacked: true,
          wrappingKeyPresent: true,
          wrappingKeyHardwareBacked: false,
        ),
      );
      expect(evidence.wrapKeyHardwareBacked, isFalse);
    });

    test('falls back to the probe key measurement before any identity exists', () {
      final evidence = G2dAndroidCapabilityEvidence.fromMap(
        measuredEvidence(hardwareBacked: true),
      );
      expect(evidence.wrappingKeyPresent, isFalse);
      expect(evidence.wrapKeyHardwareBacked, isTrue);
    });
  });

  group('probed capability rules', () {
    test('refuses an API level below the G2-D floor', () {
      final evidence = G2dAndroidCapabilityEvidence.fromMap(
        measuredEvidence(apiLevel: 26),
      );
      expect(() => G2dProbedKeyCapabilities(evidence), throwsFormatException);
    });

    test('allows software-wrapped protection on API 27 when the wrap verified', () {
      final capabilities = G2dProbedKeyCapabilities(
        G2dAndroidCapabilityEvidence.fromMap(measuredEvidence()),
      );
      expect(
        capabilities.describeProtectionFor(
          G2dIdentityAlgorithm.curve25519Xeddsa,
          G2dKeyProtection.softwareKeystoreWrapped,
        ),
        isNull,
      );
    });

    test('refuses software-wrapped protection when the wrap did not verify', () {
      final capabilities = G2dProbedKeyCapabilities(
        G2dAndroidCapabilityEvidence.fromMap(
          measuredEvidence(roundTripVerified: false),
        ),
      );
      expect(
        capabilities.describeProtectionFor(
          G2dIdentityAlgorithm.curve25519Xeddsa,
          G2dKeyProtection.softwareKeystoreWrapped,
        ),
        contains('no verified Android Keystore'),
      );
    });

    test('refuses unknown protection', () {
      final capabilities = G2dProbedKeyCapabilities(
        G2dAndroidCapabilityEvidence.fromMap(measuredEvidence()),
      );
      expect(
        capabilities.describeProtectionFor(
          G2dIdentityAlgorithm.curve25519Xeddsa,
          G2dKeyProtection.unknown,
        ),
        contains('unknown key protection'),
      );
    });

    test('refuses a hardware claim when no hardware key was measured', () {
      final capabilities = G2dProbedKeyCapabilities(
        G2dAndroidCapabilityEvidence.fromMap(
          measuredEvidence(apiLevel: 33, hardwareBacked: false),
        ),
      );
      expect(
        capabilities.describeProtectionFor(
          G2dIdentityAlgorithm.ed25519,
          G2dKeyProtection.hardwareBound,
        ),
        contains('no hardware-backed Android Keystore key was measured'),
      );
      expect(
        capabilities.isHardwarePossible(G2dIdentityAlgorithm.ed25519),
        isFalse,
      );
    });

    test('refuses a hardware claim on API 27 even when the probe reports hardware', () {
      // A hardware AES key says nothing about whether this platform can hold an
      // Ed25519 key. The documented API-level rule still denies it.
      final capabilities = G2dProbedKeyCapabilities(
        G2dAndroidCapabilityEvidence.fromMap(
          measuredEvidence(apiLevel: 27, hardwareBacked: true),
        ),
      );
      expect(
        capabilities.describeProtectionFor(
          G2dIdentityAlgorithm.ed25519,
          G2dKeyProtection.hardwareBound,
        ),
        contains('cannot hold'),
      );
      expect(
        capabilities.describeProtectionFor(
          G2dIdentityAlgorithm.curve25519Xeddsa,
          G2dKeyProtection.hardwareBound,
        ),
        contains('cannot hold'),
      );
    });

    test('allows a hardware claim on API 33 when the device measured it', () {
      final capabilities = G2dProbedKeyCapabilities(
        G2dAndroidCapabilityEvidence.fromMap(
          measuredEvidence(apiLevel: 33, hardwareBacked: true),
        ),
      );
      expect(
        capabilities.isHardwarePossible(G2dIdentityAlgorithm.ed25519),
        isTrue,
      );
      expect(
        capabilities.describeProtectionFor(
          G2dIdentityAlgorithm.ed25519,
          G2dKeyProtection.hardwareBound,
        ),
        isNull,
      );
    });

    test('never allows a hardware claim for X25519 or Curve25519', () {
      final capabilities = G2dProbedKeyCapabilities(
        G2dAndroidCapabilityEvidence.fromMap(
          measuredEvidence(apiLevel: 34, hardwareBacked: true),
        ),
      );
      expect(capabilities.isHardwarePossible(G2dIdentityAlgorithm.x25519), isFalse);
      expect(
        capabilities.isHardwarePossible(G2dIdentityAlgorithm.curve25519Xeddsa),
        isFalse,
      );
      expect(
        capabilities.describeProtectionFor(
          G2dIdentityAlgorithm.x25519,
          G2dKeyProtection.hardwareBound,
        ),
        contains('cannot hold'),
      );
    });

    test('rejects a stored record that claims hardware binding on API 27', () {
      final capabilities = G2dProbedKeyCapabilities(
        G2dAndroidCapabilityEvidence.fromMap(
          measuredEvidence(apiLevel: 27, hardwareBacked: true),
        ),
      );
      final record = recordWith(handleWith(G2dKeyProtection.hardwareBound));
      expect(capabilities.describeProtectionMismatch(record), isNotNull);
    });

    test('accepts a stored record that claims software wrapping on API 27', () {
      final capabilities = G2dProbedKeyCapabilities(
        G2dAndroidCapabilityEvidence.fromMap(measuredEvidence(apiLevel: 27)),
      );
      final record =
          recordWith(handleWith(G2dKeyProtection.softwareKeystoreWrapped));
      expect(capabilities.describeProtectionMismatch(record), isNull);
    });

    test('keeps the documented API facts for the probed level', () {
      final capabilities = G2dProbedKeyCapabilities(
        G2dAndroidCapabilityEvidence.fromMap(measuredEvidence(apiLevel: 27)),
      );
      expect(capabilities.apiLevel, 27);
      expect(
        capabilities.documented.ed25519HardwareKeyPossible,
        isFalse,
      );
      expect(
        capabilities.documented.canCreateWrappingKey,
        isTrue,
      );
      expect(
        G2dAndroidKeyCapabilities.minimumSupportedApiLevel,
        27,
      );
      expect(
        G2dAndroidKeyCapabilities.ed25519KeystoreApiLevel,
        33,
      );
    });
  });
}
