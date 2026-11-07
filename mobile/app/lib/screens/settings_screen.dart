import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_routes.dart';
import '../widgets/app_page_body.dart';
import '../widgets/foundation_notice.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final ValueListenable<ThemeMode> themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: AppPageBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Appearance',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Theme choice is in memory only and resets when the app closes.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 20),
            ValueListenableBuilder<ThemeMode>(
              valueListenable: themeMode,
              builder: (context, selectedMode, _) {
                return SegmentedButton<ThemeMode>(
                  key: const Key('theme-mode-selector'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.system,
                      label: Text('System', key: Key('theme-label-system')),
                    ),
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.light,
                      label: Text('Light', key: Key('theme-label-light')),
                    ),
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.dark,
                      label: Text('Dark', key: Key('theme-label-dark')),
                    ),
                  ],
                  selected: {selectedMode},
                  onSelectionChanged: (selection) {
                    if (selection.isNotEmpty) {
                      onThemeModeChanged(selection.first);
                    }
                  },
                );
              },
            ),
            const SizedBox(height: 24),
            const FoundationNotice(),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('settings-open-diagnostics'),
              onPressed: () =>
                  Navigator.of(context).pushNamed(AppRoutes.diagnostics),
              icon: const Icon(Icons.info_outline),
              label: const Text('View local diagnostics'),
            ),
          ],
        ),
      ),
    );
  }
}
