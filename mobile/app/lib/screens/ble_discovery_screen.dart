import 'dart:async';

import 'package:flutter/material.dart';

import '../ble/ble_diagnostic_status.dart';
import '../ble/ble_discovery_bridge.dart';
import '../ble/ble_discovery_status.dart';
import '../widgets/app_page_body.dart';

class BleDiscoveryScreen extends StatefulWidget {
  const BleDiscoveryScreen({super.key, this.bridge});

  final BleDiscoveryApi? bridge;

  @override
  State<BleDiscoveryScreen> createState() => _BleDiscoveryScreenState();
}

class _BleDiscoveryScreenState extends State<BleDiscoveryScreen>
    with WidgetsBindingObserver {
  late final BleDiscoveryApi _bridge = widget.bridge ?? BleDiscoveryBridge();
  late final StreamSubscription<BleDiscoveryStatus> _statusSubscription;

  BleDiscoveryStatus _status = BleDiscoveryStatus.initial();
  bool _loading = true;
  bool _actionInProgress = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _statusSubscription = _bridge.watchStatus().listen(
      _acceptStatus,
      onError: (Object _) => _acceptStatus(BleDiscoveryStatus.channelError()),
    );
    unawaited(_refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // A permission sheet can temporarily affect lifecycle state. Let that
      // user-initiated request finish; native Activity pause handling still
      // stops any active radio operation.
      if (!_status.isRequestingPermission && !_actionInProgress) {
        unawaited(_stopForLifecycle());
      }
    } else if (state == AppLifecycleState.resumed) {
      // Refresh permission/adapter state, but never automatically restart BLE.
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stopForDispose());
    unawaited(_statusSubscription.cancel());
    super.dispose();
  }

  Future<void> _refresh() async {
    BleDiscoveryStatus nextStatus;
    try {
      nextStatus = await _bridge.refresh();
    } catch (_) {
      nextStatus = BleDiscoveryStatus.channelError();
    }
    if (!mounted) return;
    setState(() {
      _status = nextStatus;
      _loading = false;
    });
  }

  Future<void> _stopForLifecycle() async {
    try {
      final status = await _bridge.stopAll();
      if (!mounted) return;
      setState(() => _status = status);
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = BleDiscoveryStatus.channelError());
    }
  }

  Future<void> _stopForDispose() async {
    try {
      await _bridge.stopAll();
    } catch (_) {
      // Screen teardown must continue even if the native channel is unavailable.
    }
  }

  void _acceptStatus(BleDiscoveryStatus status) {
    if (!mounted) return;
    setState(() {
      _status = status;
      _loading = false;
    });
  }

  Future<void> _startScanning() async {
    final locationPermission =
        _status.permission('android.permission.ACCESS_FINE_LOCATION');
    final requiresLegacyRationale =
        (_status.apiLevel ?? 31) <= 30 &&
        locationPermission?.requiredForScanning == true &&
        locationPermission?.state == BlePermissionState.denied &&
        locationPermission?.canRequestAgain == true;

    if (requiresLegacyRationale) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const Key('ble-discovery-legacy-location-rationale'),
          title: const Text('Android scan permission'),
          content: const Text(
            'Android 6–11 requires foreground location permission for BLE '
            'scanning. DumanMessenger uses it only to scan for the service UUID; '
            'the app does not access, collect, or store location.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (!mounted || proceed != true) return;
    }

    await _perform(_bridge.startScanning);
  }

  Future<void> _perform(
    Future<BleDiscoveryStatus> Function() operation,
  ) async {
    if (_actionInProgress || !mounted) return;
    setState(() => _actionInProgress = true);
    try {
      final status = await operation();
      if (!mounted) return;
      setState(() => _status = status);
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = BleDiscoveryStatus.channelError());
    } finally {
      if (mounted) setState(() => _actionInProgress = false);
    }
  }

  bool get _canStartAdvertising =>
      _canStartOperation(
        _status.advertisingState,
        _status.advertiserAvailable,
        forScanning: false,
      );

  bool get _canStartScanning =>
      _canStartOperation(
        _status.scanningState,
        _status.scannerAvailable,
        forScanning: true,
      );

  bool _canStartOperation(
    BleDiscoveryOperationState operationState,
    bool? operationAvailable, {
    required bool forScanning,
  }) {
    if (_loading ||
        _actionInProgress ||
        _status.isRequestingPermission ||
        _status.bleHardwareSupported != true ||
        _status.adapterAvailable == false ||
        _status.adapterEnabled == false ||
        operationAvailable == false ||
        operationState == BleDiscoveryOperationState.active ||
        operationState == BleDiscoveryOperationState.starting ||
        operationState == BleDiscoveryOperationState.unsupported) {
      return false;
    }

    final deniedRequiredPermission = _status.permissions.where((item) {
      final requiredForOperation = forScanning
          ? item.requiredForScanning
          : item.requiredForAdvertising;
      return requiredForOperation &&
          item.state == BlePermissionState.denied &&
          !item.canRequestAgain;
    });
    return deniedRequiredPermission.isEmpty;
  }

  bool _isOperationRunning(BleDiscoveryOperationState state) =>
      state == BleDiscoveryOperationState.active ||
      state == BleDiscoveryOperationState.starting;

  bool _canStop(BleDiscoveryOperationState state) =>
      _isOperationRunning(state) ||
      state == BleDiscoveryOperationState.requestingPermission;

  String _operationLabel(BleDiscoveryOperationState state) => switch (state) {
        BleDiscoveryOperationState.idle => 'Stopped',
        BleDiscoveryOperationState.requestingPermission =>
          'Waiting for Android permission',
        BleDiscoveryOperationState.starting => 'Starting',
        BleDiscoveryOperationState.active => 'Running in the foreground',
        BleDiscoveryOperationState.permissionDenied => 'Permission required',
        BleDiscoveryOperationState.unsupported => 'Unsupported',
        BleDiscoveryOperationState.unavailable => 'Unavailable',
        BleDiscoveryOperationState.failed => 'Could not start',
      };

  String _boolLabel(bool? value) => switch (value) {
        true => 'Available',
        false => 'Unavailable',
        null => 'Unknown',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('BLE discovery')),
      body: AppPageBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Foreground BLE discovery',
              key: const Key('ble-discovery-title'),
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'G2-B advertises and scans only the DumanMessenger service UUID. '
              'Operations run only while this app is in the foreground and stop '
              'when the app leaves it or this screen is closed.',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Service UUID: $dumanMessengerBleServiceUuid',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else ...[
              _CapabilityCard(status: _status, boolLabel: _boolLabel),
              const SizedBox(height: 12),
              _OperationCard(
                title: 'Advertising',
                state: _status.advertisingState,
                stateKey: const Key('ble-discovery-advertising-state'),
                startKey: const Key('ble-discovery-start-advertising'),
                stopKey: const Key('ble-discovery-stop-advertising'),
                onStart: () => _perform(_bridge.startAdvertising),
                onStop: () => _perform(_bridge.stopAdvertising),
                canStart: _canStartAdvertising,
                canStop: _canStop(_status.advertisingState),
                actionInProgress: _actionInProgress,
                label: _operationLabel,
              ),
              const SizedBox(height: 12),
              _OperationCard(
                title: 'Scanning',
                state: _status.scanningState,
                stateKey: const Key('ble-discovery-scanning-state'),
                startKey: const Key('ble-discovery-start-scanning'),
                stopKey: const Key('ble-discovery-stop-scanning'),
                onStart: _startScanning,
                onStop: () => _perform(_bridge.stopScanning),
                canStart: _canStartScanning,
                canStop: _canStop(_status.scanningState),
                actionInProgress: _actionInProgress,
                label: _operationLabel,
              ),
              const SizedBox(height: 12),
              _DiscoveryResultsCard(status: _status),
              const SizedBox(height: 12),
              _DiscoveryPermissionsCard(status: _status),
              if (_status.message != null) ...[
                const SizedBox(height: 12),
                _MessageCard(message: _status.message!),
              ],
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('ble-discovery-refresh'),
              onPressed: _loading || _actionInProgress ? null : _refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh status'),
            ),
            const SizedBox(height: 16),
            Text(
              'A matching advertisement is not authentication, trust, pairing, '
              'or a connection. No device name or address is read or shown; '
              'temporary results are held only in memory.',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({required this.status, required this.boolLabel});

  final BleDiscoveryStatus status;
  final String Function(bool?) boolLabel;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          _StatusRow(
            label: 'BLE hardware',
            value: boolLabel(status.bleHardwareSupported),
          ),
          const Divider(height: 1),
          _StatusRow(
            label: 'Bluetooth adapter',
            value: boolLabel(status.adapterAvailable),
          ),
          const Divider(height: 1),
          _StatusRow(
            label: 'Bluetooth enabled',
            value: switch (status.adapterEnabled) {
              true => 'On',
              false => 'Off — turn on manually in Android settings',
              null => 'Unknown',
            },
          ),
          const Divider(height: 1),
          _StatusRow(
            label: 'Advertiser available',
            value: boolLabel(status.advertiserAvailable),
          ),
          const Divider(height: 1),
          _StatusRow(
            label: 'Scanner available',
            value: boolLabel(status.scannerAvailable),
          ),
          const Divider(height: 1),
          _StatusRow(
            label: 'Android API level',
            value: status.apiLevel?.toString() ?? 'Unknown',
          ),
        ],
      ),
    );
  }
}

