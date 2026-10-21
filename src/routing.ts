import type { MeshMessage, MeshNode, MsgType, NodeId, QueuedMessage, TransportType } from "./types";
import type { RfParams } from "./rf";
import { canReach, peersInRange } from "./rf";
import { getNextHop, relaysCoverPeers } from "./election";

/**
 * Data plane (docs/03 §6, docs/05 §2.1).
 *
 * These functions are pure *decisions*: they say what a node should do with a
 * message. `simulation.ts` owns time, link loss and bookkeeping. Keeping the
 * split this way is what makes the routing rules unit-testable — and what makes
 * the Dart port a mechanical translation rather than a re-implementation.
 */

export const SEEN_CACHE_TTL_MS = 5 * 60 * 1000;
export const SEEN_CACHE_MAX = 5000;
export const OPP_QUEUE_MAX = 500;
export const OPP_TTL_MS = 7 * 24 * 60 * 60 * 1000;
export const SPRAY_LIMIT = 3;
export const MPR_WAIT_MS = 300;
export const INBOX_MAX = 200;

/** Text < 1 KB rides BLE; larger payloads need Wi-Fi Direct (docs/02 §3.1). */
export const BLE_MAX_BYTES = 1024;

export function selectTransport(sizeBytes: number): TransportType {
  return sizeBytes > BLE_MAX_BYTES ? "wifiDirect" : "ble";
}

function hashHint(id: string): string {
  let h = 0;
  for (let i = 0; i < id.length; i++) {
    h = ((h << 5) - h + id.charCodeAt(i)) | 0;
  }
  return Math.abs(h).toString(16).slice(0, 8);
}

/**
 * Build a message. `id` comes from the caller's monotonic counter rather than
 * the wall clock, so identical seeds produce identical message ids in both
 * language implementations.
 */
/** Dedup key: a source retry must be allowed to travel again. */
export function seenKey(msg: MeshMessage): string {
  return `${msg.id}#${msg.attempt}`;
}

export function createMessage(
  id: string,
  nowMs: number,
  from: NodeId,
  to: NodeId | "BROADCAST",
  body: string,
  type: MsgType = "text",
  ttl = 5,
  priority: MeshMessage["priority"] = "normal"
): MeshMessage {
  const sizeBytes = 64 + body.length * 4;
  return {
    id,
    type,
    from,
    to,
    destHint: to === "BROADCAST" ? "broadcast" : hashHint(to),
    body,
    ttl,
    hopCount: 0,
    attempt: 0,
    carried: false,
    priority,
    timestamp: nowMs,
    encrypted: type !== "broadcast",
    transport: selectTransport(sizeBytes),
    sizeBytes,
  };
}

// --- dedup cache -------------------------------------------------------------

export function isSeen(node: MeshNode, msgId: string): boolean {
  return node.seenCache.has(msgId);
}

export function markSeen(node: MeshNode, msgId: string, nowMs: number): void {
  if (node.seenCache.size >= SEEN_CACHE_MAX) {
    const oldest = node.seenCache.keys().next();
    if (!oldest.done) node.seenCache.delete(oldest.value);
  }
  node.seenCache.set(msgId, nowMs);
}

export function pruneSeenCache(node: MeshNode, nowMs: number): void {
  for (const [id, ts] of node.seenCache) {
    if (nowMs - ts > SEEN_CACHE_TTL_MS) node.seenCache.delete(id);
  }
  if (node.mprHeardSuper.size > SEEN_CACHE_MAX) node.mprHeardSuper.clear();
  // Relay evidence is only useful while the message itself is dedup-relevant.
  for (const key of Array.from(node.heardRelays.keys())) {
    if (!node.seenCache.has(key)) node.heardRelays.delete(key);
  }
  if (node.heardRelays.size > SEEN_CACHE_MAX) node.heardRelays.clear();
}

// --- delivery ----------------------------------------------------------------

export function deliverToInbox(node: MeshNode, msg: MeshMessage): boolean {
  if (node.inbox.some((m) => m.id === msg.id)) return false;
  node.inbox.push({ ...msg });
  if (node.inbox.length > INBOX_MAX) node.inbox.shift();
  return true;
}

// --- store-carry-forward (DTN) ----------------------------------------------

export function enqueueOpp(node: MeshNode, msg: MeshMessage, nowMs: number): boolean {
  if (msg.to === "BROADCAST") return false; // broadcasts are not queued
  if (node.oppQueue.some((q) => q.msg.id === msg.id)) return false;
  if (node.oppQueue.length >= OPP_QUEUE_MAX) {
    node.oppQueue.sort((a, b) => a.createdAt - b.createdAt);
    node.oppQueue.shift();
  }
  // Opportunistic from here on: the bundle waits for a contact rather than being
  // routed, so its end-to-end latency is a meeting time, not a transport time.
  // Marking the *stored copy* keeps the flag with the object that is eventually
  // forwarded or handed to the destination.
  const carried: MeshMessage = { ...msg, carried: true };
  node.oppQueue.push({ msg: carried, createdAt: nowMs, copyCount: 0, ttlMs: OPP_TTL_MS });
  return true;
}

/** Drop expired bundles. `nowMs` is simulation time, so a 7-day TTL is real. */
export function pruneOppQueue(node: MeshNode, nowMs: number): void {
  node.oppQueue = node.oppQueue.filter((q) => nowMs - q.createdAt <= q.ttlMs);
}

