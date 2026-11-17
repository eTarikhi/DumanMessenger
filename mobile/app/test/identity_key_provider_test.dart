import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:duman_messenger/identity/identity_key_material.dart';
import 'package:duman_messenger/identity/identity_key_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// These tests exercise the real Ed25519/X25519 implementation on the host.
///
/// They prove that keys are generated, used and serialized correctly. They do not
/// prove anything about a device, the Keystore, or at-rest protection: no test in
/// this file touches storage, and `flutter test` on Windows says nothing about
/// Android.
void main() {
  final G2dIdentityKeyProvider provider = G2dIdentityKeyProvider();

  String hex(List<int> bytes) =>
      bytes.map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  test('generates 32-byte Ed25519 and X25519 keys that sign and verify', () async {
    final G2dIdentityKeyMaterial material = await provider.generate();

    expect(material.ed25519Seed.length, G2dIdentityKeyMaterial.keyLength);
    expect(material.ed25519PublicKey.length, G2dIdentityKeyMaterial.keyLength);
    expect(material.x25519Seed.length, G2dIdentityKeyMaterial.keyLength);
    expect(material.x25519PublicKey.length, G2dIdentityKeyMaterial.keyLength);
    expect(material.ed25519Seed, isNot(material.x25519Seed));

    final List<int> challenge = utf8.encode('duman.test.challenge');
    final List<int> signature = await provider.sign(challenge, material);

    expect(signature.length, 64);
    expect(await provider.verify(challenge, signature, material), isTrue);
    expect(
      await provider.verify(utf8.encode('different'), signature, material),
      isFalse,
    );
  });

  test('two installations derive a symmetric X25519 shared secret', () async {
    final G2dIdentityKeyMaterial a = await provider.generate();
    final G2dIdentityKeyMaterial b = await provider.generate();

    final List<int> ab = await provider.sharedSecret(a, b.x25519PublicKey);
    final List<int> ba = await provider.sharedSecret(b, a.x25519PublicKey);

    expect(ab, ba);
    expect(ab.length, G2dIdentityKeyMaterial.keyLength);
    expect(ab.any((int byte) => byte != 0), isTrue);
  });

  test('the fingerprint is the domain-separated SHA-256 of the signing key',
      () async {
    final G2dIdentityKeyMaterial material = await provider.generate();
    final String fingerprint = await provider.fingerprint(material);

    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint), isTrue);

    final List<int> domainPrefixed = <int>[
      ...utf8.encode(G2dIdentityKeyProvider.fingerprintDomain),
      ...material.ed25519PublicKey,
    ];
    expect(fingerprint, hex((await Sha256().hash(domainPrefixed)).bytes));

    // The domain prefix is load-bearing: a bare key hash would collide with any
    // other SHA-256 of the same key elsewhere in the system.
    expect(fingerprint, isNot(hex((await Sha256().hash(material.ed25519PublicKey)).bytes)));

    // Deterministic for the same key, different for another one.
    expect(await provider.fingerprint(material), fingerprint);
    expect(
      await provider.fingerprint(await provider.generate()),
      isNot(fingerprint),
    );
  });

  test('serialization round-trips the exact key bytes', () async {
    final G2dIdentityKeyMaterial material = await provider.generate();
    final G2dIdentityKeyMaterial restored =
        G2dIdentityKeyMaterial.fromJson(material.toJson());

    expect(restored, material);
    expect(restored.hashCode, material.hashCode);

    // A rehydrated key really signs what the original verifies.
    final List<int> message = utf8.encode('after restore');
    final List<int> signature = await provider.sign(message, material);
    expect(await provider.verify(message, signature, restored), isTrue);
  });

  test('rejects a payload with a wrong version, algorithm or key length', () {
    final Map<String, Object?> valid = <String, Object?>{
      'version': 1,
      'algorithm': 'ed25519_x25519',
      'ed25519Seed': base64Encode(List<int>.filled(32, 1)),
      'ed25519PublicKey': base64Encode(List<int>.filled(32, 2)),
      'x25519Seed': base64Encode(List<int>.filled(32, 3)),
      'x25519PublicKey': base64Encode(List<int>.filled(32, 4)),
    };

    expect(
      () => G2dIdentityKeyMaterial.fromJson(jsonEncode(valid)),
      returnsNormally,
    );
    expect(
      () => G2dIdentityKeyMaterial.fromJson(
        jsonEncode(<String, Object?>{...valid, 'version': 2}),
      ),
      throwsFormatException,
    );
    expect(
      () => G2dIdentityKeyMaterial.fromJson(
        jsonEncode(<String, Object?>{...valid, 'algorithm': 'rsa'}),
      ),
      throwsFormatException,
    );
    expect(
      () => G2dIdentityKeyMaterial.fromJson(
        jsonEncode(<String, Object?>{
          ...valid,
          'ed25519Seed': base64Encode(List<int>.filled(31, 1)),
        }),
      ),
      throwsFormatException,
    );
    expect(
      () => G2dIdentityKeyMaterial.fromJson(
        jsonEncode(<String, Object?>{...valid, 'x25519Seed': 'not base64!'}),
      ),
      throwsFormatException,
    );
    expect(
      () => G2dIdentityKeyMaterial.fromJson('[]'),
      throwsFormatException,
    );
  });

  test('diagnostic text never contains key material', () async {
    final G2dIdentityKeyMaterial material = await provider.generate();

    expect(material.toString(), isNot(contains(material.ed25519PublicKeyHex)));
    expect(
      material.toString(),
      isNot(contains(hex(material.ed25519Seed))),
    );
  });
}
