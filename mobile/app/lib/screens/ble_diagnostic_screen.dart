import 'dart:async';

import 'package:flutter/material.dart';

import '../ble/ble_diagnostic_bridge.dart';
import '../ble/ble_diagnostic_status.dart';
import '../widgets/app_page_body.dart';

class BleDiagnosticScreen extends StatefulWidget {
  const BleDiagnosticScreen({super.key, this.bridge});

  final BleDiagnosticApi? bridge;

  @override
  State<BleDiagnosticScreen> createState() => _BleDiagnosticScreenState();
}

class _BleDiagnosticScreenState extends State<BleDiagnosticScreen> {
  late final BleDiagnosticApi _bridge = widget.bridge ?? BleDiagnosticBridge();
  late final StreamSubscription<BleDiagnosticStatus> _statusSubscription;

  BleDiagnosticStatus? _status;
  bool _loading = true;
  bool _requestingPermission = false;

  @override
  void initState() {
    super.initState();
    _statusSubscription = _bridge.watchStatus().listen(
      _acceptStatus,
      onError: (Object _) {
        _acceptStatus(BleDiagnosticStatus.diagnosticError());
      },
    );
    unawaited(_refresh());
  }

  @override
  void dispose() {
    unawaited(_statusSubscription.cancel());
    super.dispose();
  }

  Future<void> _refresh() async {
    if (mounted && _status != null && !_loading) {
      setState(() => _loading = true);
    }
    BleDiagnosticStatus nextStatus;
    try {
      nextStatus = await _bridge.refresh();
    } catch (_) {
      nextStatus = BleDiagnosticStatus.diagnosticError();
    }
    if (!mounted) return;
    setState(() {
      _status = nextStatus;
      _loading = false;
    });
  }

  Future<void> _requestRequiredPermissions() async {
    setState(() => _requestingPermission = true);
    BleDiagnosticStatus nextStatus;
    try {
      nextStatus = await _bridge.requestRequiredPermissions();
    } catch (_) {
      nextStatus = BleDiagnosticStatus.diagnosticError();
    }
    if (!mounted) return;
    setState(() {
      _status = nextStatus;
      _requestingPermission = false;
      _loading = false;
    });
  }

  void _acceptStatus(BleDiagnosticStatus status) {
    if (!mounted) return;
    setState(() {
      _status = status;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('BLE diagnostic')),
      body: AppPageBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Android BLE prerequisites',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'G2-A reports local capability, adapter, Bluetooth, and permission '
              'status only. It does not scan, advertise, connect, pair, exchange '
              'messages, or turn Bluetooth on.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 20),
            if (_loading && status == null)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(
                    key: Key('ble-diagnostic-loading'),
                  ),
                ),
              )
            else if (status != null) ...[
              _StatusCard(status: status),
              const SizedBox(height: 12),
              _ActionRow(
                loading: _loading || _requestingPermission,
                requestingPermission: _requestingPermission,
                onRefresh: _refresh,
                onRequestPermissions: _requestRequiredPermissions,
                showRequestButton: status.canRequestRequiredPermissions,
              ),
              if (status.requiresManualPermissionSettings) ...[
                const SizedBox(height: 8),
                const Text(
                  'A required permission cannot be requested again from this '
                  'screen. Review the app permission in Android system settings '
                  'and return here to refresh. This diagnostic will not open '
                  'settings automatically.',
                  key: Key('ble-manual-permission-guidance'),
                ),
              ],
              const SizedBox(height: 20),
              _CapabilitiesCard(status: status),
              const SizedBox(height: 16),
              _PermissionsCard(status: status),
            ] else ...[
              const Text(
                'Diagnostic status is not available. Refresh to try again.',
                key: Key('ble-no-status'),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('ble-refresh'),
                  onPressed: _loading ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'No adapter name, MAC address, bonded-device list, stable '
              'identity, or message data is read or displayed.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});

  final BleDiagnosticStatus status;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = switch (status.state) {
      BleDiagnosticState.ready => colorScheme.primary,
      BleDiagnosticState.bluetoothDisabled ||
      BleDiagnosticState.permissionsDenied => colorScheme.error,
      BleDiagnosticState.unsupportedPlatform ||
      BleDiagnosticState.bleHardwareUnavailable ||
      BleDiagnosticState.nativeServiceUnavailable ||
      BleDiagnosticState.error => colorScheme.onSurfaceVariant,
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.bluetooth, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    status.displayLabel,
                    key: const Key('ble-status-label'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  if (status.reason != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      status.reason!,
                      key: const Key('ble-status-reason'),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    'Prerequisite check only; no BLE radio operation was performed.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.loading,
    required this.requestingPermission,
    required this.onRefresh,
    required this.onRequestPermissions,
    required this.showRequestButton,
  });

  final bool loading;
  final bool requestingPermission;
  final VoidCallback onRefresh;
  final VoidCallback onRequestPermissions;
  final bool showRequestButton;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          key: const Key('ble-refresh'),
          onPressed: loading ? null : onRefresh,
          icon: loading && !requestingPermission
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          label: const Text('Refresh'),
        ),
        if (showRequestButton)
          FilledButton.icon(
            key: const Key('ble-request-permissions'),
            onPressed: loading || requestingPermission
                ? null
                : onRequestPermissions,
            icon: requestingPermission
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.security),
            label: const Text('Request required permission'),
          ),
      ],
    );
  }
}

