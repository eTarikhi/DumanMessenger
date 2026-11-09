import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  testWidgets('shows an honest empty state', (tester) async {
    await showConversations(tester);

    expect(find.text('No conversations yet'), findsOneWidget);
    expect(
      find.text('No messages or contacts are available in this build.'),
      findsOneWidget,
    );
    expect(find.byType(ListTile), findsNothing);
    expect(find.byIcon(Icons.send), findsNothing);
    expect(find.byKey(const Key('open-settings')), findsOneWidget);
    expect(find.byKey(const Key('open-diagnostics')), findsOneWidget);
  });

  testWidgets('settings action opens settings', (tester) async {
    await showConversations(tester);

    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
  });
}
