/// G2-D peer trust model.
///
/// Transport, session and identity facts are separate axes. They are never
/// collapsed into one "trusted" or "secure" boolean, and none of them is granted
/// automatically:
///
/// 1. discovered          — a radio candidate matched the service UUID
/// 2. connected           — a GATT link exists
/// 3. serviceReady        — expected characteristics present, notifications set up
/// 4. sessionEstablished  — a cryptographic handshake completed (provider-owned)
/// 5. identityAuthenticated — the handshake is bound to a concrete peer identity key
/// 6. userVerified        — a human compared the fingerprint out of band
/// 7. disconnected/revoked — no link; verified facts persist, revocation is terminal
///
/// A successful BLE connection proves nothing about who operates the remote
/// device. Only axis 6 is a user decision, and only axis 5 is cryptographic.
///
/// The record separates three different fingerprints, and the distinction is
/// security-relevant:
///
/// - [G2dPeerTrustRecord.identityFingerprint] — the **pin**: the identity the user
///   has been shown and, if verified, compared. Only a completed ceremony changes
///   it.
/// - [G2dPeerTrustRecord.observedIdentityFingerprint] — a different key that was
///   seen on the wire. Recording it does **not** move the pin.
/// - [G2dPeerTrustRecord.previousIdentityFingerprint] — historical evidence: the
///   key a pin replaced, or the key a revoked record refers to.
library;

import 'identity_models.dart';

/// Ordered evidence axes. The declaration order is the required order: a later
/// axis cannot be recorded unless every earlier axis is present.
enum G2dPeerTrustAxis {
  discovered,
  connected,
  serviceReady,
  sessionEstablished,
  identityAuthenticated,
  userVerified,
}

/// How a user compared a peer identity.
enum G2dVerificationMethod {
  outOfBandFingerprint('out_of_band_fingerprint'),
  scannedQrCode('scanned_qr_code');

  const G2dVerificationMethod(this.wireName);

  final String wireName;
}

/// Why a peer record was revoked.
enum G2dPeerRevocationReason {
  userRequested('user_requested'),
  identityChanged('identity_changed'),

  /// The user accepted a new identity for a peer during a re-verification
  /// ceremony. The old key stays revoked.
  replacedByIdentityRotation('replaced_by_identity_rotation');

  const G2dPeerRevocationReason(this.wireName);

  final String wireName;
}

/// A peer's local trust record. Local only: peer identifiers here are opaque
/// local handles, never Bluetooth addresses and never a public address.
class G2dPeerTrustRecord {
  G2dPeerTrustRecord({
    required this.peerId,
    Set<G2dPeerTrustAxis> axes = const <G2dPeerTrustAxis>{},
    this.identityFingerprint,
    this.observedIdentityFingerprint,
    this.previousIdentityFingerprint,
    this.verifiedAtMillis,
    this.verificationMethod,
    this.identityChangedAtMillis,
    this.revokedAtMillis,
    this.revocationReason,
  }) : axes = Set<G2dPeerTrustAxis>.unmodifiable(axes);

  /// Longest accepted opaque peer handle.
  static const int maxPeerIdLength = 64;

  final String peerId;

  /// The pinned peer identity fingerprint: the one the user was shown, and the
  /// one an explicit ceremony compared. Set when the peer identity is
  /// authenticated; `null` before that and after revocation.
  ///
  /// A newly observed, different fingerprint never replaces this value.
  final String? identityFingerprint;

  /// A fingerprint observed on the wire that differs from [identityFingerprint].
  ///
  /// Non-null only while the peer is in the changed-identity state, which fails
  /// closed: nothing is trusted for this peer until the user completes a fresh
  /// comparison, at which point this value is promoted into the pin.
  final String? observedIdentityFingerprint;

  /// The fingerprint this pin replaced, when a re-verification promoted a new
  /// identity, or the fingerprint a revoked record refers to.
  final String? previousIdentityFingerprint;

  final Set<G2dPeerTrustAxis> axes;
  final int? verifiedAtMillis;
  final G2dVerificationMethod? verificationMethod;

