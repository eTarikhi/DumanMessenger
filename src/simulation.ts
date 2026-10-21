import type {
  MeshMessage,
  MeshNode,
  MsgType,
  NodeId,
  OGM,
  Obstacle,
  RelayPolicy,
  Role,
} from "./types";
import type { Rng } from "./rng";
import { chance, createRng, randRange } from "./rng";
import type { RfParams } from "./rf";
import {
  batteryDrain,
  DEFAULT_RX_SENSITIVITY_DBM,
  insideAnyObstacle,
  DEFAULT_TX_POWER_DBM,
  DEFAULT_WALL_PENALTY_DB,
  integrateMotion,
  effectiveLossProbability,
  peersInRange,
  rssiModel,
} from "./rf";
import {
  buildOGM,
  computeScore,
  electRole,
  selectMprSet,
  NEIGHBOR_SCORE_TTL_MS,
  ogmToGossip,
  pruneStaleEntries,
  receiveOGM,
} from "./election";
import {
  createMessage,
  decideForward,
  seenKey,
  deliverToInbox,
  enqueueOpp,
  isSeen,
  markSeen,
  pruneOppQueue,
  pruneSeenCache,
  resolveMprWait,
  scanOppQueue,
  MPR_WAIT_MS,
} from "./routing";
import type { EventKind } from "./events";
import { EventQueue } from "./events";

/** A waypoint cluster: where a crowd actually stands (skills/08). */
export interface SpawnCluster {
  cx: number;
  cy: number;
  radius: number;
  count: number;
  label: string;
}

export interface SimConfig {
  /** PRNG seed — the whole run is a pure function of it. */
  seed: number;
  /** Test area in metres (skills/08 specifies a 100x100 m area). */
  areaWidth: number;
  areaHeight: number;
  nodeCount: number;
  /** Optional waypoint clusters. When set, nodes spawn inside these discs
   *  (round-robin by index) instead of uniformly across the area — real crowds
   *  cluster, and clustering is what produces stable router candidates. */
  clusters: SpawnCluster[];
  stationaryRatio: number;
  chargingRatio: number;
  obstacles: Obstacle[];

  tickIntervalMs: number;
  physicsIntervalMs: number;
  ogmIntervalMs: number;
  ogmJitterMs: number;
  ogmTtl: number;
  electionIntervalMs: number;
  scanIntervalSuperMs: number;
  scanIntervalNormalMs: number;

  enableSuperElection: boolean;
  enableMobility: boolean;
  enableDtn: boolean;
  /** "mpr" suppresses redundant NORMAL relays; "flood-all" is the baseline. */
  relayPolicy: RelayPolicy;

  hopLatencyBleMs: number;
  hopLatencyWifiMs: number;
  jitterMinMs: number;
  jitterMaxMs: number;
  mprWaitMs: number;
  /** Source retransmission when no ACK returns (docs/03 §6 "ACK via reverse
   *  path"). 0 disables retries. */
  ackTimeoutMs: number;
  maxRetries: number;

  txPowerDbm: number;
  rxSensitivityDbm: number;
  wallPenaltyDb: number;
  /** Link-layer retransmissions before a failure is reported upwards. */
  linkRetries: number;
  batteryDrainMultiplier: number;

  /** Simulated time spent settling before metrics start counting. */
  warmupMs: number;
  /** Inject random traffic every N ms (0 = off). */
  trafficIntervalMs: number;
}

export const DEFAULT_CONFIG: SimConfig = {
  seed: 42,
  areaWidth: 100,
  areaHeight: 100,
  nodeCount: 20,
  clusters: [],
  stationaryRatio: 0.5,
  chargingRatio: 0.15,
  obstacles: [
    { x: 8, y: 8, w: 18, h: 13, label: "Block A" },
    { x: 74, y: 70, w: 18, h: 14, label: "Block B" },
  ],

  tickIntervalMs: 1000,
  physicsIntervalMs: 250,
  ogmIntervalMs: 2000,
  ogmJitterMs: 200,
  ogmTtl: 5,
  electionIntervalMs: 30000,
  scanIntervalSuperMs: 250,
  scanIntervalNormalMs: 1000,

  enableSuperElection: true,
  enableMobility: true,
  enableDtn: true,
  relayPolicy: "mpr",

  hopLatencyBleMs: 120,
  hopLatencyWifiMs: 40,
  jitterMinMs: 50,
  jitterMaxMs: 200,
  mprWaitMs: MPR_WAIT_MS,
  ackTimeoutMs: 4000,
  maxRetries: 2,

  txPowerDbm: DEFAULT_TX_POWER_DBM,
  rxSensitivityDbm: DEFAULT_RX_SENSITIVITY_DBM,
  wallPenaltyDb: DEFAULT_WALL_PENALTY_DB,
  linkRetries: 2,
  batteryDrainMultiplier: 1,

  warmupMs: 8000,
  trafficIntervalMs: 0,
};