class _OperationCard extends StatelessWidget {
  const _OperationCard({
    required this.title,
    required this.state,
    required this.stateKey,
    required this.startKey,
    required this.stopKey,
    required this.onStart,
    required this.onStop,
    required this.canStart,
    required this.canStop,
    required this.actionInProgress,
    required this.label,
  });

  final String title;
  final BleDiscoveryOperationState state;
  final Key stateKey;
  final Key startKey;
  final Key stopKey;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final bool canStart;
  final bool canStop;
  final bool actionInProgress;
  final String Function(BleDiscoveryOperationState) label;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(label(state), key: stateKey),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: startKey,
                  onPressed: canStart && !actionInProgress ? onStart : null,
                  icon: const Icon(Icons.play_arrow),
                  label: Text('Start ${title.toLowerCase()}'),
                ),
                OutlinedButton.icon(
                  key: stopKey,
                  onPressed: canStop && !actionInProgress ? onStop : null,
                  icon: const Icon(Icons.stop),
                  label: Text('Stop ${title.toLowerCase()}'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscoveryResultsCard extends StatelessWidget {
  const _DiscoveryResultsCard({required this.status});

  final BleDiscoveryStatus status;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.radar),
        title: const Text('Matching devices seen this scan session'),
        subtitle: const Text('Unique results for the reserved service UUID only.'),
        trailing: Text(
          status.matchingDeviceCount.toString(),
          key: const Key('ble-discovery-results-count'),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
      ),
    );
  }
}

