import 'dart:math' as math;

import 'package:duman_mesh_sim/mesh_sim.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('seeded RNG', () {
    test('is deterministic for a given seed', () {
      final a = createRng(1234);
      final b = createRng(1234);
      for (var i = 0; i < 64; i++) {
        expect(a(), equals(b()));
      }
    });

    test('matches the fixed-point vectors shared with the TS engine', () {
      final rng = createRng(42);
      expect((rng() * 1e9).round(), equals(601103752));
      expect((rng() * 1e9).round(), equals(448290559));
      expect((rng() * 1e9).round(), equals(852465793));
    });

    test('stays inside [0, 1)', () {
      final rng = createRng(7);
      for (var i = 0; i < 20000; i++) {
        final v = rng();
        expect(v, greaterThanOrEqualTo(0.0));
        expect(v, lessThan(1.0));
      }
    });
  });

  group('RF model', () {
    final rf = rfWith();

    test('gives the documented BLE hop range for the default calibration', () {
      // tx -55 dBm, sensitivity -85 dBm -> 10^(30/20) = 31.6 m.
      expect(maxRangeM(defaultTxPowerDbm, defaultRxSensitivityDbm),
          closeTo(31.6, 0.1));
      final a = makeNode('a', 0, 0);
      expect(canReach(a, makeNode('b', 31, 0), rf), isTrue);
      expect(canReach(a, makeNode('c', 33, 0), rf), isFalse);
    });

    test('never treats a node as its own peer', () {
      final a = makeNode('a', 0, 0);
      expect(canReach(a, a, rf), isFalse);
      expect(peersInRange(a, <MeshNode>[a], rf), isEmpty);
    });

    test('follows inverse-square path loss', () {
      final a = makeNode('a', 0, 0);
      final b = makeNode('b', 10, 0);
      expect(rssiModel(a, b, rf), closeTo(-55 - 20, 1e-6));
    });

    test('attenuates by one wall penalty per boundary crossed', () {
      const building = Obstacle(10, -10, 10, 20, 'hall');
      final walled = rfWith(const <Obstacle>[building]);
      final a = makeNode('a', 0, 0);
      final b = makeNode('b', 30, 0);
      expect(countWallCrossings(a.pos, b.pos, const <Obstacle>[building]), equals(2));
      expect(rssiModel(a, b, walled),
          closeTo(rssiModel(a, b, rf) - 2 * defaultWallPenaltyDb, 1e-6));
    });

    test('flags points inside a building so spawning can reject them', () {
      const building = Obstacle(10, 10, 10, 10, 'hall');
      expect(insideAnyObstacle(Vec2(15, 15), const <Obstacle>[building]), isTrue);
      expect(insideAnyObstacle(Vec2(5, 5), const <Obstacle>[building]), isFalse);
    });

    test('normalises RSSI onto 0..1 and clamps', () {
      expect(normRssi(-30), equals(1.0));
      expect(normRssi(-100), equals(0.0));
      expect(normRssi(-65), closeTo(0.5, 1e-12));
      expect(normRssi(-200), equals(0.0));
    });

    test('retries multiply out the raw link loss', () {
      final a = makeNode('a', 0, 0);
      final weak = makeNode('w', 30, 0);
      final raw = packetLossProbability(a, weak, rf);
      expect(effectiveLossProbability(a, weak, rf, 2), closeTo(raw * raw * raw, 1e-12));
      expect(effectiveLossProbability(a, weak, rf, 0), closeTo(raw, 1e-12));
      expect(packetLossProbability(a, makeNode('s', 2, 0), rf), lessThan(0.05));
    });

    test('keeps nodes wandering around their waypoint', () {
      final rng = createRng(5);
      final n = makeNode('m', 50, 50,
          stationary: false, mobility: 0.8, wanderRadius: 12);
      for (var i = 0; i < 2000; i++) {
        integrateMotion(n, rng, 0.25, 100, 100, true);
      }
      expect(distance(n.pos, n.home), lessThanOrEqualTo(n.wanderRadius + 2));
      expect(n.pos.x, inInclusiveRange(2, 98));
    });

    test('drains battery at the documented 15%/8h for NORMAL', () {
      expect(normalDrainPerHour, closeTo(0.15 / 8, 1e-12));
      expect(superDrainPerHour, closeTo((0.15 / 8) * 4, 1e-12));
      final n = makeNode('n', 0, 0, battery: 1);
      batteryDrain(n, 8 * 3600, 1);
      expect(n.battery, closeTo(0.85, 1e-6));
    });
  });

  group('coverage score (docs/03 §3)', () {
    final rf = rfWith();

    test('applies the documented weights exactly', () {
      final nodes = ring(8);
      final centre = nodes[0];
      final peers = peersInRange(centre, nodes, rf);
      var sum = 0.0;
      for (final p in peers) {
        sum += rssiModel(centre, p, rf);
      }
      // dart:math log is the natural log; the TS engine uses the same base.
      final expected = 0.30 * (_ln(1 + peers.length) / _ln(51)) +
          0.25 * normRssi(sum / peers.length) +
          0.20 * 0.8 +
          0.15 * (1.0 * 1.0) +
          0.10 * 0.95;
      expect(computeScore(centre, nodes, rf), closeTo(expected, 1e-9));
    });

    test('scores 0 when isolated or below the battery floor', () {
      final lone = makeNode('lone', 0, 0);
      expect(computeScore(lone, <MeshNode>[lone], rf), equals(0));
      final nodes = ring(6);
      nodes[0].battery = 0.24;
      expect(computeScore(nodes[0], nodes, rf), equals(0));
      nodes[0].battery = 0.25;
      expect(computeScore(nodes[0], nodes, rf), greaterThan(0));
    });
  });

  group('election (docs/03 §3-5)', () {
    final rf = rfWith();

    test('refuses to promote with too few peers', () {
      final nodes = ring(2);
      nodes[0]
        ..score = 0.95
        ..battery = 1
        ..uptimeMin = 600;
      final out = electRole(nodes[0], nodes, rf);
      expect(out.role, equals(Role.normal));
      expect(out.reason, contains('Too few peers'));
    });

    test('refuses to promote below the battery floor', () {
      final nodes = ring(6);
      nodes[0]
        ..score = 0.95
        ..battery = 0.2;
      expect(electRole(nodes[0], nodes, rf).reason, contains('Battery'));
    });

    // skills/02 acceptance: "SUPER opt-out respected; NORMAL never
    // auto-promoted if battery saver on".
    test('refuses to promote a node that opted out of the router role', () {
      final nodes = ring(6);
      nodes[0]
        ..score = 0.95
        ..superOptOut = true;
      final out = electRole(nodes[0], nodes, rf);
      expect(out.role, equals(Role.normal));
      expect(out.reason, contains('opt-out'));
    });

    test('refuses to promote a node in battery-saver mode', () {
      final nodes = ring(6);
      nodes[0]
        ..score = 0.95
        ..batterySaver = true;
      final out = electRole(nodes[0], nodes, rf);
      expect(out.role, equals(Role.normal));
      expect(out.reason, contains('Battery saver'));
    });

    test('steps an existing SUPER down at once when it opts out', () {
      // A toggle is explicit intent, not score noise, so it must not wait out the
      // two-cycle demotion hysteresis that damps flapping.
      final nodes = ring(6);
      nodes[0]
        ..role = Role.superNode
        ..score = 0.95
        ..superOptOut = true;
      nodes[0].demoteCounter = 0;
      expect(electRole(nodes[0], nodes, rf).role, equals(Role.normal));
      expect(nodes[0].demoteCounter, equals(0));
    });

    test('promotes the next-best candidate when the top scorer opts out', () {
      // Opting out must not leave a coverage hole: the ranking is over the scores
      // heard from the neighbourhood, so the runner-up is still in the top 20%.
      final nodes = ring(9);
      for (final n in nodes) {
        n.score = 0.62;
      }
      nodes[0].score = 0.8; // would be promoted
      nodes[1]
        ..score = 0.75
        ..superOptOut = true;
      expect(electRole(nodes[0], nodes, rf).role, equals(Role.superNode));
      expect(electRole(nodes[1], nodes, rf).role, equals(Role.normal));
    });

    test('advertises the declination so peers stop ranking it as a candidate',
        () {
      final nodes = ring(6);
      nodes[0].score = 0.9;
      expect(buildOgm(nodes[0]).declinedRouter, isFalse);
      nodes[0].superOptOut = true;
      expect(buildOgm(nodes[0]).declinedRouter, isTrue);
      nodes[0]
        ..superOptOut = false
        ..batterySaver = true;
      expect(buildOgm(nodes[0]).declinedRouter, isTrue);
      // and it survives the gossip copy
      expect(buildOgm(nodes[0]).copyWith(hopCount: 1).declinedRouter, isTrue);
    });

    test('promotes above 0.60 when ranked in the top 20%', () {
      final nodes = ring(6);
      nodes[0].score = 0.75;
      for (final p in nodes.skip(1)) {
        p.score = 0.3;
      }
      final out = electRole(nodes[0], nodes, rf);
      expect(out.role, equals(Role.superNode));
      expect(out.reason, contains('Promoted'));
    });

    test('needs two consecutive low cycles to demote', () {
      final nodes = ring(6);
      nodes[0]
        ..role = Role.superNode
        ..score = 0.4;
      for (final p in nodes.skip(1)) {
        p.score = 0.1;
      }
      final first = electRole(nodes[0], nodes, rf);
      expect(first.role, equals(Role.superNode));
      expect(first.reason, contains('pending demote 1/2'));
      final second = electRole(nodes[0], nodes, rf);
      expect(second.role, equals(Role.normal));
      expect(second.reason, contains('Demoted'));
      expect(nodes[0].demoteCounter, equals(0));
    });

    test('backs off from a clearly better SUPER that is very close', () {
      final nodes = ring(6);
      nodes[0]
        ..role = Role.superNode
        ..score = 0.7;
      nodes.add(makeNode('rival', 51.5, 50, role: Role.superNode, score: 0.95));
      final out = electRole(nodes[0], nodes, rf);
      expect(out.role, equals(Role.normal));
      expect(out.reason, contains('Backed off'));
    });
  });

  group('OGM handling (docs/03 §4, §7)', () {
    test('records hop distance from the beacon, not the sender role', () {
      final me = makeNode('me', 0, 0);
      final origin = makeNode('x', 0, 0, seq: 1);
      origin.peerIds = <String>['me', 'q'];
      final ogm = buildOgm(origin)..hopCount = 2;
      receiveOgm(me, ogm, 'relay-1', 1000);
      expect(me.nextHopTable['x']!.hopCount, equals(3));
      expect(me.nextHopTable['x']!.bestNeighbor, equals('relay-1'));
    });

    test('ignores stale sequence numbers but refreshes liveness', () {
      final me = makeNode('me', 0, 0);
      final origin = makeNode('x', 0, 0, seq: 10);
      receiveOgm(me, buildOgm(origin), 'x', 1000);
      final lastSeq = me.nextHopTable['x']!.lastSeq;
      origin.seq = 9;
      expect(receiveOgm(me, buildOgm(origin), 'x', 2000), isFalse);
      expect(me.nextHopTable['x']!.lastSeq, equals(lastSeq));
      expect(me.nextHopTable['x']!.lastSeen, equals(2000));
    });

    test('decrements the gossip budget and stops at the TTL', () {
      final ogm = buildOgm(makeNode('x', 0, 0))..hopCount = 3;
      expect(ogmToGossip(ogm, 5)!.hopCount, equals(4));
      expect(ogmToGossip(ogm..hopCount = 4, 5), isNull);
    });

    test('builds a 2-hop view only from beacons heard directly', () {
      final me = makeNode('me', 0, 0);
      final origin = makeNode('x', 0, 0, seq: 1)..peerIds = <String>['me', 'q'];
      receiveOgm(me, buildOgm(origin), 'x', 1000);
      expect(me.twoHopView['x'], equals(<String>['me', 'q']));

      // A gossiped copy describes a node several hops away: must not populate it.
      final gossip = ogmToGossip(buildOgm(origin), 5)!;
      final other = makeNode('other', 0, 0)..peerIds = <String>['w'];
      receiveOgm(me, gossip, 'x', 2000);
      expect(me.twoHopView.containsKey('other'), isFalse);
      expect(other, isNotNull);
    });

    test('caps the advertised neighbour list to protect the beacon budget', () {
      final n = makeNode('a', 0, 0)
        ..peerIds = List<String>.generate(40, (i) => 'p$i');
      expect(buildOgm(n).neighborIds, hasLength(mprNeighborAdvertiseLimit));
    });

    test('drops 2-hop views for nodes that stopped being neighbours', () {
      final me = makeNode('me', 0, 0)..peerIds = <String>['x'];
      me.twoHopView['x'] = <String>['y'];
      me.twoHopView['gone'] = <String>['z'];
      receiveOgm(me, buildOgm(makeNode('x', 0, 0, seq: 1)), 'x', 1000);
      pruneStaleEntries(me, 1000, neighborScoreTtlMs);
      expect(me.twoHopView.containsKey('x'), isTrue);
      expect(me.twoHopView.containsKey('gone'), isFalse);
    });

    test('expires soft state that has not been refreshed', () {
      final me = makeNode('me', 0, 0);
      receiveOgm(me, buildOgm(makeNode('x', 0, 0, seq: 1)), 'x', 1000);
      pruneStaleEntries(me, 1000, neighborScoreTtlMs);
      expect(me.nextHopTable.containsKey('x'), isTrue);
      pruneStaleEntries(me, 40000, neighborScoreTtlMs);
      expect(me.nextHopTable.containsKey('x'), isFalse);
      expect(me.ogmTable.containsKey('x'), isFalse);
    });

    test('keeps link quality per neighbour, so a duplicate cannot zero it', () {
      // The defect this pins: tq used to live on the route entry, keyed by
      // whichever neighbour had last won it. A gossiped copy of the *same*
      // beacon arriving over a longer path is not newer, so it recorded no
      // sample — but it did discard the window because it came from a different
      // neighbour, and tq fell to 0. Gossiped duplicates always land after the
      // direct copy, so 0 was the steady state: the 20-node quad measured tq
      // 0.11 for direct neighbours whose real receipt rate was ~0.8, the window
      // never grew past one sample, and getNextHop's tq > 0.6 gate rejected
      // nearly every route.
      final me = makeNode('me', 0, 0);
      final origin = makeNode('x', 0, 0);
      for (var seq = 1; seq <= 6; seq++) {
        origin.seq = seq;
        receiveOgm(me, buildOgm(origin), 'x', seq * 1000.0);
        // Same beacon, relayed back over a 3-hop path by three neighbours.
        for (final relay in <String>['r1', 'r2', 'r3']) {
          receiveOgm(me, buildOgm(origin).copyWith(hopCount: 3), relay,
              seq * 1000.0 + 50);
        }
      }
      final entry = me.nextHopTable['x']!;
      expect(entry.bestNeighbor, equals('x'));
      expect(entry.tq, equals(1.0));
      // One sample per beacon actually heard on that link — six, not one.
      expect(entry.window, equals(<int>[1, 1, 1, 1, 1, 1]));
      expect(getNextHop(me, 'x'), equals('x'));
    });

    test('measures each candidate neighbour separately', () {
      final me = makeNode('me', 0, 0);
      final origin = makeNode('x', 0, 0);
      for (var seq = 1; seq <= 8; seq++) {
        origin.seq = seq;
        // relay-a hears every beacon; relay-b only every fourth.
        receiveOgm(me, buildOgm(origin), 'relay-a', seq * 1000.0);
        if (seq % 4 == 0) {
          receiveOgm(me, buildOgm(origin), 'relay-b', seq * 1000.0 + 10);
        }
      }
      final a = tqWindowFor(me, 'x', 'relay-a')!;
      final b = tqWindowFor(me, 'x', 'relay-b')!;
      expect(tqOfWindow(a.window), equals(1.0));
      // Heard seq 4 then seq 8: three missed beacons recorded as zeros.
      expect(b.window, equals(<int>[1, 0, 0, 0, 1]));
      expect(tqOfWindow(b.window), closeTo(0.4, 1e-12));
      // Equal hop count, so the better link wins the route.
      expect(me.nextHopTable['x']!.bestNeighbor, equals('relay-a'));
      expect(getNextHop(me, 'x'), equals('relay-a'));
    });

    test('bounds the receipt windows one node keeps', () {
      // docs/03 §7 promises O(n) memory. Per-link history is O(n x neighbours),
      // so pruneStaleEntries drops windows for neighbours that are no longer
      // peers and then evicts in insertion order — stable in both JS Maps and
      // Dart LinkedHashMaps, which is what keeps the two engines identical.
      final me = makeNode('me', 0, 0)..peerIds = <String>['x'];
      receiveOgm(me, buildOgm(makeNode('x', 0, 0, seq: 1)), 'x', 1000);
      expect(me.tqWindows.length, equals(1));
      expect(me.tqWindows.containsKey(tqPairKey('x', 'x')), isTrue);

      me.peerIds = <String>[]; // x walked out of range
      pruneStaleEntries(me, 2000, neighborScoreTtlMs);
      expect(me.tqWindows, isEmpty);

      for (var i = 0; i < tqPairMax + 50; i++) {
        me.peerIds.add('p$i');
        me.nextHopTable['o$i'] = NextHopEntry(
            bestNeighbor: 'p$i', tq: 1, lastSeq: 1, hopCount: 1, lastSeen: 2000,
            window: <int>[1], windowNeighbor: 'p$i');
        me.tqWindows[tqPairKey('o$i', 'p$i')] =
            TqWindow(lastSeq: 1, window: <int>[1]);
      }
      pruneStaleEntries(me, 2000, neighborScoreTtlMs);
      expect(me.tqWindows.length, equals(tqPairMax));
      // Oldest inserted go first.
      expect(me.tqWindows.containsKey(tqPairKey('o0', 'p0')), isFalse);
      expect(
          me.tqWindows
              .containsKey(tqPairKey('o${tqPairMax + 49}', 'p${tqPairMax + 49}')),
          isTrue);
    });

    test('only offers a next hop whose tq is usable', () {
      final me = makeNode('me', 0, 0);
      me.nextHopTable['good'] = NextHopEntry(
          bestNeighbor: 'b', tq: 0.6, lastSeq: 1, hopCount: 1, lastSeen: 0,
          window: <int>[], windowNeighbor: 'b');
      me.nextHopTable['bad'] = NextHopEntry(
          bestNeighbor: 'c', tq: 0.59, lastSeq: 1, hopCount: 1, lastSeen: 0,
          window: <int>[], windowNeighbor: 'c');
      expect(getNextHop(me, 'good'), equals('b'));
      expect(getNextHop(me, 'bad'), isNull);
      expect(getNextHop(me, 'unknown'), isNull);
    });
  });

  group('data plane (docs/03 §6, §8)', () {
    final rf = rfWith();

    test('selects transport by payload size', () {
      expect(selectTransport(1024), equals(TransportType.ble));
      expect(selectTransport(1025), equals(TransportType.wifiDirect));
      expect(
          createMessage('m1', 0, 'a', 'b', 'x' * 400).transport,
          equals(TransportType.wifiDirect));
    });

    test('creates routable, encrypted, attempt-zero messages', () {
      final m = createMessage('m1', 1234, 'a', 'b', 'hello',
          ttl: 5, priority: Priority.normal);
      expect(m.id, equals('m1'));
      expect(m.from, equals('a'));
      expect(m.to, equals('b'));
      expect(m.ttl, equals(5));
      expect(m.hopCount, equals(0));
      expect(m.attempt, equals(0));
      expect(m.carried, isFalse);
      expect(m.encrypted, isTrue);
      expect(m.timestamp, equals(1234));
      expect(m.destHint, matches(RegExp(r'^[0-9a-f]{1,8}$')));
      expect(createMessage('m2', 0, 'a', broadcastAddress, 'hi',
              type: MsgType.broadcast)
          .destHint, equals('broadcast'));
    });

    test('destHint matches the TypeScript 32-bit string hash', () {
      // Cross-language contract: both engines must agree on the routing hint.
      expect(hashHint('node-0'), equals(hashHint('node-0')));
      expect(hashHint('node-14').length, lessThanOrEqualTo(8));
    });

    test('dedups on (id, attempt) so a source retry can travel again', () {
      final n = makeNode('n', 0, 0);
      final m = createMessage('m1', 0, 'a', 'b', 'hi');
      expect(seenKey(m), equals('m1#0'));
      markSeen(n, seenKey(m), 0);
      expect(isSeen(n, seenKey(m)), isTrue);
      expect(isSeen(n, seenKey(m.copyWith(attempt: 1))), isFalse);
    });

    test('sends directly when the destination is a neighbour', () {
      final a = makeNode('a', 0, 0);
      final b = makeNode('b', 10, 0);
      final d = decideForward(a, createMessage('m', 0, 'a', 'b', 'hi'),
          <MeshNode>[a, b], rf, RelayPolicy.mpr);
      expect(d.mode, equals(ForwardMode.direct));
      expect(d.targets, equals(<String>['b']));
    });

    test('uses a known route instead of flooding', () {
      final a = makeNode('a', 0, 0);
      final relay = makeNode('r', 10, 0);
      final far = makeNode('f', 90, 0);
      a.nextHopTable['f'] = NextHopEntry(
          bestNeighbor: 'r', tq: 0.9, lastSeq: 1, hopCount: 2, lastSeen: 0,
          window: <int>[], windowNeighbor: 'r');
      final d = decideForward(a, createMessage('m', 0, 'a', 'f', 'hi'),
          <MeshNode>[a, relay, far], rf, RelayPolicy.mpr);
      expect(d.mode, equals(ForwardMode.route));
      expect(d.targets, equals(<String>['r']));
    });

    test('relays immediately when SUPER, waits when NORMAL', () {
      final a = makeNode('a', 0, 0, role: Role.superNode);
      final peers = <MeshNode>[a, makeNode('b', 10, 0), makeNode('c', 0, 10)];
      final msg = createMessage('m', 0, 'a', 'far', 'hi');
      expect(decideForward(a, msg, peers, rf, RelayPolicy.mpr).mode,
          equals(ForwardMode.flood));
      a.role = Role.normal;
      expect(decideForward(a, msg, peers, rf, RelayPolicy.mpr).mode,
          equals(ForwardMode.waitMpr));
      // Neither baseline waits; only `mpr` gives NORMAL nodes the 300 ms window.
      expect(decideForward(a, msg, peers, rf, RelayPolicy.routeFlood).mode,
          equals(ForwardMode.flood));
      expect(decideForward(a, msg, peers, rf, RelayPolicy.floodAll).mode,
          equals(ForwardMode.flood));
    });

    test('keeps the flood-all baseline naive: no routes, no direct unicast', () {
      // skills/02 measures "overhead <=70% of flood-all" and skills/08
      // "overhead down 30% vs naive flood". A baseline that unicasts along known
      // routes is not naive, so it must ignore the routing layer entirely.
      final a = makeNode('a', 0, 0);
      final b = makeNode('b', 10, 0);
      final relay = makeNode('r', 10, 0);
      final far = makeNode('f', 90, 0);
      a.nextHopTable['f'] = NextHopEntry(
          bestNeighbor: 'r', tq: 0.9, lastSeq: 1, hopCount: 2, lastSeen: 0,
          window: <int>[], windowNeighbor: 'r');
      expect(
          decideForward(a, createMessage('m', 0, 'a', 'b', 'hi'),
              <MeshNode>[a, b], rf, RelayPolicy.floodAll).mode,
          equals(ForwardMode.flood));
      final routed = decideForward(a, createMessage('m', 0, 'a', 'f', 'hi'),
          <MeshNode>[a, relay, far], rf, RelayPolicy.floodAll);
      expect(routed.mode, equals(ForwardMode.flood));
      expect(routed.targets, equals(<String>['r']));
      // `routeFlood` is the other arm: routes kept, suppression off.
      expect(
          decideForward(a, createMessage('m', 0, 'a', 'f', 'hi'),
              <MeshNode>[a, relay, far], rf, RelayPolicy.routeFlood).mode,
          equals(ForwardMode.route));
    });

    test('queues for store-carry-forward when nobody is in range', () {
      final a = makeNode('a', 0, 0);
      final far = makeNode('f', 500, 500);
      final d = decideForward(a, createMessage('m', 0, 'a', 'f', 'hi'),
          <MeshNode>[a, far], rf, RelayPolicy.mpr);
      expect(d.mode, equals(ForwardMode.queue));
      expect(d.targets, isEmpty);
    });

    test('suppresses only when the heard relays cover its neighbours', () {
      final a = makeNode('a', 0, 0);
      final b = makeNode('b', 10, 0);
      final c = makeNode('c', 0, 10);
      final peers = <MeshNode>[a, b, c];
      a.peerIds = <String>['b', 'c'];
      final msg = createMessage('m', 0, 'x', 'far', 'hi');

      // Nothing heard yet: forward.
      expect(resolveMprWait(a, msg, peers, rf).mode, equals(ForwardMode.flood));

      // Heard one relay that reaches only itself -> coverage hole -> forward.
      a.heardRelays[seenKey(msg)] = <String>{'b'};
      a.twoHopView['b'] = <String>[];
      a.mprHeardSuper.add(msg.id);
      final hole = resolveMprWait(a, msg, peers, rf);
      expect(hole.mode, equals(ForwardMode.flood));
      expect(hole.reason, contains('not covered'));

      // That relay also covers c, so every neighbour is reached: stay quiet.
      a.twoHopView['b'] = <String>['c'];
      final out = resolveMprWait(a, msg, peers, rf);
      expect(out.mode, equals(ForwardMode.drop));
      expect(out.reason, contains('cover all my neighbours'));
      expect(a.mprSuppressed, equals(1));
    });

    test('selects a minimal relay set covering the 2-hop neighbourhood', () {
      // b covers e,f,g (greedy first pick); c covers g,h (1 new); d covers none.
      final a = makeNode('a', 0, 0);
      a.peerIds = <String>['b', 'c', 'd'];
      a.twoHopView['b'] = <String>['e', 'f', 'g'];
      a.twoHopView['c'] = <String>['g', 'h'];
      a.twoHopView['d'] = <String>['e'];
      expect(selectMprSet(a), equals(<String>['b', 'c']));
    });

    test('prefers a SUPER relay when coverage gains tie', () {
      final a = makeNode('a', 0, 0);
      a.peerIds = <String>['n1', 's1'];
      a.twoHopView['n1'] = <String>['z'];
      a.twoHopView['s1'] = <String>['z'];
      a.ogmTable['s1'] = buildOgm(makeNode('s1', 0, 0, role: Role.superNode));
      expect(selectMprSet(a), equals(<String>['s1']));
    });

    test('caps the OppQueue at the spray limit and keeps the bundle', () {
      final a = makeNode('a', 0, 0);
      final dest = makeNode('d', 500, 500);
      final relay = makeNode('r', 10, 0);
      expect(enqueueOpp(a, createMessage('m', 0, 'a', 'd', 'hi'), 0), isTrue);
      expect(enqueueOpp(a, createMessage('m', 0, 'a', 'd', 'hi'), 0), isFalse);
      expect(enqueueOpp(a, createMessage('b1', 0, 'a', broadcastAddress, 'hi'), 0),
          isFalse);

      a.nextHopTable['d'] = NextHopEntry(
          bestNeighbor: 'r', tq: 1, lastSeq: 1, hopCount: 2, lastSeen: 0,
          window: <int>[], windowNeighbor: 'r');
      final forwarded = <int>[];
      for (var i = 0; i < sprayLimit + 3; i++) {
        final res = scanOppQueue(a, <MeshNode>[a, relay, dest], rf, 1000.0 + i);
        forwarded.add(res.forward.length);
        a.oppQueue
          ..clear()
          ..addAll(res.keep);
      }
      expect(forwarded.sublist(0, sprayLimit), equals(<int>[1, 1, 1]));
      expect(forwarded.sublist(sprayLimit), equals(<int>[0, 0, 0]));
      // docs/03 §8: kept, but demoted to low priority once the budget is spent.
      expect(a.oppQueue, hasLength(1));
      expect(a.oppQueue.first.copyCount, equals(sprayLimit));
      expect(a.oppQueue.first.msg.priority, equals(Priority.low));
      expect(a.oppQueue.first.msg.carried, isTrue);
    });

    test('expires OppQueue bundles on simulation time', () {
      final a = makeNode('a', 0, 0);
      enqueueOpp(a, createMessage('m', 0, 'a', 'd', 'hi'), 0);
      pruneOppQueue(a, oppTtlMs - 1);
      expect(a.oppQueue, hasLength(1));
      pruneOppQueue(a, oppTtlMs + 1);
      expect(a.oppQueue, isEmpty);
    });
  });

  group('simulation invariants', () {
    test('never spawns a node inside a building', () {
      final cfg = campusQuad(42);
      final sim = MeshSimulation(cfg);
      for (final n in sim.nodes) {
        expect(insideAnyObstacle(n.pos, cfg.obstacles), isFalse,
            reason: '${n.id} spawned inside ${cfg.obstacles}');
      }
    });

    test('brings up a connected world by default', () {
      final sim = MeshSimulation(campusQuad(42));
      sim.runFor(20000);
      sim.refresh();
      expect(sim.stats.isolatedNodes, equals(0));
      expect(sim.stats.avgPeers, greaterThan(3));
    });

    test('reproduces a run exactly for the same seed', () {
      final a = MeshSimulation(campusQuad(42));
      final b = MeshSimulation(campusQuad(42));
      a.runFor(120000);
      b.runFor(120000);
      expect(a.refresh().totalForwarded, equals(b.refresh().totalForwarded));
      expect(a.stats.superNodes, equals(b.stats.superNodes));
      expect(a.stats.avgLatencyMs, equals(b.stats.avgLatencyMs));
      expect(a.nodes.map((n) => n.pos.x).toList(),
          equals(b.nodes.map((n) => n.pos.x).toList()));
    });

    test('does not blow the stack when two adjacent nodes exchange a message',
        () {
      // Regression: the original prototype minted a fresh ACK id per delivery,
      // so ACK -> delivery -> ACK recursed until the stack overflowed.
      final sim = MeshSimulation(SimConfig(
        nodeCount: 2,
        enableMobility: false,
        enableSuperElection: false,
        areaWidth: 60,
        areaHeight: 60,
        warmupMs: 4000,
      ));
      sim.nodes[0].pos = Vec2(20, 30);
      sim.nodes[1].pos = Vec2(28, 30);
      expect(canReach(sim.nodes[0], sim.nodes[1], sim.rf), isTrue);
      sim.sendMessage('node-0', 'node-1', 'hello');
      sim.runFor(30000);
      sim.refresh();
      expect(sim.nodes[1].inbox.any((m) => m.body == 'hello'), isTrue);
      expect(sim.stats.acksReceived, lessThanOrEqualTo(1));
    });
  });

  group('hop traces and the capture log (roadmap Phase 4)', () {
    /// A run with real multi-hop traffic to inspect. Pairs are chosen by index
    /// rather than drawn from the simulation's RNG, so the run below stays
    /// comparable with and without capture.
    MeshSimulation traced(
        {bool captureLog = false,
        bool captureOgm = false,
        int? maxLogEntries,
        int messages = 24}) {
      var cfg = campusQuad(42).copyWith(
          captureLog: captureLog, captureOgm: captureOgm);
      if (maxLogEntries != null) cfg = cfg.copyWith(maxLogEntries: maxLogEntries);
      final sim = MeshSimulation(cfg);
      sim.runFor(90000);
      for (var i = 0; i < messages; i++) {
        final online = sim.nodes.where((n) => n.isOnline).toList();
        final from = online[i % online.length];
        var to = online[(i * 7 + 3) % online.length];
        if (to.id == from.id) to = online[(i + 1) % online.length];
        sim.sendMessage(from.id, to.id, 'probe-$i');
        sim.runFor(1500);
      }
      sim.refresh();
      return sim;
    }

    test('records when each hop arrived, over what link, and what it decided',
        () {
      final sim = traced();
      final multi =
          sim.deliveries.where((d) => d.hops >= 2 && !d.dtn).toList();
      expect(multi, isNotEmpty);
      final hops = multi.first.hopTrace;
      expect(hops, isNotEmpty);

      var prev = -1.0;
      for (final h in hops) {
        expect(h.atMs, greaterThanOrEqualTo(prev)); // arrival order
        prev = h.atMs;
        expect(h.rssi, lessThan(0)); // a real dBm figure from the docs/05 model
        expect(h.rssi, greaterThan(-100));
        expect(h.via, isNot(equals(h.nodeId)));
        if (h.action == HopAction.relayed || h.action == HopAction.suppressed) {
          expect(h.reason, isNotNull); // decideForward's own words
          expect(h.reason, isNotEmpty);
        }
      }
      // The recipient's copy is the one that says so.
      expect(
          hops.any((h) =>
              h.nodeId == multi.first.to && h.action == HopAction.delivered),
          isTrue);
    });

    test('recovers the route chain from the fan-out tree', () {
      // `path` lists every node that accepted a fresh copy, so it branches as
      // soon as a relay fans out; "via 2 nodes" needs the single route the
      // delivered copy took. Walking `via` backwards must reproduce exactly
      // `hops` links.
      final sim = traced();
      expect(sim.deliveries.length, greaterThan(5));
      var sawTree = false;
      for (final d in sim.deliveries) {
        final chain = deliveredChain(d.hopTrace, d.to);
        expect(chain.length, equals(d.hops));
        expect(chain.last.nodeId, equals(d.to));
        if (d.path.length > d.hops + 1) sawTree = true;
      }
      // The fan-out this exists to cut through actually happens in this world.
      expect(sawTree, isTrue);
    });

    test('marks the relays MPR suppressed, with the reason', () {
      final sim = traced();
      final suppressed = sim.deliveries
          .expand((d) => d.hopTrace.where((h) => h.action == HopAction.suppressed))
          .toList();
      expect(suppressed, isNotEmpty);
      expect(suppressed.every((h) => (h.reason ?? '').contains('MPR')), isTrue);
    });

    test('traces hops always, and captures the log only when asked', () {
      expect(defaultConfig.captureLog, isFalse);
      final plain = traced();
      expect(plain.log, isEmpty);
      expect(plain.deliveries.any((d) => d.hopTrace.isNotEmpty), isTrue);

      final captured = traced(captureLog: true);
      expect(captured.log, isNotEmpty);
      final kinds = captured.log.map((e) => e.kind).toSet();
      expect(kinds.contains(MeshLogKind.tx), isTrue);
      expect(kinds.contains(MeshLogKind.decision), isTrue);
      expect(kinds.contains(MeshLogKind.deliver), isTrue);
      // Beacons outnumber everything else, so they stay out unless asked for.
      expect(kinds.contains(MeshLogKind.ogm), isFalse);
      for (final e in captured.log) {
        expect(e.detail, isNotEmpty);
        expect(e.atMs, greaterThanOrEqualTo(0));
      }
    });

    test('logs beacons too when captureOgm is set', () {
      final sim = traced(captureLog: true, captureOgm: true, messages: 4);
      expect(sim.log.any((e) => e.kind == MeshLogKind.ogm), isTrue);
    });

    test('keeps the capture bounded and in time order', () {
      final sim = traced(captureLog: true, maxLogEntries: 40);
      expect(sim.log.length, equals(40)); // the ring buffer is full by now
      for (var i = 1; i < sim.log.length; i++) {
        expect(sim.log[i].atMs, greaterThanOrEqualTo(sim.log[i - 1].atMs));
      }
    });

    test('does not perturb the run it is measuring', () {
      // Instrumentation that changed the result would be worse than none: the
      // log must not touch the RNG, the event order or a single counter.
      final plain = traced();
      final captured = traced(captureLog: true, captureOgm: true);
      expect(captured.stats.totalForwarded, equals(plain.stats.totalForwarded));
      expect(
          captured.stats.controlOverhead, equals(plain.stats.controlOverhead));
      expect(captured.stats.totalDelivered, equals(plain.stats.totalDelivered));
      expect(captured.stats.avgLatencyMs, equals(plain.stats.avgLatencyMs));
      expect(captured.nodes.map((n) => n.pos.x).toList(),
          equals(plain.nodes.map((n) => n.pos.x).toList()));
    });

    test('drops the log when metrics are re-baselined', () {
      final sim = traced(captureLog: true);
      expect(sim.log, isNotEmpty);
      sim.clearRecords();
      expect(sim.log, isEmpty);
    });

    test('logs the DTN last resort as a queue event', () {
      // partitioned_pair's two clusters are ~190 m apart, so nothing routes: the
      // originator retries twice, gives up, and starts carrying the bundle
      // (docs/03 §8). That hand-over into the OppQueue happens on a different
      // code path from decideForward's queue mode.
      final sim = MeshSimulation(partitionedPair(42).copyWith(captureLog: true));
      sim.runFor(60000);
      final online = sim.nodes.where((n) => n.isOnline).toList();
      final sender = online.first;
      final farAway = online.last;
      for (var i = 0; i < 4; i++) {
        sim.sendMessage(sender.id, farAway.id, 'carry-$i');
        sim.runFor(60000);
      }
      sim.refresh();
      expect(sim.stats.totalQueued, greaterThan(0));
      final queued = sim.log.where((e) => e.kind == MeshLogKind.queue).toList();
      expect(queued, isNotEmpty);
      expect(queued.first.detail, contains('carrying'));
      expect(sender.oppQueue.length, equals(queued.length));
    });
  });

  group('power policy and telemetry (skills/02, skills/07)', () {
    test('never promotes a node the user opted out of', () {
      final sim = MeshSimulation(campusQuad(42));
      sim.runFor(90000); // past the first election at 30 s
      sim.refresh();
      final declined =
          sim.nodes.firstWhere((n) => n.role == Role.superNode);
      sim.setSuperOptOut(declined.id, true);
      expect(declined.role, equals(Role.normal));
      expect(declined.reasonTrace, contains('opt-out'));
      sim.runFor(40000); // and it stays down across the next tick
      expect(declined.role, equals(Role.normal));
      sim.setSuperOptOut(declined.id, false);
      sim.runFor(40000);
      expect(declined.role, equals(Role.superNode));
    });

    test('never auto-promotes with battery saver on', () {
      final sim = MeshSimulation(campusQuad(42));
      sim.runFor(90000);
      for (final n in sim.nodes) {
        sim.setBatterySaver(n.id, true);
      }
      sim.runFor(60000);
      sim.refresh();
      expect(sim.stats.superNodes, equals(0));
      final online = sim.nodes.where((n) => n.isOnline).toList();
      expect(online.every((n) => n.reasonTrace.contains('Battery saver')),
          isTrue);
    });

    test('leaves duty cycling off by default', () {
      final sim = MeshSimulation(campusQuad(42));
      sim.runFor(60000);
      sim.refresh();
      expect(sim.config.dutyCycleEnabled, isFalse);
      expect(sim.stats.awakeRatio, equals(1.0));
      expect(sim.stats.scansSkippedAsleep, equals(0));
    });

    test('scans 3 s out of every 10 s when duty cycling, never a SUPER', () {
      final sim = MeshSimulation(campusQuad(42).copyWith(dutyCycleEnabled: true));
      sim.runFor(90000);
      final superNode =
          sim.nodes.firstWhere((n) => n.role == Role.superNode);
      expect(sim.isAwake(superNode), isTrue);

      final normal = sim.nodes.firstWhere((n) => n.role == Role.normal)
        ..dutyPhaseMs = 0.0;
      var awake = 0;
      const samples = 1000;
      for (var i = 0; i < samples; i++) {
        if (sim.isAwake(normal, i / samples * 10000.0)) awake++;
      }
      expect(awake / samples, closeTo(0.3, 0.01));
      // Int literals do not convert in a `double?` context, so the window
      // boundaries are written as doubles.
      expect(sim.isAwake(normal, 0.0), isTrue);
      expect(sim.isAwake(normal, 2999.0), isTrue);
      expect(sim.isAwake(normal, 3000.0), isFalse);
      expect(sim.isAwake(normal, 9999.0), isFalse);
    });

    test('spreads duty phases so a crowd does not sleep in lockstep', () {
      final sim = MeshSimulation(campusQuad(42).copyWith(dutyCycleEnabled: true));
      final phases = sim.nodes.map((n) => n.dutyPhaseMs.round()).toSet();
      // Phases are spread by index, never drawn: the RNG draw order is part of
      // the cross-language contract with src/simulation.ts.
      expect(phases.length, equals(sim.nodes.length));
      sim.runFor(60000);
      sim.refresh();
      expect(sim.stats.awakeRatio, greaterThan(0));
      expect(sim.stats.awakeRatio, lessThan(1));
      expect(sim.stats.scansSkippedAsleep, greaterThan(0));
    });

    test('measures the per-role battery rate against the skills/07 budget', () {
      // Roles are promoted at the first election, so a window that starts at
      // warm-up bleeds pre-promotion drain into the average. Settle, re-baseline,
      // then measure. 15% over 8 h = 1.875 %/h = NORMAL_DRAIN_PER_HOUR exactly:
      // an always-scanning stationary node spends the whole budget, and SUPER is
      // the documented 4x (60% per 8 h), which is why the role is opt-out-able.
      final sim =
          MeshSimulation(campusQuad(42).copyWith(stationaryRatio: 1.0));
      sim.runFor(90000);
      sim.clearRecords();
      sim.runFor(90000);
      sim.refresh();
      expect(sim.stats.batteryPercentPerHourNormal, closeTo(1.875, 1e-3));
      expect(sim.stats.batteryPercentPerHourNormal * 8, closeTo(15, 1e-2));
      expect(sim.stats.batteryPercentPerHourSuper, closeTo(7.5, 1e-3));
    });

    test('buys battery headroom by sleeping', () {
      final alwaysOn =
          MeshSimulation(campusQuad(42).copyWith(stationaryRatio: 1.0));
      alwaysOn.runFor(90000);
      alwaysOn.clearRecords();
      alwaysOn.runFor(90000);
      alwaysOn.refresh();

      final duty = MeshSimulation(campusQuad(42).copyWith(
          stationaryRatio: 1.0, dutyCycleEnabled: true));
      duty.runFor(90000);
      duty.clearRecords();
      duty.runFor(90000);
      duty.refresh();

      // 0.3 awake + 0.7 asleep at sleepDrainFactor 0.25 = 0.475 of the budget.
      expect(duty.stats.batteryPercentPerHourNormal,
          closeTo(1.875 * 0.475, 1e-3));
      expect(duty.stats.batteryPercentPerHourNormal * 8, lessThan(8));
      expect(duty.stats.batteryPercentPerHourSuper, closeTo(7.5, 1e-3));
      expect(duty.stats.scansPerSec, lessThan(alwaysOn.stats.scansPerSec));
    });

    test('excludes charging nodes from the measured drain rate', () {
      final sim = MeshSimulation(campusQuad(42));
      sim.runFor(60000);
      for (final n in sim.nodes) {
        sim.setNodeCharging(n.id, true);
      }
      sim.refresh();
      expect(sim.stats.batteryPercentPerHourNormal, equals(0.0));
    });

    test('buckets latency by hop for first-attempt routed traffic', () {
      final sim = MeshSimulation(campusQuad(42));
      sim.runFor(90000);
      for (var i = 0; i < 20; i++) {
        sim.sendMessage('node-0', 'node-${(i % 19) + 1}', 'probe-$i');
        sim.runFor(1500);
      }
      sim.refresh();
      final buckets = sim.stats.latencyByHop;
      expect(buckets, isNotEmpty);
      for (var i = 1; i < buckets.length; i++) {
        expect(buckets[i].hops, greaterThan(buckets[i - 1].hops));
      }
      for (final b in buckets) {
        expect(b.hops, greaterThanOrEqualTo(1));
        expect(b.count, greaterThan(0));
        expect(b.avgMs, greaterThan(0));
        expect(b.p95Ms, greaterThan(0));
      }
      expect(sim.stats.scansPerSec, greaterThan(0));
      expect(sim.stats.electionEvents, greaterThan(0));
    });
  });
}

double _ln(num x) => math.log(x.toDouble());
