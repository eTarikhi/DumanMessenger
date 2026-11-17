import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Raised when a binding's bytes are not a binding. Never repaired into one.
class G2dKeyBindingFormatException implements Exception {
  const G2dKeyBindingFormatException(this.message);

  final String message;

  @override
  String toString() => 'G2dKeyBindingFormatException: $message';
}

/// What a verification concluded.
///
/// [identityMismatch] is deliberately separate from [invalidSignature]: a binding
/// can carry a perfectly good signature from a key that is simply not the identity
/// the caller pinned, and collapsing the two would report a substitution attempt as
/// ordinary corruption.
enum G2dBindingVerdict {
  valid,
  invalidSignature,
  identityMismatch;

  bool get isValid => this == G2dBindingVerdict.valid;
}

/// The signed statement "this X25519 exchange key belongs to this Ed25519 identity".
///
/// ### Status: provisional, and not the format the specification is waiting for
///
/// `docs/mobile/IDENTITY-AND-KEYS.md` describes a COSE_Sign1 container over
/// deterministic CBOR, marks that sketch **illustrative, not frozen**, and states
/// that the exact fields, content type, digest, identifier and suite are unapproved
/// application schema that must not be implemented as a format without owner and
/// independent security review. This class is therefore **not** that container and
/// makes no COSE or CBOR claim.
///
/// It is the smallest thing that can carry the proof the installation is missing —
/// that one exchange static belongs to one signing root — in a form that is
/// deterministic, versioned, domain-separated and reproducible from this docstring by
/// a second implementation. When the COSE schema is approved, that becomes version 2
/// and version 1 bindings become history; they are not silently reinterpreted.
///
/// ### Canonical signed bytes (version 1)
///
/// Big-endian, fixed order, every variable-length field length-prefixed, no maps, no
/// JSON, no platform-dependent defaults:
///
/// ```text
/// u8   version           = 0x01
/// u8   suite             = 0x01   (ed25519_x25519)
/// u8   domain length     = 18
///      domain            = "DumanKeyBinding/v1" in ASCII
/// u8   key length        = 32
///      ed25519 public key
/// u8   key length        = 32
///      x25519 public key
/// u32  generation        (>= 1)
/// u8   previous flag     = 0 or 1
/// [u8  digest length     = 32
///      previous binding digest]    present iff previous flag == 1
/// ```
///
/// The signature is `Ed25519(signingBytes)` under the identity root and is appended
/// to produce [toBytes]. The domain string is what stops these bytes from being a
/// valid signature over anything else this app signs.
///
/// ### What this proves, and what it does not
///
/// It proves possession of the Ed25519 private key and that its holder vouched for the
/// listed exchange key at the stated generation. It does **not** prove that a remote
/// person is who they claim, that the exchange key is uncompromised, that the binding
/// is current (a replayed older binding verifies), or that anything is encrypted. It
/// also does not make the keys hardware-backed.
///
/// This type holds public keys and a signature. It never holds, accepts, or returns a
/// private key or seed, and [toString] omits the signature so a stray log line cannot
/// carry one.
class G2dKeyBinding {
  G2dKeyBinding({
    required List<int> ed25519PublicKey,
    required List<int> x25519PublicKey,
    this.generation = 1,
    List<int>? previousBindingDigest,
    required List<int> signature,
  })  : ed25519PublicKey = _fixed(ed25519PublicKey, keyLength, 'Ed25519 public key'),
        x25519PublicKey = _fixed(x25519PublicKey, keyLength, 'X25519 public key'),
        previousBindingDigest = previousBindingDigest == null
            ? null
            : _fixed(previousBindingDigest, digestLength, 'Previous binding digest'),
        signature = _fixed(signature, signatureLength, 'Signature') {
    if (generation < 1 || generation > maxGeneration) {
      throw const G2dKeyBindingFormatException(
        'A binding generation must be between 1 and 2^32-1.',
      );
    }
    // Generation 1 has no predecessor, and every later generation names one. Requiring
    // both directions stops a rotation from being expressible as a fresh first binding,
    // which is exactly how a substituted exchange key would try to arrive.
    if (generation == 1 && previousBindingDigest != null) {
      throw const G2dKeyBindingFormatException(
        'Generation 1 cannot name a previous binding digest.',
      );
    }
    if (generation > 1 && previousBindingDigest == null) {
      throw const G2dKeyBindingFormatException(
        'Generation 2 and later must name the previous binding digest.',
      );
    }
  }