export type ForwardMode = "direct" | "route" | "flood" | "wait-mpr" | "queue" | "drop";

export interface ForwardDecision {
  mode: ForwardMode;
  targets: NodeId[];
  reason: string;
}

/**
 * Decide how `node` should forward `msg`.
 *
 * Rules, in order (docs/03 §6):
 *   1. destination is a neighbour              -> unicast, no wait
 *   2. a route with tq >= 0.6 is known         -> unicast to best neighbour
 *   3. SUPER                                   -> flood immediately
 *   4. NORMAL under the MPR policy             -> wait 300 ms for a SUPER
 *   5. nobody in range                         -> OppQueue (store-carry-forward)
 */
export function decideForward(
  node: MeshNode,
  msg: MeshMessage,
  allNodes: MeshNode[],
  rf: RfParams,
  mprEnabled: boolean
): ForwardDecision {
  const peers = peersInRange(node, allNodes, rf);
  if (peers.length === 0) {
    return { mode: "queue", targets: [], reason: "no peers in range" };
  }

  const peerIds = peers.map((p) => p.id);

  if (msg.to !== "BROADCAST") {
    if (peerIds.includes(msg.to)) {
      return { mode: "direct", targets: [msg.to], reason: "destination in range" };
    }
    const nextHop = getNextHop(node, msg.to);
    if (nextHop && peerIds.includes(nextHop)) {
      return { mode: "route", targets: [nextHop], reason: `route via ${nextHop}` };
    }
  }

  // Flood branch: SUPER relays everything, NORMAL applies MPR suppression.
  if (node.role === "SUPER" || !mprEnabled) {
    return { mode: "flood", targets: peerIds, reason: node.role === "SUPER" ? "SUPER relay-all" : "flood-all policy" };
  }
  return { mode: "wait-mpr", targets: peerIds, reason: "NORMAL waiting 300ms for SUPER" };
}

/**
 * Apply the MPR decision once the 300 ms wait has elapsed.
 *
 * docs/03 §6 says: "wait 300 ms; if no retransmit from SUPER heard: forward".
 * Taken literally that is unsafe, because hearing a SUPER says nothing about
 * whether that SUPER reaches *this node's* neighbours — measured on a 60-node
 * crowd it cut relays by 68-79% but cost 16-29 points of delivery.
 *
 * docs/01 and docs/03 §1 define MPR properly as a relay set "covering 2-hop
 * neighbors", so the suppression is gated on coverage: stay quiet only when the
 * relays actually heard retransmitting cover every 1-hop neighbour. Otherwise
 * forward. Same overhead win where coverage genuinely overlaps, no holes where
 * it does not.
 */
export function resolveMprWait(
  node: MeshNode,
  msg: MeshMessage,
  allNodes: MeshNode[],
  rf: RfParams
): ForwardDecision {
  const peers = peersInRange(node, allNodes, rf);
  if (peers.length === 0) return { mode: "queue", targets: [], reason: "no peers in range" };
  if (relaysCoverPeers(node, seenKey(msg))) {
    node.mprSuppressed++;
    return {
      mode: "drop",
      targets: [],
      reason: "MPR: heard relays cover all my neighbours",
    };
  }
  const heardSuper = node.mprHeardSuper.has(msg.id);
  return {
    mode: "flood",
    targets: peers.map((p) => p.id),
    reason: heardSuper
      ? "MPR fallback: SUPER heard but my neighbours are not covered"
      : "MPR fallback: no relay heard",
  };
}

/** Spray-and-wait over the OppQueue when peers are discovered (docs/03 §8). */
export interface OppScanResult {
  deliver: QueuedMessage[];
  forward: { queued: QueuedMessage; to: NodeId }[];
  keep: QueuedMessage[];
}

export function scanOppQueue(
  node: MeshNode,
  allNodes: MeshNode[],
  rf: RfParams,
  nowMs: number
): OppScanResult {
  const result: OppScanResult = { deliver: [], forward: [], keep: [] };
  for (const queued of node.oppQueue) {
    if (nowMs - queued.createdAt > queued.ttlMs) continue; // expired
    const dest = queued.msg.to;
    if (dest === "BROADCAST") {
      result.keep.push(queued);
      continue;
    }
    const destNode = allNodes.find((n) => n.id === dest);
    if (destNode && destNode.isOnline && canReach(node, destNode, rf)) {
      result.deliver.push(queued);
      continue;
    }
    const nextHop = getNextHop(node, dest);
    const neighbor = nextHop ? allNodes.find((n) => n.id === nextHop) : undefined;
    if (nextHop && neighbor && neighbor.isOnline && canReach(node, neighbor, rf)) {
      if (queued.copyCount < SPRAY_LIMIT) {
        result.forward.push({ queued, to: nextHop });
        queued.copyCount++;
        // docs/03 §8: "if copyCount == 3: keep but lower priority". The bundle
        // stays so it can still be handed straight to the destination later;
        // only the copying stops.
        if (queued.copyCount >= SPRAY_LIMIT) {
          queued.msg = { ...queued.msg, priority: "low" };
        }
      }
      result.keep.push(queued);
      continue;
    }
    result.keep.push(queued);
  }
  return result;
}
