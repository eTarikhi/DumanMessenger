import 'identity_models.dart';
import 'key_binding.dart';

/// The only five things this device is allowed to say about another identity's binding.
///
/// These are deliberately not booleans and deliberately not a ladder that a connection
/// can climb on its own:
///
/// * [bindingVerified] means a signature over the keys checked out. It says nothing about
///   the person, and nothing about whether this device has decided to talk to them.
/// * [acceptedByUser] is the only state in which anything is trusted, and a human reaches
///   it explicitly. No handshake, no successful verification and no first sighting can
///   produce it.
/// * [identityChanged] covers both "different identity key" and "same identity, different
///   exchange key". A new exchange key is a substitution until a person says otherwise, so
///   it does not inherit an earlier acceptance.
/// * [bindingInvalid] means the bytes did not verify. It is not a softer [unverified]: a
///   binding that fails its own signature must never be presented as merely unproven.
enum G2dIdentityVerificationState {
  unverified,
  bindingVerified,
  bindingInvalid,
  identityChanged,
  acceptedByUser;

  /// Honest text for the UI. Never says "secure", never says "verified peer".
  String get label {
    switch (this) {
      case G2dIdentityVerificationState.unverified:
        return 'Unverified — nothing has been accepted for this identity';
      case G2dIdentityVerificationState.bindingVerified:
        return 'Binding verified — signature checked, identity not verified by you';
      case G2dIdentityVerificationState.bindingInvalid:
        return 'Binding invalid — do not trust this identity';
      case G2dIdentityVerificationState.identityChanged:
        return 'Identity changed — re-verification required';
      case G2dIdentityVerificationState.acceptedByUser:
        return 'Accepted by you';
    }
  }
}

/// Raised when a state transition is asked for from a state that does not allow it.
class G2dBindingStateError implements Exception {
  const G2dBindingStateError(this.message);

  final String message;

  @override
  String toString() => 'G2dBindingStateError: $message';
}

/// What this device currently records about one peer's binding.
///
/// It stores fingerprints, not keys, and it stores no trust beyond [state]. The two
/// fingerprints are separate on purpose: the identity fingerprint is the identity root,
/// the exchange fingerprint is the key that would carry traffic, and a rotation moves one
/// without the other.
///
/// Format version 1, strict decode: an unknown state, an unknown version, an invalid
/// fingerprint shape, or an acceptance without the facts acceptance requires is a
/// [FormatException], never a repaired record.
class G2dIdentityBindingRecord {
  G2dIdentityBindingRecord({
    required this.identityFingerprint,
    required this.exchangeFingerprint,
    this.state = G2dIdentityVerificationState.unverified,
    this.previousIdentityFingerprint,
    this.stateChangedAtMillis,
    this.acceptedAtMillis,
    this.reason,
  }) {
    if (!G2dIdentityRecord.isValidFingerprint(identityFingerprint)) {
      throw const FormatException('Invalid identity fingerprint.');
    }
    if (!G2dIdentityRecord.isValidFingerprint(exchangeFingerprint)) {
      throw const FormatException('Invalid exchange fingerprint.');
    }
    if (previousIdentityFingerprint != null &&
        !G2dIdentityRecord.isValidFingerprint(previousIdentityFingerprint!)) {
      throw const FormatException('Invalid previous identity fingerprint.');
    }
    if (state == G2dIdentityVerificationState.acceptedByUser) {
      // Acceptance is a fact with a time and an identity; a record claiming it without
      // either is a record that would let a UI say "verified" for free.
      if (acceptedAtMillis == null || acceptedAtMillis! <= 0) {
        throw const FormatException('An accepted binding needs an acceptance time.');
      }
      if (reason != 'user_accepted' && reason != 'user_accepted_identity_change') {
        throw const FormatException('An accepted binding needs a user acceptance reason.');
      }
    }
  }

  static const int formatVersion = 1;

  /// Reason recorded when a user accepts a verified binding.
  static const String reasonUserAccepted = 'user_accepted';

  /// Reason recorded when a user accepts a changed identity after re-checking it.
  static const String reasonUserAcceptedIdentityChange = 'user_accepted_identity_change';

