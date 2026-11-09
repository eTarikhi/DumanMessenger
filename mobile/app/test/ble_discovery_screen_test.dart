import 'dart:async';

import 'package:duman_messenger/ble/ble_diagnostic_status.dart';
import 'package:duman_messenger/ble/ble_discovery_bridge.dart';
import 'package:duman_messenger/ble/ble_discovery_status.dart';
import 'package:duman_messenger/screens/ble_discovery_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows explicit controls and only a temporary result count',
      (tester) async {
    final api = _FakeBleDiscoveryApi(
      _status(results: const <BleDiscoveryResult>[
        BleDiscoveryResult(sessionId: 'opaque-session-1'),
      ]),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(home: BleDiscoveryScreen(bridge: api)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Foreground BLE discovery'), findsOneWidget);
    expect(find.byKey(const Key('ble-discovery-results-count')), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('opaque-session-1'), findsNothing);
    expect(find.text('Start scanning'), findsOneWidget);
    expect(find.text('Stop scanning'), findsOneWidget);
    expect(api.startScanningCount, 0);
    expect(api.startAdvertisingCount, 0);
  });

  testWidgets('shows unavailable hardware and disables radio operations',
      (tester) async {
    final api = _FakeBleDiscoveryApi(
      _status(
        bleHardwareSupported: false,
        advertiserAvailable: false,
        scannerAvailable: false,
      ),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(home: BleDiscoveryScreen(bridge: api)),
    );
    await tester.pumpAndSettle();

    expect(find.text('BLE hardware'), findsOneWidget);
    expect(find.text('Unavailable'), findsNWidgets(3));
    expect(
      tester.widget<FilledButton>(
        find.byKey(const Key('ble-discovery-start-advertising')),
      ).onPressed,
      isNull,
    );
    expect(
      tester.widget<FilledButton>(
        find.byKey(const Key('ble-discovery-start-scanning')),
      ).onPressed,
      isNull,
    );
    expect(api.startAdvertisingCount, 0);
    expect(api.startScanningCount, 0);
  });

  testWidgets('does not require Android 12+ Connect permission for discovery',
      (tester) async {
    final api = _FakeBleDiscoveryApi(_status());
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(home: BleDiscoveryScreen(bridge: api)),
    );
    await tester.pumpAndSettle();

    final startButton = tester.widget<FilledButton>(
      find.byKey(const Key('ble-discovery-start-scanning')),
    );
    expect(startButton.onPressed, isNotNull);
    expect(
      find.text('Not required for G2-B discovery. Runtime permission. '
          'Used by the separate G2-A adapter diagnostic; G2-B discovery does not request it.'),
      findsOneWidget,
    );
    expect(api.startScanningCount, 0);
  });

  testWidgets('explains legacy scan permission before starting the scan',
      (tester) async {
    final api = _FakeBleDiscoveryApi(
      _status(
        apiLevel: 30,
        permissions: const <BleDiscoveryPermissionStatus>[
          BleDiscoveryPermissionStatus(
            name: 'android.permission.ACCESS_FINE_LOCATION',
            state: BlePermissionState.denied,
            requiredForScanning: true,
            requiredForAdvertising: false,
            isRuntime: true,
            canRequestAgain: true,
            shouldShowRationale: true,
          ),
          BleDiscoveryPermissionStatus(
            name: 'android.permission.BLUETOOTH',
            state: BlePermissionState.granted,
            requiredForScanning: true,
            requiredForAdvertising: true,
            isRuntime: false,
            canRequestAgain: false,
            shouldShowRationale: false,
          ),
          BleDiscoveryPermissionStatus(
            name: 'android.permission.BLUETOOTH_ADMIN',
            state: BlePermissionState.granted,
            requiredForScanning: true,
            requiredForAdvertising: true,
            isRuntime: false,
            canRequestAgain: false,
            shouldShowRationale: false,
          ),
        ],
      ),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(home: BleDiscoveryScreen(bridge: api)),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('ble-discovery-start-scanning')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ble-discovery-start-scanning')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('ble-discovery-legacy-location-rationale')),
      findsOneWidget,
    );
    expect(
      find.textContaining('Android 6–11 requires foreground location permission'),
      findsNWidgets(2),
    );
    expect(api.startScanningCount, 0);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(api.startScanningCount, 1);
    expect(api.startAdvertisingCount, 0);
  });

  testWidgets('explains legacy scan location requirement and blocks a '
      'non-repeatable denial', (tester) async {
    final api = _FakeBleDiscoveryApi(
      _status(
        apiLevel: 30,
        permissions: const <BleDiscoveryPermissionStatus>[
          BleDiscoveryPermissionStatus(
            name: 'android.permission.ACCESS_FINE_LOCATION',
            state: BlePermissionState.denied,
            requiredForScanning: true,
            requiredForAdvertising: false,
            isRuntime: true,
            canRequestAgain: false,
            shouldShowRationale: false,
          ),
          BleDiscoveryPermissionStatus(
            name: 'android.permission.BLUETOOTH',
            state: BlePermissionState.granted,
            requiredForScanning: true,
            requiredForAdvertising: true,
            isRuntime: false,
            canRequestAgain: false,
            shouldShowRationale: false,
          ),
          BleDiscoveryPermissionStatus(
            name: 'android.permission.BLUETOOTH_ADMIN',
            state: BlePermissionState.granted,
            requiredForScanning: true,
            requiredForAdvertising: true,
            isRuntime: false,
            canRequestAgain: false,
            shouldShowRationale: false,
          ),
        ],
      ),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(home: BleDiscoveryScreen(bridge: api)),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Android 6–11 requires foreground location permission'),
      findsOneWidget,
    );
    expect(
      find.textContaining('no location data is read'),
      findsOneWidget,
    );
    expect(
      tester.widget<FilledButton>(
        find.byKey(const Key('ble-discovery-start-scanning')),
      ).onPressed,
      isNull,
    );
    expect(api.startScanningCount, 0);
  });

  testWidgets('starts scanning only after the user presses Start',
      (tester) async {
    final api = _FakeBleDiscoveryApi(_status());
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(home: BleDiscoveryScreen(bridge: api)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const Key('ble-discovery-start-scanning')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ble-discovery-start-scanning')));
    await tester.pumpAndSettle();

    expect(api.startScanningCount, 1);
    expect(api.startAdvertisingCount, 0);
    expect(find.text('Running in the foreground'), findsOneWidget);
    expect(find.byKey(const Key('ble-discovery-stop-scanning')), findsOneWidget);
  });

  testWidgets(
    'stops and clears results when app leaves the foreground and resumes safely',
    (tester) async {
      final activeStatus = _status(
        advertisingState: BleDiscoveryOperationState.active,
        scanningState: BleDiscoveryOperationState.active,
        results: const <BleDiscoveryResult>[
          BleDiscoveryResult(sessionId: 'temporary-result'),
        ],
      );
      final api = _FakeBleDiscoveryApi(activeStatus);
      final staleRefresh = Completer<BleDiscoveryStatus>();
      api.refreshResponse = staleRefresh.future;
      api.stopAllResponse = Completer<BleDiscoveryStatus>();
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(home: BleDiscoveryScreen(bridge: api)),
      );
      // Keep the initial status read pending while the app leaves the
      // foreground.
      await tester.pump();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await api.stopAllStarted.future;
      api.stopAllResponse!.complete(api.status);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(api.stopAllCount, 1);
      expect(api.status.advertisingState, BleDiscoveryOperationState.idle);
      expect(api.status.scanningState, BleDiscoveryOperationState.idle);
      expect(api.status.matchingDeviceCount, 0);

      final countFinder = find.byKey(const Key('ble-discovery-results-count'));
      await tester.ensureVisible(countFinder);
      await tester.pump();
      expect(tester.widget<Text>(countFinder).data, '0');
      expect(find.text('0'), findsOneWidget);

      // A pre-pause getStatus reply must not repopulate the cleared UI.
      api.refreshResponse = null;
      staleRefresh.complete(activeStatus);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(countFinder).data, '0');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(api.status.advertisingState, BleDiscoveryOperationState.idle);
      expect(api.status.scanningState, BleDiscoveryOperationState.idle);
      expect(api.startAdvertisingCount, 0);
      expect(api.startScanningCount, 0);
      expect(tester.widget<Text>(countFinder).data, '0');
    },
  );

  testWidgets('cancels the status stream and stops discovery when disposed',
      (tester) async {
    final api = _FakeBleDiscoveryApi(
      _status(
        scanningState: BleDiscoveryOperationState.active,
        results: const <BleDiscoveryResult>[
          BleDiscoveryResult(sessionId: 'temporary-result'),
        ],
      ),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(home: BleDiscoveryScreen(bridge: api)),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(api.stopAllCount, 1);
    expect(api.streamCancelled, isTrue);
    expect(api.status.matchingDeviceCount, 0);
  });
}

