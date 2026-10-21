import type { MeshNode, NodeId, OGM, Role } from "./types";
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
export const NEIGHBOR_SCORE_TTL_MS = 30_000;

function normPeers(count: number): number {
  return Math.log(1 + count) / Math.log(1 + 50);
}

export function computeScore(node: MeshNode, allNodes: MeshNode[], rf: RfParams): number {
  const peers = peersInRange(node, allNodes, rf);
  const peerCount = peers.length;
  if (peerCount === 0) return 0;
  if (node.battery < BATTERY_FLOOR) return 0;

  let rssiSum = 0;
  for (const p of peers) rssiSum += rssiModel(node, p, rf);
  const r = normRssi(rssiSum / peerCount);
  const n = normPeers(peerCount);
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
  };
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

  const prev = node.nextHopTable[ogm.nodeId];
  const hopCount = ogm.hopCount + 1;

  // Link transmit quality over a sliding window of TQ_WINDOW OGM intervals.
  let window = prev && prev.windowNeighbor === via ? prev.window.slice() : [];
  let lastSeq = prev && prev.windowNeighbor === via ? prev.lastSeq : 0;
  if (isNewer) {
    const gap = lastSeq === 0 ? 1 : ogm.seq - lastSeq;
    for (let i = 1; i < Math.min(gap, TQ_WINDOW); i++) window.push(0);
    window.push(1);
    if (window.length > TQ_WINDOW) window = window.slice(window.length - TQ_WINDOW);
    lastSeq = ogm.seq;
  }
  const tq = window.length === 0 ? 0 : window.reduce((s, v) => s + v, 0) / window.length;

  const betterHop = !prev || hopCount < prev.hopCount || (hopCount === prev.hopCount && tq > prev.tq);
  if (betterHop) {
    node.nextHopTable[ogm.nodeId] = {
      bestNeighbor: via,
      tq,
      lastSeq,
      hopCount,
      lastSeen: nowMs,
      window,
      windowNeighbor: via,
    };
  } else {
    prev.tq = tq;
    prev.lastSeq = lastSeq;
    prev.lastSeen = nowMs;
    prev.window = window;
  }

  // Bootstrap from routes the originator advertises (second-hand reachability).
  //
  // This only ever *creates* an entry. Refreshing an existing one here would let
  // a dead destination stay routable forever: neighbours keep advertising it in
  // their own beacons, each copy re-stamps lastSeen, and the 30 s soft-state
  // expiry can never fire. Once bootstrapped, an entry must be kept alive by the
  // destination's own gossiped OGMs — exactly as BATMAN does.
  for (const dest of Object.keys(ogm.bestHopTo)) {
    if (dest === node.id) continue;
    if (node.nextHopTable[dest]) continue;
    node.nextHopTable[dest] = {
      bestNeighbor: via,
      tq,
      lastSeq: 0,
      hopCount: ogm.bestHopTo[dest] + hopCount,
      lastSeen: nowMs,
      window,
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
export function electRole(node: MeshNode, allNodes: MeshNode[], rf: RfParams): ElectionOutcome {
  const peers = peersInRange(node, allNodes, rf);
  if (peers.length < MIN_PEERS) {
    node.demoteCounter = 0;
    return { role: "NORMAL", reason: `Too few peers (${peers.length}<${MIN_PEERS}) for SUPER role` };
  }
  if (node.battery < BATTERY_FLOOR) {
    node.demoteCounter = 0;
    return { role: "NORMAL", reason: `Battery ${(node.battery * 100).toFixed(0)}% below 25% threshold` };
  }

  // Rank against self + the 1-hop neighbourhood scores heard in OGMs.
  const scores: number[] = [node.score];
  for (const p of peers) {
    const heard = node.ogmTable[p.id];
    scores.push(heard ? heard.score : p.score);
  }
  const strictlyBetter = scores.filter((s) => s > node.score).length;
  const top20Count = Math.max(1, Math.ceil(scores.length * TOP_PERCENT));
  const inTop20 = strictlyBetter < top20Count;
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
  for (const id of Object.keys(node.nextHopTable)) {
    if (nowMs - node.nextHopTable[id].lastSeen > maxAgeMs) delete node.nextHopTable[id];
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
