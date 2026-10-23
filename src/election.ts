import type { MeshNode, NodeId, OGM, Role, TqWindow } from "./types";
import type { RfParams } from "./rf";
import { normRssi, peersInRange, rssiModel } from "./rf";

/**
 * Coverage-based super-node election — "Duman Adaptive Routing"
 * (docs/03-smart-router-algorithm.md, skills/02-super-node.skill.md).
 *
 *   coverageScore = 0.30*norm(peers) + 0.25*normRssi + 0.20*battery
 *                 + 0.15*stability   + 0.10*pdr   (+0.10 charging)
 *
 * Fully decentralised: no leader, no Raft. Each node self-scores, gossips the
 * score in its OGM, and self-promotes when it is in the top 20 % of the scores
 * it has heard from its 1-hop neighbourhood.
 */

export const WEIGHTS = {
  peers: 0.3,
  rssi: 0.25,
  battery: 0.2,
  stability: 0.15,
  pdr: 0.1,
} as const;

export const CHARGING_BONUS = 0.1;
export const BATTERY_FLOOR = 0.25;
export const MIN_PEERS = 3;
export const SUPER_PROMOTE_THRESHOLD = 0.6;
export const SUPER_DEMOTE_THRESHOLD = 0.5;
export const TOP_PERCENT = 0.2;
/**
 * docs/03 §5: "at most 1 SUPER per ~30 m radius ... RSSI > -60 (very close)".
 *
 * Those two numbers only agree for the doc's original tx-power assumption. With
 * the calibrated radio used here (-55 dBm at 1 m) a hard-coded -60 dBm would
 * mean "~3 m", silently disabling the guard. The threshold is therefore derived
 * from the RF parameters so it keeps its documented *physical* meaning.
 */
export const PROXIMITY_RADIUS_M = 30;

export function proximityRssiThreshold(rf: RfParams): number {
  return rf.txPowerDbm - 20 * Math.log10(PROXIMITY_RADIUS_M);
}
export const PROXIMITY_SCORE_MARGIN = 0.1;
export const DEMOTE_CYCLES = 2;
/** tq below this makes a route unusable, so the router falls back to flood. */
export const TQ_USABLE = 0.6;
export const TQ_WINDOW = 32;
/**
 * Bound on the number of (originator, neighbour) receipt windows one node
 * keeps. docs/03 §7 promises O(n) memory with n = nodes known, and per-link
 * history is O(n x neighbours); this is the hard stop, and `pruneStaleEntries`
 * evicts in insertion order so both language engines evict identically.
 */
export const TQ_PAIR_MAX = 2048;
/**
 * Bound on the neighbour list carried in an OGM.
 *
 * OLSR HELLOs advertise the full 1-hop set. The cap has to sit above the peer
 * count a scenario can actually produce, or the coverage gate can never be
 * satisfied and nothing is ever suppressed: at 12 entries a 60-node crowd with
 * 15-18 peers each truncated its advertisement, suppression collapsed from 1772
 * to 110 and overhead went *up*. 30 matches the "local sort, k <= 30" budget
 * docs/03 §3 already sets. A real deployment advertises 2-byte aliases, so 30
 * neighbours cost ~60 B per beacon.
 */
export const MPR_NEIGHBOR_ADVERTISE_LIMIT = 30;

/**
 * Fan-out cap for the MPR fallback **at density only** — when a node has more peers
 * than one beacon can advertise, it cannot know who is covered, so it must forward,
 * but forwarding to all of them is an epidemic (docs/06 §15: one 3-hop delivery
 * costing 7,038 transmissions at 200 nodes in a 100×100 m area, where each node
 * hears ~179 of the other 199). A K-ary fan-out still covers a homogeneous dense
 * world in log_K(N) hops, because every relay's peers are everyone's peers.
 *
 * Below the advertise limit the peer list is complete and the coverage answer is
 * exact, so the cap never applies: campus_quad peaks at 12 peers and
 * festival_crowd at 24, and neither changes by one transmission.
 */
export const DENSE_FALLBACK_FANOUT = 6;
export const NEIGHBOR_SCORE_TTL_MS = 30_000;

/** Normalise a peer count. `observedMax` is 0 for the shipped fixed denominator of 50;
 *  a positive value switches to the largest peer count this node has heard, which is what
 *  `peerNorm: "observed"` asks for (docs/06 §18.2). Clamped so a node can never score above
 *  1 on this term: the denominator is at least its own count. */