  /// When a different identity was first observed for this peer. Kept until a
  /// ceremony resolves the change.
  final int? identityChangedAtMillis;

  final int? revokedAtMillis;
  final G2dPeerRevocationReason? revocationReason;

  bool get isRevoked => revokedAtMillis != null;

  bool get isIdentityChanged => observedIdentityFingerprint != null;

  /// Highest axis recorded, or `null` when nothing has been observed.
  G2dPeerTrustAxis? get highestAxis {
    G2dPeerTrustAxis? highest;
    for (final axis in G2dPeerTrustAxis.values) {
      if (axes.contains(axis)) {
        highest = axis;
      }
    }
    return highest;
  }

  /// True only when the user personally compared this identity. Never granted by
  /// a connection, a handshake, or an earlier session, and never while an
  /// identity change is unresolved.
  bool get isUserVerified =>
      !isRevoked &&
      !isIdentityChanged &&
      axes.contains(G2dPeerTrustAxis.userVerified) &&
      verificationMethod != null &&
      verifiedAtMillis != null &&
      identityFingerprint != null;

  /// True only when a session is bound to the pinned peer identity.
  bool get hasAuthenticatedIdentity =>
      !isRevoked &&
      !isIdentityChanged &&
      axes.contains(G2dPeerTrustAxis.identityAuthenticated) &&
      identityFingerprint != null;

  bool get isConnected => !isRevoked && axes.contains(G2dPeerTrustAxis.connected);

  /// A short, honest description for the UI. Deliberately never says "secure".
  String get statusLabel {
    if (isRevoked) {
      return 'Revoked — do not communicate';
    }
    if (isIdentityChanged) {
      return 'Peer identity changed — re-verification required';
    }
    if (!isConnected && isUserVerified) {
      // A pin outlives a link; the label must say so instead of implying that the
      // peer is reachable or that anything is currently encrypted.
      return 'Verified by you — not currently connected';
    }
    final highest = highestAxis;
    if (highest == null) {
      return 'Not discovered';
    }
    if (highest == G2dPeerTrustAxis.userVerified) {
      // The axis is only half the invariant. Label the record by the evidence it
      // actually carries, never by the axis alone.
      return isUserVerified
          ? 'Verified by you (out-of-band comparison)'
          : 'Verification evidence incomplete — not verified';
    }
    return switch (highest) {
      G2dPeerTrustAxis.discovered =>
        'Discovered — untrusted radio candidate, not identified',
      G2dPeerTrustAxis.connected => 'Connected — transport only, identity not authenticated',
      G2dPeerTrustAxis.serviceReady =>
        'Service ready — transport only, identity not authenticated',
      G2dPeerTrustAxis.sessionEstablished =>
        'Session established — peer identity not yet authenticated',
      G2dPeerTrustAxis.identityAuthenticated =>
        'Identity authenticated — not verified by you',
      G2dPeerTrustAxis.userVerified => 'Verification evidence incomplete — not verified',
    };
  }

  /// Encoded form. Symmetric with [fromMap]; both are the only supported way to
  /// move a record across a boundary.
  Map<String, Object?> toMap() => <String, Object?>{
        'peerId': peerId,
        'axes': <String>[
          for (final axis in G2dPeerTrustAxis.values)
            if (axes.contains(axis)) axis.name,
        ],
        if (identityFingerprint != null) 'identityFingerprint': identityFingerprint,
        if (observedIdentityFingerprint != null)
          'observedIdentityFingerprint': observedIdentityFingerprint,
        if (previousIdentityFingerprint != null)
          'previousIdentityFingerprint': previousIdentityFingerprint,
        if (verifiedAtMillis != null) 'verifiedAtMillis': verifiedAtMillis,
        if (verificationMethod != null) 'verificationMethod': verificationMethod!.wireName,
        if (identityChangedAtMillis != null) 'identityChangedAtMillis': identityChangedAtMillis,
        if (revokedAtMillis != null) 'revokedAtMillis': revokedAtMillis,
        if (revocationReason != null) 'revocationReason': revocationReason!.wireName,
      };