export interface SimulationStats {
  tick: number;
  /** Virtual clock in ms — everything the UI shows is derived from this. */
  simTimeMs: number;
  onlineNodes: number;
  superNodes: number;
  superRatio: number;
  avgScore: number;
  avgBattery: number;
  totalDelivered: number;
  totalForwarded: number;
  totalQueued: number;
  deliveryRatio: number;
  broadcastReach: number;
  overheadRatio: number;
  avgLatencyMs: number;
  /** skills/08: "latencyP50/P95" per run. */
  p50LatencyMs: number;
  p95LatencyMs: number;
  avgHops: number;
  /** Mean peer count — the connectivity health of the simulated world. */
  avgPeers: number;
  /** Nodes that can hear nobody: the failure mode that made the original
   *  prototype useless (11-18 of 20 nodes isolated). */
  isolatedNodes: number;
  lostTransmissions: number;
  lostOgmTransmissions: number;
  mprSuppressed: number;
  roleChangesPerNodeMin: number;
  /** skills/08: "superStability (elections/min)". Same quantity, documented name. */
  electionsPerMin: number;
  controlOverhead: number;
  retriesSent: number;
  retriesExhausted: number;
  acksReceived: number;
  sentUnicast: number;
  sentBroadcast: number;
}

export interface DeliveryRecord {
  msgId: string;
  from: NodeId;
  to: NodeId;
  type: MsgType;
  hops: number;
  latencyMs: number;
  path: NodeId[];
  timestamp: number;
  /** True if the message reached its destination via store-carry-forward. */
  dtn: boolean;
  /** 0 for a first-attempt delivery. Retries carry end-to-end latency that
   *  includes the ACK timeout, so the per-hop transport budget must exclude
   *  them to stay a meaningful measurement. */
  attempt: number;
}

export interface SentRecord {
  msgId: string;
  from: NodeId;
  to: NodeId | "BROADCAST";
  type: MsgType;
  /** Kept so the chat UI can render straight from simulation state. */
  body: string;
  timestamp: number;
  delivered: boolean;
  recipients: number;
}

export interface RoleEvent {
  at: number;
  nodeId: NodeId;
  from: Role;
  to: Role;
  reason: string;
}

const NAMES = [
  "Amir", "Bianca", "Cristi", "Daria", "Emir", "Florin", "Gabi", "Hana",
  "Igor", "Jana", "Kemal", "Lena", "Marcu", "Nadia", "Ovidiu", "Petra",
  "Radu", "Sara", "Tudor", "Ulla", "Vlad", "Wanda", "Xenia", "Yusuf",
];

const PDR_WINDOW = 20;

/**
 * Node construction draws from the PRNG in a fixed order. That order is part of
 * the cross-language contract with `sim/mesh_sim` — changing it invalidates the
 * golden vectors.
 */
export function createNode(
  id: NodeId,
  index: number,
  rng: Rng,
  config: SimConfig,
  spawn: SpawnCluster | null
): MeshNode {
  const name = NAMES[index % NAMES.length];
  const stationary = chance(rng, config.stationaryRatio);
  const charging = chance(rng, config.chargingRatio);

  // Spawn inside the area but never inside a building. The rejection loop keeps
  // the draw order byte-identical to the Dart port.
  const draw = (): { x: number; y: number } => {
    if (spawn) {
      const angle = rng() * Math.PI * 2;
      const rad = spawn.radius * Math.sqrt(rng());
      return { x: spawn.cx + Math.cos(angle) * rad, y: spawn.cy + Math.sin(angle) * rad };
    }
    return { x: 4 + rng() * (config.areaWidth - 8), y: 4 + rng() * (config.areaHeight - 8) };
  };
  let pos = draw();
  for (let attempt = 0; attempt < 16 && insideAnyObstacle(pos, config.obstacles); attempt++) {
    pos = draw();
  }
  const x = Math.max(2, Math.min(config.areaWidth - 2, pos.x));
  const y = Math.max(2, Math.min(config.areaHeight - 2, pos.y));
  const battery = 0.5 + rng() * 0.5;
  // A real handset has been up for hours before it joins a mesh. Starting at
  // 0-30 min meant the documented stability term min(uptimeMin/60, 1) could
  // never saturate during a short run, quietly starving the coverage score.
  const uptimeMin = 30 + rng() * 330;
  const wander = 0.2 + rng() * 0.6;
  const pdr = 0.8 + rng() * 0.2;
  const wanderRadius = spawn ? spawn.radius : Math.min(config.areaWidth, config.areaHeight) / 4;
  const targetAngle = rng() * Math.PI * 2;
  const targetRad = wanderRadius * Math.sqrt(rng());

  return {
    id,
    name: `${name}-${index}`,
    pos: { x, y },
    battery,
    charging,
    uptimeMin,
    mobility: stationary ? 0 : wander,
    pdr,
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
    mprHeardSuper: new Set(),
    heardRelays: new Map(),
    twoHopView: {},
    mprSet: [],
    peerIds: [],
    oppQueue: [],
    inbox: [],
    sentLog: [],
    txPower: config.txPowerDbm,
    stationary,
    demoteCounter: 0,
    wasSuper: false,
    home: { x, y },
    target: {
      x: Math.max(2, Math.min(config.areaWidth - 2, x + Math.cos(targetAngle) * targetRad)),
      y: Math.max(2, Math.min(config.areaHeight - 2, y + Math.sin(targetAngle) * targetRad)),
    },
    wanderRadius,
    lastPhysicsAt: 0,
    nextOgmAt: 0,
    nextScanAt: 0,
    tx: { outcomes: [], cursor: 0, filled: 0 },
    roleTransitions: 0,
    txCount: 0,
    mprSuppressed: 0,
    offlineAt: -1,
  };
}

