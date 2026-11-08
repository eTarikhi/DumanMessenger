import 'dart:async';

import 'package:duman_messenger/ble/ble_discovery_bridge.dart';
import 'package:duman_messenger/ble/ble_discovery_status.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _methodChannel = MethodChannel(bleDiscoveryMethodChannelName);
const _eventChannel = EventChannel(bleDiscoveryEventChannelName);

Map<String, Object?> _snapshot({
  String advertisingState = 'idle',
  String scanningState = 'idle',
  int resultCount = 0,
}) => <String, Object?>{
      'apiLevel': 35,
      'bleHardwareSupported': true,
      'adapterAvailable': true,
      'adapterEnabled': true,
      'advertiserAvailable': true,
      'scannerAvailable': true,
      'advertisingState': advertisingState,
      'scanningState': scanningState,
      'permissions': <Object?>[
        <String, Object?>{
          'name': 'android.permission.BLUETOOTH_SCAN',
          'state': 'granted',
          'requiredForScanning': true,
          'requiredForAdvertising': false,
          'runtime': true,
          'canRequestAgain': false,
          'shouldShowRationale': false,
        },
      ],
      'results': List<Object?>.generate(
        resultCount,
        (index) => <String, Object?>{'sessionId': 'result-${index + 1}'},
      ),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(_methodChannel, null);
    messenger.setMockStreamHandler(_eventChannel, null);
  });

  test('explicit operations use the discovery method channel', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(_methodChannel, (call) async {
      calls.add(call.method);
      return _snapshot(
        advertisingState: call.method == 'startAdvertising' ? 'starting' : 'idle',
        scanningState: call.method == 'startScanning' ? 'active' : 'idle',
      );
    });
    final bridge = BleDiscoveryBridge(
      methodChannel: _methodChannel,
      eventChannel: _eventChannel,
      isAndroid: true,
    );

    final initial = await bridge.refresh();
    final advertising = await bridge.startAdvertising();
    final stopAdvertising = await bridge.stopAdvertising();
    final scanning = await bridge.startScanning();
    final stopScanning = await bridge.stopScanning();
    await bridge.stopAll();

    expect(calls, <String>[
      'getStatus',
      'startAdvertising',
      'stopAdvertising',
      'startScanning',
      'stopScanning',
      'stopAll',
    ]);
    expect(initial.advertisingState, BleDiscoveryOperationState.idle);
    expect(advertising.advertisingState, BleDiscoveryOperationState.starting);
    expect(stopAdvertising.advertisingState, BleDiscoveryOperationState.idle);
    expect(scanning.scanningState, BleDiscoveryOperationState.active);
    expect(stopScanning.scanningState, BleDiscoveryOperationState.idle);
  });

  test('method-channel failures become a typed service error', () async {
    messenger.setMockMethodCallHandler(_methodChannel, (call) async {
      throw PlatformException(code: 'native_failure');
    });
    final bridge = BleDiscoveryBridge(
      methodChannel: _methodChannel,
      eventChannel: _eventChannel,
      isAndroid: true,
    );

    final status = await bridge.startScanning();

    expect(status.errorCode, 'native_service_unavailable');
    expect(status.scanningState, BleDiscoveryOperationState.failed);
  });

  test('event-channel snapshots are typed and cancellation reaches native',
      () async {
    var cancelled = false;
    messenger.setMockStreamHandler(
      _eventChannel,
      MockStreamHandler.inline(
        onListen: (_, events) => events.success(
          _snapshot(scanningState: 'active', resultCount: 2),
        ),
        onCancel: (_) {
          cancelled = true;
        },
      ),
    );
    final bridge = BleDiscoveryBridge(
      methodChannel: _methodChannel,
      eventChannel: _eventChannel,
      isAndroid: true,
    );
    final received = Completer<BleDiscoveryStatus>();
    final subscription = bridge.watchStatus().listen((status) {
      received.complete(status);
    });
    final status = await received.future;

    expect(status.scanningState, BleDiscoveryOperationState.active);
    expect(status.matchingDeviceCount, 2);
    await subscription.cancel();
    expect(cancelled, isTrue);
  });

  test('non-Android platforms do not call native channels', () async {
    final bridge = BleDiscoveryBridge(
      methodChannel: _methodChannel,
      eventChannel: _eventChannel,
      isAndroid: false,
    );

    expect(
      (await bridge.startAdvertising()).errorCode,
      'unsupported_platform',
    );
    expect(
      (await bridge.startScanning()).errorCode,
      'unsupported_platform',
    );
    expect(
      (await bridge.watchStatus().first).advertisingState,
      BleDiscoveryOperationState.unsupported,
    );
  });
}