  /// Strict decoder.
  ///
  /// Rejects malformed or self-contradictory records instead of repairing them:
  /// an unknown axis, a duplicate axis, a session axis without its transport
  /// axis, verification facts without the verified axis, any facts on a revoked
  /// record, an observed identity equal to the pin, or an observed identity
  /// without a change timestamp. A caller must be able to tell "this record is
  /// wrong" from "this record says the peer is unverified".
  static G2dPeerTrustRecord fromMap(Object? value) {
    if (value is! Map) {
      throw const FormatException('G2-D peer trust record must be a map.');
    }
    final peerId = value['peerId'];
    if (peerId is! String || peerId.isEmpty || peerId.length > maxPeerIdLength) {
      throw const FormatException('Invalid G2-D peer identifier.');
    }
    final rawMethod = value['verificationMethod'];
    final rawReason = value['revocationReason'];
    final record = G2dPeerTrustRecord(
      peerId: peerId,
      axes: _decodeAxes(value['axes']),
      identityFingerprint: _optionalFingerprint(value['identityFingerprint'], 'pinned identity'),
      observedIdentityFingerprint:
          _optionalFingerprint(value['observedIdentityFingerprint'], 'observed identity'),
      previousIdentityFingerprint:
          _optionalFingerprint(value['previousIdentityFingerprint'], 'previous identity'),
      verifiedAtMillis: _optionalMillis(value['verifiedAtMillis'], 'verification time'),
      verificationMethod: rawMethod == null ? null : _decodeMethod(rawMethod),
      identityChangedAtMillis: _optionalMillis(value['identityChangedAtMillis'], 'identity change time'),
      revokedAtMillis: _optionalMillis(value['revokedAtMillis'], 'revocation time'),
      revocationReason: rawReason == null ? null : _decodeReason(rawReason),
    );
    record._validateConsistency();
    return record;
  }

  /// Invariants the rest of G2-D relies on.
  void _validateConsistency() {
    final pin = identityFingerprint;
    final observed = observedIdentityFingerprint;
    final previous = previousIdentityFingerprint;

    if (isRevoked) {
      if (revocationReason == null) {
        throw const FormatException('Revoked G2-D peer record requires a reason.');
      }
      if (axes.isNotEmpty) {
        throw const FormatException('Revoked G2-D peer record must not carry trust axes.');
      }
      if (pin != null || observed != null) {
        throw const FormatException('Revoked G2-D peer record must not carry a pin.');
      }
      if (identityChangedAtMillis != null) {
        throw const FormatException('Revoked G2-D peer record must not carry a pending change.');
      }
      if (verifiedAtMillis != null || verificationMethod != null) {
        throw const FormatException('Revoked G2-D peer record must not carry verification facts.');
      }
    } else if (revocationReason != null) {
      throw const FormatException('Non-revoked G2-D peer record carries a revocation reason.');
    }

    final hasVerificationAxis = axes.contains(G2dPeerTrustAxis.userVerified);
    if (hasVerificationAxis) {
      if (verificationMethod == null || verifiedAtMillis == null) {
        throw const FormatException(
          'User-verified G2-D peer record requires a method and a time.',
        );
      }
      if (pin == null) {
        throw const FormatException('User-verified G2-D peer record requires a pinned identity.');
      }
    } else if (verificationMethod != null || verifiedAtMillis != null) {
      throw const FormatException(
        'Verification facts require the user-verified axis.',
      );
    }

    if (axes.contains(G2dPeerTrustAxis.identityAuthenticated) && pin == null) {
      throw const FormatException(
        'Authenticated G2-D peer record requires a pinned identity.',
      );
    }
    if (observed != null) {
      if (pin == null) {
        throw const FormatException('An observed identity requires a pinned identity.');
      }
      if (identityChangedAtMillis == null) {
        throw const FormatException('An observed identity requires a change time.');
      }
      if (observed == pin) {
        throw const FormatException('An observed identity must differ from the pin.');
      }
    } else if (identityChangedAtMillis != null) {
      throw const FormatException('A change time requires an observed identity.');
    }
    if (previous != null && previous == pin) {
      throw const FormatException('A previous identity must differ from the pin.');
    }
  }

