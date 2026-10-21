/// Coverage-based super-node election — "Duman Adaptive Routing"
/// (docs/03-smart-router-algorithm.md, skills/02-super-node.skill.md).
///
///     coverageScore = 0.30*norm(peers) + 0.25*normRssi + 0.20*battery
///                   + 0.15*stability   + 0.10*pdr   (+0.10 charging)
///
/// Fully decentralised: no leader, no Raft. Each node self-scores, gossips the
/// score in its OGM, and self-promotes when it is in the top 20 % of the scores
/// it has heard from its 1-hop neighbourhood.
library;

import 'dart:math' as math;

import 'rf.dart';
import 'types.dart';

class Weights {
  const Weights();

  final double peers = 0.30;
  final double rssi = 0.25;
  final double battery = 0.20;
  final double stability = 0.15;
  final double pdr = 0.10;
}

const Weights weights = Weights();

const double chargingBonus = 0.10;
const double batteryFloor = 0.25;
const int minPeers = 3;
const double superPromoteThreshold = 0.60;
const double superDemoteThreshold = 0.50;
const double topPercent = 0.20;

/// docs/03 §5: "at most 1 SUPER per ~30 m radius ... RSSI > -60 (very close)".
///
/// Those two numbers only agree for the doc's original tx-power assumption. With
/// the calibrated radio used here (-55 dBm at 1 m) a hard-coded -60 dBm would
/// mean "~3 m", silently disabling the guard. The threshold is therefore derived
/// from the RF parameters so it keeps its documented *physical* meaning.
const double proximityRadiusM = 30;

double proximityRssiThreshold(RfParams rf) =>
    rf.txPowerDbm - 20 * (math.log(proximityRadiusM) / 2.302585092994046);

const double proximityScoreMargin = 0.10;
const int demoteCycles = 2;

/// tq below this makes a route unusable, so the router falls back to flood.
const double tqUsable = 0.60;
const int tqWindow = 32;

/// Bound on the neighbour list carried in an OGM.
///
/// OLSR HELLOs advertise the full 1-hop set. The cap must sit above the peer
/// count a scenario can actually produce, or the coverage gate can never be
/// satisfied and nothing is ever suppressed: at 12 entries a 60-node crowd with
/// 15-18 peers each truncated its advertisement, suppression collapsed from
/// 1772 to 110 and overhead went *up*. 30 matches the "local sort, k <= 30"
/// budget docs/03 §3 sets. A real deployment advertises 2-byte aliases, so 30
/// neighbours cost ~60 B per beacon.
const int mprNeighborAdvertiseLimit = 30;
const double neighborScoreTtlMs = 30000;

/// Entries advertised in an OGM so peers can learn routes to non-neighbours.
const int _bestHopAdvertiseLimit = 8;

double _normPeers(int count) => math.log(1 + count) / math.log(1 + 50);

double computeScore(MeshNode node, List<MeshNode> allNodes, RfParams rf) {
  final peers = peersInRange(node, allNodes, rf);
  final peerCount = peers.length;
  if (peerCount == 0) return 0;
  if (node.battery < batteryFloor) return 0;

  var rssiSum = 0.0;
  for (final p in peers) {
    rssiSum += rssiModel(node, p, rf);
  }
  final r = normRssi(rssiSum / peerCount);
  final n = _normPeers(peerCount);
  final b = node.battery;
  final s = math.min(node.uptimeMin / 60, 1.0) * (1 - node.mobility);
  final q = node.pdr;

  var score = weights.peers * n +
      weights.rssi * r +
      weights.battery * b +
      weights.stability * s +
      weights.pdr * q;

  if (node.charging) score += chargingBonus;
  return math.min(1.0, score);
}

