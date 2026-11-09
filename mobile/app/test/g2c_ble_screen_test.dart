import 'package:duman_messenger/ble/g2c_ble_bridge.dart';
import 'package:duman_messenger/ble/g2c_ble_status.dart';
import 'package:duman_messenger/screens/g2c_ble_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'renders all G2-C test sections for empty candidates and unknown BLE status',
    (tester) async {
      final api = _UnavailableG2cBleApi();
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
      expect(api.operations, isEmpty);
    },
  );
}

class _UnavailableG2cBleApi implements G2cBleApi {
  final List<String> operations = <String>[];
  final G2cBleStatus _unavailable = G2cBleStatus.unavailable(
    G2cLinkState.unsupported,
    'unsupported_platform',
  );

  void close() => operations.clear();

  @override
  Future<G2cBleStatus> refresh() async => _unavailable;

  @override
  Future<G2cBleStatus> startDiscovery() async {
    operations.add('startDiscovery');
    return _unavailable;
  }

  @override
  Future<G2cBleStatus> stopDiscovery() async {
    operations.add('stopDiscovery');
    return _unavailable;
  }

  @override
  Future<G2cBleStatus> connect(String peerId) async {
    operations.add('connect');
    return _unavailable;
  }

  @override
  Future<G2cBleStatus> disconnect() async {
    operations.add('disconnect');
    return _unavailable;
  }

  @override
  Future<G2cBleStatus> startServer() async {
    operations.add('startServer');
    return _unavailable;
  }

  @override
  Future<G2cBleStatus> stopServer() async {
    operations.add('stopServer');
    return _unavailable;
  }

  @override
  Future<G2cBleStatus> openPermissionSettings() async => _unavailable;

  @override
  Future<G2cBleStatus> sendTestFrame(int type, List<int> payload) async =>
      _unavailable;

  @override
  Stream<G2cBleStatus> watchStatus() => Stream<G2cBleStatus>.empty();
}
