import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ble_discovery_status.dart';

const String bleDiscoveryMethodChannelName =
    'com.dumanmessenger/ble_discovery/methods';
const String bleDiscoveryEventChannelName =
    'com.dumanmessenger/ble_discovery/events';

abstract interface class BleDiscoveryApi {
  Future<BleDiscoveryStatus> refresh();

  Future<BleDiscoveryStatus> startAdvertising();

  Future<BleDiscoveryStatus> stopAdvertising();

  Future<BleDiscoveryStatus> startScanning();

  Future<BleDiscoveryStatus> stopScanning();

  Future<BleDiscoveryStatus> stopAll();

  Stream<BleDiscoveryStatus> watchStatus();
}

class BleDiscoveryBridge implements BleDiscoveryApi {
  BleDiscoveryBridge({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    bool? isAndroid,
  })  : _methodChannel = methodChannel ??
            const MethodChannel(bleDiscoveryMethodChannelName),
        _eventChannel =
            eventChannel ?? const EventChannel(bleDiscoveryEventChannelName),
        _isAndroid = isAndroid ??
            (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final bool _isAndroid;

  @override
  Future<BleDiscoveryStatus> refresh() => _invoke('getStatus');

  @override
  Future<BleDiscoveryStatus> startAdvertising() =>
      _invoke('startAdvertising');

  @override
  Future<BleDiscoveryStatus> stopAdvertising() =>
      _invoke('stopAdvertising');

  @override
  Future<BleDiscoveryStatus> startScanning() => _invoke('startScanning');

  @override
  Future<BleDiscoveryStatus> stopScanning() => _invoke('stopScanning');

  @override
  Future<BleDiscoveryStatus> stopAll() => _invoke('stopAll');

  @override
  Stream<BleDiscoveryStatus> watchStatus() {
    if (!_isAndroid) {
      return Stream<BleDiscoveryStatus>.value(
        BleDiscoveryStatus.unsupportedPlatform(),
      );
    }

    return _eventChannel.receiveBroadcastStream().map(_decode).transform(
          StreamTransformer<BleDiscoveryStatus, BleDiscoveryStatus>.fromHandlers(
            handleError: (Object _, StackTrace __,
                EventSink<BleDiscoveryStatus> sink) {
              sink.add(BleDiscoveryStatus.channelError());
            },
          ),
        );
  }

  Future<BleDiscoveryStatus> _invoke(String method) async {
    if (!_isAndroid) return BleDiscoveryStatus.unsupportedPlatform();

    try {
      final response = await _methodChannel
          .invokeMapMethod<String, Object?>(method);
      if (response == null) return BleDiscoveryStatus.channelError();
      return BleDiscoveryStatus.fromMap(response);
    } on MissingPluginException {
      return BleDiscoveryStatus.channelError();
    } on PlatformException {
      return BleDiscoveryStatus.channelError();
    } on FormatException {
      return BleDiscoveryStatus.channelError();
    } catch (_) {
      return BleDiscoveryStatus.channelError();
    }
  }

  BleDiscoveryStatus _decode(Object? event) {
    if (event is! Map) return BleDiscoveryStatus.channelError();
    try {
      return BleDiscoveryStatus.fromMap(Map<String, Object?>.from(event));
    } on FormatException {
      return BleDiscoveryStatus.channelError();
    } on TypeError {
      return BleDiscoveryStatus.channelError();
    }
  }
}