/** Assign each node index to a cluster, round-robin over the declared counts. */
export function clusterForIndex(config: SimConfig, index: number): SpawnCluster | null {
  if (config.clusters.length === 0) return null;
  let cursor = 0;
  for (const c of config.clusters) {
    if (index < cursor + c.count) return c;
    cursor += c.count;
  }
  // Indices past the declared cluster sizes fall back to the largest cluster.
  let biggest = config.clusters[0];
  for (const c of config.clusters) if (c.count > biggest.count) biggest = c;
  return biggest;
}

export function createNodes(rng: Rng, config: SimConfig): MeshNode[] {
  const nodes: MeshNode[] = [];
  for (let i = 0; i < config.nodeCount; i++) {
    nodes.push(createNode(`node-${i}`, i, rng, config, clusterForIndex(config, i)));
  }
  return nodes;
}

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[idx];
}

interface MsgPayload {
  msg: MeshMessage;
  via: NodeId;
}

interface PathTrace {
  path: NodeId[];
  createdAt: number;
  from: NodeId;
  to: NodeId | "BROADCAST";
  type: MsgType;
}

/**
 * Discrete-event mesh simulation.
 *
 * Time is virtual (`now`), so TTLs, the 300 ms MPR wait, OGM expiry and latency
 * are all real protocol durations instead of wall-clock artefacts. Nothing in
 * here touches `Date.now()` or `Math.random()`.
 */
export class MeshSimulation {
  nodes: MeshNode[];
  config: SimConfig;
  rf: RfParams;
  rng: Rng;
  now = 0;
  tick = 0;
  stats: SimulationStats;
  deliveries: DeliveryRecord[] = [];
  sentRecords: SentRecord[] = [];
  roleEvents: RoleEvent[] = [];

  private queue = new EventQueue();
  private msgCounter = 0;
  private traces = new Map<string, PathTrace>();
  /** Logical msgId -> the originator still waiting for its ACK. */
  private pendingAcks = new Map<string, { msg: MeshMessage; from: NodeId; attempts: number }>();
  private listeners = new Set<() => void>();

  // counters
  private relayTx = 0;
  private ogmTx = 0;
  private lostDataTx = 0;
  private lostOgmTx = 0;
  private duplicateRx = 0;
  private mprSuppressed = 0;
  private broadcastReceipts = 0;
  private sentUnicast = 0;
  private sentBroadcast = 0;
  private superSamples = 0;
  private superSampleSum = 0;
  private retriesSent = 0;
  private retriesExhausted = 0;
  private acksReceived = 0;

  constructor(config: SimConfig = DEFAULT_CONFIG) {
    this.config = config;
    this.rng = createRng(config.seed);
    this.rf = {
      txPowerDbm: config.txPowerDbm,
      rxSensitivityDbm: config.rxSensitivityDbm,
      wallPenaltyDb: config.wallPenaltyDb,
      obstacles: config.obstacles,
    };
    this.nodes = createNodes(this.rng, config);
    this.schedule();
    this.runFor(config.warmupMs);
    this.clearRecords();
    this.stats = this.computeStats();
  }

  // --- lifecycle -------------------------------------------------------------

  private schedule(): void {
    this.queue.clear();
    this.queue.push(this.config.physicsIntervalMs, "physics", "*");
    if (this.config.enableSuperElection) {
      this.queue.push(this.config.electionIntervalMs, "election", "*");
    }
    for (const node of this.nodes) {
      const stagger = randRange(this.rng, 0, this.config.ogmIntervalMs);
      this.queue.push(stagger, "ogm", node.id);
      this.queue.push(stagger / 2, "scan", node.id);
    }
    if (this.config.trafficIntervalMs > 0) {
      this.queue.push(this.config.trafficIntervalMs, "traffic", "*");
    }
  }