  /// Version of the encoding this class reads and writes.
  static const int formatVersion = 1;

  /// Algorithm suite tag: one Ed25519 root, one X25519 exchange static.
  static const int suiteEd25519X25519 = 1;

  /// Domain separator for the signed bytes.
  static const String signingDomain = 'DumanKeyBinding/v1';

  /// Domain separator for the binding digest. Distinct from [signingDomain], so a
  /// digest can never be mistaken for the bytes that were signed.
  static const String digestDomain = 'DumanKeyBindingDigest/v1';

  /// Domain separator for the exchange-key fingerprint. Distinct from the identity
  /// fingerprint's `DumanDevice/v1`, which this class never re-derives or redefines.
  static const String exchangeFingerprintDomain = 'DumanExchange/v1';

  static const int keyLength = 32;
  static const int digestLength = 32;
  static const int signatureLength = 64;
  static const int maxGeneration = 0xFFFFFFFF;

  /// Ed25519 public key: the identity root, and the key that signs this binding.
  final Uint8List ed25519PublicKey;

  /// X25519 public key: the exchange static this binding makes attributable.
  final Uint8List x25519PublicKey;

  /// Monotonic count of bindings issued under this identity. Rotation increments it.
  final int generation;

  /// Digest of the binding this one replaces, for generation 2 and later.
  final Uint8List? previousBindingDigest;

  /// Ed25519 signature over [signingBytes].
  final Uint8List signature;

  /// The canonical bytes that are signed.
  ///
  /// Deterministic by construction: same inputs, same bytes, on every platform.
  Uint8List get signingBytes => _encodeHeader(
        ed25519PublicKey: ed25519PublicKey,
        x25519PublicKey: x25519PublicKey,
        generation: generation,
        previousBindingDigest: previousBindingDigest,
      );

  /// The binding as one byte string: [signingBytes] followed by the signature.
  Uint8List toBytes() {
    final Uint8List header = signingBytes;
    final Uint8List out = Uint8List(header.length + signatureLength)
      ..setRange(0, header.length, header)
      ..setRange(header.length, header.length + signatureLength, signature);
    return out;
  }

  /// Transport form for a QR code or a future invite. Not a frozen QR schema.
  String toBase64Url() => base64Url.encode(toBytes());

  /// Strict decoder: every length, flag and version is checked, and trailing bytes
  /// are an error rather than an extension point.
  static G2dKeyBinding fromBytes(List<int> bytes) {
    if (bytes.length < _headerMinimum) {
      throw const G2dKeyBindingFormatException('The binding is too short.');
    }
    var offset = 0;
    int take(int count, String label) {
      if (offset + count > bytes.length) {
        throw G2dKeyBindingFormatException('The binding ends inside $label.');
      }
      offset += count;
      return offset - count;
    }

    final int version = bytes[take(1, 'the version')];
    if (version != formatVersion) {
      throw G2dKeyBindingFormatException('Unsupported binding version $version.');
    }
    final int suite = bytes[take(1, 'the suite')];
    if (suite != suiteEd25519X25519) {
      throw G2dKeyBindingFormatException('Unsupported binding suite $suite.');
    }
    final int domainLength = bytes[take(1, 'the domain length')];
    final int domainStart = take(domainLength, 'the domain');
    final String domain;
    try {
      domain = ascii.decode(bytes.sublist(domainStart, domainStart + domainLength));
    } on FormatException {
      throw const G2dKeyBindingFormatException('The domain is not ASCII.');
    }
    if (domain != signingDomain) {
      throw G2dKeyBindingFormatException('Wrong domain "$domain".');
    }
    final int edLength = bytes[take(1, 'the Ed25519 key length')];
    if (edLength != keyLength) {
      throw G2dKeyBindingFormatException('Wrong Ed25519 key length $edLength.');
    }
    final int edStart = take(keyLength, 'the Ed25519 key');
    final int xLength = bytes[take(1, 'the X25519 key length')];
    if (xLength != keyLength) {
      throw G2dKeyBindingFormatException('Wrong X25519 key length $xLength.');
    }
    final int xStart = take(keyLength, 'the X25519 key');
    final int genStart = take(4, 'the generation');
    final int generation = (bytes[genStart] << 24) |
        (bytes[genStart + 1] << 16) |
        (bytes[genStart + 2] << 8) |
        bytes[genStart + 3];
    final int flag = bytes[take(1, 'the previous-digest flag')];
    if (flag > 1) {
      throw G2dKeyBindingFormatException('Invalid previous-digest flag $flag.');
    }
    Uint8List? previous;
    if (flag == 1) {
      final int prevLength = bytes[take(1, 'the previous digest length')];
      if (prevLength != digestLength) {
        throw G2dKeyBindingFormatException('Wrong previous digest length $prevLength.');
      }
      final int prevStart = take(digestLength, 'the previous digest');
      previous = Uint8List.fromList(bytes.sublist(prevStart, prevStart + digestLength));
    }
    final int sigLength = bytes[take(1, 'the signature length')];
    if (sigLength != signatureLength) {
      throw G2dKeyBindingFormatException('Wrong signature length $sigLength.');
    }
    final int sigStart = take(signatureLength, 'the signature');
    if (offset != bytes.length) {
      throw G2dKeyBindingFormatException(
        'The binding carries ${bytes.length - offset} trailing byte(s).',
      );
    }
    return G2dKeyBinding(
      ed25519PublicKey: bytes.sublist(edStart, edStart + keyLength),
      x25519PublicKey: bytes.sublist(xStart, xStart + keyLength),
      generation: generation,
      previousBindingDigest: previous,
      signature: bytes.sublist(sigStart, sigStart + signatureLength),
    );
  }