BleDiscoveryStatus _status({
  int apiLevel = 35,
  bool bleHardwareSupported = true,
  bool? adapterAvailable = true,
  bool? adapterEnabled = true,
  bool? advertiserAvailable = true,
  bool? scannerAvailable = true,
  BleDiscoveryOperationState advertisingState = BleDiscoveryOperationState.idle,
  BleDiscoveryOperationState scanningState = BleDiscoveryOperationState.idle,
  List<BleDiscoveryResult> results = const <BleDiscoveryResult>[],
  List<BleDiscoveryPermissionStatus>? permissions,
}) =>
    BleDiscoveryStatus(
      apiLevel: apiLevel,
      bleHardwareSupported: bleHardwareSupported,
      adapterAvailable: adapterAvailable,
      adapterEnabled: adapterEnabled,
      advertiserAvailable: advertiserAvailable,
      scannerAvailable: scannerAvailable,
      advertisingState: advertisingState,
      scanningState: scanningState,
      permissions: permissions ?? const <BleDiscoveryPermissionStatus>[
        BleDiscoveryPermissionStatus(
          name: 'android.permission.BLUETOOTH_SCAN',
          state: BlePermissionState.granted,
          requiredForScanning: true,
          requiredForAdvertising: false,
          isRuntime: true,
          canRequestAgain: false,
          shouldShowRationale: false,
        ),
        BleDiscoveryPermissionStatus(
          name: 'android.permission.BLUETOOTH_ADVERTISE',
          state: BlePermissionState.granted,
          requiredForScanning: false,
          requiredForAdvertising: true,
          isRuntime: true,
          canRequestAgain: false,
          shouldShowRationale: false,
        ),
        BleDiscoveryPermissionStatus(
          name: 'android.permission.BLUETOOTH_CONNECT',
          state: BlePermissionState.denied,
          requiredForScanning: false,
          requiredForAdvertising: false,
          isRuntime: true,
          canRequestAgain: false,
          shouldShowRationale: false,
        ),
        BleDiscoveryPermissionStatus(
          name: 'android.permission.ACCESS_FINE_LOCATION',
          state: BlePermissionState.notRequired,
          requiredForScanning: false,
          requiredForAdvertising: false,
          isRuntime: false,
          canRequestAgain: false,
          shouldShowRationale: false,
        ),
      ],
      results: results,
    );

