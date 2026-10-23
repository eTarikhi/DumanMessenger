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

> **Built (Oct 2026 — `sim/mesh_sim/lib/src/transport.dart`, `test/transport_test.dart`, roadmap Phase 1 item 15):** the interface above is implemented as
> specified — six verbs, same order, same signatures — with `SimulatedMeshTransport` as a reference implementation and a test double, driven by the mesh engine.
> It is pure Dart with no dependency beyond the SDK, so it lifts into the mono-repo's `core/` (item 13) unchanged, and the app layer can be written against it
> before `BleGattTransportAndroid` exists. Ten decisions in it are tested: the 12-byte beacon's byte order and its 8-byte digest, that refreshing an
> advertisement replaces it rather than adding one, that `connect` **refuses a peer the local scan has not reported** even when that peer exists in the world,
> that the radio is sized on the *packet* and per *chunk* (a 929-byte body is a 1024 B packet that still rides BLE; 930 crosses — the threshold `docs/07` §3
> corrected), that `onReceive` is per connection and delivers each payload exactly once, and that the seam consumes **no random numbers**, so a world driven
> through it is byte-identical to the same world driven by hand and the golden vectors hold.
>
> **Two deliberate divergences.** (1) `enum TransportType` is not redeclared: the engine already has `{ ble, wifiDirect, multipeer }` as the data-plane selector
> measured in `docs/07` §3 and `docs/08` §5.3, and it is a field of every `MeshMessage`. Renaming it to `{ bleGatt, ... }` would rewrite the measured record for
> no behaviour, so the mapping is `bleGatt` → `TransportType.ble`, and `wifiAware` is item 307 — a feature-flagged experiment nothing here models. (2) `localId`
> is a getter on the interface, which the listing above omits because a platform transport takes its identity from the device; the seam states it explicitly so a
> caller holding several transports can tell them apart.
>
> **Why `scan` reports what was heard and not what is true.** It reads the device's own scan cycle, which the engine refreshes on the beacon interval and leaves
> stale while a NORMAL node sleeps (item 118's duty cycle, `skills/07`'s 3 s in every 10). It never reads the geometry. A test moves a peer into range mid-run and
> asserts the two disagree at that instant and agree again later, because an implementation that reaches an unheard peer hands the app an oracle — and an app
> built on an oracle passes every test in this repo and then fails on a phone in a pocket. That is also why `connect` throws rather than returning null: `notHeard`,
> `offline`, `disconnected`, `tooLarge` and `closed` need different messages, and a nullable return cannot carry which.
>
> **Not built:** the four concrete impls below, and the MethodChannel/EventChannel bridge. `SimulatedMeshTransport` is a reference and a test double, not a radio.

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