  private clearRecords(): void {
    this.deliveries = [];
    this.sentRecords = [];
    this.roleEvents = [];
    this.traces.clear();
    this.relayTx = 0;
    this.ogmTx = 0;
    this.lostDataTx = 0;
    this.lostOgmTx = 0;
    this.duplicateRx = 0;
    this.mprSuppressed = 0;
    this.broadcastReceipts = 0;
    this.sentUnicast = 0;
    this.sentBroadcast = 0;
    this.superSamples = 0;
    this.superSampleSum = 0;
    this.retriesSent = 0;
    this.retriesExhausted = 0;
    this.acksReceived = 0;
    this.pendingAcks.clear();
    for (const n of this.nodes) {
      n.roleTransitions = 0;
      n.txCount = 0;
      n.mprSuppressed = 0;
      n.inbox = [];
      n.oppQueue = [];
      n.sentLog = [];
    }
  }

  subscribe(fn: () => void): () => void {
    this.listeners.add(fn);
    return () => {
      this.listeners.delete(fn);
    };
  }

  private notify(): void {
    for (const fn of this.listeners) fn();
  }

  /** Advance the virtual clock by `ms`, running every event that comes due. */
  runFor(ms: number): void {
    const target = this.now + ms;
    for (;;) {
      const ev = this.queue.peek();
      if (!ev || ev.at > target) break;
      this.queue.pop();
      this.now = ev.at;
      this.handleEvent(ev.kind, ev.nodeId, ev.payload);
    }
    this.now = target;
  }

  /** One UI tick. */
  step(): void {
    this.runFor(this.config.tickIntervalMs);
    this.tick++;
    this.stats = this.computeStats();
    this.notify();
  }

  runTicks(n: number): void {
    for (let i = 0; i < n; i++) this.runFor(this.config.tickIntervalMs);
    this.tick += n;
    this.stats = this.computeStats();
  }

  reset(config?: Partial<SimConfig>): void {
    const merged: SimConfig = { ...this.config, ...config };
    this.config = merged;
    this.rng = createRng(merged.seed);
    this.rf = {
      txPowerDbm: merged.txPowerDbm,
      rxSensitivityDbm: merged.rxSensitivityDbm,
      wallPenaltyDb: merged.wallPenaltyDb,
      obstacles: merged.obstacles,
    };
    this.nodes = createNodes(this.rng, merged);
    this.now = 0;
    this.tick = 0;
    this.msgCounter = 0;
    this.schedule();
    this.runFor(merged.warmupMs);
    this.clearRecords();
    this.stats = this.computeStats();
    this.notify();
  }

  // --- events ----------------------------------------------------------------

  private handleEvent(kind: EventKind, nodeId: string, payload?: unknown): void {
    switch (kind) {
      case "physics":
        this.onPhysics();
        break;
      case "ogm":
        this.onOgm(nodeId);
        break;
      case "election":
        this.onElection();
        break;
      case "scan":
        this.onScan(nodeId);
        break;
      case "msg":
        this.onMsgReceive(nodeId, payload as MsgPayload);
        break;
      case "mpr":
        this.onMprDecide(nodeId, payload as MeshMessage);
        break;
      case "acktimeout":
        this.onAckTimeout(nodeId, payload as string);
        break;
      case "traffic":
        this.onTraffic();
        break;
      default:
        break;
    }
  }

  private onPhysics(): void {
    const dtSec = this.config.physicsIntervalMs / 1000;
    for (const node of this.nodes) {
      if (!node.isOnline) continue;
      integrateMotion(
        node,
        this.rng,
        dtSec,
        this.config.areaWidth,
        this.config.areaHeight,
        this.config.enableMobility
      );
      batteryDrain(node, dtSec, this.config.batteryDrainMultiplier);
      node.uptimeMin += dtSec / 60;
      node.lastPhysicsAt = this.now;
      if (node.battery <= 0) {
        node.isOnline = false;
        node.offlineAt = this.now;
        node.role = "NORMAL";
        node.reasonTrace = "Battery depleted";
        this.queue.cancel("ogm", node.id);
        this.queue.cancel("scan", node.id);
      }
    }
    this.queue.push(this.now + this.config.physicsIntervalMs, "physics", "*");
  }

  private onOgm(nodeId: string): void {
    const node = this.byId(nodeId);
    if (!node || !node.isOnline) return;
    this.refreshPeerList(node);
    node.score = computeScore(node, this.nodes, this.rf);
    node.seq++;
    const ogm = buildOGM(node);
    this.beacon(node, ogm);
    const jitter = randRange(this.rng, -this.config.ogmJitterMs, this.config.ogmJitterMs);
    this.queue.push(
      this.now + Math.max(200, this.config.ogmIntervalMs + jitter),
      "ogm",
      nodeId
    );
  }

