import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../ble/g2c_ble_bridge.dart';
import '../ble/g2c_ble_status.dart';
import '../widgets/app_page_body.dart';

/// Android G2-C transport controls. This screen never establishes trust or security.
class G2cBleScreen extends StatefulWidget {
  const G2cBleScreen({super.key, this.bridge});

  final G2cBleApi? bridge;

  @override
  State<G2cBleScreen> createState() => _G2cBleScreenState();
}

class _G2cBleScreenState extends State<G2cBleScreen> with WidgetsBindingObserver {
  late final G2cBleApi _bridge = widget.bridge ?? G2cBleBridge();
  late final StreamSubscription<G2cBleStatus> _subscription;
  final TextEditingController _testPayload = TextEditingController();
  G2cBleStatus _status = const G2cBleStatus(
    state: G2cLinkState.disconnected,
    authenticated: false,
    testOnly: true,
  );
  bool _loading = true;
  bool _busy = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = _bridge.watchStatus().listen(
      _accept,
      onError: (Object _) => _accept(G2cBleStatus.unavailable(
        G2cLinkState.channelUnavailable,
        'native_service_unavailable',
      )),
    );
    unawaited(_refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      if (_status.permissionState != G2cRuntimePermissionState.requesting) {
        unawaited(_stopForLifecycle());
      }
    } else if (state == AppLifecycleState.resumed) {
      // Refresh actual native state; never restart a scan, server, or connection automatically.
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _testPayload.dispose();
    unawaited(_subscription.cancel());
    // Native EventChannel cancellation also cleans up, but issue explicit teardown as defense in depth.
    unawaited(_disconnectForDispose());
    super.dispose();
  }

  void _accept(G2cBleStatus value) {
    if (!mounted || _disposed) return;
    setState(() {
      _status = value;
      _loading = false;
    });
  }

  Future<void> _refresh() async {
    G2cBleStatus value;
    try {
      value = await _bridge.refresh();
    } catch (_) {
      value = G2cBleStatus.unavailable(
        G2cLinkState.channelUnavailable,
        'native_service_unavailable',
      );
    }
    if (!mounted || _disposed) return;
    setState(() {
      _status = value;
      _loading = false;
    });
  }

  Future<void> _disconnectForDispose() async {
    try {
      await _bridge.disconnect();
    } catch (_) {
      // EventChannel cancellation and native Activity teardown remain the cleanup fallback.
    }
  }

  Future<void> _stopForLifecycle() async {
    try {
      final value = await _bridge.disconnect();
      if (mounted && !_disposed) setState(() => _status = value);
    } catch (_) {
      // The native Activity also tears down G2-C on pause. Do not claim a live state here.
      if (mounted && !_disposed) {
        setState(() => _status = G2cBleStatus.unavailable(
          G2cLinkState.channelUnavailable,
          'lifecycle_cleanup_unavailable',
        ));
      }
    }
  }

