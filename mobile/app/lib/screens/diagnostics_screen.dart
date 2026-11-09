import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_routes.dart';
import '../widgets/app_page_body.dart';

class DiagnosticsSnapshot {
  const DiagnosticsSnapshot({required this.platform, required this.buildMode});

  final String platform;
  final String buildMode;

  factory DiagnosticsSnapshot.current() {
    return DiagnosticsSnapshot(
      platform: _platformLabel(defaultTargetPlatform),
      buildMode: _currentBuildMode(),
    );
  }

  static String _platformLabel(TargetPlatform platform) {
    switch (platform) {
      case TargetPlatform.android:
        return 'Android';
      case TargetPlatform.iOS:
        return 'iOS';
      case TargetPlatform.fuchsia:
        return 'Fuchsia';
      case TargetPlatform.linux:
        return 'Linux';
      case TargetPlatform.macOS:
        return 'macOS';
      case TargetPlatform.windows:
        return 'Windows';
    }
  }

  static String _currentBuildMode() {
    if (kReleaseMode) {
      return 'Release';
    }
    if (kProfileMode) {
      return 'Profile';
    }
    return 'Debug';
  }
}

class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key, this.snapshot});

  final DiagnosticsSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    final details = snapshot ?? DiagnosticsSnapshot.current();

    return Scaffold(
      appBar: AppBar(title: const Text('Local diagnostics')),
      body: AppPageBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'App environment',
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'This screen shows app environment details and links to the local '
              'BLE prerequisite diagnostic and foreground discovery experiment.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 20),
            Card(
              child: Column(
                children: [
                  _DiagnosticRow(label: 'Platform', value: details.platform),
                  const Divider(height: 1),
                  _DiagnosticRow(label: 'Build mode', value: details.buildMode),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('diagnostics-open-ble'),
                onPressed: () => Navigator.of(context)
                    .pushNamed(AppRoutes.bleDiagnostics),
                icon: const Icon(Icons.bluetooth),
                label: const Text('Android BLE diagnostic'),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('diagnostics-open-ble-discovery'),
                onPressed: () => Navigator.of(context)
                    .pushNamed(AppRoutes.bleDiscovery),
                icon: const Icon(Icons.bluetooth_searching),
                label: const Text('Foreground BLE discovery'),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('diagnostics-open-g2c-ble'),
                onPressed: () => Navigator.of(context).pushNamed(AppRoutes.g2cBle),
                icon: const Icon(Icons.security),
                label: const Text('G2-C BLE link (TEST ONLY)'),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'No telemetry, messages, device IDs, or keys are collected.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _DiagnosticRow extends StatelessWidget {
  const _DiagnosticRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          const SizedBox(width: 12),
          Text(value, style: Theme.of(context).textTheme.labelLarge),
        ],
      ),
    );
  }
}
