import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:duman_messenger/identity/identity_key_material.dart';
import 'package:duman_messenger/identity/identity_key_provider.dart';
import 'package:duman_messenger/identity/key_binding.dart';
import 'package:flutter_test/flutter_test.dart';

/// Known-answer vector computed by an independent implementation (PyNaCl / libsodium),
/// from the documented layout alone: Ed25519 seed `00..1f`, X25519 seed `20..3f`,
/// generation 1, no predecessor. Ed25519 is deterministic per RFC 8032, so a second
/// implementation must reproduce these bytes exactly — which is what makes "the
/// encoding is cross-platform" a testable statement rather than a hope.
const String kVectorEd25519PublicKey =
    '03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8';
const String kVectorX25519PublicKey =
    '358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254';
const String kVectorSignedBytes =
    '01011244756d616e4b657942696e64696e672f76312003a107bff3ce10be1d70dd18e74bc099'
    '67e4d6309ba50d5f1ddc8664125531b820358072d6365880d1aeea329adf9121383851ed21a2'
    '8e3b75e965d0d2cd1662540000000100';
const String kVectorSignature =
    '2117c7b247f00ef502ee52512ac8235331a26d779721c4fc1449f91bd1d1c09996cbcb2ec9'
    '0aa8538b363e453d55c5ac5ada6425494dc2a8086ad389aacab600';
const String kVectorWire =
    '01011244756d616e4b657942696e64696e672f76312003a107bff3ce10be1d70dd18e74bc099'
    '67e4d6309ba50d5f1ddc8664125531b820358072d6365880d1aeea329adf9121383851ed21a2'
    '8e3b75e965d0d2cd1662540000000100402117c7b247f00ef502ee52512ac8235331a26d7797'
    '21c4fc1449f91bd1d1c09996cbcb2ec90aa8538b363e453d55c5ac5ada6425494dc2a8086ad3'
    '89aacab600';
const String kVectorDigest =
    '4ef5e069b3b7804cd6193f4bcf6fd9adb56dd38cb11382763447d04b47f65c72';
const String kVectorExchangeFingerprint =
    '7e7cebb049b04e750981fabb6779afdfcfeaa955367a4333cf1a1d064fdbeae7';
const String kVectorBase64Url =
    'AQESRHVtYW5LZXlCaW5kaW5nL3YxIAOhB7_zzhC-HXDdGOdLwJln5NYwm6UNXx3chmQSVTG4IDWActY2'
    'WIDRruoymt-RITg4Ue0hoo47dell0NLNFmJUAAAAAQBAIRfHskfwDvUC7lJRKsgjUzGibXeXIcT8FEn5'
    'G9HRwJmWy8suyQqoU4s2PkU9VcWsWtpkJUlNwqgIatOJqsq2AA==';

String _hex(List<int> bytes) =>
    bytes.map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();

List<int> _hexToBytes(String value) => <int>[
      for (var i = 0; i < value.length; i += 2)
        int.parse(value.substring(i, i + 2), radix: 16),
    ];

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

    test('the encoding reproduces an independent implementation byte for byte',
        () async {
      final List<int> edSeed = List<int>.generate(32, (int i) => i);
      final List<int> xSeed = List<int>.generate(32, (int i) => 0x20 + i);
      final SimplePublicKey xPublic =
          await (await X25519().newKeyPairFromSeed(xSeed)).extractPublicKey();
      // Same RFC 7748 clamping as libsodium's crypto_scalarmult_base.
      expect(_hex(xPublic.bytes), kVectorX25519PublicKey);

      final G2dKeyBinding binding = await G2dKeyBinding.sign(
        ed25519Seed: edSeed,
        x25519PublicKey: xPublic.bytes,
      );

      expect(_hex(binding.ed25519PublicKey), kVectorEd25519PublicKey);
      expect(_hex(binding.signingBytes), kVectorSignedBytes);
      expect(_hex(binding.signature), kVectorSignature);
      expect(_hex(binding.toBytes()), kVectorWire);
      expect(_hex(await binding.digest()), kVectorDigest);
      expect(await binding.exchangeKeyFingerprint(), kVectorExchangeFingerprint);
      expect(binding.toBase64Url(), kVectorBase64Url);
      expect(
        await binding.verify(
          expectedEd25519PublicKey: _hexToBytes(kVectorEd25519PublicKey),
        ),
        G2dBindingVerdict.valid,
      );

      // The decoder must accept the other implementation's bytes, not only ours.
      final G2dKeyBinding decoded =
          G2dKeyBinding.fromBytes(_hexToBytes(kVectorWire));
      expect(_hex(decoded.toBytes()), kVectorWire);
      expect(G2dKeyBinding.fromBase64Url(kVectorBase64Url).toBase64Url(), kVectorBase64Url);

      // And a single flipped byte anywhere in the wire form is refused or fails
      // verification — never silently accepted.
      final List<int> wire = _hexToBytes(kVectorWire);
      for (final int index in <int>[0, 1, 2, 30, 60, 100, wire.length - 1]) {
        final List<int> mutated = List<int>.of(wire);
        mutated[index] = mutated[index] ^ 0x01;
        G2dKeyBinding? parsed;
        try {
          parsed = G2dKeyBinding.fromBytes(mutated);
        } on G2dKeyBindingFormatException {
          continue;
        }
        expect(
          await parsed.verify(),
          isNot(G2dBindingVerdict.valid),
          reason: 'byte $index accepted after being flipped',
        );
      }
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
