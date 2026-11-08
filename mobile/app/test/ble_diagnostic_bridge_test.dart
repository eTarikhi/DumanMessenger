import 'package:duman_messenger/ble/ble_diagnostic_bridge.dart';
import 'package:duman_messenger/ble/ble_diagnostic_status.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _methodChannel = MethodChannel(bleDiagnosticMethodChannelName);
const _eventChannel = EventChannel(bleDiagnosticEventChannelName);

Map<String, Object?> _readyStatus() => <String, Object?>{
      'state': 'ready',
      'apiLevel': 35,
      'bleHardwareSupported': true,
      'bluetoothManagerAvailable': true,
      'adapterAvailable': true,
      'bluetoothEnabled': true,
      'permissions': <Object?>[
        <String, Object?>{
          'name': 'android.permission.BLUETOOTH_CONNECT',
          'state': 'granted',
          'requiredForDiagnostics': true,
          'runtime': true,
          'canRequestAgain': false,
          'shouldShowRationale': false,
        },
      ],
      'advertisingCapability': 'supported',
      'reason': 'No BLE radio operation was performed.',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(_methodChannel, null);
    messenger.setMockStreamHandler(_eventChannel, null);
  });

  test('refresh and permission request use the typed method bridge', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(_methodChannel, (call) async {
      calls.add(call.method);
      return _readyStatus();
    });
    final bridge = BleDiagnosticBridge(
      methodChannel: _methodChannel,
      eventChannel: _eventChannel,
      isAndroid: true,
    );

    final refreshed = await bridge.refresh();
    final requested = await bridge.requestRequiredPermissions();

    expect(calls, <String>['getStatus', 'requestRequiredPermissions']);
    expect(refreshed.state, BleDiagnosticState.ready);
    expect(requested.state, BleDiagnosticState.ready);
  });

  test('event channel values become typed status updates', () async {
    messenger.setMockStreamHandler(
      _eventChannel,
      MockStreamHandler.inline(
        onListen: (_, events) => events.success(_readyStatus()),
      ),
    );
    final bridge = BleDiagnosticBridge(
      methodChannel: _methodChannel,
      eventChannel: _eventChannel,
      isAndroid: true,
    );

    final status = await bridge.watchStatus().first;

    expect(status.state, BleDiagnosticState.ready);
    expect(status.bluetoothEnabled, isTrue);
  });

  test('platform stream errors are represented as diagnostic status', () async {
    messenger.setMockStreamHandler(
      _eventChannel,
      MockStreamHandler.inline(
        onListen: (_, events) => events.error(
          code: 'diagnostic_failure',
          message: 'Unavailable',
        ),
      ),
    );
    final bridge = BleDiagnosticBridge(
      methodChannel: _methodChannel,
      eventChannel: _eventChannel,
      isAndroid: true,
    );

    final status = await bridge.watchStatus().first;

    expect(status.state, BleDiagnosticState.error);
  });

  test('non-Android platforms return unsupported status without channels',
      () async {
    final bridge = BleDiagnosticBridge(
      methodChannel: _methodChannel,
      eventChannel: _eventChannel,
      isAndroid: false,
    );

    expect(
      (await bridge.refresh()).state,
      BleDiagnosticState.unsupportedPlatform,
    );
    expect(
      (await bridge.watchStatus().first).state,
      BleDiagnosticState.unsupportedPlatform,
    );
  });
}