  /** Transmit an OGM to every peer, then let each peer gossip it onward. */
  private beacon(node: MeshNode, ogm: OGM): void {
    for (const peer of peersInRange(node, this.nodes, this.rf)) {
      this.ogmTx++;
      if (chance(this.rng, effectiveLossProbability(node, peer, this.rf, this.config.linkRetries))) {
        this.lostOgmTx++;
        continue;
      }
      this.acceptOgm(peer, ogm, node.id);
    }
  }

  private acceptOgm(receiver: MeshNode, ogm: OGM, via: NodeId): void {
    if (!receiver.isOnline) return;
    const shouldGossip = receiveOGM(receiver, ogm, via, this.now);
    if (!shouldGossip) return;
    const next = ogmToGossip(ogm, this.config.ogmTtl);
    if (!next) return;
    for (const peer of peersInRange(receiver, this.nodes, this.rf)) {
      if (peer.id === via) continue;
      this.ogmTx++;
      if (
        chance(this.rng, effectiveLossProbability(receiver, peer, this.rf, this.config.linkRetries))
      ) {
        this.lostOgmTx++;
        continue;
      }
      this.acceptOgm(peer, next, receiver.id);
    }
  }

  private onElection(): void {
    for (const node of this.nodes) {
      if (!node.isOnline) continue;
      node.score = computeScore(node, this.nodes, this.rf);
      if (!this.config.enableSuperElection) continue;
      const { role, reason } = electRole(node, this.nodes, this.rf);
      if (role !== node.role) {
        node.wasSuper = node.role === "SUPER";
        node.roleTransitions++;
        this.roleEvents.push({ at: this.now, nodeId: node.id, from: node.role, to: role, reason });
      }
      node.role = role;
      node.reasonTrace = reason;
    }
    const online = this.nodes.filter((n) => n.isOnline);
    this.superSamples++;
    this.superSampleSum += online.filter((n) => n.role === "SUPER").length / Math.max(1, online.length);
    this.queue.push(this.now + this.config.electionIntervalMs, "election", "*");
  }

  private onScan(nodeId: string): void {
    const node = this.byId(nodeId);
    if (!node || !node.isOnline) return;
    const peers = this.refreshPeerList(node);
    if (peers.length > 0) {
      let sum = 0;
      for (const p of peers) sum += rssiModel(node, p, this.rf);
      node.avgRssi = sum / peers.length;
    }
    pruneSeenCache(node, this.now);
    pruneStaleEntries(node, this.now, NEIGHBOR_SCORE_TTL_MS);
    pruneOppQueue(node, this.now);
    node.mprSet = selectMprSet(node);

    if (this.config.enableDtn && node.oppQueue.length > 0) {
      const scan = scanOppQueue(node, this.nodes, this.rf, this.now);
      for (const q of scan.deliver) {
        this.transmit(node, q.msg, q.msg.to as NodeId);
      }
      for (const f of scan.forward) {
        this.transmit(node, f.queued.msg, f.to);
      }
      node.oppQueue = scan.keep;
    }

    const interval =
      node.role === "SUPER" ? this.config.scanIntervalSuperMs : this.config.scanIntervalNormalMs;
    this.queue.push(this.now + interval, "scan", nodeId);
  }

  private onTraffic(): void {
    this.injectRandomMessage();
    if (this.config.trafficIntervalMs > 0) {
      this.queue.push(this.now + this.config.trafficIntervalMs, "traffic", "*");
    }
  }

  // --- sending ---------------------------------------------------------------

  /** Recompute the 1-hop neighbour list. Sorted, so OGM advertisements and the
   *  MPR set are deterministic across runs and across both language engines. */
  private refreshPeerList(node: MeshNode): MeshNode[] {
    const peers = peersInRange(node, this.nodes, this.rf);
    node.peerCount = peers.length;
    node.peerIds = peers.map((p) => p.id).sort();
    return peers;
  }

  private nextMsgId(): string {
    this.msgCounter++;
    return `m${this.msgCounter}`;
  }

  private byId(id: NodeId): MeshNode | undefined {
    for (const n of this.nodes) if (n.id === id) return n;
    return undefined;
  }

  /** Inject a user message into the mesh. Returns the message, or null. */
  sendMessage(
    fromId: NodeId,
    toId: NodeId | "BROADCAST",
    body: string,
    type: MsgType = "text"
  ): MeshMessage | null {
    const from = this.byId(fromId);
    if (!from || !from.isOnline) return null;

    const ttl = type === "sos" ? 7 : 5;
    const priority = type === "sos" || type === "voice" ? "high" : "normal";
    const msgType: MsgType = toId === "BROADCAST" && type === "text" ? "broadcast" : type;
    const msg = createMessage(this.nextMsgId(), this.now, fromId, toId, body, msgType, ttl, priority);

    from.sentLog.push({ ...msg });
    if (msgType !== "ack") {
      this.sentRecords.push({
        msgId: msg.id,
        from: fromId,
        to: toId,
        type: msgType,
        body,
        timestamp: this.now,
        delivered: false,
        recipients: 0,
      });
      if (toId === "BROADCAST") this.sentBroadcast++;
      else this.sentUnicast++;
    }
    this.traces.set(msg.id, {
      path: [fromId],
      createdAt: this.now,
      from: fromId,
      to: toId,
      type: msgType,
    });

    if (toId !== "BROADCAST" && msgType !== "ack" && this.config.maxRetries > 0) {
      this.pendingAcks.set(msg.id, { msg, from: fromId, attempts: 0 });
      this.queue.push(this.now + this.config.ackTimeoutMs, "acktimeout", fromId, msg.id);
    }

    const decision = decideForward(
      from,
      msg,
      this.nodes,
      this.rf,
      this.config.relayPolicy === "mpr"
    );
    this.applyDecision(from, msg, decision.mode, decision.targets);
    return msg;
  }

