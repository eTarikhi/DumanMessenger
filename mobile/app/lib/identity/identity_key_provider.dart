import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'identity_key_material.dart';

/// Raised when real key generation or its self-check fails.
///
/// This is not a "try again quietly" condition: an installation that cannot
/// generate and immediately exercise its own identity keys must not end up with
/// a record pointing at material nobody verified.
class G2dIdentityKeyProviderException implements Exception {
  const G2dIdentityKeyProviderException(this.message);

  final String message;

  @override
  String toString() => 'G2dIdentityKeyProviderException: $message';
}

/// Generates and uses the real Curve25519 identity keys.
///
/// What this is, precisely: an Ed25519 signing root and an independent X25519
/// exchange static generated in software, by `package:cryptography` (pure Dart
/// Ed25519/X25519 — RFC 8032 and RFC 7748), on the device, at creation time. The
/// public fingerprint is `SHA-256("DumanDevice/v1" || ed25519_public_key)`, the
/// domain-separated identifier `docs/mobile/IDENTITY-AND-KEYS.md` describes.
///
/// What this is not:
///
/// * **not hardware-backed.** Android Keystore cannot generate Ed25519 keys below
///   API 33 and has never had an X25519 generation API, so on the API 27 floor
///   the private keys are ordinary software keys. They are protected at rest by a
///   non-exportable Keystore AES key (`software_keystore_wrapped`), and that is
///   the strongest true claim available on this device;
/// * **not a bound identity.** There is no signed binding between the Ed25519
///   root and the X25519 static yet. Nothing here may be described as a device
///   certificate, a verified contact identity, or a session;
/// * **not custom crypto.** The primitives, encodings and validation come from
///   the library; nothing here implements a curve operation.
///
/// Every generated key is exercised before it is returned: a signature is made
/// and verified with the new Ed25519 key, and a shared secret is derived with the
/// new X25519 key against a fresh ephemeral peer. A key that cannot do that is a
/// failure, not a success with a caveat.
class G2dIdentityKeyProvider {
  G2dIdentityKeyProvider({
    Random? random,
    Ed25519? ed25519,
    X25519? x25519,
    Sha256? sha256,
  })  : _random = random ?? Random.secure(),
        _ed25519 = ed25519 ?? Ed25519(),
        _x25519 = x25519 ?? X25519(),
        _sha256 = sha256 ?? Sha256();

  /// Provider name recorded in the identity record's key handle.
  ///
  /// Deliberately not `android_keystore`: the keys are not Keystore keys, and a
  /// name that implied otherwise would be a stored lie.
  static const String providerName = 'duman_software';

  /// Local, non-secret lookup name for the single identity key slot.
  static const String keyAlias = 'identity.key.1';

  /// Domain separator for the public fingerprint. Changing it changes every
  /// fingerprint this app produces, so it is versioned and fixed.
  static const String fingerprintDomain = 'DumanDevice/v1';

  /// Fixed challenge used to prove a freshly generated key signs and verifies.
  static const String selfCheckLabel = 'duman.identity.selfcheck.v1';

  final Random _random;
  final Ed25519 _ed25519;
  final X25519 _x25519;
  final Sha256 _sha256;

  /// Generates a new identity keypair set and proves it works.
  ///
  /// Throws [G2dIdentityKeyProviderException] if generation or the self-check
  /// fails. The caller must not persist anything before this returns.
  Future<G2dIdentityKeyMaterial> generate() async {
    final G2dIdentityKeyMaterial material;
    try {
      final SimpleKeyPair ed25519Pair =
          await _ed25519.newKeyPairFromSeed(_randomSeed()) as SimpleKeyPair;
      final SimpleKeyPair x25519Pair =
          await _x25519.newKeyPairFromSeed(_randomSeed()) as SimpleKeyPair;

      material = G2dIdentityKeyMaterial(
        ed25519Seed: await ed25519Pair.extractPrivateKeyBytes(),
        ed25519PublicKey: (await ed25519Pair.extractPublicKey()).bytes,
        x25519Seed: await x25519Pair.extractPrivateKeyBytes(),
        x25519PublicKey: (await x25519Pair.extractPublicKey()).bytes,
      );
    } catch (error) {
      throw G2dIdentityKeyProviderException(
        'key generation failed: $error',
      );
    }
    await _selfCheck(material);
    return material;
  }

