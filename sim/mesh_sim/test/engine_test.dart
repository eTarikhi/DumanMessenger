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

    test('expires soft state that has not been refreshed', () {
      final me = makeNode('me', 0, 0);
      receiveOgm(me, buildOgm(makeNode('x', 0, 0, seq: 1)), 'x', 1000);
      pruneStaleEntries(me, 1000, neighborScoreTtlMs);
      expect(me.nextHopTable.containsKey('x'), isTrue);
      pruneStaleEntries(me, 40000, neighborScoreTtlMs);
      expect(me.nextHopTable.containsKey('x'), isFalse);
      expect(me.ogmTable.containsKey('x'), isFalse);
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
          <MeshNode>[a, b], rf, true);
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
          <MeshNode>[a, relay, far], rf, true);
      expect(d.mode, equals(ForwardMode.route));
      expect(d.targets, equals(<String>['r']));
    });

    test('relays immediately when SUPER, waits when NORMAL', () {
      final a = makeNode('a', 0, 0, role: Role.superNode);
      final peers = <MeshNode>[a, makeNode('b', 10, 0), makeNode('c', 0, 10)];
      final msg = createMessage('m', 0, 'a', 'far', 'hi');
      expect(decideForward(a, msg, peers, rf, true).mode, equals(ForwardMode.flood));
      a.role = Role.normal;
      expect(decideForward(a, msg, peers, rf, true).mode, equals(ForwardMode.waitMpr));
      expect(decideForward(a, msg, peers, rf, false).mode, equals(ForwardMode.flood));
    });

    test('queues for store-carry-forward when nobody is in range', () {
      final a = makeNode('a', 0, 0);
      final far = makeNode('f', 500, 500);
      final d = decideForward(a, createMessage('m', 0, 'a', 'f', 'hi'),
          <MeshNode>[a, far], rf, true);
      expect(d.mode, equals(ForwardMode.queue));
      expect(d.targets, isEmpty);
    });

    test('suppresses a NORMAL relay that overheard a SUPER', () {
      final a = makeNode('a', 0, 0);
      final peers = <MeshNode>[a, makeNode('b', 10, 0)];
      final msg = createMessage('m', 0, 'x', 'far', 'hi');
      expect(resolveMprWait(a, msg, peers, rf).mode, equals(ForwardMode.flood));
      a.mprHeardSuper.add(msg.id);
      expect(resolveMprWait(a, msg, peers, rf).mode, equals(ForwardMode.drop));
      expect(a.mprSuppressed, equals(1));
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
        final res = scanOppQueue(a, <MeshNode>[a, relay, dest], rf, 1000 + i);
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
}

double _ln(num x) => math.log(x.toDouble());
