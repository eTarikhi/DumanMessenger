import 'package:duman_messenger/conversations/conversation.dart';
import 'package:duman_messenger/conversations/conversation_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Conversation domain and repository behaviour.
///
/// These tests do not touch storage because there is no durable storage yet: the
/// only store is in memory and reports `isPersistent == false`. What they do prove
/// is that titles are validated before anything is written, that ordering is
/// deterministic, and that the codec fails closed.
void main() {
  int now = 1000;
  int nextId = 0;

  G2dConversationRepository repositoryOver(G2dConversationStore store) =>
      G2dConversationRepository(
        store: store,
        nowMillis: () => now++,
        newId: () => 'id${(nextId++).toString().padLeft(4, '0')}',
      );

  setUp(() {
    now = 1000;
    nextId = 0;
  });

  test('starts empty and admits it persists nothing', () async {
    final store = G2dInMemoryConversationStore();
    final repository = repositoryOver(store);

    expect(await repository.list(), isEmpty);
    expect(repository.isPersistent, isFalse);
    expect(store.storeKind, 'memory');
  });

  test('creates a conversation with a trimmed title', () async {
    final repository = repositoryOver(G2dInMemoryConversationStore());

    final G2dConversation created = await repository.create('  Alice  ');

    expect(created.title, 'Alice');
    expect(created.createdAtMillis, created.lastActivityMillis);
    final List<G2dConversation> listed = await repository.list();
    expect(listed, <G2dConversation>[created]);
  });

  test('rejects an unusable title without writing anything', () async {
    final store = G2dInMemoryConversationStore();
    final repository = repositoryOver(store);

    await expectLater(
      repository.create('   '),
      throwsA(isA<G2dConversationException>()),
    );
    await expectLater(
      repository.create('x' * (G2dConversation.maxTitleLength + 1)),
      throwsA(isA<G2dConversationException>()),
    );
    expect(await repository.list(), isEmpty);
  });

  test('lists the most recent activity first', () async {
    final repository = repositoryOver(G2dInMemoryConversationStore());

    final G2dConversation first = await repository.create('First');
    final G2dConversation second = await repository.create('Second');
    final G2dConversation third = await repository.create('Third');

    final List<G2dConversation> listed = await repository.list();
    expect(
      listed.map((G2dConversation conversation) => conversation.title),
      <String>['Third', 'Second', 'First'],
    );
    expect(listed.first, third);
    expect(listed.last, first);
    expect(listed.contains(second), isTrue);
  });

  test('conversations live in the store, not the repository', () async {
    final store = G2dInMemoryConversationStore();
    final first = repositoryOver(store);
    await first.create('Survives a new repository object');

    final second = repositoryOver(store);
    final List<G2dConversation> listed = await second.list();

    expect(listed, hasLength(1));
    expect(listed.single.title, 'Survives a new repository object');
  });

  test('refuses a duplicate identifier instead of silently replacing', () async {
    final store = G2dInMemoryConversationStore();
    final repository = G2dConversationRepository(
      store: store,
      nowMillis: () => now++,
      newId: () => 'fixedid01',
    );

    await repository.create('First');
    await expectLater(
      repository.create('Second'),
      throwsA(isA<G2dConversationException>()),
    );
    final List<G2dConversation> listed = await repository.list();
    expect(listed, hasLength(1));
    expect(listed.single.title, 'First');
  });

  test('codec round-trips and rejects anything inconsistent', () {
    final conversation = G2dConversation(
      id: 'abcdef0123456789',
      title: 'Codec',
      createdAtMillis: 10,
      lastActivityMillis: 20,
    );

    expect(G2dConversation.fromMap(conversation.toMap()), conversation);

    expect(
      () => G2dConversation.fromMap(
        <String, Object?>{...conversation.toMap(), 'version': 2},
      ),
      throwsFormatException,
    );
    expect(
      () => G2dConversation.fromMap(
        <String, Object?>{...conversation.toMap(), 'title': ''},
      ),
      throwsFormatException,
    );
    expect(
      () => G2dConversation.fromMap(
        <String, Object?>{...conversation.toMap(), 'lastActivityMillis': 5},
      ),
      throwsFormatException,
    );
    expect(
      () => G2dConversation.fromMap(
        <String, Object?>{...conversation.toMap(), 'id': 'not a valid id!'},
      ),
      throwsFormatException,
    );
  });
}
