import 'package:duman_messenger/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows onboarding limitations', (tester) async {
    await tester.pumpWidget(const DumanMessengerApp());

    expect(find.text('Welcome to Duman Messenger'), findsOneWidget);
    expect(
      find.textContaining('messaging and mesh are unavailable'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'No mesh transport, delivery, or encryption is implemented.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'No location, Bluetooth, camera, microphone, or file access.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('onboarding-continue')), findsOneWidget);
  });

  testWidgets('continue opens the empty conversations screen', (tester) async {
    await tester.pumpWidget(const DumanMessengerApp());
    await tester.ensureVisible(find.byKey(const Key('onboarding-continue')));
    await tester.tap(find.byKey(const Key('onboarding-continue')));
    await tester.pumpAndSettle();

    expect(find.text('Conversations'), findsOneWidget);
    expect(find.text('No conversations yet'), findsOneWidget);
  });
}
