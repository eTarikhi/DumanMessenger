import 'package:duman_messenger/conversations/conversation_repository.dart';
import 'package:duman_messenger/screens/conversation_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The conversation flow a user can actually perform today.
///
/// There is no durable store, so these tests also assert that the screen *says*
/// so. A list that looked permanent while holding nothing would be worse than an
/// empty one.
void main() {
  int now = 1000;
  int nextId = 0;

  G2dConversationRepository buildRepository() => G2dConversationRepository(
        store: G2dInMemoryConversationStore(),
        nowMillis: () => now++,
        newId: () => 'id${(nextId++).toString().padLeft(4, '0')}',
      );

  setUp(() {
    now = 1000;
    nextId = 0;
  });

  Future<void> pumpScreen(
    WidgetTester tester,
    G2dConversationRepository repository,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: ConversationListScreen(repository: repository)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('empty state is honest and offers creation',
      (WidgetTester tester) async {
    await pumpScreen(tester, buildRepository());

    expect(find.text('No conversations yet'), findsOneWidget);
    expect(
      find.text('No messages or contacts are available in this build.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('conversations-not-persisted')), findsOneWidget);
    expect(find.textContaining('disappear when the app is restarted'),
        findsOneWidget);
    expect(find.byKey(const Key('conversation-create')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('creates a conversation through the dialog',
      (WidgetTester tester) async {
    final repository = buildRepository();
    await pumpScreen(tester, repository);

    await tester.ensureVisible(find.byKey(const Key('conversation-create')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conversation-create')));
    await tester.pumpAndSettle();
    expect(find.text('New conversation'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('conversation-title-field')),
      'Team standup',
    );
    await tester.tap(find.byKey(const Key('conversation-create-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Team standup'), findsOneWidget);
    expect(find.text('No conversations yet'), findsNothing);
    expect(find.byType(ListTile), findsOneWidget);
    expect(await repository.list(), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling creates nothing', (WidgetTester tester) async {
    final repository = buildRepository();
    await pumpScreen(tester, repository);

    await tester.ensureVisible(find.byKey(const Key('conversation-create')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conversation-create')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('conversation-title-field')),
      'Discarded',
    );
    await tester.tap(find.byKey(const Key('conversation-create-cancel')));
    await tester.pumpAndSettle();

    expect(find.text('No conversations yet'), findsOneWidget);
    expect(find.text('Discarded'), findsNothing);
    expect(await repository.list(), isEmpty);
  });

  testWidgets('a blank title is refused with a reason, not a silent no-op',
      (WidgetTester tester) async {
    final repository = buildRepository();
    await pumpScreen(tester, repository);

    await tester.ensureVisible(find.byKey(const Key('conversation-create')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conversation-create')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('conversation-title-field')),
      '   ',
    );
    await tester.tap(find.byKey(const Key('conversation-create-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('A conversation needs a title.'), findsOneWidget);
    expect(find.text('No conversations yet'), findsOneWidget);
    expect(await repository.list(), isEmpty);
  });
}
