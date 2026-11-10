import 'package:duman_messenger/identity/trust_state.dart';
import 'package:flutter_test/flutter_test.dart';

String fingerprint(String nibble) => List<String>.filled(64, nibble).join();

const String peer = 'peer-1';

G2dPeerTrustStore connectedPeer() {
  final store = G2dPeerTrustStore();
  store.markDiscovered(peer);
  store.markConnected(peer);
  store.markServiceReady(peer);
  store.markSessionEstablished(peer);
  return store;
}

void main() {
  group('transport axes', () {
    test('an unknown peer has no record', () {
      final store = G2dPeerTrustStore();
      expect(store.recordFor(peer), isNull);
      expect(store.length, 0);
    });

    test('discovery is recorded without implying identity', () {
      final store = G2dPeerTrustStore();
      final record = store.markDiscovered(peer);

      expect(record.axes, contains(G2dPeerTrustAxis.discovered));
      expect(record.identityFingerprint, isNull);
      expect(record.hasAuthenticatedIdentity, isFalse);
      expect(record.isUserVerified, isFalse);
      expect(record.statusLabel, 'Discovered — untrusted radio candidate, not identified');
    });

    test('axes cannot be skipped ahead', () {
      final store = G2dPeerTrustStore();
      expect(() => store.markConnected(peer), throwsA(isA<G2dPeerTrustError>()));
      store.markDiscovered(peer);
      expect(() => store.markServiceReady(peer), throwsA(isA<G2dPeerTrustError>()));
      store.markConnected(peer);
      expect(
        () => store.markSessionEstablished(peer),
        throwsA(isA<G2dPeerTrustError>()),
      );
    });

    test('a connected link is never described as authenticated', () {
      final store = G2dPeerTrustStore();
      store.markDiscovered(peer);
      final record = store.markConnected(peer);

      expect(record.isConnected, isTrue);
      expect(record.statusLabel,
          'Connected — transport only, identity not authenticated');
      expect(record.statusLabel.toLowerCase().contains('secure'), isFalse);
    });

    test('a service-ready link is still only transport', () {
      final store = G2dPeerTrustStore();
      store.markDiscovered(peer);
      store.markConnected(peer);
      final record = store.markServiceReady(peer);

      expect(record.statusLabel,
          'Service ready — transport only, identity not authenticated');
    });

    test('an established session is not an authenticated identity', () {
      final store = connectedPeer();
      final record = store.recordFor(peer)!;

      expect(record.highestAxis, G2dPeerTrustAxis.sessionEstablished);
      expect(record.hasAuthenticatedIdentity, isFalse);
      expect(record.statusLabel,
          'Session established — peer identity not yet authenticated');
    });

    test('repeating an axis is idempotent', () {
      final store = G2dPeerTrustStore();
      store.markDiscovered(peer);
      final first = store.markConnected(peer);
      final second = store.markConnected(peer);

      expect(second.axes, first.axes);
    });
  });

  group('identity authentication', () {
    test('requires an established session', () {
      final store = G2dPeerTrustStore();
      store.markDiscovered(peer);
      store.markConnected(peer);
      store.markServiceReady(peer);

      expect(
        () => store.authenticateIdentity(peer, fingerprint('a'), atMillis: 100),
        throwsA(isA<G2dPeerTrustError>()),
      );
    });

    test('requires a discovered peer', () {
      final store = G2dPeerTrustStore();
      expect(
        () => store.authenticateIdentity(peer, fingerprint('a'), atMillis: 100),
        throwsA(isA<G2dPeerTrustError>()),
      );
    });

    test('rejects a malformed fingerprint', () {
      final store = connectedPeer();
      expect(
        () => store.authenticateIdentity(peer, 'abc', atMillis: 100),
        throwsA(isA<G2dPeerTrustError>()),
      );
    });

    test('first identity is recorded but not verified', () {
      final store = connectedPeer();
      final observation = store.authenticateIdentity(peer, fingerprint('a'), atMillis: 100);

      expect(observation, isA<G2dPeerIdentityFirstSeen>());
      final record = store.recordFor(peer)!;
      expect(record.identityFingerprint, fingerprint('a'));
      expect(record.hasAuthenticatedIdentity, isTrue);
      expect(record.isUserVerified, isFalse);
      expect(record.statusLabel, 'Identity authenticated — not verified by you');
    });

    test('the same identity does not re-verify or re-trust', () {
      final store = connectedPeer();
      store.authenticateIdentity(peer, fingerprint('a'), atMillis: 100);
      final observation = store.authenticateIdentity(peer, fingerprint('a'), atMillis: 200);

      expect(observation, isA<G2dPeerIdentityUnchanged>());
      expect(store.recordFor(peer)!.isUserVerified, isFalse);
    });
  });

  group('user verification', () {
    test('cannot be granted before the identity is authenticated', () {
      final store = connectedPeer();
      expect(
        () => store.verifyIdentity(
          peerId: peer,
          method: G2dVerificationMethod.outOfBandFingerprint,
          atMillis: 100,
        ),
        throwsA(isA<G2dPeerTrustError>()),
      );
    });

    test('records the method and time when the user compares out of band', () {
      final store = connectedPeer();
      store.authenticateIdentity(peer, fingerprint('a'), atMillis: 100);
      final record = store.verifyIdentity(
        peerId: peer,
        method: G2dVerificationMethod.scannedQrCode,
        atMillis: 300,
      );

      expect(record.isUserVerified, isTrue);
      expect(record.verificationMethod, G2dVerificationMethod.scannedQrCode);
      expect(record.verifiedAtMillis, 300);
      expect(record.statusLabel, 'Verified by you (out-of-band comparison)');
    });
  });

  group('changed peer identity', () {
    test('fails closed and demands re-verification', () {
      final store = connectedPeer();
      store.authenticateIdentity(peer, fingerprint('a'), atMillis: 100);
      store.verifyIdentity(
        peerId: peer,
        method: G2dVerificationMethod.outOfBandFingerprint,
        atMillis: 300,
      );

      final observation = store.authenticateIdentity(peer, fingerprint('b'), atMillis: 400);
      expect(observation, isA<G2dPeerIdentityChanged>());
      final changed = observation as G2dPeerIdentityChanged;
      expect(changed.previousFingerprint, fingerprint('a'));
      expect(changed.observedFingerprint, fingerprint('b'));

      final record = store.recordFor(peer)!;
      expect(record.isIdentityChanged, isTrue);
      expect(record.isUserVerified, isFalse);
      expect(record.hasAuthenticatedIdentity, isFalse);
      expect(record.axes, <G2dPeerTrustAxis>{G2dPeerTrustAxis.discovered});
      expect(record.verifiedAtMillis, isNull);
      expect(record.previousIdentityFingerprint, fingerprint('a'));
      expect(record.statusLabel, 'Peer identity changed — re-verification required');
    });

    test('a fresh ceremony clears the change and restores verification', () {
      final store = connectedPeer();
      store.authenticateIdentity(peer, fingerprint('a'), atMillis: 100);
      store.authenticateIdentity(peer, fingerprint('b'), atMillis: 200);

      store.markConnected(peer);
      store.markServiceReady(peer);
      store.markSessionEstablished(peer);
      final reauthenticated = store.authenticateIdentity(peer, fingerprint('b'), atMillis: 300);
      expect(reauthenticated, isA<G2dPeerIdentityUnchanged>());

      final verified = store.verifyIdentity(
        peerId: peer,
        method: G2dVerificationMethod.outOfBandFingerprint,
        atMillis: 400,
      );
      expect(verified.isUserVerified, isTrue);
      expect(verified.isIdentityChanged, isFalse);
      expect(verified.identityFingerprint, fingerprint('b'));
      expect(verified.previousIdentityFingerprint, fingerprint('a'));
    });
  });

  group('disconnect and revocation', () {
    test('disconnect clears session facts but keeps the pin and verification', () {
      final store = connectedPeer();
      store.authenticateIdentity(peer, fingerprint('a'), atMillis: 100);
      store.verifyIdentity(
        peerId: peer,
        method: G2dVerificationMethod.outOfBandFingerprint,
        atMillis: 300,
      );

      final record = store.disconnect(peer);
      expect(record.isConnected, isFalse);
      expect(record.hasAuthenticatedIdentity, isFalse);
      expect(record.isUserVerified, isTrue);
      expect(record.identityFingerprint, fingerprint('a'));
      expect(record.statusLabel, 'Verified by you — not currently connected');
    });

    test('revocation is terminal', () {
      final store = connectedPeer();
      store.authenticateIdentity(peer, fingerprint('a'), atMillis: 100);
      final revoked = store.revokePeer(
        peerId: peer,
        reason: G2dPeerRevocationReason.userRequested,
        atMillis: 500,
      );

      expect(revoked.isRevoked, isTrue);
      expect(revoked.statusLabel, 'Revoked — do not communicate');
      expect(revoked.isUserVerified, isFalse);
      expect(revoked.hasAuthenticatedIdentity, isFalse);
      expect(revoked.identityFingerprint, isNull);
      expect(revoked.previousIdentityFingerprint, fingerprint('a'));

      expect(() => store.markDiscovered(peer), throwsA(isA<G2dPeerTrustError>()));
      expect(
        () => store.authenticateIdentity(peer, fingerprint('a'), atMillis: 600),
        throwsA(isA<G2dPeerTrustError>()),
      );
      expect(
        () => store.verifyIdentity(
          peerId: peer,
          method: G2dVerificationMethod.outOfBandFingerprint,
          atMillis: 600,
        ),
        throwsA(isA<G2dPeerTrustError>()),
      );
    });

    test('a revoked peer stays revoked when a disconnect arrives', () {
      final store = connectedPeer();
      store.revokePeer(
        peerId: peer,
        reason: G2dPeerRevocationReason.identityChanged,
        atMillis: 500,
      );
      final afterDisconnect = store.disconnect(peer);

      expect(afterDisconnect.isRevoked, isTrue);
      expect(afterDisconnect.statusLabel, 'Revoked — do not communicate');
    });
  });

  group('record shape and validation', () {
    test('rejects empty and oversized peer identifiers', () {
      final store = G2dPeerTrustStore();
      expect(() => store.markDiscovered(''), throwsA(isA<G2dPeerTrustError>()));
      expect(
        () => store.markDiscovered(List<String>.filled(65, 'p').join()),
        throwsA(isA<G2dPeerTrustError>()),
      );
    });

    test('rejects non-positive timestamps', () {
      final store = connectedPeer();
      expect(
        () => store.authenticateIdentity(peer, fingerprint('a'), atMillis: 0),
        throwsA(isA<G2dPeerTrustError>()),
      );
      expect(
        () => store.verifyIdentity(
          peerId: peer,
          method: G2dVerificationMethod.outOfBandFingerprint,
          atMillis: 0,
        ),
        throwsA(isA<G2dPeerTrustError>()),
      );
    });

    test('the encoded record lists axes in order and omits absent facts', () {
      final store = G2dPeerTrustStore();
      store.markDiscovered(peer);
      store.markConnected(peer);
      final map = store.recordFor(peer)!.toMap();

      expect(map['axes'], <String>['discovered', 'connected']);
      expect(map.containsKey('identityFingerprint'), isFalse);
      expect(map.containsKey('verifiedAtMillis'), isFalse);
      expect(map['peerId'], peer);
    });
  });

  // Regression tests for the defect where `authenticateIdentity` validated and
  // compared the observed fingerprint but never bound it to the record: the pin
  // stayed null, so every later observation looked like first contact, an
  // identity change could never be detected, and verification facts (which
  // require a pin) never counted.
  group('pin persistence', () {
    test('the first observation stores the pinned fingerprint', () {
      final store = connectedPeer();
      final observation = store.authenticateIdentity(peer, fingerprint('a'), atMillis: 100);

      expect(observation, isA<G2dPeerIdentityFirstSeen>());
      final first = observation as G2dPeerIdentityFirstSeen;
      expect(first.record.identityFingerprint, fingerprint('a'));
      expect(store.recordFor(peer)!.identityFingerprint, fingerprint('a'));
    });

    test('the stored record and the returned record agree after authentication', () {
      final store = connectedPeer();
      final observation = store.authenticateIdentity(peer, fingerprint('a'), atMillis: 100);
      final returned = (observation as G2dPeerIdentityFirstSeen).record;
      final stored = store.recordFor(peer)!;

      expect(stored.identityFingerprint, isNotNull);
      expect(stored.identityFingerprint, returned.identityFingerprint);
      expect(stored.previousIdentityFingerprint, returned.previousIdentityFingerprint);
      expect(stored.axes, returned.axes);
      expect(stored.verifiedAtMillis, returned.verifiedAtMillis);
    });

    test('a first observation invents no previous fingerprint and no verification', () {
      final store = connectedPeer();
      final observation = store.authenticateIdentity(peer, fingerprint('a'), atMillis: 100);
      final record = (observation as G2dPeerIdentityFirstSeen).record;

      expect(record.previousIdentityFingerprint, isNull);
      expect(record.identityChangedAtMillis, isNull);
      expect(record.verifiedAtMillis, isNull);
      expect(record.verificationMethod, isNull);
      expect(record.isUserVerified, isFalse);
    });

    test('a repeated observation keeps the pin and reports unchanged', () {
      final store = connectedPeer();
      store.authenticateIdentity(peer, fingerprint('a'), atMillis: 100);

      final second = store.authenticateIdentity(peer, fingerprint('a'), atMillis: 200);
      expect(second, isA<G2dPeerIdentityUnchanged>());
      final unchanged = second as G2dPeerIdentityUnchanged;
      expect(unchanged.record.identityFingerprint, fingerprint('a'));
      expect(store.recordFor(peer)!.identityFingerprint, fingerprint('a'));
    });

    test('a disconnect keeps the pin and the next observation stays unchanged', () {
      final store = connectedPeer();
      store.authenticateIdentity(peer, fingerprint('a'), atMillis: 100);
      store.disconnect(peer);

      expect(store.recordFor(peer)!.identityFingerprint, fingerprint('a'));

      store.markConnected(peer);
      store.markServiceReady(peer);
      store.markSessionEstablished(peer);
      final again = store.authenticateIdentity(peer, fingerprint('a'), atMillis: 300);
      expect(again, isA<G2dPeerIdentityUnchanged>());
      expect(store.recordFor(peer)!.identityFingerprint, fingerprint('a'));
    });

    test('revocation moves the pin to the revoked fingerprint and refuses the peer', () {
      final store = connectedPeer();
      store.authenticateIdentity(peer, fingerprint('a'), atMillis: 100);

      final revoked = store.revokePeer(
        peerId: peer,
        reason: G2dPeerRevocationReason.userRequested,
        atMillis: 500,
      );

      expect(revoked.identityFingerprint, isNull);
      expect(revoked.previousIdentityFingerprint, fingerprint('a'));
      expect(
        () => store.authenticateIdentity(peer, fingerprint('a'), atMillis: 600),
        throwsA(isA<G2dPeerTrustError>()),
      );
    });
  });
}
