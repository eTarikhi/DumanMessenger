import { GROUP_ADDRESS } from "./types";
import type { MeshMessage, MeshNode, MsgType, NodeId, QueuedMessage, RelayPolicy, TransportType } from "./types";
import type { RfParams } from "./rf";
import { canReach, peersInRange, rssiModel } from "./rf";
import {
  DENSE_FALLBACK_FANOUT,
  MPR_NEIGHBOR_ADVERTISE_LIMIT,
  getNextHop,
  relaysCoverPeers,
} from "./election";

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

/** Padding block, per `skills/03`: "DO pad to 256B blocks". */
export const PAD_BLOCK_BYTES = 256;

/**
 * Everything around the body in one encrypted packet, from `skills/03`'s layout:
 * `header {msgId16, ttl, type, destHint8, hop}` = 27 B, `aead {nonce12, tag16}` = 28 B,
 * and inside the ciphertext `from` 32 B + `ts` 8 B. 95 B before the body.
 */
export const PACKET_OVERHEAD_BYTES = 27 + 12 + 16 + 32 + 8;

/**
 * Wire size of one message, in bytes, as the transport selector sees it.
 *
 * This used to be a `64 + 4 bytes per character` heuristic, which crossed the 1 KB
 * BLE ceiling at 241 characters. The documented packet crosses it at 930: encryption
 * adds 95 B and padding rounds *up* to a 256 B block, so a 900-character body is a
 * 1 024 B packet that still rides BLE. The heuristic therefore flipped long texts
 * onto Wi-Fi Direct about four times too early — and since transport is what sets
 * per-hop latency in this model, it made long messages look faster than they are
 * (docs/07 §3).
 */
export function wireSizeOf(bodyChars: number): number {
  const raw = PACKET_OVERHEAD_BYTES + Math.max(0, bodyChars);
  return Math.ceil(raw / PAD_BLOCK_BYTES) * PAD_BLOCK_BYTES;
}

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
  const sizeBytes = wireSizeOf(body.length);
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
  // A repeated SOS flood is a new radio event but the same emergency: it lands on
  // the existing alert with its fresher GPS fix instead of raising a second
  // notification (docs/04: "SOS misuse — the channel is opt-in", and four
  // identical alerts for one emergency is exactly the spam that rule guards
  // against). The receipt still counts at radio level, which is what
  // broadcastReach measures.
  if (msg.sosId) {
    const existing = node.inbox.find((m) => m.sosId === msg.sosId);
    if (existing) {
      // Copies arrive out of order, so only ever move the alert forward in time —
      // a late flood 1 must not overwrite the fix from flood 3. It is still a
      // receipt, and it still must not raise a second notification.
      if (msg.timestamp >= existing.timestamp) {
        existing.id = msg.id;
        existing.body = msg.body;
        existing.timestamp = msg.timestamp;
        existing.sosRepeat = msg.sosRepeat;
        existing.sosPos = msg.sosPos;
      }
      return true;
    }
  }
  node.inbox.push({ ...msg });
  if (node.inbox.length > INBOX_MAX) node.inbox.shift();
  return true;
}

// --- store-carry-forward (DTN) ----------------------------------------------

