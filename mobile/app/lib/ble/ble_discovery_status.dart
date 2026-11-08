import 'ble_diagnostic_status.dart';

const String dumanMessengerBleServiceUuid =
    '5d1796d0-d8f8-406a-8b3d-1a8684447470';

enum BleDiscoveryOperationState {
  idle,
  requestingPermission,
  starting,
  active,
  permissionDenied,
  unsupported,
  unavailable,
  failed,
}

class BleDiscoveryPermissionStatus {
  const BleDiscoveryPermissionStatus({
    required this.name,
    required this.state,
    required this.requiredForScanning,
    required this.requiredForAdvertising,
    required this.isRuntime,
    required this.canRequestAgain,
    required this.shouldShowRationale,
  });

  final String name;
  final BlePermissionState state;
  final bool requiredForScanning;
  final bool requiredForAdvertising;
  final bool isRuntime;
  final bool canRequestAgain;
  final bool shouldShowRationale;

  factory BleDiscoveryPermissionStatus.fromMap(Map<String, Object?> map) {
    final name = map['name'];
    final rawState = map['state'];
    if (name is! String || rawState is! String) {
      throw const FormatException('Invalid BLE discovery permission entry.');
    }

    final state = switch (rawState) {
      'granted' => BlePermissionState.granted,
      'denied' => BlePermissionState.denied,
      'not_required' => BlePermissionState.notRequired,
      _ => throw const FormatException(
          'Unknown BLE discovery permission state.',
        ),
    };

    return BleDiscoveryPermissionStatus(
      name: name,
      state: state,
      requiredForScanning: map['requiredForScanning'] == true,
      requiredForAdvertising: map['requiredForAdvertising'] == true,
      isRuntime: map['runtime'] == true,
      canRequestAgain: map['canRequestAgain'] == true,
      shouldShowRationale: map['shouldShowRationale'] == true,
    );
  }
}

class BleDiscoveryResult {
  const BleDiscoveryResult({required this.sessionId});

  /// Generated for this scan session; it is not derived from a device identifier.
  final String sessionId;

  factory BleDiscoveryResult.fromMap(Map<String, Object?> map) {
    final sessionId = map['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) {
      throw const FormatException('Invalid temporary BLE discovery result.');
    }
    return BleDiscoveryResult(sessionId: sessionId);
  }
}

class BleDiscoveryStatus {
  const BleDiscoveryStatus({
    required this.advertisingState,
    required this.scanningState,
    required this.permissions,
    required this.results,
    this.apiLevel,
    this.bleHardwareSupported,
    this.adapterAvailable,
    this.adapterEnabled,
    this.advertiserAvailable,
    this.scannerAvailable,
    this.errorCode,
    this.message,
  });

  final int? apiLevel;
  final bool? bleHardwareSupported;
  final bool? adapterAvailable;
  final bool? adapterEnabled;
  final bool? advertiserAvailable;
  final bool? scannerAvailable;
  final BleDiscoveryOperationState advertisingState;
  final BleDiscoveryOperationState scanningState;
  final List<BleDiscoveryPermissionStatus> permissions;
  final List<BleDiscoveryResult> results;
  final String? errorCode;
  final String? message;

  int get matchingDeviceCount => results.length;

  bool get isRequestingPermission =>
      advertisingState == BleDiscoveryOperationState.requestingPermission ||
      scanningState == BleDiscoveryOperationState.requestingPermission;

  BleDiscoveryPermissionStatus? permission(String name) {
    for (final item in permissions) {
      if (item.name == name) return item;
    }
    return null;
  }

  factory BleDiscoveryStatus.fromMap(Map<String, Object?> map) {
    final advertisingState = _operationState(map['advertisingState']);
    final scanningState = _operationState(map['scanningState']);
    final rawPermissions = map['permissions'];
    final rawResults = map['results'];
    if (rawPermissions is! List || rawResults is! List) {
      throw const FormatException('Missing BLE discovery status collections.');
    }

    final permissions = rawPermissions.map((entry) {
      if (entry is! Map) {
        throw const FormatException('Invalid BLE discovery permission list.');
      }
      return BleDiscoveryPermissionStatus.fromMap(
        Map<String, Object?>.from(entry),
      );
    }).toList(growable: false);

    final results = rawResults.map((entry) {
      if (entry is! Map) {
        throw const FormatException('Invalid BLE discovery results list.');
      }
      return BleDiscoveryResult.fromMap(Map<String, Object?>.from(entry));
    }).toList(growable: false);

    return BleDiscoveryStatus(
      apiLevel: map['apiLevel'] is int ? map['apiLevel'] as int : null,
      bleHardwareSupported: _optionalBool(map['bleHardwareSupported']),
      adapterAvailable: _optionalBool(map['adapterAvailable']),
      adapterEnabled: _optionalBool(map['adapterEnabled']),
      advertiserAvailable: _optionalBool(map['advertiserAvailable']),
      scannerAvailable: _optionalBool(map['scannerAvailable']),
      advertisingState: advertisingState,
      scanningState: scanningState,
      permissions: permissions,
      results: results,
      errorCode: map['errorCode'] is String ? map['errorCode'] as String : null,
      message: map['message'] is String ? map['message'] as String : null,
    );
  }

  factory BleDiscoveryStatus.initial() => const BleDiscoveryStatus(
        advertisingState: BleDiscoveryOperationState.idle,
        scanningState: BleDiscoveryOperationState.idle,
        permissions: <BleDiscoveryPermissionStatus>[],
        results: <BleDiscoveryResult>[],
      );

  factory BleDiscoveryStatus.unsupportedPlatform() => const BleDiscoveryStatus(
        advertisingState: BleDiscoveryOperationState.unsupported,
        scanningState: BleDiscoveryOperationState.unsupported,
        permissions: <BleDiscoveryPermissionStatus>[],
        results: <BleDiscoveryResult>[],
        errorCode: 'unsupported_platform',
        message: 'Foreground BLE discovery is available on Android only.',
      );

  factory BleDiscoveryStatus.channelError() => const BleDiscoveryStatus(
        advertisingState: BleDiscoveryOperationState.failed,
        scanningState: BleDiscoveryOperationState.failed,
        permissions: <BleDiscoveryPermissionStatus>[],
        results: <BleDiscoveryResult>[],
        errorCode: 'native_service_unavailable',
        message: 'The Android BLE discovery service is unavailable.',
      );

  static BleDiscoveryOperationState _operationState(Object? value) {
    if (value is! String) {
      throw const FormatException('Missing BLE discovery operation state.');
    }
    return switch (value) {
      'idle' => BleDiscoveryOperationState.idle,
      'requesting_permission' =>
        BleDiscoveryOperationState.requestingPermission,
      'starting' => BleDiscoveryOperationState.starting,
      'active' => BleDiscoveryOperationState.active,
      'permission_denied' => BleDiscoveryOperationState.permissionDenied,
      'unsupported' => BleDiscoveryOperationState.unsupported,
      'unavailable' => BleDiscoveryOperationState.unavailable,
      'failed' => BleDiscoveryOperationState.failed,
      _ => throw const FormatException('Unknown BLE discovery operation state.'),
    };
  }

  static bool? _optionalBool(Object? value) => value is bool ? value : null;
}