Ogm buildOgm(MeshNode node, [int hopCount = 0]) {
  final bestHopTo = <NodeId, int>{};
  // Advertise only routes backed by direct evidence from the destination itself
  // (lastSeq > 0 means we have heard that originator's own beacon). Advertising
  // bootstrapped, second-hand entries would let a dead destination stay routable
  // forever: prune deletes it, a neighbour re-advertises it, it is recreated
  // with a fresh timestamp, and the 30 s soft-state expiry can never converge.
  final entries = node.nextHopTable.entries
      .where((e) => e.value.tq >= tqUsable && e.value.lastSeq > 0)
      .toList()
    ..sort((a, b) {
      final byHop = a.value.hopCount.compareTo(b.value.hopCount);
      return byHop != 0 ? byHop : a.key.compareTo(b.key);
    });
  for (final e in entries.take(_bestHopAdvertiseLimit)) {
    bestHopTo[e.key] = e.value.hopCount;
  }
  return Ogm(
    nodeId: node.id,
    seq: node.seq,
    score: node.score,
    isSuper: node.role == Role.superNode,
    peerCount: node.peerCount,
    batteryBucket: (node.battery * 10).floor(),
    bestHopTo: bestHopTo,
    hopCount: hopCount,
    neighborIds: node.peerIds.take(mprNeighborAdvertiseLimit).toList(),
  );
}

/// Minimal relay set covering this node's 2-hop neighbourhood — the MPR
/// selection OLSR defines and docs/03 §1 asks Duman to borrow ("each node picks
/// minimal relays covering 2-hop neighbors").
///
/// Greedy set cover over the advertised neighbour lists: repeatedly take the
/// neighbour covering the most still-uncovered 2-hop nodes, preferring SUPERs,
/// then better tq, then id so the result is deterministic. O(k^2) with k <= 30,
/// the "no Dijkstra on phones, just local sort" budget docs/03 §3 sets.
List<NodeId> selectMprSet(MeshNode node) {
  final peers = node.peerIds;
  final direct = peers.toSet();
  final uncovered = <NodeId>{};
  for (final p in peers) {
    for (final q in node.twoHopView[p] ?? const <NodeId>[]) {
      if (q != node.id && !direct.contains(q)) uncovered.add(q);
    }
  }

  final selected = <NodeId>[];
  while (uncovered.isNotEmpty) {
    NodeId? best;
    var bestGain = 0;
    var bestSuper = false;
    var bestTq = -1.0;
    for (final p in peers) {
      if (selected.contains(p)) continue;
      var gain = 0;
      for (final q in node.twoHopView[p] ?? const <NodeId>[]) {
        if (uncovered.contains(q)) gain++;
      }
      if (gain == 0) continue;
      final isSuper = node.ogmTable[p]?.isSuper ?? false;
      final tq = node.nextHopTable[p]?.tq ?? 0.0;
      final better = gain > bestGain ||
          (gain == bestGain && isSuper && !bestSuper) ||
          (gain == bestGain && isSuper == bestSuper && tq > bestTq) ||
          (gain == bestGain &&
              isSuper == bestSuper &&
              tq == bestTq &&
              (best == null || p.compareTo(best) < 0));
      if (better) {
        best = p;
        bestGain = gain;
        bestSuper = isSuper;
        bestTq = tq;
      }
    }
    if (best == null) break; // nobody advertises the remainder
    selected.add(best);
    for (final q in node.twoHopView[best] ?? const <NodeId>[]) {
      uncovered.remove(q);
    }
  }
  return selected;
}

/// Do the neighbours this node heard the message from cover all of its own
/// 1-hop neighbours? If yes, staying quiet is safe. If no, there is a coverage
/// hole and this node must forward — the check whose absence made the
/// doc-literal "heard a SUPER" rule lose 16-29 points of delivery in crowds.
bool relaysCoverPeers(MeshNode node, String key) {
  final relays = node.heardRelays[key];
  if (relays == null || relays.isEmpty) return false;
  final covered = relays.toSet();
  for (final r in relays) {
    covered.addAll(node.twoHopView[r] ?? const <NodeId>[]);
  }
  for (final p in node.peerIds) {
    if (!covered.contains(p)) return false;
  }
  return true;
}

