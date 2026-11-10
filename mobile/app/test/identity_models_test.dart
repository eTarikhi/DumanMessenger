import 'package:duman_messenger/identity/identity_models.dart';
import 'package:flutter_test/flutter_test.dart';

String fingerprint(String nibble) => List<String>.filled(64, nibble).join();

G2dKeyHandle testHandle({
  G2dKeyProtection protection = G2dKeyProtection.softwareKeystoreWrapped,
  bool probeVerified = true,
  String provider = 'android_keystore',
  String alias = 'g2d.identity.v1',
}) =>
    G2dKeyHandle(
      provider: provider,
      alias: alias,
      protection: protection,
      probeVerified: probeVerified,
    );

G2dIdentityRecord testRecord({
  G2dIdentityState state = G2dIdentityState.active,
  int keyVersion = 1,
  String? publicKeyFingerprint,
  String? previousKeyFingerprint,
  int? rotatedAtMillis,
  int? revokedAtMillis,
  G2dRevocationReason? revocationReason,
  G2dKeyHandle? keyHandle,
}) =>
    G2dIdentityRecord(
      identityId: 'identity-1',
      keyVersion: keyVersion,
      algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
      publicKeyFingerprint: publicKeyFingerprint ?? fingerprint('a'),
      keyHandle: keyHandle ?? testHandle(),
      state: state,
      createdAtMillis: 1000,
      rotatedAtMillis: rotatedAtMillis,
      previousKeyFingerprint: previousKeyFingerprint,
      revokedAtMillis: revokedAtMillis,
      revocationReason: revocationReason,
    );

