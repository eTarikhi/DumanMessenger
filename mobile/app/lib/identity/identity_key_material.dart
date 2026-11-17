import 'dart:convert';
import 'dart:typed_data';

/// Real Curve25519 identity key material for one installation.
///
/// This is the first type in the identity stack that holds private key bytes,
/// and what it holds is deliberately narrow:
///
/// * both keys are **software-generated** by `G2dIdentityKeyProvider`; no Android
///   Keystore operation can produce Ed25519 or X25519 keys on the API 27 floor
///   this project targets (`G2dAndroidKeyCapabilities.ed25519KeystoreApiLevel` is
///   33, and X25519 has no Keystore generation path at all);
/// * the message handled here is *serialization*, not cryptography: it is stored
///   only inside the Keystore-wrapped key-material slot, so on disk it exists as
///   AES-256-GCM ciphertext under a non-exportable key;
/// * nothing in this file signs, verifies, derives or formats a fingerprint —
///   that is `G2dIdentityKeyProvider`'s job.
///
/// Honest limits, stated here because they must not be discovered later:
///
/// * while the app is running, these bytes are ordinary Dart memory. They are not
///   hardware-backed and this class must never be presented as such;
/// * Dart cannot reliably zero a `Uint8List` that the garbage collector may have
///   copied, so [ed25519Seed] and [x25519Seed] are not claimed to be zeroized
///   after use. [toString] omits them so a stray log line cannot leak them.
///
/// Format version 1. Unknown fields are ignored on read; an unknown version, an
/// unknown algorithm tag, a wrong field type or a wrong key length is a
/// [FormatException], never a repaired value.
class G2dIdentityKeyMaterial {
  G2dIdentityKeyMaterial({
    required List<int> ed25519Seed,
    required List<int> ed25519PublicKey,
    required List<int> x25519Seed,
    required List<int> x25519PublicKey,
  })  : ed25519Seed = _copyKey(ed25519Seed, 'Ed25519 seed'),
        ed25519PublicKey = _copyKey(ed25519PublicKey, 'Ed25519 public key'),
        x25519Seed = _copyKey(x25519Seed, 'X25519 seed'),
        x25519PublicKey = _copyKey(x25519PublicKey, 'X25519 public key');

  /// Every key in this milestone is 32 bytes: Ed25519 seed and public key per
  /// RFC 8032, X25519 scalar and public key per RFC 7748.
  static const int keyLength = 32;

  /// Wire version of the serialized form.
  static const int formatVersion = 1;

  /// Algorithm pair actually generated. One Ed25519 root plus one independent
  /// X25519 static key, as `docs/mobile/IDENTITY-AND-KEYS.md` requires — there is
  /// deliberately no signed binding between them yet.
  static const String algorithmTag = 'ed25519_x25519';

  /// Ed25519 signing seed (the 32-byte private key of RFC 8032).
  final Uint8List ed25519Seed;

  /// Ed25519 public key, 32 bytes. The identity root.
  final Uint8List ed25519PublicKey;

  /// X25519 private scalar, 32 bytes.
  final Uint8List x25519Seed;

  /// X25519 public key, 32 bytes. The exchange static, not yet bound to the root.
  final Uint8List x25519PublicKey;

  static Uint8List _copyKey(List<int> bytes, String label) {
    if (bytes.length != keyLength) {
      throw FormatException(
        '$label must be $keyLength bytes, got ${bytes.length}.',
      );
    }
    return Uint8List.fromList(bytes);
  }

  /// Serializes for the wrapped key-material slot.
  ///
  /// The returned string contains private keys. It may only be handed to
  /// `G2dKeystoreKeyMaterialStore`, which stores it encrypted, and it must never
  /// be logged, shown, or persisted anywhere else.
  String toJson() => jsonEncode(<String, Object?>{
        'version': formatVersion,
        'algorithm': algorithmTag,
        'ed25519Seed': base64Encode(ed25519Seed),
        'ed25519PublicKey': base64Encode(ed25519PublicKey),
        'x25519Seed': base64Encode(x25519Seed),
        'x25519PublicKey': base64Encode(x25519PublicKey),
      });

  /// Parses a serialized material blob, failing closed on anything unexpected.
  factory G2dIdentityKeyMaterial.fromJson(String payload) {
    final Object? decoded = jsonDecode(payload);
    if (decoded is! Map) {
      throw const FormatException('G2-D identity key material must be a map.');
    }
    final version = decoded['version'];
    if (version != formatVersion) {
      throw FormatException(
        'G2-D identity key material version $version is not supported.',
      );
    }
    final algorithm = decoded['algorithm'];
    if (algorithm != algorithmTag) {
      throw FormatException(
        'G2-D identity key material algorithm $algorithm is not supported.',
      );
    }
    return G2dIdentityKeyMaterial(
      ed25519Seed: _decodeKey(decoded, 'ed25519Seed'),
      ed25519PublicKey: _decodeKey(decoded, 'ed25519PublicKey'),
      x25519Seed: _decodeKey(decoded, 'x25519Seed'),
      x25519PublicKey: _decodeKey(decoded, 'x25519PublicKey'),
    );
  }

  static Uint8List _decodeKey(Map<Object?, Object?> map, String field) {
    final Object? value = map[field];
    if (value is! String) {
      throw FormatException('G2-D identity key material is missing $field.');
    }
    final List<int> bytes;
    try {
      bytes = base64Decode(value);
    } on FormatException {
      throw FormatException('G2-D identity key material $field is not base64.');
    }
    return _copyKey(bytes, 'G2-D identity key material $field');
  }

  /// Lowercase hex of the Ed25519 public key, for tests and comparison only.
  String get ed25519PublicKeyHex => _hex(ed25519PublicKey);

  static String _hex(List<int> bytes) =>
      bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var index = 0; index < a.length; index += 1) {
      if (a[index] != b[index]) {
        return false;
      }
    }
    return true;
  }

  /// Byte equality, used to prove a write actually round-tripped.
  @override
  bool operator ==(Object other) =>
      other is G2dIdentityKeyMaterial &&
      _sameBytes(other.ed25519Seed, ed25519Seed) &&
      _sameBytes(other.ed25519PublicKey, ed25519PublicKey) &&
      _sameBytes(other.x25519Seed, x25519Seed) &&
      _sameBytes(other.x25519PublicKey, x25519PublicKey);

  @override
  int get hashCode => Object.hash(
        Object.hashAll(ed25519Seed),
        Object.hashAll(ed25519PublicKey),
        Object.hashAll(x25519Seed),
        Object.hashAll(x25519PublicKey),
      );

  /// Deliberately hides both seeds and the public keys: this object exists on
  /// paths that can reach a log line, and the seeds are the identity.
  @override
  String toString() => 'G2dIdentityKeyMaterial($algorithmTag, seeds hidden)';
}