  final String identityFingerprint;
  final String exchangeFingerprint;
  final G2dIdentityVerificationState state;

  /// The identity fingerprint an accepted change replaced, kept as history.
  final String? previousIdentityFingerprint;

  final int? stateChangedAtMillis;
  final int? acceptedAtMillis;
  final String? reason;

  bool get isAccepted => state == G2dIdentityVerificationState.acceptedByUser;

  /// True only for an accepted record whose fingerprints are exactly [identity] and
  /// [exchange]. Used before any later session is allowed to treat this peer as known.
  bool acceptsExactly({required String identity, required String exchange}) =>
      isAccepted && identityFingerprint == identity && exchangeFingerprint == exchange;

  G2dIdentityBindingRecord _copy({
    G2dIdentityVerificationState? state,
    String? identityFingerprint,
    String? exchangeFingerprint,
    String? previousIdentityFingerprint,
    int? stateChangedAtMillis,
    int? acceptedAtMillis,
    String? reason,
  }) =>
      G2dIdentityBindingRecord(
        identityFingerprint: identityFingerprint ?? this.identityFingerprint,
        exchangeFingerprint: exchangeFingerprint ?? this.exchangeFingerprint,
        state: state ?? this.state,
        previousIdentityFingerprint:
            previousIdentityFingerprint ?? this.previousIdentityFingerprint,
        stateChangedAtMillis: stateChangedAtMillis ?? this.stateChangedAtMillis,
        acceptedAtMillis: acceptedAtMillis ?? this.acceptedAtMillis,
        reason: reason ?? this.reason,
      );

  /// The user accepted this verified binding after comparing it out of band.
  ///
  /// Only reachable from [G2dIdentityVerificationState.bindingVerified]: accepting an
  /// unverified or invalid binding, or silently accepting a changed identity, is exactly
  /// the shortcut this type exists to make impossible.
  G2dIdentityBindingRecord accept({required int atMillis}) {
    if (state != G2dIdentityVerificationState.bindingVerified) {
      throw G2dBindingStateError(
        'cannot accept a binding in state ${state.name}',
      );
    }
    if (atMillis <= 0) {
      throw const G2dBindingStateError('invalid acceptance time');
    }
    return _copy(
      state: G2dIdentityVerificationState.acceptedByUser,
      acceptedAtMillis: atMillis,
      stateChangedAtMillis: atMillis,
      reason: reasonUserAccepted,
    );
  }