export function normPeers(count: number, observedMax = 0): number {
  const denom = observedMax > 0 ? Math.max(observedMax, count) : 50;
  return Math.log(1 + count) / Math.log(1 + denom);
}

export function computeScore(
  node: MeshNode,
  allNodes: MeshNode[],
  rf: RfParams,
  observedMax = 0
): number {
  const peers = peersInRange(node, allNodes, rf);
  const peerCount = peers.length;
  if (peerCount === 0) return 0;
  if (node.battery < BATTERY_FLOOR) return 0;

  let rssiSum = 0;
  for (const p of peers) rssiSum += rssiModel(node, p, rf);
  const r = normRssi(rssiSum / peerCount);
  const n = normPeers(peerCount, observedMax);
  const b = node.battery;
  const s = Math.min(node.uptimeMin / 60, 1) * (1 - node.mobility);
  const q = node.pdr;

  let score =
    WEIGHTS.peers * n +
    WEIGHTS.rssi * r +
    WEIGHTS.battery * b +
    WEIGHTS.stability * s +
    WEIGHTS.pdr * q;

  if (node.charging) score += CHARGING_BONUS;
  return Math.min(1, score);
}

/** Entries advertised in an OGM so peers can learn routes to non-neighbours. */
const BEST_HOP_ADVERTISE_LIMIT = 8;

export function buildOGM(node: MeshNode, hopCount = 0): OGM {
  const bestHopTo: Record<string, number> = {};
  // Advertise only routes backed by direct evidence from the destination itself
  // (lastSeq > 0 means we have heard that originator's own beacon). Advertising
  // bootstrapped, second-hand entries would let a dead destination stay routable
  // forever: prune deletes it, a neighbour re-advertises it, it is recreated
  // with a fresh timestamp, and the 30 s soft-state expiry can never converge.
  const entries = Object.entries(node.nextHopTable)
    .filter(([, e]) => e.tq >= TQ_USABLE && e.lastSeq > 0)
    .sort((a, b) => a[1].hopCount - b[1].hopCount || (a[0] < b[0] ? -1 : 1))
    .slice(0, BEST_HOP_ADVERTISE_LIMIT);
  for (const [dest, e] of entries) bestHopTo[dest] = e.hopCount;
  return {
    nodeId: node.id,
    seq: node.seq,
    score: node.score,
    isSuper: node.role === "SUPER",
    peerCount: node.peerCount,
    batteryBucket: Math.floor(node.battery * 10),
    bestHopTo,
    hopCount,
    neighborIds: node.peerIds.slice(0, MPR_NEIGHBOR_ADVERTISE_LIMIT),
    declinedRouter: node.superOptOut || node.batterySaver,
  };
}

/**
 * Minimal relay set covering this node's 2-hop neighbourhood — the MPR selection
 * OLSR defines and docs/03 §1 asks Duman to borrow ("each node picks minimal
 * relays covering 2-hop neighbors").
 *
 * Greedy set cover over the advertised neighbour lists: repeatedly take the
 * neighbour that covers the most still-uncovered 2-hop nodes, preferring SUPERs,
 * then better tq, then id so the result is deterministic. O(k^2) with k <= 30,
 * which is the "no Dijkstra on phones, just local sort" budget docs/03 §3 sets.
 */
/**
 * [allNodes] and [preferCommunity] are optional so every existing call site keeps working.
 * With `preferCommunity`, a plugged and stationary peer wins an equal-coverage tie against
 * a phone — the relay work is the same either way, but one of them is running on somebody's
 * battery (roadmap Phase 5, docs/06 §19.4).
 *
 * A real deployment has to learn those two bits from the beacon rather than from a node
 * table: `declinedRouter` is already advertised for exactly this kind of decision, and
 * `charging` and `stationary` would be two more flags in the same OGM.
 */
