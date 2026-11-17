import 'package:cryptography/cryptography.dart';
import 'package:duman_messenger/identity/binding_trust.dart';
import 'package:duman_messenger/identity/key_binding.dart';
import 'package:flutter_test/flutter_test.dart';

/// Focused tests for the identity verification state model.
///
/// The point of every case here is the same invariant from a different side: a valid
/// cryptographic binding never becomes trust on its own.
void main() {
  const String identityA = 'aa' 'aa' 'aa' 'aa' 'aa' 'aa' 'aa' 'aa'
      'aa' 'aa' 'aa' 'aa' 'aa' 'aa' 'aa' 'aa'
      'aa' 'aa' 'aa' 'aa' 'aa' 'aa' 'aa' 'aa'
      'aa' 'aa' 'aa' 'aa' 'aa' 'aa' 'aa' 'aa';
  const String identityB = 'bb' 'bb' 'bb' 'bb' 'bb' 'bb' 'bb' 'bb'
      'bb' 'bb' 'bb' 'bb' 'bb' 'bb' 'bb' 'bb'
      'bb' 'bb' 'bb' 'bb' 'bb' 'bb' 'bb' 'bb'
      'bb' 'bb' 'bb' 'bb' 'bb' 'bb' 'bb' 'bb';

  test('a valid binding on first sighting is unverified, not trust', () async {
    final _Keys keys = await _keys(5);
    final G2dKeyBinding binding = keys.binding;

    expect(
      await G2dIdentityBindingEvaluator.evaluate(
        binding: binding,
        identityFingerprint: identityA,
      ),
      G2dIdentityVerificationState.unverified,
    );
  });

  test('acceptance is explicit and only reachable from a verified binding', () async {
    final _Keys keys = await _keys(9);
    final G2dKeyBinding binding = keys.binding;

    final G2dIdentityBindingRecord seen = G2dIdentityBindingRecord(
      identityFingerprint: identityA,
      exchangeFingerprint: 'cc' * 32,
    );
    expect(
      () => seen.accept(atMillis: 1000),
      throwsA(isA<G2dBindingStateError>()),
      reason: 'an unverified record cannot be accepted',
    );

    final G2dIdentityBindingRecord verified = G2dIdentityBindingRecord(
      identityFingerprint: identityA,
      exchangeFingerprint: await binding.exchangeKeyFingerprint(),
    );
    expect(
      await G2dIdentityBindingEvaluator.evaluate(
        binding: binding,
        identityFingerprint: identityA,
        previous: verified,
      ),
      G2dIdentityVerificationState.bindingVerified,
    );

    final G2dIdentityBindingRecord accepted = verified.accept(atMillis: 1234);
    expect(accepted.state, G2dIdentityVerificationState.acceptedByUser);
    expect(accepted.acceptedAtMillis, 1234);
    expect(
      accepted.acceptsExactly(
        identity: identityA,
        exchange: await binding.exchangeKeyFingerprint(),
      ),
      isTrue,
    );
    expect(
      accepted.acceptsExactly(identity: identityB, exchange: 'cc' * 32),
      isFalse,
    );
    expect(
      await G2dIdentityBindingEvaluator.evaluate(
        binding: binding,
        identityFingerprint: identityA,
        previous: accepted,
      ),
      G2dIdentityVerificationState.acceptedByUser,
    );
    expect(accepted.toString(), isNot(contains('aa')));
  });

  test('a binding that fails its own signature is invalid, even beside a good record',
      () async {
    final _Keys keys = await _keys(13);
    final List<int> bytes = keys.binding.toBytes();
    bytes[57] = bytes[57] ^ 0x01;
    final G2dKeyBinding tampered = G2dKeyBinding.fromBytes(bytes);

    final G2dIdentityBindingRecord accepted = G2dIdentityBindingRecord(
      identityFingerprint: identityA,
      exchangeFingerprint: await keys.binding.exchangeKeyFingerprint(),
    ).accept(atMillis: 4321);

    expect(
      await G2dIdentityBindingEvaluator.evaluate(
        binding: tampered,
        identityFingerprint: identityA,
        previous: accepted,
      ),
      G2dIdentityVerificationState.bindingInvalid,
    );
  });

  test('a different identity key is a change, and acceptance must be redone', () async {
    final _Keys keys = await _keys(17);
    final G2dIdentityBindingRecord accepted = G2dIdentityBindingRecord(
      identityFingerprint: identityA,
      exchangeFingerprint: await keys.binding.exchangeKeyFingerprint(),
    ).accept(atMillis: 2000);

    expect(
      await G2dIdentityBindingEvaluator.evaluate(
        binding: keys.binding,
        identityFingerprint: identityB,
        previous: accepted,
      ),
      G2dIdentityVerificationState.identityChanged,
    );

    final G2dIdentityBindingRecord changed = accepted._asChanged(identityB);
    expect(
      () => changed.accept(atMillis: 3000),
      throwsA(isA<G2dBindingStateError>()),
      reason: 'a changed identity needs its own ceremony',
    );
    final G2dIdentityBindingRecord reaffirmed =
        changed.acceptChangedIdentity(atMillis: 3000);
    expect(reaffirmed.state, G2dIdentityVerificationState.acceptedByUser);
    expect(reaffirmed.identityFingerprint, identityB);
    expect(reaffirmed.previousIdentityFingerprint, identityA);
    expect(reaffirmed.reason, G2dIdentityBindingRecord.reasonUserAcceptedIdentityChange);
  });

  test('a substituted exchange key does not inherit acceptance', () async {
    final _Keys keys = await _keys(19);
    final _Keys other = await _keys(29);
    final G2dIdentityBindingRecord accepted = G2dIdentityBindingRecord(
      identityFingerprint: identityA,
      exchangeFingerprint: await other.binding.exchangeKeyFingerprint(),
    ).accept(atMillis: 1500);

    expect(
      await G2dIdentityBindingEvaluator.evaluate(
        binding: keys.binding,
        identityFingerprint: identityA,
        previous: accepted,
      ),
      G2dIdentityVerificationState.identityChanged,
    );
  });

  test('a rotation that does not continue the chain is refused', () async {
    final _Keys keys = await _keys(23);
    final G2dKeyBinding first = keys.binding;
    final G2dKeyBinding skipped = await G2dKeyBinding.sign(
      ed25519Seed: keys.seed,
      x25519PublicKey: keys.x25519PublicKey,
      generation: 3,
      previousBindingDigest: await first.digest(),
    );

    expect(await skipped.verify(), G2dBindingVerdict.valid);
    expect(
      await G2dIdentityBindingEvaluator.evaluate(
        binding: skipped,
        identityFingerprint: identityA,
        previousBinding: first,
      ),
      G2dIdentityVerificationState.bindingInvalid,
      reason: 'a valid signature over a skipped generation is still a substitution',
    );
  });

  test('the record codec is strict and round-trips an acceptance', () async {
    final _Keys keys = await _keys(31);
    final G2dIdentityBindingRecord accepted = G2dIdentityBindingRecord(
      identityFingerprint: identityA,
      exchangeFingerprint: await keys.binding.exchangeKeyFingerprint(),
    ).accept(atMillis: 7777);

    final G2dIdentityBindingRecord decoded =
        G2dIdentityBindingRecord.fromMap(accepted.toMap());
    expect(decoded.toMap(), accepted.toMap());
    expect(decoded.state, G2dIdentityVerificationState.acceptedByUser);

    // An acceptance with no time, no reason, or a reason that is not the user's is refused.
    expect(
      () => G2dIdentityBindingRecord.fromMap(<String, Object?>{
        'version': 1,
        'identityFingerprint': identityA,
        'exchangeFingerprint': 'cc' * 32,
        'state': 'acceptedByUser',
      }),
      throwsFormatException,
    );
    expect(
      () => G2dIdentityBindingRecord.fromMap(<String, Object?>{
        'version': 1,
        'identityFingerprint': identityA,
        'exchangeFingerprint': 'cc' * 32,
        'state': 'trusted',
      }),
      throwsFormatException,
    );
    expect(
      () => G2dIdentityBindingRecord.fromMap(<String, Object?>{
        'version': 2,
        'identityFingerprint': identityA,
        'exchangeFingerprint': 'cc' * 32,
        'state': 'unverified',
      }),
      throwsFormatException,
    );
    // A fingerprint that is not the shape the rest of the app produces is refused.
    expect(
      () => G2dIdentityBindingRecord(
        identityFingerprint: 'not-a-fingerprint',
        exchangeFingerprint: 'cc' * 32,
      ),
      throwsFormatException,
    );
  });
}

