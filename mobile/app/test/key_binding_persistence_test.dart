import 'dart:convert';

import 'package:duman_messenger/identity/identity_channel.dart';
import 'package:duman_messenger/identity/identity_key_material.dart';
import 'package:duman_messenger/identity/identity_key_provider.dart';
import 'package:duman_messenger/identity/key_binding.dart';
import 'package:duman_messenger/identity/key_binding_service.dart';
import 'package:duman_messenger/identity/key_binding_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'identity_fake_platform.dart';

/// Focused tests for persisting this installation's own signed key binding.
///
/// The platform double stores the document in the clear, so nothing here proves
/// encryption. What it does prove is the part that has no other witness: the binding is
/// issued once, written to its own slot, read back through the store, re-verified, and
/// refused — never silently replaced — when what is stored does not match the keys.
void main() {
  late FakeIdentityPlatform platform;
  late G2dKeystoreKeyBindingStore store;
  late G2dIdentityBindingService service;
  late G2dIdentityKeyProvider provider;

  setUp(() {
    platform = FakeIdentityPlatform();
    platform.install();
    provider = G2dIdentityKeyProvider();
    store = G2dKeystoreKeyBindingStore(channel: G2dIdentityChannel());
    service = G2dIdentityBindingService(store: store, provider: provider);
  });

  tearDown(() {
    platform.uninstall();
  });

  test('an empty slot reads as absent, not as damage', () async {
    expect(await store.load(), isNull);
    expect(store.isPersistent, isTrue);

    final G2dIdentityKeyMaterial material = await provider.generate();
    final G2dBindingStatus status = await service.status(material);
    expect(status.presence, G2dBindingPresence.absent);
    expect(status.isUsable, isFalse);
    expect(platform.bindingSaveCount, 0);
  });

  test('the first call issues a binding, stores it, and verifies what came back',
      () async {
    final G2dIdentityKeyMaterial material = await provider.generate();

    final G2dKeyBinding issued = await service.ensureBound(material);

    expect(await issued.verify(expectedEd25519PublicKey: material.ed25519PublicKey),
        G2dBindingVerdict.valid);
    expect(issued.generation, 1);
    expect(platform.bindingSaveCount, 1);

    // Its own slot, and only its own slot.
    expect(platform.storedBindings, isNotNull);
    expect(platform.storedMessages, isNull);
    expect(platform.storedConversations, isNull);
    expect(platform.storedKeyMaterial, isNull);
    expect(platform.storedPayload, isNull);

    // One versioned document holding one base64url binding.
    final Map<String, Object?> document =
        jsonDecode(platform.storedBindings!) as Map<String, Object?>;
    expect(document['version'], 1);
    final String encoded = document['binding']! as String;
    expect(G2dKeyBinding.fromBase64Url(encoded).toBytes(), issued.toBytes());

    // And it reads back through the store, not just from memory.
    final G2dKeyBinding? stored = await store.load();
    expect(stored, isNotNull);
    expect(stored!.toBytes(), issued.toBytes());
    expect((await service.status(material)).presence, G2dBindingPresence.verified);
  });

  test('a second call re-verifies instead of re-issuing', () async {
    final G2dIdentityKeyMaterial material = await provider.generate();
    final G2dKeyBinding first = await service.ensureBound(material);
    final G2dKeyBinding second = await service.ensureBound(material);

    expect(second.toBytes(), first.toBytes());
    expect(platform.bindingSaveCount, 1,
        reason: 'an existing binding must not be overwritten on every start');
  });

  test('a stored binding for other keys is refused, not overwritten', () async {
    final G2dIdentityKeyMaterial material = await provider.generate();
    final G2dIdentityKeyMaterial other = await provider.generate();
    // A perfectly valid binding — belonging to somebody else.
    await store.save(await provider.signKeyBinding(other));
    expect(platform.bindingSaveCount, 1);

    await expectLater(
      service.ensureBound(material),
      throwsA(isA<G2dIdentityBindingException>()),
    );
    expect(platform.bindingSaveCount, 1, reason: 'nothing may be written to recover');
    expect((await service.status(material)).presence, G2dBindingPresence.mismatched);
  });

  test('a damaged document is a typed failure on read and on write', () async {
    final G2dIdentityKeyMaterial material = await provider.generate();
    platform.storedBindings = '{"version":1,"binding":"not-a-binding"}';

    await expectLater(store.load(), throwsA(isA<G2dIdentityBindingException>()));
    await expectLater(
      service.ensureBound(material),
      throwsA(isA<G2dIdentityBindingException>()),
    );
    expect(platform.bindingSaveCount, 0);
    expect(platform.storedBindings, '{"version":1,"binding":"not-a-binding"}',
        reason: 'the unusable record stays where it is for the owner to decide');
  });

  test('an unsupported document version is refused rather than guessed', () async {
    platform.storedBindings = '{"version":2,"binding":""}';
    await expectLater(store.load(), throwsA(isA<G2dIdentityBindingException>()));
  });

  test('the binding names exactly the keys the identity generated', () async {
    final G2dIdentityKeyMaterial material = await provider.generate();
    final G2dKeyBinding issued = await service.ensureBound(material);

    expect(issued.ed25519PublicKey, material.ed25519PublicKey);
    expect(issued.x25519PublicKey, material.x25519PublicKey);
    // The identity fingerprint is still the provider's: this milestone did not restate
    // it and did not derive a second one from the exchange key.
    expect(await provider.fingerprint(material), matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(await issued.exchangeKeyFingerprint(), isNot(await provider.fingerprint(material)));
  });
}