void main() {
  group('fingerprint', () {
    test('accepts 64 lowercase hex characters', () {
      expect(G2dIdentityRecord.isValidFingerprint(fingerprint('a')), isTrue);
      expect(
        G2dIdentityRecord.isValidFingerprint(List<String>.filled(4, '0123456789abcdef').join()),
        isTrue,
      );
    });

    test('rejects uppercase, short, long and non-hex values', () {
      expect(G2dIdentityRecord.isValidFingerprint(fingerprint('A')), isFalse);
      expect(G2dIdentityRecord.isValidFingerprint(fingerprint('a').substring(1)), isFalse);
      expect(G2dIdentityRecord.isValidFingerprint('${fingerprint('a')}a'), isFalse);
      expect(G2dIdentityRecord.isValidFingerprint(List<String>.filled(64, 'g').join()), isFalse);
      expect(G2dIdentityRecord.isValidFingerprint(''), isFalse);
    });

    test('display formatting groups the full value without truncation', () {
      final value = List<String>.filled(16, 'ab01').join();
      expect(G2dIdentityRecord.isValidFingerprint(value), isTrue);
      final formatted = G2dIdentityRecord.formatFingerprintForDisplay(value);
      expect(formatted.split(' ').length, 16);
      expect(formatted.replaceAll(' ', ''), value);
      expect(formatted.length, 64 + 15);
    });

    test('display formatting refuses an invalid fingerprint', () {
      expect(
        () => G2dIdentityRecord.formatFingerprintForDisplay('short'),
        throwsFormatException,
      );
    });
  });

  group('key handle', () {
    test('round-trips provider, alias, protection and probe flag', () {
      final handle = testHandle(protection: G2dKeyProtection.hardwareBound);
      final decoded = G2dKeyHandle.fromMap(handle.toMap());
      expect(decoded, handle);
      expect(decoded.protection, G2dKeyProtection.hardwareBound);
      expect(decoded.probeVerified, isTrue);
    });

    test('rejects an unprobed protection claim', () {
      expect(
        () => G2dKeyHandle.fromMap(<String, Object?>{
          'provider': 'android_keystore',
          'alias': 'g2d.identity.v1',
          'protection': 'hardware_bound',
        }),
        throwsFormatException,
      );
    });

    test('rejects probe flag on unknown protection', () {
      expect(
        () => G2dKeyHandle.fromMap(<String, Object?>{
          'provider': 'android_keystore',
          'alias': 'g2d.identity.v1',
          'protection': 'unknown',
          'probeVerified': true,
        }),
        throwsFormatException,
      );
    });

    test('rejects unknown protection names and empty identifiers', () {
      expect(
        () => G2dKeyHandle.fromMap(<String, Object?>{
          'provider': 'android_keystore',
          'alias': 'a',
          'protection': 'tee_enclave',
        }),
        throwsFormatException,
      );
      expect(
        () => G2dKeyHandle.fromMap(<String, Object?>{
          'provider': '',
          'alias': 'a',
          'protection': 'unknown',
        }),
        throwsFormatException,
      );
      expect(
        () => G2dKeyHandle.fromMap(<String, Object?>{
          'provider': 'p',
          'alias': '',
          'protection': 'unknown',
        }),
        throwsFormatException,
      );
      expect(
        () => G2dKeyHandle.fromMap('not a map'),
        throwsFormatException,
      );
    });
  });

  group('identity record', () {
    test('round-trips every field of an active identity', () {
      final record = testRecord();
      final decoded = G2dIdentityRecord.fromMap(record.toMap());
      expect(decoded, record);
      expect(decoded.state, G2dIdentityState.active);
      expect(decoded.isUsable, isTrue);
      expect(decoded.hasVerifiedProtection, isTrue);
    });

    test('round-trips a rotated identity with its previous fingerprint', () {
      final record = testRecord(
        keyVersion: 2,
        publicKeyFingerprint: fingerprint('b'),
        previousKeyFingerprint: fingerprint('a'),
        rotatedAtMillis: 2000,
      );
      final decoded = G2dIdentityRecord.fromMap(record.toMap());
      expect(decoded.keyVersion, 2);
      expect(decoded.previousKeyFingerprint, fingerprint('a'));
      expect(decoded.rotatedAtMillis, 2000);
    });

    test('round-trips a revoked identity', () {
      final record = testRecord(
        state: G2dIdentityState.revoked,
        revokedAtMillis: 3000,
        revocationReason: G2dRevocationReason.compromised,
      );
      final decoded = G2dIdentityRecord.fromMap(record.toMap());
      expect(decoded.state, G2dIdentityState.revoked);
      expect(decoded.revocationReason, G2dRevocationReason.compromised);
      expect(decoded.isUsable, isFalse);
    });

    test('omits absent optional fields from the encoded map', () {
      final map = testRecord().toMap();
      expect(map.containsKey('rotatedAtMillis'), isFalse);
      expect(map.containsKey('previousKeyFingerprint'), isFalse);
      expect(map.containsKey('revokedAtMillis'), isFalse);
      expect(map.containsKey('revocationReason'), isFalse);
      expect(map['recordVersion'], G2dIdentityRecord.currentRecordVersion);
    });

    test('rejects unsupported record versions instead of guessing', () {
      final map = testRecord().toMap()..['recordVersion'] = 2;
      expect(() => G2dIdentityRecord.fromMap(map), throwsFormatException);
    });

    test('rejects malformed required fields', () {
      for (final mutate in <void Function(Map<String, Object?>)>[
        (map) => map['identityId'] = '',
        (map) => map['keyVersion'] = 0,
        (map) => map['algorithm'] = 'rsa2048',
        (map) => map['publicKeyFingerprint'] = 'short',
        (map) => map['createdAtMillis'] = 0,
        (map) => map['state'] = 'trusted',
        (map) => map.remove('keyHandle'),
      ]) {
        final map = testRecord().toMap();
        mutate(map);
        expect(() => G2dIdentityRecord.fromMap(map), throwsFormatException);
      }
    });

    test('rejects a revoked record that carries no revocation evidence', () {
      final map = testRecord(state: G2dIdentityState.revoked).toMap();
      expect(() => G2dIdentityRecord.fromMap(map), throwsFormatException);
    });

    test('rejects revocation data on a non-revoked record', () {
      final map = testRecord(revokedAtMillis: 2000).toMap();
      expect(() => G2dIdentityRecord.fromMap(map), throwsFormatException);
    });

    test('rejects a pending rotation without a previous fingerprint', () {
      final map = testRecord(state: G2dIdentityState.rotationPending).toMap();
      expect(() => G2dIdentityRecord.fromMap(map), throwsFormatException);
    });

    test('rejects a rotation that does not change the fingerprint', () {
      final map = testRecord(
        state: G2dIdentityState.rotationPending,
        keyVersion: 2,
        previousKeyFingerprint: fingerprint('a'),
        rotatedAtMillis: 2000,
      ).toMap();
      expect(() => G2dIdentityRecord.fromMap(map), throwsFormatException);
    });

    test('rejects key version 2 without a rotation time', () {
      final map = testRecord(keyVersion: 2).toMap();
      expect(() => G2dIdentityRecord.fromMap(map), throwsFormatException);
    });

    test('rejects a rotation time before creation', () {
      final map = testRecord(
        keyVersion: 2,
        publicKeyFingerprint: fingerprint('b'),
        previousKeyFingerprint: fingerprint('a'),
        rotatedAtMillis: 500,
      ).toMap();
      expect(() => G2dIdentityRecord.fromMap(map), throwsFormatException);
    });

    test('rejects an active identity whose protection is unknown', () {
      // The handle itself is well-formed (an unknown level makes no claim), but
      // an active identity may not exist on top of an unverified protection.
      final record = testRecord(
        keyHandle: testHandle(
          protection: G2dKeyProtection.unknown,
          probeVerified: false,
        ),
      );
      expect(() => G2dIdentityRecord.fromMap(record.toMap()), throwsFormatException);
    });

    test('rejects a pending rotation whose protection was never probed', () {
      // A pending rotation is one step from active, so it may not rest on an
      // unverified protection claim.
      final record = testRecord(
        state: G2dIdentityState.rotationPending,
        keyVersion: 2,
        publicKeyFingerprint: fingerprint('b'),
        previousKeyFingerprint: fingerprint('a'),
        rotatedAtMillis: 2000,
        keyHandle: testHandle(
          protection: G2dKeyProtection.unknown,
          probeVerified: false,
        ),
      );
      expect(() => G2dIdentityRecord.fromMap(record.toMap()), throwsFormatException);
    });

    test('rejects a revocation time before creation', () {
      final record = testRecord(
        state: G2dIdentityState.revoked,
        revokedAtMillis: 500,
        revocationReason: G2dRevocationReason.userRequested,
      );
      expect(() => G2dIdentityRecord.fromMap(record.toMap()), throwsFormatException);
    });

    test('copyWith changes only the named fields', () {
      final record = testRecord();
      final rotated = record.copyWith(keyVersion: 2, rotatedAtMillis: 2000);
      expect(rotated.keyVersion, 2);
      expect(rotated.rotatedAtMillis, 2000);
      expect(rotated.identityId, record.identityId);
      expect(rotated.publicKeyFingerprint, record.publicKeyFingerprint);
      expect(rotated.createdAtMillis, record.createdAtMillis);
    });

    test('equality covers lifecycle fields', () {
      expect(testRecord(), testRecord());
      expect(testRecord().hashCode, testRecord().hashCode);
      expect(testRecord(keyVersion: 2), isNot(testRecord()));
    });
  });
}