  G2dPeerTrustRecord _withAxes(Set<G2dPeerTrustAxis> nextAxes) => G2dPeerTrustRecord(
        peerId: peerId,
        axes: nextAxes,
        identityFingerprint: identityFingerprint,
        observedIdentityFingerprint: observedIdentityFingerprint,
        previousIdentityFingerprint: previousIdentityFingerprint,
        verifiedAtMillis: verifiedAtMillis,
        verificationMethod: verificationMethod,
        identityChangedAtMillis: identityChangedAtMillis,
        revokedAtMillis: revokedAtMillis,
        revocationReason: revocationReason,
      );

  @override
  bool operator ==(Object other) =>
      other is G2dPeerTrustRecord &&
      other.peerId == peerId &&
      other.identityFingerprint == identityFingerprint &&
      other.observedIdentityFingerprint == observedIdentityFingerprint &&
      other.previousIdentityFingerprint == previousIdentityFingerprint &&
      other.axes.length == axes.length &&
      other.axes.containsAll(axes) &&
      other.verifiedAtMillis == verifiedAtMillis &&
      other.verificationMethod == verificationMethod &&
      other.identityChangedAtMillis == identityChangedAtMillis &&
      other.revokedAtMillis == revokedAtMillis &&
      other.revocationReason == revocationReason;

  @override
  int get hashCode => Object.hash(
        peerId,
        identityFingerprint,
        observedIdentityFingerprint,
        previousIdentityFingerprint,
        Object.hashAllUnordered(axes),
        verifiedAtMillis,
        verificationMethod,
        identityChangedAtMillis,
        revokedAtMillis,
        revocationReason,
      );

  /// Deliberately omits fingerprints and verification data: this string is safe
  /// to put in a diagnostic log.
  @override
  String toString() => 'G2dPeerTrustRecord($peerId, axes=${axes.length}, '
      'changed=$isIdentityChanged, revoked=$isRevoked)';
}

/// Outcome of observing a peer identity.
sealed class G2dPeerIdentityObservation {
  const G2dPeerIdentityObservation();
}

/// First identity seen for this peer: recorded, authenticated, not trusted by
/// the user and not verified.
class G2dPeerIdentityFirstSeen extends G2dPeerIdentityObservation {
  const G2dPeerIdentityFirstSeen(this.record);

  final G2dPeerTrustRecord record;
}

/// The same identity as the existing pin. Session axes advance; nothing is
/// re-verified and nothing is re-trusted.
class G2dPeerIdentityUnchanged extends G2dPeerIdentityObservation {
  const G2dPeerIdentityUnchanged(this.record);

  final G2dPeerTrustRecord record;
}

/// A different identity was observed for a pinned peer.
///
/// The record fails closed: the pin is **not** replaced, the observed value is
/// kept separately, session and verification evidence for the pinned key is
/// dropped, and nothing is trusted until a fresh ceremony promotes the observed
/// fingerprint.
class G2dPeerIdentityChanged extends G2dPeerIdentityObservation {
  const G2dPeerIdentityChanged({
    required this.record,
    required this.previousFingerprint,
    required this.observedFingerprint,
  });

  final G2dPeerTrustRecord record;

  /// The identity that remains pinned.
  final String previousFingerprint;

  /// The identity that was observed on the wire.
  final String observedFingerprint;
}

/// Raised when a peer trust transition is not allowed. These are programming
/// errors or protocol violations, never user-facing states.
class G2dPeerTrustError implements Exception {
  const G2dPeerTrustError(this.reason);

  final String reason;

  @override
  String toString() => 'G2dPeerTrustError($reason)';
}

/// Local trust table. In-memory in this milestone; a durable implementation must
/// reuse the same transitions and the same failure rules.
class G2dPeerTrustStore {
  G2dPeerTrustStore();

  final Map<String, G2dPeerTrustRecord> _records = <String, G2dPeerTrustRecord>{};

  G2dPeerTrustRecord? recordFor(String peerId) => _records[peerId];

  /// Number of tracked peers. Diagnostic only.
  int get length => _records.length;

