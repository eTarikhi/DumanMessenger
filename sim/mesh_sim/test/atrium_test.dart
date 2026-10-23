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

  group('observed-maximum peer normalisation, measured and rejected (docs/06 §18.4)', () {
    /// One world under one normalisation, reporting both the score and the quantity the
    /// election actually decides on: where that score ranks inside the node's own 1-hop
    /// candidacy list.
    ({
      MeshSimulation sim,
      MeshNode atrium,
      double score,
      int rank,
      int candidates,
      int cap,
      Role role,
      int supers,
    })
        atriumArm(String name, PeerNorm peerNorm) {
      final sim = MeshSimulation(buildScenario(name, 42)
          .copyWith(enableMobility: false, peerNorm: peerNorm));
      sim.runFor(20000);
      final atrium = mostOpenNode(sim);
      sim.runFor(60000);
      final online = sim.nodes.where((n) => n.isOnline).toList();
      final candidates = <MeshNode>[atrium]
        ..addAll(peersInRange(atrium, online, sim.rf)
            .where((p) => !(p.superOptOut || p.batterySaver)));
      final better = candidates.where((c) => c.score > atrium.score).length;
      return (
        sim: sim,
        atrium: atrium,
        score: atrium.score,
        rank: better + 1,
        candidates: candidates.length,
        cap: math.max(1, (candidates.length * topPercent).ceil()),
        role: atrium.role,
        supers: sim.nodes.where((n) => n.role == Role.superNode).length,
      );
    }

    test("raises every open node's score and leaves the ranking exactly where it was", () {
      // docs/06 §18.2 predicted this would make openness decisive in sparse worlds. It does
      // not: an election is a ranking and this is a level change, so every well-placed
      // neighbour gains the same way and the most open node in the world is beaten by the
      // same people it was beaten by before.
      for (final name in scenarioNames()) {
        final fixed = atriumArm(name, PeerNorm.fixed);
        final observed = atriumArm(name, PeerNorm.observed);
        expect(observed.score, greaterThan(fixed.score), reason: name);
        expect(observed.rank, equals(fixed.rank), reason: name);
        expect(observed.cap, equals(fixed.cap), reason: name);
        expect(observed.role, equals(fixed.role), reason: name);
      }
    });

    test('what it does move is the promote gate and the size of the elected set', () {
      // sparse_village: the atrium phone crosses the promote threshold only under the
      // observed denominator, and one more node in the world crosses with it.
      final villageFixed = atriumArm('sparse_village', PeerNorm.fixed);
      final villageObserved = atriumArm('sparse_village', PeerNorm.observed);
      expect(villageFixed.score, lessThan(superPromoteThreshold));
      expect(villageObserved.score, greaterThan(superPromoteThreshold));
      expect(villageObserved.supers, equals(villageFixed.supers + 1));

      // festival_crowd: the observed maximum *is* the crowd, so mid-open nodes lose score
      // and the elected set shrinks instead.
      final crowdFixed = atriumArm('festival_crowd', PeerNorm.fixed);
      final crowdObserved = atriumArm('festival_crowd', PeerNorm.observed);
      expect(crowdObserved.supers, equals(crowdFixed.supers - 2));
    });

    test("holds skills/02's band on the campus world, and puts one seed on its floor", () {
      final ratios = <double>[];
      for (final seed in <int>[42, 7, 1234, 99, 2026, 555]) {
        final sim = MeshSimulation(campusQuad(seed)
            .copyWith(peerNorm: PeerNorm.observed, trafficIntervalMs: 1000));
        sim.runFor(20000);
        sim.runFor(180000);
        ratios.add(sim.refresh().superRatio);
      }
      for (final r in ratios) {
        expect(r, greaterThanOrEqualTo(0.15));
        expect(r, lessThanOrEqualTo(0.25));
      }
      // Seed 99 lands exactly on the floor, which is the practical objection: the lever buys
      // nothing measurable and spends the band's margin doing it.
      expect(ratios.reduce(math.min), closeTo(0.15, 1e-9));
    });
  });
}
