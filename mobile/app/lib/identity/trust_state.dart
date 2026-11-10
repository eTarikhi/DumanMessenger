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
    this.previousIdentityFingerprint,
    this.verifiedAtMillis,
    this.verificationMethod,
    this.identityChangedAtMillis,
    this.revokedAtMillis,
    this.revocationReason,
  }) : axes = Set<G2dPeerTrustAxis>.unmodifiable(axes);

  final String peerId;

  /// Pinned peer identity fingerprint. Set only when the peer identity was
  /// authenticated; `null` before that and after revocation.
  final String? identityFingerprint;

  /// The fingerprint this pin replaced, when an identity change was observed, or
  /// the fingerprint that was revoked. Kept so the change can be shown and
  /// audited locally.
  final String? previousIdentityFingerprint;

  final Set<G2dPeerTrustAxis> axes;
  final int? verifiedAtMillis;
  final G2dVerificationMethod? verificationMethod;

  /// Set when a different identity was observed for a peer that already had a
  /// pinned fingerprint. While set, the peer is not verified and cannot be used
  /// until the user completes a fresh comparison.
  final int? identityChangedAtMillis;

  final int? revokedAtMillis;
  final G2dPeerRevocationReason? revocationReason;

  bool get isRevoked => revokedAtMillis != null;

  bool get isIdentityChanged => identityChangedAtMillis != null;

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
  /// a connection, a handshake, or an earlier session.
  bool get isUserVerified =>
      !isRevoked &&
      !isIdentityChanged &&
      axes.contains(G2dPeerTrustAxis.userVerified) &&
      verificationMethod != null &&
      verifiedAtMillis != null &&
      identityFingerprint != null;

  /// True only when a session is bound to an authenticated peer identity.
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
    if (!isConnected && axes.contains(G2dPeerTrustAxis.userVerified)) {
      // A pin outlives a link; the label must say so instead of implying that the
      // peer is reachable or that anything is currently encrypted.
      return 'Verified by you — not currently connected';
    }
    final highest = highestAxis;
    if (highest == null) {
      return 'Not discovered';
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
      G2dPeerTrustAxis.userVerified => 'Verified by you (out-of-band comparison)',
    };
  }

  /// Structured copy used by tests and by any future UI. Never claims encryption.
  Map<String, Object?> toMap() => <String, Object?>{
        'peerId': peerId,
        'axes': <String>[
          for (final axis in G2dPeerTrustAxis.values)
            if (axes.contains(axis)) axis.name,
        ],
        if (identityFingerprint != null) 'identityFingerprint': identityFingerprint,
        if (previousIdentityFingerprint != null)
          'previousIdentityFingerprint': previousIdentityFingerprint,
        if (verifiedAtMillis != null) 'verifiedAtMillis': verifiedAtMillis,
        if (verificationMethod != null) 'verificationMethod': verificationMethod!.wireName,
        if (identityChangedAtMillis != null) 'identityChangedAtMillis': identityChangedAtMillis,
        if (revokedAtMillis != null) 'revokedAtMillis': revokedAtMillis,
        if (revocationReason != null) 'revocationReason': revocationReason!.wireName,
      };

  /// Copy with a new axis set.
  ///
  /// [identityFingerprint] binds the pin when an authenticated identity is being
  /// recorded. Omitting it keeps the current pin, so transport-axis advances and
  /// a disconnect can never drop a pinned identity. There is deliberately no way
  /// to clear the pin through this helper: unpinning is a revocation decision,
  /// not an axis transition.
  G2dPeerTrustRecord _withAxes(
    Set<G2dPeerTrustAxis> nextAxes, {
    String? identityFingerprint,
  }) =>
      G2dPeerTrustRecord(
        peerId: peerId,
        axes: nextAxes,
        identityFingerprint: identityFingerprint ?? this.identityFingerprint,
        previousIdentityFingerprint: previousIdentityFingerprint,
        verifiedAtMillis: verifiedAtMillis,
        verificationMethod: verificationMethod,
        identityChangedAtMillis: identityChangedAtMillis,
        revokedAtMillis: revokedAtMillis,
        revocationReason: revocationReason,
      );
}

/// Outcome of observing a peer identity.
sealed class G2dPeerIdentityObservation {
  const G2dPeerIdentityObservation();
}

/// First identity seen for this peer: recorded and authenticated, not trusted by
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

/// A different identity was observed for a pinned peer. The record fails closed:
/// session and verification evidence is dropped, the observed fingerprint is
/// retained for display, and nothing is trusted until a fresh ceremony completes.
class G2dPeerIdentityChanged extends G2dPeerIdentityObservation {
  const G2dPeerIdentityChanged({
    required this.record,
    required this.previousFingerprint,
    required this.observedFingerprint,
  });

  final G2dPeerTrustRecord record;
  final String previousFingerprint;
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

  static const int _maxPeerIdLength = 64;

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
  /// This is the only entry point that can set the pinned fingerprint, and it
  /// fails closed when the fingerprint differs from an existing pin.
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
      // Identity change: drop every session-bound and human-supplied fact. The
      // observed fingerprint replaces the pin for display only; nothing is
      // trusted until a fresh ceremony completes.
      final changed = G2dPeerTrustRecord(
        peerId: id,
        axes: const <G2dPeerTrustAxis>{G2dPeerTrustAxis.discovered},
        identityFingerprint: fingerprint,
        previousIdentityFingerprint: pinned,
        identityChangedAtMillis: atMillis,
      );
      _records[id] = changed;
      return G2dPeerIdentityChanged(
        record: changed,
        previousFingerprint: pinned,
        observedFingerprint: fingerprint,
      );
    }

    // Reaching here means the observed fingerprint is either the first pin for
    // this peer or the same value as the existing pin. Binding it is not
    // optional: without this the record never gains a pin, so a second
    // observation would look like a first contact forever, an identity change
    // could never be detected, and verification facts (which require a pin)
    // would never count.
    final updated = existing._withAxes(
      <G2dPeerTrustAxis>{
        ...existing.axes,
        G2dPeerTrustAxis.identityAuthenticated,
      },
      identityFingerprint: fingerprint,
    );
    _records[id] = updated;
    return pinned == fingerprint
        ? G2dPeerIdentityUnchanged(updated)
        : G2dPeerIdentityFirstSeen(updated);
  }

  /// Records an explicit user comparison out of band.
  ///
  /// Requires an authenticated identity. Completing it also clears a pending
  /// identity-change marker, because re-verifying a changed identity is exactly
  /// the ceremony that resolves the change.
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
    final updated = G2dPeerTrustRecord(
      peerId: id,
      axes: <G2dPeerTrustAxis>{
        ...existing.axes,
        G2dPeerTrustAxis.userVerified,
      },
      identityFingerprint: existing.identityFingerprint,
      previousIdentityFingerprint: existing.previousIdentityFingerprint,
      verifiedAtMillis: atMillis,
      verificationMethod: method,
    );
    _records[id] = updated;
    return updated;
  }

  /// Clears the link. Transport and session facts go away; the pinned identity
  /// and a user verification stay, because they are not link properties.
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
    if (atMillis <= 0) {
      throw const G2dPeerTrustError('invalid revocation time');
    }
    final updated = G2dPeerTrustRecord(
      peerId: id,
      previousIdentityFingerprint: existing.identityFingerprint,
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
    if (peerId.isEmpty || peerId.length > _maxPeerIdLength) {
      throw const G2dPeerTrustError('invalid peer id');
    }
    return peerId;
  }
}