  static G2dKeyBinding fromBase64Url(String encoded) {
    final List<int> bytes;
    try {
      bytes = base64Url.decode(encoded);
    } on FormatException {
      throw const G2dKeyBindingFormatException('The binding is not base64url.');
    }
    return fromBytes(bytes);
  }

  /// Signs a binding for the exchange key named by [x25519PublicKey].
  ///
  /// Takes the identity **seed** because signing is the one operation that needs it, and
  /// returns a value that contains only public keys. Nothing derived from the seed is
  /// kept, returned, or logged.
  static Future<G2dKeyBinding> sign({
    required List<int> ed25519Seed,
    required List<int> x25519PublicKey,
    int generation = 1,
    List<int>? previousBindingDigest,
  }) async {
    if (ed25519Seed.length != keyLength) {
      throw const G2dKeyBindingFormatException(
        'The identity seed must be 32 bytes.',
      );
    }
    final Ed25519 ed25519 = Ed25519();
    final SimpleKeyPair pair = await ed25519.newKeyPairFromSeed(ed25519Seed);
    final SimplePublicKey publicKey = await pair.extractPublicKey();
    // Encode first, then sign exactly those bytes: the signature can never cover a
    // different encoding from the one that will be verified.
    final Uint8List header = _encodeHeader(
      ed25519PublicKey: publicKey.bytes,
      x25519PublicKey: x25519PublicKey,
      generation: generation,
      previousBindingDigest: previousBindingDigest,
    );
    final Signature signature = await ed25519.sign(header, keyPair: pair);
    return G2dKeyBinding(
      ed25519PublicKey: publicKey.bytes,
      x25519PublicKey: x25519PublicKey,
      generation: generation,
      previousBindingDigest: previousBindingDigest,
      signature: signature.bytes,
    );
  }

