import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ble_diagnostic_status.dart';

const String bleDiagnosticMethodChannelName =
    'com.dumanmessenger/ble_diagnostic/methods';
const String bleDiagnosticEventChannelName =
    'com.dumanmessenger/ble_diagnostic/events';

abstract interface class BleDiagnosticApi {
  Future<BleDiagnosticStatus> refresh();

  Future<BleDiagnosticStatus> requestRequiredPermissions();

  Stream<BleDiagnosticStatus> watchStatus();
}

class BleDiagnosticBridge implements BleDiagnosticApi {
  BleDiagnosticBridge({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    bool? isAndroid,
  })  : _methodChannel = methodChannel ??
            const MethodChannel(bleDiagnosticMethodChannelName),
        _eventChannel =
            eventChannel ?? const EventChannel(bleDiagnosticEventChannelName),
        _isAndroid = isAndroid ??
            (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final bool _isAndroid;

  @override
  Future<BleDiagnosticStatus> refresh() => _invoke('getStatus');

  @override
  Future<BleDiagnosticStatus> requestRequiredPermissions() =>
      _invoke('requestRequiredPermissions');

  @override
  Stream<BleDiagnosticStatus> watchStatus() {
    if (!_isAndroid) {
      return Stream<BleDiagnosticStatus>.value(
        BleDiagnosticStatus.unsupportedPlatform(),
      );
    }

    return _eventChannel
        .receiveBroadcastStream()
        .map(_decode)
        .transform(
          StreamTransformer<BleDiagnosticStatus, BleDiagnosticStatus>.fromHandlers(
            handleError: (Object error, StackTrace _,
                EventSink<BleDiagnosticStatus> sink) {
              sink.add(_statusForError(error));
            },
          ),
        );
  }

  Future<BleDiagnosticStatus> _invoke(String method) async {
    if (!_isAndroid) return BleDiagnosticStatus.unsupportedPlatform();

    try {
      final response = await _methodChannel
          .invokeMapMethod<String, Object?>(method);
      if (response == null) {
        return BleDiagnosticStatus.nativeServiceUnavailable();
      }
      return BleDiagnosticStatus.fromMap(response);
    } on MissingPluginException {
      return BleDiagnosticStatus.nativeServiceUnavailable();
    } on PlatformException {
      return BleDiagnosticStatus.diagnosticError();
    } on FormatException {
      return BleDiagnosticStatus.diagnosticError();
    } catch (_) {
      return BleDiagnosticStatus.diagnosticError();
    }
  }

  BleDiagnosticStatus _decode(Object? event) {
    if (event is! Map) return BleDiagnosticStatus.diagnosticError();
    try {
      return BleDiagnosticStatus.fromMap(Map<String, Object?>.from(event));
    } on FormatException {
      return BleDiagnosticStatus.diagnosticError();
    } on TypeError {
      return BleDiagnosticStatus.diagnosticError();
    }
  }

  BleDiagnosticStatus _statusForError(Object error) {
    if (error is MissingPluginException) {
      return BleDiagnosticStatus.nativeServiceUnavailable();
    }
    return BleDiagnosticStatus.diagnosticError();
  }
}
