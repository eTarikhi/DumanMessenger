import 'package:duman_messenger/identity/identity_models.dart';
import 'package:duman_messenger/identity/platform_key_capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

String fingerprint(String nibble) => List<String>.filled(64, nibble).join();

G2dIdentityRecord recordWith({
  required G2dIdentityAlgorithm algorithm,
  required G2dKeyProtection protection,
  bool probeVerified = true,
}) =>
    G2dIdentityRecord(
      identityId: 'identity-1',
      keyVersion: 1,
      algorithm: algorithm,
      publicKeyFingerprint: fingerprint('a'),
      keyHandle: G2dKeyHandle(
        provider: 'android_keystore',
        alias: 'g2d.identity',
        protection: protection,
        probeVerified: probeVerified,
      ),
      state: G2dIdentityState.active,
      createdAtMillis: 1000,
    );

void main() {
  group('api level floor', () {
    test('accepts the project floor and above', () {
      expect(G2dAndroidKeyCapabilities.forApi(27).apiLevel, 27);
      expect(G2dAndroidKeyCapabilities.forApi(34).apiLevel, 34);
    });

    test('rejects API levels below the floor', () {
      expect(() => G2dAndroidKeyCapabilities.forApi(26), throwsFormatException);
      expect(() => G2dAndroidKeyCapabilities.forApi(0), throwsFormatException);
    });
  });

  group('documented platform limits', () {
    test('a wrapping key is available at the floor', () {
      expect(const G2dAndroidKeyCapabilities(27).canCreateWrappingKey, isTrue);
    });

    test('Ed25519 hardware keys are not possible before API 33', () {
      expect(const G2dAndroidKeyCapabilities(27).ed25519HardwareKeyPossible, isFalse);
      expect(const G2dAndroidKeyCapabilities(32).ed25519HardwareKeyPossible, isFalse);
      expect(const G2dAndroidKeyCapabilities(33).ed25519HardwareKeyPossible, isTrue);
    });

    test('X25519 is never a keystore key algorithm here', () {
      for (final api in <int>[27, 30, 33, 34]) {
        expect(G2dAndroidKeyCapabilities(api).x25519HardwareKeyPossible, isFalse);
      }
    });

    test('hardware possibility is per algorithm', () {
      const api27 = G2dAndroidKeyCapabilities(27);
      const api33 = G2dAndroidKeyCapabilities(33);

      expect(api27.isHardwarePossible(G2dIdentityAlgorithm.ed25519), isFalse);
      expect(api33.isHardwarePossible(G2dIdentityAlgorithm.ed25519), isTrue);
      for (final api in <G2dAndroidKeyCapabilities>[api27, api33]) {
        expect(api.isHardwarePossible(G2dIdentityAlgorithm.curve25519Xeddsa), isFalse);
        expect(api.isHardwarePossible(G2dIdentityAlgorithm.x25519), isFalse);
      }
    });
  });

  group('protection resolution', () {
    const api27 = G2dAndroidKeyCapabilities(27);
    const api33 = G2dAndroidKeyCapabilities(33);

    test('a probe that claims hardware on API 27 is downgraded, not trusted', () {
      expect(
        api27.resolveProtection(
          algorithm: G2dIdentityAlgorithm.ed25519,
          hardwareProbeSucceeded: true,
          wrappedByKeystore: true,
        ),
        G2dKeyProtection.softwareKeystoreWrapped,
      );
    });

    test('an impossible hardware claim without wrapping yields unknown', () {
      expect(
        api27.resolveProtection(
          algorithm: G2dIdentityAlgorithm.ed25519,
          hardwareProbeSucceeded: true,
          wrappedByKeystore: false,
        ),
        G2dKeyProtection.unknown,
      );
    });

    test('API 33 can justify a hardware-bound Ed25519 key', () {
      expect(
        api33.resolveProtection(
          algorithm: G2dIdentityAlgorithm.ed25519,
          hardwareProbeSucceeded: true,
          wrappedByKeystore: true,
        ),
        G2dKeyProtection.hardwareBound,
      );
    });

    test('a curve25519 identity is never hardware-bound', () {
      expect(
        api33.resolveProtection(
          algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
          hardwareProbeSucceeded: true,
          wrappedByKeystore: true,
        ),
        G2dKeyProtection.softwareKeystoreWrapped,
      );
    });

    test('without a probe the result is software-wrapped or unknown', () {
      expect(
        api27.resolveProtection(
          algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
          hardwareProbeSucceeded: false,
          wrappedByKeystore: true,
        ),
        G2dKeyProtection.softwareKeystoreWrapped,
      );
      expect(
        api27.resolveProtection(
          algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
          hardwareProbeSucceeded: false,
          wrappedByKeystore: false,
        ),
        G2dKeyProtection.unknown,
      );
    });
  });

  group('record/protection consistency', () {
    test('rejects a hardware claim the platform cannot provide', () {
      const api27 = G2dAndroidKeyCapabilities(27);
      final mismatch = api27.describeProtectionMismatch(recordWith(
        algorithm: G2dIdentityAlgorithm.ed25519,
        protection: G2dKeyProtection.hardwareBound,
      ));

      expect(mismatch, isNotNull);
      expect(mismatch, contains('cannot hold'));
    });

    test('accepts a hardware claim that matches the platform', () {
      const api33 = G2dAndroidKeyCapabilities(33);
      expect(
        api33.describeProtectionMismatch(recordWith(
          algorithm: G2dIdentityAlgorithm.ed25519,
          protection: G2dKeyProtection.hardwareBound,
        )),
        isNull,
      );
    });

    test('rejects a hardware claim for a non-hardware algorithm', () {
      const api33 = G2dAndroidKeyCapabilities(33);
      expect(
        api33.describeProtectionMismatch(recordWith(
          algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
          protection: G2dKeyProtection.hardwareBound,
        )),
        isNotNull,
      );
    });

    test('accepts a software-wrapped record and flags an unknown one', () {
      const api27 = G2dAndroidKeyCapabilities(27);
      expect(
        api27.describeProtectionMismatch(recordWith(
          algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
          protection: G2dKeyProtection.softwareKeystoreWrapped,
        )),
        isNull,
      );
      expect(
        api27.describeProtectionMismatch(recordWith(
          algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
          protection: G2dKeyProtection.unknown,
          probeVerified: false,
        )),
        'unknown key protection is not usable',
      );
    });
  });

  group('protection wording', () {
    test('describes software protection without claiming hardware', () {
      final text = describeKeyProtection(G2dKeyProtection.softwareKeystoreWrapped);
      expect(text.toLowerCase().contains('hardware'), isFalse);
      expect(text, contains('memory'));
    });

    test('describes hardware protection only when it is hardware', () {
      expect(
        describeKeyProtection(G2dKeyProtection.hardwareBound),
        contains('hardware'),
      );
    });

    test('states plainly that unverified protection is unusable', () {
      expect(
        describeKeyProtection(G2dKeyProtection.unknown),
        contains('Not usable'),
      );
    });
  });
}
