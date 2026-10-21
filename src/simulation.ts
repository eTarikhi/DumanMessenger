import type {
  HopAction,
  HopRecord,
  MeshLogEntry,
  MeshLogKind,
  MeshMessage,
  MeshNode,
  MsgType,
  NodeId,
  OGM,
  Obstacle,
  RelayPolicy,
  Role,
} from "./types";
import type { ForwardDecision, ForwardMode } from "./routing";
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

  /** skills/07 duty cycling — "NORMAL `scan 3s/sleep 7s`, SUPER `continuous`".
   *  Off by default: it changes when discovery happens, so turning it on is a
   *  different experiment (docs/06 §7). */
  dutyCycleEnabled: boolean;
  normalScanWindowMs: number;
  normalScanCycleMs: number;
  /** Scanner-off battery drain as a fraction of the awake rate. */
  sleepDrainFactor: number;

  /** Record the pcap-like mesh log (`sim.log`). Off by default: a 60-node crowd
   *  emits hundreds of thousands of events and the golden runs pay for none of
   *  it. Hop traces on delivered messages are always recorded — they are bounded
   *  by the path length and are what the UI's "via 2 nodes" line reads. */
  captureLog: boolean;
  /** Also log OGM beacons. Separate flag because beacons outnumber everything. */
  captureOgm: boolean;
  /** Ring-buffer depth for `sim.log`. */
  maxLogEntries: number;

  /** docs/05 §"Broadcast SOS | All transports, flood (TTL=5)". */
  sosTtl: number;
  /** Gap between the repeated SOS floods. */
  sosRepeatMs: number;
  /** How many times the originator re-floods after the first. `0` reduces SOS to
   *  a single broadcast, which is the arm the repeat mechanism is measured
   *  against. */
  sosRepeats: number;

  enableSuperElection: boolean;
  enableMobility: boolean;
  enableDtn: boolean;
  /** `mpr` ships; `route-flood` and `flood-all` are the two A/B baselines. */
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

  dutyCycleEnabled: false,
  normalScanWindowMs: 3000,
  normalScanCycleMs: 10000,
  sleepDrainFactor: 0.25,

  captureLog: false,
  captureOgm: false,
  maxLogEntries: 2000,

  sosTtl: 5,
  sosRepeatMs: 5000,
  sosRepeats: 3,

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
  /** SOS floods actually put on air, repeats included (docs/05 §SOS mode). */
  sosFloods: number;

  /** skills/07 telemetry: "Battery %/h per role, scans/sec, relays/sec".
   *  Measured from the battery snapshot taken when metrics were cleared, over
   *  nodes that are online, in that role and not charging. */
  batteryPercentPerHourNormal: number;
  batteryPercentPerHourSuper: number;
  scansPerSec: number;
  relaysPerSec: number;
  /** Scans a duty-cycling node skipped because its scanner was asleep. */
  scansSkippedAsleep: number;
  /** Fraction of online non-SUPER nodes inside their wake window (1 when duty
   *  cycling is off). */
  awakeRatio: number;
  /** Election log depth — skills/02: "DO log `electionEvents` for tuner". */
  electionEvents: number;
  /** roadmap Phase 2 metrics dashboard: "latency by hop". First-attempt routed
   *  unicast only, matching the docs/04 §5 budget's scope. */
  latencyByHop: LatencyByHop[];
}

/** Latency distribution for one hop count. */
export interface LatencyByHop {
  hops: number;
  count: number;
  avgMs: number;
  p95Ms: number;
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
  /** The journey behind `path`: time, link budget and decision per hop
   *  (roadmap Phase 4, "via 2 nodes • SUPER Amir"). */
  hopTrace: HopRecord[];
}

/**
 * The chain of nodes a delivered copy actually travelled, recovered by walking
 * `via` backwards from the recipient.
 *
 * `path` (and therefore `hopTrace`) is every node that accepted a fresh copy —
 * a *tree* once a relay fans out, so a 4-hop delivery in a 20-node mesh can list
 * 15 nodes. The roadmap's "via 2 nodes • SUPER Amir" wants the route, not the
 * tree, and `via` is enough to recover it. The originator is not in the result
 * (it never receives its own message): prepend `delivery.from` when rendering.
 * A retransmission shares the message id and so the same trace, in which case
 * the first record for each node wins.
 */
