import 'package:duman_messenger/conversations/conversation.dart';
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
    // The FAB is also labelled "New conversation", so the title must be
    // matched inside the dialog rather than anywhere on screen.
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('New conversation'),
      ),
      findsOneWidget,
    );
    expect(find.byType(AlertDialog), findsOneWidget);

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

  testWidgets('renames a conversation from the row menu',
      (WidgetTester tester) async {
    final repository = buildRepository();
    final G2dConversation created = await repository.create('Before');
    await pumpScreen(tester, repository);

    await tester.tap(find.byKey(Key('conversation-menu-${created.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('conversation-rename-field')),
      'After',
    );
    await tester.tap(find.byKey(const Key('conversation-rename-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('After'), findsOneWidget);
    expect(find.text('Before'), findsNothing);
    expect((await repository.list()).single.title, 'After');
    expect(tester.takeException(), isNull);
  });

  testWidgets('deletes a conversation only after confirmation',
      (WidgetTester tester) async {
    final repository = buildRepository();
    final G2dConversation created = await repository.create('Remove me');
    await pumpScreen(tester, repository);

    await tester.tap(find.byKey(Key('conversation-menu-${created.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conversation-delete-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('Remove me'), findsOneWidget);
    expect(await repository.list(), hasLength(1));

    await tester.tap(find.byKey(Key('conversation-menu-${created.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conversation-delete-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Remove me'), findsNothing);
    expect(find.text('No conversations yet'), findsOneWidget);
    expect(await repository.list(), isEmpty);
  });
}
