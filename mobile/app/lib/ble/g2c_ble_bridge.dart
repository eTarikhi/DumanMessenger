import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'g2c_ble_status.dart';

const String g2cBleMethodChannelName = 'com.dumanmessenger/g2c/methods';
const String g2cBleEventChannelName = 'com.dumanmessenger/g2c/events';

abstract interface class G2cBleApi {
  Future<G2cBleStatus> refresh();
  Future<G2cBleStatus> startDiscovery();
  Future<G2cBleStatus> stopDiscovery();
  Future<G2cBleStatus> connect(String peerId);
  Future<G2cBleStatus> disconnect();
  Future<G2cBleStatus> startServer();
  Future<G2cBleStatus> stopServer();
  Future<G2cBleStatus> openPermissionSettings();
  Future<G2cBleStatus> sendTestFrame(int type, List<int> payload);
  Stream<G2cBleStatus> watchStatus();
}

/// Android G2-C bridge. Discovery references are process-local opaque tokens,
/// not peer identities. A transport connection is never equivalent to security.
class G2cBleBridge implements G2cBleApi {
  G2cBleBridge({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    bool? isAndroid,
  })  : _methods = methodChannel ?? const MethodChannel(g2cBleMethodChannelName),
        _events = eventChannel ?? const EventChannel(g2cBleEventChannelName),
        _isAndroid = isAndroid ??
            (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final MethodChannel _methods;
  final EventChannel _events;
  final bool _isAndroid;

  @override
  Future<G2cBleStatus> refresh() => _invoke('getStatus');

  @override
  Future<G2cBleStatus> startDiscovery() => _invoke('startDiscovery');

  @override
  Future<G2cBleStatus> stopDiscovery() => _invoke('stopDiscovery');

  @override
  Future<G2cBleStatus> connect(String peerId) {
    if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(peerId)) {
      return Future.value(G2cBleStatus.unavailable(
        G2cLinkState.connectionFailed,
        'invalid_peer_reference',
      ));
    }
    return _invoke('connect', <String, Object?>{'peerId': peerId});
  }

  @override
  Future<G2cBleStatus> disconnect() => _invoke('disconnect');

  @override
  Future<G2cBleStatus> startServer() => _invoke('startServer');

  @override
  Future<G2cBleStatus> stopServer() => _invoke('stopServer');

  @override
  Future<G2cBleStatus> openPermissionSettings() =>
      _invoke('openPermissionSettings');

  @override
  Future<G2cBleStatus> sendTestFrame(int type, List<int> payload) {
    if (type < 1 || type > 255 || payload.length > 512) {
      return Future.value(G2cBleStatus.unavailable(
        G2cLinkState.protocolError,
        'invalid_test_frame',
      ));
    }
    return _invoke('sendTestFrame', <String, Object?>{
      'type': type,
      'payload': Uint8List.fromList(payload),
    });
  }

  @override
  Stream<G2cBleStatus> watchStatus() {
    if (!_isAndroid) {
      return Stream<G2cBleStatus>.value(
        G2cBleStatus.unavailable(
          G2cLinkState.unsupported,
          'unsupported_platform',
        ),
      );
    }
    return _events.receiveBroadcastStream().map(_decode).transform(
          StreamTransformer<G2cBleStatus, G2cBleStatus>.fromHandlers(
            handleError: (Object _, StackTrace _, sink) {
              sink.add(G2cBleStatus.unavailable(
                G2cLinkState.channelUnavailable,
                'native_service_unavailable',
              ));
            },
          ),
        );
  }

  Future<G2cBleStatus> _invoke(String method, [Map<String, Object?>? args]) async {
    if (!_isAndroid) {
      return G2cBleStatus.unavailable(
        G2cLinkState.unsupported,
        'unsupported_platform',
      );
    }
    try {
      final map = await _methods.invokeMapMethod<Object?, Object?>(method, args);
      if (map == null) throw const FormatException('Missing native status.');
      return G2cBleStatus.fromMap(map);
    } on MissingPluginException {
      return G2cBleStatus.unavailable(
        G2cLinkState.channelUnavailable,
        'native_service_unavailable',
      );
    } on PlatformException catch (error) {
      return G2cBleStatus.unavailable(
        G2cLinkState.connectionFailed,
        error.code,
      );
    } on FormatException {
      return G2cBleStatus.unavailable(
        G2cLinkState.connectionFailed,
        'invalid_native_status',
      );
    } on TypeError {
      return G2cBleStatus.unavailable(
        G2cLinkState.connectionFailed,
        'invalid_native_status',
      );
    }
  }

  G2cBleStatus _decode(Object? event) {
    if (event is! Map) {
      return G2cBleStatus.unavailable(
        G2cLinkState.connectionFailed,
        'invalid_native_event',
      );
    }
    try {
      return G2cBleStatus.fromMap(Map<Object?, Object?>.from(event));
    } on FormatException {
      return G2cBleStatus.unavailable(
        G2cLinkState.connectionFailed,
        'invalid_native_event',
      );
    } on TypeError {
      return G2cBleStatus.unavailable(
        G2cLinkState.connectionFailed,
        'invalid_native_event',
      );
    }
  }
}