class _DiscoveryPermissionsCard extends StatelessWidget {
  const _DiscoveryPermissionsCard({required this.status});

  final BleDiscoveryStatus status;

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
                'Discovery permissions',
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
                _DiscoveryPermissionTile(permission: permission),
          ],
        ),
      ),
    );
  }
}

class _DiscoveryPermissionTile extends StatelessWidget {
  const _DiscoveryPermissionTile({required this.permission});

  final BleDiscoveryPermissionStatus permission;

  @override
  Widget build(BuildContext context) {
    final operationRequired = permission.requiredForScanning ||
        permission.requiredForAdvertising;
    final stateLabel = switch (permission.state) {
      BlePermissionState.granted => 'Granted',
      BlePermissionState.denied => !operationRequired
          ? 'Not required for G2-B discovery'
          : permission.canRequestAgain
              ? 'Not granted; start the operation to request it'
              : 'Denied; allow it in Android app settings',
      BlePermissionState.notRequired => 'Not required on this Android version',
    };
    final detail = switch (permission.name) {
      'android.permission.BLUETOOTH_SCAN' =>
        'Needed only when you start scanning; results are filtered to the DumanMessenger UUID.',
      'android.permission.BLUETOOTH_ADVERTISE' =>
        'Needed only when you start advertising the DumanMessenger UUID.',
      'android.permission.ACCESS_FINE_LOCATION' =>
        'Android 6–11 requires foreground location permission for BLE scanning. '
            'It is requested only when scanning starts; no location data is read.',
      'android.permission.BLUETOOTH_CONNECT' =>
        'Used by the separate G2-A adapter diagnostic; G2-B discovery does not request it.',
      _ => operationRequired
          ? 'Legacy Bluetooth permission required for foreground BLE discovery.'
          : 'Not required for foreground discovery.',
    };
    final type = permission.state == BlePermissionState.notRequired
        ? null
        : permission.isRuntime
            ? 'Runtime permission'
            : 'Normal permission';
    final subtitle = <String>[stateLabel, ?type, detail].join('. ');
    final name = switch (permission.name) {
      'android.permission.BLUETOOTH_SCAN' => 'Bluetooth scan',
      'android.permission.BLUETOOTH_ADVERTISE' => 'Bluetooth advertise',
      'android.permission.BLUETOOTH_CONNECT' => 'Bluetooth connect',
      'android.permission.ACCESS_FINE_LOCATION' =>
        'Fine location (Android 6–11 scan requirement)',
      'android.permission.BLUETOOTH' => 'Bluetooth (legacy)',
      'android.permission.BLUETOOTH_ADMIN' => 'Bluetooth admin (legacy)',
      _ => permission.name,
    };

    return ListTile(
      key: ValueKey<String>('ble-discovery-permission-${permission.name}'),
      dense: true,
      title: Text(name),
      subtitle: Text(subtitle),
      trailing: permission.shouldShowRationale
          ? const Tooltip(
              message: 'Android indicates that a permission rationale is appropriate.',
              child: Icon(Icons.info_outline),
            )
          : null,
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('ble-discovery-message'),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(message),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        ],
      ),
    );
  }
}