class _CapabilitiesCard extends StatelessWidget {
  const _CapabilitiesCard({required this.status});

  final BleDiagnosticStatus status;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          _DiagnosticRow(
            label: 'Android API level',
            value: status.apiLevel?.toString() ?? 'Unavailable',
          ),
          const Divider(height: 1),
          _DiagnosticRow(
            label: 'Bluetooth LE hardware',
            value: _boolLabel(status.bleHardwareSupported),
          ),
          const Divider(height: 1),
          _DiagnosticRow(
            label: 'Bluetooth service',
            value: _boolLabel(status.bluetoothManagerAvailable),
          ),
          const Divider(height: 1),
          _DiagnosticRow(
            label: 'Adapter available',
            value: _boolLabel(status.adapterAvailable),
          ),
          const Divider(height: 1),
          _DiagnosticRow(
            label: 'Bluetooth enabled',
            value: _boolLabel(status.bluetoothEnabled),
          ),
          const Divider(height: 1),
          _DiagnosticRow(
            label: 'Advertising capability',
            value: switch (status.advertisingCapability) {
              BleAdvertisingCapability.supported => 'Reported supported',
              BleAdvertisingCapability.unsupported => 'Reported unsupported',
              BleAdvertisingCapability.unknown => 'Unknown',
            },
          ),
        ],
      ),
    );
  }

  String _boolLabel(bool? value) => switch (value) {
        true => 'Yes',
        false => 'No',
        null => 'Unknown',
      };
}

class _PermissionsCard extends StatelessWidget {
  const _PermissionsCard({required this.status});

  final BleDiagnosticStatus status;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                'Android permissions',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (status.permissions.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Permission details are unavailable on this platform.'),
              )
            else
              for (final permission in status.permissions)
                _PermissionTile(permission: permission),
          ],
        ),
      ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  const _PermissionTile({required this.permission});

  final BlePermissionStatus permission;

  @override
  Widget build(BuildContext context) {
    final displayName = _permissionName(permission.name);
    final stateLabel = switch (permission.state) {
      BlePermissionState.granted => 'Granted',
      BlePermissionState.denied => permission.requiredForDiagnostics
          ? 'Denied'
          : 'Not granted (not requested by G2-A)',
      BlePermissionState.notRequired => 'Not applicable on this Android version',
    };
    final detail = switch (permission.name) {
      'android.permission.BLUETOOTH_CONNECT' =>
        'Used only to inspect the local adapter state on Android 12 and later.',
      'android.permission.BLUETOOTH_SCAN' =>
        'Scanning is outside G2-A; this permission is not requested here.',
      'android.permission.BLUETOOTH_ADVERTISE' =>
        'Advertising is outside G2-A; this permission is not requested here.',
      'android.permission.ACCESS_FINE_LOCATION' =>
        'Declared through Android 11 (API 30) for legacy BLE compatibility; '
            'G2-A does not request or use location.',
      _ => permission.requiredForDiagnostics
          ? 'Declared for local Android Bluetooth diagnostics.'
          : 'Not needed by the G2-A diagnostic scope.',
    };
    final typeLabel = permission.state == BlePermissionState.notRequired
        ? null
        : permission.isRuntime
            ? 'Runtime permission'
            : 'Normal permission';
    final subtitle = <String>[
      stateLabel,
      ?typeLabel,
      detail,
    ].join('. ');

    return ListTile(
      key: ValueKey<String>('ble-permission-${permission.name}'),
      dense: true,
      title: Text(displayName),
      subtitle: Text(subtitle),
      trailing: permission.shouldShowRationale
          ? const Tooltip(
              message: 'Android indicates that a permission rationale is appropriate.',
              child: Icon(Icons.info_outline),
            )
          : null,
    );
  }

  String _permissionName(String permission) => switch (permission) {
        'android.permission.BLUETOOTH_SCAN' => 'Bluetooth scan',
        'android.permission.BLUETOOTH_ADVERTISE' => 'Bluetooth advertise',
        'android.permission.BLUETOOTH_CONNECT' => 'Bluetooth connect',
        'android.permission.BLUETOOTH' => 'Bluetooth (legacy)',
        'android.permission.BLUETOOTH_ADMIN' => 'Bluetooth admin (legacy)',
        'android.permission.ACCESS_FINE_LOCATION' => 'Location (fine, legacy)',
        _ => permission,
      };
}

class _DiagnosticRow extends StatelessWidget {
  const _DiagnosticRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
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
