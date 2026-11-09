import 'dart:async';

import 'package:duman_messenger/ble/g2c_ble_bridge.dart';
import 'package:duman_messenger/ble/g2c_ble_status.dart';
import 'package:duman_messenger/screens/g2c_ble_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'renders all G2-C test sections for empty candidates and unknown BLE status',
    (tester) async {
      final api = _FakeG2cBleApi(
        G2cBleStatus.unavailable(
          G2cLinkState.unsupported,
          'unsupported_platform',
        ),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(home: G2cBleScreen(bridge: api)),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('G2-C BLE — TEST ONLY'), findsOneWidget);
      expect(find.textContaining('TEST ONLY. A BLE connection'), findsOneWidget);
      expect(find.text('Capability and permissions'), findsOneWidget);
      expect(find.text('Discovery'), findsOneWidget);
      expect(find.text('Connection and GATT server'), findsOneWidget);
      expect(find.text('Test frame (unauthenticated)'), findsOneWidget);
      expect(find.text('No candidates currently discovered.'), findsOneWidget);
      expect(find.text('Unknown'), findsWidgets);
      expect(_text(tester, const Key('g2c-transport-outcome')),
          'No send or receive yet');
      expect(_text(tester, const Key('g2c-received-count')), '0');
      expect(api.operations, isEmpty);
    },
  );

  testWidgets('keeps send disabled without any ready transport', (tester) async {
    final api = _FakeG2cBleApi(_status());
    addTearDown(api.close);

    await tester.pumpWidget(MaterialApp(home: G2cBleScreen(bridge: api)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(_sendButton(tester).onPressed, isNull);
  });

  testWidgets('enables client sending only for a ready central GATT link',
      (tester) async {
    final api = _FakeG2cBleApi(
      _status(
        state: G2cLinkState.connectedUnauthenticated,
        activeRole: 'client',
      ),
    );
    addTearDown(api.close);

    await tester.pumpWidget(MaterialApp(home: G2cBleScreen(bridge: api)));
    await tester.pumpAndSettle();
    expect(_sendButton(tester).onPressed, isNull);

    api.publish(
      _status(state: G2cLinkState.serviceReady, activeRole: 'client'),
    );
    await tester.pumpAndSettle();
    expect(_sendButton(tester).onPressed, isNotNull);
  });

  testWidgets('requires a connected and subscribed client for server sending',
      (tester) async {
    final api = _FakeG2cBleApi(
      _status(
        serverRunning: true,
        activeRole: 'server',
        serverClientConnected: false,
      ),
    );
    addTearDown(api.close);

    await tester.pumpWidget(MaterialApp(home: G2cBleScreen(bridge: api)));
    await tester.pumpAndSettle();
    expect(_sendButton(tester).onPressed, isNull);

    api.publish(
      _status(
        state: G2cLinkState.connectedUnauthenticated,
        serverRunning: true,
        activeRole: 'server',
        serverClientConnected: true,
        serverSubscriptionReady: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(_sendButton(tester).onPressed, isNull);

    api.publish(
      _status(
        state: G2cLinkState.serviceReady,
        serverRunning: true,
        activeRole: 'server',
        serverClientConnected: true,
        serverSubscriptionReady: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(_sendButton(tester).onPressed, isNotNull);

    await tester.ensureVisible(find.byKey(const Key('g2c-send-test-frame')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('g2c-send-test-frame')));
    await tester.pumpAndSettle();
    expect(api.sendCount, 1);
  });

  testWidgets('shows queued transport separately from an actually received frame',
      (tester) async {
    final api = _FakeG2cBleApi(
      _status(state: G2cLinkState.serviceReady, activeRole: 'client'),
    );
    api.sendResult = _status(
      state: G2cLinkState.serviceReady,
      activeRole: 'client',
      transportOutcome: G2cTransportOutcome.queued,
      transportOutcomeDetail: 'queued_for_transmission',
    );
    addTearDown(api.close);

    await tester.pumpWidget(MaterialApp(home: G2cBleScreen(bridge: api)));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('g2c-send-test-frame')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('g2c-send-test-frame')));
    await tester.pumpAndSettle();

    expect(
      _text(tester, const Key('g2c-transport-outcome')),
      'Queued for transmission — delivery not confirmed',
    );
    expect(find.textContaining('Queued for transmission only'), findsOneWidget);
    expect(find.textContaining('transport evidence only'), findsNothing);
    expect(_text(tester, const Key('g2c-received-count')), '0');

    api.publish(
      _status(
        state: G2cLinkState.serviceReady,
        activeRole: 'client',
        transportOutcome: G2cTransportOutcome.received,
        receivedFrameCount: 2,
        lastReceivedFrame: const G2cReceivedFrame(
          role: 'client',
          type: 1,
          payloadBytes: 5,
          payloadPreview: '68656c6c6f',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_text(tester, const Key('g2c-transport-outcome')), 'Remote frame received');
    expect(_text(tester, const Key('g2c-received-count')), '2');
    expect(_text(tester, const Key('g2c-received-preview')), '68656c6c6f');
    expect(find.textContaining('transport evidence only'), findsOneWidget);
    expect(find.text('GATT client (central)'), findsWidgets);
  });

  testWidgets('shows a malformed frame diagnostic without a layout exception',
      (tester) async {
    final api = _FakeG2cBleApi(
      _status(
        state: G2cLinkState.protocolError,
        errorCode: 'protocol_error',
        activeRole: 'server',
        serverRunning: true,
        transportOutcome: G2cTransportOutcome.malformedFrame,
        transportOutcomeDetail: 'invalid_fragment_header',
      ),
    );
    addTearDown(api.close);

    await tester.pumpWidget(MaterialApp(home: G2cBleScreen(bridge: api)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(_text(tester, const Key('g2c-transport-outcome')),
        'Malformed frame rejected');
    expect(find.text('Outcome detail'), findsOneWidget);
    expect(find.text('invalid_fragment_header'), findsOneWidget);
    expect(find.text('Error: protocol_error'), findsOneWidget);
    expect(_sendButton(tester).onPressed, isNull);
  });

  testWidgets('distinguishes transport unavailable from disconnected',
      (tester) async {
    final api = _FakeG2cBleApi(
      _status(
        transportOutcome: G2cTransportOutcome.transportUnavailable,
        transportOutcomeDetail: 'transport_unavailable',
      ),
    );
    addTearDown(api.close);

    await tester.pumpWidget(MaterialApp(home: G2cBleScreen(bridge: api)));
    await tester.pumpAndSettle();
    expect(_text(tester, const Key('g2c-transport-outcome')),
        'Transport unavailable — nothing sent');

    api.publish(
      _status(
        serverRunning: true,
        activeRole: 'server',
        transportOutcome: G2cTransportOutcome.disconnected,
      ),
    );
    await tester.pumpAndSettle();
    expect(_text(tester, const Key('g2c-transport-outcome')),
        'Disconnected — nothing sent');
    expect(find.text('None'), findsWidgets);
  });

  testWidgets('disables sending after the GATT client disconnects',
      (tester) async {
    final api = _FakeG2cBleApi(
      _status(
        state: G2cLinkState.serviceReady,
        serverRunning: true,
        activeRole: 'server',
        serverClientConnected: true,
        serverSubscriptionReady: true,
        transportOutcome: G2cTransportOutcome.received,
        receivedFrameCount: 1,
        lastReceivedFrame: const G2cReceivedFrame(
          role: 'server',
          type: 1,
          payloadBytes: 2,
          payloadPreview: '6869',
        ),
      ),
    );
    addTearDown(api.close);

    await tester.pumpWidget(MaterialApp(home: G2cBleScreen(bridge: api)));
    await tester.pumpAndSettle();
    expect(_sendButton(tester).onPressed, isNotNull);
    expect(find.text('Connected — unauthenticated'), findsOneWidget);

    api.publish(
      _status(
        state: G2cLinkState.disconnected,
        serverRunning: false,
        transportOutcome: G2cTransportOutcome.disconnected,
        transportOutcomeDetail: 'explicit_disconnect',
        receivedFrameCount: 1,
        lastReceivedFrame: const G2cReceivedFrame(
          role: 'server',
          type: 1,
          payloadBytes: 2,
          payloadPreview: '6869',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_sendButton(tester).onPressed, isNull);
    // Both the GATT server row and the idle discovery row read "Stopped".
    expect(find.text('Stopped'), findsWidgets);
    expect(find.text('Not ready'), findsOneWidget);
    expect(find.text('Disconnected — nothing sent'), findsOneWidget);
    // Reception evidence is historical and is not erased by a later disconnect.
    expect(_text(tester, const Key('g2c-received-count')), '1');
  });

  testWidgets('does not offer the server role when no BLE advertiser exists',
      (tester) async {
    final api = _FakeG2cBleApi(_status(advertiserAvailable: false));
    addTearDown(api.close);

    await tester.pumpWidget(MaterialApp(home: G2cBleScreen(bridge: api)));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Start server'))
          .onPressed,
      isNull,
    );
    expect(
      find.text('Server role unavailable: no BLE advertiser on this device.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('does not expose a BLE advertiser'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Start discovery'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('retains the server role when no BLE scanner exists',
      (tester) async {
    final api = _FakeG2cBleApi(_status(scannerAvailable: false));
    addTearDown(api.close);

    await tester.pumpWidget(MaterialApp(home: G2cBleScreen(bridge: api)));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Start discovery'),
          )
          .onPressed,
      isNull,
    );
    expect(
      find.textContaining('does not expose a BLE scanner'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Start server'))
          .onPressed,
      isNotNull,
    );
  });
}

String _text(WidgetTester tester, Key key) =>
    tester.widget<Text>(find.byKey(key)).data ?? '';

OutlinedButton _sendButton(WidgetTester tester) => tester.widget<OutlinedButton>(
      find.byKey(const Key('g2c-send-test-frame')),
    );

G2cBleStatus _status({
  G2cLinkState state = G2cLinkState.disconnected,
  String? errorCode,
  String? operationError,
  int? apiLevel = 34,
  bool? bleHardwareSupported = true,
  bool? bluetoothEnabled = true,
  bool? connectPermissionGranted = true,
  bool? scanPermissionGranted = true,
  bool? advertisePermissionGranted = true,
  G2cRuntimePermissionState permissionState = G2cRuntimePermissionState.granted,
  G2cDiscoveryState discoveryState = G2cDiscoveryState.idle,
  List<String> discoveredPeerIds = const <String>[],
  bool? advertiserAvailable = true,
  bool? scannerAvailable = true,
  String? activeRole,
  bool serverRunning = false,
  bool serverClientConnected = false,
  bool serverSubscriptionReady = false,
  G2cTransportOutcome transportOutcome = G2cTransportOutcome.none,
  String? transportOutcomeDetail,
  int receivedFrameCount = 0,
  G2cReceivedFrame? lastReceivedFrame,
}) =>
    G2cBleStatus(
      state: state,
      authenticated: false,
      testOnly: true,
      errorCode: errorCode,
      operationError: operationError,
      apiLevel: apiLevel,
      bleHardwareSupported: bleHardwareSupported,
      bluetoothEnabled: bluetoothEnabled,
      connectPermissionGranted: connectPermissionGranted,
      scanPermissionGranted: scanPermissionGranted,
      advertisePermissionGranted: advertisePermissionGranted,
      permissionState: permissionState,
      discoveryState: discoveryState,
      discoveredPeerIds: discoveredPeerIds,
      advertiserAvailable: advertiserAvailable,
      scannerAvailable: scannerAvailable,
      activeRole: activeRole,
      serverRunning: serverRunning,
      serverClientConnected: serverClientConnected,
      serverSubscriptionReady: serverSubscriptionReady,
      transportOutcome: transportOutcome,
      transportOutcomeDetail: transportOutcomeDetail,
      receivedFrameCount: receivedFrameCount,
      lastReceivedFrame: lastReceivedFrame,
    );

class _FakeG2cBleApi implements G2cBleApi {
  _FakeG2cBleApi(this.status);

  G2cBleStatus status;
  G2cBleStatus? sendResult;
  int sendCount = 0;
  final List<String> operations = <String>[];
  final StreamController<G2cBleStatus> _controller =
      StreamController<G2cBleStatus>.broadcast();

  void publish(G2cBleStatus next) {
    status = next;
    _controller.add(next);
  }

  void close() {
    unawaited(_controller.close());
  }

  @override
  Future<G2cBleStatus> refresh() async => status;

  @override
  Future<G2cBleStatus> startDiscovery() async {
    operations.add('startDiscovery');
    return status;
  }

  @override
  Future<G2cBleStatus> stopDiscovery() async {
    operations.add('stopDiscovery');
    return status;
  }

  @override
  Future<G2cBleStatus> connect(String peerId) async {
    operations.add('connect');
    return status;
  }

  @override
  Future<G2cBleStatus> disconnect() async {
    operations.add('disconnect');
    return status;
  }

  @override
  Future<G2cBleStatus> startServer() async {
    operations.add('startServer');
    return status;
  }

  @override
  Future<G2cBleStatus> stopServer() async {
    operations.add('stopServer');
    return status;
  }

  @override
  Future<G2cBleStatus> openPermissionSettings() async => status;

  @override
  Future<G2cBleStatus> sendTestFrame(int type, List<int> payload) async {
    sendCount++;
    operations.add('sendTestFrame');
    final result = sendResult ?? status;
    status = result;
    return result;
  }

  @override
  Stream<G2cBleStatus> watchStatus() => _controller.stream;
}