export function deliveredChain(hopTrace: HopRecord[], to: NodeId): HopRecord[] {
  const firstAt = new Map<NodeId, HopRecord>();
  for (const h of hopTrace) {
    if (!firstAt.has(h.nodeId)) firstAt.set(h.nodeId, h);
  }
  const chain: HopRecord[] = [];
  const seen = new Set<NodeId>();
  let cur = firstAt.get(to);
  while (cur && !seen.has(cur.nodeId)) {
    seen.add(cur.nodeId);
    chain.unshift(cur);
    cur = firstAt.get(cur.via);
  }
  return chain;
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
  /** Set on every SOS flood of one emergency, so a UI can collapse the repeats
   *  into a single alert exactly as a receiver's inbox does. */
  sosId?: string;
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
    tqWindows: new Map(),
    neighborScores: {},
    seenCache: new Map(),
    mprHeardSuper: new Set(),
    heardRelays: new Map(),
    twoHopView: {},
    mprSet: [],
    peerIds: [],
    superOptOut: false,
    batterySaver: false,
    // Spread phases evenly over the cycle by index, so a crowd does not sleep in
    // lockstep. Derived, never drawn: the RNG draw order is a contract.
    dutyPhaseMs:
      config.nodeCount > 0
        ? (index % config.nodeCount) * (config.normalScanCycleMs / config.nodeCount)
        : 0,
    batteryAtMeasure: battery,
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

/** How a forwarding decision shows up in a message's hop trace. `wait-mpr` is
 *  provisional: if the 300 ms wait ends in suppression, `onMprDecide` rewrites
 *  the record so the trace reports the outcome, not the intention. */
const HOP_ACTION_BY_MODE: Record<ForwardMode, HopAction> = {
  direct: "relayed",
  route: "relayed",
  flood: "relayed",
  "wait-mpr": "relayed",
  queue: "queued",
  drop: "suppressed",
};

interface PathTrace {
  path: NodeId[];
  /** One record per node that accepted a fresh copy, in arrival order. Parallel
   *  to `path` but carrying time, link budget and the forwarding decision. */
  hops: HopRecord[];
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
interface SosRepeatPayload {
  sosId: string;
  body: string;
  repeat: number;
}

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
  /** pcap-like capture of radio and protocol events. Bounded, and empty unless
   *  `config.captureLog` is set. */
  log: MeshLogEntry[] = [];
  private scanCount = 0;
  private scansSkippedAsleep = 0;
  /** Simulation time when metrics were last cleared: the telemetry baseline. */
  private measureStartMs = 0;

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
  private sosFloods = 0;
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

  /**
   * Re-baseline the measurement window: drop the accumulated records and
   * snapshot every node's battery and the clock now, so the stats that follow
   * describe only what happens after this call. The warm-up path uses it to
   * discard bootstrap churn; a caller can use it to measure a settled window
   * (roles promoted at the first election otherwise bleed their pre-promotion
   * drain into a per-role %/h average).
   */
  clearRecords(): void {
    this.log = [];
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
    this.sosFloods = 0;
    this.superSamples = 0;
    this.superSampleSum = 0;
    this.retriesSent = 0;
    this.retriesExhausted = 0;
    this.acksReceived = 0;
    this.scanCount = 0;
    this.scansSkippedAsleep = 0;
    this.measureStartMs = this.now;
    this.pendingAcks.clear();
    for (const n of this.nodes) {
      n.batteryAtMeasure = n.battery;
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
      case "sosrepeat":
        this.onSosRepeat(nodeId, payload as SosRepeatPayload);
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
      // A duty-cycling node with its scanner off burns less: skills/07's whole
      // argument is that the sleep slot is what keeps NORMAL under 15%/8h.
      batteryDrain(
        node,
        dtSec,
        this.config.batteryDrainMultiplier * (this.isAwake(node) ? 1 : this.config.sleepDrainFactor)
      );
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
      this.pushLog("ogm", node.id, `OGM seq ${ogm.seq} → ${peer.id} (score ${ogm.score.toFixed(2)})`, {
        peerId: peer.id,
      });
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

  /** Is this node's scanner inside its wake window?
   *
   *  skills/07: "Duty cycle: NORMAL `scan 3s/sleep 7s`, SUPER `continuous`".
   *  Only *scanning* is affected. An asleep node keeps beaconing and keeps
   *  relaying traffic it already knows how to forward, which is the BLE
   *  asymmetry the spec describes: the advertiser stays up and the link layer
   *  schedules connection events, while the scanner is what gets throttled
   *  (Android caps it at 5 starts per 30 s). Modelling a fully off radio would
   *  also need connection-interval negotiation, which is out of scope here.
   */
  isAwake(node: MeshNode, atMs: number = this.now): boolean {
    if (!this.config.dutyCycleEnabled || node.role === "SUPER") return true;
    const cycle = Math.max(1, this.config.normalScanCycleMs);
    const phase = ((atMs + node.dutyPhaseMs) % cycle + cycle) % cycle;
    return phase < this.config.normalScanWindowMs;
  }

  /** Append one capture-log line. A no-op unless capture is on, so the default
   *  path — and every golden vector — pays nothing for the log. */
  private pushLog(
    kind: MeshLogKind,
    nodeId: NodeId,
    detail: string,
    extra: Partial<MeshLogEntry> = {}
  ): void {
    if (!this.config.captureLog) return;
    if (kind === "ogm" && !this.config.captureOgm) return;
    this.log.push({ atMs: this.now, kind, nodeId, detail, ...extra });
    if (this.log.length > this.config.maxLogEntries) {
      this.log.splice(0, this.log.length - this.config.maxLogEntries);
    }
  }

  /** Score and re-elect one node, recording any transition. */
  private electOne(node: MeshNode): void {
    node.score = computeScore(node, this.nodes, this.rf);
    if (!this.config.enableSuperElection) return;
    const { role, reason } = electRole(node, this.nodes, this.rf);
    if (role !== node.role) {
      node.wasSuper = node.role === "SUPER";
      node.roleTransitions++;
      this.roleEvents.push({ at: this.now, nodeId: node.id, from: node.role, to: role, reason });
    }
    if (role !== node.role) {
      this.pushLog("election", node.id, `${node.name}: ${node.role} → ${role} — ${reason}`);
    }
    node.role = role;
    node.reasonTrace = reason;
  }

  private onElection(): void {
    for (const node of this.nodes) {
      if (!node.isOnline) continue;
      this.electOne(node);
    }
    const online = this.nodes.filter((n) => n.isOnline);
    this.superSamples++;
    this.superSampleSum += online.filter((n) => n.role === "SUPER").length / Math.max(1, online.length);
    this.queue.push(this.now + this.config.electionIntervalMs, "election", "*");
  }

  private onScan(nodeId: string): void {
    const node = this.byId(nodeId);
    if (!node || !node.isOnline) return;
    const interval =
      node.role === "SUPER" ? this.config.scanIntervalSuperMs : this.config.scanIntervalNormalMs;

    if (!this.isAwake(node)) {
      // Scanner off: no discovery, no OppQueue hand-off, no MPR recompute this
      // cycle. The scan event still recurs so the node picks its window back up
      // without a reschedule, and the event stream stays regular.
      this.scansSkippedAsleep++;
      this.queue.push(this.now + interval, "scan", nodeId);
      return;
    }
    this.scanCount++;

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

    // docs/05 §"Broadcast SOS | All transports, flood (TTL=5)". Reach comes from
    // repeating the flood, not from a longer TTL — see onSosRepeat.
    const ttl = type === "sos" ? this.config.sosTtl : 5;
    const priority = type === "sos" || type === "voice" ? "high" : "normal";
    const msgType: MsgType = toId === "BROADCAST" && type === "text" ? "broadcast" : type;
    const msg = createMessage(this.nextMsgId(), this.now, fromId, toId, body, msgType, ttl, priority);
    if (msgType === "sos") {
      const sosId = `sos-${fromId}-${Math.round(this.now)}`;
      this.decorateSos(msg, from, 0, sosId);
      this.sosFloods++;
      this.pushLog(
        "sos",
        fromId,
        `${sosId} flood 1/${this.config.sosRepeats + 1} from ${from.name} at (${from.pos.x.toFixed(1)}, ${from.pos.y.toFixed(1)})`,
        { msgId: msg.id, msgType: "sos" }
      );
    }

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
        sosId: msg.sosId,
      });
      if (toId === "BROADCAST") this.sentBroadcast++;
      else this.sentUnicast++;
    }
    this.traces.set(msg.id, {
      path: [fromId],
      hops: [],
      createdAt: this.now,
      from: fromId,
      to: toId,
      type: msgType,
    });

    // A note to self never needs the radio: the originator ignores copies of its
    // own messages (see onMsgReceive), so echo it straight into the inbox.
    if (toId === fromId && msgType !== "ack") {
      if (deliverToInbox(from, msg)) {
        this.recordDelivery(from, msg, this.traces.get(msg.id));
      }
      this.pushLog(
        "deliver",
        fromId,
        `${msg.id} kept locally — the sender is the destination`,
        { msgId: msg.id, msgType }
      );
      return msg;
    }

    if (toId !== "BROADCAST" && msgType !== "ack" && this.config.maxRetries > 0) {
      this.pendingAcks.set(msg.id, { msg, from: fromId, attempts: 0 });
      this.queue.push(this.now + this.config.ackTimeoutMs, "acktimeout", fromId, msg.id);
    }

    const decision = decideForward(
      from,
      msg,
      this.nodes,
      this.rf,
      this.config.relayPolicy
    );
    this.applyDecision(from, msg, decision);
    if (msgType === "sos" && this.config.sosRepeats > 0) {
      this.scheduleSosRepeat(fromId, msg.sosId!, body, 1);
    }
    return msg;
  }

  /**
   * Stamp the SOS fields on a flood.
   *
   * Wi-Fi Direct is the transport an SOS goes out on. In this model the RF budget
   * is transport-independent, so what it buys is a third of the per-hop latency
   * (`hopLatencyWifiMs` 40 vs `hopLatencyBleMs` 120) — and docs/02 §3.1 has the
   * app preferring the higher-capability transport for a payload that must move.
   * "All transports" is not modelled: one payload, one transport, one radio.
   */
  private decorateSos(msg: MeshMessage, from: MeshNode, repeat: number, sosId: string): void {
    msg.sosId = sosId;
    msg.sosRepeat = repeat;
    msg.sosPos = { x: from.pos.x, y: from.pos.y };
    msg.transport = "wifiDirect";
  }

  private scheduleSosRepeat(nodeId: string, sosId: string, body: string, repeat: number): void {
    this.queue.push(this.now + this.config.sosRepeatMs, "sosrepeat", nodeId, { sosId, body, repeat });
  }

  /**
   * Repeat an SOS flood — docs/05 §"SOS mode: repeated flood of GPS + text over
   * all transports", whose exit criterion is "SOS reaches all within TTL".
   *
   * Every flood is a fresh message with a fresh id: the seen-cache is keyed on the
   * id, so a repeat that reused one would be dropped by every node that already
   * heard it. What ties the floods together is `sosId`, which is also what
   * receivers collapse on. Each carries the sender's position *now*, so a sender
   * that is moving stays trackable across repeats — which is a reason to repeat
   * beyond mere loss recovery. A node that goes offline or is switched off stops
   * flooding: the emergency is over, or it can no longer speak.
   */
  private onSosRepeat(nodeId: string, payload: SosRepeatPayload): void {
    const node = this.byId(nodeId);
    if (!node || !node.isOnline) return;

    const msg = createMessage(
      this.nextMsgId(),
      this.now,
      nodeId,
      "BROADCAST",
      payload.body,
      "sos",
      this.config.sosTtl,
      "high"
    );
    this.decorateSos(msg, node, payload.repeat, payload.sosId);
    this.sosFloods++;
    this.sentBroadcast++;

    node.sentLog.push({ ...msg });
    this.sentRecords.push({
      msgId: msg.id,
      from: nodeId,
      to: "BROADCAST",
      type: "sos",
      body: payload.body,
      timestamp: this.now,
      delivered: false,
      recipients: 0,
      sosId: msg.sosId,
    });
    this.traces.set(msg.id, {
      path: [nodeId],
      hops: [],
      createdAt: this.now,
      from: nodeId,
      to: "BROADCAST",
      type: "sos",
    });
    this.pushLog(
      "sos",
      nodeId,
      `${payload.sosId} flood ${payload.repeat + 1}/${this.config.sosRepeats + 1} from ${node.name} at (${node.pos.x.toFixed(1)}, ${node.pos.y.toFixed(1)})`,
      { msgId: msg.id, msgType: "sos" }
    );

    const decision = decideForward(node, msg, this.nodes, this.rf, this.config.relayPolicy);
    this.applyDecision(node, msg, decision);

    if (payload.repeat < this.config.sosRepeats) {
      this.scheduleSosRepeat(nodeId, payload.sosId, payload.body, payload.repeat + 1);
    }
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
      if (this.config.enableDtn) {
        enqueueOpp(node, pending.msg, this.now);
        this.pushLog(
          "queue",
          node.id,
          `${msgId} retries exhausted at ${node.name} — carrying until a peer appears (${node.oppQueue.length} held)`,
          { msgId, msgType: pending.msg.type }
        );
      }
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
      this.config.relayPolicy
    );
    this.applyDecision(node, retry, decision);
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

  private applyDecision(node: MeshNode, msg: MeshMessage, decision: ForwardDecision): void {
    switch (decision.mode) {
      case "direct":
      case "route":
      case "flood":
        for (const t of decision.targets) this.transmit(node, msg, t);
        break;
      case "wait-mpr":
        this.queue.push(this.now + this.config.mprWaitMs, "mpr", node.id, msg);
        break;
      case "queue":
        if (this.config.enableDtn) {
          enqueueOpp(node, msg, this.now);
          this.pushLog("queue", node.id, `${msg.id} → OppQueue at ${node.name} (${node.oppQueue.length} held)`, {
            msgId: msg.id,
            msgType: msg.type,
          });
        }
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
    const hopRecord = this.traces.get(msg.id)?.hops.find((h) => h.nodeId === node.id);
    if (decision.mode === "drop") {
      this.mprSuppressed++;
      node.mprSuppressed++;
      if (hopRecord) {
        hopRecord.action = "suppressed";
        hopRecord.reason = decision.reason;
      }
      this.pushLog("decision", node.id, `${msg.id} MPR-suppressed at ${node.name} — ${decision.reason}`, {
        msgId: msg.id,
        msgType: msg.type,
        hop: msg.hopCount,
      });
      return;
    }
    if (hopRecord) hopRecord.reason = decision.reason;
    this.applyDecision(node, msg, decision);
  }

  /** One radio transmission: rolls link loss, then schedules the hop. */
  private transmit(node: MeshNode, msg: MeshMessage, targetId: NodeId): void {
    const target = this.byId(targetId);
    if (!target || !target.isOnline || target.id === node.id) return;
    node.txCount++;
    this.relayTx++;
    const loss = effectiveLossProbability(node, target, this.rf, this.config.linkRetries);
    const rssi = rssiModel(node, target, this.rf);
    if (chance(this.rng, loss)) {
      this.lostDataTx++;
      this.recordTxOutcome(node, 0);
      this.pushLog("loss", node.id, `${msg.id} → ${targetId} lost (${(loss * 100).toFixed(1)}% at ${rssi.toFixed(0)} dBm)`, {
        peerId: targetId,
        msgId: msg.id,
        msgType: msg.type,
        hop: msg.hopCount,
        rssi,
      });
      return;
    }
    this.recordTxOutcome(node, 1);
    this.pushLog("tx", node.id, `${msg.id} → ${targetId} (${msg.type}, hop ${msg.hopCount}, ${rssi.toFixed(0)} dBm)`, {
      peerId: targetId,
      msgId: msg.id,
      msgType: msg.type,
      hop: msg.hopCount,
      rssi,
    });
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

    // A node never hears its own transmission, but it does hear peers relaying it
    // back — and that copy is not news. Without this the originator would accept
    // its own broadcast as a delivery (raising its own SOS as a received alert)
    // and then re-flood it, so every returning copy triggers a fresh fan-out from
    // the source: a storm amplifier on exactly the message type that already
    // floods to every peer. Coverage evidence above is recorded either way, since
    // a neighbour relaying my message back is still a neighbour that holds it.
    const isOwn = msg.from === node.id;
    if (isOwn || isSeen(node, seenKey(msg))) {
      // A duplicate copy still carries information: it tells this node that a
      // SUPER neighbour retransmitted, which is what MPR suppression listens for.
      this.duplicateRx++;
      if (sender && sender.role === "SUPER") node.mprHeardSuper.add(msg.id);
      this.pushLog(
        "duplicate",
        node.id,
        isOwn
          ? `${msg.id} own message returned by ${via} — not re-flooded`
          : `${msg.id} duplicate from ${via} — already seen, not relayed`,
        {
        peerId: via,
        msgId: msg.id,
        msgType: msg.type,
        hop: msg.hopCount,
      });
      return;
    }
    markSeen(node, seenKey(msg), this.now);
    if (sender && sender.role === "SUPER") node.mprHeardSuper.add(msg.id);

    const trace = this.traces.get(msg.id);
    // roadmap Phase 4 hop transparency: record when the copy arrived, over what
    // link budget, and — below — what this node decided to do with it. Only
    // fresh copies are traced, so a flood cannot grow the array without bound;
    // duplicates and losses live in the capture log instead.
    let hopRecord: HopRecord | undefined;
    if (trace && !trace.path.includes(node.id)) {
      trace.path.push(node.id);
      hopRecord = {
        nodeId: node.id,
        atMs: this.now,
        via,
        rssi: sender ? rssiModel(node, sender, this.rf) : 0,
        hop: msg.hopCount,
        action: "received",
      };
      trace.hops.push(hopRecord);
    }

    if (msg.to === node.id) {
      if (msg.type === "ack") {
        const ackedId = msg.body.slice(4);
        if (this.pendingAcks.has(ackedId)) this.pendingAcks.delete(ackedId);
        this.acksReceived++;
        this.pushLog("ack", node.id, `${ackedId} acknowledged`, { msgId: ackedId, peerId: via });
      }
      // Set before recordDelivery copies the trace, so the delivered record
      // carries the final action rather than the provisional one.
      if (hopRecord) hopRecord.action = "delivered";
      const fresh = deliverToInbox(node, msg);
      if (fresh) this.recordDelivery(node, msg, trace);
      this.pushLog(
        "deliver",
        node.id,
        `${msg.id} delivered to ${node.name} via ${via} — ${msg.hopCount + 1} hop${msg.hopCount ? "s" : ""}, ${(this.now - msg.timestamp).toFixed(0)} ms`,
        { peerId: via, msgId: msg.id, msgType: msg.type, hop: msg.hopCount + 1 }
      );
      if (msg.type !== "ack" && msg.to !== "BROADCAST") this.sendAck(node, msg);
      return;
    }

    if (msg.to === "BROADCAST") {
      const fresh = deliverToInbox(node, msg);
      if (fresh) {
        this.broadcastReceipts++;
        this.recordDelivery(node, msg, trace);
        this.pushLog("deliver", node.id, `${msg.id} broadcast reached ${node.name} via ${via}`, {
          peerId: via,
          msgId: msg.id,
          msgType: msg.type,
          hop: msg.hopCount + 1,
        });
        const rec = this.sentRecords.find((s) => s.msgId === msg.id);
        if (rec) {
          rec.recipients++;
          rec.delivered = true;
        }
      }
    }

    if (msg.ttl <= 0) {
      if (hopRecord) hopRecord.action = "expired";
      this.pushLog("decision", node.id, `${msg.id} TTL exhausted at ${node.name} — not forwarded`, {
        msgId: msg.id,
        msgType: msg.type,
        hop: msg.hopCount,
      });
      return;
    }

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
      this.config.relayPolicy
    );
    if (hopRecord) {
      hopRecord.action = HOP_ACTION_BY_MODE[decision.mode];
      hopRecord.reason = decision.reason;
    }
    this.pushLog("decision", node.id, `${msg.id} at ${node.name}: ${decision.mode} — ${decision.reason}`, {
      msgId: msg.id,
      msgType: msg.type,
      hop: forwarded.hopCount,
    });
    this.applyDecision(node, forwarded, decision);
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
      hops: [],
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
      this.config.relayPolicy
    );
    this.applyDecision(node, ack, decision);
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
      hopTrace: trace ? trace.hops.slice() : [],
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

  /** skills/02: "SUPER opt-out respected". Re-elects immediately, so the
   *  opt-out takes effect now instead of at the next 30 s tick. */
  setSuperOptOut(id: NodeId, optedOut: boolean): void {
    const node = this.byId(id);
    if (!node) return;
    node.superOptOut = optedOut;
    if (node.isOnline) this.electOne(node);
    this.stats = this.computeStats();
    this.notify();
  }

  /** skills/02: "NORMAL never auto-promoted if battery saver on". */
  setBatterySaver(id: NodeId, on: boolean): void {
    const node = this.byId(id);
    if (!node) return;
    node.batterySaver = on;
    if (node.isOnline) this.electOne(node);
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

    // skills/07 telemetry, measured rather than read off the drain model so it
    // reflects the role mix, duty cycling and charging as they actually
    // happened during the window.
    const elapsedMs = Math.max(1, this.now - this.measureStartMs);
    const elapsedHours = elapsedMs / 3600000;
    const elapsedSec = elapsedMs / 1000;
    const drainPerHour = (role: "SUPER" | "NORMAL"): number => {
      const rates = online
        .filter((n) => n.role === role && !n.charging)
        .map((n) => ((n.batteryAtMeasure - n.battery) / elapsedHours) * 100)
        // A node that charged and later unplugged shows a net gain. That is not
        // a drain rate, so it drops out instead of pulling the mean down.
        .filter((v) => v > 0);
      return rates.length ? rates.reduce((a, b) => a + b, 0) / rates.length : 0;
    };
    const dutyNodes = online.filter((n) => n.role !== "SUPER");
    const awakeRatio = dutyNodes.length
      ? dutyNodes.filter((n) => this.isAwake(n)).length / dutyNodes.length
      : 1;

    // roadmap Phase 2 metrics dashboard: "latency by hop". Scoped like the
    // docs/04 §5 budget — first-attempt routed unicast only — so a retry (which
    // adds a whole ACK timeout) and a DTN bundle (which measures a meeting time,
    // not transport) cannot smear the distribution.
    const perHop = new Map<number, number[]>();
    for (const d of unicastDeliveries) {
      if (d.attempt !== 0 || d.dtn) continue;
      const xs = perHop.get(d.hops);
      if (xs) xs.push(d.latencyMs);
      else perHop.set(d.hops, [d.latencyMs]);
    }
    const latencyByHop: LatencyByHop[] = Array.from(perHop.entries())
      .sort((a, b) => a[0] - b[0])
      .map(([hops, xs]) => {
        const sorted = xs.slice().sort((a, b) => a - b);
        return {
          hops,
          count: sorted.length,
          avgMs: sorted.reduce((a, b) => a + b, 0) / sorted.length,
          p95Ms: percentile(sorted, 95),
        };
      });

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
      sosFloods: this.sosFloods,
      batteryPercentPerHourNormal: drainPerHour("NORMAL"),
      batteryPercentPerHourSuper: drainPerHour("SUPER"),
      scansPerSec: this.scanCount / elapsedSec,
      relaysPerSec: this.relayTx / elapsedSec,
      scansSkippedAsleep: this.scansSkippedAsleep,
      awakeRatio,
      electionEvents: this.roleEvents.length,
      latencyByHop,
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