/// Consume one OGM copy. [via] is the neighbour that handed it over and [nowMs]
/// is *simulation* time. Returns true when this node should gossip the beacon
/// onward (BATMAN re-broadcasts OGMs so every node builds a best-next-hop table
/// for the whole mesh — without this, routes only ever exist for direct
/// neighbours and multi-hop unicast is impossible).
bool receiveOgm(MeshNode node, Ogm ogm, NodeId via, double nowMs) {
  if (ogm.nodeId == node.id) return false;

  final existing = node.ogmTable[ogm.nodeId];
  final isNewer = existing == null || ogm.seq > existing.seq;
  if (isNewer) node.ogmTable[ogm.nodeId] = ogm;
  node.neighborScores[ogm.nodeId] = ogm.score;

  // A beacon heard straight from its originator (hopCount 0) tells us that
  // originator's own neighbour list, which is what MPR coverage is computed
  // from. Gossiped copies describe a node that may be several hops away, so they
  // must not populate the 2-hop view.
  if (ogm.hopCount == 0 && via == ogm.nodeId) {
    node.twoHopView[ogm.nodeId] = List<NodeId>.of(ogm.neighborIds);
  }

  final prev = node.nextHopTable[ogm.nodeId];
  final hopCount = ogm.hopCount + 1;

  // Link transmit quality over a sliding window of tqWindow OGM intervals.
  var window = (prev != null && prev.windowNeighbor == via)
      ? List<int>.of(prev.window)
      : <int>[];
  var lastSeq = (prev != null && prev.windowNeighbor == via) ? prev.lastSeq : 0;
  if (isNewer) {
    final gap = lastSeq == 0 ? 1 : ogm.seq - lastSeq;
    final zeros = math.min(gap, tqWindow);
    for (var i = 1; i < zeros; i++) {
      window.add(0);
    }
    window.add(1);
    if (window.length > tqWindow) {
      window = window.sublist(window.length - tqWindow);
    }
    lastSeq = ogm.seq;
  }
  final tq = window.isEmpty
      ? 0.0
      : window.fold<int>(0, (s, v) => s + v) / window.length;

  final betterHop = prev == null ||
      hopCount < prev.hopCount ||
      (hopCount == prev.hopCount && tq > prev.tq);
  if (betterHop) {
    node.nextHopTable[ogm.nodeId] = NextHopEntry(
      bestNeighbor: via,
      tq: tq,
      lastSeq: lastSeq,
      hopCount: hopCount,
      lastSeen: nowMs,
      window: window,
      windowNeighbor: via,
    );
  } else {
    prev.tq = tq;
    prev.lastSeq = lastSeq;
    prev.lastSeen = nowMs;
    prev.window = window;
  }

  // Bootstrap from routes the originator advertises (second-hand reachability).
  //
  // This only ever *creates* an entry — see buildOgm for why refreshing one
  // here would make stale routes immortal.
  ogm.bestHopTo.forEach((dest, advertised) {
    if (dest == node.id) return;
    if (node.nextHopTable.containsKey(dest)) return;
    node.nextHopTable[dest] = NextHopEntry(
      bestNeighbor: via,
      tq: tq,
      lastSeq: 0,
      hopCount: advertised + hopCount,
      lastSeen: nowMs,
      window: List<int>.of(window),
      windowNeighbor: via,
    );
  });

  return isNewer;
}

/// The OGM payload to gossip onward, or null when the beacon budget is spent.
Ogm? ogmToGossip(Ogm ogm, int ogmTtl) {
  if (ogm.hopCount + 1 >= ogmTtl) return null;
  return ogm.copyWith(hopCount: ogm.hopCount + 1);
}

class ElectionOutcome {
  const ElectionOutcome(this.role, this.reason);

  final Role role;
  final String reason;
}

String _pct(double v) => (v * 100).toStringAsFixed(0);

