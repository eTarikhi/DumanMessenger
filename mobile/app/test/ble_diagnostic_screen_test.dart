import 'dart:async';

import 'package:duman_messenger/ble/ble_diagnostic_bridge.dart';
import 'package:duman_messenger/ble/ble_diagnostic_status.dart';
import 'package:duman_messenger/screens/ble_diagnostic_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows prerequisite-only status and refreshes it', (tester) async {
    final api = _FakeBleDiagnosticApi(
      initialStatus: _status(BleDiagnosticState.ready),
      refreshStatus: _status(BleDiagnosticState.bleHardwareUnavailable),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(home: BleDiagnosticScreen(bridge: api)),
    );
    await tester.pumpAndSettle();

    expect(find.text('BLE diagnostic'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.textContaining('does not scan'), findsOneWidget);
    expect(find.textContaining('No adapter name, MAC address'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ble-refresh')));
    await tester.pumpAndSettle();

    expect(api.refreshCount, 2);
    expect(find.text('BLE unavailable'), findsOneWidget);
  });

  testWidgets('requests only a required permission when it can be requested',
      (tester) async {
    final api = _FakeBleDiagnosticApi(
      initialStatus: _status(
        BleDiagnosticState.permissionsDenied,
        connectPermissionCanRequestAgain: true,
      ),
      permissionRequestStatus: _status(BleDiagnosticState.bluetoothDisabled),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(home: BleDiagnosticScreen(bridge: api)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ble-request-permissions')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ble-request-permissions')));
    await tester.pumpAndSettle();

    expect(api.permissionRequestCount, 1);
    expect(find.text('Bluetooth is off'), findsOneWidget);
    expect(find.textContaining('Enable it manually'), findsOneWidget);
  });

  testWidgets('explains manual settings after a non-repeatable denial',
      (tester) async {
    final api = _FakeBleDiagnosticApi(
      initialStatus: _status(
        BleDiagnosticState.permissionsDenied,
        connectPermissionCanRequestAgain: false,
      ),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(home: BleDiagnosticScreen(bridge: api)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ble-manual-permission-guidance')),
        findsOneWidget);
    expect(find.byKey(const Key('ble-request-permissions')), findsNothing);
    expect(api.permissionRequestCount, 0);
  });

  testWidgets('reports legacy fine location without requesting it',
      (tester) async {
    final api = _FakeBleDiagnosticApi(
      initialStatus: _status(
        BleDiagnosticState.ready,
        apiLevel: 30,
        additionalPermissions: <BlePermissionStatus>[
          BlePermissionStatus(
            name: 'android.permission.ACCESS_FINE_LOCATION',
            state: BlePermissionState.denied,
            requiredForDiagnostics: false,
            isRuntime: true,
            canRequestAgain: false,
            shouldShowRationale: false,
          ),
        ],
      ),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(home: BleDiagnosticScreen(bridge: api)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Location (fine, legacy)'), findsOneWidget);
    expect(
      find.textContaining('Not granted (not requested by G2-A)'),
      findsOneWidget,
    );
    expect(
      find.textContaining('G2-A does not request or use location.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('ble-request-permissions')), findsNothing);
    expect(api.permissionRequestCount, 0);
  });

  testWidgets('cancels the native status stream when disposed', (tester) async {
    final api = _FakeBleDiagnosticApi(
      initialStatus: _status(BleDiagnosticState.ready),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(home: BleDiagnosticScreen(bridge: api)),
    );
    await tester.pumpAndSettle();
    expect(api.streamCancelled, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(api.streamCancelled, isTrue);
  });
}

BleDiagnosticStatus _status(
  BleDiagnosticState state, {
  bool connectPermissionCanRequestAgain = false,
  int apiLevel = 35,
  List<BlePermissionStatus> additionalPermissions =
      const <BlePermissionStatus>[],
}) {
  final permissionDenied = state == BleDiagnosticState.permissionsDenied;
  return BleDiagnosticStatus(
    state: state,
    apiLevel: apiLevel,
    bleHardwareSupported: true,
    bluetoothManagerAvailable: true,
    adapterAvailable: true,
    bluetoothEnabled: switch (state) {
      BleDiagnosticState.ready => true,
      BleDiagnosticState.bluetoothDisabled => false,
      _ => null,
    },
    permissions: <BlePermissionStatus>[
      if (apiLevel >= 31)
        BlePermissionStatus(
          name: 'android.permission.BLUETOOTH_CONNECT',
          state: permissionDenied
              ? BlePermissionState.denied
              : BlePermissionState.granted,
          requiredForDiagnostics: true,
          isRuntime: true,
          canRequestAgain: connectPermissionCanRequestAgain,
          shouldShowRationale: connectPermissionCanRequestAgain,
        )
      else ...<BlePermissionStatus>[
        BlePermissionStatus(
          name: 'android.permission.BLUETOOTH',
          state: BlePermissionState.granted,
          requiredForDiagnostics: true,
          isRuntime: false,
          canRequestAgain: false,
          shouldShowRationale: false,
        ),
        BlePermissionStatus(
          name: 'android.permission.BLUETOOTH_ADMIN',
          state: BlePermissionState.granted,
          requiredForDiagnostics: true,
          isRuntime: false,
          canRequestAgain: false,
          shouldShowRationale: false,
        ),
      ],
      ...additionalPermissions,
    ],
    advertisingCapability: BleAdvertisingCapability.unknown,
    reason: switch (state) {
      BleDiagnosticState.ready =>
        'Prerequisites are satisfied; no BLE radio operation was performed.',
      BleDiagnosticState.bleHardwareUnavailable =>
        'This device does not report BLE hardware support.',
      BleDiagnosticState.permissionsDenied =>
        'Bluetooth Connect permission is needed to read adapter state.',
      BleDiagnosticState.bluetoothDisabled =>
        'Bluetooth is off. Enable it manually in Android system settings.',
      BleDiagnosticState.unsupportedPlatform =>
        'BLE diagnostics are available on Android only.',
      BleDiagnosticState.nativeServiceUnavailable =>
        'The Android diagnostic service is unavailable.',
      BleDiagnosticState.error => 'The BLE diagnostic status could not be read.',
    },
  );
}

class _FakeBleDiagnosticApi implements BleDiagnosticApi {
  _FakeBleDiagnosticApi({
    required this.initialStatus,
    BleDiagnosticStatus? refreshStatus,
    BleDiagnosticStatus? permissionRequestStatus,
  })  : refreshStatus = refreshStatus ?? initialStatus,
        permissionRequestStatus = permissionRequestStatus ?? initialStatus {
    _statusController = StreamController<BleDiagnosticStatus>.broadcast(
      onCancel: () => streamCancelled = true,
    );
  }

  final BleDiagnosticStatus initialStatus;
  late final StreamController<BleDiagnosticStatus> _statusController;
  BleDiagnosticStatus refreshStatus;
  BleDiagnosticStatus permissionRequestStatus;
  int refreshCount = 0;
  int permissionRequestCount = 0;
  bool streamCancelled = false;

  @override
  Future<BleDiagnosticStatus> refresh() async {
    refreshCount += 1;
    return refreshCount == 1 ? initialStatus : refreshStatus;
  }

  @override
  Future<BleDiagnosticStatus> requestRequiredPermissions() async {
    permissionRequestCount += 1;
    return permissionRequestStatus;
  }

  @override
  Stream<BleDiagnosticStatus> watchStatus() => _statusController.stream;

  Future<void> close() => _statusController.close();
}
