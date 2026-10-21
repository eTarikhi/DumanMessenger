import type { MeshNode, MeshMessage, NodeId, QueuedMessage } from "./types";
import { canReach, rssiModel } from "./rf";
import { getNextHop } from "./election";

const SEEN_CACHE_TTL = 5 * 60 * 1000;
const SEEN_CACHE_MAX = 5000;
const OPP_QUEUE_MAX = 500;
const OPP_TTL_DAYS = 7;
const SPRAY_LIMIT = 3;
const MPR_WAIT_MS = 300;

let msgCounter = 0;
export function generateMsgId(): string {
  msgCounter++;
  return `msg-${Date.now()}-${msgCounter}`;
}

export function createMessage(
  from: NodeId,
  to: NodeId | "BROADCAST",
  body: string,
  type: MeshMessage["type"] = "text",
  ttl = 5,
  priority: MeshMessage["priority"] = "normal"
): MeshMessage {
  return {
    id: generateMsgId(),
    type,
    from,
    to,
    destHint: to === "BROADCAST" ? "broadcast" : hashHint(to),
    body,
    ttl,
    hopCount: 0,
    priority,
    timestamp: Date.now(),
    encrypted: true,
  };
}

function hashHint(id: string): string {
  let h = 0;
  for (let i = 0; i < id.length; i++) {
    h = ((h << 5) - h + id.charCodeAt(i)) | 0;
  }
  return Math.abs(h).toString(16).slice(0, 8);
}

export function isSeen(node: MeshNode, msgId: string): boolean {
  return node.seenCache.has(msgId);
}

export function markSeen(node: MeshNode, msgId: string): void {
  if (node.seenCache.size >= SEEN_CACHE_MAX) {
    const oldest = node.seenCache.keys().next().value;
    if (oldest) node.seenCache.delete(oldest);
  }
  node.seenCache.set(msgId, Date.now());
}

export function pruneSeenCache(node: MeshNode): void {
  const now = Date.now();
  for (const [id, ts] of node.seenCache) {
    if (now - ts > SEEN_CACHE_TTL) node.seenCache.delete(id);
  }
}

export function deliverToInbox(node: MeshNode, msg: MeshMessage): void {
  if (node.inbox.some((m) => m.id === msg.id)) return;
  node.inbox.push({ ...msg });
  if (node.inbox.length > 200) node.inbox.shift();
}

export function enqueueOpp(node: MeshNode, msg: MeshMessage): void {
  if (node.oppQueue.some((q) => q.msg.id === msg.id)) return;
  if (node.oppQueue.length >= OPP_QUEUE_MAX) {
    node.oppQueue.sort((a, b) => a.createdAt - b.createdAt);
    node.oppQueue.shift();
  }
  node.oppQueue.push({
    msg: { ...msg },
    createdAt: Date.now(),
    copyCount: 0,
    ttlDays: OPP_TTL_DAYS,
  });
}

export function tryDeliverOppQueue(
  node: MeshNode,
  allNodes: MeshNode[]
): { delivered: MeshMessage[]; forwarded: { to: NodeId; msg: MeshMessage }[] } {
  const delivered: MeshMessage[] = [];
  const forwarded: { to: NodeId; msg: MeshMessage }[] = [];

  const remaining: QueuedMessage[] = [];
  for (const queued of node.oppQueue) {
    const ageDays = (Date.now() - queued.createdAt) / (1000 * 60 * 60 * 24);
    if (ageDays > queued.ttlDays) continue;

    const dest = queued.msg.to;
    if (dest === "BROADCAST") {
      remaining.push(queued);
      continue;
    }

    const destNode = allNodes.find((n) => n.id === dest);
    if (destNode && destNode.isOnline && canReach(node, destNode)) {
      delivered.push(queued.msg);
    } else {
      const route = getNextHop(node, dest);
      if (route) {
        const neighbor = allNodes.find((n) => n.id === route);
        if (neighbor && neighbor.isOnline && canReach(node, neighbor)) {
          if (queued.copyCount < SPRAY_LIMIT) {
            forwarded.push({ to: route, msg: queued.msg });
            queued.copyCount++;
          }
          if (queued.copyCount < SPRAY_LIMIT) {
            remaining.push(queued);
          }
        } else {
          remaining.push(queued);
        }
      } else {
        remaining.push(queued);
      }
    }
  }
  node.oppQueue = remaining;
  return { delivered, forwarded };
}