export function selectMprSet(
  node: MeshNode,
  allNodes: MeshNode[] = [],
  preferCommunity = false
): NodeId[] {
  const peers = node.peerIds;
  const community = new Set<NodeId>();
  if (preferCommunity) {
    for (const n of allNodes) if (isCommunityRelay(n)) community.add(n.id);
  }
  const direct = new Set<NodeId>(peers);
  const uncovered = new Set<NodeId>();
  for (const p of peers) {
    for (const q of node.twoHopView[p] ?? []) {
      if (q !== node.id && !direct.has(q)) uncovered.add(q);
    }
  }

  const selected: NodeId[] = [];
  while (uncovered.size > 0) {
    let best: NodeId | null = null;
    let bestGain = 0;
    let bestSuper = false;
    let bestCommunity = false;
    let bestTq = -1;
    for (const p of peers) {
      if (selected.includes(p)) continue;
      let gain = 0;
      for (const q of node.twoHopView[p] ?? []) if (uncovered.has(q)) gain++;
      if (gain === 0) continue;
      const isSuper = node.ogmTable[p]?.isSuper === true;
      const isCommunity = community.has(p);
      const tq = node.nextHopTable[p]?.tq ?? 0;
      const better =
        gain > bestGain ||
        (gain === bestGain && isCommunity && !bestCommunity) ||
        (gain === bestGain && isCommunity === bestCommunity && isSuper && !bestSuper) ||
        (gain === bestGain &&
          isCommunity === bestCommunity &&
          isSuper === bestSuper &&
          tq > bestTq) ||
        (gain === bestGain &&
          isCommunity === bestCommunity &&
          isSuper === bestSuper &&
          tq === bestTq &&
          (best === null || p < best));
      if (better) {
        best = p;
        bestGain = gain;
        bestSuper = isSuper;
        bestCommunity = isCommunity;
        bestTq = tq;
      }
    }
    if (best === null) break; // nobody advertises the remainder
    selected.push(best);
    for (const q of node.twoHopView[best] ?? []) uncovered.delete(q);
  }
  return selected;
}

/**
 * Does the set of relays this node actually heard retransmitting cover all of
 * its own 1-hop neighbours? If yes, staying quiet is safe. If no, there is a
 * coverage hole and this node must forward — this is the check whose absence
 * made the doc-literal "heard a SUPER" rule lose 16-29 points of delivery in
 * dense crowds.
 */
export function relaysCoverPeers(node: MeshNode, key: string): boolean {
  const relays = node.heardRelays.get(key);
  if (!relays || relays.size === 0) return false;
  const covered = new Set<NodeId>(relays);
  for (const r of relays) {
    for (const q of node.twoHopView[r] ?? []) covered.add(q);
  }
  for (const p of node.peerIds) if (!covered.has(p)) return false;
  return true;
}

/** Key for one link's receipt history: `"originator|neighbour"`. */
export function tqPairKey(originator: NodeId, via: NodeId): string {
  return `${originator}|${via}`;
}

/** Ratio of received to expected OGMs over the window; 0 when there is none. */
export function tqOfWindow(window: readonly number[]): number {
  if (window.length === 0) return 0;
  let ones = 0;
  for (const v of window) ones += v;
  return ones / window.length;
}

/**
 * Record one OGM receipt against the link that delivered it and return that
 * link's window.
 *
 * Missing sequence numbers between two receipts over the *same* neighbour are
 * the "OGMs expected" half of docs/03 §7, so they are recorded as zeros. A copy
 * that arrives over a different neighbour is evidence about that other link and
 * must not disturb this one.
 */
export function recordTqSample(
  node: MeshNode,
  originator: NodeId,
  via: NodeId,
  seq: number
): TqWindow {
  const key = tqPairKey(originator, via);
  const existing = node.tqWindows.get(key);
  if (!existing) {
    // First copy over this link: there is no way to know how many were missed
    // before it, so start optimistic and let the gaps pull it down, exactly as
    // BATMAN's tq does for a newly discovered neighbour.
    const created: TqWindow = { lastSeq: seq, window: [1] };
    node.tqWindows.set(key, created);
    return created;
  }
  if (seq > existing.lastSeq) {
    const gap = seq - existing.lastSeq;
    for (let i = 1; i < Math.min(gap, TQ_WINDOW); i++) existing.window.push(0);
    existing.window.push(1);
    if (existing.window.length > TQ_WINDOW) {
      existing.window = existing.window.slice(existing.window.length - TQ_WINDOW);
    }
    existing.lastSeq = seq;
  }
  return existing;
}

/** The receipt window for one link, or null if that link has no history. */
export function tqWindowFor(node: MeshNode, originator: NodeId, via: NodeId): TqWindow | null {
  return node.tqWindows.get(tqPairKey(originator, via)) ?? null;
}

/**
 * Consume one OGM copy. `via` is the neighbour that handed it over and
 * `nowMs` is *simulation* time. Returns true when this node should gossip the
 * beacon onward (BATMAN re-broadcasts OGMs so every node builds a
 * best-next-hop table for the whole mesh — without this, routes only ever exist
 * for direct neighbours and multi-hop unicast is impossible).
 */