  /// Verifies the signature, and — when [expectedEd25519PublicKey] is supplied — that the
  /// signing identity is the one the caller already pinned.
  ///
  /// The identity comparison happens first: a valid signature by an unexpected key is a
  /// substitution, not a corruption, and the caller must be able to tell them apart.
  Future<G2dBindingVerdict> verify({List<int>? expectedEd25519PublicKey}) async {
    if (expectedEd25519PublicKey != null) {
      if (expectedEd25519PublicKey.length != keyLength) {
        throw const G2dKeyBindingFormatException(
          'The expected identity key must be 32 bytes.',
        );
      }
      if (!_sameBytes(expectedEd25519PublicKey, ed25519PublicKey)) {
        return G2dBindingVerdict.identityMismatch;
      }
    }
    final bool ok = await Ed25519().verify(
      signingBytes,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(ed25519PublicKey, type: KeyPairType.ed25519),
      ),
    );
    return ok ? G2dBindingVerdict.valid : G2dBindingVerdict.invalidSignature;
  }

  /// `SHA-256("DumanKeyBindingDigest/v1" || toBytes())`.
  ///
  /// Deterministic, and what a rotation names as its [previousBindingDigest].
  Future<List<int>> digest() async {
    final List<int> domain = utf8.encode(digestDomain);
    final Uint8List body = toBytes();
    final Uint8List input = Uint8List(domain.length + body.length)
      ..setRange(0, domain.length, domain)
      ..setRange(domain.length, domain.length + body.length, body);
    final Hash hash = await Sha256().hash(input);
    return hash.bytes;
  }

  /// `SHA-256("DumanExchange/v1" || x25519_public_key)`, lowercase hex.
  ///
  /// Identifies the exchange key only. It is **not** the identity fingerprint, is not a
  /// substitute for one, and never appears where a user is asked to compare an identity.
  Future<String> exchangeKeyFingerprint() async {
    final List<int> domain = utf8.encode(exchangeFingerprintDomain);
    final Uint8List input = Uint8List(domain.length + x25519PublicKey.length)
      ..setRange(0, domain.length, domain)
      ..setRange(domain.length, domain.length + x25519PublicKey.length, x25519PublicKey);
    final Hash hash = await Sha256().hash(input);
    return hash.bytes
        .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// True when this binding is exactly the next step after [previous]: one generation
  /// later, and naming [previous]'s digest.
  ///
  /// Rejects a rotation that skips a generation, a lower generation replayed after a
  /// higher one, and a "new" binding that does not point at the binding it replaces.
  Future<bool> continuesFrom(G2dKeyBinding previous) async {
    if (generation != previous.generation + 1) {
      return false;
    }
    final List<int> expected = await previous.digest();
    final Uint8List? claimed = previousBindingDigest;
    return claimed != null && _sameBytes(claimed, expected);
  }

  /// True when this binding is about the same two keys as [other], ignoring generation,
  /// history and signature.
  bool bindsSameKeysAs(G2dKeyBinding other) =>
      _sameBytes(ed25519PublicKey, other.ed25519PublicKey) &&
      _sameBytes(x25519PublicKey, other.x25519PublicKey);

  /// Deliberately omits the signature and both keys' bytes.
  @override
  String toString() => 'G2dKeyBinding(v$formatVersion, generation $generation)';

  static const int _headerMinimum = 1 + 1 + 1 + 1 + 1 + 1 + 4 + 1 + 1;

  static Uint8List _encodeHeader({
    required List<int> ed25519PublicKey,
    required List<int> x25519PublicKey,
    required int generation,
    required List<int>? previousBindingDigest,
  }) {
    final Uint8List ed = _fixed(ed25519PublicKey, keyLength, 'Ed25519 public key');
    final Uint8List x = _fixed(x25519PublicKey, keyLength, 'X25519 public key');
    final Uint8List? previous = previousBindingDigest == null
        ? null
        : _fixed(previousBindingDigest, digestLength, 'Previous binding digest');
    if (generation < 1 || generation > maxGeneration) {
      throw const G2dKeyBindingFormatException(
        'A binding generation must be between 1 and 2^32-1.',
      );
    }
    if (generation == 1 && previous != null) {
      throw const G2dKeyBindingFormatException(
        'Generation 1 cannot name a previous binding digest.',
      );
    }
    if (generation > 1 && previous == null) {
      throw const G2dKeyBindingFormatException(
        'Generation 2 and later must name the previous binding digest.',
      );
    }

    final Uint8List domain = Uint8List.fromList(ascii.encode(signingDomain));
    final int length = 1 + 1 + 1 + domain.length + 1 + keyLength + 1 + keyLength + 4 + 1 +
        (previous == null ? 0 : 1 + digestLength);
    final Uint8List out = Uint8List(length);
    var offset = 0;
    out[offset++] = formatVersion;
    out[offset++] = suiteEd25519X25519;
    out[offset++] = domain.length;
    out.setRange(offset, offset + domain.length, domain);
    offset += domain.length;
    out[offset++] = keyLength;
    out.setRange(offset, offset + keyLength, ed);
    offset += keyLength;
    out[offset++] = keyLength;
    out.setRange(offset, offset + keyLength, x);
    offset += keyLength;
    out[offset++] = (generation >> 24) & 0xFF;
    out[offset++] = (generation >> 16) & 0xFF;
    out[offset++] = (generation >> 8) & 0xFF;
    out[offset++] = generation & 0xFF;
    out[offset++] = previous == null ? 0 : 1;
    if (previous != null) {
      out[offset++] = digestLength;
      out.setRange(offset, offset + digestLength, previous);
      offset += digestLength;
    }
    return out;
  }

  static Uint8List _fixed(List<int> bytes, int length, String label) {
    if (bytes.length != length) {
      throw G2dKeyBindingFormatException(
        '$label must be $length bytes, got ${bytes.length}.',
      );
    }
    return Uint8List.fromList(bytes);
  }

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
}