/// Role decision with hysteresis and the SUPER proximity guard (docs/03 §3, §5).
/// Pure apart from the demote counter, which is the hysteresis state itself.
ElectionOutcome electRole(MeshNode node, List<MeshNode> allNodes, RfParams rf) {
  final peers = peersInRange(node, allNodes, rf);
  if (peers.length < minPeers) {
    node.demoteCounter = 0;
    return ElectionOutcome(
        Role.normal, 'Too few peers (${peers.length}<$minPeers) for SUPER role');
  }
  if (node.battery < batteryFloor) {
    node.demoteCounter = 0;
    return ElectionOutcome(
        Role.normal, 'Battery ${_pct(node.battery)}% below 25% threshold');
  }

  // Rank against self + the 1-hop neighbourhood scores heard in OGMs.
  final scores = <double>[node.score];
  for (final p in peers) {
    final heard = node.ogmTable[p.id];
    scores.add(heard != null ? heard.score : p.score);
  }
  final strictlyBetter = scores.where((s) => s > node.score).length;
  final top20Count = math.max(1, (scores.length * topPercent).ceil());
  final inTop20 = strictlyBetter < top20Count;
  final rankLabel = '${strictlyBetter + 1}/${scores.length}';

  final shouldBeSuper = node.score > superPromoteThreshold && inTop20;
  final shouldDemote = node.score < superDemoteThreshold;

  // Proximity guard: at most one SUPER per ~30 m. A clearly better SUPER that is
  // very close wins, and the lower scorer backs off.
  MeshNode? blockingSuper;
  final threshold = proximityRssiThreshold(rf);
  for (final p in peers) {
    if (p.role == Role.superNode &&
        p.score > node.score + proximityScoreMargin &&
        rssiModel(node, p, rf) > threshold) {
      blockingSuper = p;
      break;
    }
  }

  if (shouldBeSuper && blockingSuper == null) {
    node.demoteCounter = 0;
    if (node.role != Role.superNode) {
      return ElectionOutcome(
          Role.superNode,
          'Promoted: score ${node.score.toStringAsFixed(2)}, rank $rankLabel, '
              '${peers.length} peers, battery ${_pct(node.battery)}%');
    }
    return ElectionOutcome(Role.superNode,
        'SUPER: score ${node.score.toStringAsFixed(2)}, ${peers.length} peers');
  }

  if (shouldDemote && node.role == Role.superNode) {
    node.demoteCounter++;
    if (node.demoteCounter >= demoteCycles) {
      node.demoteCounter = 0;
      return ElectionOutcome(
          Role.normal,
          'Demoted: score ${node.score.toStringAsFixed(2)} < '
              '$superDemoteThreshold for $demoteCycles cycles');
    }
    return ElectionOutcome(Role.superNode,
        'SUPER (pending demote ${node.demoteCounter}/$demoteCycles)');
  }

  if (blockingSuper != null && node.role == Role.superNode) {
    node.demoteCounter = 0;
    return ElectionOutcome(Role.normal,
        'Backed off: SUPER ${blockingSuper.id} closer and better scored');
  }

  node.demoteCounter = 0;
  return ElectionOutcome(Role.normal,
      'NORMAL: score ${node.score.toStringAsFixed(2)}, rank $rankLabel');
}

/// Drop routes and scores that have not been refreshed (soft state, docs/05 §1.4).
void pruneStaleEntries(MeshNode node, double nowMs, double maxAgeMs) {
  // Drop 2-hop views for nodes that are no longer direct neighbours.
  final peers = node.peerIds.toSet();
  node.twoHopView.removeWhere((id, _) => !peers.contains(id));
  node.nextHopTable.removeWhere((_, e) => nowMs - e.lastSeen > maxAgeMs);
  final orphaned = node.ogmTable.keys
      .where((id) => !node.nextHopTable.containsKey(id))
      .toList();
  for (final id in orphaned) {
    node.ogmTable.remove(id);
    node.neighborScores.remove(id);
  }
}

NodeId? getNextHop(MeshNode node, NodeId dest) {
  final entry = node.nextHopTable[dest];
  if (entry != null && entry.tq >= tqUsable) return entry.bestNeighbor;
  return null;
}
