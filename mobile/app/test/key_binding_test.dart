import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:duman_messenger/identity/identity_key_material.dart';
import 'package:duman_messenger/identity/identity_key_provider.dart';
import 'package:duman_messenger/identity/key_binding.dart';
import 'package:flutter_test/flutter_test.dart';

/// Focused tests for the provisional Ed25519 -> X25519 binding.
///
/// Real keys and real signatures: `package:cryptography` is pure Dart, so a test that
/// used a stub verifier would prove nothing about the thing being shipped. Nothing
/// here touches the Keystore, a device, or a transport.
void main() {
  group('G2dKeyBinding', () {
    test('a signed binding verifies under its own identity and refuses another',
        () async {
      final _Identity identity = await _makeIdentity(7);
      final G2dKeyBinding binding = await G2dKeyBinding.sign(
        ed25519Seed: identity.seed,
        x25519PublicKey: identity.x25519PublicKey,
      );

      expect(await binding.verify(), G2dBindingVerdict.valid);
      expect(
        await binding.verify(expectedEd25519PublicKey: identity.ed25519PublicKey),
        G2dBindingVerdict.valid,
      );

      final _Identity other = await _makeIdentity(91);
      expect(
        await binding.verify(expectedEd25519PublicKey: other.ed25519PublicKey),
        G2dBindingVerdict.identityMismatch,
      );
      expect(binding.generation, 1);
      expect(binding.previousBindingDigest, isNull);
      expect(binding.toString(), isNot(contains('signature')));
    });

    test('editing the exchange key invalidates the signature', () async {
      final _Identity identity = await _makeIdentity(11);
      final G2dKeyBinding binding = await G2dKeyBinding.sign(
        ed25519Seed: identity.seed,
        x25519PublicKey: identity.x25519PublicKey,
      );

      final List<int> bytes = binding.toBytes();
      // version, suite, domain length + domain, key length, 32-byte Ed25519 key,
      // key length: the X25519 key starts at 55 and the signature is untouched.
      bytes[55 + 3] = bytes[55 + 3] ^ 0x01;

      final G2dKeyBinding tampered = G2dKeyBinding.fromBytes(bytes);
      expect(tampered.x25519PublicKey, isNot(binding.x25519PublicKey));
      expect(await tampered.verify(), G2dBindingVerdict.invalidSignature);
      // A replaced exchange key does not silently become a valid one, and it is not
      // reported as an identity mismatch: the signature is what failed.
      expect(tampered.bindsSameKeysAs(binding), isFalse);
    });

    test('a valid signature by a substituted identity is an identity mismatch',
        () async {
      final _Identity victim = await _makeIdentity(23);
      final _Identity attacker = await _makeIdentity(67);

      // The attacker signs a perfectly good binding, over the victim's exchange key.
      final G2dKeyBinding substituted = await G2dKeyBinding.sign(
        ed25519Seed: attacker.seed,
        x25519PublicKey: victim.x25519PublicKey,
      );

      expect(await substituted.verify(), G2dBindingVerdict.valid);
      expect(
        await substituted.verify(expectedEd25519PublicKey: victim.ed25519PublicKey),
        G2dBindingVerdict.identityMismatch,
      );
      // The pinned key is what decides, not the presence of a signature.
      expect(
        await substituted.verify(expectedEd25519PublicKey: attacker.ed25519PublicKey),
        G2dBindingVerdict.valid,
      );
    });

    test('a rotation must name the digest of the binding it replaces', () async {
      final _Identity identity = await _makeIdentity(31);
      final G2dKeyBinding first = await G2dKeyBinding.sign(
        ed25519Seed: identity.seed,
        x25519PublicKey: identity.x25519PublicKey,
      );
      final List<int> firstDigest = await first.digest();

      final G2dKeyBinding second = await G2dKeyBinding.sign(
        ed25519Seed: identity.seed,
        x25519PublicKey: identity.x25519PublicKey,
        generation: 2,
        previousBindingDigest: firstDigest,
      );
      expect(await second.verify(), G2dBindingVerdict.valid);
      expect(await second.continuesFrom(first), isTrue);

      // A "second generation" that points somewhere else is not a continuation.
      final G2dKeyBinding wrongParent = await G2dKeyBinding.sign(
        ed25519Seed: identity.seed,
        x25519PublicKey: identity.x25519PublicKey,
        generation: 2,
        previousBindingDigest: List<int>.filled(32, 0),
      );
      expect(await wrongParent.continuesFrom(first), isFalse);

      // A skipped generation is not a continuation either.
      final G2dKeyBinding third = await G2dKeyBinding.sign(
        ed25519Seed: identity.seed,
        x25519PublicKey: identity.x25519PublicKey,
        generation: 3,
        previousBindingDigest: firstDigest,
      );
      expect(await third.continuesFrom(first), isFalse);

      // The two directions of the generation rule are enforced at construction.
      expect(
        () => G2dKeyBinding(
          ed25519PublicKey: identity.ed25519PublicKey,
          x25519PublicKey: identity.x25519PublicKey,
          generation: 2,
          signature: List<int>.filled(64, 0),
        ),
        throwsA(isA<G2dKeyBindingFormatException>()),
      );
      expect(
        () => G2dKeyBinding(
          ed25519PublicKey: identity.ed25519PublicKey,
          x25519PublicKey: identity.x25519PublicKey,
          previousBindingDigest: List<int>.filled(32, 0),
          signature: List<int>.filled(64, 0),
        ),
        throwsA(isA<G2dKeyBindingFormatException>()),
      );
    });

    test('malformed bytes are refused, never repaired', () async {
      final _Identity identity = await _makeIdentity(41);
      final G2dKeyBinding binding = await G2dKeyBinding.sign(
        ed25519Seed: identity.seed,
        x25519PublicKey: identity.x25519PublicKey,
      );
      final List<int> good = binding.toBytes();

      expect(G2dKeyBinding.fromBytes(good).toBytes(), good);

      // Round trip through the encoded form is what a second implementation would do.
      expect(G2dKeyBinding.fromBase64Url(binding.toBase64Url()).toBytes(), good);

      final List<int> badVersion = List<int>.of(good)..[0] = 2;
      expect(
        () => G2dKeyBinding.fromBytes(badVersion),
        throwsA(isA<G2dKeyBindingFormatException>()),
      );

      final List<int> badSuite = List<int>.of(good)..[1] = 9;
      expect(
        () => G2dKeyBinding.fromBytes(badSuite),
        throwsA(isA<G2dKeyBindingFormatException>()),
      );

      expect(
        () => G2dKeyBinding.fromBytes(good.sublist(0, good.length - 1)),
        throwsA(isA<G2dKeyBindingFormatException>()),
      );
      expect(
        () => G2dKeyBinding.fromBytes(<int>[...good, 0]),
        throwsA(isA<G2dKeyBindingFormatException>()),
      );
      expect(
        () => G2dKeyBinding.fromBase64Url('not base64!!'),
        throwsA(isA<G2dKeyBindingFormatException>()),
      );
      expect(
        () => G2dKeyBinding.fromBytes(const <int>[]),
        throwsA(isA<G2dKeyBindingFormatException>()),
      );
    });

    test('the identity provider signs a binding that verifies against its own material',
        () async {
      final G2dIdentityKeyProvider provider = G2dIdentityKeyProvider();
      final G2dIdentityKeyMaterial material = await provider.generate();
      final G2dKeyBinding binding = await provider.signKeyBinding(material);

      expect(
        await binding.verify(expectedEd25519PublicKey: material.ed25519PublicKey),
        G2dBindingVerdict.valid,
      );
      expect(binding.ed25519PublicKey, material.ed25519PublicKey);
      expect(binding.x25519PublicKey, material.x25519PublicKey);
      // The identity fingerprint is unchanged by this milestone: still the
      // domain-separated hash of the signing key, never of the exchange key.
      expect(await provider.fingerprint(material), matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('the signed bytes, the digest and the exchange fingerprint are deterministic',
        () async {
      final _Identity identity = await _makeIdentity(53);
      final G2dKeyBinding one = await G2dKeyBinding.sign(
        ed25519Seed: identity.seed,
        x25519PublicKey: identity.x25519PublicKey,
      );
      final G2dKeyBinding two = await G2dKeyBinding.sign(
        ed25519Seed: identity.seed,
        x25519PublicKey: identity.x25519PublicKey,
      );

      expect(two.signingBytes, one.signingBytes);
      expect(await two.digest(), await one.digest());
      expect(two.toBytes(), one.toBytes());

      final String exchange = await one.exchangeKeyFingerprint();
      expect(exchange, hasLength(64));
      expect(exchange, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(await two.exchangeKeyFingerprint(), exchange);

      // The exchange fingerprint identifies the exchange key, not the binding: a
      // rotation re-issues it, and it must not be confused with the identity
      // fingerprint, which this class never computes.
      final G2dKeyBinding rotated = await G2dKeyBinding.sign(
        ed25519Seed: identity.seed,
        x25519PublicKey: identity.x25519PublicKey,
        generation: 2,
        previousBindingDigest: await one.digest(),
      );
      expect(await rotated.exchangeKeyFingerprint(), exchange);
      expect(await rotated.digest(), isNot(await one.digest()));

      // Domain separation is visible in the bytes, not implied.
      expect(
        ascii.decode(one.signingBytes.sublist(3, 3 + G2dKeyBinding.signingDomain.length)),
        G2dKeyBinding.signingDomain,
      );
    });
  });
}

class _Identity {
  const _Identity({
    required this.seed,
    required this.ed25519PublicKey,
    required this.x25519PublicKey,
  });

  final List<int> seed;
  final List<int> ed25519PublicKey;
  final List<int> x25519PublicKey;
}

Future<_Identity> _makeIdentity(int base) async {
  final List<int> seed = List<int>.generate(32, (int i) => (base + i) & 0xFF);
  final SimpleKeyPair edPair = await Ed25519().newKeyPairFromSeed(seed);
  final SimplePublicKey edPublic = await edPair.extractPublicKey();

  final List<int> xSeed = List<int>.generate(32, (int i) => (base * 7 + i) & 0xFF);
  final SimpleKeyPair xPair = await X25519().newKeyPairFromSeed(xSeed);
  final SimplePublicKey xPublic = await xPair.extractPublicKey();

  return _Identity(
    seed: seed,
    ed25519PublicKey: edPublic.bytes,
    x25519PublicKey: xPublic.bytes,
  );
}