export function receiveOGM(
  node: MeshNode,
  ogm: OGM,
  via: NodeId,
  nowMs: number
): boolean {
  if (ogm.nodeId === node.id) return false;

  const existing = node.ogmTable[ogm.nodeId];
  const isNewer = !existing || ogm.seq > existing.seq;
  if (isNewer) node.ogmTable[ogm.nodeId] = ogm;
  node.neighborScores[ogm.nodeId] = ogm.score;

  // A beacon heard straight from its originator (hopCount 0) tells us that
  // originator's own neighbour list, which is what MPR coverage is computed
  // from. Gossiped copies describe a node that may be several hops away, so
  // they must not populate the 2-hop view.
  if (ogm.hopCount === 0 && via === ogm.nodeId) {
    node.twoHopView[ogm.nodeId] = ogm.neighborIds.slice();
  }

  const prev = node.nextHopTable[ogm.nodeId];
  const hopCount = ogm.hopCount + 1;

  // Link transmit quality over a sliding window of TQ_WINDOW OGM intervals,
  // tracked per (originator, neighbour) pair rather than per route entry.
  //
  // Keying it on the entry instead means a duplicate copy that arrives over a
  // longer path destroys the history of a perfect direct link: the copy is not
  // newer, so no sample is recorded, yet the window is thrown away because it
  // came from a different neighbour and tq collapses to 0. Gossiped duplicates
  // always land after the direct copy, so the zero was the steady state — the
  // 20-node quad measured tq 0.11 for direct neighbours whose real receipt rate
  // was ~0.8, the window never grew past one sample, and getNextHop's
  // tq > 0.6 gate rejected almost every route (docs/06 §6).
  const sample = recordTqSample(node, ogm.nodeId, via, ogm.seq);

  // Fewest hops wins, ties go to the better link. Whichever copy arrives last,
  // the entry reports the window of the neighbour it actually routes through.
  const betterHop =
    !prev || hopCount < prev.hopCount || (hopCount === prev.hopCount && tqOfWindow(sample.window) > prev.tq);
  const bestNeighbor = betterHop ? via : prev.bestNeighbor;
  const best = betterHop ? sample : tqWindowFor(node, ogm.nodeId, bestNeighbor) ?? sample;
  node.nextHopTable[ogm.nodeId] = {
    bestNeighbor,
    tq: tqOfWindow(best.window),
    // Highest sequence number heard from this originator. Entries bootstrapped
    // second-hand from a neighbour's bestHopTo never see one, which is how
    // buildOGM tells "I have heard this node's beacon" from "someone mentioned
    // it" — see the note there on why that distinction keeps dead routes mortal.
    lastSeq: Math.max(prev ? prev.lastSeq : 0, ogm.seq),
    hopCount: betterHop ? hopCount : prev.hopCount,
    lastSeen: nowMs,
    window: best.window.slice(),
    windowNeighbor: bestNeighbor,
  };

  // Bootstrap from routes the originator advertises (second-hand reachability).
  //
  // This only ever *creates* an entry. Refreshing an existing one here would let
  // a dead destination stay routable forever: neighbours keep advertising it in
  // their own beacons, each copy re-stamps lastSeen, and the 30 s soft-state
  // expiry can never fire. Once bootstrapped, an entry must be kept alive by the
  // destination's own gossiped OGMs — exactly as BATMAN does.
  // The only link this second-hand route can be judged on is the one to the
  // neighbour that told us about it: nothing about `dest`'s own beacon has been
  // heard, so lastSeq stays 0 and buildOGM will not pass the rumour on.
  const linkToVia = tqWindowFor(node, via, via) ?? sample;
  for (const dest of Object.keys(ogm.bestHopTo)) {
    if (dest === node.id) continue;
    if (node.nextHopTable[dest]) continue;
    node.nextHopTable[dest] = {
      bestNeighbor: via,
      tq: tqOfWindow(linkToVia.window),
      lastSeq: 0,
      hopCount: ogm.bestHopTo[dest] + hopCount,
      lastSeen: nowMs,
      window: linkToVia.window.slice(),
      windowNeighbor: via,
    };
  }

  return isNewer;
}

/** The OGM payload to gossip onward, or null when the beacon budget is spent. */
export function ogmToGossip(ogm: OGM, ogmTtl: number): OGM | null {
  if (ogm.hopCount + 1 >= ogmTtl) return null;
  return { ...ogm, hopCount: ogm.hopCount + 1 };
}

