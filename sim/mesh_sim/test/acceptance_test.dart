import 'dart:math' as math;

import 'package:duman_mesh_sim/mesh_sim.dart';
import 'package:test/test.dart';

/// Acceptance criteria, transcribed from the repo's own targets:
///
///   skills/02-qa-mesh-routing.skill.md
///     "Simulator 20 nodes: SUPER ratio 15-25%, delivery >=90% at 3 hops,
///      overhead <=70% of flood-all."
///
///   skills/08-qa-simulator.skill.md
///     "CI simulator: 20-node seed -> delivery >=90% <5 hops,
///      overhead down 30% vs naive flood."
///
///   docs/04-offline-first-architecture.md §5
///     "1 hop: < 2 s ; 3 hops: < 5 s"
///
/// "delivery >=90% <5 hops" is read as: at least 90% of *sent* messages arrive
/// within five radio hops. ACKs and broadcasts are excluded so control traffic
/// cannot inflate the ratio.
const List<int> _seeds = <int>[42, 7, 1234];
const int _messages = 150;
const double _gapMs = 1500;

class _Run {
  _Run({
    required this.sent,
    required this.stats,
    required this.deliveredUnicast,
    required this.withinFiveHops,
    required this.overheadVsFlood,
    required this.baselineRelays,
    required this.oneHopMaxMs,
    required this.threeHopMaxMs,
    required this.isolatedNodes,
    required this.avgPeers,
  });

  final int sent;
  final SimulationStats stats;
  final int deliveredUnicast;
  final int withinFiveHops;
  final double overheadVsFlood;

  /// Relay count of the flood-all arm. Carried so the guard that used to sit in
  /// [_measure] can be asserted from inside a test instead.
  final int baselineRelays;
  final double oneHopMaxMs;
  final double threeHopMaxMs;
  final int isolatedNodes;
  final double avgPeers;

  double get deliveryRatio => deliveredUnicast / math.max(1, sent);
  double get withinFiveRatio => withinFiveHops / math.max(1, sent);
}

/// Identical traffic for both arms of the A/B — see bin/mesh_sim.dart.
List<List<int>> _trafficPlan(int seed, int count, int nodeCount) {
  final rng = createRng((seed ^ 0x5bf03635) & 0xFFFFFFFF);
  final plan = <List<int>>[];
  for (var i = 0; i < count; i++) {
    final from = (rng() * nodeCount).floor();
    var to = (rng() * nodeCount).floor();
    var guard = 0;
    while (to == from && guard++ < 32) {
      to = (rng() * nodeCount).floor();
    }
    if (to != from) plan.add(<int>[from, to]);
  }
  return plan;
}

int _replay(MeshSimulation sim, List<List<int>> plan) {
  var sent = 0;
  for (var i = 0; i < plan.length; i++) {
    final from = sim.nodes[plan[i][0]];
    final to = sim.nodes[plan[i][1]];
    if (from.isOnline && to.isOnline) {
      if (sim.sendMessage(from.id, to.id, 'acc-$i') != null) sent++;
    }
    sim.runFor(_gapMs);
  }
  sim.refresh();
  return sent;
}

_Run _measure(SimConfig config, {bool baseline = true}) {
  final sim = MeshSimulation(config);
  final plan = _trafficPlan(config.seed, _messages, config.nodeCount);
  final sent = _replay(sim, plan);

  var baselineRelays = sim.stats.totalForwarded;
  if (baseline) {
    final flood = MeshSimulation(config.copyWith(relayPolicy: RelayPolicy.floodAll));
    _replay(flood, plan);
    baselineRelays = flood.stats.totalForwarded;
  }

  final uni = sim.deliveries
      .where((d) => d.type != MsgType.ack && d.type != MsgType.broadcast)
      .toList();
  // The docs/04 per-hop budget applies to traffic that was routed on its first
  // attempt: a retry legitimately adds a whole ACK timeout, and a bundle that
  // waited for a human to walk past is measuring a meeting time, not transport.
  final routed = uni.where((d) => d.attempt == 0 && !d.dtn).toList();
  final oneHop = routed.where((d) => d.hops == 1).map((d) => d.latencyMs).toList();
  final threeHop = routed.where((d) => d.hops <= 3).map((d) => d.latencyMs).toList();

  return _Run(
    sent: sent,
    stats: sim.stats,
    deliveredUnicast: uni.length,
    withinFiveHops: uni.where((d) => d.hops <= 5).length,
    overheadVsFlood: sim.stats.totalForwarded / math.max(1, baselineRelays),
    baselineRelays: baselineRelays,
    oneHopMaxMs: oneHop.isEmpty ? 0.0 : oneHop.reduce(math.max),
    threeHopMaxMs: threeHop.isEmpty ? 0.0 : threeHop.reduce(math.max),
    isolatedNodes: sim.stats.isolatedNodes,
    avgPeers: sim.stats.avgPeers,
  );
}

