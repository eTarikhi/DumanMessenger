import 'dart:convert';

import 'package:duman_messenger/conversations/conversation.dart';
import 'package:duman_messenger/conversations/conversation_repository.dart';
import 'package:duman_messenger/conversations/conversation_store_android.dart';
import 'package:duman_messenger/identity/identity_channel.dart';
import 'package:duman_messenger/screens/conversation_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'identity_fake_platform.dart';

/// Encrypted conversation storage, exercised through the real channel client and
/// the fake platform.
///
/// What this proves: the store writes one JSON document to its own slot, reads it
/// back into the same conversations, refuses to read a damaged document, and never
/// overwrites one. What it does not prove: encryption. The double keeps strings in
/// the clear; AES-GCM and the Keystore belong to the device.
void main() {
  late FakeIdentityPlatform platform;

  setUp(() {
    platform = FakeIdentityPlatform();
    platform.install();
  });

  tearDown(() {
    platform.uninstall();
  });

  G2dKeystoreConversationStore buildStore() =>
      G2dKeystoreConversationStore(channel: G2dIdentityChannel());

  test('an empty slot reads as no conversations, without writing', () async {
    final store = buildStore();

    expect(await store.load(), isEmpty);
    expect(store.isPersistent, isTrue);
    expect(store.storeKind, 'keystore');
    expect(platform.conversationSaveCount, 0);
  });

  test('saves and reads back the same conversations', () async {
    final store = buildStore();
    final conversations = <G2dConversation>[
      G2dConversation(
        id: 'aa11',
        title: 'First',
        createdAtMillis: 10,
        lastActivityMillis: 20,
      ),
      G2dConversation(
        id: 'bb22',
        title: 'Second',
        createdAtMillis: 30,
        lastActivityMillis: 40,
      ),
    ];

    await store.save(conversations);

    expect(platform.conversationSaveCount, 1);
    // One document, versioned, in the conversation slot only.
    final Map<String, Object?> document = jsonDecode(platform.storedConversations!)
        as Map<String, Object?>;
    expect(document['version'], 1);
    expect(platform.storedPayload, isNull);
    expect(platform.storedKeyMaterial, isNull);

    final List<G2dConversation> loaded = await store.load();
    expect(loaded, conversations);
  });

  test('a damaged document is refused, not repaired or overwritten', () async {
    final store = buildStore();
    platform.storedConversations = '{"version":1,"conversations":[{"version":1}]}';

    await expectLater(
      store.load(),
      throwsA(isA<G2dConversationException>()),
    );
    expect(platform.storedConversations,
        '{"version":1,"conversations":[{"version":1}]}');

    final repository = G2dConversationRepository(store: store);
    await expectLater(
      repository.create('Must not overwrite'),
      throwsA(isA<G2dConversationException>()),
    );
    expect(platform.conversationSaveCount, 0);
  });

  test('a repository over the encrypted store persists across instances',
      () async {
    int now = 1000;
    var nextId = 0;

    G2dConversationRepository buildRepository() => G2dConversationRepository(
          store: buildStore(),
          nowMillis: () => now++,
          newId: () => 'id${(nextId++).toString().padLeft(4, '0')}',
        );

    final first = buildRepository();
    final G2dConversation created = await first.create('Persisted');

    // A fresh repository over the same channel sees what was written.
    final second = buildRepository();
    final List<G2dConversation> listed = await second.list();

    expect(listed, <G2dConversation>[created]);
    expect(second.isPersistent, isTrue);
  });

  testWidgets('the screen stops claiming conversations are not saved',
      (WidgetTester tester) async {
    final repository = G2dConversationRepository(
      store: buildStore(),
      nowMillis: () => 1000,
      newId: () => 'abcd0001',
    );

    await tester.pumpWidget(
      MaterialApp(home: ConversationListScreen(repository: repository)),
    );
    await tester.pumpAndSettle();

    expect(find.text('No conversations yet'), findsOneWidget);
    expect(find.byKey(const Key('conversations-not-persisted')), findsNothing);
    expect(find.textContaining('disappear when the app is restarted'),
        findsNothing);

    await tester.ensureVisible(find.byKey(const Key('conversation-create')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conversation-create')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('conversation-title-field')),
      'Stored',
    );
    await tester.tap(find.byKey(const Key('conversation-create-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Stored'), findsOneWidget);
    expect(platform.storedConversations, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