class _FakeBleDiscoveryApi implements BleDiscoveryApi {
  _FakeBleDiscoveryApi(this.status) {
    _statusController = StreamController<BleDiscoveryStatus>.broadcast(
      onCancel: () => streamCancelled = true,
    );
  }

  BleDiscoveryStatus status;
  late final StreamController<BleDiscoveryStatus> _statusController;
  int startAdvertisingCount = 0;
  int startScanningCount = 0;
  int stopAllCount = 0;
  bool streamCancelled = false;
  Future<BleDiscoveryStatus>? refreshResponse;
  Completer<BleDiscoveryStatus>? stopAllResponse;
  final Completer<void> stopAllStarted = Completer<void>();

  @override
  Future<BleDiscoveryStatus> refresh() =>
      refreshResponse ?? Future<BleDiscoveryStatus>.value(status);

  @override
  Future<BleDiscoveryStatus> startAdvertising() async {
    startAdvertisingCount++;
    status = _copyStatus(advertisingState: BleDiscoveryOperationState.active);
    _publish();
    return status;
  }

  @override
  Future<BleDiscoveryStatus> stopAdvertising() async {
    status = _copyStatus(advertisingState: BleDiscoveryOperationState.idle);
    _publish();
    return status;
  }

  @override
  Future<BleDiscoveryStatus> startScanning() async {
    startScanningCount++;
    status = _copyStatus(scanningState: BleDiscoveryOperationState.active);
    _publish();
    return status;
  }

  @override
  Future<BleDiscoveryStatus> stopScanning() async {
    status = _copyStatus(scanningState: BleDiscoveryOperationState.idle);
    _publish();
    return status;
  }

  @override
  Future<BleDiscoveryStatus> stopAll() {
    stopAllCount++;
    status = _copyStatus(
      advertisingState: BleDiscoveryOperationState.idle,
      scanningState: BleDiscoveryOperationState.idle,
      results: const <BleDiscoveryResult>[],
    );
    _publish();
    if (!stopAllStarted.isCompleted) stopAllStarted.complete();
    return stopAllResponse?.future ?? Future<BleDiscoveryStatus>.value(status);
  }

  @override
  Stream<BleDiscoveryStatus> watchStatus() => _statusController.stream;

  BleDiscoveryStatus _copyStatus({
    BleDiscoveryOperationState? advertisingState,
    BleDiscoveryOperationState? scanningState,
    List<BleDiscoveryResult>? results,
  }) =>
      BleDiscoveryStatus(
        apiLevel: status.apiLevel,
        bleHardwareSupported: status.bleHardwareSupported,
        adapterAvailable: status.adapterAvailable,
        adapterEnabled: status.adapterEnabled,
        advertiserAvailable: status.advertiserAvailable,
        scannerAvailable: status.scannerAvailable,
        advertisingState: advertisingState ?? status.advertisingState,
        scanningState: scanningState ?? status.scanningState,
        permissions: status.permissions,
        results: results ?? status.results,
        errorCode: status.errorCode,
        message: status.message,
      );

  void _publish() {
    if (!_statusController.isClosed) _statusController.add(status);
  }

  Future<void> close() => _statusController.close();
}