void main() {
  final runs = <int, _Run>{
    for (final seed in _seeds) seed: _measure(campusQuad(seed)),
  };

  group('skills/02 + skills/08 acceptance — campus quad, 20 nodes', () {
    for (final seed in _seeds) {
      test('seed $seed elects a stable 15-25% super-node set', () {
        final r = runs[seed]!;
        expect(r.stats.superRatio, greaterThanOrEqualTo(0.15));
        expect(r.stats.superRatio, lessThanOrEqualTo(0.25));
        expect(r.stats.electionsPerMin, lessThanOrEqualTo(1.0));
      });

      test('seed $seed delivers >=90% of messages', () {
        expect(runs[seed]!.deliveryRatio, greaterThanOrEqualTo(0.90));
      });

      test('seed $seed delivers >=90% within five hops', () {
        final r = runs[seed]!;
        expect(r.withinFiveRatio, greaterThanOrEqualTo(0.90));
        expect(r.stats.avgHops, lessThanOrEqualTo(3.0));
      });

      test('seed $seed uses <=70% of the naive flood-all relay budget', () {
        final r = runs[seed]!;
        // A ratio against an empty baseline would be meaningless, and this used
        // to be guarded inside _measure, where expect() cannot run.
        expect(r.baselineRelays, greaterThan(0));
        expect(r.overheadVsFlood, lessThanOrEqualTo(0.70));
      });

      test('seed $seed keeps a connected world with no isolated node', () {
        final r = runs[seed]!;
        expect(r.isolatedNodes, equals(0));
        expect(r.avgPeers, greaterThan(3));
      });

      test('seed $seed respects the docs/04 latency budget', () {
        final r = runs[seed]!;
        expect(r.oneHopMaxMs, lessThan(2000)); // 1 hop < 2 s
        expect(r.threeHopMaxMs, lessThan(5000)); // 3 hops < 5 s
      });
    }

    test('MPR suppression actually fires', () {
      for (final seed in _seeds) {
        expect(runs[seed]!.stats.mprSuppressed, greaterThan(0));
      }
    });
  });

  group('dense crowd (docs/02 §6: 50+ nodes)', () {
    test('stays stable and cheap at 60 nodes', () {
      final r = _measure(festivalCrowd(42));
      expect(r.stats.superRatio, inInclusiveRange(0.10, 0.30));
      expect(r.stats.roleChangesPerNodeMin, lessThanOrEqualTo(1.0));
      expect(r.stats.avgHops, lessThanOrEqualTo(4.0));
      expect(r.deliveryRatio, greaterThanOrEqualTo(0.85));
      // 12-14% of the naive epidemic budget measured; the documented bar is 70%.
      expect(r.overheadVsFlood, lessThanOrEqualTo(0.20));
      expect(r.stats.mprSuppressed, greaterThan(1000));
    });
  });

  group('skills/08 configuration envelope', () {
    test('supports the documented node counts and areas', () {
      for (final nodeCount in <int>[10, 60]) {
        final sim = MeshSimulation(campusQuad(42).copyWith(nodeCount: nodeCount));
        sim.runFor(2000);
        expect(sim.nodes, hasLength(nodeCount));
      }
      final sim = MeshSimulation(const SimConfig(
          areaWidth: 200, areaHeight: 120, wallPenaltyDb: 20));
      for (final n in sim.nodes) {
        expect(n.pos.x, lessThanOrEqualTo(200));
        expect(n.pos.y, lessThanOrEqualTo(120));
      }
      expect(sim.rf.wallPenaltyDb, equals(20));
    });

    test('exposes the metrics skills/08 requires per run', () {
      final s = runs[42]!.stats;
      expect(s.deliveryRatio, isA<double>());
      expect(s.overheadRatio, isA<double>()); // relays / delivered
      expect(s.p50LatencyMs, isA<double>());
      expect(s.p95LatencyMs, isA<double>());
      expect(s.electionsPerMin, isA<double>()); // superStability
      expect(s.toJson(), contains('deliveryRatio'));
    });
  });

  group('delay-tolerant scenarios', () {
    test('carries traffic in a sparse village instead of dropping it', () {
      final r = _measure(sparseVillage(42), baseline: false);
      expect(r.stats.totalQueued, greaterThan(0));
    });

    test('every named scenario builds and runs', () {
      expect(scenarioNames(),
          equals(<String>['campus_quad', 'sparse_village', 'festival_crowd', 'partitioned_pair']));
      for (final name in scenarioNames()) {
        final sim = MeshSimulation(buildScenario(name, 42));
        sim.runFor(2000);
        expect(sim.nodes, isNotEmpty);
      }
      expect(() => buildScenario('nope'), throwsArgumentError);
    });
  });

  test('supports the documented 10-200 node range without a quadratic fallback',
      () {
    // skills/08: "Configurable: nodeCount 10-200, area 100x100m". The top of that
    // range is one radio cell — at 200 nodes every node hears ~179 of the other 199
    // — so a beacon cannot describe the neighbourhood and the MPR coverage question
    // is unanswerable. Unbounded, the fallback cost 531 transmissions per message
    // (one 3-hop delivery: 7,038); bounded to six direction-spread peers it is ~125
    // at 98.3% delivery. See docs/06 §15.
    for (final nodeCount in <int>[10, 200]) {
      final sim = MeshSimulation(campusQuad(42).copyWith(nodeCount: nodeCount));
      sim.runFor(sim.config.warmupMs);
      sim.clearRecords();
      var sent = 0;
      for (var i = 0; i < 6; i++) {
        final from = 'node-${i % nodeCount}';
        final to = 'node-${(i * 37 + 11) % nodeCount}';
        if (sim.sendMessage(from, to, 'scale-$i') != null) sent++;
        sim.runFor(1500);
      }
      sim.refresh();
      expect(sim.nodes.length, equals(nodeCount), reason: '$nodeCount nodes');
      expect(sim.stats.isolatedNodes, equals(0), reason: '$nodeCount nodes');
      final uni = sim.deliveries
          .where((d) =>
              d.type != MsgType.ack &&
              d.type != MsgType.broadcast &&
              d.groupId == null)
          .toList();
      expect(uni.length / sent, greaterThanOrEqualTo(0.9), reason: '$nodeCount nodes');
      expect(sim.stats.totalForwarded / sent, lessThan(400), reason: '$nodeCount nodes');
    }
  });
}
