import type { MeshNode, NodeId, MeshMessage } from "./types";
import { computeScore, electRole, buildOGM, receiveOGM, pruneStaleEntries } from "./election";
import { peersInRange, rssiModel, randomWalk, batteryDrain } from "./rf";
import { createMessage, processMessage, tryDeliverOppQueue, pruneSeenCache } from "./routing";

export interface SimConfig {
  areaWidth: number;
  areaHeight: number;
  nodeCount: number;
  stationaryRatio: number;
  chargingRatio: number;
  wallPenalty: number;
  tickIntervalMs: number;
  enableSuperElection: boolean;
  enableMobility: boolean;
}

export const DEFAULT_CONFIG: SimConfig = {
  areaWidth: 800,
  areaHeight: 600,
  nodeCount: 20,
  stationaryRatio: 0.3,
  chargingRatio: 0.15,
  wallPenalty: 12,
  tickIntervalMs: 1000,
  enableSuperElection: true,
  enableMobility: true,
};

export interface SimulationStats {
  tick: number;
  onlineNodes: number;
  superNodes: number;
  avgScore: number;
  avgBattery: number;
  totalDelivered: number;
  totalForwarded: number;
  totalQueued: number;
  deliveryRatio: number;
  overheadRatio: number;
  avgLatencyMs: number;
}

export interface DeliveryRecord {
  msgId: string;
  from: NodeId;
  to: NodeId;
  hops: number;
  latencyMs: number;
  path: NodeId[];
  timestamp: number;
}

export interface SentRecord {
  msgId: string;
  from: NodeId;
  to: NodeId | "BROADCAST";
  type: MeshMessage["type"];
  timestamp: number;
  delivered: boolean;
}

const NAMES = [
  "Amir", "Bianca", "Cristi", "Daria", "Emir", "Florin", "Gabi", "Hana",
  "Igor", "Jana", "Kemal", "Lena", "Marcu", "Nadia", "Ovidiu", "Petra",
  "Radu", "Sara", "Tudor", "Ulla", "Vlad", "Wanda", "Xenia", "Yusuf",
];

export function createNode(id: NodeId, config: SimConfig): MeshNode {
  const idx = parseInt(id.replace("node-", ""), 10);
  const name = NAMES[idx % NAMES.length] ?? `Node${idx}`;
  const stationary = Math.random() < config.stationaryRatio;
  const charging = Math.random() < config.chargingRatio;

  return {
    id,
    name: `${name}-${idx}`,
    pos: {
      x: 50 + Math.random() * (config.areaWidth - 100),
      y: 50 + Math.random() * (config.areaHeight - 100),
    },
    battery: 0.5 + Math.random() * 0.5,
    charging,
    uptimeMin: Math.random() * 30,
    mobility: stationary ? 0 : 0.2 + Math.random() * 0.6,
    pdr: 0.8 + Math.random() * 0.2,
    role: "NORMAL",
    score: 0,
    seq: 0,
    peerCount: 0,
    avgRssi: -70,
    isOnline: true,
    reasonTrace: "Initial",
    ogmTable: {},
    nextHopTable: {},
    neighborScores: {},
    seenCache: new Map(),
    oppQueue: [],
    inbox: [],
    sentLog: [],
    txPower: -30,
    stationary,
    demoteCounter: 0,
    wasSuper: false,
  };
}

export function createNodes(config: SimConfig): MeshNode[] {
  return Array.from({ length: config.nodeCount }, (_, i) =>
    createNode(`node-${i}`, config)
  );
}

export class MeshSimulation {
  nodes: MeshNode[];
  config: SimConfig;
  tick = 0;
  stats: SimulationStats;
  deliveries: DeliveryRecord[] = [];
  sentRecords: SentRecord[] = [];
  msgPathTracker: Map<string, { path: NodeId[]; startTime: number; from: NodeId; to: NodeId | "BROADCAST" }> = new Map();
  ogmInterval = 2;
  electionInterval = 30;
  private listeners: Set<() => void> = new Set();

  constructor(config: SimConfig = DEFAULT_CONFIG) {
    this.config = config;
    this.nodes = createNodes(config);
    this.stats = this.computeStats();
  }

