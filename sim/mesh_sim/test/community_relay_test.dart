import 'package:duman_mesh_sim/mesh_sim.dart';
import 'package:test/test.dart';

/// Cap-aware community-relay promotion, built and rejected (roadmap Phase 5,
/// docs/06 §19.4).
///
/// Mirrors `cap-aware community-relay promotion, measured and rejected` in
/// `src/__tests__/simulation.test.ts`. The point of the tests is not that the knob works —
/// it is that the knob cannot work the way it was proposed, and the reason is visible in
/// the election's own bookkeeping.
void main() {
  /// The `relays` most open positions in the crowd, plugged in and not moving: a café on a
  /// corner rather than a phone in somebody's pocket.
  ({MeshSimulation sim, List<MeshNode> tablets}) crowdArm(int seed, int relays, double quota) {
    final sim = MeshSimulation(
        festivalCrowd(seed).copyWith(communityRelayQuota: quota));
    sim.runFor(20000);
    final online = sim.nodes.where((n) => n.isOnline).toList();
    // Same ordering as the TypeScript harness: most peers first, and node id as the
    // tie-break, because Dart's sort is not stable and a tie would pick a different
    // tablet than the other engine did.
    final ranked = List<MeshNode>.of(online)..sort((a, b) {
      final byPeers = peersInRange(b, online, sim.rf)
          .length
          .compareTo(peersInRange(a, online, sim.rf).length);
      if (byPeers != 0) return byPeers;
      return a.id.compareTo(b.id);
    });
    final tablets = ranked.take(relays).toList();
    for (final n in tablets) {
      n.charging = true;
      n.stationary = true;
      n.battery = 1.0;
      n.superOptOut = false;
      n.batterySaver = false;
      n.uptimeMin = 600.0;
    }
    sim.runFor(60000);
    return (sim: sim, tablets: tablets);
  }

  int elected(List<MeshNode> tablets) =>
      tablets.where((n) => n.role == Role.superNode).length;

  test('the cap a tablet loses is being spent on other tablets, not on phones', () {
    final arm = crowdArm(42, 6, 0);
    expect(elected(arm.tablets), 4);

    final blocked =
        arm.tablets.where((n) => n.role != Role.superNode).toList();
    expect(blocked.length, 2);
    for (final n in blocked) {
      final better = peersInRange(n, arm.sim.nodes, arm.sim.rf)
          .where((p) => p.score > n.score)
          .toList();
      final tablets = better.where(isCommunityRelay).length;
      final phones = better.where((p) => !isCommunityRelay(p)).length;
      // Six plugged nodes in one crowd all hear each other, so the five top-20% slots they
      // are competing for are already theirs. Reserving part of the cap for community
      // relays cannot help a relay that lost to a better community relay.
      expect(tablets, greaterThan(phones));
      expect(phones, 0);
    }
  });

  test('exempting tablets from the cap elects all six and fills skills/02 band to the top',
      () {
    final capped = crowdArm(42, 6, 0);
    final exempt = crowdArm(42, 6, 1);
    expect(elected(capped.tablets), 4);
    expect(elected(exempt.tablets), 6);

    final supers = exempt.sim.nodes.where((n) => n.role == Role.superNode).length;
    expect(supers, 15);
    expect(supers / exempt.sim.nodes.length, closeTo(0.25, 1e-9));
    expect(supers,
        greaterThan(capped.sim.nodes.where((n) => n.role == Role.superNode).length));

    // Three tablets are all elected either way, so the exemption buys nothing at the scale
    // a real café programme would start at.
    expect(elected(crowdArm(42, 3, 1).tablets), elected(crowdArm(42, 3, 0).tablets));
  });

  test('reserving half the cap hands a slot to a phone instead', () {
    // A tablet already outscores every phone in range, so the reserved slots were theirs
    // before the reservation existed; taking them out of the open pool loosens the rule
    // for everybody else.
    final plain = crowdArm(42, 3, 0);
    final reserved = crowdArm(42, 3, 0.5);
    expect(elected(reserved.tablets), elected(plain.tablets));
    int phoneSupers(({MeshSimulation sim, List<MeshNode> tablets}) arm) => arm.sim.nodes
        .where((n) => n.role == Role.superNode && !isCommunityRelay(n))
        .length;
    expect(phoneSupers(reserved), phoneSupers(plain) + 1);
  });
}