  /// Records that a radio candidate was seen. Never implies identity.
  G2dPeerTrustRecord markDiscovered(String peerId) =>
      _advance(_requirePeerId(peerId), G2dPeerTrustAxis.discovered);

  G2dPeerTrustRecord markConnected(String peerId) =>
      _advance(_requirePeerId(peerId), G2dPeerTrustAxis.connected);

  G2dPeerTrustRecord markServiceReady(String peerId) =>
      _advance(_requirePeerId(peerId), G2dPeerTrustAxis.serviceReady);

  /// Records that a cryptographic session was established. A session is not a
  /// peer identity: axis 5 still has to be bound to a concrete key.
  G2dPeerTrustRecord markSessionEstablished(String peerId) =>
      _advance(_requirePeerId(peerId), G2dPeerTrustAxis.sessionEstablished);

  /// Binds the established session to an authenticated peer identity key.
  ///
  /// This is the only entry point that can set the pin, and it never replaces an
  /// existing pin: a different fingerprint is recorded as an observation and the
  /// record enters the fail-closed changed state.
  G2dPeerIdentityObservation authenticateIdentity(
    String peerId,
    String fingerprint, {
    required int atMillis,
  }) {
    final id = _requirePeerId(peerId);
    if (!G2dIdentityRecord.isValidFingerprint(fingerprint)) {
      throw const G2dPeerTrustError('invalid peer identity fingerprint');
    }
    if (atMillis <= 0) {
      throw const G2dPeerTrustError('invalid identity authentication time');
    }
    final existing = _records[id];
    if (existing == null) {
      throw const G2dPeerTrustError('peer must be discovered before identity authentication');
    }
    if (existing.isRevoked) {
      throw const G2dPeerTrustError('revoked peer cannot be authenticated');
    }
    if (!existing.axes.contains(G2dPeerTrustAxis.sessionEstablished)) {
      throw const G2dPeerTrustError(
        'peer identity cannot be authenticated before a session is established',
      );
    }

    final pinned = existing.identityFingerprint;
    if (pinned != null && pinned != fingerprint) {
      // A different key than the pin. Record it as observed evidence only: the
      // pin is untouched, the user's verification of the pinned key stops
      // counting, and the change time is preserved if this is a repeat sighting.
      final changed = G2dPeerTrustRecord(
        peerId: id,
        axes: <G2dPeerTrustAxis>{
          ...existing.axes.where((axis) => axis != G2dPeerTrustAxis.userVerified),
          G2dPeerTrustAxis.sessionEstablished,
          G2dPeerTrustAxis.identityAuthenticated,
        },
        identityFingerprint: pinned,
        observedIdentityFingerprint: fingerprint,
        previousIdentityFingerprint: existing.previousIdentityFingerprint,
        identityChangedAtMillis: existing.identityChangedAtMillis ?? atMillis,
      );
      _records[id] = changed;
      return G2dPeerIdentityChanged(
        record: changed,
        previousFingerprint: pinned,
        observedFingerprint: fingerprint,
      );
    }

    // First contact or the same key as the pin. The authenticated fingerprint is
    // written explicitly: on first contact there is no pin yet, and a copy that
    // preserved "no pin" is exactly the defect that made every later observation
    // look like first contact.
    final updated = G2dPeerTrustRecord(
      peerId: id,
      axes: <G2dPeerTrustAxis>{
        ...existing.axes,
        G2dPeerTrustAxis.identityAuthenticated,
      },
      identityFingerprint: fingerprint,
      observedIdentityFingerprint: existing.observedIdentityFingerprint,
      previousIdentityFingerprint: existing.previousIdentityFingerprint,
      verifiedAtMillis: existing.verifiedAtMillis,
      verificationMethod: existing.verificationMethod,
      identityChangedAtMillis: existing.identityChangedAtMillis,
      revokedAtMillis: existing.revokedAtMillis,
      revocationReason: existing.revocationReason,
    );
    _records[id] = updated;

    if (existing.isIdentityChanged) {
      // The pinned key is back on the wire, but a different key was observed for
      // this peer and the user has not resolved that yet: keep failing closed.
      return G2dPeerIdentityChanged(
        record: updated,
        previousFingerprint: pinned ?? fingerprint,
        observedFingerprint: existing.observedIdentityFingerprint!,
      );
    }
    return pinned == fingerprint
        ? G2dPeerIdentityUnchanged(updated)
        : G2dPeerIdentityFirstSeen(updated);
  }