export interface ElectionOutcome {
  role: Role;
  reason: string;
}

/**
 * Role decision with hysteresis and the SUPER proximity guard
 * (docs/03 §3 and §5). Pure apart from the demote counter, which is the
 * hysteresis state itself.
 */
/**
 * A community relay: plugged in and not moving, which is what "keep Duman running on the
 * café's tablet" means in the model (roadmap Phase 5, docs/06 §19). The two flags are what
 * the coverage score already reads — `charging` for the +0.10 bonus, `stationary` for the
 * stability term — so this adds no new state, only a name for the combination.
 */
export function isCommunityRelay(node: MeshNode): boolean {
  return node.charging && node.stationary;
}

/**
 * Share of the top-20% cap reserved for community relays, 0 to disable (docs/06 §19.2).
 *
 * The measurement behind it: six plugged tablets in a 60-node crowd take 18.6% of the radio
 * work off everybody else, because at six they *displace* battery-powered SUPERs; at three
 * they merely join an already-full elected set and everybody else's transmissions rise
 * 9.2%. Reserving part of the cap makes displacement happen at three as well.
 */
export function electRole(
  node: MeshNode,
  allNodes: MeshNode[],
  rf: RfParams,
  communityRelayQuota = 0
): ElectionOutcome {
  // skills/02 acceptance: "SUPER opt-out respected; NORMAL never auto-promoted
  // if battery saver on". Both are explicit user or OS intent, so they are
  // checked before any scoring and demote immediately rather than waiting out
  // the two-cycle hysteresis below — hysteresis exists to damp score noise, and
  // a toggle is not noise.
  if (node.superOptOut) {
    node.demoteCounter = 0;
    return { role: "NORMAL", reason: "SUPER opt-out: user declined the router role" };
  }
  if (node.batterySaver) {
    node.demoteCounter = 0;
    return { role: "NORMAL", reason: "Battery saver on: never auto-promoted" };
  }

  const peers = peersInRange(node, allNodes, rf);
  if (peers.length < MIN_PEERS) {
    node.demoteCounter = 0;
    return { role: "NORMAL", reason: `Too few peers (${peers.length}<${MIN_PEERS}) for SUPER role` };
  }
  if (node.battery < BATTERY_FLOOR) {
    node.demoteCounter = 0;
    return { role: "NORMAL", reason: `Battery ${(node.battery * 100).toFixed(0)}% below 25% threshold` };
  }

  // Rank against self + the 1-hop neighbourhood scores heard in OGMs. Peers
  // that have declined the router role are not candidates: counting them would
  // burn top-20% slots on nodes that can never promote, so a crowd of opt-outs
  // would leave the mesh with too few SUPERs to cover it (skills/02's 15-25%).
  const candidates: Array<{ score: number; community: boolean }> = [
    { score: node.score, community: isCommunityRelay(node) },
  ];
  for (const p of peers) {
    const heard = node.ogmTable[p.id];
    if (heard ? heard.declinedRouter : p.superOptOut || p.batterySaver) continue;
    candidates.push({ score: heard ? heard.score : p.score, community: isCommunityRelay(p) });
  }
  const scores = candidates.map((c) => c.score);
  const strictlyBetter = scores.filter((s) => s > node.score).length;
  const top20Count = Math.max(1, Math.ceil(scores.length * TOP_PERCENT));
  let inTop20 = strictlyBetter < top20Count;
  if (communityRelayQuota >= 1 && isCommunityRelay(node)) {
    // A quota of 1 or more means "the cap does not bind a community relay": it still has
    // to clear `SUPER_PROMOTE_THRESHOLD` and the 30 m proximity guard below, but it does
    // not have to beat its neighbours. The measurement that motivates it is that the
    // tablets which fail to be elected are not losing to phones — six plugged nodes in one
    // crowd all hear each other, so they spend the five slots on each other and the
    // weakest two stay NORMAL (docs/06 §19.4).
    inTop20 = true;
  } else if (communityRelayQuota > 0) {
    // Split the cap rather than widen it: `reserved` slots are competed for by community
    // relays only and the rest by everybody, so a plugged tablet displaces a
    // battery-powered router instead of adding to the elected set. Reserved slots that no
    // community relay can fill fall back to the open competition (`Math.min` against the
    // candidate count), and with no community relays in range at all the reserved count is
    // zero and this is the unmodified rule.
    const communityCount = candidates.filter((c) => c.community).length;
    const reserved = Math.min(Math.floor(top20Count * communityRelayQuota), communityCount);
    const open = top20Count - reserved;
    const betterCommunity = candidates.filter((c) => c.community && c.score > node.score).length;
    const betterOpen = candidates.filter((c) => !c.community && c.score > node.score).length;
    inTop20 = candidates[0].community
      ? betterCommunity < reserved || strictlyBetter < top20Count
      : betterOpen < open;
  }
  const rankLabel = `${strictlyBetter + 1}/${scores.length}`;

  const shouldBeSuper = node.score > SUPER_PROMOTE_THRESHOLD && inTop20;
  const shouldDemote = node.score < SUPER_DEMOTE_THRESHOLD;

  // Proximity guard: at most one SUPER per ~30 m. A clearly better SUPER that is
  // very close wins, and the lower scorer backs off.
  let blockingSuper: MeshNode | null = null;
  for (const p of peers) {
    if (
      p.role === "SUPER" &&
      p.score > node.score + PROXIMITY_SCORE_MARGIN &&
      rssiModel(node, p, rf) > proximityRssiThreshold(rf)
    ) {
      blockingSuper = p;
      break;
    }
  }

  if (shouldBeSuper && !blockingSuper) {
    node.demoteCounter = 0;
    if (node.role !== "SUPER") {
      return {
        role: "SUPER",
        reason: `Promoted: score ${node.score.toFixed(2)}, rank ${rankLabel}, ${peers.length} peers, battery ${(node.battery * 100).toFixed(0)}%`,
      };
    }
    return { role: "SUPER", reason: `SUPER: score ${node.score.toFixed(2)}, ${peers.length} peers` };
  }

  if (shouldDemote && node.role === "SUPER") {
    node.demoteCounter++;
    if (node.demoteCounter >= DEMOTE_CYCLES) {
      node.demoteCounter = 0;
      return {
        role: "NORMAL",
        reason: `Demoted: score ${node.score.toFixed(2)} < ${SUPER_DEMOTE_THRESHOLD} for ${DEMOTE_CYCLES} cycles`,
      };
    }
    return { role: "SUPER", reason: `SUPER (pending demote ${node.demoteCounter}/${DEMOTE_CYCLES})` };
  }

  if (blockingSuper && node.role === "SUPER") {
    node.demoteCounter = 0;
    return { role: "NORMAL", reason: `Backed off: SUPER ${blockingSuper.id} closer and better scored` };
  }

  node.demoteCounter = 0;
  return { role: "NORMAL", reason: `NORMAL: score ${node.score.toFixed(2)}, rank ${rankLabel}` };
}