  /// `SHA-256("DumanDevice/v1" || ed25519_public_key)`, lowercase hex.
  ///
  /// The domain prefix is what stops this value from being a bare public-key
  /// hash that could be confused with any other SHA-256 of a key in the system.
  Future<String> fingerprint(G2dIdentityKeyMaterial material) async {
    final List<int> domain = utf8.encode(fingerprintDomain);
    final Uint8List input = Uint8List(domain.length + material.ed25519PublicKey.length)
      ..setRange(0, domain.length, domain)
      ..setRange(domain.length, domain.length + material.ed25519PublicKey.length,
          material.ed25519PublicKey);
    final Hash hash = await _sha256.hash(input);
    return hash.bytes
        .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Signs [message] with the identity's Ed25519 root.
  ///
  /// Public so the milestone can prove the key is usable; no messaging path calls
  /// it yet, and a signature here proves possession of the key and nothing about
  /// any peer.
  Future<List<int>> sign(List<int> message, G2dIdentityKeyMaterial material) async {
    final Signature signature = await _ed25519.sign(
      message,
      keyPair: _ed25519Pair(material),
    );
    return signature.bytes;
  }

  /// Verifies [signature] over [message] with the material's own public key.
  Future<bool> verify(
    List<int> message,
    List<int> signature,
    G2dIdentityKeyMaterial material,
  ) =>
      _ed25519.verify(
        message,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(
            material.ed25519PublicKey,
            type: KeyPairType.ed25519,
          ),
        ),
      );

  /// X25519 key agreement with a peer's 32-byte exchange public key.
  ///
  /// Present so the exchange static can be exercised; no session, handshake or
  /// message encryption is implemented, and an all-zero result is rejected
  /// because it is the low-order-point failure RFC 7748 warns about.
  Future<List<int>> sharedSecret(
    G2dIdentityKeyMaterial material,
    List<int> remoteX25519PublicKey,
  ) async {
    if (remoteX25519PublicKey.length != G2dIdentityKeyMaterial.keyLength) {
      throw const G2dIdentityKeyProviderException(
        'peer X25519 public key must be 32 bytes',
      );
    }
    final SecretKey secret = await _x25519.sharedSecretKey(
      keyPair: _x25519Pair(material),
      remotePublicKey: SimplePublicKey(
        remoteX25519PublicKey,
        type: KeyPairType.x25519,
      ),
    );
    final List<int> bytes = await secret.extractBytes();
    if (bytes.every((int byte) => byte == 0)) {
      throw const G2dIdentityKeyProviderException(
        'X25519 agreement produced an all-zero secret',
      );
    }
    return bytes;
  }

  Future<void> _selfCheck(G2dIdentityKeyMaterial material) async {
    final List<int> challenge = utf8.encode(selfCheckLabel);
    final List<int> signature = await sign(challenge, material);
    if (!await verify(challenge, signature, material)) {
      throw const G2dIdentityKeyProviderException(
        'the generated Ed25519 key did not verify its own signature',
      );
    }

    final SimpleKeyPair peer =
        await _x25519.newKeyPairFromSeed(_randomSeed()) as SimpleKeyPair;
    final List<int> peerPublic = (await peer.extractPublicKey()).bytes;
    final List<int> secret = await sharedSecret(material, peerPublic);
    if (secret.length != G2dIdentityKeyMaterial.keyLength) {
      throw const G2dIdentityKeyProviderException(
        'X25519 agreement returned a secret of the wrong length',
      );
    }
  }

  List<int> _randomSeed() {
    final Uint8List seed = Uint8List(G2dIdentityKeyMaterial.keyLength);
    for (var index = 0; index < seed.length; index += 1) {
      seed[index] = _random.nextInt(256);
    }
    return seed;
  }

  SimpleKeyPairData _ed25519Pair(G2dIdentityKeyMaterial material) =>
      SimpleKeyPairData(
        Uint8List.fromList(material.ed25519Seed),
        publicKey: SimplePublicKey(
          Uint8List.fromList(material.ed25519PublicKey),
          type: KeyPairType.ed25519,
        ),
        type: KeyPairType.ed25519,
      );

  SimpleKeyPairData _x25519Pair(G2dIdentityKeyMaterial material) =>
      SimpleKeyPairData(
        Uint8List.fromList(material.x25519Seed),
        publicKey: SimplePublicKey(
          Uint8List.fromList(material.x25519PublicKey),
          type: KeyPairType.x25519,
        ),
        type: KeyPairType.x25519,
      );
}