class _Keys {
  const _Keys({required this.seed, required this.x25519PublicKey, required this.binding});

  final List<int> seed;
  final List<int> x25519PublicKey;
  final G2dKeyBinding binding;
}

Future<_Keys> _keys(int base) async {
  final List<int> seed = List<int>.generate(32, (int i) => (base + i) & 0xFF);
  final SimpleKeyPair edPair = await Ed25519().newKeyPairFromSeed(seed);
  final SimplePublicKey edPublic = await edPair.extractPublicKey();
  final List<int> xSeed = List<int>.generate(32, (int i) => (base * 5 + i) & 0xFF);
  final SimpleKeyPair xPair = await X25519().newKeyPairFromSeed(xSeed);
  final SimplePublicKey xPublic = await xPair.extractPublicKey();

  final G2dKeyBinding binding = await G2dKeyBinding.sign(
    ed25519Seed: seed,
    x25519PublicKey: xPublic.bytes,
  );
  expect(binding.ed25519PublicKey, edPublic.bytes);
  return _Keys(seed: seed, x25519PublicKey: xPublic.bytes, binding: binding);
}

extension on G2dIdentityBindingRecord {
  /// Rebuilds this record as a changed identity, which is how a caller would persist a
  /// change it observed. Mirrors the evaluator's verdict without widening the public API.
  G2dIdentityBindingRecord _asChanged(String identity) {
    expect(state, G2dIdentityVerificationState.acceptedByUser);
    return G2dIdentityBindingRecord(
      identityFingerprint: identity,
      exchangeFingerprint: exchangeFingerprint,
      state: G2dIdentityVerificationState.identityChanged,
      previousIdentityFingerprint: identityFingerprint,
      stateChangedAtMillis: acceptedAtMillis,
      reason: 'identity_changed',
    );
  }
}
