import 'dart:math' as math;

import 'package:duman_mesh_sim/mesh_sim.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Roadmap Phase 2's field-test criterion names a building feature — "atrium should
/// become SUPER" — and the simulator can answer it before anybody travels
/// (docs/06 §18, docs/09 §5).
///
/// Mirrors `the atrium becomes a router` in `src/__tests__/simulation.test.ts`.
void main() {
  /// The most open node in a world: the one that hears the most peers at the strongest
  /// average RSSI. Found by measurement rather than assumed from a floor plan.
  MeshNode mostOpenNode(MeshSimulation sim) {
    final online = sim.nodes.where((n) => n.isOnline).toList();
    var best = online.first;
    var bestScore = -1e9;
    for (final n in online) {
      final peers = peersInRange(n, online, sim.rf);
      var rssiSum = 0.0;
      for (final p in peers) {
        rssiSum += rssiModel(n, p, sim.rf);
      }
      final avg = peers.isNotEmpty ? rssiSum / peers.length : -120.0;
      final score = peers.length * 100 + avg;
      if (score > bestScore) {
        bestScore = score;
        best = n;
      }
    }
    return best;
  }

  group('the atrium becomes a router (docs/06 §18)', () {
    for (final name in scenarioNames()) {
      test('elects a healthy open node in $name within two cycles', () {
        final sim = MeshSimulation(
            buildScenario(name, 42).copyWith(enableMobility: false));
        sim.runFor(20000); // let the peer lists settle before judging who is open
        final atrium = mostOpenNode(sim);
        expect(peersInRange(atrium, sim.nodes.where((n) => n.isOnline).toList(), sim.rf),
            isNotEmpty);

        // Healthy as well as open: full battery, ten hours of uptime, a stationary phone
        // that has not been dropping packets. The second test shows why both halves are
        // needed.
        atrium.battery = 1.0;
        atrium.uptimeMin = 600;
        atrium.pdr = 0.99;
        atrium.mobility = 0;

        // Two election cycles at the 30 s interval: the criterion is not "eventually"
        // but "before the walk is over".
        sim.runFor(60000);
        expect(atrium.role, equals(Role.superNode));

        // And it is not luck: its score is at or above the mean of the elected set.
        final supers = sim.nodes.where((n) => n.role == Role.superNode).toList();
        final meanScore =
            supers.fold<double>(0, (a, n) => a + n.score) / supers.length;
        expect(atrium.score, greaterThanOrEqualTo(meanScore - 1e-9));
      });
    }

    test('weighs openness against health, and says where the crossover is', () {
      final rf = rfWith();
      expect(weights.peers + weights.rssi, closeTo(0.55, 1e-12));
      expect(
        weights.peers + weights.rssi + weights.battery + weights.stability + weights.pdr,
        closeTo(1.0, 1e-12),
      );
      expect(chargingBonus, equals(0.10));
      expect(batteryFloor, equals(0.25));

      /// A candidate with [peerCount] peers 12 m away in every direction.
      double score(int peerCount,
          {double battery = 0.8,
          double uptimeMin = 120,
          double pdr = 0.95,
          bool charging = false}) {
        final node = makeNode('candidate', 50, 50,
            battery: battery,
            uptimeMin: uptimeMin,
            pdr: pdr,
            charging: charging);
        final all = <MeshNode>[node];
        for (var i = 0; i < peerCount; i++) {
          final a = (i / math.max(1, peerCount)) * 2 * math.pi;
          all.add(makeNode('p$i', 50 + math.cos(a) * 12, 50 + math.sin(a) * 12));
        }
        return computeScore(node, all, rf);
      }

      // The atrium phone at the end of a long day, against a corridor phone that has been
      // sitting on a desk all week.
      final openButDrained = score(19, battery: 0.3, uptimeMin: 20, pdr: 0.9);
      final closedButHealthy = score(9, battery: 1.0, uptimeMin: 600, pdr: 0.99);
      expect(closedButHealthy, greaterThan(openButDrained));

      // The peer term is normalised logarithmically against 50 peers (docs/03 §3) and so
      // saturates: at 199 peers — more than any world in docs/06 §15 has nodes — the
      // drained phone still loses to a healthy one with nine.
      expect(score(199, battery: 0.3, uptimeMin: 20, pdr: 0.9),
          lessThan(closedButHealthy));
      expect(score(60, battery: 0.3, uptimeMin: 20, pdr: 0.9),
          lessThan(closedButHealthy));
      // Health has more range than position: the two position terms can contribute at most
      // 0.30 x log(1+P)/log(51) + 0.25, while battery, stability and pdr contribute up to
      // 0.45 between them.
      expect(weights.battery + weights.stability + weights.pdr, closeTo(0.45, 1e-12));
      // Plugging in changes the answer without changing the position.
      expect(
        score(9, battery: 0.3, uptimeMin: 20, pdr: 0.9, charging: true),
        greaterThan(score(9, battery: 0.4, uptimeMin: 20, pdr: 0.9)),
      );
    });
  });
}