  /// Records an explicit user comparison out of band.
  ///
  /// Requires an authenticated identity. This is the only transition that can
  /// promote an observed fingerprint into the pin, and it is the only way to
  /// clear a pending identity change. It never runs implicitly on a connection,
  /// a discovery, or an observation.
  G2dPeerTrustRecord verifyIdentity({
    required String peerId,
    required G2dVerificationMethod method,
    required int atMillis,
  }) {
    final id = _requirePeerId(peerId);
    final existing = _records[id];
    if (existing == null) {
      throw const G2dPeerTrustError('unknown peer');
    }
    if (existing.isRevoked) {
      throw const G2dPeerTrustError('revoked peer cannot be verified');
    }
    if (!existing.axes.contains(G2dPeerTrustAxis.identityAuthenticated)) {
      throw const G2dPeerTrustError('peer identity must be authenticated before verification');
    }
    if (atMillis <= 0) {
      throw const G2dPeerTrustError('invalid verification time');
    }
    final pin = existing.identityFingerprint;
    if (pin == null) {
      throw const G2dPeerTrustError('peer has no pinned identity to verify');
    }
    final observed = existing.observedIdentityFingerprint;
    final promoted = observed ?? pin;

    final updated = G2dPeerTrustRecord(
      peerId: id,
      axes: <G2dPeerTrustAxis>{
        ...existing.axes,
        G2dPeerTrustAxis.userVerified,
      },
      identityFingerprint: promoted,
      // Promotion replaces the pin, so the displaced key becomes the historical
      // evidence. Without a change, earlier history is preserved as it was.
      previousIdentityFingerprint: observed != null ? pin : existing.previousIdentityFingerprint,
      verifiedAtMillis: atMillis,
      verificationMethod: method,
    );
    _records[id] = updated;
    return updated;
  }

  /// Clears the link. Transport and session facts go away; the pin, an observed
  /// identity, a pending change and a user verification stay, because they are
  /// not link properties.
  G2dPeerTrustRecord disconnect(String peerId) {
    final id = _requirePeerId(peerId);
    final existing = _records[id];
    if (existing == null) {
      throw const G2dPeerTrustError('unknown peer');
    }
    final remaining = <G2dPeerTrustAxis>{
      if (existing.axes.contains(G2dPeerTrustAxis.discovered)) G2dPeerTrustAxis.discovered,
      if (existing.axes.contains(G2dPeerTrustAxis.userVerified)) G2dPeerTrustAxis.userVerified,
    };
    final updated = existing._withAxes(remaining);
    _records[id] = updated;
    return updated;
  }

  /// Revokes a peer. Terminal: the record refuses every later transition.
  ///
  /// A second revocation returns the existing record unchanged, so the original
  /// timestamp, reason and the fingerprint evidence are not rewritten.
  G2dPeerTrustRecord revokePeer({
    required String peerId,
    required G2dPeerRevocationReason reason,
    required int atMillis,
  }) {
    final id = _requirePeerId(peerId);
    final existing = _records[id];
    if (existing == null) {
      throw const G2dPeerTrustError('unknown peer');
    }
    if (existing.isRevoked) {
      return existing;
    }
    if (atMillis <= 0) {
      throw const G2dPeerTrustError('invalid revocation time');
    }
    // Keep the most recent identity evidence in the tombstone, including a key
    // that was observed but never promoted.
    final evidence = existing.observedIdentityFingerprint ??
        existing.identityFingerprint ??
        existing.previousIdentityFingerprint;
    final updated = G2dPeerTrustRecord(
      peerId: id,
      previousIdentityFingerprint: evidence,
      revokedAtMillis: atMillis,
      revocationReason: reason,
    );
    _records[id] = updated;
    return updated;
  }

