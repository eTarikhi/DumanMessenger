/// Test double for the `duman/identity` platform side.
///
/// This is a Dart-level double: it stands in for the Android adapter so the
/// channel client, the store adapter and the runtime can be exercised without a
/// device. It does **not** encrypt anything, it does not touch the Keystore, and
/// a passing test here is not device verification.
///
/// Anything that must be proven on real hardware — AES-GCM, a failed tag, a
/// deleted or invalidated key, interrupted writes — is covered by the Android
/// instrumentation tests in
/// `android/app/src/androidTest/kotlin/com/example/duman_messenger/identity/`.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in platform implementation with controllable behaviour.
class FakeIdentityPlatform {
  FakeIdentityPlatform({Map<String, Object?>? capabilities})
      : capabilities = capabilities ?? measuredEvidence();

  /// The channel the app uses.
  static const MethodChannel channel = MethodChannel('duman/identity');

  /// Response to `capabilities`.
  Map<String, Object?> capabilities;

  /// Stands in for the encrypted slot files: the payload the platform holds.
  String? storedPayload;

  /// Every call the adapter made, in order.
  final List<MethodCall> calls = <MethodCall>[];

  /// Thrown once by the next call, then cleared.
  PlatformException? failNext;

  /// When true, `save` throws a write failure once.
  bool failSaveOnce = false;

  /// When set, every `load` throws this error, as a device with encrypted data
  /// but a missing or invalidated wrapping key does.
  PlatformException? persistentLoadFailure;

  void install() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handle);
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  /// Number of `save` calls that reached the platform.
  int get saveCount => calls.where((MethodCall call) => call.method == 'save').length;

  /// Payloads sent to `save`, decoded for assertions.
  List<Map<String, Object?>> get savedPayloads => calls
      .where((MethodCall call) => call.method == 'save')
      .map((MethodCall call) =>
          (call.arguments as Map<Object?, Object?>)['payload']! as String)
      .map((String payload) => decodeRecordPayload(payload))
      .toList();

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    final PlatformException? failure = failNext;
    if (failure != null) {
      failNext = null;
      throw failure;
    }
    switch (call.method) {
      case 'capabilities':
        return capabilities;
      case 'load':
        if (persistentLoadFailure != null) {
          throw persistentLoadFailure!;
        }
        return storedPayload;
      case 'save':
        if (failSaveOnce) {
          failSaveOnce = false;
          throw PlatformException(
            code: 'write_failed',
            message: 'simulated write failure',
          );
        }
        final arguments = call.arguments as Map<Object?, Object?>;
        storedPayload = arguments['payload']! as String;
        return null;
      case 'delete':
        storedPayload = null;
        return null;
    }
    throw MissingPluginException('unknown identity method ${call.method}');
  }
}

/// Decodes a record payload without importing the identity codec, so a payload
/// shape change shows up as a decode failure here too.
Map<String, Object?> decodeRecordPayload(String payload) {
  final Object? decoded = jsonDecode(payload);
  if (decoded is! Map) {
    throw FormatException('payload is not a map');
  }
  return decoded.cast<String, Object?>();
}

/// Capability evidence for a device whose Keystore round trip verified.
///
/// Defaults describe the API 27 test device honestly: the wrap works, and the
/// AES key is *not* reported as hardware-backed unless a test asks for it.
Map<String, Object?> measuredEvidence({
  int apiLevel = 27,
  bool hardwareBacked = false,
  bool roundTripVerified = true,
  bool aesGcmSupported = true,
  bool strongBoxRequested = false,
  bool strongBoxKeyCreated = false,
  bool wrappingKeyPresent = false,
  bool? wrappingKeyHardwareBacked,
  List<String> notes = const <String>[],
}) =>
    <String, Object?>{
      'apiLevel': apiLevel,
      'keystoreProvider': 'AndroidKeyStore',
      'aesGcmSupported': aesGcmSupported,
      'probeKeyGenerated': true,
      'roundTripVerified': roundTripVerified,
      'probeKeyHardwareBacked': hardwareBacked,
      'probeKeySizeBits': 256,
      'strongBoxRequested': strongBoxRequested,
      'strongBoxKeyCreated': strongBoxKeyCreated,
      'wrappingKeyPresent': wrappingKeyPresent,
      'wrappingKeyHardwareBacked': wrappingKeyHardwareBacked,
      'notes': notes,
      'failure': null,
    };
