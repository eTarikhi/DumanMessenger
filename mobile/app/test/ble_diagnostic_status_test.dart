import 'package:duman_messenger/ble/ble_diagnostic_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BleDiagnosticStatus.fromMap', () {
    test('parses Android capability, permission, and adapter status', () {
      final status = BleDiagnosticStatus.fromMap(<String, Object?>{
        'state': 'permissions_denied',
        'apiLevel': 35,
        'bleHardwareSupported': true,
        'bluetoothManagerAvailable': true,
        'adapterAvailable': true,
        'bluetoothEnabled': null,
        'permissions': <Object?>[
          <String, Object?>{
            'name': 'android.permission.BLUETOOTH_CONNECT',
            'state': 'denied',
            'requiredForDiagnostics': true,
            'runtime': true,
            'canRequestAgain': true,
            'shouldShowRationale': true,
          },
          <String, Object?>{
            'name': 'android.permission.BLUETOOTH_SCAN',
            'state': 'denied',
            'requiredForDiagnostics': false,
            'runtime': true,
            'canRequestAgain': false,
            'shouldShowRationale': false,
          },
        ],
        'advertisingCapability': 'unknown',
        'reason': 'Bluetooth Connect permission is needed.',
      });

      expect(status.state, BleDiagnosticState.permissionsDenied);
      expect(status.apiLevel, 35);
      expect(status.bleHardwareSupported, isTrue);
      expect(status.bluetoothEnabled, isNull);
      expect(
        status.advertisingCapability,
        BleAdvertisingCapability.unknown,
      );
      expect(status.canRequestRequiredPermissions, isTrue);
      expect(status.requiresManualPermissionSettings, isFalse);
      expect(
        status.permission('android.permission.BLUETOOTH_CONNECT')?.state,
        BlePermissionState.denied,
      );
      expect(
        status.permission('android.permission.BLUETOOTH_CONNECT')?.isRuntime,
        isTrue,
      );
      expect(
        status.permission('android.permission.BLUETOOTH_SCAN')
            ?.requiredForDiagnostics,
        isFalse,
      );
    });

    test('marks a permanently denied required permission for manual settings', () {
      final status = BleDiagnosticStatus.fromMap(<String, Object?>{
        'state': 'permissions_denied',
        'permissions': <Object?>[
          <String, Object?>{
            'name': 'android.permission.BLUETOOTH_CONNECT',
            'state': 'denied',
            'requiredForDiagnostics': true,
            'runtime': true,
            'canRequestAgain': false,
            'shouldShowRationale': false,
          },
        ],
        'advertisingCapability': 'unsupported',
      });

      expect(status.canRequestRequiredPermissions, isFalse);
      expect(status.requiresManualPermissionSettings, isTrue);
    });

    test('does not request permission when BLE hardware is unavailable', () {
      final status = BleDiagnosticStatus.fromMap(<String, Object?>{
        'state': 'ble_hardware_unavailable',
        'bleHardwareSupported': false,
        'permissions': <Object?>[
          <String, Object?>{
            'name': 'android.permission.BLUETOOTH_CONNECT',
            'state': 'denied',
            'requiredForDiagnostics': true,
            'runtime': true,
            'canRequestAgain': true,
            'shouldShowRationale': false,
          },
        ],
        'advertisingCapability': 'unsupported',
      });

      expect(status.canRequestRequiredPermissions, isFalse);
      expect(status.requiresManualPermissionSettings, isFalse);
    });

    test('parses legacy ready status and not-applicable permissions', () {
      final status = BleDiagnosticStatus.fromMap(<String, Object?>{
        'state': 'ready',
        'apiLevel': 30,
        'bleHardwareSupported': true,
        'bluetoothManagerAvailable': true,
        'adapterAvailable': true,
        'bluetoothEnabled': true,
        'permissions': <Object?>[
          <String, Object?>{
            'name': 'android.permission.BLUETOOTH',
            'state': 'granted',
            'requiredForDiagnostics': true,
            'runtime': false,
          },
          <String, Object?>{
            'name': 'android.permission.BLUETOOTH_CONNECT',
            'state': 'not_required',
            'requiredForDiagnostics': false,
            'runtime': false,
          },
          <String, Object?>{
            'name': 'android.permission.ACCESS_FINE_LOCATION',
            'state': 'denied',
            'requiredForDiagnostics': false,
            'runtime': true,
            'canRequestAgain': false,
            'shouldShowRationale': false,
          },
        ],
        'advertisingCapability': 'supported',
      });

      expect(status.state, BleDiagnosticState.ready);
      expect(status.displayLabel, 'Ready');
      expect(
        status.permission('android.permission.BLUETOOTH_CONNECT')?.state,
        BlePermissionState.notRequired,
      );
      final fineLocation =
          status.permission('android.permission.ACCESS_FINE_LOCATION');
      expect(fineLocation?.state, BlePermissionState.denied);
      expect(fineLocation?.isRuntime, isTrue);
      expect(fineLocation?.requiredForDiagnostics, isFalse);
      expect(status.canRequestRequiredPermissions, isFalse);
      expect(status.advertisingCapability, BleAdvertisingCapability.supported);
    });

    test('rejects unknown wire states', () {
      expect(
        () => BleDiagnosticStatus.fromMap(<String, Object?>{
          'state': 'scanning',
          'permissions': <Object?>[],
        }),
        throwsFormatException,
      );
    });
  });
}
