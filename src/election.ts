import type { MeshNode, NodeId, Role, OGM } from "./types";
import { normRssi, peersInRange, rssiModel } from "./rf";

const WEIGHTS = {
  peers: 0.3,
  rssi: 0.25,
  battery: 0.2,
  stability: 0.15,
  pdr: 0.1,
};
const CHARGING_BONUS = 0.1;
const SUPER_PROMOTE_THRESHOLD = 0.6;
const SUPER_DEMOTE_THRESHOLD = 0.5;
const TOP_20_PERCENT = 0.2;
const PROXIMITY_RSSI_THRESHOLD = -60;
const PROXIMITY_SCORE_MARGIN = 0.1;

function normPeers(count: number): number {
  return Math.log(1 + count) / Math.log(1 + 50);
}

export function computeScore(node: MeshNode, allNodes: MeshNode[]): number {
  const peers = peersInRange(node, allNodes);
  const peerCount = peers.length;
  if (peerCount === 0) return 0;

  const avgRssi =
    peers.reduce((sum, p) => sum + rssiModel(node, p), 0) / peerCount;
  const r = normRssi(avgRssi);
  const n = normPeers(peerCount);
  const b = node.battery;
  const s = Math.min(node.uptimeMin / 60, 1) * (1 - node.mobility);
  const q = node.pdr;

  if (b < 0.25) return 0;

  let score =
    WEIGHTS.peers * n +
    WEIGHTS.rssi * r +
    WEIGHTS.battery * b +
    WEIGHTS.stability * s +
    WEIGHTS.pdr * q;

  if (node.charging) score += CHARGING_BONUS;

  return Math.min(1, score);
}

export function buildOGM(node: MeshNode): OGM {
  return {
    nodeId: node.id,
    seq: node.seq,
    score: node.score,
    isSuper: node.role === "SUPER",
    peerCount: node.peerCount,
    batteryBucket: Math.floor(node.battery * 10),
    bestHopTo: {},
  };
}

export function receiveOGM(node: MeshNode, ogm: OGM, fromNeighbor: NodeId): void {
  const existing = node.ogmTable[ogm.nodeId];
  if (existing && ogm.seq <= existing.seq) return;

  node.ogmTable[ogm.nodeId] = ogm;
  node.neighborScores[ogm.nodeId] = ogm.score;

  const prevSeq = node.nextHopTable[ogm.nodeId]?.lastSeq ?? 0;
  const tqEntry = node.nextHopTable[ogm.nodeId] ?? {
    bestNeighbor: fromNeighbor,
    tq: 0,
    lastSeq: 0,
    hopCount: 0,
    lastSeen: Date.now(),
  };

  const expected = ogm.seq - prevSeq;
  const received = 1;
  const newTq = tqEntry.tq * 0.75 + (expected > 0 ? received / expected : 0) * 0.25;

  node.nextHopTable[ogm.nodeId] = {
    bestNeighbor: fromNeighbor,
    tq: Math.min(1, newTq),
    lastSeq: ogm.seq,
    hopCount: ogm.isSuper ? 1 : (tqEntry.hopCount + 1),
    lastSeen: Date.now(),
  };
}

export function electRole(
  node: MeshNode,
  allNodes: MeshNode[]
): { role: Role; reason: string } {
  const peers = peersInRange(node, allNodes);
  if (peers.length < 3) {
    return { role: "NORMAL", reason: "Too few peers (<3) for SUPER role" };
  }
  if (node.battery < 0.25) {
    return { role: "NORMAL", reason: "Battery below 25% threshold" };
  }

  const allScores = [node.score, ...peers.map((p) => p.score)];
  allScores.sort((a, b) => b - a);
  const rank = allScores.indexOf(node.score);
  const top20Count = Math.max(1, Math.ceil(allScores.length * TOP_20_PERCENT));
  const inTop20 = rank < top20Count;
  const shouldBeSuper = node.score > SUPER_PROMOTE_THRESHOLD && inTop20;
  const shouldDemote = node.score < SUPER_DEMOTE_THRESHOLD;

  const nearbySupers = peers.filter(
    (p) =>
      p.role === "SUPER" &&
      p.score > node.score + PROXIMITY_SCORE_MARGIN &&
      rssiModel(node, p) > PROXIMITY_RSSI_THRESHOLD
  );

  if (shouldBeSuper && nearbySupers.length === 0) {
    if (node.role !== "SUPER") {
      return {
        role: "SUPER",
        reason: `Promoted: score ${node.score.toFixed(2)}, rank ${rank + 1}/${allScores.length}, ${peers.length} peers`,
      };
    }
    return { role: "SUPER", reason: `SUPER: score ${node.score.toFixed(2)}, ${peers.length} peers` };
  }

  if (shouldDemote && node.role === "SUPER") {
    node.demoteCounter++;
    if (node.demoteCounter >= 2) {
      node.demoteCounter = 0;
      return { role: "NORMAL", reason: `Demoted: score ${node.score.toFixed(2)} < ${SUPER_DEMOTE_THRESHOLD} for 2 cycles` };
    }
    return { role: "SUPER", reason: `SUPER (pending demote: ${node.demoteCounter}/2)` };
  }

  if (nearbySupers.length > 0 && node.role === "SUPER") {
    return { role: "NORMAL", reason: `Backed off: SUPER ${nearbySupers[0].id} nearby with higher score` };
  }

  node.demoteCounter = 0;
  return { role: "NORMAL", reason: `NORMAL: score ${node.score.toFixed(2)}, rank ${rank + 1}/${allScores.length}` };
}

export function pruneStaleEntries(node: MeshNode, maxAgeMs: number): void {
  const now = Date.now();
  for (const id of Object.keys(node.ogmTable)) {
    if (now - (node.nextHopTable[id]?.lastSeen ?? 0) > maxAgeMs) {
      delete node.ogmTable[id];
      delete node.neighborScores[id];
      delete node.nextHopTable[id];
    }
  }
}

export function getNextHop(node: MeshNode, dest: NodeId): NodeId | null {
  const entry = node.nextHopTable[dest];
  if (entry && entry.tq > 0.6) return entry.bestNeighbor;
  return null;
}
