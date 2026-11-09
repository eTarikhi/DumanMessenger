// import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_routes.dart';
import 'ble/ble_diagnostic_bridge.dart';
import 'ble/ble_discovery_bridge.dart';
import 'ble/g2c_ble_bridge.dart';
import 'screens/ble_diagnostic_screen.dart';
import 'screens/ble_discovery_screen.dart';
import 'screens/g2c_ble_screen.dart';
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
  });

  final BleDiagnosticApi? bleDiagnosticApi;
  final BleDiscoveryApi? bleDiscoveryApi;
  final G2cBleApi? g2cBleApi;

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
          routes: {
            AppRoutes.onboarding: (_) => const OnboardingScreen(),
            AppRoutes.conversations: (_) => const ConversationListScreen(),
            AppRoutes.settings: (_) => SettingsScreen(
              themeMode: _themeMode,
              onThemeModeChanged: (mode) => _themeMode.value = mode,
            ),
            AppRoutes.diagnostics: (_) => const DiagnosticsScreen(),
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