  /// The user re-checked a changed identity and accepted the new keys.
  ///
  /// This is the only transition out of [G2dIdentityVerificationState.identityChanged].
  /// The displaced identity fingerprint is kept, so the history is not rewritten.
  G2dIdentityBindingRecord acceptChangedIdentity({required int atMillis}) {
    if (state != G2dIdentityVerificationState.identityChanged) {
      throw G2dBindingStateError(
        'cannot accept an identity change in state ${state.name}',
      );
    }
    if (atMillis <= 0) {
      throw const G2dBindingStateError('invalid acceptance time');
    }
    return _copy(
      state: G2dIdentityVerificationState.acceptedByUser,
      previousIdentityFingerprint: identityFingerprint,
      acceptedAtMillis: atMillis,
      stateChangedAtMillis: atMillis,
      reason: reasonUserAcceptedIdentityChange,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        'version': formatVersion,
        'identityFingerprint': identityFingerprint,
        'exchangeFingerprint': exchangeFingerprint,
        'state': state.name,
        if (previousIdentityFingerprint != null)
          'previousIdentityFingerprint': previousIdentityFingerprint,
        if (stateChangedAtMillis != null) 'stateChangedAtMillis': stateChangedAtMillis,
        if (acceptedAtMillis != null) 'acceptedAtMillis': acceptedAtMillis,
        if (reason != null) 'reason': reason,
      };

  static G2dIdentityBindingRecord fromMap(Object? value) {
    if (value is! Map) {
      throw const FormatException('An identity binding record must be a map.');
    }
    if (value['version'] != formatVersion) {
      throw FormatException(
        'Identity binding record version ${value['version']} is not supported.',
      );
    }
    final Object? identity = value['identityFingerprint'];
    final Object? exchange = value['exchangeFingerprint'];
    final Object? state = value['state'];
    if (identity is! String || exchange is! String || state is! String) {
      throw const FormatException('An identity binding record needs both fingerprints.');
    }
    final Object? changed = value['stateChangedAtMillis'];
    final Object? accepted = value['acceptedAtMillis'];
    final Object? reason = value['reason'];
    final Object? previous = value['previousIdentityFingerprint'];
    if ((changed != null && (changed is! int || changed <= 0)) ||
        (accepted != null && (accepted is! int || accepted <= 0)) ||
        (reason != null && reason is! String) ||
        (previous != null && previous is! String)) {
      throw const FormatException('Invalid identity binding record fields.');
    }
    return G2dIdentityBindingRecord(
      identityFingerprint: identity,
      exchangeFingerprint: exchange,
      state: _stateFromName(state),
      previousIdentityFingerprint: previous as String?,
      stateChangedAtMillis: changed as int?,
      acceptedAtMillis: accepted as int?,
      reason: reason as String?,
    );
  }

  /// Never prints fingerprints: a record can reach a log, and the fingerprints are the
  /// values a user compares, so an unsolicited copy of them is a leak of the thing the
  /// comparison is meant to protect.
  @override
  String toString() => 'G2dIdentityBindingRecord(${state.name})';
}

G2dIdentityVerificationState _stateFromName(String value) {
  for (final G2dIdentityVerificationState state in G2dIdentityVerificationState.values) {
    if (state.name == value) {
      return state;
    }
  }
  throw FormatException('Unknown identity verification state: $value');
}

/// Decides what this device may say about a peer's binding.
///
/// The evaluation is a pure function of the binding, the fingerprints the caller computed
/// with the existing identity fingerprint code, and what was previously recorded. It reads
/// no clock, writes nothing, and never promotes anything to [acceptedByUser].
class G2dIdentityBindingEvaluator {
  const G2dIdentityBindingEvaluator._();

  /// [identityFingerprint] must come from `G2dIdentityKeyProvider.fingerprint` for the
  /// binding's signing key: this class does not re-derive fingerprint semantics, so there
  /// is exactly one definition of what an identity fingerprint is.
  static Future<G2dIdentityVerificationState> evaluate({
    required G2dKeyBinding binding,
    required String identityFingerprint,
    G2dIdentityBindingRecord? previous,
    G2dKeyBinding? previousBinding,
  }) async {
    if (!G2dIdentityRecord.isValidFingerprint(identityFingerprint)) {
      throw const FormatException('Invalid identity fingerprint.');
    }
    final String exchangeFingerprint = await binding.exchangeKeyFingerprint();

    final G2dBindingVerdict verdict = await binding.verify();
    if (!verdict.isValid) {
      return G2dIdentityVerificationState.bindingInvalid;
    }

    // A rotation that does not continue the chain it claims to continue is a substitution,
    // not an update: an older binding replayed as generation n+1 must not be accepted as a
    // fresh rotation.
    if (previousBinding != null && binding.generation != previousBinding.generation) {
      final bool continues = await binding.continuesFrom(previousBinding);
      if (!continues) {
        return G2dIdentityVerificationState.bindingInvalid;
      }
    }

    if (previous == null) {
      // First sighting. A good signature is not trust, and there is nothing yet to have
      // accepted.
      return G2dIdentityVerificationState.unverified;
    }

    if (previous.identityFingerprint != identityFingerprint) {
      return G2dIdentityVerificationState.identityChanged;
    }
    if (previous.exchangeFingerprint != exchangeFingerprint) {
      // Same identity root, different exchange key. Treated as a change requiring an
      // explicit decision rather than as a transparent rotation.
      return G2dIdentityVerificationState.identityChanged;
    }

    return previous.isAccepted
        ? G2dIdentityVerificationState.acceptedByUser
        : G2dIdentityVerificationState.bindingVerified;
  }
}
