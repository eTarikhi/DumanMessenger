import {
  HISTORY_BUCKETS,
  GROUP_ADDRESS,
  GROUP_MIN_MEMBERS,
  GROUP_MAX_MEMBERS,
} from "./types";
import type {
  Group,
  HistoryEntry,
  TransportType,
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
  BLE_MAX_BYTES,
  MPR_WAIT_MS,
  createMessage,
  decideForward,
  deliverToInbox,
  enqueueOpp,
  isSeen,
  markSeen,
  pruneAcked,
  pruneOppQueue,
  pruneSeenCache,
  resolveMprWait,
  scanOppQueue,
  seenKey,
  selectTransport,
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

  /** How a group message travels: one scoped flood the whole network relays and
   *  only members accept, or one routed unicast per member. `docs/06` §14 measures
   *  the two against each other; the flood is the default because a group's members
   *  are typically spread across the world and the network does not know who they
   *  are. */
  groupMode: "scoped-flood" | "per-member-unicast";

  /** Link throughput, for the serialization time a large payload occupies the radio
   *  with. The 250× ratio is not a guess: docs/05 §3.2 puts Wi-Fi Direct at "250×
   *  faster than BLE" for images, so 80 kbit/s against 20 Mbit/s reproduces exactly
   *  that claim (docs/08 §1). */
  bleKbps: number;
  wifiDirectKbps: number;
  /** Chunk size for a large transfer (docs/05 §3.2: "64 KB slices"). */
  transferChunkBytes: number;
  /** Chunks in flight before waiting for an ACK ("sliding-window ACK"). */
  transferWindow: number;
  /** How long a transfer may make no progress before the sender re-sends the chunks
   *  the receiver is still missing. Without it, a chunk whose retries ran out parks in
   *  the OppQueue and the window never advances: the transfer hangs forever. That is
   *  what "resume on reconnect" (docs/05 §3.2) has to mean in practice (docs/08 §6). */
  transferStallMs: number;
  /** Opus framing for push-to-talk (docs/05 §3.3: 500 ms frames, 6-12 kbps). */
  voiceKbps: number;
  voiceFrameMs: number;
  /** Receiver buffer before playback can start (docs/05 §3.3: "jitter buffer 200 ms"). */
  jitterBufferMs: number;
  /** TTL for one voice chunk. skills/05 puts `VOICE_CHUNK` at `prio=high, ttl=3`:
   *  a frame that needs four hops is stale by the time it arrives, so it is not
   *  worth the radio time. */
  voiceTtl: number;
  /** skills/05: "Max 10 MB". A larger send is refused rather than attempted, because
   *  on this mesh it would occupy the radio for minutes (docs/08 §8). */
  maxTransferBytes: number;

  /** How often a group member offers its history digests to the co-members it can
   *  hear (roadmap Phase 1: "hash beacon anti-entropy"). 0 turns repair off, which
   *  leaves a member that missed a flood missing it forever. */
  historyBeaconMs: number;
  /** Entries in one anti-entropy reply. Bounded so that repairing a long absence
   *  cannot turn into one huge transmission; the next beacon picks up the rest. */
  historyReplyMax: number;

  /** skills/04: "DO prefer SUPER as bundle carrier (more storage/battery)". When a
   *  carrier has no route of its own, hand the bundle to the strongest SUPER in range
   *  instead of waiting for a route to appear. Bounded by the spray limit either way.
   *
   *  Implemented, measured, and **off by default**: once a carried bundle is parked
   *  instead of being deleted by flood suppression, the routing layer delivers it by
   *  itself, and biasing the spray towards SUPERs duplicates copies into the busiest
   *  nodes' queues — crowd delivery falls 94.7% to 91.2% over six seeds and parked
   *  bundles grow 39 to 63 per run (docs/06 §20.4). The intuition behind the rule is
   *  about who should *hold* a bundle, not about who should be handed extra copies. */
  dtnPreferSuper: boolean;

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
  /** First retry timer for one chunk of a transfer, before any ACK has come back to
   *  measure the path. Media cannot wait as long as text: 4 s is eight 500 ms voice
   *  frames, and one lost frame then leaves a four-second hole in the audio that a
   *  200 ms jitter buffer cannot cover (docs/08 §5). */
  mediaAckTimeoutMs: number;
  /** Grow that timer from the round trips the transfer's own ACKs report, instead of
   *  holding it fixed. Off by default: measured against a fixed 600 ms it wins for a
   *  voice note two hops away and loses for a file, where the window keeps the radio
   *  busy enough to inflate every round trip (docs/08 §7). */
  adaptiveMediaAck: boolean;
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


// --- group history anti-entropy (roadmap Phase 1: "CRDT for group/broadcast
// --- history (hash beacon anti-entropy)") -----------------------------------

/**
 * FNV-1a, 32-bit, over the characters of a message id.
 *
 * Not a cryptographic hash, deliberately: a digest here only has to tell two sets
 * apart, and the ids it covers are already visible to every relay on the path. Four
 * lines that behave identically in TypeScript and Dart, which is what the
 * cross-language golden vectors need.
 */
export function fnv1a32(text: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

/** Which of the [HISTORY_BUCKETS] a message id falls in. */
export function historyBucket(msgId: string): number {
  return fnv1a32(msgId) % HISTORY_BUCKETS;
}

/** Cap on the ids a request lists. Well above a bucket's share of any realistic
 *  group history (400 entries over 16 buckets is 25), so it bounds the packet without
 *  ever bounding the repair. */
export const HISTORY_REQUEST_MAX_IDS = 64;

/**
 * The digest a node advertises for one group: one XOR-folded hash per bucket, plus a
 * count.
 *
 * XOR over a *set* is order-independent, so two nodes holding the same entries
 * produce the same digest whatever order they arrived in. That is what makes the merge
 * a union rather than a negotiation, and what lets a beacon be lost, duplicated or
 * reordered without the protocol caring (the G-Set property `HistoryEntry` documents).
 *
 * Splitting into buckets is what keeps a repair proportional to the *difference*:
 * a node that missed two messages out of two hundred asks for one bucket, not for the
 * whole history.
 */
export function historyDigest(
  entries: Iterable<HistoryEntry>
): { count: number; buckets: number[] } {
  const buckets = new Array<number>(HISTORY_BUCKETS).fill(0);
  let count = 0;
  for (const e of entries) {
    const b = historyBucket(e.msgId);
    buckets[b] = (buckets[b] ^ fnv1a32(e.msgId)) >>> 0;
    count++;
  }
  return { count, buckets };
}

/** `HB|group|epoch|count|hexdigests` — what a beacon carries. */
export function encodeHistoryBeacon(
  groupId: string,
  epoch: number,
  digest: { count: number; buckets: number[] }
): string {
  return `HB|${groupId}|${epoch}|${digest.count}|${digest.buckets
    .map((b) => b.toString(16).padStart(8, "0"))
    .join(",")}`;
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
  groupMode: "scoped-flood",
  bleKbps: 80,
  wifiDirectKbps: 20000,
  transferChunkBytes: 65536,
  transferWindow: 4,
  transferStallMs: 3000,
  voiceKbps: 12,
  voiceFrameMs: 500,
  jitterBufferMs: 200,
  voiceTtl: 3,
  maxTransferBytes: 10 * 1048576,
  historyBeaconMs: 10000,
  historyReplyMax: 32,
  dtnPreferSuper: false,

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
  mediaAckTimeoutMs: 600,
  adaptiveMediaAck: false,
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
  /** Group messages handed to the radio: 1 per send in `scoped-flood`, one per
   *  member in `per-member-unicast`. */
  sentGroup: number;
  /** Member deliveries of group traffic. */
  groupReceipts: number;
  /** Member deliveries that should have happened: the denominator that makes
   *  `groupDeliveryRatio` comparable across the two modes. */
  groupExpected: number;
  groupDeliveryRatio: number;
  /** Copies a *member* could not decrypt because the key had rotated since. */
  groupEpochRejected: number;
  /** Large transfers started and finished, chunks put on air, and bytes delivered
   *  (docs/08). Chunks are kept out of `sentUnicast`/`deliveryRatio` on purpose:
   *  one 10 MB file is 160 of them. */
  transfersStarted: number;
  transfersCompleted: number;
  /** Windows that stopped moving and had to be kicked (docs/08 §6). */
  transferStalls: number;
  /** Anti-entropy: digest beacons sent, bucket requests sent, replies sent, entries
   *  recovered that way, entries dropped because a key rotation made them unreadable,
   *  and the payload bytes the whole exchange occupied (docs/06 §17). */
  historyBeacons: number;
  historyRequests: number;
  historyReplies: number;
  historyEntriesSynced: number;
  historyEpochDropped: number;
  historyBytes: number;
  /** DTN (skills/04): bundles dropped because their ACK was overheard, and bundles
   *  handed to a SUPER because the carrier had no route of its own. */
  bundlesPruned: number;
  dtnSuperCarries: number;
  sentChunks: number;
  /** Anti-entropy packets put on air: beacons, bucket requests and replies. */
  sentSync: number;
  bytesDelivered: number;

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

/**
 * One large transfer in flight: a file chopped into chunks, or a push-to-talk note
 * streamed as Opus frames (docs/05 §3.2-3.3).
 *
 * Chunks are ordinary unicasts, so they inherit everything the data plane already
 * does — ACKs, retransmission, and the OppQueue as a last resort, which is what
 * makes "resume on reconnect" (docs/05 §3.2) fall out instead of needing its own
 * mechanism.
 */
export interface Transfer {
  id: string;
  kind: "file" | "voice";
  from: NodeId;
  to: NodeId;
  totalBytes: number;
  chunkBytes: number;
  chunks: number;
  /** Chunks the receiver has, in arrival order-independent count. */
  received: number;
  /** Chunks that took at least one retransmission to arrive. */
  retransmitted: number;
  /** Chunk indices the receiver has, so a retry that arrives twice is not counted. */
  receivedChunks: Set<number>;
  /** Chunk indices the sender has actually put on air. A voice note is captured in
   *  real time, so frames that have not been recorded yet are missing without being
   *  lost — and re-sending them would be meaningless. */
  onAir: Set<number>;
  /** Next chunk index the sender may put on air (the sliding window's right edge). */
  nextToSend: number;
  window: number;
  /** Times the window stopped moving and missing chunks had to be re-sent. */
  stalls: number;
  /** Round trips this transfer's own ACKs have reported. Null until the first one:
   *  `mediaAckTimeoutMs` covers the cold start. `minRttMs` is the one the timer is
   *  built from, because the smoothed average measures the queue the transfer is
   *  creating for itself (docs/08 §7). */
  srttMs: number | null;
  rttVarMs: number;
  minRttMs: number | null;
  /** Simulation time the last chunk arrived: the stall watchdog's reference. */
  lastProgressAt: number;
  startedAt: number;
  /** When the receiver got chunk 0: streaming playback can begin here. */
  firstChunkAt: number | null;
  /** When the last chunk arrived. */
  completedAt: number | null;
  /** For a voice note: when capture ended, i.e. when the user let go of the button. */
  releasedAt: number | null;
  transport: TransportType;
  /** skills/05: "Send ... via best transport (WiFi Direct if GO connected, else
   *  chunked BLE 512B MTU)". A Wi-Fi Direct group owner that is already negotiated
   *  means the radio is available whatever the payload size says, so the caller can
   *  force it; null leaves the size-based choice in `selectTransport`. */
  forcedTransport: TransportType | null;
  state: "active" | "complete";
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
  /** Set on group traffic, so it can be accounted separately from 1:1. */
  groupId?: string;
  /** Set on one chunk of a large transfer. */
  transferId?: string;
  /** Its position in that transfer, so arrival gaps can be measured per frame. */
  chunkIndex?: number;
  /** Whether this copy needed a retransmission to arrive. */
  retransmitted?: boolean;
  /** The key epoch this copy was sent under. */
  groupEpoch?: number;
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
  /** Set on group traffic, so a UI can show one card per send even in
   *  `per-member-unicast` mode, where one user action is N radio messages. */
  groupId?: string;
  /** Set on one chunk of a large transfer, so a UI can show the file rather than
   *  160 empty messages. */
  transferId?: string;
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
    history: new Map(),
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
interface ChunkPayload {
  transferId: string;
  index: number;
}

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
  private pendingAcks = new Map<
    string,
    { msg: MeshMessage; from: NodeId; attempts: number; sentAt: number }
  >();
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
  private sentGroup = 0;
  private groupReceipts = 0;
  private groupExpected = 0;
  private groupEpochRejected = 0;
  private transfersStarted = 0;
  private transfersCompleted = 0;
  private transferStalls = 0;
  private historyBeacons = 0;
  private historyRequests = 0;
  private historyReplies = 0;
  private historyEntriesSynced = 0;
  private historyEpochDropped = 0;
  private historyBytes = 0;
  private bundlesPruned = 0;
  private dtnSuperCarries = 0;
  /** Nodes with a beacon chain running, so joining a second group does not start a
   *  second one (the beacon covers every group the node is in). */
  private historyBeaconArmed = new Set<NodeId>();
  private sentChunks = 0;
  private sentSync = 0;
  private bytesDelivered = 0;
  private transferSeq = 0;
  /** Live and finished large transfers, keyed by transfer id. */
  readonly transfers = new Map<string, Transfer>();
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
    this.sentGroup = 0;
    this.groupReceipts = 0;
    this.groupExpected = 0;
    this.groupEpochRejected = 0;
    this.transfers.clear();
    this.transferSeq = 0;
    this.transfersStarted = 0;
    this.transfersCompleted = 0;
    this.transferStalls = 0;
    this.historyBeacons = 0;
    this.historyRequests = 0;
    this.historyReplies = 0;
    this.historyEntriesSynced = 0;
    this.historyEpochDropped = 0;
    this.historyBytes = 0;
    this.bundlesPruned = 0;
    this.dtnSuperCarries = 0;
    this.sentChunks = 0;
    this.sentSync = 0;
    this.bytesDelivered = 0;
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
    // Groups belong to the world, not to the metrics window: rebuilding the mesh
    // invalidates every membership, so the registry goes with it.
    this.groups.clear();
    this.historyBeaconArmed.clear();
    this.groupSeq = 0;
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
      case "transferchunk": {
        const chunk = payload as ChunkPayload;
        const t = this.transfers.get(chunk.transferId);
        if (t && t.state === "active" && this.byId(nodeId)?.isOnline) this.sendChunk(t, chunk.index);
        break;
      }
      case "transferstall":
        this.onTransferStall(nodeId, (payload as ChunkPayload).transferId);
        break;
      case "historybeacon":
        this.onHistoryBeacon(nodeId);
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
      const scan = scanOppQueue(node, this.nodes, this.rf, this.now, {
        preferSuper: this.config.dtnPreferSuper,
      });
      this.dtnSuperCarries += scan.superCarries;
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
  /**
   * How long a payload occupies the radio on top of the calibrated hop latency.
   *
   * `hopLatencyBleMs` 120 already *includes* one GATT write of a full-sized packet, so
   * only the excess over that packet is charged. That leaves every latency measured so
   * far — and the golden vectors — exactly where they are, while making a 64 KB chunk
   * cost what a 64 KB chunk costs (docs/08 §2).
   */
  serializationMs(bytes: number, transport: TransportType): number {
    const excess = Math.max(0, bytes - BLE_MAX_BYTES);
    if (excess === 0) return 0;
    const kbps = transport === "wifiDirect" ? this.config.wifiDirectKbps : this.config.bleKbps;
    return (excess * 8) / kbps; // bits over kbit/s is milliseconds
  }

  /**
   * Send a large file: sliced into `transferChunkBytes` chunks and pushed through a
   * sliding window of unacknowledged chunks (docs/05 §3.2, "64 KB slices,
   * sliding-window ACK").
   *
   * Every chunk is an ordinary unicast, so it inherits ACKs, retransmission and the
   * OppQueue as a last resort — which is what makes "resume on reconnect" work without
   * any media-specific state machine. Returns null if the sender is offline.
   */
  sendFile(
    fromId: NodeId,
    toId: NodeId,
    totalBytes: number,
    opts?: { chunkBytes?: number; window?: number; transport?: TransportType }
  ): Transfer | null {
    const from = this.byId(fromId);
    if (!from || !from.isOnline || totalBytes <= 0) return null;
    if (totalBytes > this.config.maxTransferBytes) {
      // skills/05: "Max 10 MB". Refusing is the honest behaviour: docs/08 §8
      // measures what attempting it would cost the mesh.
      this.pushLog(
        "transfer",
        fromId,
        `refused ${(totalBytes / 1048576).toFixed(1)} MB to ${toId} — over the ` +
          `${(this.config.maxTransferBytes / 1048576).toFixed(0)} MB ceiling (skills/05)`,
        { msgType: "file" }
      );
      return null;
    }
    const chunkBytes = Math.max(64, opts?.chunkBytes ?? this.config.transferChunkBytes);
    const chunks = Math.max(1, Math.ceil(totalBytes / chunkBytes));
    const t = this.newTransfer(
      "file",
      fromId,
      toId,
      totalBytes,
      chunkBytes,
      chunks,
      opts?.window,
      opts?.transport
    );
    this.pushWindow(t);
    return t;
  }

  /**
   * Start a push-to-talk note. `seconds` is how long the button is held, and the note
   * is captured and streamed at the same time: frame i covers the capture window
   * `[i, i+1) × voiceFrameMs`, so it can only leave at the *end* of that window
   * (docs/05 §3.3, "500 ms frames at 6-12 kbps"). The last frame therefore departs at
   * the moment of release — the honest worst case, and the one the roadmap's
   * "<3 s 1-hop" budget has to cover.
   *
   * `stream: false` sends the finished note as one blob at release instead, which is
   * the alternative the streaming design is measured against in docs/08 §5.
   */
  sendVoice(
    fromId: NodeId,
    toId: NodeId,
    seconds: number,
    opts?: { stream?: boolean; transport?: TransportType }
  ): Transfer | null {
    const from = this.byId(fromId);
    if (!from || !from.isOnline || seconds <= 0) return null;
    const frameMs = this.config.voiceFrameMs;
    const frames = Math.max(1, Math.ceil((seconds * 1000) / frameMs));
    const frameBytes = Math.max(1, Math.ceil((frameMs * this.config.voiceKbps) / 8));
    const stream = opts?.stream ?? true;
    // Capture ends one `seconds` from now either way, and nothing can leave the
    // phone before it has been recorded.
    const releasedAt = this.now + seconds * 1000;
    const totalBytes = frames * frameBytes;

    if (!stream) {
      // One blob of the whole note, sent when the button is released.
      const t = this.newTransfer(
        "voice",
        fromId,
        toId,
        totalBytes,
        totalBytes,
        1,
        1,
        opts?.transport
      );
      t.releasedAt = releasedAt;
      this.queue.push(releasedAt, "transferchunk", fromId, { transferId: t.id, index: 0 });
      return t;
    }

    const t = this.newTransfer(
      "voice",
      fromId,
      toId,
      totalBytes,
      frameBytes,
      frames,
      1,
      opts?.transport
    );
    t.releasedAt = releasedAt;
    for (let i = 0; i < frames; i++) {
      const departsAt = this.now + Math.min((i + 1) * frameMs, seconds * 1000);
      this.queue.push(departsAt, "transferchunk", fromId, { transferId: t.id, index: i });
    }
    return t;
  }

  private newTransfer(
    kind: "file" | "voice",
    fromId: NodeId,
    toId: NodeId,
    totalBytes: number,
    chunkBytes: number,
    chunks: number,
    window?: number,
    forced?: TransportType
  ): Transfer {
    const id = `transfer-${this.transferSeq++}`;
    const t: Transfer = {
      id,
      kind,
      from: fromId,
      to: toId,
      totalBytes,
      chunkBytes,
      chunks,
      received: 0,
      retransmitted: 0,
      receivedChunks: new Set<number>(),
      onAir: new Set<number>(),
      nextToSend: 0,
      window: Math.max(1, window ?? this.config.transferWindow),
      stalls: 0,
      srttMs: null,
      rttVarMs: 0,
      minRttMs: null,
      lastProgressAt: this.now,
      startedAt: this.now,
      firstChunkAt: null,
      completedAt: null,
      releasedAt: null,
      transport: forced ?? selectTransport(chunkBytes),
      forcedTransport: forced ?? null,
      state: "active",
    };
    this.transfers.set(id, t);
    this.transfersStarted++;
    this.queueStallCheck(id, fromId);
    return t;
  }

  /** (Re)arm the stall watchdog. It stops by itself once the transfer completes. */
  private queueStallCheck(transferId: string, nodeId: NodeId): void {
    this.queue.push(this.now + this.config.transferStallMs, "transferstall", nodeId, { transferId });
  }

  /** Put chunks on air for as long as the sliding window has room. */
  private pushWindow(t: Transfer): void {
    while (t.nextToSend < t.chunks && t.nextToSend < t.received + t.window) {
      this.sendChunk(t, t.nextToSend++);
    }
  }

  private sendChunk(t: Transfer, index: number): void {
    const bytes = Math.min(t.chunkBytes, t.totalBytes - index * t.chunkBytes);
    if (bytes <= 0 || index >= t.chunks) return;
    t.onAir.add(index);
    // skills/05: a voice note goes out as VOICE_CHUNK packets, prio=high and ttl=3,
    // which `sendMessage` derives from the "voice" type.
    this.sendMessage(t.from, t.to, "", t.kind === "voice" ? "voice" : "file", undefined, {
      transferId: t.id,
      index,
      bytes,
      transport: t.forcedTransport,
    });
  }

  /**
   * The window has not moved for `transferStallMs`: re-send the chunks the receiver is
   * still missing.
   *
   * This is what makes a transfer survive the two things a mesh actually does to it — a
   * chunk whose retries ran out (it goes to the OppQueue and its logical id is never
   * seen again), and a link that came back after a node walked out of range. The
   * receiver dedupes by chunk index, so a re-send that was not needed costs radio time
   * and nothing else.
   */
  private onTransferStall(nodeId: NodeId, transferId: string): void {
    const t = this.transfers.get(transferId);
    if (!t || t.state !== "active") return;
    const node = this.byId(nodeId);
    // A transfer three hops away legitimately hears nothing for longer than the stall
    // threshold, so the threshold follows the retry timer it is backstopping.
    const stallMs = Math.max(
      this.config.transferStallMs,
      this.transferTimeoutMs(t) * (this.config.maxRetries + 1) * 1.25
    );
    if (node && node.isOnline && this.now - t.lastProgressAt >= stallMs) {
      // Only chunks that were put on air and never arrived. Frames still being
      // recorded are not missing, they are not due yet.
      const missing: number[] = [];
      for (const i of t.onAir) if (!t.receivedChunks.has(i)) missing.push(i);
      missing.sort((x, y) => x - y);
      if (missing.length > 0) {
        t.stalls++;
        this.transferStalls++;
        t.lastProgressAt = this.now;
        this.pushLog(
          "transfer",
          nodeId,
          `${t.id} stalled — nothing arrived for ${stallMs.toFixed(0)} ms, re-sending ` +
            `${Math.min(missing.length, t.window)} of ${missing.length} missing chunk${missing.length === 1 ? "" : "s"} (stall ${t.stalls})`,
          { msgType: "file" }
        );
        for (const i of missing.slice(0, t.window)) this.sendChunk(t, i);
      }
    }
    this.queueStallCheck(transferId, nodeId);
  }

  /**
   * The receiver got a chunk: slides the window on, and completes the transfer when
   * the last one lands. A duplicate (a retry that arrived after the original) is
   * ignored, exactly as the inbox ignores a duplicate message.
   */
  private onChunkArrived(msg: MeshMessage, node: MeshNode): void {
    const t = this.transfers.get(msg.transferId!);
    if (!t || t.to !== node.id || t.state !== "active") return;
    const index = msg.chunkIndex ?? 0;
    if (t.receivedChunks.has(index)) return;
    t.receivedChunks.add(index);
    t.received++;
    t.lastProgressAt = this.now;
    t.transport = msg.transport;
    if (msg.attempt > 0) t.retransmitted++;
    if (index === 0) t.firstChunkAt = this.now;

    if (t.received === t.chunks) {
      t.completedAt = this.now;
      t.state = "complete";
      this.transfersCompleted++;
      this.bytesDelivered += t.totalBytes;
      const kb = (t.totalBytes / 1024).toFixed(t.totalBytes < 1048576 ? 1 : 0);
      this.pushLog(
        "transfer",
        node.id,
        `${t.id} ${t.kind} ${t.totalBytes >= 1048576 ? `${(t.totalBytes / 1048576).toFixed(1)} MB` : `${kb} KB`} complete: ` +
          `${t.chunks} chunk${t.chunks === 1 ? "" : "s"} in ${(this.now - t.startedAt).toFixed(0)} ms` +
          (t.retransmitted ? `, ${t.retransmitted} retransmitted` : "") +
          ` over ${t.transport}`,
        { peerId: t.from, msgId: msg.id, msgType: msg.type }
      );
      return;
    }
    if (t.kind === "file") this.pushWindow(t);
  }

  sendMessage(
    fromId: NodeId,
    toId: NodeId | "BROADCAST",
    body: string,
    type: MsgType = "text",
    groupCtx?: { id: string; epoch: number },
    chunk?: { transferId: string; index: number; bytes: number; transport?: TransportType | null }
  ): MeshMessage | null {
    const from = this.byId(fromId);
    if (!from || !from.isOnline) return null;

    // A group id in the destination position means "send to this group"
    // (docs/04 §4, roadmap Phase 1 "group (3-10 members)"). Which radio pattern
    // that turns into is `groupMode`, and the two are measured against each other
    // in docs/06 §14 rather than assumed.
    const group = groupCtx ? undefined : this.groups.get(toId);
    if (group) {
      const targets = [...group.members].filter((id) => id !== fromId);
      if (targets.length === 0) return null;
      this.groupExpected += targets.length;
      const ctx = { id: group.id, epoch: group.keyEpoch };
      if (this.config.groupMode === "per-member-unicast") {
        // One routed message per member: the route table can aim each one, and each
        // costs an ACK and possibly a retry.
        let last: MeshMessage | null = null;
        for (const t of targets) {
          const m = this.sendMessage(fromId, t, body, type, ctx);
          if (m) last = m;
        }
        return last;
      }
      // One scoped flood: addressed to nobody in particular, relayed by the whole
      // network on the normal policy, accepted only by members holding the current
      // key epoch. The network never learns who the members are.
      return this.sendMessage(fromId, GROUP_ADDRESS, body, type, ctx);
    }

    // docs/05 §"Broadcast SOS | All transports, flood (TTL=5)". Reach comes from
    // repeating the flood, not from a longer TTL — see onSosRepeat.
    const ttl =
      type === "sos" ? this.config.sosTtl : type === "voice" ? this.config.voiceTtl : 5;
    const priority = type === "sos" || type === "voice" ? "high" : "normal";
    const msgType: MsgType = toId === "BROADCAST" && type === "text" ? "broadcast" : type;
    const msg = createMessage(this.nextMsgId(), this.now, fromId, toId, body, msgType, ttl, priority);
    if (groupCtx) {
      msg.groupId = groupCtx.id;
      msg.groupEpoch = groupCtx.epoch;
    }
    if (chunk) {
      // A chunk's size is the payload it carries, not the empty body it was built
      // from — and that size is what picks the transport and the air time.
      msg.sizeBytes = chunk.bytes;
      msg.transport = chunk.transport ?? selectTransport(chunk.bytes);
      msg.transferId = chunk.transferId;
      msg.chunkIndex = chunk.index;
    }
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
        groupId: msg.groupId,
        transferId: msg.transferId,
      });
      // Group traffic gets its own counters: folding it into `sentUnicast` would
      // let a 10-member group flatter `deliveryRatio`, and folding it into
      // `sentBroadcast` would deflate `broadcastReach`.
      // Anti-entropy is counted apart too: a digest beacon is not a message anybody
      // sent to anybody, and folding it into `sentUnicast` would make deliveryRatio a
      // statement about how often a group repaired itself.
      if (msgType === "sync") this.sentSync++;
      else if (chunk) this.sentChunks++;
      else if (groupCtx) this.sentGroup++;
      else if (toId === "BROADCAST") this.sentBroadcast++;
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

    // A scoped group flood is addressed to nobody, so no ACK can ever come back:
    // arming the retry timer here would burn two retransmissions and then push the
    // message into the OppQueue on every single group send.
    // Anti-entropy is not acknowledged either: it is periodic by construction, so a
    // lost beacon costs one interval of convergence rather than a retransmission, and
    // ACKing every digest would cost more than the repair it reports on.
    if (
      toId !== "BROADCAST" &&
      toId !== GROUP_ADDRESS &&
      msgType !== "ack" &&
      msgType !== "sync" &&
      this.config.maxRetries > 0
    ) {
      this.pendingAcks.set(msg.id, { msg, from: fromId, attempts: 0, sentAt: this.now });
      this.queue.push(this.now + this.ackTimeoutFor(msg), "acktimeout", fromId, msg.id);
    }

    if (groupCtx) this.recordHistory(from, groupCtx.id, msg, groupCtx.epoch);

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
      groupId: msg.groupId,
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
    this.queue.push(this.now + this.ackTimeoutFor(retry), "acktimeout", nodeId, msgId);
  }

  /** The ACK timeout that applies to this message: media retries far sooner than text,
   *  and by default on a timer measured from the path rather than a constant. */
  private ackTimeoutFor(msg: MeshMessage): number {
    if (!msg.transferId) return this.config.ackTimeoutMs;
    const t = this.transfers.get(msg.transferId);
    return t ? this.transferTimeoutMs(t) : this.config.mediaAckTimeoutMs;
  }

  /** The retry timer one transfer is using right now. */
  private transferTimeoutMs(t: Transfer): number {
    return this.config.adaptiveMediaAck ? this.mediaTimeoutMs(t) : this.config.mediaAckTimeoutMs;
  }

  /**
   * The retry timer for a transfer, from the round trips its own ACKs have reported.
   *
   * Twice the fastest round trip this transfer has seen, plus 200 ms of slack, clamped
   * to [300 ms, `ackTimeoutMs`]. Measured rather than fixed because the right value is a
   * property of the path and the path is not known in advance: a round trip is ~0.5 s at
   * one hop and ~1.5 s at three, so any constant is wrong for one of them.
   *
   * The *minimum* rather than RFC 6298's `srtt + 4·rttvar`, because with a window of
   * chunks in flight the smoothed average measures the queue the transfer is creating
   * for itself and drifts to the ceiling — measured in docs/08 §7.
   */
  mediaTimeoutMs(t: Transfer): number {
    if (t.minRttMs === null) return this.config.mediaAckTimeoutMs;
    return Math.min(this.config.ackTimeoutMs, Math.max(300, 2 * t.minRttMs + 200));
  }

  /** Fold one ACK's round trip into the transfer's estimate. */
  private observeAck(msg: MeshMessage, sentAt: number): void {
    if (!msg.transferId) return;
    const t = this.transfers.get(msg.transferId);
    if (!t) return;
    const rtt = this.now - sentAt;
    if (t.minRttMs === null || rtt < t.minRttMs) t.minRttMs = rtt;
    if (t.srttMs === null) {
      t.srttMs = rtt;
      t.rttVarMs = rtt / 2;
      return;
    }
    t.rttVarMs = 0.75 * t.rttVarMs + 0.25 * Math.abs(t.srttMs - rtt);
    t.srttMs = 0.875 * t.srttMs + 0.125 * rtt;
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
    const delay =
      base +
      this.serializationMs(msg.sizeBytes, msg.transport) +
      randRange(this.rng, this.config.jitterMinMs, this.config.jitterMaxMs);
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

    // skills/04: "On ackReceived from dest: remove + gossip ACK (so relays can prune)".
    // The ACK comes back along the reverse path, and the nodes on that path are the ones
    // that were carrying copies, so hearing one is enough to drop the bundle — no extra
    // traffic and no new packet type. Without it a delivered message holds a slot in
    // every carrier's queue for the full seven days, and the 500-message cap spends
    // itself on bundles that have already arrived.
    if (msg.type === "ack") {
      this.bundlesPruned += pruneAcked(node, msg.body.slice(4));
    }

    if (msg.to === node.id) {
      if (msg.type === "ack") {
        const ackedId = msg.body.slice(4);
        const pending = this.pendingAcks.get(ackedId);
        if (pending) {
          this.pendingAcks.delete(ackedId);
          this.observeAck(pending.msg, pending.sentAt);
        }
        this.acksReceived++;
        this.pushLog("ack", node.id, `${ackedId} acknowledged`, { msgId: ackedId, peerId: via });
      }
      // Set before recordDelivery copies the trace, so the delivered record
      // carries the final action rather than the provisional one.
      if (hopRecord) hopRecord.action = "delivered";
      if (msg.type === "sync") {
        // Control plane: it reached this node, which the hop trace should say, but it
        // is not a message for the user and not a delivery to count.
        this.onSyncMessage(node, msg);
        return;
      }
      const fresh = deliverToInbox(node, msg);
      if (fresh) {
        this.recordDelivery(node, msg, trace);
        if (msg.transferId) this.onChunkArrived(msg, node);
      }
      this.pushLog(
        "deliver",
        node.id,
        `${msg.id} delivered to ${node.name} via ${via} — ${msg.hopCount + 1} hop${msg.hopCount ? "s" : ""}, ${(this.now - msg.timestamp).toFixed(0)} ms`,
        { peerId: via, msgId: msg.id, msgType: msg.type, hop: msg.hopCount + 1 }
      );
      if (msg.type !== "ack" && msg.to !== "BROADCAST") {
        // A bundle that arrived by store-carry-forward is acknowledged to whoever
        // carried it in, not to the originator: the originator's retry timer expired
        // long ago, and the carriers are the nodes holding copies that can now be
        // pruned (skills/04: "remove + gossip ACK (so relays can prune)").
        this.sendAck(node, msg, msg.carried ? via : undefined);
      }
      return;
    }

    if (msg.to === GROUP_ADDRESS && msg.groupId) {
      const group = this.groups.get(msg.groupId);
      const isMember = group ? group.members.has(node.id) : false;
      if (group && isMember && group.keyEpoch === msg.groupEpoch) {
        const fresh = deliverToInbox(node, msg);
        if (fresh) {
          this.recordDelivery(node, msg, trace);
          this.recordHistory(node, group.id, msg, msg.groupEpoch ?? group.keyEpoch);
          this.pushLog(
            "deliver",
            node.id,
            `${msg.id} group "${group.name}" reached ${node.name} via ${via} (epoch ${msg.groupEpoch})`,
            { peerId: via, msgId: msg.id, msgType: msg.type, hop: msg.hopCount + 1 }
          );
        }
      } else if (group && isMember) {
        // A member holding an older epoch cannot decrypt this copy: the key rotated
        // when somebody left or joined (docs/04 §4, "groupKey rotated on member
        // leave"). It still relays — the bytes are not secret to the network, only
        // unreadable to this node.
        this.groupEpochRejected++;
        this.pushLog(
          "group",
          node.id,
          `${msg.id} group "${group.name}" at ${node.name}: sent under epoch ${msg.groupEpoch}, holds ${group.keyEpoch} — cannot decrypt, still relaying`,
          { msgId: msg.id, msgType: msg.type }
        );
      }
      // Non-members fall through silently: relaying traffic you cannot read is the
      // normal case in a scoped flood, and logging it would drown the capture.
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

  private sendAck(node: MeshNode, original: MeshMessage, ackTo?: NodeId): void {
    const target = ackTo ?? original.from;
    const ack = createMessage(
      this.nextMsgId(),
      this.now,
      node.id,
      target,
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
      to: target,
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
    // Counted here rather than at a delivery call site because group traffic
    // arrives by two different roads — a scoped flood addressed to GROUP_ADDRESS,
    // or a routed unicast per member — and a counter in only one of them silently
    // reports 0% for the other mode.
    if (msg.groupId) this.groupReceipts++;
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
      groupId: msg.groupId,
      groupEpoch: msg.groupEpoch,
      transferId: msg.transferId,
      chunkIndex: msg.chunkIndex,
      retransmitted: msg.attempt > 0,
      timestamp: this.now,
      attempt: msg.attempt,
      dtn: msg.carried,
    });
    if (this.deliveries.length > 5000) this.deliveries.shift();
    const rec = this.sentRecords.find((s) => s.msgId === msg.id);
    if (rec) rec.delivered = true;
  }

  // --- group channels (docs/04 §4, roadmap Phase 1 and Phase 4 "Group UX") ----

  /** Live group channels. Membership is simulator state, not wire state: the
   *  network relays a group flood without ever learning who is in it. */
  readonly groups = new Map<string, Group>();
  private groupSeq = 0;

  /**
   * Create a group. The 3-10 member bound is roadmap Phase 1's, and it is enforced
   * here rather than left to a UI: below 3 a group is a 1:1 chat with an audience,
   * and above 10 it is a broadcast wearing a member list — which matters because a
   * scoped flood costs the whole network relays no matter how few nodes accept it.
   */
  createGroup(name: string, memberIds: NodeId[], adminId?: NodeId): Group | null {
    const unique = [...new Set(memberIds)].filter((id) => this.byId(id));
    if (unique.length < GROUP_MIN_MEMBERS || unique.length > GROUP_MAX_MEMBERS) return null;
    const group: Group = {
      id: `grp-${++this.groupSeq}`,
      name,
      members: new Set(unique),
      adminId: adminId && unique.includes(adminId) ? adminId : unique[0],
      keyEpoch: 0,
      createdAt: this.now,
    };
    this.groups.set(group.id, group);
    for (const id of unique) this.armHistoryBeacon(id);
    this.pushLog("group", group.adminId, `group "${group.name}" created with ${unique.length} members (epoch 0)`);
    return group;
  }

  /**
   * Add a member. Rotates the key on the way in, for the mirror image of the reason
   * `removeFromGroup` rotates it: a joiner must not be able to read the history it
   * missed. docs/04 §4 names the leave case; the join case is the same argument.
   */
  inviteToGroup(groupId: string, nodeId: NodeId): boolean {
    const group = this.groups.get(groupId);
    if (!group || group.members.has(nodeId) || !this.byId(nodeId)) return false;
    if (group.members.size >= GROUP_MAX_MEMBERS) return false;
    group.members.add(nodeId);
    group.keyEpoch++;
    this.armHistoryBeacon(nodeId);
    this.pushLog(
      "group",
      nodeId,
      `${this.byId(nodeId)?.name} joined "${group.name}" — key rotated to epoch ${group.keyEpoch}`
    );
    return true;
  }

  /**
   * Remove a member and rotate the group key, which is what makes the departure
   * stick: the departed node keeps relaying group traffic (it is just bytes now)
   * but can no longer read any of it. Refuses to go below 3 members — at that point
   * the group is a 1:1 chat and should be one.
   */
  removeFromGroup(groupId: string, nodeId: NodeId): boolean {
    const group = this.groups.get(groupId);
    if (!group || !group.members.has(nodeId)) return false;
    if (group.members.size <= GROUP_MIN_MEMBERS) return false;
    group.members.delete(nodeId);
    group.keyEpoch++;
    this.pushLog(
      "group",
      nodeId,
      `${this.byId(nodeId)?.name} left "${group.name}" — key rotated to epoch ${group.keyEpoch}`
    );
    return true;
  }

  /** Manual rotation, admin only (roadmap Phase 4: "admin rotate key"). */
  rotateGroupKey(groupId: string, requestedBy: NodeId): boolean {
    const group = this.groups.get(groupId);
    if (!group || group.adminId !== requestedBy) return false;
    group.keyEpoch++;
    this.pushLog("group", requestedBy, `admin rotated "${group.name}" key to epoch ${group.keyEpoch}`);
    return true;
  }

  /** Groups a node belongs to, for the UI's destination picker. */
  groupsOf(nodeId: NodeId): Group[] {
    return [...this.groups.values()].filter((g) => g.members.has(nodeId));
  }

  // --- group history anti-entropy -------------------------------------------

  /**
   * Start a node's beacon chain. One chain covers every group the node is in, so
   * joining a second group does not start a second one.
   *
   * Nothing is scheduled for a node with no groups, which is why this whole feature
   * is inert on a run that never creates one — including the golden vectors.
   */
  private armHistoryBeacon(nodeId: NodeId): void {
    if (this.config.historyBeaconMs <= 0) return;
    if (this.historyBeaconArmed.has(nodeId)) return;
    this.historyBeaconArmed.add(nodeId);
    this.queue.push(this.now + this.config.historyBeaconMs, "historybeacon", nodeId);
  }

  /**
   * The entries a node can actually share for one group: the ones written under the
   * key epoch the group is on now.
   *
   * A rotation makes everything older unreadable to everybody (docs/06 §14), so
   * repairing it would move bytes nobody can decrypt. That has a consequence worth
   * stating plainly: in a group whose membership changes often, the repairable history
   * is only ever as old as the last change.
   */
  syncableHistory(node: MeshNode, group: Group): Map<string, HistoryEntry> {
    const all = node.history.get(group.id);
    const out = new Map<string, HistoryEntry>();
    if (!all) return out;
    for (const [id, entry] of all) if (entry.epoch === group.keyEpoch) out.set(id, entry);
    return out;
  }

  /** Add one entry to a node's history. A duplicate is a no-op: the merge is a union. */
  private recordHistory(node: MeshNode, groupId: string, msg: MeshMessage, epoch: number): void {
    this.putHistory(node, {
      msgId: msg.id,
      groupId,
      from: msg.from,
      at: msg.timestamp,
      body: msg.body,
      epoch,
    });
  }

  /** The union step of the G-Set: returns true if the entry was new to this node. */
  private putHistory(node: MeshNode, entry: HistoryEntry): boolean {
    let map = node.history.get(entry.groupId);
    if (!map) {
      map = new Map<string, HistoryEntry>();
      node.history.set(entry.groupId, map);
    }
    if (map.has(entry.msgId)) return false;
    map.set(entry.msgId, entry);
    return true;
  }

  /**
   * Offer this node's digests to every co-member it can currently hear.
   *
   * Beacons go only to peers, not across the mesh: anti-entropy repairs the last hop
   * of a loss (a node that was asleep, out of range, or switched off while a flood
   * went by), and a peer that is out of range will be a peer again later. The chain
   * stops by itself when a node leaves its last group.
   */
  private onHistoryBeacon(nodeId: NodeId): void {
    const node = this.byId(nodeId);
    this.historyBeaconArmed.delete(nodeId);
    if (!node || !node.isOnline || this.config.historyBeaconMs <= 0) return;
    const groups = this.groupsOf(nodeId);
    if (groups.length === 0) return;
    this.armHistoryBeacon(nodeId);

    for (const group of groups) {
      const mine = this.syncableHistory(node, group);
      const digest = historyDigest(mine.values());
      for (const peerId of node.peerIds) {
        if (!group.members.has(peerId)) continue;
        const body = encodeHistoryBeacon(group.id, group.keyEpoch, digest);
        if (this.sendMessage(nodeId, peerId, body, "sync")) {
          this.historyBeacons++;
          this.historyBytes += body.length;
        }
      }
    }
  }

  /**
   * One anti-entropy packet arrived: a beacon, a request for the buckets that differ,
   * or the entries that fill them.
   *
   * The three-step exchange is what keeps a repair proportional to the difference
   * rather than to the history — a beacon is ~170 characters whatever the group has
   * said, and a reply carries only the buckets the requester is missing.
   */
  private onSyncMessage(node: MeshNode, msg: MeshMessage): void {
    const parts = msg.body.split("|");
    // A message body may itself contain "|", so a reply's payload is everything after
    // the third field rather than the fourth field alone.
    const payload = parts.slice(3).join("|");
    const group = this.groups.get(parts[1]);
    if (!group || !group.members.has(node.id)) return;
    const epoch = Number(parts[2]);
    if (epoch !== group.keyEpoch) return; // stale round: the key has rotated since

    if (parts[0] === "HB") {
      if (parts.length < 5) return;
      const mine = this.syncableHistory(node, group);
      const digest = historyDigest(mine.values());
      const theirs = parts[4].split(",").map((h) => parseInt(h, 16));
      const differing: number[] = [];
      for (let i = 0; i < HISTORY_BUCKETS; i++) {
        if (theirs[i] !== digest.buckets[i]) differing.push(i);
      }
      if (differing.length === 0) return;
      // The request carries the ids this node already holds in those buckets. Without
      // them a *bounded* reply would offer the same head of the list every round and
      // convergence would stall at `historyReplyMax` entries — which is exactly what
      // the first version of this protocol did (docs/06 §17).
      const wanted = new Set(differing);
      const have = [...mine.values()]
        .filter((e) => wanted.has(historyBucket(e.msgId)))
        .map((e) => e.msgId)
        .sort()
        .slice(0, HISTORY_REQUEST_MAX_IDS);
      const body = `RQ|${group.id}|${epoch}|${differing.join(",")}|${have.join(",")}`;
      if (this.sendMessage(node.id, msg.from, body, "sync")) {
        this.historyRequests++;
        this.historyBytes += body.length;
        this.pushLog(
          "sync",
          node.id,
          `${group.name}: ${node.name} and ${this.byId(msg.from)?.name ?? msg.from} disagree on ` +
            `bucket${differing.length === 1 ? "" : "s"} ${differing.join(",")} (${digest.count} vs ` +
            `${Number(parts[3])} entries) — requesting`,
          { peerId: msg.from, msgId: msg.id, msgType: "sync" }
        );
      }
      return;
    }

    if (parts[0] === "RQ") {
      const wanted = new Set(parts[3].split(",").map((b) => Number(b)));
      const theyHave = new Set(parts.length > 4 && parts[4] ? parts[4].split(",") : []);
      const mine = this.syncableHistory(node, group);
      const out: HistoryEntry[] = [];
      for (const entry of mine.values()) {
        if (wanted.has(historyBucket(entry.msgId)) && !theyHave.has(entry.msgId)) out.push(entry);
      }
      out.sort((a, b) => (a.msgId < b.msgId ? -1 : a.msgId > b.msgId ? 1 : 0));
      const slice = out.slice(0, this.config.historyReplyMax);
      if (slice.length === 0) return;
      const body = `RS|${group.id}|${epoch}|${JSON.stringify(slice)}`;
      if (this.sendMessage(node.id, msg.from, body, "sync")) {
        this.historyReplies++;
        this.historyBytes += body.length;
        this.pushLog(
          "sync",
          node.id,
          `${group.name}: ${node.name} sent ${slice.length} of ${out.length} missing entries in ` +
            `bucket${wanted.size === 1 ? "" : "s"} ${[...wanted].join(",")} to ` +
            `${this.byId(msg.from)?.name ?? msg.from}`,
          { peerId: msg.from, msgId: msg.id, msgType: "sync" }
        );
      }
      return;
    }

    if (parts[0] === "RS") {
      let entries: HistoryEntry[];
      try {
        entries = JSON.parse(payload) as HistoryEntry[];
      } catch {
        return;
      }
      let added = 0;
      let dropped = 0;
      for (const entry of entries) {
        if (entry.epoch !== group.keyEpoch) {
          // Unreadable under the current key. Counted rather than silently dropped,
          // because it is the cost of rotating on every membership change.
          dropped++;
          continue;
        }
        if (this.putHistory(node, { ...entry, synced: true })) added++;
      }
      this.historyEntriesSynced += added;
      this.historyEpochDropped += dropped;
      if (added > 0) {
        this.pushLog(
          "sync",
          node.id,
          `${group.name}: ${node.name} recovered ${added} message${added === 1 ? "" : "s"} from ` +
            `${this.byId(msg.from)?.name ?? msg.from}${dropped > 0 ? ` (${dropped} unreadable under epoch ${group.keyEpoch})` : ""}`,
          { peerId: msg.from, msgId: msg.id, msgType: "sync" }
        );
      }
    }
  }

  /**
   * The repairable history one node holds for one group, oldest first. What a UI
   * renders when it wants to show a member the messages it missed and recovered;
   * entries carry `synced` so a recovered one can be marked as such.
   */
  groupHistoryOf(nodeId: NodeId, groupId: string): HistoryEntry[] {
    const node = this.byId(nodeId);
    const group = this.groups.get(groupId);
    if (!node || !group) return [];
    return [...this.syncableHistory(node, group).values()].sort((a, b) =>
      a.at === b.at ? (a.msgId < b.msgId ? -1 : 1) : a.at - b.at
    );
  }

  /** Whether every member of a group holds the same repairable history. */
  historyConverged(group: Group): boolean {
    const members = [...group.members].map((id) => this.byId(id)).filter((n) => n !== undefined);
    if (members.length === 0) return true;
    const reference = historyDigest(this.syncableHistory(members[0], group).values());
    return members.every((m) => {
      const d = historyDigest(this.syncableHistory(m, group).values());
      return d.count === reference.count && d.buckets.every((b, i) => b === reference.buckets[i]);
    });
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

    // Group traffic is neither: it has its own denominator (`groupExpected`), and
    // folding it in here would let a 10-member group flatter `deliveryRatio`.
    // Media chunks are excluded as well: a 10 MB file is 160 of them, and letting
    // them into the ratio would make delivery about the file rather than the mesh.
    // So is anti-entropy: a digest beacon is control traffic, not a message anybody
    // sent to anybody.
    const unicastDeliveries = this.deliveries.filter(
      (d) =>
        d.type !== "ack" &&
        d.type !== "broadcast" &&
        d.type !== "sync" &&
        !d.groupId &&
        !d.transferId
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
      sentGroup: this.sentGroup,
      groupReceipts: this.groupReceipts,
      groupExpected: this.groupExpected,
      groupDeliveryRatio:
        this.groupExpected > 0 ? this.groupReceipts / this.groupExpected : 0,
      groupEpochRejected: this.groupEpochRejected,
      transfersStarted: this.transfersStarted,
      transfersCompleted: this.transfersCompleted,
      transferStalls: this.transferStalls,
      historyBeacons: this.historyBeacons,
      historyRequests: this.historyRequests,
      historyReplies: this.historyReplies,
      historyEntriesSynced: this.historyEntriesSynced,
      historyEpochDropped: this.historyEpochDropped,
      historyBytes: this.historyBytes,
      bundlesPruned: this.bundlesPruned,
      dtnSuperCarries: this.dtnSuperCarries,
      sentChunks: this.sentChunks,
      sentSync: this.sentSync,
      bytesDelivered: this.bytesDelivered,
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
