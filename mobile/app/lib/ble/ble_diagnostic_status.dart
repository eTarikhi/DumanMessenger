enum BleDiagnosticState {
  unsupportedPlatform,
  bleHardwareUnavailable,
  nativeServiceUnavailable,
  permissionsDenied,
  bluetoothDisabled,
  ready,
  error,
}

enum BleAdvertisingCapability { supported, unsupported, unknown }

enum BlePermissionState { granted, denied, notRequired }

class BlePermissionStatus {
  const BlePermissionStatus({
    required this.name,
    required this.state,
    required this.requiredForDiagnostics,
    required this.canRequestAgain,
    required this.shouldShowRationale,
    this.isRuntime = false,
  });

  final String name;
  final BlePermissionState state;
  final bool requiredForDiagnostics;
  final bool isRuntime;
  final bool canRequestAgain;
  final bool shouldShowRationale;

  factory BlePermissionStatus.fromMap(Map<String, Object?> map) {
    final name = map['name'];
    final rawState = map['state'];
    if (name is! String || rawState is! String) {
      throw const FormatException('Invalid BLE permission entry.');
    }

    final state = switch (rawState) {
      'granted' => BlePermissionState.granted,
      'denied' => BlePermissionState.denied,
      'not_required' => BlePermissionState.notRequired,
      _ => throw const FormatException('Unknown BLE permission state.'),
    };

    return BlePermissionStatus(
      name: name,
      state: state,
      requiredForDiagnostics: map['requiredForDiagnostics'] == true,
      isRuntime: map['runtime'] == true,
      canRequestAgain: map['canRequestAgain'] == true,
      shouldShowRationale: map['shouldShowRationale'] == true,
    );
  }

  bool get isGranted => state == BlePermissionState.granted;
}

class BleDiagnosticStatus {
  const BleDiagnosticStatus({
    required this.state,
    required this.permissions,
    required this.advertisingCapability,
    this.apiLevel,
    this.bleHardwareSupported,
    this.bluetoothManagerAvailable,
    this.adapterAvailable,
    this.bluetoothEnabled,
    this.reason,
  });

  final BleDiagnosticState state;
  final int? apiLevel;
  final bool? bleHardwareSupported;
  final bool? bluetoothManagerAvailable;
  final bool? adapterAvailable;
  final bool? bluetoothEnabled;
  final List<BlePermissionStatus> permissions;
  final BleAdvertisingCapability advertisingCapability;
  final String? reason;

  factory BleDiagnosticStatus.fromMap(Map<String, Object?> map) {
    final rawState = map['state'];
    if (rawState is! String) {
      throw const FormatException('Missing BLE diagnostic state.');
    }

    final state = switch (rawState) {
      'ble_hardware_unavailable' => BleDiagnosticState.bleHardwareUnavailable,
      'native_service_unavailable' =>
        BleDiagnosticState.nativeServiceUnavailable,
      'permissions_denied' => BleDiagnosticState.permissionsDenied,
      'bluetooth_disabled' => BleDiagnosticState.bluetoothDisabled,
      'ready' => BleDiagnosticState.ready,
      'error' => BleDiagnosticState.error,
      _ => throw const FormatException('Unknown BLE diagnostic state.'),
    };

    final rawPermissions = map['permissions'];
    if (rawPermissions is! List) {
      throw const FormatException('Missing BLE permission report.');
    }
    final permissions = rawPermissions.map((entry) {
      if (entry is! Map) {
        throw const FormatException('Invalid BLE permission report.');
      }
      return BlePermissionStatus.fromMap(Map<String, Object?>.from(entry));
    }).toList(growable: false);

    final rawCapability = map['advertisingCapability'];
    final capability = switch (rawCapability) {
      'supported' => BleAdvertisingCapability.supported,
      'unsupported' => BleAdvertisingCapability.unsupported,
      _ => BleAdvertisingCapability.unknown,
    };

    return BleDiagnosticStatus(
      state: state,
      apiLevel: map['apiLevel'] is int ? map['apiLevel'] as int : null,
      bleHardwareSupported: _optionalBool(map['bleHardwareSupported']),
      bluetoothManagerAvailable:
          _optionalBool(map['bluetoothManagerAvailable']),
      adapterAvailable: _optionalBool(map['adapterAvailable']),
      bluetoothEnabled: _optionalBool(map['bluetoothEnabled']),
      permissions: permissions,
      advertisingCapability: capability,
      reason: map['reason'] is String ? map['reason'] as String : null,
    );
  }

  factory BleDiagnosticStatus.unsupportedPlatform() =>
      const BleDiagnosticStatus(
        state: BleDiagnosticState.unsupportedPlatform,
        permissions: <BlePermissionStatus>[],
        advertisingCapability: BleAdvertisingCapability.unknown,
        reason: 'BLE diagnostics are available on Android only.',
      );

  factory BleDiagnosticStatus.nativeServiceUnavailable() =>
      const BleDiagnosticStatus(
        state: BleDiagnosticState.nativeServiceUnavailable,
        permissions: <BlePermissionStatus>[],
        advertisingCapability: BleAdvertisingCapability.unknown,
        reason: 'The Android diagnostic service is unavailable.',
      );

  factory BleDiagnosticStatus.diagnosticError() =>
      const BleDiagnosticStatus(
        state: BleDiagnosticState.error,
        permissions: <BlePermissionStatus>[],
        advertisingCapability: BleAdvertisingCapability.unknown,
        reason: 'The BLE diagnostic status could not be read.',
      );

  BlePermissionStatus? permission(String name) {
    for (final item in permissions) {
      if (item.name == name) return item;
    }
    return null;
  }

  bool get canRequestRequiredPermissions =>
      state == BleDiagnosticState.permissionsDenied &&
      permissions.any(
        (item) =>
            item.requiredForDiagnostics &&
            item.state == BlePermissionState.denied &&
            item.canRequestAgain,
      );

  bool get requiresManualPermissionSettings =>
      state == BleDiagnosticState.permissionsDenied &&
      permissions.any(
        (item) =>
            item.requiredForDiagnostics &&
            item.state == BlePermissionState.denied &&
            !item.canRequestAgain,
      );

  String get displayLabel => switch (state) {
        BleDiagnosticState.unsupportedPlatform => 'Unsupported platform',
        BleDiagnosticState.bleHardwareUnavailable => 'BLE unavailable',
        BleDiagnosticState.nativeServiceUnavailable =>
          'Diagnostic service unavailable',
        BleDiagnosticState.permissionsDenied => 'Permission required',
        BleDiagnosticState.bluetoothDisabled => 'Bluetooth is off',
        BleDiagnosticState.ready => 'Ready',
        BleDiagnosticState.error => 'Diagnostic error',
      };

  static bool? _optionalBool(Object? value) => value is bool ? value : null;
}
