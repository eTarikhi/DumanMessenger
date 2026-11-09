import 'package:duman_messenger/ble/ble_diagnostic_status.dart';
import 'package:duman_messenger/ble/ble_discovery_status.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _entry({
  required String name,
  required String state,
  bool scanning = false,
  bool advertising = false,
  bool runtime = false,
  bool canRequestAgain = false,
  bool shouldShowRationale = false,
}) => <String, Object?>{
      'name': name,
      'state': state,
      'requiredForScanning': scanning,
      'requiredForAdvertising': advertising,
      'runtime': runtime,
      'canRequestAgain': canRequestAgain,
      'shouldShowRationale': shouldShowRationale,
    };

void main() {
  test('uses the reserved DumanMessenger BLE service UUID', () {
    expect(
      dumanMessengerBleServiceUuid,
      '5d1796d0-d8f8-406a-8b3d-1a8684447470',
    );
  });

  group('BleDiscoveryStatus.fromMap', () {
    test('parses API 30 foreground scan permission and temporary results', () {
      final status = BleDiscoveryStatus.fromMap(<String, Object?>{
        'apiLevel': 30,
        'bleHardwareSupported': true,
        'adapterAvailable': true,
        'adapterEnabled': true,
        'advertiserAvailable': true,
        'scannerAvailable': null,
        'advertisingState': 'idle',
        'scanningState': 'permission_denied',
        'permissions': <Object?>[
          _entry(
            name: 'android.permission.ACCESS_FINE_LOCATION',
            state: 'denied',
            scanning: true,
            runtime: true,
            canRequestAgain: true,
            shouldShowRationale: true,
          ),
          _entry(
            name: 'android.permission.BLUETOOTH',
            state: 'granted',
            scanning: true,
            advertising: true,
          ),
        ],
        'results': <Object?>[
          <String, Object?>{'sessionId': 'result-1'},
        ],
        'errorCode': 'permission_denied',
        'message': 'Foreground permission is required to scan.',
      });

      final location =
          status.permission('android.permission.ACCESS_FINE_LOCATION');
      expect(status.apiLevel, 30);
      expect(status.bleHardwareSupported, isTrue);
      expect(status.scannerAvailable, isNull);
      expect(status.advertisingState, BleDiscoveryOperationState.idle);
      expect(status.scanningState, BleDiscoveryOperationState.permissionDenied);
      expect(location?.state, BlePermissionState.denied);
      expect(location?.requiredForScanning, isTrue);
      expect(location?.requiredForAdvertising, isFalse);
      expect(location?.canRequestAgain, isTrue);
      expect(status.matchingDeviceCount, 1);
      expect(status.results.single.sessionId, 'result-1');
      expect(status.errorCode, 'permission_denied');
    });

    test('parses Android 12+ scan and advertising permissions separately', () {
      final status = BleDiscoveryStatus.fromMap(<String, Object?>{
        'apiLevel': 35,
        'bleHardwareSupported': true,
        'adapterAvailable': true,
        'adapterEnabled': null,
        'advertiserAvailable': true,
        'scannerAvailable': true,
        'advertisingState': 'active',
        'scanningState': 'active',
        'permissions': <Object?>[
          _entry(
            name: 'android.permission.BLUETOOTH_SCAN',
            state: 'granted',
            scanning: true,
            runtime: true,
          ),
          _entry(
            name: 'android.permission.BLUETOOTH_ADVERTISE',
            state: 'granted',
            advertising: true,
            runtime: true,
          ),
          _entry(
            name: 'android.permission.ACCESS_FINE_LOCATION',
            state: 'not_required',
          ),
        ],
        'results': <Object?>[],
      });

      expect(status.isRequestingPermission, isFalse);
      expect(status.advertisingState, BleDiscoveryOperationState.active);
      expect(status.scanningState, BleDiscoveryOperationState.active);
      expect(
        status.permission('android.permission.BLUETOOTH_SCAN')
            ?.requiredForScanning,
        isTrue,
      );
      expect(
        status.permission('android.permission.BLUETOOTH_ADVERTISE')
            ?.requiredForAdvertising,
        isTrue,
      );
      expect(
        status.permission('android.permission.ACCESS_FINE_LOCATION')?.state,
        BlePermissionState.notRequired,
      );
    });

    test('rejects unknown operation states and malformed results', () {
      expect(
        () => BleDiscoveryStatus.fromMap(<String, Object?>{
          'advertisingState': 'connected',
          'scanningState': 'idle',
          'permissions': <Object?>[],
          'results': <Object?>[],
        }),
        throwsFormatException,
      );
      expect(
        () => BleDiscoveryResult.fromMap(<String, Object?>{
          'sessionId': 42,
        }),
        throwsFormatException,
      );
    });
  });
}