export interface ForwardResult {
  delivered: { to: NodeId; msg: MeshMessage }[];
  forwarded: { to: NodeId; msg: MeshMessage }[];
  queued: MeshMessage[];
  acks: { to: NodeId; msg: MeshMessage }[];
}

export function processMessage(
  node: MeshNode,
  msg: MeshMessage,
  allNodes: MeshNode[]
): ForwardResult {
  const result: ForwardResult = { delivered: [], forwarded: [], queued: [], acks: [] };

  if (isSeen(node, msg.id)) return result;
  markSeen(node, msg.id);

  if (msg.to === node.id || (msg.to === "BROADCAST" && msg.from !== node.id)) {
    if (msg.type !== "ack" && msg.to === node.id) {
      deliverToInbox(node, msg);
      const ack = createMessage(node.id, msg.from, `ACK:${msg.id}`, "ack", 3, "high");
      result.acks.push({ to: msg.from, msg: ack });
    } else if (msg.to === "BROADCAST") {
      deliverToInbox(node, msg);
    }
    if (msg.to === node.id && msg.type !== "ack") return result;
  }

  if (msg.ttl <= 0) return result;

  const decremented: MeshMessage = {
    ...msg,
    ttl: msg.ttl - 1,
    hopCount: msg.hopCount + 1,
  };

  if (msg.to === "BROADCAST") {
    const neighbors = allNodes.filter(
      (n) => n.id !== node.id && n.isOnline && canReach(node, n)
    );
    for (const n of neighbors) {
      result.forwarded.push({ to: n.id, msg: decremented });
    }
    return result;
  }

  if (msg.type === "ack") {
    const dest = msg.to;
    const nextHop = getNextHop(node, dest);
    if (nextHop) {
      result.forwarded.push({ to: nextHop, msg: decremented });
    } else {
      const neighbors = allNodes.filter(
        (n) => n.id !== node.id && n.isOnline && canReach(node, n)
      );
      for (const n of neighbors) {
        result.forwarded.push({ to: n.id, msg: decremented });
      }
    }
    return result;
  }

  const dest = msg.to;
  const destNode = allNodes.find((n) => n.id === dest);

  if (destNode && destNode.isOnline && canReach(node, destNode)) {
    result.forwarded.push({ to: dest, msg: decremented });
    return result;
  }

  const nextHop = getNextHop(node, dest);
  if (nextHop) {
    const neighbor = allNodes.find((n) => n.id === nextHop);
    if (neighbor && neighbor.isOnline && canReach(node, neighbor)) {
      result.forwarded.push({ to: nextHop, msg: decremented });
      return result;
    }
  }

  if (node.role === "SUPER") {
    const neighbors = allNodes.filter(
      (n) => n.id !== node.id && n.isOnline && canReach(node, n) && rssiModel(node, n) > -75
    );
    for (const n of neighbors) {
      result.forwarded.push({ to: n.id, msg: decremented });
    }
  }

  if (result.forwarded.length === 0) {
    result.queued.push(decremented);
    enqueueOpp(node, decremented);
  }

  return result;
}

export function shouldNormalRelay(
  node: MeshNode,
  _msg: MeshMessage,
  _allNodes: MeshNode[],
  superRetransmitted: boolean
): boolean {
  if (node.role === "SUPER") return true;
  if (superRetransmitted) return false;
  return true;
}

export { MPR_WAIT_MS };