  Future<void> _operation(Future<G2cBleStatus> Function() action) async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    try {
      _accept(await action());
    } catch (_) {
      _accept(G2cBleStatus.unavailable(
        G2cLinkState.connectionFailed,
        'native_operation_failed',
      ));
    } finally {
      if (mounted && !_disposed) setState(() => _busy = false);
    }
  }

  Future<void> _permissionGatedAction({
    required String title,
    required String explanation,
    required bool permissionMissing,
    required List<String> permissionNames,
    required Future<G2cBleStatus> Function() action,
  }) async {
    final thisOperationWasPermanentlyDenied = _status.permissionPermanentlyDenied &&
        _status.permissionNames.any(permissionNames.contains);
    if (thisOperationWasPermanentlyDenied && permissionMissing) {
      final openSettings = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Permission blocked'),
          content: Text(
            'Android no longer offers the requested permission. Open app settings '
            'to grant ${_status.permissionNames.join(', ')}, then return and retry. '
            'G2-C will not start the operation without permission.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
      if (!mounted || openSettings != true) return;
      await _operation(_bridge.openPermissionSettings);
      return;
    }

    if (permissionMissing) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(explanation),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (!mounted || proceed != true) return;
    }
    await _operation(action);
  }

  bool get _scanPermissionMissing => _status.scanPermissionGranted == false;
  List<String> get _scanPermissionNames => [
        (_status.apiLevel ?? 31) >= 31
            ? 'android.permission.BLUETOOTH_SCAN'
            : 'android.permission.ACCESS_FINE_LOCATION',
      ];
  List<String> get _connectPermissionNames => const [
        'android.permission.BLUETOOTH_CONNECT',
      ];
  List<String> get _serverPermissionNames => const [
        'android.permission.BLUETOOTH_CONNECT',
        'android.permission.BLUETOOTH_ADVERTISE',
      ];
  bool get _connectPermissionMissing => _status.connectPermissionGranted == false;
  bool get _serverPermissionMissing =>
      _connectPermissionMissing || _status.advertisePermissionGranted == false;

  String get _permissionExplanation {
    if ((_status.apiLevel ?? 31) <= 30) {
      return 'Android 8.1–11 requires foreground location permission for BLE scanning. '
          'G2-C uses it only for nearby BLE discovery; it does not read or store location. '
          'The app requests it only when you start scanning.';
    }
    return 'Android 12+ separates Bluetooth Scan, Connect, and Advertise permissions. '
        'G2-C requests only the permission needed for the action you selected. Denial stops '
        'that operation; discovery never grants peer trust.';
  }

  String _linkLabel(G2cLinkState state) => switch (state) {
        G2cLinkState.disconnected => 'Disconnected',
        G2cLinkState.discovered => 'Candidate discovered (not trusted)',
        G2cLinkState.connecting => 'Connecting',
        G2cLinkState.connectedUnauthenticated => 'Connected — unauthenticated',
        G2cLinkState.serviceReady => 'GATT service ready — unauthenticated',
        G2cLinkState.authenticating => 'Authentication unavailable in this build',
        G2cLinkState.authenticated => 'Invalid state: authenticated status is disabled',
        G2cLinkState.disconnecting => 'Disconnecting',
        G2cLinkState.connectionFailed => 'Connection failed',
        G2cLinkState.permissionDenied => 'Permission denied',
        G2cLinkState.timedOut => 'Timed out',
        G2cLinkState.protocolError => 'Protocol/frame error',
        G2cLinkState.unsupported => 'Unsupported on this device/platform',
        G2cLinkState.channelUnavailable => 'Native BLE service unavailable',
      };

  String _discoveryLabel(G2cDiscoveryState state) => switch (state) {
        G2cDiscoveryState.idle => 'Stopped',
        G2cDiscoveryState.scanning => 'Scanning in foreground',
        G2cDiscoveryState.results => 'Candidates available',
        G2cDiscoveryState.permissionDenied => 'Permission required',
        G2cDiscoveryState.timedOut => 'Scan timed out',
        G2cDiscoveryState.unsupported => 'Discovery unsupported',
        G2cDiscoveryState.failed => 'Discovery failed',
      };

  @override
  Widget build(BuildContext context) {
    final canAct = !_loading && !_busy && _status.bleHardwareSupported != false;
    final canSend = canAct && _status.state == G2cLinkState.serviceReady;
    return Scaffold(
      appBar: AppBar(title: const Text('G2-C BLE — TEST ONLY')),
      body: AppPageBody(
        child: ListView(
          children: [
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'TEST ONLY. A BLE connection or ready GATT service is NOT authenticated, '
                  'trusted, encrypted end-to-end, or connected to production messaging. '
                  'No G2-C handshake is implemented.',
                ),
              ),
            ),
            const SizedBox(height: 12),
            _section('Capability and permissions', [
              _row('Platform API', _status.apiLevel?.toString() ?? 'Unknown'),
              _row('BLE hardware', _boolLabel(_status.bleHardwareSupported)),
              _row('Bluetooth radio', _radioLabel(_status.bluetoothEnabled)),
              _row('Scan permission', _boolLabel(_status.scanPermissionGranted)),
              _row('Connect permission', _boolLabel(_status.connectPermissionGranted)),
              _row('Advertise permission', _boolLabel(_status.advertisePermissionGranted)),
              _row('Permission request', _permissionLabel(_status.permissionState)),
              if (_status.permissionNames.isNotEmpty)
                _row('Last requested', _status.permissionNames.join(', ')),
              if (_status.permissionErrorCode != null)
                _error(_status.permissionErrorCode!),
              if (_status.permissionPermanentlyDenied)
                const Text('Permission is blocked. Use app settings, then return and retry.'),
            ]),
            const SizedBox(height: 12),
            _section('Discovery', [
              _row('Discovery state', _discoveryLabel(_status.discoveryState)),
              if (_status.discoveryErrorCode != null) _error(_status.discoveryErrorCode!),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.tonal(
                  onPressed: canAct &&
                          _status.discoveryState != G2cDiscoveryState.scanning
                      ? () => _permissionGatedAction(
                            title: 'Allow BLE discovery',
                            explanation: _permissionExplanation,
                            permissionMissing: _scanPermissionMissing,
                            permissionNames: _scanPermissionNames,
                            action: _bridge.startDiscovery,
                          )
                      : null,
                  child: const Text('Start discovery'),
                ),
                OutlinedButton(
                  onPressed: canAct &&
                          _status.discoveryState != G2cDiscoveryState.idle
                      ? () => _operation(_bridge.stopDiscovery)
                      : null,
                  child: const Text('Stop discovery'),
                ),
              ]),
              if (_status.discoveredPeerIds.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('No candidates currently discovered.'),
                )
              else
                ..._status.discoveredPeerIds.asMap().entries.map((entry) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.bluetooth_searching),
                      title: Text('Temporary candidate ${entry.key + 1}'),
                      subtitle: const Text('Opaque scan token — identity not verified or trusted'),
                      trailing: TextButton(
                        onPressed: canAct
                            ? () => _permissionGatedAction(
                                  title: 'Connect to selected candidate',
                                  explanation: 'Android may request Bluetooth Connect permission. '
                                      'This opens a GATT transport only; it does not authenticate '
                                      'or trust the peer.',
                                  permissionMissing: _connectPermissionMissing,
                                  permissionNames: _connectPermissionNames,
                                  action: () => _bridge.connect(entry.value),
                                )
                            : null,
                        child: const Text('Connect'),
                      ),
                    )),
            ]),
            const SizedBox(height: 12),
            _section('Connection and GATT server', [
              _row('Link state', _linkLabel(_status.state)),
              _row('Authenticated', 'No — protocol not implemented'),
              _row('Trusted peer', 'No — trust ceremony/storage not implemented'),
              _row('GATT server', _status.serverRunning ? 'Running (test-only)' : 'Stopped'),
              if (_status.errorCode != null) _error(_status.errorCode!),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.tonal(
                  onPressed: canAct && !_status.serverRunning
                      ? () => _permissionGatedAction(
                            title: 'Start G2-C GATT server',
                            explanation: 'Android may request Bluetooth Connect and Advertise '
                                'permissions. This explicitly starts a foreground TEST-ONLY GATT '
                                'service; advertised presence does not establish identity or trust.',
                            permissionMissing: _serverPermissionMissing,
                            permissionNames: _serverPermissionNames,
                            action: _bridge.startServer,
                          )
                      : null,
                  child: const Text('Start server'),
                ),
                OutlinedButton(
                  onPressed: canAct && _status.serverRunning
                      ? () => _operation(_bridge.stopServer)
                      : null,
                  child: const Text('Stop server'),
                ),
                OutlinedButton(
                  onPressed: canAct && _status.state != G2cLinkState.disconnected
                      ? () => _operation(_bridge.disconnect)
                      : null,
                  child: const Text('Disconnect'),
                ),
              ]),
            ]),
            const SizedBox(height: 12),
            _section('Test frame (unauthenticated)', [
              const Text(
                'Optional raw test bytes only. They are not encrypted or authenticated and are '
                'discarded by the native test transport; they are never sent as Duman messages.',
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _testPayload,
                maxLength: 512,
                decoration: const InputDecoration(
                  labelText: 'Test text payload (max 512 UTF-8 bytes)',
                  border: OutlineInputBorder(),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: canSend ? _sendTestFrame : null,
                  child: const Text('Send test frame'),
                ),
              ),
              if (_status.operationError != null) _error(_status.operationError!),
            ]),
          ],
        ),
      ),
    );
  }

  Future<void> _sendTestFrame() async {
    final bytes = utf8.encode(_testPayload.text);
    if (bytes.length > 512) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('UTF-8 test payload exceeds the 512-byte limit.')),
      );
      return;
    }
    await _operation(() => _bridge.sendTestFrame(1, bytes));
  }

  Widget _section(String title, List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        ),
      );

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(label)),
            const SizedBox(width: 12),
            Flexible(child: Text(value, textAlign: TextAlign.end)),
          ],
        ),
      );

  Widget _error(String code) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text('Error: $code', style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );

  String _boolLabel(bool? value) => switch (value) {
        true => 'Granted / available',
        false => 'Missing / unavailable',
        null => 'Unknown',
      };

  String _radioLabel(bool? value) => switch (value) {
        true => 'Enabled',
        false => 'Disabled / unavailable',
        null => 'Unknown (CONNECT permission required to inspect)',
      };

  String _permissionLabel(G2cRuntimePermissionState state) => switch (state) {
        G2cRuntimePermissionState.notRequired => 'Not required / not requested',
        G2cRuntimePermissionState.granted => 'Granted',
        G2cRuntimePermissionState.requesting => 'Awaiting Android response',
        G2cRuntimePermissionState.requestable => 'Denied; request may be retried',
        G2cRuntimePermissionState.permanentlyDenied => 'Blocked; app settings required',
      };
}
