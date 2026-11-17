import 'dart:convert';

import 'package:duman_messenger/app_routes.dart';
import 'package:duman_messenger/conversations/conversation.dart';
import 'package:duman_messenger/conversations/conversation_repository.dart';
import 'package:duman_messenger/messages/message.dart';
import 'package:duman_messenger/messages/message_repository.dart';
import 'package:duman_messenger/messages/message_store.dart';
import 'package:duman_messenger/messages/message_store_android.dart';
import 'package:duman_messenger/identity/identity_channel.dart';
import 'package:duman_messenger/screens/conversation_detail_screen.dart';
import 'package:duman_messenger/screens/conversation_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'identity_fake_platform.dart';

/// Message domain, encrypted store and the conversation detail screen.
///
/// These tests prove wiring, ordering, validation and honest UI states. They do not
/// prove encryption: the platform double stores JSON in the clear, and the AES-GCM
/// envelope is the instrumentation suite's and the device's business.
void main() {
  late FakeIdentityPlatform platform;
  int now = 5000;
  int nextId = 0;

  setUp(() {
    platform = FakeIdentityPlatform();
    platform.install();
    now = 5000;
    nextId = 0;
  });

  tearDown(() {
    platform.uninstall();
  });

  G2dMessageRepository memoryRepository([G2dMessageStore? store]) =>
      G2dMessageRepository(
        store: store ?? G2dInMemoryMessageStore(),
        nowMillis: () => now++,
        newId: () => 'm${(nextId++).toString().padLeft(4, '0')}',
      );

  G2dConversationRepository conversationRepositoryWith(
    G2dConversation conversation,
  ) {
    final store = G2dInMemoryConversationStore(initial: <G2dConversation>[conversation]);
    return G2dConversationRepository(store: store);
  }

  G2dConversation conversation({String id = 'conv01', String title = 'Thread'}) =>
      G2dConversation(
        id: id,
        title: title,
        createdAtMillis: 1000,
        lastActivityMillis: 1000,
      );

  test('message codec is strict and versioned', () {
    final message = G2dMessage(
      id: 'm1',
      conversationId: 'conv01',
      body: 'hello',
      createdAtMillis: 10,
      localStatus: G2dMessageLocalStatus.storedLocally,
    );

    expect(G2dMessage.fromMap(message.toMap()), message);
    expect(
      () => G2dMessage.fromMap(<String, Object?>{...message.toMap(), 'version': 2}),
      throwsFormatException,
    );
    expect(
      () => G2dMessage.fromMap(<String, Object?>{...message.toMap(), 'body': ''}),
      throwsFormatException,
    );
    expect(
      () => G2dMessage.fromMap(<String, Object?>{...message.toMap(), 'body': ' padded '}),
      throwsFormatException,
    );
    expect(
      () => G2dMessage.fromMap(<String, Object?>{...message.toMap(), 'localStatus': 'sent'}),
      throwsFormatException,
    );
    expect(
      () => G2dMessage.fromMap(<String, Object?>{...message.toMap(), 'conversationId': 'Bad Id!'}),
      throwsFormatException,
    );
    // The body never appears in diagnostic text.
    expect(message.toString(), isNot(contains('hello')));
  });

  test('append stores locally, trims, and lists oldest first', () async {
    final repository = memoryRepository();

    await repository.append(conversationId: 'conv01', body: '  first  ');
    await repository.append(conversationId: 'conv01', body: 'second');
    await repository.append(conversationId: 'other', body: 'elsewhere');

    final List<G2dMessage> listed = await repository.listFor('conv01');
    expect(listed.map((G2dMessage message) => message.body),
        <String>['first', 'second']);
    expect(listed.first.localStatus, G2dMessageLocalStatus.storedLocally);
    expect(await repository.listFor('other'), hasLength(1));
    expect(repository.isPersistent, isFalse);

    await expectLater(
      repository.append(conversationId: 'conv01', body: '   '),
      throwsA(isA<G2dMessageException>()),
    );
  });

  test('the encrypted store writes one document to the message slot only',
      () async {
    final store = G2dKeystoreMessageStore(channel: G2dIdentityChannel());
    final repository = memoryRepository(store);

    expect(store.isPersistent, isTrue);
    expect(store.storeKind, 'keystore');
    expect(await store.load(), isEmpty);

    await repository.append(conversationId: 'conv01', body: 'secret body');

    final Map<String, Object?> document =
        jsonDecode(platform.storedMessages!) as Map<String, Object?>;
    expect(document['version'], 1);
    expect(platform.storedConversations, isNull);
    expect(platform.storedPayload, isNull);
    expect(platform.storedKeyMaterial, isNull);

    // A fresh repository over the same channel sees the message.
    final List<G2dMessage> reloaded = await memoryRepository(store).listFor('conv01');
    expect(reloaded.single.body, 'secret body');
  });

  test('a damaged message document is refused and never overwritten', () async {
    final store = G2dKeystoreMessageStore(channel: G2dIdentityChannel());
    platform.storedMessages = '{"version":1,"messages":[{"version":1}]}';

    await expectLater(store.load(), throwsA(isA<G2dMessageException>()));

    final repository = memoryRepository(store);
    await expectLater(
      repository.append(conversationId: 'conv01', body: 'must not overwrite'),
      throwsA(isA<G2dMessageException>()),
    );
    expect(platform.messageSaveCount, 0);
    expect(platform.storedMessages, '{"version":1,"messages":[{"version":1}]}');
  });

  test('deleteFor removes only the requested conversation', () async {
    final repository = memoryRepository();
    await repository.append(conversationId: 'conv01', body: 'a');
    await repository.append(conversationId: 'conv02', body: 'b');

    await repository.deleteFor('conv01');

    expect(await repository.listFor('conv01'), isEmpty);
    expect(await repository.listFor('conv02'), hasLength(1));
    // Deleting nothing is not an error.
    await repository.deleteFor('conv01');
  });

  testWidgets('detail screen shows an honest empty state and saves locally',
      (WidgetTester tester) async {
    final conversationRepository = conversationRepositoryWith(conversation());
    final messageRepository = memoryRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: ConversationDetailScreen(
          conversationId: 'conv01',
          conversationRepository: conversationRepository,
          messageRepository: messageRepository,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Thread'), findsOneWidget);
    expect(find.byKey(const Key('conversation-detail-empty')), findsOneWidget);
    expect(find.byKey(const Key('conversation-detail-local-only')), findsOneWidget);
    // Nothing may claim a transport state.
    expect(find.textContaining('Delivered'), findsNothing);
    expect(find.textContaining('Read receipt'), findsNothing);
    expect(find.textContaining('Sent'), findsNothing);

    await tester.enterText(find.byKey(const Key('message-field')), 'Hello there');
    await tester.tap(find.byKey(const Key('message-save')));
    await tester.pumpAndSettle();

    expect(find.text('Hello there'), findsOneWidget);
    // The tile subtitle and the confirmation snackbar both say this.
    expect(find.textContaining('Saved on this device'), findsWidgets);
    expect((await messageRepository.listFor('conv01')).single.body, 'Hello there');
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail screen reports a missing conversation without inventing one',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationDetailScreen(
          conversationId: 'gone',
          conversationRepository: conversationRepositoryWith(conversation()),
          messageRepository: memoryRepository(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('conversation-detail-missing')), findsOneWidget);
    expect(find.byKey(const Key('message-field')), findsNothing);
  });

  testWidgets('tapping a conversation opens its detail screen',
      (WidgetTester tester) async {
    final conversationRepository = conversationRepositoryWith(conversation());
    final messageRepository = memoryRepository();

    await tester.pumpWidget(
      MaterialApp(
        onGenerateRoute: (RouteSettings settings) {
          if (settings.name == AppRoutes.conversationDetail) {
            return MaterialPageRoute<void>(
              settings: settings,
              builder: (BuildContext context) => ConversationDetailScreen(
                conversationId: settings.arguments! as String,
                conversationRepository: conversationRepository,
                messageRepository: messageRepository,
              ),
            );
          }
          return null;
        },
        home: ConversationListScreen(
          repository: conversationRepository,
          messageRepository: messageRepository,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Thread'));
    await tester.pumpAndSettle();

    expect(find.byType(ConversationDetailScreen), findsOneWidget);
    expect(find.byKey(const Key('conversation-detail-empty')), findsOneWidget);
  });
}
