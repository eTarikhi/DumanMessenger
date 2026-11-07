import 'package:duman_messenger/screens/diagnostics_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows local platform and build mode only', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DiagnosticsScreen(
          snapshot: DiagnosticsSnapshot(
            platform: 'Android',
            buildMode: 'Debug',
          ),
        ),
      ),
    );

    expect(find.text('Local diagnostics'), findsOneWidget);
    expect(find.text('Platform'), findsOneWidget);
    expect(find.text('Android'), findsOneWidget);
    expect(find.text('Build mode'), findsOneWidget);
    expect(find.text('Debug'), findsOneWidget);
    expect(
      find.textContaining('No telemetry, messages'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('uses current runtime diagnostics', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DiagnosticsScreen()));

    expect(find.text('Platform'), findsOneWidget);
    expect(find.text('Build mode'), findsOneWidget);
    expect(find.textContaining('device identifier'), findsNothing);
  });
}
