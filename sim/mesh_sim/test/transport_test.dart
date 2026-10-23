import 'dart:convert' show latin1;
import 'dart:typed_data';

import 'package:duman_mesh_sim/mesh_sim.dart';
import 'package:test/test.dart';

/// The transport seam (roadmap Phase 1 item 15) and its reference implementation.
///
/// These tests are about the *decisions* the seam makes, not about the mesh: which radio a
/// payload rides, what a scan is allowed to report, and when a send is refused. The engine's
/// own behaviour is covered everywhere else in this directory.
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

  group('MeshTransport — advertise', () {
    test('puts a 12-byte beacon on air, and refreshing does not add a second one', () async {
      final sim = lineWorld(n: 2);
      final t = SimulatedMeshTransport(sim, sim.nodes[0].id, dbHash: 0x1122334455667788);
      expect(t.advertising, isFalse);

      final a = await t.advertise();
      expect(a.sizeBytes, equals(12));
      expect(a.localId, equals(sim.nodes[0].id));
      expect(t.advertising, isTrue);

      // The digest is big-endian in the first 8 bytes, which is the part that has to be
      // fixed before either platform bridge exists.
      final view = ByteData.view(a.beacon.buffer);
      expect(view.getUint32(0, Endian.big), equals(0x11223344));
      expect(view.getUint32(4, Endian.big), equals(0x55667788));

      // Idempotent: a device advertises, it does not accumulate advertisements.
      final b = await t.advertise();
      expect(b.sizeBytes, equals(12));
      expect(t.advertisement?.beacon, equals(b.beacon));

      // The id field is a stable function of the node id, so two devices hashing the same
      // id agree — and two different ids do not collide on the first try.
      final other = SimulatedMeshTransport(sim, sim.nodes[1].id);
      final b2 = await other.advertise();
      expect(view.getUint32(8, Endian.big), isNot(equals(0)));
      expect(b2.beacon.sublist(8), isNot(equals(a.beacon.sublist(8))));
      expect(b2.beacon.sublist(0, 8), equals(a.beacon.sublist(0, 8)));

      await t.close();
      expect(t.advertising, isFalse);
      await other.close();
    });
  });

  group('MeshTransport — scan', () {
    test('reports what this device heard, not what the geometry says', () {
      final sim = lineWorld(n: 3);
      final t = SimulatedMeshTransport(sim, sim.nodes[0].id);
      final edges = t.advance(5000);

      // node-0 hears node-1 at 20 m but not node-2 at 40 m, which is past the 31.6 m
      // line-of-sight budget. A scan that reported node-2 would be reporting the world
      // rather than the measurement.
      final found = edges.where((e) => e.found).map((e) => e.peer.id).toSet();
      expect(found, equals(<NodeId>{sim.nodes[1].id}));
      expect(found.contains(sim.nodes[2].id), isFalse);
      expect(peersInRange(sim.nodes[0], sim.nodes, sim.rf).length, equals(1));

      // The reported peer carries a measurement, and it is the same model the engine's link
      // loss uses rather than a number invented for the UI.
      final p = edges.first.peer;
      expect(p.rssiDbm, equals(rssiModel(sim.nodes[0], sim.nodes[1], sim.rf)));
      expect(p.rssiDbm, lessThan(0));
      expect(p.name, equals(sim.nodes[1].name));
    });

    test('emits a lost edge when a peer leaves, and drops its link with it', () async {
      final sim = lineWorld(n: 2);
      final t = SimulatedMeshTransport(sim, sim.nodes[0].id);
      final first = t.advance(5000);
      expect(first.where((e) => e.found).length, equals(1));

      final peer = sim.nodes[1].id;
      final conn = await t.connect(peer);
      expect(conn, isNotNull);
      expect(t.openLinks, contains(peer));

      // Walk the peer out of range. The scan has to notice on its own cycle, which is the
      // part an app cannot fake: on hardware the peer is simply not heard any more.
      sim.nodes[1].pos = Vec2(500, 500);
      sim.nodes[1].target = Vec2(500, 500);
      sim.nodes[1].home = Vec2(500, 500);
      final after = t.advance(20000);

      expect(after.where((e) => !e.found).map((e) => e.peer.id), contains(peer));
      expect(t.openLinks, isNot(contains(peer)));
      expect(await t.connect(peer), isNull);
    });

    test('goes quiet once closed, and keeps the engine running', () {
      final sim = lineWorld(n: 2);
      final t = SimulatedMeshTransport(sim, sim.nodes[0].id);
      t.advance(5000);
      t.close();
      final before = sim.now;
      expect(t.advance(5000), isEmpty);
      expect(sim.now, greaterThan(before)); // the clock is the engine's, not the transport's
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
      expect(await t.connect(sim.nodes[2].id), isNull);

      // An id that is not a node at all is refused the same way rather than throwing.
      expect(await t.connect('node-does-not-exist'), isNull);

      final conn = await t.connect(sim.nodes[1].id);
      expect(conn, isNotNull);
      // Discovery always opens on BLE: that is the radio which found the peer.
      expect(conn!.transport, equals(TransportType.ble));
    });

    test('sizes the radio on the packet, and crosses to Wi-Fi Direct at 930 bytes of body',
        () async {
      final sim = lineWorld(n: 2);
      final t = SimulatedMeshTransport(sim, sim.nodes[0].id);
      t.advance(5000);
      final to = sim.nodes[1].id;

      // docs/07 §3: encryption adds 95 B and padding rounds up to a 256 B block, so a
      // 900-byte body is a 1024 B packet that still rides BLE. The naive "64 + 4 per
      // character" heuristic this replaced crossed at 241 characters and put long texts on
      // Wi-Fi Direct about four times too early — which matters because transport is what
      // sets per-hop latency in this model.
      final just = await t.send(to, bytes(929));
      expect(just.ok, isTrue);
      expect(just.transport, equals(TransportType.ble));
      expect(just.wireBytes, equals(1024));

      final over = await t.send(to, bytes(930));
      expect(over.ok, isTrue);
      expect(over.transport, equals(TransportType.wifiDirect));
      expect(over.wireBytes, equals(1280));

      // And the payload survives the trip exactly: the engine models a body as characters,
      // so the adapter has to hand it something that round-trips byte for byte.
      expect(runUntil(sim, () => sim.deliveries.length >= 2, 30000), isTrue);
      final body = sim.sentRecords.firstWhere((r) => r.msgId == just.messageId).body;
      expect(latin1.encode(body), equals(bytes(929)));
    });

    test('reports a refusal instead of throwing when the local radio is gone', () async {
      final sim = lineWorld(n: 2);
      final t = SimulatedMeshTransport(sim, sim.nodes[0].id);
      t.advance(5000);
      final to = sim.nodes[1].id;

      sim.nodes[0].isOnline = false;
      final r = await t.send(to, bytes(16));
      expect(r.ok, isFalse);
      expect(r.status, equals(SendStatus.refused));
      expect(r.messageId, isNull);
      // Still sized, so the app can say what it *would* have cost.
      expect(r.wireBytes, greaterThan(0));

      // A transport bound to an id the engine does not know refuses rather than crashing.
      final ghost = SimulatedMeshTransport(sim, 'node-ghost');
      expect((await ghost.send(to, bytes(16))).status, equals(SendStatus.refused));
      expect(ghost.advance(1000), isEmpty);
    });
  });

  group('MeshTransport — transfer', () {
    test('carries a file in chunks, each sized on its own radio', () async {
      final sim = lineWorld(n: 2);
      final t = SimulatedMeshTransport(sim, sim.nodes[0].id);
      t.advance(5000);
      final conn = await t.connect(sim.nodes[1].id);
      expect(conn, isNotNull);

      final h = await t.transfer(conn!, 1048576);
      expect(h, isNotNull);
      expect(h!.chunks, equals(16)); // 1 MB at the 64 KB default
      // A chunk is what rides the radio, not the file: 64 KB is far past the 1 KB ceiling.
      expect(h.transport, equals(TransportType.wifiDirect));

      var p = t.progressOf(h.id);
      expect(p, isNotNull);
      expect(p!.complete, isFalse);
      expect(p.chunksReceived, lessThan(p.chunks));

      expect(runUntil(sim, () => t.progressOf(h.id)!.complete, 300000), isTrue);
      p = t.progressOf(h.id)!;
      expect(p.chunksReceived, equals(p.chunks));
      expect(p.chunksSent, equals(p.chunks));
      expect(p.elapsedMs, greaterThan(0));

      // Unknown id is null rather than an exception: an app polls, and a transfer the engine
      // has forgotten is an ordinary answer.
      expect(t.progressOf('no-such-transfer'), isNull);
    });

    test('refuses a transfer to a peer that has left, and one over the ceiling', () async {
      final sim = lineWorld(n: 2);
      final t = SimulatedMeshTransport(sim, sim.nodes[0].id);
      t.advance(5000);
      final conn = await t.connect(sim.nodes[1].id);
      expect(conn, isNotNull);

      // skills/05: "Max 10 MB". The engine refuses rather than attempting it, and the seam
      // has to pass that refusal through instead of inventing a success.
      expect(await t.transfer(conn!, 64 * 1024 * 1024), isNull);

      sim.nodes[1].pos = Vec2(900, 900);
      sim.nodes[1].target = Vec2(900, 900);
      t.advance(15000);
      expect(await t.transfer(conn, 262144), isNull);
    });
  });

  group('MeshTransport — the seam is inert', () {
    test('adds no randomness of its own, so the golden contract still holds', () {
      // The cross-language contract is that new state is derived and never drawn. The
      // adapter reads the engine and calls its existing methods, so a world driven through
      // the transport and the same world driven by hand must agree on every packet. If this
      // ever fails, the seam has started consuming random numbers and the golden vectors in
      // both engines move with it.
      final bodies = <String>['a', 'bb', 'ccc', 'dddd', 'eeeee'];

      final plain = lineWorld(n: 3);
      for (final b in bodies) {
        plain.sendMessage(plain.nodes[0].id, plain.nodes[1].id, b);
        plain.runFor(1500);
      }
      plain.runFor(20000);

      final viaTransport = lineWorld(n: 3);
      final t = SimulatedMeshTransport(viaTransport, viaTransport.nodes[0].id);
      t.advance(0);
      for (final b in bodies) {
        t.send(viaTransport.nodes[1].id, Uint8List.fromList(latin1.encode(b)));
        t.advance(1500);
      }
      t.advance(20000);

      expect(viaTransport.deliveries.length, equals(plain.deliveries.length));
      expect(viaTransport.deliveries.map((d) => d.hops).toList(),
          equals(plain.deliveries.map((d) => d.hops).toList()));
      expect(viaTransport.deliveries.map((d) => d.latencyMs).toList(),
          equals(plain.deliveries.map((d) => d.latencyMs).toList()));
      expect(viaTransport.sentRecords.map((r) => r.body).toList(),
          equals(plain.sentRecords.map((r) => r.body).toList()));
      expect(viaTransport.now, equals(plain.now));
      for (var i = 0; i < plain.nodes.length; i++) {
        expect(viaTransport.nodes[i].peerIds, equals(plain.nodes[i].peerIds));
        expect(viaTransport.nodes[i].battery, equals(plain.nodes[i].battery));
      }
    });

    test("the peer set it reports is always the device's own scan result", () {
      // The invariant that makes this a measurement rather than an oracle, checked at every
      // poll of a run in which the device really does fall asleep: whatever the transport
      // believes it can hear is exactly `node.peerIds`, which the engine refreshes on the
      // scan cycle and leaves stale while a NORMAL node sleeps (skills/07: 3 s of scanning in
      // every 10 s cycle). Reading `peersInRange` here instead would pass this test too, and
      // would then let an app depend on knowing a peer is in range before it has been heard.
      final sim = lineWorld(n: 3, dutyCycle: true);
      final t = SimulatedMeshTransport(sim, sim.nodes[0].id);
      final me = sim.nodes[0];
      var sawSleep = false;
      var disagreed = false;
      for (var i = 0; i < 60; i++) {
        t.advance(1000);
        expect(t.heardPeers, equals(me.peerIds.toSet()));
        if (!sim.isAwake(me)) sawSleep = true;
        // The geometry, which no real device can read. Where the two differ, the scan is
        // behind the world — and that is the case an app has to survive.
        final truth = peersInRange(me, sim.nodes, sim.rf).map((n) => n.id).toSet();
        if (truth.length != t.heardPeers.length ||
            !truth.every(t.heardPeers.contains)) {
          disagreed = true;
        }
      }
      // If the device never slept, or its scan never disagreed with the geometry, the run
      // says nothing about staleness and the invariant above is vacuous — so assert the two
      // things that make it interesting actually happened.
      expect(sawSleep, isTrue);
      expect(disagreed, isTrue);
    });
  });
}
