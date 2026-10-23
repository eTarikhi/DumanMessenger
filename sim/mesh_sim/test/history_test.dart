import 'package:duman_mesh_sim/mesh_sim.dart';
import 'package:test/test.dart';

/// Group history anti-entropy (roadmap Phase 1: "SQLite + CRDT for group/broadcast
/// history (hash beacon anti-entropy)").
///
/// Mirrors the `group history anti-entropy` block in
/// `src/__tests__/simulation.test.ts`, including the digest fixed points, so a drift in
/// either engine fails CI.
void main() {
  /// A line of members 20 m apart, all in one group, so every member can hear every
  /// neighbour and a beacon reaches the peer it is addressed to in one hop.
  ({MeshSimulation sim, Group group, List<NodeId> ids}) lineGroup(
      {int n = 3, double historyBeaconMs = 10000, int historyReplyMax = 32}) {
    final sim = MeshSimulation(SimConfig(
      nodeCount: n,
      stationaryRatio: 1.0,
      chargingRatio: 0.0,
      trafficIntervalMs: 0,
      enableSuperElection: false,
      warmupMs: 0,
      // defaultConfig carries walls, and a wall between two nodes 20 m apart turns the
      // "line" into a partition. The geometry has to be the only variable here.
      obstacles: const <Obstacle>[],
      captureLog: true,
      historyBeaconMs: historyBeaconMs,
      historyReplyMax: historyReplyMax,
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
    final ids = sim.nodes.map((node) => node.id).toList();
    final group = sim.createGroup('field team', ids, ids.first)!;
    sim.runFor(2000);
    sim.clearRecords();
    return (sim: sim, group: group, ids: ids);
  }

  bool runUntil(MeshSimulation sim, bool Function() done, double budgetMs) {
    var elapsed = 0.0;
    while (!done() && elapsed < budgetMs) {
      sim.runFor(250);
      elapsed += 250;
    }
    return done();
  }

  HistoryEntry entry(String msgId) => HistoryEntry(
      msgId: msgId,
      groupId: 'grp-1',
      from: 'node-0',
      at: 0,
      body: msgId,
      epoch: 0);

  group('group history anti-entropy', () {
    test('repairs a flood a member missed while it was offline', () {
      final w = lineGroup();
      final sim = w.sim;
      final group = w.group;
      final ids = w.ids;
      sim.toggleNodeOnline(ids[2]);
      sim.sendMessage(ids[0], group.id, 'meet at the north gate');
      sim.runFor(4000);
      expect(
        sim.groupHistoryOf(ids[1], group.id).map((e) => e.body),
        contains('meet at the north gate'),
      );
      expect(sim.groupHistoryOf(ids[2], group.id), isEmpty); // it was away
      expect(sim.historyConverged(group), isFalse);

      sim.toggleNodeOnline(ids[2]);
      sim.runFor(30000); // three beacon intervals

      final recovered = sim.groupHistoryOf(ids[2], group.id);
      expect(recovered.map((e) => e.body), contains('meet at the north gate'));
      expect(recovered.first.synced, isTrue);
      expect(recovered.first.from, equals(ids[0]));
      expect(sim.refresh().historyEntriesSynced, equals(1));
      expect(sim.historyConverged(group), isTrue);
      expect(
        sim.log.any((l) =>
            l.kind == MeshLogKind.sync && l.detail.contains('recovered 1 message')),
        isTrue,
      );
    });

    test('digests a set, not a sequence: the union properties the merge relies on', () {
      // Cross-language fixed points — the TS engine asserts the same numbers.
      expect(fnv1a32('m1'), equals(2486071275));
      expect(fnv1a32('m2'), equals(2502848894));
      expect(fnv1a32('msg-0001'), equals(3384865146));
      expect(historyBucket('m1'), equals(11));
      expect(historyBucket('m2'), equals(14));
      expect(historyBucket('msg-0001'), equals(10));

      final three = <HistoryEntry>[entry('m1'), entry('m2'), entry('msg-0001')];
      final digest = historyDigest(three);
      expect(digest.count, equals(3));
      expect(digest.buckets.length, equals(historyBuckets));
      // Commutative: XOR over a set does not depend on arrival order.
      expect(historyDigest(three.reversed).buckets, equals(digest.buckets));
      // Associative: merging in two steps gives the same buckets as one.
      final staged = historyDigest(<HistoryEntry>[entry('m1')]);
      final rest =
          historyDigest(<HistoryEntry>[entry('m2'), entry('msg-0001')]);
      expect(
        List<int>.generate(historyBuckets,
            (i) => (staged.buckets[i] ^ rest.buckets[i]) & 0xffffffff),
        equals(digest.buckets),
      );
      // XOR folds a *set*: the same id twice cancels itself out. That is not a defect to
      // fix but the reason the store is keyed by message id and the merge is a union.
      final twice = historyDigest(<HistoryEntry>[...three, entry('m1')]);
      expect(twice.buckets[historyBucket('m1')], equals(0));
      expect(twice.count, equals(4)); // the count is not a set, so it still disagrees
    });

    test('keeps a beacon inside one BLE packet whatever the history holds', () {
      final empty = encodeHistoryBeacon('grp-1', 0, historyDigest(<HistoryEntry>[]));
      final full = encodeHistoryBeacon(
          'grp-1',
          0,
          historyDigest(List<HistoryEntry>.generate(400, (i) => entry('msg-$i'))));
      expect(empty.length, equals(156));
      // The only thing that grows with the history is the decimal entry count: 16 bucket
      // digests, not 400 ids.
      expect(full.length, equals(158));
      expect(wireSizeOf(empty.length), equals(256));
      expect(wireSizeOf(full.length), equals(256));
      expect(selectTransport(wireSizeOf(full.length)), equals(TransportType.ble));
    });

    test('repairs a long absence in bounded rounds rather than one huge reply', () {
      final w = lineGroup(historyReplyMax: 8);
      final sim = w.sim;
      final group = w.group;
      final ids = w.ids;
      sim.toggleNodeOnline(ids[2]);
      for (var i = 0; i < 20; i++) {
        sim.sendMessage(ids[0], group.id, 'status $i');
        sim.runFor(200);
      }
      sim.runFor(2000);

      sim.toggleNodeOnline(ids[2]);
      sim.runFor(12000); // one round
      final afterOne = sim.groupHistoryOf(ids[2], group.id).length;
      expect(afterOne, greaterThan(0));
      expect(afterOne, lessThan(20)); // the reply is capped at 8 entries

      // Rounds are 10 s apart, a round can be lost to link loss, and a copy one member
      // lost has to reach it from another member first — repair is transitive, so it is
      // given time rather than a fixed number of rounds. The sender always holds its own
      // entries, so a converged group necessarily holds all 20.
      expect(runUntil(sim, () => sim.historyConverged(group), 200000), isTrue);
      expect(sim.groupHistoryOf(ids[2], group.id).length, equals(20));
      expect(sim.groupHistoryOf(ids[1], group.id).length, equals(20));
      expect(sim.refresh().historyReplies, greaterThanOrEqualTo(3));
      expect(
        sim.log.any((l) =>
            l.kind == MeshLogKind.sync && l.detail.contains('missing entries')),
        isTrue,
      );
    });

    test('cannot repair history a key rotation made unreadable', () {
      final w = lineGroup();
      final sim = w.sim;
      final group = w.group;
      final ids = w.ids;
      sim.toggleNodeOnline(ids[2]);
      sim.sendMessage(ids[0], group.id, 'before the rotation');
      sim.runFor(3000);
      expect(sim.groupHistoryOf(ids[1], group.id).length, equals(1));

      // docs/06 §14: a rotation makes every older copy unreadable network-wide, so there
      // is nothing worth repairing — and the engine does not offer it.
      expect(sim.rotateGroupKey(group.id, group.adminId), isTrue);
      expect(sim.syncableHistory(sim.nodes[1], group).length, equals(0));

      sim.sendMessage(ids[0], group.id, 'after the rotation');
      sim.runFor(3000);
      sim.toggleNodeOnline(ids[2]);
      sim.runFor(40000);

      final recovered = sim.groupHistoryOf(ids[2], group.id).map((e) => e.body).toList();
      expect(recovered, contains('after the rotation'));
      expect(recovered, isNot(contains('before the rotation')));
      // Nothing stale was even put on air, so nothing had to be dropped on arrival.
      expect(sim.refresh().historyEpochDropped, equals(0));
      expect(sim.historyConverged(group), isTrue);
    });

    test('costs control traffic only: no ACKs, no deliveries, no unicast count', () {
      final w = lineGroup(n: 4);
      final sim = w.sim;
      sim.runFor(60000); // six beacon intervals, and not one group message
      final stats = sim.refresh();
      expect(stats.sentUnicast, equals(0));
      expect(stats.sentGroup, equals(0));
      expect(stats.sentSync, greaterThan(0));
      expect(stats.historyBeacons, greaterThan(0));
      expect(stats.acksReceived, equals(0)); // periodic, so a lost beacon is not retried
      expect(stats.deliveryRatio, equals(0.0));
      expect(sim.deliveries.where((d) => d.type != MsgType.sync), isEmpty);
      expect(stats.historyBytes, greaterThan(0));
      expect(
        sim.sentRecords
            .where((r) => r.type == MsgType.sync)
            .every((r) => r.body.startsWith('HB|')),
        isTrue,
      );
    });

    test('stops beaconing when a node leaves its last group, and can be switched off',
        () {
      final w = lineGroup(n: 4);
      final sim = w.sim;
      final group = w.group;
      final ids = w.ids;
      sim.runFor(12000);
      final before = sim.refresh().historyBeacons;
      expect(before, greaterThan(0));
      expect(sim.removeFromGroup(group.id, ids[3]), isTrue); // 4 -> 3 members
      sim.runFor(40000);
      expect(sim.refresh().historyBeacons, greaterThan(before));
      // The departed node contributes no more beacons; the three remaining members do.
      expect(
        sim.sentRecords.where((r) =>
            r.type == MsgType.sync &&
            r.from == ids[3] &&
            r.timestamp > sim.now - 40000),
        isEmpty,
      );

      final off = lineGroup(historyBeaconMs: 0);
      off.sim.sendMessage(off.ids[0], off.group.id, 'no repair here');
      off.sim.toggleNodeOnline(off.ids[2]);
      off.sim.runFor(60000);
      expect(off.sim.refresh().historyBeacons, equals(0));
      expect(off.sim.groupHistoryOf(off.ids[2], off.group.id), isEmpty);
      expect(off.sim.historyConverged(off.group), isFalse);
    });
  });
}