  /**
   * No ACK came back, so the originator retransmits. The retry carries the same
   * logical id but a new `attempt`, which lets it travel again through nodes
   * that already relayed (and deduped) the first copy.
   */
  private onAckTimeout(nodeId: string, msgId: string): void {
    const pending = this.pendingAcks.get(msgId);
    if (!pending || pending.from !== nodeId) return;
    const node = this.byId(nodeId);
    if (!node || !node.isOnline) {
      this.pendingAcks.delete(msgId);
      return;
    }
    if (pending.attempts >= this.config.maxRetries) {
      this.pendingAcks.delete(msgId);
      this.retriesExhausted++;
      // Last resort: carry it until a peer appears (docs/03 §8).
      if (this.config.enableDtn) enqueueOpp(node, pending.msg, this.now);
      return;
    }
    pending.attempts++;
    this.retriesSent++;
    const retry: MeshMessage = {
      ...pending.msg,
      attempt: pending.attempts,
      ttl: pending.msg.ttl,
      hopCount: 0,
      timestamp: this.now,
    };
    const decision = decideForward(
      node,
      retry,
      this.nodes,
      this.rf,
      this.config.relayPolicy === "mpr"
    );
    this.applyDecision(node, retry, decision.mode, decision.targets);
    this.queue.push(this.now + this.config.ackTimeoutMs, "acktimeout", nodeId, msgId);
  }

  /** Pick a random online pair and send a message (used by UI + traffic gen). */
  injectRandomMessage(): MeshMessage | null {
    const online = this.nodes.filter((n) => n.isOnline);
    if (online.length < 2) return null;
    const from = online[Math.floor(this.rng() * online.length)];
    let to = online[Math.floor(this.rng() * online.length)];
    let guard = 0;
    while (to.id === from.id && guard++ < 32) {
      to = online[Math.floor(this.rng() * online.length)];
    }
    if (to.id === from.id) return null;
    const broadcast = chance(this.rng, 0.25);
    return this.sendMessage(
      from.id,
      broadcast ? "BROADCAST" : to.id,
      broadcast ? "ping all" : `hey ${to.name}`,
      broadcast ? "broadcast" : "text"
    );
  }

  /** Send `count` messages spread evenly over `overMs` of simulated time. */
  injectTraffic(count: number, overMs: number): void {
    const gap = overMs / Math.max(1, count);
    for (let i = 0; i < count; i++) {
      const at = this.now + gap * (i + 1);
      this.queue.push(at, "traffic", "*");
    }
  }

  private applyDecision(
    node: MeshNode,
    msg: MeshMessage,
    mode: string,
    targets: NodeId[]
  ): void {
    switch (mode) {
      case "direct":
      case "route":
      case "flood":
        for (const t of targets) this.transmit(node, msg, t);
        break;
      case "wait-mpr":
        this.queue.push(this.now + this.config.mprWaitMs, "mpr", node.id, msg);
        break;
      case "queue":
        if (this.config.enableDtn) enqueueOpp(node, msg, this.now);
        break;
      case "drop":
        this.mprSuppressed++;
        break;
      default:
        break;
    }
  }

  private onMprDecide(nodeId: string, msg: MeshMessage): void {
    const node = this.byId(nodeId);
    if (!node || !node.isOnline) return;
    const decision = resolveMprWait(node, msg, this.nodes, this.rf);
    if (decision.mode === "drop") {
      this.mprSuppressed++;
      node.mprSuppressed++;
      return;
    }
    this.applyDecision(node, msg, decision.mode, decision.targets);
  }

  /** One radio transmission: rolls link loss, then schedules the hop. */
  private transmit(node: MeshNode, msg: MeshMessage, targetId: NodeId): void {
    const target = this.byId(targetId);
    if (!target || !target.isOnline || target.id === node.id) return;
    node.txCount++;
    this.relayTx++;
    const loss = effectiveLossProbability(node, target, this.rf, this.config.linkRetries);
    if (chance(this.rng, loss)) {
      this.lostDataTx++;
      this.recordTxOutcome(node, 0);
      return;
    }
    this.recordTxOutcome(node, 1);
    const base = msg.transport === "wifiDirect" ? this.config.hopLatencyWifiMs : this.config.hopLatencyBleMs;
    const delay = base + randRange(this.rng, this.config.jitterMinMs, this.config.jitterMaxMs);
    this.queue.push(this.now + delay, "msg", targetId, { msg, via: node.id } as MsgPayload);
  }

