import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_routes.dart';
import '../identity/identity_runtime_controller.dart';
import '../identity/identity_service.dart';
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
  const DiagnosticsScreen({super.key, this.snapshot, this.identityRuntime});

  final DiagnosticsSnapshot? snapshot;

  /// The application's identity runtime. Reported as measured, never assumed.
  final G2dIdentityRuntimeController? identityRuntime;

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
            _IdentityCard(controller: identityRuntime),
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
  const _DiagnosticRow({required this.label, required this.value, this.valueKey});

  final String label;
  final String value;

  /// Key placed on the value [Text].
  ///
  /// Diagnostics legitimately repeat values (`no`, for example, is both "not
  /// hardware-backed" and "no StrongBox key"), so a test that matches on the
  /// string alone cannot tell which row it read. The key makes the row's value
  /// addressable without changing what is displayed.
  final Key? valueKey;

  /// Width below which the row stacks instead of using two columns.
  ///
  /// At 320 logical pixels the card is ~272 wide after page padding, and two
  /// columns of that leave too little for a failure description to read well.
  static const double _stackBelow = 360;

  static const EdgeInsets _padding =
      EdgeInsets.symmetric(horizontal: 16, vertical: 14);

  @override
  Widget build(BuildContext context) {
    final TextStyle? valueStyle = Theme.of(context).textTheme.labelLarge;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool stacked = constraints.maxWidth < _stackBelow;
        final Widget labelText = Text(label, softWrap: true);
        final Widget valueText = Text(
          value,
          key: valueKey,
          style: valueStyle,
          softWrap: true,
          textAlign: stacked ? TextAlign.start : TextAlign.end,
        );

        if (stacked) {
          return Padding(
            padding: _padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                labelText,
                const SizedBox(height: 4),
                valueText,
              ],
            ),
          );
        }

        // Two columns, both constrained: a long value wraps inside its own
        // share instead of pushing the row past the right edge. Nothing is
        // ellipsised, so a failure reason is never shortened.
        return Padding(
          padding: _padding,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(flex: 2, child: labelText),
              const SizedBox(width: 12),
              Expanded(flex: 3, child: valueText),
            ],
          ),
        );
      },
    );
  }
}

/// Asks before creating an identity, then creates it.
///
/// The confirmation states what is generated and how it is protected — a software
/// Ed25519/X25519 keypair wrapped at rest by the Keystore — because the honest
/// description of this device is not "hardware-backed" and the button must not
/// imply otherwise.
Future<void> _confirmCreateIdentity(
  BuildContext context,
  G2dIdentityRuntimeController runtime,
) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('Create identity?'),
      content: const Text(
        'This generates a Curve25519 identity keypair on this device. The private '
        'keys are stored only inside the Keystore-encrypted slot. They are '
        'software-generated and protected at rest, not hardware-backed, and there '
        'is no messaging or session capability yet.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('diagnostics-create-identity-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Create'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) {
    return;
  }
  try {
    await runtime.createIdentity();
  } catch (_) {
    // Surfaced through the card's "Last operation error" row.
  }
}

/// Identity state as the application can honestly report it.
///
/// Nothing here displays key material, a fingerprint or an identity id: the card
/// shows *states* and *measurements*, so a screenshot cannot leak an identity.
class _IdentityCard extends StatelessWidget {
  const _IdentityCard({this.controller});

  final G2dIdentityRuntimeController? controller;

  @override
  Widget build(BuildContext context) {
    final runtime = controller;
    if (runtime == null) {
      return const Card(
        child: _DiagnosticRow(
          label: 'Identity runtime',
          value: 'not wired',
          valueKey: Key('diagnostics-identity-status'),
        ),
      );
    }
    return AnimatedBuilder(
      animation: runtime,
      builder: (BuildContext context, Widget? _) {
        return Card(
          child: Column(
            children: <Widget>[
              _DiagnosticRow(
                label: 'Identity runtime',
                value: _statusLabel(runtime.status),
                valueKey: const Key('diagnostics-identity-status'),
              ),
              const Divider(height: 1),
              _DiagnosticRow(
                label: 'At-rest protection',
                value: runtime.protectionSummary ?? 'not measured',
                valueKey: const Key('diagnostics-identity-protection'),
              ),
              const Divider(height: 1),
              _DiagnosticRow(
                label: 'Wrapping key hardware-backed',
                value: _boolLabel(runtime.wrapKeyHardwareBacked),
                valueKey: const Key('diagnostics-identity-hardware-backed'),
              ),
              const Divider(height: 1),
              _DiagnosticRow(
                label: 'StrongBox key created',
                value: _boolLabel(runtime.strongBoxVerified),
                valueKey: const Key('diagnostics-identity-strongbox'),
              ),
              const Divider(height: 1),
              _DiagnosticRow(
                label: 'Identity',
                value: _snapshotLabel(runtime.snapshot),
                valueKey: const Key('diagnostics-identity-state'),
              ),
              const Divider(height: 1),
              _DiagnosticRow(
                label: 'Identity key protection',
                value: runtime.keyProtection ?? 'not created',
                valueKey: const Key('diagnostics-identity-key-protection'),
              ),
              if (runtime.failureReason != null) ...<Widget>[
                const Divider(height: 1),
                _DiagnosticRow(
                  label: 'Unavailable because',
                  value: runtime.failureReason!,
                  valueKey: const Key('diagnostics-identity-failure-reason'),
                ),
              ],
              if (runtime.operationError != null) ...<Widget>[
                const Divider(height: 1),
                _DiagnosticRow(
                  label: 'Last operation error',
                  value: runtime.operationError!,
                  valueKey: const Key('diagnostics-identity-operation-error'),
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const Key('diagnostics-read-identity'),
                    onPressed: runtime.isReady && !runtime.busy
                        ? () => unawaited(runtime.reload())
                        : null,
                    icon: const Icon(Icons.badge_outlined),
                    label: const Text('Read identity from this device'),
                  ),
                ),
              ),
              if (runtime.snapshot is G2dIdentityAbsent)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      key: const Key('diagnostics-create-identity'),
                      onPressed: runtime.canCreateIdentity
                          ? () => unawaited(_confirmCreateIdentity(context, runtime))
                          : null,
                      icon: const Icon(Icons.key_outlined),
                      label: const Text('Create identity on this device'),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  static String _statusLabel(G2dIdentityRuntimeStatus status) =>
      switch (status) {
        G2dIdentityRuntimeStatus.unsupportedPlatform =>
          'not supported on this platform',
        G2dIdentityRuntimeStatus.initializing => 'initializing',
        G2dIdentityRuntimeStatus.ready => 'ready',
        G2dIdentityRuntimeStatus.unavailable => 'unavailable',
      };

  static String _boolLabel(bool? value) {
    if (value == null) {
      return 'not measured';
    }
    return value ? 'yes' : 'no';
  }

  static String _snapshotLabel(G2dIdentitySnapshot? snapshot) {
    if (snapshot == null) {
      return 'not read yet';
    }
    return switch (snapshot) {
      G2dIdentityAbsent() => 'none stored',
      G2dIdentityActive() => 'active',
      G2dIdentityRotationPending() => 'rotation pending',
      G2dIdentityRevoked() => 'revoked',
      G2dIdentityStorageUnavailable() => 'storage unavailable',
      G2dIdentityCorrupt() => 'unreadable (reset required)',
    };
  }
}