/** Park a message that has nowhere to go (skills/04: "DO bound memory strictly"). */
export function enqueueOpp(node: MeshNode, msg: MeshMessage, nowMs: number): boolean {
  if (msg.to === "BROADCAST") return false; // broadcasts are not queued
  if (node.oppQueue.some((q) => q.msg.id === msg.id)) return false;
  if (node.oppQueue.length >= OPP_QUEUE_MAX) {
    // skills/04: "keep newest 500 (LRU by priority)". Priority first, then age: a bundle
    // that has already sprayed its three copies is the one to lose, and among those the
    // oldest. Evicting purely by age — what this did before — could throw away a fresh
    // bundle to keep a sprayed-out one.
    const rank = (q: QueuedMessage): number => (q.msg.priority === "low" ? 0 : 1);
    node.oppQueue.sort((a, b) => rank(a) - rank(b) || a.createdAt - b.createdAt);
    node.oppQueue.shift();
    node.oppQueue.sort((a, b) => a.createdAt - b.createdAt);
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

/**
 * Drop every copy of a bundle that has been acknowledged, and report how many went.
 *
 * skills/04: "On `ackReceived` from dest: remove + gossip ACK (so relays can prune)".
 * The ACK travels back along the reverse path, and the nodes on that path are exactly
 * the nodes that were carrying copies — so overhearing one is enough to prune, with no
 * extra traffic and no new packet type. Without it a delivered bundle holds a slot in
 * every carrier's queue for the full seven days, and the 500-message cap spends itself
 * on messages that have already arrived.
 */
export function pruneAcked(node: MeshNode, ackedId: string): number {
  if (node.oppQueue.length === 0) return 0;
  const before = node.oppQueue.length;
  node.oppQueue = node.oppQueue.filter((q) => q.msg.id !== ackedId);
  return before - node.oppQueue.length;
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
  policy: RelayPolicy
): ForwardDecision {
  const peers = peersInRange(node, allNodes, rf);
  if (peers.length === 0) {
    return { mode: "queue", targets: [], reason: "no peers in range" };
  }

  const peerIds = peers.map((p) => p.id);

  // An SOS is the one payload the network optimises for reach instead of
  // efficiency: docs/02 §"Broadcast SOS | All transports flooding | Maximize
  // reach" and docs/05 §"SOS mode | Repeated flood of GPS + text over all
  // transports". MPR suppression exists to delete the duplicate copies that an
  // emergency broadcast is *made of*, and a route lookup would hand the alert to
  // one neighbour instead of all of them, so SOS bypasses both — at every hop,
  // not just at the originator.
  if (msg.type === "sos") {
    return { mode: "flood", targets: peerIds, reason: "SOS: flood every peer — reach over efficiency" };
  }

  // Naive epidemic flooding. Deliberately consulted *before* the route table:
  // a baseline that quietly unicasts along known routes is not the "naive
  // flood" the acceptance criteria compare against, and it flatters nothing —
  // it is the arm that used to hide most of the routing layer's contribution.
  if (policy === "flood-all") {
    return { mode: "flood", targets: peerIds, reason: "naive flood baseline" };
  }

  // A group flood is addressed to nobody in particular: the network does not know
  // the membership, so it forwards on the normal policy (MPR included, unlike SOS)
  // and delivery is decided at the recipient. Routing it as a unicast would send a
  // group message to one neighbour and strand the rest.
  if (msg.to !== "BROADCAST" && msg.to !== GROUP_ADDRESS) {
    if (peerIds.includes(msg.to)) {
      return { mode: "direct", targets: [msg.to], reason: "destination in range" };
    }
    const nextHop = getNextHop(node, msg.to);
    if (nextHop && peerIds.includes(nextHop)) {
      return { mode: "route", targets: [nextHop], reason: `route via ${nextHop}` };
    }
    // A bundle already in DTN circulation has nowhere to go *right now*, which is
    // exactly why it is being carried. Flooding it would spend the neighbourhood's radio
    // on a copy with no path, and MPR suppression would delete it outright — measured in
    // docs/06 §20 as the reason skills/04's carry test could not pass. Park it instead
    // and let the next contact decide.
    if (msg.carried) {
      return {
        mode: "queue",
        targets: [],
        reason: "carried bundle: no route to the destination right now",
      };
    }
  }

  // Flood branch: SUPER relays everything, NORMAL applies MPR suppression —
  // unless the policy switches suppression off, which is what `route-flood` is
  // for (routing kept, MPR removed).
  if (node.role === "SUPER" || policy === "route-flood") {
    return {
      mode: "flood",
      targets: peerIds,
      reason: node.role === "SUPER" ? "SUPER relay-all" : "routing without MPR suppression",
    };
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
  const why = heardSuper
    ? "MPR fallback: SUPER heard but my neighbours are not covered"
    : "MPR fallback: no relay heard";

  // At density the coverage question is unanswerable from the wire, because a beacon
  // advertises at most MPR_NEIGHBOR_ADVERTISE_LIMIT of a node's neighbours. This node
  // still has to forward — it cannot prove anyone else did — but forwarding to all
  // 179 peers is how one message becomes 7,038 transmissions. Forward instead to the
  // strongest links: a K-ary fan-out covers a homogeneous dense world in log_K(N)
  // hops, so the reach survives and the cost stops being quadratic. Where the peer
  // list is complete this branch is not taken and nothing changes.
  if (peers.length > MPR_NEIGHBOR_ADVERTISE_LIMIT) {
    // Chosen by *direction*, not by strength. The strongest links are the nearest
    // peers, and the nearest peers are all on the same side of this node, so picking
    // by RSSI fans out into one wedge and leaves the rest of the world to chance.
    // K angular sectors, best link per sector, then strongest-first to fill any
    // sector that is empty. Measured at 200 nodes: 98.3% delivery at 125
    // transmissions per message, against 96.7% at 205 for the same K chosen by RSSI
    // (docs/06 §15).
    const scored = peers.map((p) => ({
      id: p.id,
      rssi: rssiModel(node, p, rf),
      ang: Math.atan2(p.pos.y - node.pos.y, p.pos.x - node.pos.x),
    }));
    const k = DENSE_FALLBACK_FANOUT;
    const sectors = new Map<number, { id: string; rssi: number }>();
    for (const s of scored) {
      const idx = Math.floor(((s.ang + Math.PI) / (2 * Math.PI)) * k) % k;
      const current = sectors.get(idx);
      if (!current || s.rssi > current.rssi) sectors.set(idx, s);
    }
    const best = [...sectors.values()].map((s) => s.id);
    if (best.length < k) {
      // Tie-break on the id as well as the link: JS and Dart sort differently when
      // two keys are equal, and the two engines must pick the same peers.
      for (const s of scored
        .slice()
        .sort((a, b) => b.rssi - a.rssi || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))) {
        if (best.length >= k) break;
        if (!best.includes(s.id)) best.push(s.id);
      }
    }
    return {
      mode: "flood",
      targets: best,
      reason: `${why} — capped at ${best.length} of ${peers.length} peers (density)`,
    };
  }

  return { mode: "flood", targets: peers.map((p) => p.id), reason: why };
}

/** Spray-and-wait over the OppQueue when peers are discovered (docs/03 §8). */
export interface OppScanResult {
  deliver: QueuedMessage[];
  forward: { queued: QueuedMessage; to: NodeId }[];
  keep: QueuedMessage[];
  /** Forwards that went to a SUPER because the carrier had no route of its own
   *  (skills/04: "prefer SUPER as bundle carrier"). Counted so the cost of the rule can
   *  be reported separately from routed forwarding. */
  superCarries: number;
}

export function scanOppQueue(
  node: MeshNode,
  allNodes: MeshNode[],
  rf: RfParams,
  nowMs: number,
  opts?: { preferSuper?: boolean }
): OppScanResult {
  const result: OppScanResult = { deliver: [], forward: [], keep: [], superCarries: 0 };
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
        // A copy handed to a carrier is a *later* copy of the same bundle, and bumping
        // `attempt` is what says so: intermediate nodes dedupe on `id#attempt`, so without
        // this a relay that already heard the bundle swallows every later hand-over as a
        // duplicate and the bundle never moves. The increment has to be relative to the
        // attempt the bundle is *already* on, because the source retries that put it in
        // the queue used 1 and 2 first: numbering sprayed copies from 1 collides with
        // them and the carrier's cache swallows the first two copies of every bundle
        // (docs/06 §20).
        queued.msg = { ...queued.msg, attempt: queued.msg.attempt + 1 };
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
    // No route of our own. skills/04: "DO prefer SUPER as bundle carrier (more
    // storage/battery)" — and a SUPER is also the node with the fullest view, since it
    // scans continuously and relays everything, so handing a bundle to one is the best
    // available guess about who will meet the destination next. Still bounded by the
    // spray limit: this is the "spray" half of spray-and-wait, not a flood.
    if (opts?.preferSuper && queued.copyCount < SPRAY_LIMIT) {
      const carriers = allNodes.filter(
        (p) => p.id !== node.id && p.isOnline && p.role === "SUPER" && canReach(node, p, rf)
      );
      if (carriers.length > 0) {
        // Deterministic tie-break: strongest signal, then id.
        carriers.sort(
          (a, b) => rssiModel(node, b, rf) - rssiModel(node, a, rf) || (a.id < b.id ? -1 : 1)
        );
        result.forward.push({ queued, to: carriers[0].id });
        result.superCarries++;
        queued.copyCount++;
        queued.msg = { ...queued.msg, attempt: queued.msg.attempt + 1 };
        if (queued.copyCount >= SPRAY_LIMIT) {
          queued.msg = { ...queued.msg, priority: "low" };
        }
        result.keep.push(queued);
        continue;
      }
    }
    result.keep.push(queued);
  }
  return result;
}
