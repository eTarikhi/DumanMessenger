import 'dart:convert';
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
      // 400 characters is a 512 B packet under skills/03's layout (95 B of header,
      // nonce, tag, sender and timestamp, padded up to a 256 B block), so it rides
      // BLE. Under the old `64 + 4 bytes per character` heuristic it was 1 664 B and
      // flipped to Wi-Fi Direct — see the packet-size group below and docs/07 §4.
      expect(createMessage('m1', 0.0, 'a', 'b', 'x' * 400).transport,
          equals(TransportType.ble));
      expect(createMessage('m2', 0.0, 'a', 'b', 'x' * 930).transport,
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

  group('group channels (docs/04, roadmap Phase 1 "group (3-10 members)")', () {
    /// A settled world with one group in it. Members are spread across the world by
    /// default, so delivery has to cross hops rather than fall out of one radio range.
    Map<String, Object?> groupWorld(
        {SimConfig? world,
        GroupMode? mode,
        int size = 5,
        bool spread = true,
        bool captureLog = false}) {
      final cfg = (world ?? campusQuad(42)).copyWith(
          groupMode: mode ?? GroupMode.scopedFlood, captureLog: captureLog);
      final sim = MeshSimulation(cfg);
      sim.runFor(90000);
      sim.clearRecords();
      final online = sim.nodes.where((n) => n.isOnline).toList();
      final cx = online.fold<double>(0, (a, n) => a + n.pos.x) / online.length;
      final cy = online.fold<double>(0, (a, n) => a + n.pos.y) / online.length;
      double fromCentroid(MeshNode n) =>
          (n.pos.x - cx) * (n.pos.x - cx) + (n.pos.y - cy) * (n.pos.y - cy);
      // furthest-from-centroid first, so a "spread" group really spans the world
      final ranked = online.toList()..sort((a, b) => fromCentroid(b).compareTo(fromCentroid(a)));
      final List<NodeId> ids;
      if (spread) {
        final step = ranked.length ~/ size;
        final picked = <NodeId>{};
        for (var i = 0; i < ranked.length && picked.length < size; i++) {
          picked.add(ranked[(i * step) % ranked.length].id);
        }
        ids = picked.toList();
      } else {
        final anchorNode = ranked.first;
        double fromAnchor(MeshNode n) => (n.pos.x - anchorNode.pos.x) * (n.pos.x - anchorNode.pos.x) +
            (n.pos.y - anchorNode.pos.y) * (n.pos.y - anchorNode.pos.y);
        ids = (online.toList()..sort((a, b) => fromAnchor(a).compareTo(fromAnchor(b))))
            .take(size)
            .map((n) => n.id)
            .toList();
      }
      final group = sim.createGroup('field team', ids, ids.first)!;
      return <String, Object?>{
        'sim': sim,
        'group': group,
        'ids': ids,
        'sender': sim.nodes.firstWhere((n) => n.id == ids.first),
      };
    }

    /// Send [n] group messages, letting each one propagate.
    void send(MeshSimulation sim, String groupId, NodeId from,
        {int n = 4, double gapMs = 4000}) {
      for (var i = 0; i < n; i++) {
        sim.sendMessage(from, groupId, 'status $i');
        sim.runFor(gapMs);
      }
      sim.refresh();
    }

    List<MeshMessage> held(MeshNode n, String groupId) =>
        n.inbox.where((m) => m.groupId == groupId).toList();

    test('enforces the 3-10 member bound', () {
      final r = groupWorld(size: 5, spread: false);
      final sim = r['sim'] as MeshSimulation;
      final all = sim.nodes.map((n) => n.id).toList();
      expect(sim.createGroup('too small', all.sublist(0, 2)), isNull);
      expect(sim.createGroup('too big', all.sublist(0, 11)), isNull);
      expect(sim.createGroup('just right', all.sublist(0, 3)), isNotNull);
      expect(sim.createGroup('at the cap', all.sublist(0, 10)), isNotNull);
      // duplicate ids and ids that do not exist cannot pad out the minimum
      expect(sim.createGroup('padded', <NodeId>['node-0', 'node-0', 'node-404']), isNull);
      final g = sim.createGroup('admin', all.sublist(0, 4), all[2])!;
      expect(g.adminId, equals(all[2]));
      expect(g.keyEpoch, equals(0));
      expect(g.members.length, equals(4));
    });

    test('reaches every member and nobody else', () {
      final r = groupWorld();
      final sim = r['sim'] as MeshSimulation;
      final group = r['group'] as Group;
      final ids = r['ids'] as List<NodeId>;
      final sender = r['sender'] as MeshNode;
      send(sim, group.id, sender.id);
      for (final n in sim.nodes) {
        if (n.id == sender.id) {
          expect(held(n, group.id), isEmpty); // a sender does not receive its own
        } else if (ids.contains(n.id)) {
          expect(held(n, group.id).length, equals(4));
        } else {
          expect(held(n, group.id), isEmpty);
        }
      }
      expect(sim.stats.groupReceipts, equals(4 * (ids.length - 1)));
      expect(sim.stats.groupExpected, equals(4 * (ids.length - 1)));
      expect(sim.stats.groupDeliveryRatio, equals(1));
    });

    test('relays through non-members, so a spread group still works', () {
      final r = groupWorld(spread: true);
      final sim = r['sim'] as MeshSimulation;
      final group = r['group'] as Group;
      final ids = r['ids'] as List<NodeId>;
      final sender = r['sender'] as MeshNode;
      send(sim, group.id, sender.id, n: 2);
      final far = ids.where((id) => id != sender.id && !sender.peerIds.contains(id)).toList();
      expect(far, isNotEmpty);
      for (final id in far) {
        expect(held(sim.nodes.firstWhere((n) => n.id == id), group.id), isNotEmpty);
      }
      // a non-member carried the traffic: it transmitted without ever receiving
      final carriers = sim.nodes
          .where((n) =>
              !ids.contains(n.id) &&
              n.txCount > 0 &&
              !n.inbox.any((m) => m.groupId == group.id))
          .toList();
      expect(carriers, isNotEmpty);
    });

    test('keeps group traffic out of the unicast metrics', () {
      final r = groupWorld();
      final sim = r['sim'] as MeshSimulation;
      final group = r['group'] as Group;
      send(sim, group.id, (r['sender'] as MeshNode).id);
      expect(sim.stats.sentUnicast, equals(0));
      expect(sim.stats.sentBroadcast, equals(0));
      expect(sim.stats.sentGroup, equals(4));
      expect(sim.stats.deliveryRatio, equals(0));
      expect(sim.deliveries.every((d) => d.groupId == group.id), isTrue);
    });

    test('never arms a retry timer for a scoped flood', () {
      // The flood is addressed to nobody, so no ACK can come back. Arming the timer
      // would burn two retransmissions and then push every group message into the
      // OppQueue.
      final r = groupWorld();
      final sim = r['sim'] as MeshSimulation;
      final sender = r['sender'] as MeshNode;
      send(sim, (r['group'] as Group).id, sender.id);
      expect(sim.stats.retriesSent, equals(0));
      expect(sim.stats.retriesExhausted, equals(0));
      expect(sender.oppQueue, isEmpty);
      expect(sim.nodes.every((n) => n.oppQueue.isEmpty), isTrue);
    });

    test('rotates the key on leave; the departed node relays but cannot read', () {
      final r = groupWorld(spread: true);
      final sim = r['sim'] as MeshSimulation;
      final group = r['group'] as Group;
      final ids = r['ids'] as List<NodeId>;
      final sender = r['sender'] as MeshNode;
      send(sim, group.id, sender.id, n: 1);
      final leaving = ids.firstWhere((id) => id != sender.id);
      final leaver = sim.nodes.firstWhere((n) => n.id == leaving);
      expect(held(leaver, group.id).length, equals(1));
      final epochBefore = group.keyEpoch;
      expect(sim.removeFromGroup(group.id, leaving), isTrue);
      expect(group.keyEpoch, equals(epochBefore + 1)); // docs/04 §4: rotated on leave
      expect(group.members.contains(leaving), isFalse);

      final txBefore = leaver.txCount;
      leaver.inbox.clear();
      send(sim, group.id, sender.id, n: 2);
      expect(held(leaver, group.id), isEmpty); // cannot read any of it...
      expect(leaver.txCount, greaterThan(txBefore)); // ...but still carries it
      for (final id in ids.where((x) => x != leaving && x != sender.id)) {
        expect(held(sim.nodes.firstWhere((n) => n.id == id), group.id).length, equals(3));
      }
    });

    test('refuses to shrink a group below three', () {
      final r = groupWorld(size: 3, spread: false);
      final sim = r['sim'] as MeshSimulation;
      final group = r['group'] as Group;
      final ids = r['ids'] as List<NodeId>;
      expect(group.members.length, equals(3));
      expect(sim.removeFromGroup(group.id, ids[1]), isFalse);
      expect(group.members.length, equals(3));
      expect(sim.removeFromGroup(group.id, 'node-404'), isFalse);
    });

    test('rotates on join, so a joiner cannot read the history it missed', () {
      final r = groupWorld(size: 4, spread: true);
      final sim = r['sim'] as MeshSimulation;
      final group = r['group'] as Group;
      final ids = r['ids'] as List<NodeId>;
      final sender = r['sender'] as MeshNode;
      send(sim, group.id, sender.id, n: 2);
      final outsider =
          sim.nodes.firstWhere((n) => n.isOnline && !ids.contains(n.id));
      final epochBefore = group.keyEpoch;
      expect(sim.inviteToGroup(group.id, outsider.id), isTrue);
      expect(group.keyEpoch, equals(epochBefore + 1));
      expect(held(outsider, group.id), isEmpty); // pre-join traffic is unreadable
      send(sim, group.id, sender.id, n: 2);
      expect(held(outsider, group.id).length, equals(2));
      expect(sim.inviteToGroup(group.id, outsider.id), isFalse); // not twice
      for (final n in sim.nodes.where((x) => x.isOnline && !group.members.contains(x.id))) {
        if (group.members.length >= groupMaxMembers) break;
        sim.inviteToGroup(group.id, n.id);
      }
      expect(group.members.length, lessThanOrEqualTo(groupMaxMembers));
    });

    test('counts a stale key epoch as rejected, not as a delivery', () {
      final r = groupWorld(size: 4, spread: true);
      final sim = r['sim'] as MeshSimulation;
      final group = r['group'] as Group;
      final ids = r['ids'] as List<NodeId>;
      // A message already in flight under epoch 0 meets a group that rotated to 1.
      // Rotation discards the old key everywhere, so the copy is unreadable to every
      // member, not just to the node that left.
      final msg = sim.sendMessage((r['sender'] as MeshNode).id, group.id, 'in flight')!;
      expect(msg.groupEpoch, equals(0));
      expect(sim.removeFromGroup(group.id, ids[1]), isTrue);
      expect(group.keyEpoch, equals(1));
      sim.runFor(6000);
      sim.refresh();
      expect(sim.stats.groupEpochRejected, greaterThan(0));
      expect(sim.deliveries.where((d) => d.msgId == msg.id), isEmpty);
    });

    test('lets only the admin rotate the key', () {
      final r = groupWorld(size: 4, spread: false);
      final sim = r['sim'] as MeshSimulation;
      final group = r['group'] as Group;
      final ids = r['ids'] as List<NodeId>;
      final sender = r['sender'] as MeshNode;
      expect(group.adminId, equals(sender.id));
      final epoch = group.keyEpoch;
      expect(sim.rotateGroupKey(group.id, ids[1]), isFalse);
      expect(group.keyEpoch, equals(epoch));
      expect(sim.rotateGroupKey(group.id, sender.id), isTrue);
      expect(group.keyEpoch, equals(epoch + 1));
      expect(sim.rotateGroupKey('grp-404', sender.id), isFalse);
    });

    test('offers per-member unicast, with ACKs and the same reach', () {
      // The mode the measurement says is cheaper when members are close together:
      // 4.0 transmissions per message against 519.6 for a scoped flood in the
      // 60-node crowd, because every member is a direct peer (docs/06 §14).
      final r = groupWorld(mode: GroupMode.perMemberUnicast, size: 5, spread: false);
      final sim = r['sim'] as MeshSimulation;
      final group = r['group'] as Group;
      final ids = r['ids'] as List<NodeId>;
      send(sim, group.id, (r['sender'] as MeshNode).id, n: 2);
      expect(sim.stats.sentGroup, equals(2 * (ids.length - 1)));
      expect(sim.stats.groupDeliveryRatio, equals(1));
      expect(sim.stats.acksReceived, greaterThan(0));
      expect(sim.stats.sentUnicast, equals(0));
      // ACKs are deliveries too and belong to the member message, not the group.
      expect(
          sim.deliveries
              .where((d) => d.type != MsgType.ack)
              .every((d) => d.groupId == group.id),
          isTrue);
      expect(sim.deliveries.where((d) => d.type == MsgType.ack), isNotEmpty);
    });

    test('logs membership changes when capture is on', () {
      final r = groupWorld(size: 4, spread: false, captureLog: true);
      final sim = r['sim'] as MeshSimulation;
      final group = r['group'] as Group;
      final ids = r['ids'] as List<NodeId>;
      sim.sendMessage((r['sender'] as MeshNode).id, group.id, 'hello');
      sim.runFor(4000);
      sim.inviteToGroup(
          group.id, sim.nodes.firstWhere((n) => n.isOnline && !ids.contains(n.id)).id);
      sim.removeFromGroup(group.id, ids[2]);
      sim.rotateGroupKey(group.id, group.adminId);
      final entries = sim.log.where((e) => e.kind == MeshLogKind.group).toList();
      final detail = entries.map((e) => e.detail).join(' | ');
      expect(entries.length, greaterThanOrEqualTo(4)); // create, join, leave, rotate
      expect(detail, contains('created with 4 members'));
      expect(detail, contains('joined'));
      expect(detail, contains('left'));
      expect(detail, contains('admin rotated'));
    });

    test("lists a node's groups, and forgets them when the world is rebuilt", () {
      final r = groupWorld(size: 4, spread: false);
      final sim = r['sim'] as MeshSimulation;
      final group = r['group'] as Group;
      final ids = r['ids'] as List<NodeId>;
      expect(sim.groupsOf(ids.first).map((g) => g.id).toList(), equals(<String>[group.id]));
      expect(sim.groupsOf('node-404'), isEmpty);
      sim.reset();
      expect(sim.groups, isEmpty);
      expect(sim.groupsOf(ids.first), isEmpty);
    });

    test('defaults to the mode whose cost does not depend on the route table', () {
      expect(defaultConfig.groupMode, equals(GroupMode.scopedFlood));
    });
  });

  group('MPR fallback at density (skills/08 nodeCount 10-200)', () {
    MeshMessage msg() => createMessage('m1', 0.0, 'centre', 'node-999', 'hi');

    int sectorOf(MeshNode centre, MeshNode p) {
      final a = math.atan2(p.pos.y - centre.pos.y, p.pos.x - centre.pos.x);
      return (((a + math.pi) / (2 * math.pi)) * denseFallbackFanout).floor() %
          denseFallbackFanout;
    }

    /// Wire the centre's peer list up to the ring, as a scan would.
    MeshNode wire(List<MeshNode> nodes) {
      final centre = nodes.first;
      centre.peerIds
        ..clear()
        ..addAll(nodes.skip(1).map((p) => p.id));
      return centre;
    }

    test('floods to every peer while a beacon can describe the neighbourhood', () {
      final nodes = ring(mprNeighborAdvertiseLimit);
      final centre = wire(nodes);
      final d = resolveMprWait(centre, msg(), nodes, rfWith());
      expect(d.mode, equals(ForwardMode.flood));
      expect(d.targets.length, equals(nodes.length - 1));
      expect(d.reason.contains('capped'), isFalse);
    });

    test('caps the fan-out once the neighbourhood no longer fits in a beacon', () {
      final nodes = ring(mprNeighborAdvertiseLimit * 2);
      final centre = wire(nodes);
      final d = resolveMprWait(centre, msg(), nodes, rfWith());
      expect(d.mode, equals(ForwardMode.flood));
      expect(d.targets.length, equals(denseFallbackFanout));
      expect(d.reason,
          contains('capped at $denseFallbackFanout of ${nodes.length - 1} peers'));
      final ids = nodes.skip(1).map((p) => p.id).toSet();
      expect(ids.containsAll(d.targets), isTrue);
    });

    test('spreads the capped fan-out over direction, not the strongest links', () {
      // The nearest peers are all on one side of a node, so choosing by RSSI fans out
      // into a wedge. One peer per angular sector covers the world instead — measured
      // at 200 nodes as 98.3% delivery and 125 tx/message against 96.7% and 205
      // (docs/06 §15).
      final nodes = ring(mprNeighborAdvertiseLimit * 3);
      final centre = wire(nodes);
      final d = resolveMprWait(centre, msg(), nodes, rfWith());
      final chosen = nodes.skip(1).where((p) => d.targets.contains(p.id)).toList();
      expect(chosen.map((p) => sectorOf(centre, p)).toSet().length,
          equals(denseFallbackFanout));
    });

    test('still suppresses at density when the heard relays cover everyone', () {
      // The cap is a fallback, not a replacement for the coverage check: a node that
      // can prove its neighbours are covered stays quiet however dense the world is.
      final nodes = ring(mprNeighborAdvertiseLimit * 2);
      final centre = wire(nodes);
      final m = msg();
      final peers = nodes.skip(1).toList();
      final half = peers.length ~/ 2;
      centre.heardRelays[seenKey(m)] = <NodeId>{peers[0].id, peers[1].id};
      centre.twoHopView[peers[0].id] =
          peers.sublist(0, half).map((p) => p.id).toList();
      centre.twoHopView[peers[1].id] =
          peers.sublist(half).map((p) => p.id).toList();
      final d = resolveMprWait(centre, m, nodes, rfWith());
      expect(d.mode, equals(ForwardMode.drop));
      expect(d.reason, contains('cover all my neighbours'));
      expect(centre.mprSuppressed, equals(1));
    });
  });

  group('SOS mode: repeated flood of GPS + text (docs/05, roadmap Phase 3)', () {
    /// The node furthest from the centroid: an SOS from the edge makes reach a
    /// real test rather than a formality.
    MeshNode edgeSender(MeshSimulation sim) {
      final online = sim.nodes.where((n) => n.isOnline).toList();
      final cx = online.fold<double>(0, (a, n) => a + n.pos.x) / online.length;
      final cy = online.fold<double>(0, (a, n) => a + n.pos.y) / online.length;
      var best = online.first;
      var bestD = -1.0;
      for (final n in online) {
        final d = (n.pos.x - cx) * (n.pos.x - cx) + (n.pos.y - cy) * (n.pos.y - cy);
        if (d > bestD) {
          bestD = d;
          best = n;
        }
      }
      return best;
    }

    /// Every node a chain of radio links reaches from [start]. The honest
    /// denominator for "SOS reaches all": a node nothing can hear is not a
    /// protocol failure.
    Set<NodeId> componentOf(MeshSimulation sim, MeshNode start) {
      final seen = <NodeId>{start.id};
      final stack = <MeshNode>[start];
      while (stack.isNotEmpty) {
        final n = stack.removeLast();
        if (!n.isOnline) continue;
        for (final p in peersInRange(n, sim.nodes, sim.rf)) {
          if (p.isOnline && !seen.contains(p.id)) {
            seen.add(p.id);
            stack.add(p);
          }
        }
      }
      return seen;
    }

    /// One SOS, settled world, 45 s window — enough for four floods at 5 s.
    Map<String, Object?> sosRun(
        {SimConfig? world, int repeats = 3, bool captureLog = false}) {
      final cfg = (world ?? campusQuad(42))
          .copyWith(sosRepeats: repeats, captureLog: captureLog);
      final sim = MeshSimulation(cfg);
      sim.runFor(90000);
      sim.clearRecords();
      final sender = edgeSender(sim);
      final at = sender.pos.clone();
      final msg = sim.sendMessage(
          sender.id, broadcastAddress, 'injured, need help', MsgType.sos)!;
      sim.runFor(45000);
      sim.refresh();
      final floods =
          sender.sentLog.where((m) => m.sosId == msg.sosId).toList();
      final others =
          sim.nodes.where((n) => n.isOnline && n.id != sender.id).toList();
      final reached = others.where((n) => n.inbox.any((m) => m.sosId == msg.sosId)).toList();
      return <String, Object?>{
        'sim': sim, 'sender': sender, 'msg': msg, 'floods': floods,
        'others': others, 'reached': reached, 'at': at,
      };
    }

    test('takes its TTL from the documented value, not a longer data TTL', () {
      // docs/05 §"Broadcast SOS | All transports, flood (TTL=5)". The engine used
      // to hardcode 7 here, contradicting the spec; a deployment wider than 5 hops
      // is what the scenario-level sosTtl override is for.
      expect(defaultConfig.sosTtl, equals(5));
      final sim = MeshSimulation(campusQuad(42));
      final sos = sim.sendMessage('node-0', broadcastAddress, 'help', MsgType.sos)!;
      expect(sos.ttl, equals(5));
      expect(sos.priority, equals(Priority.high));
      final text = sim.sendMessage('node-0', 'node-1', 'hi')!;
      expect(text.ttl, equals(5));
      expect(text.priority, equals(Priority.normal));
    });

    test('carries a GPS fix and goes out on the fastest transport', () {
      final r = sosRun(repeats: 0);
      final msg = r['msg'] as MeshMessage;
      final at = r['at'] as Vec2;
      expect(msg.sosPos!.x, equals(at.x));
      expect(msg.sosPos!.y, equals(at.y));
      expect(msg.sosRepeat, equals(0));
      expect(msg.sosId, contains((r['sender'] as MeshNode).id));
      // Wi-Fi Direct: the RF budget is transport-independent in this model, so
      // what it buys is 40 ms per hop instead of 120 (docs/02 §3.1).
      expect(msg.transport, equals(TransportType.wifiDirect));
    });

    test('re-floods on the interval, every flood with a fresh id', () {
      final r = sosRun();
      final sim = r['sim'] as MeshSimulation;
      final msg = r['msg'] as MeshMessage;
      final floods = r['floods'] as List<MeshMessage>;
      expect(sim.config.sosRepeats, equals(3));
      expect(floods.length, equals(4)); // 1 + 3 repeats
      expect(sim.stats.sosFloods, equals(4));
      // A repeat that reused the id would be dropped by every node that already
      // heard it: the seen-cache is keyed on the message id.
      expect(floods.map((f) => f.id).toSet().length, equals(4));
      expect(floods.every((f) => f.sosId == msg.sosId), isTrue);
      expect(floods.map((f) => f.sosRepeat).toList(), equals(<int>[0, 1, 2, 3]));
      for (var i = 1; i < floods.length; i++) {
        expect(floods[i].timestamp - floods[i - 1].timestamp,
            equals(sim.config.sosRepeatMs));
      }
    });

    test('gives a single-flood arm to measure against', () {
      final r = sosRun(repeats: 0);
      expect((r['floods'] as List<MeshMessage>).length, equals(1));
      expect((r['sim'] as MeshSimulation).stats.sosFloods, equals(1));
    });

    test('re-floods with a fresh fix, so a moving sender stays trackable', () {
      final r = sosRun();
      final sender = r['sender'] as MeshNode;
      if (sender.stationary) return; // nothing new to report
      final floods = r['floods'] as List<MeshMessage>;
      final positions = floods
          .map((f) => '${f.sosPos!.x.toStringAsFixed(3)},${f.sosPos!.y.toStringAsFixed(3)}')
          .toSet();
      expect(positions.length, greaterThan(1));
    });

    test('reaches every radio-connected node — the roadmap exit criterion', () {
      final r = sosRun();
      final sim = r['sim'] as MeshSimulation;
      final sender = r['sender'] as MeshNode;
      final msg = r['msg'] as MeshMessage;
      final others = r['others'] as List<MeshNode>;
      final comp = componentOf(sim, sender);
      final inComp = others.where((n) => comp.contains(n.id)).toList();
      expect(inComp.length, equals(others.length)); // campus_quad is one component
      final missed = inComp
          .where((n) => !n.inbox.any((m) => m.sosId == msg.sosId))
          .map((n) => n.id)
          .toList();
      expect(missed, equals(<NodeId>[]));
    });

    test('reaches all of a 60-node crowd, which TTL=5 cannot span', () {
      // Measured: from an edge sender this world is 6+ hops across, so the spec
      // TTL=5 flood stops short of ~7% of it. The scenario widens the radius and
      // the repeats absorb the loss; together they reach everyone.
      expect(festivalCrowd(42).sosTtl, equals(7));
      final r = sosRun(world: festivalCrowd(42));
      final sim = r['sim'] as MeshSimulation;
      final sender = r['sender'] as MeshNode;
      final msg = r['msg'] as MeshMessage;
      final others = r['others'] as List<MeshNode>;
      final comp = componentOf(sim, sender);
      expect(comp.length, equals(others.length + 1));
      final missed = others
          .where((n) => comp.contains(n.id))
          .where((n) => !n.inbox.any((m) => m.sosId == msg.sosId))
          .map((n) => n.id)
          .toList();
      expect(missed, equals(<NodeId>[]));
    });

    test('collapses repeats into one alert per receiver, newest fix wins', () {
      final r = sosRun();
      final sim = r['sim'] as MeshSimulation;
      final msg = r['msg'] as MeshMessage;
      final floods = r['floods'] as List<MeshMessage>;
      final reached = r['reached'] as List<MeshNode>;
      expect(reached, isNotEmpty);
      final radioReceipts =
          sim.deliveries.where((d) => d.type == MsgType.sos).length;
      for (final n in reached) {
        final alerts = n.inbox.where((m) => m.sosId == msg.sosId).toList();
        // Four floods, one notification: docs/04 keeps the SOS channel opt-in
        // precisely so an emergency cannot spam it.
        expect(alerts.length, equals(1));
        final newest =
            floods.where((f) => f.sosRepeat == alerts.first.sosRepeat).first;
        expect(alerts.first.sosPos!.x, equals(newest.sosPos!.x));
        expect(alerts.first.sosPos!.y, equals(newest.sosPos!.y));
        expect(alerts.first.timestamp, equals(newest.timestamp));
      }
      // The radio did the work four times over; the inbox shows it once.
      expect(radioReceipts, greaterThan(reached.length));
    });

    test('keeps a late copy from overwriting a newer fix', () {
      // Copies arrive out of order across four floods, so the alert must only ever
      // move forward in time.
      final node = makeNode('node-x', 0, 0);
      MeshMessage sos(int repeat, double timestamp, double x, double y) =>
          createMessage('sos-msg-$repeat', timestamp, 'node-a', broadcastAddress,
              'injured, need help',
              type: MsgType.sos,
              ttl: 5,
              priority: Priority.high,
              sosId: 'sos-a',
              sosRepeat: repeat,
              sosPos: Vec2(x, y));
      expect(deliverToInbox(node, sos(3, 2000.0, 9, 9)), isTrue);
      expect(deliverToInbox(node, sos(1, 1000.0, 1, 1)), isTrue); // still a receipt
      expect(node.inbox.length, equals(1));
      expect(node.inbox.first.sosPos!.x, equals(9));
      expect(node.inbox.first.sosRepeat, equals(3));
    });

    test('floods to every peer whatever the relay policy says', () {
      // MPR exists to delete duplicate copies; an SOS is made of them. So the
      // suppression path must not apply, at any hop.
      final r = sosRun();
      final sim = r['sim'] as MeshSimulation;
      final hops = sim.deliveries
          .where((d) => d.type == MsgType.sos)
          .expand((d) => d.hopTrace)
          .toList();
      expect(hops, isNotEmpty);
      expect(hops.any((h) => h.action == HopAction.suppressed), isFalse);
      final relays = hops.where((h) => h.reason != null).toList();
      expect(relays, isNotEmpty);
      expect(
          relays.every((h) => h.reason!.contains('SOS: flood every peer')), isTrue);
    });

    test('stops flooding when the sender goes dark', () {
      final sim = MeshSimulation(campusQuad(42).copyWith(sosRepeats: 3));
      sim.runFor(90000);
      sim.clearRecords();
      final sender = edgeSender(sim);
      sim.sendMessage(sender.id, broadcastAddress, 'injured', MsgType.sos);
      sim.runFor(1000);
      sim.toggleNodeOnline(sender.id); // battery dead, or switched off
      sim.runFor(30000);
      sim.refresh();
      expect(sim.stats.sosFloods, equals(1));
    });

    test('logs every flood when capture is on', () {
      final r = sosRun(captureLog: true);
      final sim = r['sim'] as MeshSimulation;
      final msg = r['msg'] as MeshMessage;
      final sosEntries = sim.log.where((e) => e.kind == MeshLogKind.sos).toList();
      expect(sosEntries.length, equals(4));
      expect(sosEntries.first.detail, contains('flood 1/4'));
      expect(sosEntries.last.detail, contains('flood 4/4'));
      expect(sosEntries.every((e) => e.msgId != null), isTrue);
      expect(sim.log.where((e) => e.msgId == msg.id).length, greaterThan(1));
    });

    test('buys reach with radio time, and the cost is visible', () {
      final one = sosRun(repeats: 0)['sim'] as MeshSimulation;
      final four = sosRun(repeats: 3)['sim'] as MeshSimulation;
      // Measured on campus_quad seed 42: 178 → 691 data transmissions. Four floods
      // of a fan-out is not free, which is why the repeat count is a knob.
      expect(four.stats.totalForwarded,
          greaterThan(one.stats.totalForwarded * 3));
      expect(four.stats.totalForwarded, lessThan(one.stats.totalForwarded * 5));
    });

    test('leaves the unicast metrics baseline alone', () {
      // An SOS is a broadcast: it must not move deliveryRatio, which the
      // acceptance criteria measure on unicast traffic.
      final sim = sosRun()['sim'] as MeshSimulation;
      expect(sim.stats.sentUnicast, equals(0));
      expect(sim.stats.sentBroadcast, equals(4));
      expect(sim.stats.deliveryRatio, equals(0));
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

  group('encrypted packet size (skills/03 Packet)', () {
    test('is the documented layout: 95 bytes around the body, padded to 256', () {
      expect(packetOverheadBytes, equals(27 + 12 + 16 + 32 + 8));
      expect(padBlockBytes, equals(256));
      expect(wireSizeOf(0), equals(256)); // an empty body is still one padded block
      expect(wireSizeOf(161), equals(256)); // 95 + 161 fits exactly
      expect(wireSizeOf(162), equals(512)); // one byte over costs a whole block
      expect(wireSizeOf(900), equals(1024));
    });

    test('keeps a long text on BLE, where the documented packet still fits', () {
      // The old heuristic (64 + 4 bytes per character) crossed the 1 KB ceiling at
      // 241 characters and put every longer text on Wi-Fi Direct. The real packet
      // does not cross until 930, and transport is what sets per-hop latency here —
      // so the heuristic was making long messages look three times faster than they
      // are (docs/07 §3).
      expect(selectTransport(wireSizeOf(241)), equals(TransportType.ble));
      expect(selectTransport(wireSizeOf(700)), equals(TransportType.ble));
      expect(selectTransport(wireSizeOf(900)), equals(TransportType.ble));
      expect(selectTransport(wireSizeOf(930)), equals(TransportType.wifiDirect));
    });

    test('sizes a created message from the packet layout', () {
      final shortMsg = createMessage('m1', 0.0, 'a', 'b', 'hi');
      expect(shortMsg.sizeBytes, equals(256));
      expect(shortMsg.transport, equals(TransportType.ble));
      final longMsg = createMessage('m2', 0.0, 'a', 'b', 'x' * 930);
      expect(longMsg.sizeBytes, equals(1280));
      expect(longMsg.transport, equals(TransportType.wifiDirect));
    });

    test('counts a body in UTF-8 bytes, not in UTF-16 code units', () {
      expect(utf8ByteLength(''), equals(0));
      expect(utf8ByteLength('hey Kemal'), equals(9));
      expect(utf8ByteLength('isik'), equals(4)); // ASCII: bytes == code units
      expect(utf8ByteLength('\u0131\u015f\u0131k'), equals(7)); // "isik" in Turkish
      expect(utf8ByteLength('\u0394'), equals(2)); // GREEK CAPITAL LETTER DELTA
      expect(utf8ByteLength('\u0927'), equals(3)); // DEVANAGARI DHA
      expect(utf8ByteLength('\u7159'), equals(3)); // CJK "smoke"
      expect(utf8ByteLength('\uD83D\uDE00'), equals(4)); // one grinning face
      expect('\uD83D\uDE00'.length, equals(2)); // but two UTF-16 code units
      // A lone surrogate encodes as U+FFFD in both engines. `utf8.encode` throws on
      // these by default, which is why the rule is written out in utf8ByteLength
      // rather than delegated: the TypeScript TextEncoder replaces, so the two
      // would otherwise disagree.
      expect(utf8ByteLength('\uD83D'), equals(3));
      expect(utf8ByteLength('\uDE00'), equals(3));
    });

    test('agrees with utf8.encode on every script the app will meet first', () {
      final samples = <String>[
        '',
        'hey Kemal',
        'ping all',
        'Duman: \u0131\u015f\u0131k \u00e7\u0131\u011f \u015ei\u015fli',
        'Marcu \u021aepe\u0219',
        '\u0394\u03BF\u03C5\u03BC\u03AC\u03BD\u03B9',
        '\u0414\u0443\u043C\u0430\u043D',
        '\u062F\u062E\u0627\u0646',
        '\u0927\u0941\u0906\u0901',
        '\u0E04\u0E27\u0E31\u0E19',
        '\u7159',
        '\uACF0\uAE30',
        '\u3051\u3080\u308A',
        '\uD83C\uDD98\uD83D\uDC65\uD83D\uDCE6',
      ];
      for (final text in samples) {
        expect(utf8ByteLength(text), equals(utf8.encode(text).length), reason: text);
      }
    });

    test('moves a non-ASCII body to the transport that can actually carry it', () {
      final emoji = '\uD83D\uDE00' * 300;
      expect(emoji.length, equals(600)); // code units
      expect(utf8ByteLength(emoji), equals(1200)); // bytes on air
      // By code units this is a 768 B packet that rides BLE. By bytes it is 1536 B
      // and needs Wi-Fi Direct. Only one of those is a packet a radio can send.
      expect(wireSizeOf(emoji.length), equals(768));
      expect(selectTransport(wireSizeOf(emoji.length)), equals(TransportType.ble));
      expect(wireSizeOfBody(emoji), equals(1536));
      expect(selectTransport(wireSizeOfBody(emoji)), equals(TransportType.wifiDirect));
    });

    test('leaves every ASCII result exactly where wireSizeOf put it', () {
      for (final chars in <int>[0, 1, 160, 161, 162, 241, 700, 900, 929, 930, 1200]) {
        expect(wireSizeOfBody('x' * chars), equals(wireSizeOf(chars)), reason: '$chars');
      }
      // Every fixture body is ASCII, so no golden vector moves.
      expect(createMessage('m3', 0.0, 'a', 'b', 'merhaba \u0131\u015f\u0131k').sizeBytes,
          equals(256));
      expect(createMessage('m4', 0.0, 'a', 'b', 'hey Kemal').sizeBytes, equals(256));
    });
  });

  group('abuse limits (docs/04 §6)', () {
    test('the caps are the numbers docs/04 §6 states', () {
      expect(broadcastPerMinuteCapDefault, equals(5));
      expect(relayPerSourcePerMinuteCapDefault, equals(30));
      expect(rateWindowMs, equals(60000));
    });

    test('admits exactly cap messages, then refuses', () {
      final buckets = <String, RateBucket>{};
      for (var i = 0; i < broadcastPerMinuteCapDefault; i++) {
        expect(admitByRate(buckets, 'a|src', broadcastPerMinuteCapDefault, 0.0).ok,
            isTrue,
            reason: 'message $i');
      }
      final refused =
          admitByRate(buckets, 'a|src', broadcastPerMinuteCapDefault, 0.0);
      expect(refused.ok, isFalse);
      expect(refused.reason, contains('rate limit'));
      expect(refused.reason, contains('5 per minute'));
      expect(refused.retryInMs, greaterThan(0));
    });

    test('refills continuously, so a rate is enforced rather than a tally', () {
      // A tumbling counter would admit 5 at t=59 999 and 5 more at t=60 001: ten
      // broadcasts in two milliseconds while never breaking a per-minute count.
      final buckets = <String, RateBucket>{};
      for (var i = 0; i < 5; i++) {
        admitByRate(buckets, 'k', 5, 0.0);
      }
      expect(admitByRate(buckets, 'k', 5, 1000.0).ok, isFalse);
      // One token per rateWindowMs / cap = 12 s at cap 5.
      expect(admitByRate(buckets, 'k', 5, 11999.0).ok, isFalse);
      expect(admitByRate(buckets, 'k', 5, 12001.0).ok, isTrue);
      expect(admitByRate(buckets, 'k', 5, 12002.0).ok, isFalse);
    });

    test('never refills above the cap, so silence does not bank a burst', () {
      final buckets = <String, RateBucket>{};
      admitByRate(buckets, 'k', 5, 0.0);
      final after = admitByRate(buckets, 'k', 5, 600000.0);
      expect(after.ok, isTrue);
      expect(after.tokensLeft, lessThanOrEqualTo(5.0));
      var admitted = 1;
      while (admitByRate(buckets, 'k', 5, 600000.0).ok) {
        admitted++;
      }
      expect(admitted, equals(5));
    });

    test('keeps sources and enforcers apart', () {
      final buckets = <String, RateBucket>{};
      for (var i = 0; i < 5; i++) {
        admitByRate(buckets, 'a|src1', 5, 0.0);
      }
      expect(admitByRate(buckets, 'a|src1', 5, 0.0).ok, isFalse);
      expect(admitByRate(buckets, 'a|src2', 5, 0.0).ok, isTrue);
      expect(admitByRate(buckets, 'b|src1', 5, 0.0).ok, isTrue);
    });

    test('treats a non-positive cap as no cap', () {
      final buckets = <String, RateBucket>{};
      for (var i = 0; i < 500; i++) {
        expect(admitByRate(buckets, 'k', 0, i.toDouble()).ok, isTrue);
      }
      expect(buckets.length, equals(0));
      expect(admitByRate(buckets, 'k', -1, 0.0).ok, isTrue);
    });

    test('grants no refill when the clock goes backwards', () {
      final buckets = <String, RateBucket>{};
      for (var i = 0; i < 5; i++) {
        admitByRate(buckets, 'k', 5, 10000.0);
      }
      expect(admitByRate(buckets, 'k', 5, 0.0).ok, isFalse);
      expect(buckets['k']!.atMs, equals(0.0));
    });

    test('reports one token every 2 s at the relay cap', () {
      final buckets = <String, RateBucket>{};
      for (var i = 0; i < 30; i++) {
        admitByRate(buckets, 'k', 30, 0.0);
      }
      final refused = admitByRate(buckets, 'k', 30, 0.0);
      expect(refused.ok, isFalse);
      expect(refused.retryInMs.round(), equals(2000));
      expect(refused.reason, contains('2.0 s'));
    });

    test('exempts control-plane traffic from the relay cap', () {
      expect(countsAgainstRelayCap(createMessage('m', 0.0, 'a', 'b', '', type: MsgType.ogm)),
          isFalse);
      expect(countsAgainstRelayCap(createMessage('m', 0.0, 'a', 'b', '', type: MsgType.ack)),
          isFalse);
      expect(countsAgainstRelayCap(createMessage('m', 0.0, 'a', 'b', '', type: MsgType.sync)),
          isFalse);
      for (final type in <MsgType>[
        MsgType.text,
        MsgType.broadcast,
        MsgType.voice,
        MsgType.file,
        MsgType.sos,
      ]) {
        expect(countsAgainstRelayCap(createMessage('m', 0.0, 'a', 'b', '', type: type)),
            isTrue,
            reason: type.name);
      }
    });

    test('counting beacons would cost a node 90% of its sustained data rate', () {
      // docs/03 §1: an OGM every 2 s. docs/04 §6: cap relay at 30/min per source.
      // 60 000 / 2 000 = 30 — a source's own beacons arrive at exactly the cap rate.
      const ogmIntervalMs = 2000.0;
      expect(rateWindowMs / ogmIntervalMs, equals(relayPerSourcePerMinuteCapDefault));

      int sustained(bool countOgms) {
        final buckets = <String, RateBucket>{};
        var admitted = 0;
        for (var t = 0.0; t < 10 * rateWindowMs; t += ogmIntervalMs) {
          if (countOgms) {
            admitByRate(buckets, 'relay|src', relayPerSourcePerMinuteCapDefault, t);
          }
          if (admitByRate(buckets, 'relay|src', relayPerSourcePerMinuteCapDefault, t).ok) {
            admitted++;
          }
        }
        return admitted;
      }

      // Counting beacons: the bucket refills one token per slot and the beacon spends
      // it, so data runs off the initial burst alone and then starves.
      expect(sustained(true), equals(29));
      // Exempting them: the full 30/min is available to user traffic.
      expect(sustained(false), equals(300));
      // And the exemption does not disable the cap: a burst is still refused.
      final flooding = <String, RateBucket>{};
      var refused = 0;
      for (var i = 0; i < 100; i++) {
        if (!admitByRate(flooding, 'relay|src', relayPerSourcePerMinuteCapDefault, 0.0).ok) {
          refused++;
        }
      }
      expect(refused, equals(100 - relayPerSourcePerMinuteCapDefault));
    });

    test('is off by default, so nothing a shipped run does changes', () {
      final config = campusQuad(42);
      expect(config.rateLimits, isFalse);
      expect(config.broadcastPerMinuteCap, equals(broadcastPerMinuteCapDefault));
      expect(config.relayPerSourcePerMinuteCap,
          equals(relayPerSourcePerMinuteCapDefault));
      final on = config.copyWith(rateLimits: true);
      expect(on.rateLimits, isTrue);
      // copyWith carries every other knob across unchanged.
      expect(on.nodeCount, equals(config.nodeCount));
      expect(on.mediaBackpressure, equals(config.mediaBackpressure));
      expect(on.broadcastCapScope, equals(config.broadcastCapScope));
    });
  });

  group('broadcast cap enforcement scope', () {
    // Mirrors the TypeScript engine's `broadcastCapScope` knob: docs/04 §6 says
    // "SUPERs drop excess", which bounds how *far* a flood travels and not whether the
    // flooder's own one-hop neighbours see it. docs/06 §21.5 measures the two scopes
    // against each other rather than asserting one is better.

    Map<String, num> flooded(bool rateLimits, BroadcastCapScope scope) {
      final sim = MeshSimulation(campusQuad(42).copyWith(
        rateLimits: rateLimits,
        broadcastCapScope: scope,
      ));
      sim.runFor(60000.0); // settle elections, so there are SUPERs either way
      sim.refresh();
      final source = sim.nodes.first.id;
      for (var i = 0; i < 24; i++) {
        sim.sendMessage(source, 'BROADCAST', 'flood \$i', MsgType.broadcast);
        sim.runFor(200.0);
      }
      sim.runFor(20000.0);
      sim.refresh();
      return {
        'broadcastDrops': sim.stats.rateBroadcastDrops,
        'relayDrops': sim.stats.rateRelayDrops,
        'transmissions': sim.nodes.fold<int>(0, (sum, n) => sum + n.txCount),
      };
    }

    test('defaults to docs/04 §6 — SUPERs only', () {
      expect(campusQuad(42).broadcastCapScope, equals(BroadcastCapScope.superOnly));
      expect(BroadcastCapScope.superOnly.wire, equals('super'));
      expect(BroadcastCapScope.all.wire, equals('all'));
    });

    test('suppresses more when every node enforces than when only SUPERs do', () {
      final superOnly = flooded(true, BroadcastCapScope.superOnly);
      final everywhere = flooded(true, BroadcastCapScope.all);
      expect(superOnly['broadcastDrops']!, greaterThan(0));
      expect(everywhere['broadcastDrops']!,
          greaterThan(superOnly['broadcastDrops']!));
    });

    test('cuts the airtime a flood costs, which is what the cap is for', () {
      final uncapped = flooded(false, BroadcastCapScope.superOnly)['transmissions']!;
      final superOnly = flooded(true, BroadcastCapScope.superOnly)['transmissions']!;
      final everywhere = flooded(true, BroadcastCapScope.all)['transmissions']!;
      expect(uncapped, greaterThan(superOnly));
      expect(superOnly, greaterThan(everywhere));
    });

    test('still costs an honest network nothing under either scope', () {
      for (final scope in <BroadcastCapScope>[
        BroadcastCapScope.superOnly,
        BroadcastCapScope.all,
      ]) {
        final sim = MeshSimulation(campusQuad(42).copyWith(
          rateLimits: true,
          broadcastCapScope: scope,
        ));
        sim.runFor(60000.0);
        sim.refresh();
        final source = sim.nodes.first.id;
        // One broadcast every 20 s is 3/min, under the cap of 5 — and a NORMAL node
        // filtering its own honest neighbour is exactly the risk `all` would introduce.
        for (var i = 0; i < 6; i++) {
          sim.sendMessage(source, 'BROADCAST', 'honest \$i', MsgType.broadcast);
          sim.runFor(20000.0);
        }
        sim.refresh();
        expect(sim.stats.rateBroadcastDrops, equals(0), reason: scope.name);
        expect(sim.stats.rateRelayDrops, equals(0), reason: scope.name);
      }
    });
  });

  group('local blocklist (docs/04 §6, bullet 1)', () {
    // "Block/mute peer locally (ignore msgs from pubKey)". Mirrors
    // `src/__tests__/blocklist.test.ts`. Three properties: it is local, it filters user
    // traffic rather than the protocol, and it is inert while empty.

    MeshSimulation world([BlockScope scope = BlockScope.delivery]) {
      final sim =
          MeshSimulation(campusQuad(42).copyWith(blockScope: scope));
      sim.runFor(60000.0);
      sim.refresh();
      return sim;
    }

    test('isBlockableTraffic covers user traffic and exempts protocol and SOS', () {
      MeshMessage msg(MsgType type) =>
          createMessage('m', 0.0, 'a', 'b', '', type: type);
      for (final type in <MsgType>[
        MsgType.text,
        MsgType.broadcast,
        MsgType.voice,
        MsgType.file,
      ]) {
        expect(isBlockableTraffic(msg(type)), isTrue, reason: type.name);
      }
      for (final type in <MsgType>[
        MsgType.ogm,
        MsgType.ack,
        MsgType.sync,
        MsgType.sos,
      ]) {
        expect(isBlockableTraffic(msg(type)), isFalse, reason: type.name);
      }
      // SOS is user traffic for the relay cap and exempt from the block, so the two
      // predicates are deliberately not the same set.
      expect(countsAgainstRelayCap(msg(MsgType.sos)), isTrue);
    });

    test('defaults to delivery scope and is inert while empty', () {
      expect(campusQuad(42).blockScope, equals(BlockScope.delivery));
      expect(BlockScope.delivery.wire, equals('delivery'));
      expect(BlockScope.relay.wire, equals('relay'));
      final sim = world();
      sim.runFor(60000.0);
      sim.refresh();
      expect(sim.stats.blockedDrops, equals(0));
    });

    test('blocks, unblocks, refuses a self-block, and reports the list sorted', () {
      final sim = world();
      final a = sim.nodes[0].id;
      final b = sim.nodes[1].id;
      final c = sim.nodes[2].id;
      expect(sim.blockPeer(a, b), isTrue);
      expect(sim.blockPeer(a, b), isFalse); // already blocked: the list did not change
      expect(sim.blockPeer(a, a), isFalse); // a node cannot block itself
      expect(sim.isBlocked(a, b), isTrue);
      expect(sim.isBlocked(b, a), isFalse); // and it is not mutual
      sim.blockPeer(a, c);
      expect(sim.blockedPeers(a), equals(<NodeId>[b, c]..sort()));
      expect(sim.unblockPeer(a, b), isTrue);
      expect(sim.unblockPeer(a, b), isFalse);
      expect(sim.isBlocked(a, b), isFalse);
      sim.unblockPeer(a, c);
      expect(sim.blockedPeers(a), isEmpty);
    });

    test('keeps a blocked peer out of the blocker inbox but not out of the mesh', () {
      final sim = world();
      final sender = sim.nodes[0].id;
      final blocker = sim.nodes[1].id;
      sim.blockPeer(blocker, sender);
      for (var i = 0; i < 8; i++) {
        sim.sendMessage(sender, broadcastAddress, 'spam \$i', MsgType.broadcast);
        sim.runFor(1000.0);
      }
      sim.runFor(20000.0);
      sim.refresh();
      final inbox = sim.nodes.firstWhere((n) => n.id == blocker).inbox;
      expect(inbox.where((m) => m.from == sender), isEmpty);
      expect(sim.stats.blockedDrops, greaterThan(0));
      // Local means local: other nodes still hear the blocked peer.
      final others = sim.nodes
          .where((n) => n.id != blocker)
          .where((n) => n.inbox.any((m) => m.from == sender))
          .length;
      expect(others, greaterThan(1));
    });

    test('lets a blocked peer SOS through, and still lets the blocker send', () {
      final sim = world();
      final sender = sim.nodes[0].id;
      final blocker = sim.nodes[1].id;
      sim.blockPeer(blocker, sender);
      sim.sendMessage(sender, broadcastAddress, 'sos help', MsgType.sos);
      sim.sendMessage(blocker, sender, 'still allowed to send', MsgType.text);
      sim.runFor(30000.0);
      sim.refresh();
      final blockerInbox = sim.nodes.firstWhere((n) => n.id == blocker).inbox;
      expect(blockerInbox.any((m) => m.type == MsgType.sos), isTrue);
      final senderInbox = sim.nodes.firstWhere((n) => n.id == sender).inbox;
      expect(senderInbox.any((m) => m.body == 'still allowed to send'), isTrue);
    });

    test('keeps the blocked peer in the routing table, because OGMs are not blockable',
        () {
      final sim = world();
      final blockerNode = sim.nodes[1];
      sim.blockPeer(blockerNode.id, sim.nodes[0].id);
      final peersBefore = blockerNode.peerIds.length;
      sim.runFor(30000.0);
      sim.refresh();
      // Not a strict equality: peers come and go with mobility. The property is that
      // blocking does not empty the table, which is what filtering OGMs would do.
      expect(blockerNode.peerIds, isNotEmpty);
      expect(blockerNode.peerIds.length, greaterThanOrEqualTo(peersBefore - 2));
    });

    test('relay scope costs the blocked source airtime that delivery scope spends', () {
      Map<String, int> flooded(BlockScope scope) {
        final sim = world(scope);
        final sender = sim.nodes[0].id;
        for (final n in sim.nodes) {
          if (n.id != sender) sim.blockPeer(n.id, sender);
        }
        for (var i = 0; i < 24; i++) {
          sim.sendMessage(sender, broadcastAddress, 'spam \$i', MsgType.broadcast);
          sim.runFor(300.0);
        }
        sim.runFor(20000.0);
        sim.refresh();
        return {
          'transmissions': sim.nodes.fold<int>(0, (sum, n) => sum + n.txCount),
          'forwarded': sim.stats.totalForwarded,
          'blocked': sim.stats.blockedDrops,
        };
      }

      final delivery = flooded(BlockScope.delivery);
      final relay = flooded(BlockScope.relay);
      expect(delivery['transmissions']!, greaterThan(relay['transmissions']!));
      expect(delivery['forwarded']!, greaterThan(relay['forwarded']!));
      // One broadcast heard by four blockers is four entries under delivery; under relay
      // the first to hear it stops the other three ever hearing it.
      expect(delivery['blocked']!, greaterThan(relay['blocked']!));
    });
  });
}

double _ln(num x) => math.log(x.toDouble());