  private recordTxOutcome(node: MeshNode, ok: number): void {
    const w = node.tx;
    if (w.outcomes.length < PDR_WINDOW) {
      w.outcomes.push(ok);
    } else {
      w.outcomes[w.cursor] = ok;
    }
    w.cursor = (w.cursor + 1) % PDR_WINDOW;
    w.filled = Math.min(PDR_WINDOW, w.filled + 1);
    let sum = 0;
    for (const v of w.outcomes) sum += v;
    node.pdr = w.filled === 0 ? 0.9 : sum / w.outcomes.length;
  }

  // --- receiving -------------------------------------------------------------

  private onMsgReceive(nodeId: string, payload: MsgPayload): void {
    const node = this.byId(nodeId);
    if (!node || !node.isOnline) return;
    const { msg, via } = payload;
    const sender = this.byId(via);

    // Coverage evidence for the MPR gate. Any neighbour we receive a copy from
    // already holds the message, so it never needs covering again; and that
    // neighbour's own advertised list tells us who else is reached. Recorded for
    // duplicates too, since a second relay covering a different neighbour is
    // exactly what closes a hole.
    if (sender) {
      const key = seenKey(msg);
      let relays = node.heardRelays.get(key);
      if (!relays) {
        relays = new Set<NodeId>();
        node.heardRelays.set(key, relays);
      }
      relays.add(sender.id);
    }

    if (isSeen(node, seenKey(msg))) {
      // A duplicate copy still carries information: it tells this node that a
      // SUPER neighbour retransmitted, which is what MPR suppression listens for.
      this.duplicateRx++;
      if (sender && sender.role === "SUPER") node.mprHeardSuper.add(msg.id);
      return;
    }
    markSeen(node, seenKey(msg), this.now);
    if (sender && sender.role === "SUPER") node.mprHeardSuper.add(msg.id);

    const trace = this.traces.get(msg.id);
    if (trace && !trace.path.includes(node.id)) trace.path.push(node.id);

    if (msg.to === node.id) {
      if (msg.type === "ack") {
        const ackedId = msg.body.slice(4);
        if (this.pendingAcks.has(ackedId)) this.pendingAcks.delete(ackedId);
        this.acksReceived++;
      }
      const fresh = deliverToInbox(node, msg);
      if (fresh) this.recordDelivery(node, msg, trace);
      if (msg.type !== "ack" && msg.to !== "BROADCAST") this.sendAck(node, msg);
      return;
    }

    if (msg.to === "BROADCAST") {
      const fresh = deliverToInbox(node, msg);
      if (fresh) {
        this.broadcastReceipts++;
        this.recordDelivery(node, msg, trace);
        const rec = this.sentRecords.find((s) => s.msgId === msg.id);
        if (rec) {
          rec.recipients++;
          rec.delivered = true;
        }
      }
    }

    if (msg.ttl <= 0) return;

    const forwarded: MeshMessage = {
      ...msg,
      ttl: msg.ttl - 1,
      hopCount: msg.hopCount + 1,
    };
    const decision = decideForward(
      node,
      forwarded,
      this.nodes,
      this.rf,
      this.config.relayPolicy === "mpr"
    );
    this.applyDecision(node, forwarded, decision.mode, decision.targets);
  }

  private sendAck(node: MeshNode, original: MeshMessage): void {
    const ack = createMessage(
      this.nextMsgId(),
      this.now,
      node.id,
      original.from,
      `ACK:${original.id}`,
      "ack",
      3,
      "high"
    );
    this.traces.set(ack.id, {
      path: [node.id],
      createdAt: this.now,
      from: node.id,
      to: original.from,
      type: "ack",
    });
    const decision = decideForward(
      node,
      ack,
      this.nodes,
      this.rf,
      this.config.relayPolicy === "mpr"
    );
    this.applyDecision(node, ack, decision.mode, decision.targets);
  }

  private recordDelivery(
    node: MeshNode,
    msg: MeshMessage,
    trace: PathTrace | undefined
  ): void {
    const createdAt = trace ? trace.createdAt : msg.timestamp;
    this.deliveries.push({
      msgId: msg.id,
      from: msg.from,
      to: node.id,
      type: msg.type,
      // Radio hops traversed: a direct transmission is 1 hop, so the
      // documented "<2 s 1 hop / <5 s 3 hops" budget is comparable.
      hops: msg.hopCount + 1,
      latencyMs: Math.max(0, this.now - createdAt),
      path: trace ? trace.path.slice() : [node.id],
      timestamp: this.now,
      attempt: msg.attempt,
      dtn: msg.carried,
    });
    if (this.deliveries.length > 5000) this.deliveries.shift();
    const rec = this.sentRecords.find((s) => s.msgId === msg.id);
    if (rec) rec.delivered = true;
  }

