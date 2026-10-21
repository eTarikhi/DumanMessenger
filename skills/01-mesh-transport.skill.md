# Skill 01 — Mesh Discovery & Transport

**Goal:** Two or more phones discover each other offline and exchange bytes via the best available radio.

### Interfaces (Dart)
```dart
abstract class MeshTransport {
  Future<void> startAdvertising(AdvertPayload payload); // 12B beacon + service UUID
  Stream<Peer> scan(); // discovered peers with rssi, txPower
  Future<Connection> connect(PeerId id);
  Future<void> send(Connection c, Uint8List bytes); // reliable
  Stream<Uint8List> onReceive(Connection c);
  Future<void> stop();
}
enum TransportType { bleGatt, wifiDirect, wifiAware, multipeer }
```

### Concrete impls
- `BleGattTransportAndroid` (Kotlin): `BluetoothLeAdvertiser` + `BluetoothGattServer` + `BluetoothLeScanner` (low latency scan mode when SUPER, low power when NORMAL)
- `BleGattTransportIos` (Swift): `CBPeripheralManager` + `CBCentralManager` with service UUID `DUMAN_MESH_SVC`
- `WifiDirectTransportAndroid`: `WifiP2pManager.createGroup` (when SUPER) / `discoverPeers` + `connect` + `SocketChannel`
- `MultipeerTransportIos`: `MCSession` + `MCNearbyServiceAdvertiser/Browser`

### Do / Don't
- DO use **MethodChannel/EventChannel** bridge, keep scan logic native, expose normalized `Peer` to Dart [1](https://uynguyen.github.io/2026/03/14/Best-practice-BLE-cross-platform-iOS-Flutter-ReactNative/)
- DO handle Android BLE quirks: stop scan before connect, 500 ms delay, 5 scans/30s limit [2](https://www.silabs.com/documents/public/application-notes/an1200-0-bluetooth-mesh-1x-for-android-and-ios-adk.pdf)
- DON'T use BLE Mesh spec (Nordic lib) — phones are proxy-only [3](https://argenox.com/blog/10-reasons-why-ble-mesh-has-struggled-to-gain-traction); build GATT-based mesh

### Acceptance
- [ ] 2 Android phones: discover in <3s, exchange 1 KB over BLE GATT
- [ ] Android ↔ iOS: discover via BLE, exchange text
- [ ] WiFi Direct: 2 Android phones transfer 5 MB file >10 Mbps when SUPER forms group
- [ ] No GMS device still discovers via raw BLE

### Metrics
`discoveryLatency, rssiStability, bytesPerSecPerTransport, permissionDenialRate`