  G2dPeerTrustRecord _advance(String peerId, G2dPeerTrustAxis axis) {
    final existing = _records[peerId];
    if (existing != null && existing.isRevoked) {
      throw const G2dPeerTrustError('revoked peer cannot advance');
    }
    final record = existing ?? G2dPeerTrustRecord(peerId: peerId);
    if (record.axes.contains(axis)) {
      return record;
    }
    // Every earlier axis must already be present: "service ready" without a
    // connection, or "verified" without authentication, is not a state the app
    // is allowed to invent.
    for (final requiredAxis in G2dPeerTrustAxis.values) {
      if (requiredAxis == axis) {
        break;
      }
      if (!record.axes.contains(requiredAxis)) {
        throw G2dPeerTrustError('cannot record ${axis.name} before ${requiredAxis.name}');
      }
    }
    final updated = record._withAxes(<G2dPeerTrustAxis>{...record.axes, axis});
    _records[peerId] = updated;
    return updated;
  }

  String _requirePeerId(String peerId) {
    if (peerId.isEmpty || peerId.length > G2dPeerTrustRecord.maxPeerIdLength) {
      throw const G2dPeerTrustError('invalid peer id');
    }
    return peerId;
  }
}

Set<G2dPeerTrustAxis> _decodeAxes(Object? value) {
  if (value is! List) {
    throw const FormatException('Invalid G2-D trust axes.');
  }
  final axes = <G2dPeerTrustAxis>{};
  for (final raw in value) {
    if (raw is! String) {
      throw const FormatException('Invalid G2-D trust axis.');
    }
    final axis = _axisFromName(raw);
    if (!axes.add(axis)) {
      throw const FormatException('Duplicate G2-D trust axis.');
    }
  }
  // The session-bound axes can only exist on the transport axes they were
  // observed on. `userVerified` is deliberately exempt: a pin and the user's
  // comparison outlive a link, so it may survive a disconnect on its own.
  const ordered = <G2dPeerTrustAxis>[
    G2dPeerTrustAxis.discovered,
    G2dPeerTrustAxis.connected,
    G2dPeerTrustAxis.serviceReady,
    G2dPeerTrustAxis.sessionEstablished,
    G2dPeerTrustAxis.identityAuthenticated,
  ];
  for (var index = 0; index < ordered.length; index += 1) {
    if (!axes.contains(ordered[index])) {
      continue;
    }
    for (var earlier = 0; earlier < index; earlier += 1) {
      if (!axes.contains(ordered[earlier])) {
        throw FormatException(
          'G2-D trust axis ${ordered[index].name} requires ${ordered[earlier].name}.',
        );
      }
    }
  }
  return axes;
}

G2dPeerTrustAxis _axisFromName(String value) {
  for (final axis in G2dPeerTrustAxis.values) {
    if (axis.name == value) {
      return axis;
    }
  }
  throw FormatException('Unknown G2-D trust axis: $value');
}

G2dVerificationMethod _decodeMethod(Object? value) {
  if (value is! String) {
    throw const FormatException('Invalid G2-D verification method.');
  }
  for (final method in G2dVerificationMethod.values) {
    if (method.wireName == value) {
      return method;
    }
  }
  throw const FormatException('Unknown G2-D verification method.');
}

G2dPeerRevocationReason _decodeReason(Object? value) {
  if (value is! String) {
    throw const FormatException('Invalid G2-D peer revocation reason.');
  }
  for (final reason in G2dPeerRevocationReason.values) {
    if (reason.wireName == value) {
      return reason;
    }
  }
  throw const FormatException('Unknown G2-D peer revocation reason.');
}

String? _optionalFingerprint(Object? value, String label) {
  if (value == null) {
    return null;
  }
  if (value is! String || !G2dIdentityRecord.isValidFingerprint(value)) {
    throw FormatException('Invalid G2-D $label fingerprint.');
  }
  return value;
}

int? _optionalMillis(Object? value, String label) {
  if (value == null) {
    return null;
  }
  if (value is! int || value <= 0) {
    throw FormatException('Invalid G2-D $label.');
  }
  return value;
}