  // --- manual controls (UI) ---------------------------------------------------

  toggleNodeOnline(id: NodeId): void {
    const node = this.byId(id);
    if (!node) return;
    node.isOnline = !node.isOnline;
    if (!node.isOnline) {
      node.role = "NORMAL";
      node.reasonTrace = "Offline";
      node.offlineAt = this.now;
      this.queue.cancel("ogm", node.id);
      this.queue.cancel("scan", node.id);
    } else {
      node.battery = Math.max(node.battery, 0.3);
      node.uptimeMin = 0;
      node.offlineAt = -1;
      node.reasonTrace = "Reconnected";
      this.queue.push(this.now + 100, "ogm", node.id);
      this.queue.push(this.now + 100, "scan", node.id);
    }
    this.stats = this.computeStats();
    this.notify();
  }

  setNodeCharging(id: NodeId, charging: boolean): void {
    const node = this.byId(id);
    if (!node) return;
    node.charging = charging;
    this.stats = this.computeStats();
    this.notify();
  }

  // --- metrics ---------------------------------------------------------------

  private computeStats(): SimulationStats {
    const online = this.nodes.filter((n) => n.isOnline);
    const supers = online.filter((n) => n.role === "SUPER");
    const avgScore = online.length ? online.reduce((s, n) => s + n.score, 0) / online.length : 0;
    const avgBattery = online.length ? online.reduce((s, n) => s + n.battery, 0) / online.length : 0;

    const unicastDeliveries = this.deliveries.filter(
      (d) => d.type !== "ack" && d.type !== "broadcast"
    );
    const dataDeliveries = this.deliveries.filter((d) => d.type !== "ack");
    const latencies = unicastDeliveries.map((d) => d.latencyMs).sort((a, b) => a - b);
    const hops = unicastDeliveries.map((d) => d.hops);

    const deliveryRatio = this.sentUnicast > 0 ? unicastDeliveries.length / this.sentUnicast : 0;
    const broadcastReach =
      this.sentBroadcast > 0
        ? this.broadcastReceipts / (this.sentBroadcast * Math.max(1, online.length))
        : 0;
    const overheadRatio = dataDeliveries.length > 0 ? this.relayTx / dataDeliveries.length : 0;
    const avgLatencyMs = latencies.length ? latencies.reduce((s, v) => s + v, 0) / latencies.length : 0;
    const avgHops = hops.length ? hops.reduce((s, v) => s + v, 0) / hops.length : 0;

    const elapsedMin = this.now / 60000;
    const transitions = this.nodes.reduce((s, n) => s + n.roleTransitions, 0);
    const roleChangesPerNodeMin =
      elapsedMin > 0 && this.nodes.length > 0 ? transitions / this.nodes.length / elapsedMin : 0;

    const peerCounts = this.nodes.map((n) => n.peerCount);
    const avgPeers = peerCounts.length
      ? peerCounts.reduce((a, b) => a + b, 0) / peerCounts.length
      : 0;

    return {
      tick: this.tick,
      simTimeMs: this.now,
      onlineNodes: online.length,
      superNodes: supers.length,
      superRatio: online.length ? supers.length / online.length : 0,
      avgScore,
      avgBattery,
      totalDelivered: unicastDeliveries.length,
      totalForwarded: this.relayTx,
      totalQueued: this.nodes.reduce((s, n) => s + n.oppQueue.length, 0),
      deliveryRatio,
      broadcastReach,
      overheadRatio,
      avgLatencyMs,
      p50LatencyMs: percentile(latencies, 50),
      p95LatencyMs: percentile(latencies, 95),
      avgHops,
      avgPeers,
      isolatedNodes: peerCounts.filter((c) => c === 0).length,
      lostTransmissions: this.lostDataTx,
      lostOgmTransmissions: this.lostOgmTx,
      mprSuppressed: this.mprSuppressed,
      roleChangesPerNodeMin,
      electionsPerMin: roleChangesPerNodeMin,
      controlOverhead: this.ogmTx,
      retriesSent: this.retriesSent,
      retriesExhausted: this.retriesExhausted,
      acksReceived: this.acksReceived,
      sentUnicast: this.sentUnicast,
      sentBroadcast: this.sentBroadcast,
    };
  }

  /** Time-averaged SUPER ratio across election samples. */
  get timeAvgSuperRatio(): number {
    return this.superSamples > 0 ? this.superSampleSum / this.superSamples : 0;
  }

  get duplicateReceptions(): number {
    return this.duplicateRx;
  }

  refresh(): SimulationStats {
    this.stats = this.computeStats();
    return this.stats;
  }
}

export { percentile };
