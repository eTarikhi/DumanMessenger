import 'dart:convert' show latin1;
import 'dart:typed_data';

import 'package:duman_mesh_sim/mesh_sim.dart';
import 'package:test/test.dart';

/// The transport seam (`skills/01`, roadmap Phase 1 item 15) and its reference
/// implementation.
///
/// These tests are about the *decisions* the seam makes, not about the mesh: which radio a
/// payload rides, what a scan is allowed to report, when a connection is refused rather than
/// attempted, and what arrives on the receive stream. The engine's own behaviour is covered
/// everywhere else in this directory.
void main() {
  /// Two or three nodes 20 m apart on an empty field, inside the 31.6 m line-of-sight
  /// budget, so every node hears every other and the only variable is the transport.
  MeshSimulation lineWorld({int n = 3, bool dutyCycle = false}) {
    final sim = MeshSimulation(SimConfig(
      nodeCount: n,
      stationaryRatio: 1.0,
      chargingRatio: 0.0,
      trafficIntervalMs: 0,
      enableSuperElection: false,
      warmupMs: 0,
      obstacles: const <Obstacle>[],
      dutyCycleEnabled: dutyCycle,
    ));
    for (var i = 0; i < sim.nodes.length; i++) {
      final node = sim.nodes[i];
      node.pos = Vec2(10.0 + i * 20, 10);
      node.target = Vec2(10.0 + i * 20, 10);
      node.mobility = 0;
      node.isOnline = true;
      node.battery = 1.0;
    }
    sim.runFor(20000); // beacons settle, routes form
    sim.clearRecords();
    return sim;
  }

  bool runUntil(MeshSimulation sim, bool Function() done, double budgetMs) {
    var elapsed = 0.0;
    while (!done() && elapsed < budgetMs) {
      sim.runFor(100);
      elapsed += 100;
    }
    return done();
  }

  Uint8List bytes(int n, [int fill = 0x61]) =>
      Uint8List.fromList(List<int>.filled(n, fill));

  Matcher failsWith(TransportFailure f) => throwsA(
      isA<TransportException>().having((e) => e.failure, 'failure', f));

  group('MeshTransport — startAdvertising', () {
    test('puts a 12-byte beacon on air, and refreshing replaces it', () async {
      final sim = lineWorld(n: 2);
      final a = SimulatedMeshTransport(sim, sim.nodes[0].id);
      expect(a.advertisement, isNull);

      const digest = 0x1122334455667788;
      await a.startAdvertising(AdvertPayload(localId: a.localId, dbHash: digest));
      final adv = a.advertisement!;
      final beacon = adv.beacon;

      // skills/01: "12B beacon + service UUID". The UUID is what a scanner filters on, so it
      // travels with the payload rather than being baked into the implementation.
      expect(beacon.lengthInBytes, equals(AdvertPayload.beaconBytes));
      expect(beacon.lengthInBytes, equals(12));
      expect(adv.serviceUuid, equals(dumanMeshServiceUuid));

      // Big-endian, which is the part that has to be fixed before either platform bridge
      // exists: a beacon that reads differently on Android and iOS matches nobody.
      final view = ByteData.view(beacon.buffer);
      expect(view.getUint32(0, Endian.big), equals(0x11223344));
      expect(view.getUint32(4, Endian.big), equals(0x55667788));
      expect(view.getUint32(8, Endian.big), equals(beaconIdHash(a.localId)));

      // Two devices holding the same database agree on the digest and differ on the id —
      // which is the whole use of the beacon: recognise the peer, then compare 8 bytes to
      // learn whether it has anything you are missing, without either side sending a list.
      final b = SimulatedMeshTransport(sim, sim.nodes[1].id);
      await b.startAdvertising(AdvertPayload(localId: b.localId, dbHash: digest));
      final bBeacon = b.advertisement!.beacon;
      expect(bBeacon.sublist(0, 8), equals(beacon.sublist(0, 8)));
      expect(bBeacon.sublist(8), isNot(equals(beacon.sublist(8))));

      // Idempotent: a device advertises, it does not accumulate advertisements.
      await a.startAdvertising(AdvertPayload(localId: a.localId, dbHash: 1));
      expect(a.advertisement!.dbHash, equals(1));
      expect(a.advertisement!.beacon.sublist(0, 8), isNot(equals(beacon.sublist(0, 8))));

      await a.stop();
      expect(a.advertisement, isNull);
      // Stopping twice is ordinary, not an error: an app calls stop() from a lifecycle
      // callback it does not control the ordering of.
      await a.stop();
      await b.stop();
    });

    test('refuses to advertise once stopped', () async {
      final sim = lineWorld(n: 2);
      final t = SimulatedMeshTransport(sim, sim.nodes[0].id);
      await t.stop();
      await expectLater(
          t.startAdvertising(AdvertPayload(localId: t.localId, dbHash: 0)),
          failsWith(TransportFailure.closed));
    });
  });

  group('MeshTransport — scan', () {
    test('reports what this device heard, not what the geometry says', () async {
      final sim = lineWorld(n: 3);
      final t = SimulatedMeshTransport(sim, sim.nodes[0].id);
      final sightings = <Peer>[];
      t.scan().listen(sightings.add);

      t.advance(5000);

      // node-0 hears node-1 at 20 m but not node-2 at 40 m, past the 31.6 m line-of-sight
      // budget. A scan that reported node-2 would be reporting the world rather than the
      // measurement.
      final heard = sightings.map((p) => p.id).toSet();
      expect(heard, equals(<PeerId>{sim.nodes[1].id}));
      expect(heard.contains(sim.nodes[2].id), isFalse);
      expect(peersInRange(sim.nodes[0], sim.nodes, sim.rf).length, equals(1));
      expect(t.heardPeers, equals(heard));

      // skills/01 asks for rssi and txPower on the peer. Both come from the engine's own
      // model rather than from anything invented for the UI, so what an app would estimate
      // distance from is what the link loss is actually computed with.
      final p = sightings.first;
      expect(p.rssiDbm, equals(rssiModel(sim.nodes[0], sim.nodes[1], sim.rf)));
      expect(p.rssiDbm, lessThan(0));
      expect(p.txPowerDbm, equals(sim.nodes[1].txPower));
      expect(p.name, equals(sim.nodes[1].name));
      expect(p.at, equals(sim.now));

      // A stream of sightings, not a polled list: each poll that still hears the peer emits
      // again, with a fresh rssi and timestamp, which is how a consumer ages peers out
      // without the transport deciding how long a peer stays valid.
      sightings.clear();
      t.advance(5000);
      expect(sightings.length, equals(1));
      expect(t.lastSeen(sim.nodes[1].id)?.at, equals(sim.now));
      expect(t.lastSeen(sim.nodes[2].id), isNull);
    });

    test('drops a peer that leaves, and its link with it', () async {
      final sim = lineWorld(n: 2);
      final t = SimulatedMeshTransport(sim, sim.nodes[0].id);
      t.advance(5000);

      final peer = sim.nodes[1].id;
      final conn = await t.connect(peer);
      expect(t.openLinks, contains(peer));

      // Walk the peer out of range. The scan has to notice on its own cycle, which is the
      // part an app cannot fake: on hardware the peer simply stops being heard.
      sim.nodes[1].pos = Vec2(500, 500);
      sim.nodes[1].target = Vec2(500, 500);
      t.advance(20000);

      expect(t.heardPeers, isNot(contains(peer)));
      expect(t.openLinks, isNot(contains(peer)));
      expect(t.lastSeen(peer), isNull);
      await expectLater(t.connect(peer), failsWith(TransportFailure.notHeard));
      // And a write down the link that was open when the peer left fails rather than
      // silently succeeding into nothing. It reports `disconnected` and not `notHeard`: the
      // scan already dropped the link, so the specific thing wrong is that this Connection is
      // stale, and "reconnect" is different advice from "the peer is out of range". `notHeard`
      // is what a write gets in the window between the peer leaving and the next poll, when
      // the link has not been dropped yet.
      await expectLater(t.send(conn, bytes(8)), failsWith(TransportFailure.disconnected));
    });

    test('goes quiet once stopped, and leaves the engine running', () async {
      final sim = lineWorld(n: 2);
      final t = SimulatedMeshTransport(sim, sim.nodes[0].id);
      final sightings = <Peer>[];
      t.scan().listen(sightings.add, onDone: () {});
      t.advance(5000);
      expect(sightings, isNotEmpty);

      await t.stop();
      sightings.clear();
      final before = sim.now;
      t.advance(5000);
      expect(sightings, isEmpty);
      expect(t.heardPeers, isEmpty);
      // The clock belongs to the engine, not to the transport: stopping one device does not
      // stop the mesh.
      expect(sim.now, greaterThan(before));
    });
  });

  group('MeshTransport — connect and send', () {
    test('refuses a peer the local scan has not reported', () async {
      final sim = lineWorld(n: 3);
      final t = SimulatedMeshTransport(sim, sim.nodes[0].id);
      t.advance(5000);

      // node-2 is in the world and online, and node-0 has never heard it. Reaching it anyway
      // would hand the app an oracle it would then depend on.
      expect(sim.nodes[2].isOnline, isTrue);
      await expectLater(
          t.connect(sim.nodes[2].id), failsWith(TransportFailure.notHeard));

      // An id that is not a node at all is refused the same way rather than throwing
      // something the app has not been told to catch.
      await expectLater(
          t.connect('node-does-not-exist'), failsWith(TransportFailure.notHeard));

      final conn = await t.connect(sim.nodes[1].id);
      // Discovery always opens on BLE: that is the radio which found the peer.
      expect(conn.transport, equals(TransportType.ble));
      expect(conn.peerId, equals(sim.nodes[1].id));
      expect(conn.openedAt, equals(sim.now));
    });

    test('refuses to send when this device\'s own radio is gone', () async {
      final sim = lineWorld(n: 2);
      final t = SimulatedMeshTransport(sim, sim.nodes[0].id);
      t.advance(5000);
      final conn = await t.connect(sim.nodes[1].id);

      sim.nodes[0].isOnline = false;
      await expectLater(t.send(conn, bytes(16)), failsWith(TransportFailure.offline));
      await expectLater(
          t.connect(sim.nodes[1].id), failsWith(TransportFailure.offline));

      // A transport bound to an id the engine does not know about refuses rather than
      // crashing, and its scan never opens.
      final ghost = SimulatedMeshTransport(sim, 'node-ghost');
      ghost.advance(1000);
      expect(ghost.heardPeers, isEmpty);
      await expectLater(
          ghost.connect(sim.nodes[1].id), failsWith(TransportFailure.notHeard));
    });

    test('sizes the radio on the packet, crossing to Wi-Fi Direct at 930 bytes of body',
        () async {
      final sim = lineWorld(n: 2);
      final t = SimulatedMeshTransport(sim, sim.nodes[0].id);
      t.advance(5000);
      final conn = await t.connect(sim.nodes[1].id);

      // docs/07 §3: encryption adds 95 B and padding rounds up to a 256 B block, so a
      // 929-byte body is a 1024 B packet that still rides BLE. The "64 + 4 per character"
      // heuristic this replaced crossed at 241 characters and put long texts on Wi-Fi Direct
      // about four times too early — which matters because transport is what sets per-hop
      // latency in this model.
      expect(t.transportFor(929), equals(TransportType.ble));
      expect(wireSizeOf(929), equals(1024));
      expect(t.transportFor(930), equals(TransportType.wifiDirect));
      expect(wireSizeOf(930), equals(1280));

      // And the payload survives the trip exactly: the engine models a body as characters,
      // so the seam has to hand it something that round-trips byte for byte.
      final payload = bytes(929);
      final before = sim.sentRecords.length;
      await t.send(conn, payload);
      expect(sim.sentRecords.length, equals(before + 1));
      final rec = sim.sentRecords.last;
      expect(latin1.encode(rec.body), equals(payload));
      expect(runUntil(sim, () => sim.deliveries.any((d) => d.msgId == rec.msgId), 30000),
          isTrue);
      expect(sim.deliveries.firstWhere((d) => d.msgId == rec.msgId).hops, equals(1));
    });

    test('delivers to onReceive what the peer sent, once, and nothing else', () async {
      final sim = lineWorld(n: 2);
      final a = SimulatedMeshTransport(sim, sim.nodes[0].id);
      final b = SimulatedMeshTransport(sim, sim.nodes[1].id);
      // `a` drives the shared clock; `b` only polls, so the engine advances once per step
      // rather than twice.
      void step(double ms) {
        a.advance(ms);
        b.advance(0);
      }

      step(5000);
      final connA = await a.connect(sim.nodes[1].id);
      final connB = await b.connect(sim.nodes[0].id);

      final got = <Uint8List>[];
      a.onReceive(connA).listen(got.add);

      await b.send(connB, latin1.encode('hello'));
      step(10000);
      expect(got.length, equals(1));
      expect(latin1.decode(got.first), equals('hello'));

      // Polling again does not redeliver: an app that saw the same message twice would show
      // it twice, and nothing above this seam can tell the difference.
      step(10000);
      expect(got.length, equals(1));

      // A second message does arrive, so the deduplication is not simply a stream that
      // closed after one event.
      await b.send(connB, latin1.encode('again'));
      step(10000);
      expect(got.length, equals(2));
      expect(latin1.decode(got.last), equals('again'));

      await a.stop();
      await b.stop();
    });

    test('the receive stream is per connection, not per transport', () async {
      final sim = lineWorld(n: 3);
      // Bring node-2 inside node-0's range so one device has two links to tell apart. In the
      // spawned line node-0 hears only node-1, and a single link cannot show that the streams
      // are per connection rather than per transport.
      sim.nodes[2].pos = Vec2(25, 10);
      sim.nodes[2].target = Vec2(25, 10);

      final a = SimulatedMeshTransport(sim, sim.nodes[0].id);
      final b = SimulatedMeshTransport(sim, sim.nodes[1].id);
      final c = SimulatedMeshTransport(sim, sim.nodes[2].id);
      // `a` drives the shared clock; the others only poll, so the engine advances once per
      // step rather than three times.
      void step(double ms) {
        a.advance(ms);
        b.advance(0);
        c.advance(0);
      }

      step(20000);
      expect(a.heardPeers.length, equals(2));

      final toB = await a.connect(sim.nodes[1].id);
      final toC = await a.connect(sim.nodes[2].id);
      final fromB = <Uint8List>[];
      final fromC = <Uint8List>[];
      a.onReceive(toB).listen(fromB.add);
      a.onReceive(toC).listen(fromC.add);

      final bToA = await b.connect(sim.nodes[0].id);
      final cToA = await c.connect(sim.nodes[0].id);
      await b.send(bToA, latin1.encode('from-b'));
      await c.send(cToA, latin1.encode('from-c'));
      step(20000);

      // Each payload lands on its own peer's stream and on nobody else's. A transport-wide
      // stream would hand the app both and leave it to work out who said what — which is the
      // work a GATT characteristic or an MCSession does per link, so the seam does it here.
      expect(fromB.map((u) => latin1.decode(u)).toList(), equals(<String>['from-b']));
      expect(fromC.map((u) => latin1.decode(u)).toList(), equals(<String>['from-c']));

      await a.stop();
      await b.stop();
      await c.stop();
    });
  });

  group('MeshTransport — bulk transfer', () {
    test('carries a file in chunks, each sized on its own radio', () async {
      final sim = lineWorld(n: 2);
      final t = SimulatedMeshTransport(sim, sim.nodes[0].id);
      t.advance(5000);
      final conn = await t.connect(sim.nodes[1].id);

      final h = await t.transfer(conn, 1048576);
      expect(h.chunks, equals(16)); // 1 MB at the 64 KB default
      // A chunk is what rides the radio, not the file: 64 KB is far past the 1 KB ceiling.
      expect(h.transport, equals(TransportType.wifiDirect));
      expect(h.chunkBytes, equals(sim.config.transferChunkBytes));

      var p = t.progressOf(h.id);
      expect(p, isNotNull);
      expect(p!.complete, isFalse);
      expect(p.chunksReceived, lessThan(p.chunks));

      expect(runUntil(sim, () => t.progressOf(h.id)!.complete, 300000), isTrue);
      p = t.progressOf(h.id)!;
      expect(p.chunksReceived, equals(p.chunks));
      expect(p.chunksSent, equals(p.chunks));
      expect(p.elapsedMs, greaterThan(0));

      // Unknown id is null rather than an exception: a caller polls, and "no such transfer"
      // is an ordinary answer.
      expect(t.progressOf('no-such-transfer'), isNull);
    });

    test('refuses an over-ceiling file with a reason an app can show', () async {
      final sim = lineWorld(n: 2);
      final t = SimulatedMeshTransport(sim, sim.nodes[0].id);
      t.advance(5000);
      final conn = await t.connect(sim.nodes[1].id);

      // skills/05: "Max 10 MB". The engine refuses rather than attempting it, and the seam
      // passes that refusal through instead of inventing a success — and says which refusal
      // it was, because "too large" and "peer left" need different messages.
      await expectLater(t.transfer(conn, 64 * 1024 * 1024),
          failsWith(TransportFailure.tooLarge));
      expect(sim.transfers, isEmpty);
    });
  });

  group('MeshTransport — the seam is inert', () {
    test('adds no randomness of its own, so the golden contract still holds', () async {
      // The cross-language contract is that new state is derived and never drawn. The
      // adapter reads the engine and calls its existing methods, so a world driven through
      // the seam and the same world driven by hand must agree on every packet. If this ever
      // fails, the seam has started consuming random numbers and the golden vectors in both
      // engines move with it.
      final bodies = <String>['a', 'bb', 'ccc', 'dddd', 'eeeee'];

      final plain = lineWorld(n: 3);
      for (final b in bodies) {
        plain.sendMessage(plain.nodes[0].id, plain.nodes[1].id, b);
        plain.runFor(1500);
      }
      plain.runFor(20000);

      final driven = lineWorld(n: 3);
      final t = SimulatedMeshTransport(driven, driven.nodes[0].id);
      t.advance(0); // poll only: the clock does not move
      final conn = await t.connect(driven.nodes[1].id);
      for (final b in bodies) {
        await t.send(conn, Uint8List.fromList(latin1.encode(b)));
        t.advance(1500);
      }
      t.advance(20000);

      expect(driven.deliveries.length, equals(plain.deliveries.length));
      expect(driven.deliveries.map((d) => d.hops).toList(),
          equals(plain.deliveries.map((d) => d.hops).toList()));
      expect(driven.deliveries.map((d) => d.latencyMs).toList(),
          equals(plain.deliveries.map((d) => d.latencyMs).toList()));
      expect(driven.sentRecords.map((r) => r.body).toList(),
          equals(plain.sentRecords.map((r) => r.body).toList()));
      expect(driven.now, equals(plain.now));
      for (var i = 0; i < plain.nodes.length; i++) {
        expect(driven.nodes[i].peerIds, equals(plain.nodes[i].peerIds));
        expect(driven.nodes[i].battery, equals(plain.nodes[i].battery));
        expect(driven.nodes[i].role, equals(plain.nodes[i].role));
      }
    });

    test("the peer set it reports is always the device's own scan result", () async {
      // The invariant that makes this a measurement rather than an oracle, checked at every
      // poll of a run in which the device really does fall asleep: whatever the transport
      // believes it can hear is exactly `node.peerIds`, which the engine refreshes on the
      // scan cycle and leaves stale while a NORMAL node sleeps (skills/07: 3 s of scanning in
      // every 10 s). Reading `peersInRange` here instead would pass this test too, and would
      // then let an app depend on knowing a peer is in range before it has been heard.
      final sim = lineWorld(n: 3, dutyCycle: true);
      final t = SimulatedMeshTransport(sim, sim.nodes[0].id);
      final me = sim.nodes[0];
      var sawSleep = false;

      for (var i = 0; i < 60; i++) {
        if (i == 20) {
          // A peer walks into range. The geometry knows the instant it moves; the device
          // only knows at its next scan, and if it is asleep that is a whole cycle later.
          // Three stationary nodes would never produce that gap on their own, so without
          // this the staleness assertion below could not fail and would prove nothing.
          sim.nodes[2].pos = Vec2(25, 10);
          sim.nodes[2].target = Vec2(25, 10);

          // Poll before the engine has had a chance to rescan — `advance(0)` moves no clock
          // — which is the only instant the two can be caught disagreeing.
          t.advance(0);
          expect(t.heardPeers, equals(me.peerIds.toSet()));
          final truth = peersInRange(me, sim.nodes, sim.rf).map((n) => n.id).toSet();
          expect(truth, contains(sim.nodes[2].id));
          expect(t.heardPeers, isNot(contains(sim.nodes[2].id)));
        }
        t.advance(1000);
        expect(t.heardPeers, equals(me.peerIds.toSet()));
        if (!sim.isAwake(me)) sawSleep = true;
      }

      // If the device never slept the run says nothing about staleness, so assert the thing
      // that makes it interesting actually happened.
      expect(sawSleep, isTrue);
      // And the gap closes: a scan that is permanently behind is not stale, it is broken.
      expect(t.heardPeers, contains(sim.nodes[2].id));
    });
  });
}
