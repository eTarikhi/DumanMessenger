// import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_routes.dart';
import 'ble/ble_diagnostic_bridge.dart';
import 'ble/ble_discovery_bridge.dart';
import 'ble/g2c_ble_bridge.dart';
import 'conversations/conversation_repository.dart';
import 'messages/message_repository.dart';
import 'screens/conversation_detail_screen.dart';
import 'identity/identity_runtime_controller.dart';
import 'screens/ble_diagnostic_screen.dart';
import 'screens/ble_discovery_screen.dart';
import 'screens/g2c_ble_screen.dart';
import 'screens/my_identity_screen.dart';
import 'screens/conversation_list_screen.dart';
import 'screens/diagnostics_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/settings_screen.dart';

class DumanMessengerApp extends StatefulWidget {
  const DumanMessengerApp({
    super.key,
    this.bleDiagnosticApi,
    this.bleDiscoveryApi,
    this.g2cBleApi,
    this.identityRuntime,
    this.conversationRepository,
    this.messageRepository,
  });

  final BleDiagnosticApi? bleDiagnosticApi;
  final BleDiscoveryApi? bleDiscoveryApi;
  final G2cBleApi? g2cBleApi;

  /// The application's single identity runtime, created in `main`.
  ///
  /// Optional so tests and secondary entry points can build the app without a
  /// platform behind them; the diagnostics screen then reports the runtime as
  /// not wired rather than inventing a state.
  final G2dIdentityRuntimeController? identityRuntime;

  /// The application's conversation repository, created in `main`.
  ///
  /// Optional so tests can build the app without one; the conversations screen
  /// then keeps its own in-memory repository and says it persists nothing.
  final G2dConversationRepository? conversationRepository;

  /// The application's message repository, created in `main`. Optional for the
  /// same reason as the conversation repository.
  final G2dMessageRepository? messageRepository;

  @override
  State<DumanMessengerApp> createState() => _DumanMessengerAppState();
}

class _DumanMessengerAppState extends State<DumanMessengerApp> {
  final ValueNotifier<ThemeMode> _themeMode = ValueNotifier(ThemeMode.system);

  @override
  void dispose() {
    _themeMode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _themeMode,
      builder: (context, themeMode, _) {
        return MaterialApp(
          title: 'Duman Messenger',
          debugShowCheckedModeBanner: false,
          theme: _themeFor(Brightness.light),
          darkTheme: _themeFor(Brightness.dark),
          themeMode: themeMode,
          initialRoute: AppRoutes.onboarding,
          onGenerateRoute: (RouteSettings settings) {
            if (settings.name == AppRoutes.conversationDetail) {
              final Object? arguments = settings.arguments;
              return MaterialPageRoute<void>(
                settings: settings,
                builder: (BuildContext context) => ConversationDetailScreen(
                  conversationId: arguments is String ? arguments : null,
                  conversationRepository: widget.conversationRepository,
                  messageRepository: widget.messageRepository,
                ),
              );
            }
            return null;
          },
          routes: {
            AppRoutes.onboarding: (_) => const OnboardingScreen(),
            AppRoutes.conversations: (_) => ConversationListScreen(
              repository: widget.conversationRepository,
              messageRepository: widget.messageRepository,
            ),
            AppRoutes.identity: (_) => MyIdentityScreen(
              identityRuntime: widget.identityRuntime,
            ),
            AppRoutes.settings: (_) => SettingsScreen(
              themeMode: _themeMode,
              onThemeModeChanged: (mode) => _themeMode.value = mode,
            ),
            AppRoutes.diagnostics: (_) => DiagnosticsScreen(
              identityRuntime: widget.identityRuntime,
            ),
            AppRoutes.bleDiagnostics: (_) => BleDiagnosticScreen(
              bridge: widget.bleDiagnosticApi,
            ),
            AppRoutes.bleDiscovery: (_) => BleDiscoveryScreen(
              bridge: widget.bleDiscoveryApi,
            ),
            AppRoutes.g2cBle: (_) => G2cBleScreen(bridge: widget.g2cBleApi),
          },
        );
      },
    );
  }

  ThemeData _themeFor(Brightness brightness) {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF3B7564),
        brightness: brightness,
      ),
      useMaterial3: true,
    );
  }
}
