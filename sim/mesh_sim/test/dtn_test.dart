import 'package:duman_mesh_sim/mesh_sim.dart';
import 'package:test/test.dart';

/// Store-carry-forward against `skills/04` (docs/06 §20).
///
/// Mirrors `store-carry-forward against skills/04` in
/// `src/__tests__/simulation.test.ts`, including the two defects whose fixes it pins:
/// sprayed copies must not reuse the source retries' attempt numbers, and a carried
/// bundle with no route must be parked rather than deleted by flood suppression.
void main() {
  /// A-B-C in a line, 20 m apart: A and C are 40 m apart, which is outside the 31.6 m
  /// line-of-sight budget, so every bundle between them has to be carried by B.
  MeshSimulation carryWorld({bool dtnPreferSuper = false}) {
    final sim = MeshSimulation(SimConfig(
      nodeCount: 3,
      stationaryRatio: 1.0,
      chargingRatio: 0.0,
      trafficIntervalMs: 0,
      enableSuperElection: false,
      warmupMs: 0,
      obstacles: const <Obstacle>[],
      captureLog: true,
      dtnPreferSuper: dtnPreferSuper,
    ));
    for (var i = 0; i < sim.nodes.length; i++) {
      final node = sim.nodes[i];
      node.pos = Vec2(10.0 + i * 20, 10);
      node.target = Vec2(10.0 + i * 20, 10);
      node.mobility = 0;
      node.isOnline = true;
      node.battery = 1.0;
    }
    sim.runFor(20000);
    sim.clearRecords();
    return sim;
  }

  group('store-carry-forward against skills/04', () {
    test('carries a bundle for a destination that was offline, and delivers it on contact',
        () {
      // skills/04 acceptance: "A→C: A enqueues for C (C offline); B meets A then later C →
      // C receives (carry test)".
      final sim = carryWorld();
      final a = sim.nodes[0];
      final c = sim.nodes[2];
      sim.toggleNodeOnline(c.id); // C walks away: no route, no contact
      final msg = sim.sendMessage(a.id, c.id, 'carry me')!;
      sim.runFor(30000); // retries exhaust, the bundle is parked
      expect(a.oppQueue.map((q) => q.msg.id), contains(msg.id));
      expect(a.oppQueue.first.msg.carried, isTrue);
      expect(sim.refresh().totalQueued, greaterThan(0));

      sim.toggleNodeOnline(c.id); // ... and comes back, within B's range but not A's
      var elapsed = 0.0;
      while (sim.deliveries.where((d) => d.msgId == msg.id).isEmpty &&
          elapsed < 300000) {
        sim.runFor(250);
        elapsed += 250;
      }
      final arrived = sim.deliveries.where((d) => d.msgId == msg.id).toList();
      expect(arrived.length, equals(1));
      // It arrived opportunistically, so it is marked as carried and stays out of the
      // latency budget docs/04 §5 writes for routed traffic.
      expect(arrived.first.dtn, isTrue);
      expect(c.inbox.any((m) => m.id == msg.id), isTrue);

      // What the ACK does and does not clean up: it goes to the carrier that handed the
      // bundle over, so carriers on that reverse path prune; the originator is not on it,
      // and its copy waits for the seven-day TTL. The safety property is that the copy
      // cannot produce a second delivery, because the destination dedupes on the id.
      sim.runFor(120000);
      expect(sim.deliveries.where((d) => d.msgId == msg.id).length, equals(1));
      expect(c.inbox.where((m) => m.id == msg.id).length, equals(1));
    });

    test('never puts more than three copies of one bundle on air', () {
      // skills/04 acceptance: "Spray limit: same msg not duplicated >3x in network
      // capture" — counted from the capture log, which is the network's view, rather than
      // from queue state.
      final sim = carryWorld();
      final a = sim.nodes[0];
      final c = sim.nodes[2];
      sim.toggleNodeOnline(c.id);
      final msg = sim.sendMessage(a.id, c.id, 'spray me')!;
      sim.runFor(30000);
      sim.toggleNodeOnline(c.id);
      sim.runFor(120000);

      final carrierCopies = sim.log
          .where((l) =>
              l.kind == MeshLogKind.tx && l.msgId == msg.id && l.nodeId != a.id)
          .length;
      expect(carrierCopies, lessThanOrEqualTo(sprayLimit));
      for (final n in sim.nodes) {
        for (final q in n.oppQueue.where((q) => q.msg.id == msg.id)) {
          expect(q.copyCount, lessThanOrEqualTo(sprayLimit));
        }
      }
    });

    test('hands a bundle to a SUPER only when asked to, and never past the spray limit',
        () {
      // skills/04: "DO prefer SUPER as bundle carrier". Implemented and off by default,
      // because in a partitioned world it is pure cost and in a crowd it costs delivery
      // once carried bundles are parked rather than suppressed (docs/06 §20.4).
      final on = MeshSimulation(
          buildScenario('partitioned_pair', 42).copyWith(dtnPreferSuper: true));
      on.runFor(90000);
      on.clearRecords();
      final online = on.nodes.where((n) => n.isOnline).toList();
      for (var i = 0; i < 40; i++) {
        final from = online[i % online.length];
        var to = online[(i * 5 + 3) % online.length];
        if (to.id == from.id) to = online[(i + 1) % online.length];
        on.sendMessage(from.id, to.id, 'dtn-$i');
        on.runFor(1500);
      }
      on.runFor(60000);
      final stats = on.refresh();
      expect(stats.dtnSuperCarries, greaterThan(0));
      for (final n in on.nodes) {
        expect(n.oppQueue.length, lessThanOrEqualTo(oppQueueMax));
        for (final q in n.oppQueue) {
          expect(q.copyCount, lessThanOrEqualTo(sprayLimit));
        }
      }

      final off = MeshSimulation(buildScenario('partitioned_pair', 42));
      expect(off.config.dtnPreferSuper, isFalse);
      off.runFor(90000);
      off.clearRecords();
      expect(off.refresh().dtnSuperCarries, equals(0));
    });

    test('prunes a bundle when its ACK is overheard, and evicts by priority then age', () {
      final node = makeNode('carrier', 0, 0);
      node.oppQueue.clear();
      enqueueOpp(
          node,
          createMessage('old-low', 0, 'a', 'c', 'x')
              .copyWith(priority: Priority.low),
          0);
      enqueueOpp(node, createMessage('normal', 50, 'a', 'c', 'z'), 50);
      enqueueOpp(
          node,
          createMessage('new-low', 100, 'a', 'c', 'y')
              .copyWith(priority: Priority.low),
          100);
      expect(node.oppQueue.map((q) => q.msg.id).toList(),
          equals(<String>['old-low', 'normal', 'new-low']));

      // skills/04: "On ackReceived from dest: remove + gossip ACK (so relays can prune)".
      expect(pruneAcked(node, 'normal'), equals(1));
      expect(node.oppQueue.map((q) => q.msg.id).toList(),
          equals(<String>['old-low', 'new-low']));
      expect(pruneAcked(node, 'normal'), equals(0)); // idempotent, and quiet when empty

      // The cap keeps the newest 500 by priority: both demoted bundles go before any
      // normal one, however fresh, and the older of the two goes first.
      for (var i = 0; i < oppQueueMax; i++) {
        enqueueOpp(node, createMessage('fill-$i', 200.0 + i, 'a', 'c', 'f'), 200.0 + i);
      }
      expect(node.oppQueue.length, equals(oppQueueMax));
      expect(node.oppQueue.any((q) => q.msg.id == 'old-low'), isFalse);
      expect(node.oppQueue.any((q) => q.msg.id == 'new-low'), isFalse);
      expect(node.oppQueue.any((q) => q.msg.id == 'normal'), isFalse);
      expect(node.oppQueue.any((q) => q.msg.id == 'fill-0'), isTrue);
      expect(node.oppQueue.any((q) => q.msg.id == 'fill-${oppQueueMax - 1}'), isTrue);

      // Expiry is a real seven days of simulation time, which is 2.4 M physics ticks and
      // not runnable event by event, so the boundary is asserted on the sweeper itself.
      final stale = makeNode('stale', 0, 0);
      stale.oppQueue.clear();
      enqueueOpp(stale, createMessage('week-old', 0, 'a', 'c', 'w'), 0);
      pruneOppQueue(stale, oppTtlMs);
      expect(stale.oppQueue.length, equals(1));
      pruneOppQueue(stale, oppTtlMs + 1);
      expect(stale.oppQueue.length, equals(0));
    });

    test('a carried bundle is parked, never suppressed, at every hop', () {
      // The second of the two defects: with the destination offline a carrier's route
      // lookup fails, the copy used to fall into the flood branch, and a NORMAL node
      // MPR-suppressed it — deleting the message it was supposed to be carrying.
      final sim = carryWorld();
      final a = sim.nodes[0];
      final c = sim.nodes[2];
      sim.toggleNodeOnline(c.id);
      final msg = sim.sendMessage(a.id, c.id, 'park me')!;
      sim.runFor(40000);
      sim.toggleNodeOnline(c.id);
      sim.runFor(60000);

      // Somebody other than the originator parked a copy: the bundle travelled as a
      // bundle rather than being deleted at the first relay with no route.
      final queuedElsewhere = sim.log
          .where((l) =>
              l.kind == MeshLogKind.queue &&
              l.msgId == msg.id &&
              l.nodeId != a.id)
          .length;
      expect(queuedElsewhere, greaterThan(0));
      expect(
        sim.log.any((l) =>
            l.kind == MeshLogKind.decision &&
            l.msgId == msg.id &&
            l.detail.contains('carried bundle')),
        isTrue,
      );
    });
  });
}