/** Drop routes and scores that have not been refreshed (soft state, docs/05 §1.4). */
export function pruneStaleEntries(node: MeshNode, nowMs: number, maxAgeMs: number): void {
  // Drop 2-hop views for nodes that are no longer direct neighbours.
  const peers = new Set<NodeId>(node.peerIds);
  for (const id of Object.keys(node.twoHopView)) {
    if (!peers.has(id)) delete node.twoHopView[id];
  }
  for (const id of Object.keys(node.nextHopTable)) {
    if (nowMs - node.nextHopTable[id].lastSeen > maxAgeMs) delete node.nextHopTable[id];
  }
  // Receipt windows are keyed by the neighbour that delivered them: a neighbour
  // we can no longer hear is not a candidate next hop, and an originator whose
  // route entry just expired is not worth measuring either.
  for (const key of Array.from(node.tqWindows.keys())) {
    const sep = key.lastIndexOf("|");
    const originator = key.slice(0, sep);
    const via = key.slice(sep + 1);
    if (!peers.has(via) || !node.nextHopTable[originator]) node.tqWindows.delete(key);
  }
  // Insertion order is stable in both JS Maps and Dart LinkedHashMaps, so
  // evicting the oldest keeps the two engines bit-identical.
  while (node.tqWindows.size > TQ_PAIR_MAX) {
    const oldest = node.tqWindows.keys().next();
    if (oldest.done) break;
    node.tqWindows.delete(oldest.value);
  }
  for (const id of Object.keys(node.ogmTable)) {
    if (!node.nextHopTable[id]) {
      delete node.ogmTable[id];
      delete node.neighborScores[id];
    }
  }
}

export function getNextHop(node: MeshNode, dest: NodeId): NodeId | null {
  const entry = node.nextHopTable[dest];
  if (entry && entry.tq >= TQ_USABLE) return entry.bestNeighbor;
  return null;
}