  subscribe(fn: () => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  private notify(): void {
    this.listeners.forEach((fn) => fn());
  }

  step(): void {
    this.tick++;
    const dt = this.config.tickIntervalMs / 1000;

    for (const node of this.nodes) {
      if (!node.isOnline) continue;
      if (this.config.enableMobility) {
        randomWalk(node, this.config.areaWidth, this.config.areaHeight);
      }
      batteryDrain(node, dt);
      if (node.battery <= 0) {
        node.isOnline = false;
        node.role = "NORMAL";
        node.reasonTrace = "Battery depleted";
      }
    }

    if (this.tick % this.ogmInterval === 0) {
      this.broadcastOGMs();
    }

    if (this.config.enableSuperElection && this.tick % this.electionInterval === 0) {
      this.runElection();
    }

    for (const node of this.nodes) {
      if (!node.isOnline) continue;
      pruneSeenCache(node);
      pruneStaleEntries(node, 30000);
      const oppResult = tryDeliverOppQueue(node, this.nodes);
      for (const msg of oppResult.delivered) {
        this.recordDelivery(msg, node.id, [node.id]);
      }
      for (const fwd of oppResult.forwarded) {
        const target = this.nodes.find((n) => n.id === fwd.to);
        if (target) {
          const result = processMessage(target, fwd.msg, this.nodes);
          this.handleForwardResult(target, fwd.msg, result);
        }
      }
    }

    this.stats = this.computeStats();
    this.notify();
  }

  private broadcastOGMs(): void {
    for (const node of this.nodes) {
      if (!node.isOnline) continue;
      node.seq++;
      const peers = peersInRange(node, this.nodes);
      node.peerCount = peers.length;
      if (peers.length > 0) {
        node.avgRssi = peers.reduce((s, p) => s + rssiModel(node, p), 0) / peers.length;
      }
      node.score = computeScore(node, this.nodes);
      const ogm = buildOGM(node);
      for (const peer of peers) {
        receiveOGM(peer, ogm, node.id);
      }
    }
  }

  private runElection(): void {
    for (const node of this.nodes) {
      if (!node.isOnline) continue;
      const { role, reason } = electRole(node, this.nodes);
      if (role !== node.role) {
        node.wasSuper = node.role === "SUPER";
      }
      node.role = role;
      node.reasonTrace = reason;
    }
  }

  sendMessage(
    fromId: NodeId,
    toId: NodeId | "BROADCAST",
    body: string,
    type: MeshMessage["type"] = "text"
  ): MeshMessage | null {
    const from = this.nodes.find((n) => n.id === fromId);
    if (!from || !from.isOnline) return null;

    const ttl = type === "sos" ? 7 : type === "broadcast" ? 5 : 5;
    const priority = type === "sos" || type === "voice" ? "high" : "normal";
    const msg = createMessage(fromId, toId, body, type, ttl, priority);
    from.sentLog.push({ ...msg });
    this.sentRecords.push({
      msgId: msg.id,
      from: fromId,
      to: toId,
      type,
      timestamp: Date.now(),
      delivered: false,
    });
    this.msgPathTracker.set(msg.id, {
      path: [fromId],
      startTime: Date.now(),
      from: fromId,
      to: toId,
    });

    if (toId === "BROADCAST") {
      const peers = peersInRange(from, this.nodes);
      for (const peer of peers) {
        const result = processMessage(peer, msg, this.nodes);
        this.handleForwardResult(peer, msg, result);
      }
    } else {
      const destNode = this.nodes.find((n) => n.id === toId);
      if (destNode && destNode.isOnline) {
        const peers = peersInRange(from, this.nodes);
        const canReachDest = peers.some((p) => p.id === toId);
        if (canReachDest) {
          const result = processMessage(destNode, msg, this.nodes);
          this.handleForwardResult(destNode, msg, result);
        } else {
          const nextHop = this.nodes.find((n) => n.id === from.nextHopTable[toId]?.bestNeighbor);
          if (nextHop && nextHop.isOnline && peers.some((p) => p.id === nextHop.id)) {
            const result = processMessage(nextHop, msg, this.nodes);
            this.handleForwardResult(nextHop, msg, result);
          } else {
            for (const peer of peers) {
              const result = processMessage(peer, msg, this.nodes);
              this.handleForwardResult(peer, msg, result);
            }
          }
        }
      } else {
        for (const [id, entry] of Object.entries(from.nextHopTable)) {
          if (id === toId) {
            const hop = this.nodes.find((n) => n.id === entry.bestNeighbor);
            if (hop && hop.isOnline) {
              const result = processMessage(hop, msg, this.nodes);
              this.handleForwardResult(hop, msg, result);
              return msg;
            }
          }
        }
        const peers = peersInRange(from, this.nodes);
        for (const peer of peers) {
          const result = processMessage(peer, msg, this.nodes);
          this.handleForwardResult(peer, msg, result);
        }
      }
    }
    return msg;
  }

  private handleForwardResult(
    node: MeshNode,
    originalMsg: MeshMessage,
    result: ReturnType<typeof processMessage>
  ): void {
    const tracker = this.msgPathTracker.get(originalMsg.id);

    for (const ack of result.acks) {
      const ackTarget = this.nodes.find((n) => n.id === ack.to);
      if (ackTarget && ackTarget.isOnline) {
        const ackResult = processMessage(ackTarget, ack.msg, this.nodes);
        this.handleForwardResult(ackTarget, ack.msg, ackResult);
      }
    }

    for (const fwd of result.forwarded) {
      const target = this.nodes.find((n) => n.id === fwd.to);
      if (!target || !target.isOnline) continue;

      if (tracker) {
        if (!tracker.path.includes(fwd.to)) {
          tracker.path.push(fwd.to);
        }
      }

      if (fwd.msg.to === target.id) {
        this.recordDelivery(fwd.msg, target.id, tracker?.path ?? [target.id]);
        const sentRec = this.sentRecords.find((s) => s.msgId === originalMsg.id);
        if (sentRec) sentRec.delivered = true;
        const ack = createMessage(target.id, originalMsg.from, `ACK:${originalMsg.id}`, "ack", 3, "high");
        this.sendMessage(target.id, originalMsg.from, ack.body, "ack");
      } else if (fwd.msg.to === "BROADCAST" && fwd.msg.from !== target.id) {
        if (!target.inbox.some((m) => m.id === fwd.msg.id)) {
          target.inbox.push({ ...fwd.msg });
        }
        const fwdResult = processMessage(target, fwd.msg, this.nodes);
        this.handleForwardResult(target, fwd.msg, fwdResult);
      } else {
        const fwdResult = processMessage(target, fwd.msg, this.nodes);
        this.handleForwardResult(target, fwd.msg, fwdResult);
      }
    }
  }

  private recordDelivery(msg: MeshMessage, toId: NodeId, path: NodeId[]): void {
    const tracker = this.msgPathTracker.get(msg.id);
    const latency = tracker ? Date.now() - tracker.startTime : 0;
    const hops = (tracker?.path.length ?? path.length) - 1;
    this.deliveries.push({
      msgId: msg.id,
      from: msg.from,
      to: toId,
      hops: Math.max(0, hops),
      latencyMs: latency,
      path: tracker?.path ?? path,
      timestamp: Date.now(),
    });
    if (this.deliveries.length > 5000) this.deliveries.shift();
  }

  toggleNodeOnline(id: NodeId): void {
    const node = this.nodes.find((n) => n.id === id);
    if (node) {
      node.isOnline = !node.isOnline;
      if (!node.isOnline) {
        node.role = "NORMAL";
        node.reasonTrace = "Offline";
      } else {
        node.battery = Math.max(node.battery, 0.3);
        node.uptimeMin = 0;
        node.reasonTrace = "Reconnected";
      }
      this.notify();
    }
  }

  setNodeCharging(id: NodeId, charging: boolean): void {
    const node = this.nodes.find((n) => n.id === id);
    if (node) {
      node.charging = charging;
      this.notify();
    }
  }

  private computeStats(): SimulationStats {
    const online = this.nodes.filter((n) => n.isOnline);
    const supers = online.filter((n) => n.role === "SUPER");
    const avgScore = online.length > 0 ? online.reduce((s, n) => s + n.score, 0) / online.length : 0;
    const avgBattery = online.length > 0 ? online.reduce((s, n) => s + n.battery, 0) / online.length : 0;

    const totalQueued = this.nodes.reduce((s, n) => s + n.oppQueue.length, 0);
    const totalDelivered = this.deliveries.length;
    const totalSent = this.sentRecords.length;
    const totalForwarded = this.nodes.reduce(
      (s, n) => s + n.seenCache.size,
      0
    );

    const deliveryRatio = totalSent > 0 ? totalDelivered / totalSent : 0;
    const overheadRatio = totalDelivered > 0 ? totalForwarded / totalDelivered : 0;
    const avgLatencyMs = totalDelivered > 0
      ? this.deliveries.reduce((s, d) => s + d.latencyMs, 0) / totalDelivered
      : 0;

    return {
      tick: this.tick,
      onlineNodes: online.length,
      superNodes: supers.length,
      avgScore,
      avgBattery,
      totalDelivered,
      totalForwarded,
      totalQueued,
      deliveryRatio,
      overheadRatio,
      avgLatencyMs,
    };
  }

  reset(config?: Partial<SimConfig>): void {
    this.config = { ...this.config, ...config };
    this.nodes = createNodes(this.config);
    this.tick = 0;
    this.deliveries = [];
    this.sentRecords = [];
    this.msgPathTracker.clear();
    this.stats = this.computeStats();
    this.notify();
  }
}
