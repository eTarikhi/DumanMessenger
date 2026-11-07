import 'package:duman_messenger/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> showConversations(WidgetTester tester) async {
  await tester.pumpWidget(const DumanMessengerApp());
  await tester.ensureVisible(find.byKey(const Key('onboarding-continue')));
  await tester.tap(find.byKey(const Key('onboarding-continue')));
  await tester.pumpAndSettle();
}
