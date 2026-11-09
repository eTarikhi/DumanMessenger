import 'package:duman_messenger/ble/g2c_ble_status.dart';
import 'package:flutter_test/flutter_test.dart';

Map<Object?, Object?> _map([Map<Object?, Object?> extra = const <Object?, Object?>{}]) =>
    <Object?, Object?>{
      'testOnly': true,
      'state': 'service_ready',
      'authenticated': false,
      'permissionState': 'granted',
      'permissionNames': <Object?>[],
      'discoveredPeerIds': <Object?>[],
      ...extra,
    };

void main() {
  test('parses TEST-ONLY transport diagnostics and a received frame', () {
    final status = G2cBleStatus.fromMap(_map(<Object?, Object?>{
      'advertiserAvailable': false,
      'scannerAvailable': true,
      'activeRole': 'server',
      'serverRunning': true,
      'serverClientConnected': true,
      'serverSubscriptionReady': true,
      'transportOutcome': 'received',
      'transportOutcomeDetail': null,
      'receivedFrameCount': 3,
      'lastReceivedFrameRole': 'server',
      'lastReceivedFrameType': 1,
      'lastReceivedFrameBytes': 5,
      'lastReceivedFramePreview': '68656c6c6f',
    }));

    expect(status.state, G2cLinkState.serviceReady);
    expect(status.authenticated, isFalse);
    expect(status.testOnly, isTrue);
    expect(status.advertiserAvailable, isFalse);
    expect(status.scannerAvailable, isTrue);
    expect(status.activeRole, 'server');
    expect(status.serverRunning, isTrue);
    expect(status.serverClientConnected, isTrue);
    expect(status.serverSubscriptionReady, isTrue);
    expect(status.transportOutcome, G2cTransportOutcome.received);
    expect(status.receivedFrameCount, 3);
    expect(status.lastReceivedFrame, isNotNull);
    expect(status.lastReceivedFrame!.role, 'server');
    expect(status.lastReceivedFrame!.type, 1);
    expect(status.lastReceivedFrame!.payloadBytes, 5);
    expect(status.lastReceivedFrame!.payloadPreview, '68656c6c6f');
  });

  test('defaults transport diagnostics to none when the native fields are absent', () {
    final status = G2cBleStatus.fromMap(_map());

    expect(status.transportOutcome, G2cTransportOutcome.none);
    expect(status.receivedFrameCount, 0);
    expect(status.lastReceivedFrame, isNull);
    expect(status.serverClientConnected, isFalse);
    expect(status.serverSubscriptionReady, isFalse);
    expect(status.activeRole, isNull);
    expect(status.advertiserAvailable, isNull);
    expect(status.scannerAvailable, isNull);
  });

  test('parses each distinct transport outcome', () {
    const expected = <String, G2cTransportOutcome>{
      'none': G2cTransportOutcome.none,
      'queued': G2cTransportOutcome.queued,
      'received': G2cTransportOutcome.received,
      'busy': G2cTransportOutcome.busy,
      'transport_unavailable': G2cTransportOutcome.transportUnavailable,
      'disconnected': G2cTransportOutcome.disconnected,
      'malformed_frame': G2cTransportOutcome.malformedFrame,
      'timed_out': G2cTransportOutcome.timedOut,
      'permission_denied': G2cTransportOutcome.permissionDenied,
      'transport_failure': G2cTransportOutcome.transportFailure,
    };
    expected.forEach((wire, outcome) {
      final status = G2cBleStatus.fromMap(_map(<Object?, Object?>{
        'transportOutcome': wire,
      }));
      expect(status.transportOutcome, outcome, reason: wire);
    });
  });

  test('rejects an unknown transport outcome', () {
    expect(
      () => G2cBleStatus.fromMap(_map(<Object?, Object?>{
        'transportOutcome': 'delivered',
      })),
      throwsFormatException,
    );
  });

  test('rejects malformed received frame metadata', () {
    expect(
      () => G2cBleStatus.fromMap(_map(<Object?, Object?>{
        'lastReceivedFrameRole': 'server',
        'lastReceivedFrameType': 0,
        'lastReceivedFrameBytes': 5,
        'lastReceivedFramePreview': '68656c6c6f',
      })),
      throwsFormatException,
    );
    expect(
      () => G2cBleStatus.fromMap(_map(<Object?, Object?>{
        'lastReceivedFrameRole': 'peer',
        'lastReceivedFrameType': 1,
        'lastReceivedFrameBytes': 5,
        'lastReceivedFramePreview': '68656c6c6f',
      })),
      throwsFormatException,
    );
    expect(
      () => G2cBleStatus.fromMap(_map(<Object?, Object?>{
        'lastReceivedFrameRole': 'server',
        'lastReceivedFrameType': 1,
        'lastReceivedFrameBytes': 513,
        'lastReceivedFramePreview': '68',
      })),
      throwsFormatException,
    );
  });

  test('rejects an unknown active role and a negative receive count', () {
    expect(
      () => G2cBleStatus.fromMap(_map(<Object?, Object?>{
        'activeRole': 'peripheral',
      })),
      throwsFormatException,
    );
    expect(
      () => G2cBleStatus.fromMap(_map(<Object?, Object?>{
        'receivedFrameCount': -1,
      })),
      throwsFormatException,
    );
  });

  test('parses bounded transport diagnostics in order', () {
    final status = G2cBleStatus.fromMap(_map(<Object?, Object?>{
      'diagnostics': <Object?>[
        <String, Object?>{
          'sequence': 1,
          'code': 'client_connect_attempt',
          'detail': null,
        },
        <String, Object?>{
          'sequence': 2,
          'code': 'client_connection_callback',
          'detail': 'status=0,state=2',
        },
        <String, Object?>{
          'sequence': 3,
          'code': 'client_service_found',
          'detail': null,
        },
      ],
    }));

    expect(status.diagnostics.length, 3);
    expect(status.diagnostics.first.code, 'client_connect_attempt');
    expect(status.diagnostics.first.label, 'client_connect_attempt');
    expect(status.diagnostics[1].detail, 'status=0,state=2');
    expect(status.diagnostics[1].label, 'client_connection_callback (status=0,state=2)');
    expect(status.lastDiagnostic!.code, 'client_service_found');
  });

  test('defaults diagnostics to empty when the native field is absent', () {
    final status = G2cBleStatus.fromMap(_map());

    expect(status.diagnostics, isEmpty);
    expect(status.lastDiagnostic, isNull);
  });

  test('rejects malformed diagnostic entries', () {
    for (final bad in <Object?>[
      'not-a-list',
      <Object?>['not-a-map'],
      <Object?>[
        <String, Object?>{'sequence': -1, 'code': 'x', 'detail': null},
      ],
      <Object?>[
        <String, Object?>{'sequence': 1, 'code': '', 'detail': null},
      ],
      <Object?>[
        <String, Object?>{'sequence': 1, 'code': 'x', 'detail': 5},
      ],
      <Object?>[
        <String, Object?>{'sequence': 1, 'code': 'x' * 49, 'detail': null},
      ],
    ]) {
      expect(
        () => G2cBleStatus.fromMap(_map(<Object?, Object?>{'diagnostics': bad})),
        throwsFormatException,
      );
    }
  });

  test('rejects an unbounded diagnostic list', () {
    final tooMany = List<Object?>.generate(
      49,
      (index) => <String, Object?>{
        'sequence': index,
        'code': 'event_$index',
        'detail': null,
      },
    );
    expect(
      () => G2cBleStatus.fromMap(_map(<Object?, Object?>{'diagnostics': tooMany})),
      throwsFormatException,
    );
  });

  test('still rejects any authentication claim', () {
    expect(
      () => G2cBleStatus.fromMap(<Object?, Object?>{
        ..._map(),
        'authenticated': true,
      }),
      throwsFormatException,
    );
    expect(
      () => G2cBleStatus.fromMap(<Object?, Object?>{
        ..._map(),
        'state': 'authenticated',
      }),
      throwsFormatException,
    );
  });
}
