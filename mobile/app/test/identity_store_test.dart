import 'package:duman_messenger/identity/identity_models.dart';
import 'package:duman_messenger/identity/identity_store.dart';
import 'package:flutter_test/flutter_test.dart';

String fingerprint(String nibble) => List<String>.filled(64, nibble).join();

G2dIdentityRecord record({String identityId = 'identity-1'}) => G2dIdentityRecord(
      identityId: identityId,
      keyVersion: 1,
      algorithm: G2dIdentityAlgorithm.curve25519Xeddsa,
      publicKeyFingerprint: fingerprint('a'),
      keyHandle: const G2dKeyHandle(
        provider: 'android_keystore',
        alias: 'g2d.identity',
        protection: G2dKeyProtection.softwareKeystoreWrapped,
        probeVerified: true,
      ),
      state: G2dIdentityState.active,
      createdAtMillis: 1000,
    );

void main() {
  group('unavailable store', () {
    const store = G2dUnavailableIdentityStore();

    test('reports its identity and that it is not secure at rest', () {
      expect(store.storeKind, 'unavailable');
      expect(store.isSecureAtRest, isFalse);
    });

    test('fails closed on every operation instead of degrading', () async {
      await expectLater(store.load(), throwsA(isA<G2dIdentityStoreUnavailable>()));
      await expectLater(
        store.save(record()),
        throwsA(isA<G2dIdentityStoreUnavailable>()),
      );
      await expectLater(store.delete(), throwsA(isA<G2dIdentityStoreUnavailable>()));
    });

    test('carries the reason so the failure can be reported honestly', () async {
      try {
        await store.load();
        fail('load should have thrown');
      } on G2dIdentityStoreUnavailable catch (error) {
        expect(error.reason, isNotEmpty);
        expect(error.toString(), contains('G2dIdentityStoreUnavailable'));
      }
    });
  });

  group('in-memory store', () {
    test('starts empty', () async {
      expect(await G2dInMemoryIdentityStore().load(), isNull);
    });

    test('round-trips a record through storage', () async {
      final store = G2dInMemoryIdentityStore();
      final stored = record();
      await store.save(stored);
      expect(await store.load(), stored);
      expect(store.committedWrites, 1);
      expect(store.storeKind, 'in_memory_test_only');
      expect(store.isSecureAtRest, isFalse);
    });

    test('replaces the previous record rather than accumulating', () async {
      final store = G2dInMemoryIdentityStore();
      await store.save(record());
      final rotated = record(identityId: 'identity-2');
      await store.save(rotated);
      expect((await store.load())!.identityId, 'identity-2');
      expect(store.committedWrites, 2);
    });

    test('delete is idempotent and leaves no record', () async {
      final store = G2dInMemoryIdentityStore();
      await store.save(record());
      await store.delete();
      expect(await store.load(), isNull);
      await store.delete();
      expect(await store.load(), isNull);
    });

    test('reports unparsable bytes as corruption, not as absence', () async {
      final store = G2dInMemoryIdentityStore()..corruptStoredValue();
      await expectLater(store.load(), throwsA(isA<G2dIdentityStoreCorrupt>()));
    });

    test('reports a half-written record as corruption', () async {
      final store = G2dInMemoryIdentityStore()..simulatePartialWrite();
      await expectLater(store.load(), throwsA(isA<G2dIdentityStoreCorrupt>()));
    });

    test('a failed write does not commit anything', () async {
      final store = G2dInMemoryIdentityStore()..failNextWrite = true;
      await expectLater(
        store.save(record()),
        throwsA(isA<G2dIdentityStoreWriteFailed>()),
      );
      expect(await store.load(), isNull);
      expect(store.committedWrites, 0);
      // The failure is one-shot: a later write can still succeed.
      await store.save(record());
      expect(await store.load(), record());
    });

    test('a non-atomic write is visible as corruption afterwards', () async {
      final store = G2dInMemoryIdentityStore();
      await store.save(record());
      store.destructiveNextWrite = true;
      await expectLater(
        store.save(record(identityId: 'identity-2')),
        throwsA(isA<G2dIdentityStoreWriteFailed>()),
      );
      // The previous record is gone and nothing valid replaced it: the store must
      // surface that as corruption rather than pretend the old identity survived.
      await expectLater(store.load(), throwsA(isA<G2dIdentityStoreCorrupt>()));
    });
  });
}
