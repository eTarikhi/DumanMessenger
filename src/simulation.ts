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
  ChannelAccess,
  ChannelPriority,
  ChannelCapture,
  ChannelBackoff,
  PeerNorm,
  RelayPolicy,
  Role,
} from "./types";
import type { ForwardDecision, ForwardMode, RateBucket } from "./routing";
import type { Rng } from "./rng";
import { chance, createRng, randInt, randRange } from "./rng";
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
  TQ_USABLE,
} from "./election";
import {
  BLE_MAX_BYTES,
  BROADCAST_PER_MINUTE_CAP,
  MPR_WAIT_MS,
  RELAY_PER_SOURCE_PER_MINUTE_CAP,
  admitByRate,
  countsAgainstRelayCap,
  isBlockableTraffic,
  createMessage,
  decideForward,
  deliverToInbox,
  enqueueOpp,
  isSeen,
  markSeen,
  ogmWireBytes,
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

/** One node's radio under `channelAccess: "halfDuplex"`: the instant it comes free
 *  again, and the bounded FIFO of packets waiting for it (docs/08 §12). */
/** WMM-like ranking for a radio that has to choose what to send next. An SOS and a
 *  push-to-talk frame have a deadline; an ACK is small and keeps somebody else's window
 *  moving; a 64 KB chunk has neither property and is the only thing here that can afford
 *  to wait. `ogm` never reaches a transmit queue — control beacons have their own path. */
const CHANNEL_CLASS: Record<MsgType, number> = {
  sos: 0,
  voice: 0,
  ack: 1,
  text: 2,
  broadcast: 2,
  file: 2,
  sync: 2,
  ogm: 2,
};

interface ChannelState {
  busyUntil: number;
  queue: Array<{ msg: MeshMessage; targetId: NodeId; queuedAt: number }>;
  /** Whether a `channel` drain event is already in the queue for this radio. Without
   *  it, a packet that arrives while the radio is busy but the queue was empty at the
   *  last drain has nothing to wake the radio up, and waits for the next transmission
   *  to be handed to it — which is how a mesh stalls (docs/08 §12.1). */
  drainScheduled: boolean;
  /** Contention window this radio currently draws from, in slots (`channelBackoff`). Starts
   *  at `channelCwMin`, doubles after a collision, resets after a clean transmission. */
  cw: number;
  /** Whether a slot count has already been drawn for the attempt now in progress, and how
   *  many slots of it are left to wait. Drawn once per attempt so a radio that is deferred
   *  again mid-backoff keeps the turn it already paid for. */
  backoffArmed: boolean;
  backoffSlots: number;
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
  /** docs/04 §5: *"Mitigate traffic analysis: random jitter 50-200 ms before forwarding,
   *  dummy beacons at low rate."* The jitter half ships unconditionally (`jitterMinMs` /
   *  `jitterMaxMs`); this is the dummy-beacon half, off by default.
   *
   *  A cover packet is one radio burst that carries nothing: it increments the node's
   *  `txCount`, which is what a passive observer counts, and it is logged at the `ogm`
   *  kind so it stays behind the same `captureOgm` opt-in as real beacons. It creates no
   *  routing state, delivers nothing, and is never acknowledged — a dummy that had to be
   *  ACKed would not be a dummy. What it models is **timing and count** cover only: this
   *  engine gives beacons no length, so a length-based observer is out of reach here and
   *  `docs/06` §23 says so rather than implying the mitigation is complete. */
  coverTraffic: boolean;
  /** Mean interval between a node's dummy beacons. "Low rate" is the document's word and
   *  not a number, so `docs/06` §23 sweeps it instead of picking one. */
  coverIntervalMs: number;
  /** How long a packet holds a radio — which is *not* the same question as how long it takes
   *  to arrive, and `docs/06` §24.3 measured what conflating them costs.
   *
   *  - `"hop-latency"` ships. Occupancy is the calibrated hop latency plus the serialization
   *    of whatever exceeds a full BLE packet, which is what `docs/08` §12's contention arms
   *    were measured under and what every published number in this repository assumes.
   *  - `"airtime"` charges only `bytes × 8 / kbps`, the rate the engine already has for
   *    serialization, applied to the whole packet instead of to its excess over 1 024 B.
   *    Physically that is how long a radio is busy; the hop latency is scheduling and
   *    propagation on top of it, during which a device may or may not be awake.
   *
   *  Delivery latency is **not** affected: `airTime` keeps its hop-latency base in both
   *  models, because that is what `docs/02` §6's budget measures. Only the busy-radio
   *  duration used by `csma`, the capture model and the wake-lock accounting changes. Under
   *  the shipped `free`/`none` baseline nothing consumes occupancy at all, so this knob
   *  moves the telemetry and nothing else — which is what makes it safe to add. */
  radioOccupancy: "hop-latency" | "airtime";
  /** How many bytes one *advertised* neighbour costs on air, read only under
   *  `radioOccupancy: "airtime"`.
   *
   *  32 ships, because that is what this engine actually puts in an OGM: the neighbour's
   *  X25519 public key. `docs/03` §4 says a real deployment advertises 2-byte aliases
   *  instead (~60 B for 30 neighbours), and the difference is not cosmetic — §24.6 derives a
   *  fully loaded beacon at 1 270 B on 32-byte ids, over the 1 024 B BLE ceiling, and at
   *  130 B on aliases. Since beacon *reception* is the dominant term in demanded radio
   *  time, the encoding is a bigger lever than the beacon interval, and setting this to 2
   *  measures that instead of asserting it. The originator's own id stays 32 B either way:
   *  an alias cannot identify a sender nobody has heard from yet. */
  ogmAliasBytes: number;
  /** How often to sample the connectivity of the radio graph, in ms. `0` disables it.
   *
   *  `docs/06` §24.10 measured why this belongs in the engine rather than in a probe: a
   *  60-node crowd splits and re-joins repeatedly inside a measurement window, so
   *  `broadcastReach` and `deliveryRatio` averaged over that window are unreadable without
   *  knowing how much of it the network was in one piece. The graph measured *after* the
   *  window cannot tell you — a partition that healed looks like a network that was never
   *  partitioned, which is exactly the mistake §24.9 made. Sampling consumes no RNG and
   *  schedules no events, so it cannot move a golden vector or a published number. */
  connectivitySampleMs: number;
  /** Whether a node beacons on the fixed interval `docs/03` §4 specifies, or on one derived
   *  from how many peers will hear it.
   *
   *  - `"fixed"` ships: every node beacons every `ogmIntervalMs`, which is what §4 says and
   *    what every published number assumes.
   *  - `"density"` holds the *receptions a node imposes on its neighbourhood* constant, by
   *    stretching the interval in proportion to its peer count. It ships off, and
   *    `docs/06` §24.11-§24.12 is why — which is not that it lost. Where the topology can be
   *    held equal it is cheaper and does not cost reach: with `enableMobility: false` in
   *    `festival_crowd` it takes 44 % off the demanded radio time and 44 % off the beacons, and
   *    is equal or better on reach in seven of eight seeds. Delivery is *not* a win — better on
   *    four seeds, worse on three, level on one, and the +2.5-point mean is mostly one seed.
   *    Where the topology cannot be held equal it
   *    loses or cannot be read — `sparse_village` pays 3.11× the airtime for +1.6 points and
   *    `campus_quad` 1.20× for −0.7, both comparable, while the mobile crowd's two arms land
   *    in different topologies (mean largest component 85 % against 94 %) so that pair means
   *    nothing, because §24.10 shows reach tracks the topology rather than the interval. It
   *    ships off because the shipped condition is the mobile one: turning it on would change
   *    `docs/03` §4's 2 s on evidence from a network that is partitioned half the time.
   *
   *  The rule is anchored so that a node with `ogmDensityReferencePeers` peers beacons at
   *  exactly `ogmIntervalMs` — the specified 2 s is not replaced, it becomes what the
   *  reference density does — and clamped to `[ogmIntervalMs / 4, NEIGHBOR_SCORE_TTL_MS / 2]`,
   *  the upper bound being two chances per soft-state TTL so one lost beacon cannot expire a
   *  neighbour that is still there. The lower bound is what makes it expensive in a sparse
   *  world: a node with three peers beacons every 500 ms, four times the specified rate, to
   *  hold a reception load nobody was struggling with. */
  ogmIntervalMode: "fixed" | "density";
  /** The peer count at which `"density"` reproduces `ogmIntervalMs` exactly. 10 is the median
   *  peer count `campus_quad` produces, so the reference world is the one §4's 2 s was written
   *  against and the crowd stretches from there. */
  ogmDensityReferencePeers: number;
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

  /** How much of a radio a device has. `free` (default) is an infinitely wide
   *  radio; `halfDuplex` gives it one transmitter that does one thing at a time,
   *  which is the mechanism that lets media actually compete with text
   *  (docs/08 §12). */
  channelAccess: ChannelAccess;
  /** How many packets a node's transmitter will hold while it is busy, under
   *  `channelAccess: "halfDuplex"`. Bounded on purpose: an unbounded queue lets the
   *  radio commit air time arbitrarily far into the future, and the mesh then spends
   *  its whole run waiting for a horizon that keeps moving (docs/08 §12.1). */
  channelQueueDepth: number;
  /** Which queued packet a busy radio takes next. `"fifo"` ships; `"ackFirst"` promotes
   *  acknowledgements only; `"class"` also promotes deadline-driven traffic ahead of bulk
   *  chunks. Only consulted when `channelAccess` makes packets wait at all
   *  (docs/08 §12.8). */
  channelPriority: ChannelPriority;

  /** Share of the top-20% SUPER cap reserved for community relays — plugged, stationary
   *  nodes such as a café's tablet (roadmap Phase 5). 0 disables it, which is what ships:
   *  with no reservation a tablet joins an already-full elected set and everybody else's
   *  transmissions rise, and the reservation is the change that turns it into a quota
   *  rather than a device (docs/06 §19.2). */
  communityRelayQuota: number;

  /** Whether the coverage score normalises peer count against a fixed 50 (ships) or
   *  against the largest peer count this node has heard (docs/06 §18.2). */
  peerNorm: PeerNorm;

  /** What a receiver does when two packets arrive at once. `"none"` ships: a busy receiver
   *  takes everything, which is the second half of why this model has no contention.
   *  `"first"` loses the later packet, and loses any packet that arrives while its receiver
   *  is itself transmitting (docs/08 §12.9). */
  channelCapture: ChannelCapture;
  /** How much stronger a newcomer has to be to take a busy receiver over, in dB. Only
   *  consulted under `channelCapture: "strongest"`. Six dB is the capture ratio usually
   *  quoted for an angle-modulated receiver, and 0 dB reduces the model to "loudest wins
   *  regardless of margin" while a large value reduces it to `first`. */
  channelCaptureRatioDb: number;

  /** Whether a node that has been waiting for the medium waits a *random* number of slots
   *  before taking it, and how wide the window it draws from is. Carrier sense alone wakes
   *  every waiting node at the same instant the medium clears, so they transmit together;
   *  the random wait is what disperses them, and doubling the window after a collision is
   *  what stops two nodes that keep meeting from keeping meeting (docs/08 §12.13). Only
   *  consulted under `channelAccess: "csma"`. */
  channelBackoff: ChannelBackoff;
  /** Contention window after a clean transmission, in slots. */
  channelCwMin: number;
  /** Contention window ceiling after repeated collisions, in slots. */
  channelCwMax: number;
  /** How long one backoff slot lasts. 802.11's is 9 µs at 2.4 GHz; a BLE mesh has no such
   *  constant, so this is a knob rather than a calibration. */
  channelSlotMs: number;

  /** Whether a transfer stops pumping chunks when the sender's radio is full. A real socket
   *  blocks; an engine that keeps handing packets to a saturated radio converts somebody
   *  else's queue slots into drops, which is the mechanism docs/08 §12.10 could not answer
   *  without. Off by default, and inert under `channelAccess: "free"` where nothing queues. */
  mediaBackpressure: boolean;

  /** Whether `docs/04` §6's two abuse limits are enforced. Off by default, so a
   *  shipped run allocates no buckets and no golden vector moves. */
  rateLimits: boolean;
  /** docs/04 §6: "Max 5 broadcasts / minute per node; SUPERs drop excess." */
  broadcastPerMinuteCap: number;
  /** docs/04 §6: "Cap relay to 30 msgs/min per source; ignore floods." Control-plane
   *  traffic is exempt — see `countsAgainstRelayCap`, and the 2 s OGM beacon that
   *  makes the number as written unusable. */
  relayPerSourcePerMinuteCap: number;
  /** Who enforces the broadcast cap.
   *
   *  `"super"` is what `docs/04` §6 says — "SUPERs drop excess" — and it is the
   *  default. It bounds how *far* a flood travels, not whether the flooder's own
   *  neighbours see it: a NORMAL node neither relays far nor filters, so one hop of
   *  abuse still lands in full, and one hop is the whole attack for the neighbour
   *  spam §6 is about. `"all"` is the reading that closes that, and it is a knob
   *  rather than a replacement because §6 does not contain the rule — the two are
   *  measured against each other in `docs/06` §21.5 instead of one being asserted
   *  better than the other. */
  broadcastCapScope: "super" | "all";
  /** How far a local block reaches (`docs/04` §6: *"Block/mute peer locally (ignore msgs
   *  from pubKey)"*).
   *
   *  `"delivery"` is the literal reading and the default: the blocking node ignores the
   *  message, and the mesh still carries it for everyone else, so blocking can never cost
   *  a third party a delivery. `"relay"` also refuses to forward, which is what §6's
   *  battery-drain bullet means by *"ignore floods"* — the blocker stops paying airtime
   *  and battery for someone it blocked — at the cost of putting a hole in that source's
   *  routes wherever the blocker was a relay. Both are measured in `docs/06` §22 rather
   *  than one being asserted better. */
  blockScope: "delivery" | "relay";

  /** When two relays cover the same neighbours, pick the plugged one: a community relay's
   *  transmission costs nobody's battery and its position does not change. Off by default,
   *  and measured rather than assumed — see docs/06 §19.5. */
  communityRelayPreference: boolean;

  /** Hand a parked bundle to a plugged, stationary carrier instead of a SUPER when the
   *  carrier has no route of its own (skills/04's "prefer SUPER as bundle carrier", read
   *  for the community-relay programme). Off by default; docs/06 §19.5 measures it. */
  dtnPreferCommunity: boolean;

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
  coverTraffic: false,
  coverIntervalMs: 30_000,
  radioOccupancy: "hop-latency",
  ogmAliasBytes: 32,
  connectivitySampleMs: 5_000,
  ogmIntervalMode: "fixed",
  ogmDensityReferencePeers: 10,
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
  channelAccess: "free",
  channelQueueDepth: 8,
  channelPriority: "fifo",
  communityRelayQuota: 0,
  peerNorm: "fixed",
  channelCapture: "none",
  channelCaptureRatioDb: 6,
  channelBackoff: "none",
  channelCwMin: 4,
  channelCwMax: 64,
  channelSlotMs: 1,
  mediaBackpressure: false,
  rateLimits: false,
  broadcastPerMinuteCap: BROADCAST_PER_MINUTE_CAP,
  relayPerSourcePerMinuteCap: RELAY_PER_SOURCE_PER_MINUTE_CAP,
  broadcastCapScope: "super",
  blockScope: "delivery",
  communityRelayPreference: false,
  dtnPreferCommunity: false,

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
  /** Bundles handed to a community relay as carrier (`dtnPreferCommunity`). */
  dtnCommunityCarries: number;
  sentChunks: number;
  /** Channel access (docs/08 §12): transmissions that had to wait for a radio to
   *  come free, and how long they waited in total. Both stay 0 under the default
   *  `channelAccess: "free"`, where nothing is ever occupied. */
  channelDeferrals: number;
  channelDeferMs: number;
  /** Packets a busy transmitter could not hold: the queue was full, so they were
   *  dropped at the radio rather than lost on a link. */
  channelDrops: number;
  /** Where those drops happen, which is the question docs/08 §12.12 answered by argument and
   *  §12.13 needs answered by measurement. `channelDropsRelayed` counts the packets shed by a
   *  node forwarding somebody else's message (`hopCount > 0`); the difference is shed by the
   *  node that originated it. `channelDropsMedia` counts the shed packets that were file or
   *  voice chunks, i.e. the ones a transfer window is responsible for. */
  channelDropsRelayed: number;
  channelDropsMedia: number;
  /** Of the packets shed by a relay, how many had a peer in range that was at least as close
   *  to the destination as the next hop that was chosen — i.e. how many could have gone round
   *  the congestion instead of into it. This is the number that decides whether congestion-aware
   *  forwarding is a mechanism this topology can offer at all, and it is measured rather than
   *  assumed because docs/08 §12.12's argument for hop-by-hop flow control depends on it. */
  channelDropsWithAlternative: number;
  /** Packets lost because the receiver was locked onto a packet that arrived first
   *  (`channelCapture: "first"`, docs/08 §12.9). */
  channelCaptured: number;
  /** Times a stronger newcomer took a busy receiver over from the packet it was holding,
   *  under `channelCapture: "strongest"`. Each one is also a collision loss — of the
   *  incumbent — so it is counted in `channelCaptured` as well. This is the count that says
   *  how much of `first`'s pessimism the capture effect actually buys back. */
  channelCaptureEffects: number;
  /** Packets lost because the receiver was itself transmitting: a half-duplex radio cannot
   *  hear over its own transmitter. */
  channelDeafRx: number;
  /** Contention-window draws: how often a node found the medium free and still had to wait
   *  a random number of slots for it (`channelBackoff`, docs/08 §12.13). */
  channelBackoffs: number;
  /** Times a transfer was refused air by its own radio and had to wait for a slot to free
   *  (`mediaBackpressure`, docs/08 §12.12). This is backpressure working, not a failure. */
  transferBlocks: number;
  /** Broadcasts a SUPER dropped because the source exceeded docs/04 §6's 5/min. */
  rateBroadcastDrops: number;
  /** Relays refused because the source exceeded docs/04 §6's 30/min. */
  rateRelayDrops: number;
  /** Messages a node ignored because it had blocked the sender locally (docs/04 §6:
   *  "Block/mute peer locally"). Counted per receiving node, like `rateBroadcastDrops`,
   *  so one broadcast heard by four nodes that all blocked the sender is four. */
  blockedDrops: number;
  /** Route entries dropped because no beacon refreshed them inside
   *  `NEIGHBOR_SCORE_TTL_MS` — the route table's churn.
   *
   *  A neighbour that expires and is re-learned a moment later costs two table updates, and
   *  in between, anything that needed it is forwarded by a node that no longer knows where it
   *  goes. `docs/06` §24.7 uses this to test why a 12 s beacon interval delivered worse than
   *  both 5 s and 25 s in a 60-node crowd: the flap hypothesis predicts the middle interval
   *  is the one that churns, and before this counter existed there was no way to ask. */
  routeExpiries: number;
  /** How many times the radio graph was sampled inside the window, at
   *  `connectivitySampleMs`. Zero disables the metric, not the network. */
  connectivitySamples: number;
  /** Fraction of those samples at which every node could reach every other. **Read this
   *  beside `broadcastReach` and `deliveryRatio` in any mobile scenario**: `docs/06` §24.10
   *  shows `festival_crowd` reaches 98 % when it stays connected and 54-79 % when it does
   *  not, and the two look like one bimodal metric unless this column is beside them. */
  connectedSampleShare: number;
  /** Mean share of the network inside the largest component across those samples. A
   *  broadcast cannot do better than this, so a reach near it is a topology result and a
   *  reach well below it is a routing one. */
  meanLargestComponent: number;
  /** Anti-entropy packets put on air: beacons, bucket requests and replies. */
  sentSync: number;
  /** Dummy beacons put on air by `coverTraffic` (docs/04 §5). Zero unless it is on, which
   *  is what makes the feature inert: a shipped run reports 0 and behaves identically.
   *  Not included in `controlOverhead`, which counts the OGMs the routing protocol needs;
   *  cover traffic is optional and its whole cost belongs in this column. */
  coverTx: number;
  bytesDelivered: number;

  /** skills/07 telemetry: "Battery %/h per role, scans/sec, relays/sec".
   *  Measured from the battery snapshot taken when metrics were cleared, over
   *  nodes that are online, in that role and not charging. */
  batteryPercentPerHourNormal: number;
  batteryPercentPerHourSuper: number;
  scansPerSec: number;
  relaysPerSec: number;
  /** skills/07 telemetry, fourth item: "wake-locks".
   *
   *  A wake lock is what an Android device holds while its CPU must stay awake, and on a
   *  messenger whose radio is the reason the device is awake, radio activity is the whole
   *  of it. Counted here as one acquisition per transmission and per reception, held for
   *  the duration that packet physically occupies the radio — `occupied` on the way out
   *  and `airTime` on the way in, both of which the engine already computes for the
   *  receiver model, so this is accounting rather than a new radio model and it works
   *  under the shipped `channelAccess: "free"` baseline where `txUntil`/`rxUntil` are not
   *  maintained at all.
   *
   *  Scan windows are deliberately not counted: `awakeRatio` and `scansSkippedAsleep`
   *  already report the duty cycle's share, and folding them in here would double-count a
   *  reception that happens inside a scan window. What this measures is the cost of
   *  traffic, which is the part an abuser controls.
   *
   *  A beacon is charged once to its sender however many peers hear it — the per-peer loop
   *  in `beacon()` exists to give each link its own loss draw, not because the radio
   *  transmits once per neighbour — and once to each peer that actually hears it, because
   *  each of those radios really did wake. Charging the sender per peer inflated an idle
   *  node's share past 100 % of the clock, which is how that was caught.
   *
   *  Under `radioOccupancy: "airtime"` the duration comes from `ogmWireBytes`, derived from
   *  the fields an OGM actually carries, so a beacon advertising 30 neighbours and 8 routes
   *  costs what that payload costs and one advertising 3 neighbours costs far less. */
  wakeLocks: number;
  /** Total milliseconds those locks were held, network-wide, over the measured window. */
  wakeLockMs: number;
  /** Each role's share of the radio time the network demanded, in percent. The two sum to
   *  100. This is a *split between roles* and deliberately not a share of wall clock: see
   *  `radioDemandRatio` for why the absolute figure cannot be read as one. Charging nodes
   *  are included, unlike the battery rates above — being plugged in does not keep a CPU
   *  asleep. */
  wakeLockShareNormal: number;
  wakeLockShareSuper: number;
  /** Total demanded radio time divided by the radio time that exists (`nodes × window`).
   *
   *  Above 1 the model is asking for more airtime than there is, and `docs/06` §24 measures
   *  it at roughly **3.9** on `campus_quad` at 20 nodes under every channel model — because
   *  a beacon is charged one `hopLatencyBleMs` (120 ms, calibrated to include a GATT write)
   *  at every one of the ten peers that hear it, and reception dominates the total. Under
   *  `channelAccess: "free"` nothing notices, since `free` enforces no exclusivity; under
   *  `half-duplex`/`csma` the transmit queue absorbs it as deferrals. Read every airtime
   *  figure in this repository with that in mind: transmission *counts* are exact, and
   *  durations are the model's, not a device's. */
  radioDemandRatio: number;
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
  /** Which *transmission* this is, not which message. A message can be on air several times
   *  over — a retry, or two relays racing with the same copy — and `channelCapture:
   *  "strongest"` has to be able to say "this one was taken over" without condemning every
   *  later attempt at the same message. Only assigned under `"strongest"`; undefined
   *  otherwise, so the other two modes never touch it. */
  seq?: number;
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
    {
      msg: MeshMessage;
      from: NodeId;
      attempts: number;
      sentAt: number;
      /** When the originator's own copy of this message last went on air. Only maintained
       *  under a queued radio, where handing a packet over and transmitting it are different
       *  instants and a retry timer that cannot tell them apart multiplies load
       *  (docs/08 §12.11). */
      onAirAt?: number;
    }
  >();
  private listeners = new Set<() => void>();

  // counters
  private relayTx = 0;
  private channelDeferrals = 0;
  private channelDeferMs = 0;
  private channelDrops = 0;
  private channelDropsRelayed = 0;
  private channelDropsMedia = 0;
  private channelDropsWithAlternative = 0;
  private channelCaptured = 0;
  private channelCaptureEffects = 0;
  private channelDeafRx = 0;
  /** Per-transmission sequence, for `channelCapture: "strongest"` only. Not a random draw,
   *  so it cannot move a golden vector. */
  private txSeq = 0;
  private rxRssi = new Map<NodeId, number>();
  private rxSeq = new Map<NodeId, number>();
  private superseded = new Set<number>();
  private channelBackoffs = 0;
  private transferBlocks = 0;
  private rateBroadcastDrops = 0;
  private blockedDrops = 0;
  private rateRelayDrops = 0;
  /** Token buckets for docs/04 §6's two caps, keyed `"enforcer|source"`. Kept here
   *  rather than on `MeshNode` so that adding the feature adds no field to the
   *  cross-language node contract — a node's identity, draw order and golden-vector
   *  surface are untouched, and the state is per enforcing pair anyway. */
  private rateBroadcasts = new Map<string, RateBucket>();
  private rateRelays = new Map<string, RateBucket>();
  /** docs/04 §6's local blocklist, keyed blocker → blocked peers. On the simulation
   *  rather than on `MeshNode` for the same reason the rate buckets are: a node-contract
   *  field would move the golden vectors, and this is inert while empty, so a shipped run
   *  behaves identically whether or not the feature exists. */
  private blocked = new Map<NodeId, Set<NodeId>>();
  /** skills/07's fourth telemetry item, per node: acquisitions and milliseconds held. On
   *  the simulation rather than on `MeshNode` for the same reason as everything above it —
   *  no field is added to the cross-language node contract, so no golden vector moves. */
  private wakeLocksByNode = new Map<NodeId, number>();
  private wakeLockMsByNode = new Map<NodeId, number>();
  /**
   * Block a peer locally, as `docs/04` §6 specifies: no moderation server exists, so the
   * list never leaves the device and never affects anyone else's view of the network.
   * Returns whether the list changed.
   *
   * Keyed on the sender's node id, which is the mesh's identity: `docs/07` §4 derives
   * `destHint8 = SHA-256(pubKey)[0:8]`, and a node id carries that hint, so blocking a
   * pubKey and blocking a node id are the same act on air.
   */
  blockPeer(blockerId: NodeId, peerId: NodeId): boolean {
    if (blockerId === peerId) return false; // a node cannot block itself
    const list = this.blocked.get(blockerId);
    if (list) {
      if (list.has(peerId)) return false;
      list.add(peerId);
      return true;
    }
    this.blocked.set(blockerId, new Set([peerId]));
    return true;
  }

  /** Undo a block. Returns whether the list changed. */
  unblockPeer(blockerId: NodeId, peerId: NodeId): boolean {
    const list = this.blocked.get(blockerId);
    if (!list || !list.has(peerId)) return false;
    list.delete(peerId);
    if (list.size === 0) this.blocked.delete(blockerId);
    return true;
  }

  /** Whether `blockerId` has blocked `peerId`. */
  isBlocked(blockerId: NodeId, peerId: NodeId): boolean {
    return this.blocked.get(blockerId)?.has(peerId) === true;
  }

  /** The peers a node has blocked, sorted — the same contract as `peerIds`. */
  blockedPeers(blockerId: NodeId): NodeId[] {
    return [...(this.blocked.get(blockerId) ?? [])].sort();
  }

  /**
   * How long `bytes` take to push over `transport` at the modelled bit rate — the whole
   * packet, unlike `serializationMs`, which charges only the excess over a full BLE packet
   * because the calibrated hop latency already includes one.
   */
  airtimeMs(bytes: number, transport: TransportType): number {
    const kbps = transport === "wifiDirect" ? this.config.wifiDirectKbps : this.config.bleKbps;
    return (Math.max(0, bytes) * 8) / kbps; // bits over kbit/s is milliseconds
  }

  /**
   * How long a packet holds a radio, under `radioOccupancy`.
   *
   * The `"hop-latency"` branch is the expression `onAir` used before this method existed,
   * byte for byte, so the default model is unchanged and the golden vectors do not move.
   */
  occupancyMs(bytes: number, transport: TransportType): number {
    if (this.config.radioOccupancy === "airtime") return this.airtimeMs(bytes, transport);
    return (
      (transport === "wifiDirect"
        ? this.config.hopLatencyWifiMs
        : this.config.hopLatencyBleMs) + this.serializationMs(bytes, transport)
    );
  }

  /**
   * What one beacon costs in wake-lock time.
   *
   * Beacons ride `beacon()` rather than `onAir()`, so they have no packet and no size in
   * this engine — the same limitation `docs/06` §23.2 names for cover traffic — and are
   * accounted as one BLE hop with no payload term. That is a floor, not an estimate: a real
   * OGM carries an originator id, a sequence number, a score and a neighbour list, so the
   * true figure is this plus a serialization term. It is not zero, and it cannot be
   * ignored, because on an idle network beaconing is the *only* radio activity there is —
   * one acquisition every 2 s per node, which is exactly what `skills/07`'s duty-cycle
   * question is about.
   */
  private beaconWakeMs(ogm: OGM): number {
    if (this.config.radioOccupancy === "airtime") {
      // The size the beacon actually carries: its MPR neighbour set and its route
      // advertisements are the payload, and both are bounded by the advertise limits
      // `ogmWireBytes` was derived from.
      return this.airtimeMs(
        ogmWireBytes(
          ogm.neighborIds.length,
          Object.keys(ogm.bestHopTo).length,
          this.config.ogmAliasBytes
        ),
        "ble"
      );
    }
    return this.config.hopLatencyBleMs;
  }

  /** One wake-lock acquisition of `ms` milliseconds by `nodeId` (skills/07 telemetry). */
  private holdWakeLock(nodeId: NodeId, ms: number): void {
    this.wakeLocksByNode.set(nodeId, (this.wakeLocksByNode.get(nodeId) ?? 0) + 1);
    this.wakeLockMsByNode.set(nodeId, (this.wakeLockMsByNode.get(nodeId) ?? 0) + ms);
  }

  /** Wake locks acquired by one node since the metrics were cleared. */
  wakeLocksFor(nodeId: NodeId): number {
    return this.wakeLocksByNode.get(nodeId) ?? 0;
  }

  /** Milliseconds one node has spent holding a wake lock since the metrics were cleared. */
  wakeLockMsFor(nodeId: NodeId): number {
    return this.wakeLockMsByNode.get(nodeId) ?? 0;
  }

  /**
   * Component sizes of the radio graph right now — who can hear whom — largest first.
   *
   * A node is in a component with the peers inside RF range of it, which is the graph a
   * broadcast has to cross. `docs/06` §24.10 uses this to explain `festival_crowd`'s two
   * modes, and any measurement of reach in a mobile network should report it beside the
   * reach, because a graph sampled once after the window cannot see a partition that healed.
   */
  componentSizes(): number[] {
    const adj = new Map<NodeId, NodeId[]>();
    for (const node of this.nodes) {
      adj.set(node.id, peersInRange(node, this.nodes, this.rf).map((p) => p.id));
    }
    const seen = new Set<NodeId>();
    const out: number[] = [];
    for (const node of this.nodes) {
      if (seen.has(node.id)) continue;
      let size = 0;
      const stack = [node.id];
      while (stack.length > 0) {
        const id = stack.pop()!;
        if (seen.has(id)) continue;
        seen.add(id);
        size++;
        for (const nb of adj.get(id) ?? []) if (!seen.has(nb)) stack.push(nb);
      }
      out.push(size);
    }
    out.sort((a, b) => b - a);
    return out;
  }

  /** Take one connectivity sample if the interval has elapsed. Called from the physics tick,
   *  so it adds no event to the queue and consumes no random number. */
  private sampleConnectivity(): void {
    const every = this.config.connectivitySampleMs;
    if (every <= 0) return;
    if (this.lastConnectivitySampleMs < 0) this.lastConnectivitySampleMs = this.now;
    if (this.now - this.lastConnectivitySampleMs < every) return;
    this.lastConnectivitySampleMs = this.now;
    const sizes = this.componentSizes();
    if (sizes.length === 0) return;
    this.connectivitySamples++;
    if (sizes.length === 1) this.connectedSamples++;
    this.largestComponentSum += sizes[0] / this.nodes.length;
  }

  /** Whether the transmission that just went on air collided at its receiver. Read by the
   *  contention window to decide whether to widen; written by `onAir`. */
  private lastTxCollided = false;
  /** Until when each node is transmitting, and until when it is locked onto a reception.
   *  Maintained only while the receiver model or carrier sense is on, so the shipped model
   *  pays nothing. */
  private txUntil = new Map<NodeId, number>();
  private rxUntil = new Map<NodeId, number>();
  /** One radio per node: when it comes free, and what is waiting for it. Only
   *  maintained under `channelAccess: "halfDuplex"` — under `"free"` a radio is never
   *  busy, so the map stays empty and costs nothing. */
  private channel = new Map<NodeId, ChannelState>();
  private ogmTx = 0;
  private coverTx = 0;
  private routeExpiries = 0;
  /** In-window connectivity sampling (`docs/06` §24.10). Counters, not state: nothing here
   *  feeds back into routing, so a sample cannot change the world it is measuring. */
  private connectivitySamples = 0;
  private connectedSamples = 0;
  private largestComponentSum = 0;
  private lastConnectivitySampleMs = -1;
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
  private dtnCommunityCarries = 0;
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
      // Reuses the stagger already drawn for the beacon rather than drawing its own, so
      // enabling cover traffic does not shift the RNG sequence at t=0.
      if (this.config.coverTraffic) this.queue.push(stagger, "cover", node.id);
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
    this.channelDeferrals = 0;
    this.channelDeferMs = 0;
    this.channelDrops = 0;
    this.channelDropsRelayed = 0;
    this.channelDropsMedia = 0;
    this.channelDropsWithAlternative = 0;
    this.channelCaptured = 0;
    this.channelCaptureEffects = 0;
    this.channelDeafRx = 0;
    this.txSeq = 0;
    this.superseded.clear();
    this.channelBackoffs = 0;
    this.transferBlocks = 0;
    this.rateBroadcastDrops = 0;
    this.rateRelayDrops = 0;
    this.rateBroadcasts.clear();
    this.rateRelays.clear();
    this.blockedDrops = 0;
    this.wakeLocksByNode.clear();
    this.wakeLockMsByNode.clear();
    this.lastTxCollided = false;
    this.channel.clear();
    this.txUntil.clear();
    this.rxUntil.clear();
    this.rxRssi.clear();
    this.rxSeq.clear();
    this.ogmTx = 0;
    this.coverTx = 0;
    this.routeExpiries = 0;
    this.connectivitySamples = 0;
    this.connectedSamples = 0;
    this.largestComponentSum = 0;
    // Sample from the start of the window rather than inheriting the settle period's clock,
    // so a caller that clears and then runs for 60 s gets 60 s of samples.
    this.lastConnectivitySampleMs = this.now;
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
    this.dtnCommunityCarries = 0;
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
      case "cover":
        this.onCover(nodeId);
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
      case "channel": {
        const node = this.byId(nodeId);
        if (node && node.isOnline) {
          const ch = this.channel.get(node.id);
          if (ch) ch.drainScheduled = false;
          this.drainChannel(node);
        }
        break;
      }
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
        this.queue.cancel("cover", node.id);
        this.queue.cancel("scan", node.id);
        // A dead radio is an idle radio: whatever it had committed to is gone, and a
        // node that comes back must not inherit a busy transmitter.
        this.channel.delete(node.id);
        this.queue.cancel("channel", node.id);
        this.txUntil.delete(node.id);
        this.rxUntil.delete(node.id);
        this.rxRssi.delete(node.id);
        this.rxSeq.delete(node.id);
      }
    }
    // Sampled here rather than from its own event: a queue entry would carry a sequence
    // number, and two events at the same instant are ordered by it, so adding one could
    // reorder unrelated events. This consumes no random number and schedules nothing, so a
    // published number and a golden vector are both untouched by it.
    this.sampleConnectivity();
    this.queue.push(this.now + this.config.physicsIntervalMs, "physics", "*");
  }

  private onOgm(nodeId: string): void {
    const node = this.byId(nodeId);
    if (!node || !node.isOnline) return;
    this.refreshPeerList(node);
    node.score = computeScore(node, this.nodes, this.rf, this.observedPeerMax(node));
    node.seq++;
    const ogm = buildOGM(node);
    this.beacon(node, ogm);
    const jitter = randRange(this.rng, -this.config.ogmJitterMs, this.config.ogmJitterMs);
    this.queue.push(
      this.now + Math.max(200, this.ogmIntervalFor(node) + jitter),
      "ogm",
      nodeId
    );
  }

  /**
   * Put one dummy beacon on air (docs/04 §5, "dummy beacons at low rate").
   *
   * The point of cover traffic is that an observer cannot tell it from the real thing, so
   * it is counted exactly where a real transmission is counted — `node.txCount` — and
   * nowhere else. It does not enter the message path: no routing state, no delivery, no
   * ACK. Returning early when the knob is off keeps the reschedule from happening, so a
   * disabled run pushes no event and spends no draw.
   */
  private onCover(nodeId: string): void {
    if (!this.config.coverTraffic) return;
    const node = this.byId(nodeId);
    if (!node || !node.isOnline) return;
    node.txCount++;
    this.coverTx++;
    this.pushLog("ogm", node.id, `dummy beacon (cover traffic) → peers in range`, {
      peerId: undefined,
    });
    const jitter = randRange(this.rng, -this.config.ogmJitterMs, this.config.ogmJitterMs);
    this.queue.push(
      this.now + Math.max(200, this.config.coverIntervalMs + jitter),
      "cover",
      nodeId
    );
  }

  /**
   * The interval before this node's next beacon, under `ogmIntervalMode`.
   *
   * `"density"` holds the receptions a node imposes constant: at interval `I` with `p` peers
   * it causes `p / I` receptions per millisecond, so setting `I` proportional to `p` keeps
   * that product at whatever the reference density produces. Called after `refreshPeerList`,
   * so `peerIds` is this instant's neighbourhood and a node that walks into a crowd starts
   * beaconing more slowly on its next beacon rather than on a timer of its own.
   *
   * Consumes no random number: the jitter draw belongs to the caller and happens either way,
   * so the fixed mode's sequence of draws is untouched and the golden vectors do not move.
   */
  private ogmIntervalFor(node: MeshNode): number {
    if (this.config.ogmIntervalMode === "fixed") return this.config.ogmIntervalMs;
    const peers = Math.max(1, node.peerIds.length);
    const reference = Math.max(1, this.config.ogmDensityReferencePeers);
    const raw = (this.config.ogmIntervalMs * peers) / reference;
    const floor = this.config.ogmIntervalMs / 4;
    // Two chances per soft-state TTL: a neighbour expires at NEIGHBOR_SCORE_TTL_MS, and an
    // interval at half that survives one lost beacon, which BLE links produce routinely.
    const ceiling = NEIGHBOR_SCORE_TTL_MS / 2;
    return Math.min(ceiling, Math.max(floor, raw));
  }

  /** Transmit an OGM to every peer, then let each peer gossip it onward. */
  private beacon(node: MeshNode, ogm: OGM): void {
    const peers = peersInRange(node, this.nodes, this.rf);
    // One beacon is one broadcast, however many peers are in range to hear it: the per-peer
    // loop below exists to give each link its own loss draw, not because the radio
    // transmits once per neighbour. Charging the sender per peer inflated an idle node's
    // wake-lock share past 100 % of the clock, which is how this was caught. The receiver
    // side *is* per peer, because each of them really does wake and listen.
    if (peers.length > 0) this.holdWakeLock(node.id, this.beaconWakeMs(ogm));
    for (const peer of peers) {
      this.ogmTx++;
      this.pushLog("ogm", node.id, `OGM seq ${ogm.seq} → ${peer.id} (score ${ogm.score.toFixed(2)})`, {
        peerId: peer.id,
      });
      if (chance(this.rng, effectiveLossProbability(node, peer, this.rf, this.config.linkRetries))) {
        this.lostOgmTx++;
        continue;
      }
      // The receiver pays only if it heard the beacon, mirroring the data path.
      this.holdWakeLock(peer.id, this.beaconWakeMs(ogm));
      this.acceptOgm(peer, ogm, node.id);
    }
  }

  private acceptOgm(receiver: MeshNode, ogm: OGM, via: NodeId): void {
    if (!receiver.isOnline) return;
    const shouldGossip = receiveOGM(receiver, ogm, via, this.now);
    if (!shouldGossip) return;
    const next = ogmToGossip(ogm, this.config.ogmTtl);
    if (!next) return;
    // One gossip retransmission, not one per neighbour — the same reasoning as `beacon`.
    const gossipTo = peersInRange(receiver, this.nodes, this.rf).filter((p) => p.id !== via);
    if (gossipTo.length > 0) this.holdWakeLock(receiver.id, this.beaconWakeMs(next));
    for (const peer of gossipTo) {
      this.ogmTx++;
      if (
        chance(this.rng, effectiveLossProbability(receiver, peer, this.rf, this.config.linkRetries))
      ) {
        this.lostOgmTx++;
        continue;
      }
      this.holdWakeLock(peer.id, this.beaconWakeMs(next));
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
    node.score = computeScore(node, this.nodes, this.rf, this.observedPeerMax(node));
    if (!this.config.enableSuperElection) return;
    const { role, reason } = electRole(node, this.nodes, this.rf, this.config.communityRelayQuota);
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
    this.routeExpiries += pruneStaleEntries(node, this.now, NEIGHBOR_SCORE_TTL_MS);
    pruneOppQueue(node, this.now);
    node.mprSet = selectMprSet(node, this.nodes, this.config.communityRelayPreference);

    if (this.config.enableDtn && node.oppQueue.length > 0) {
      const scan = scanOppQueue(node, this.nodes, this.rf, this.now, {
        preferSuper: this.config.dtnPreferSuper,
        preferCommunity: this.config.dtnPreferCommunity,
      });
      this.dtnSuperCarries += scan.superCarries;
      this.dtnCommunityCarries += scan.communityCarries;
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

  /**
   * The largest peer count this node has heard: its own, and the `peerCount` advertised in
   * the OGMs it holds. That is the decentralised denominator `peerNorm: "observed"` asks
   * for (docs/06 §18.2) — a node cannot know the world's maximum, only what its own
   * neighbourhood told it, which is the honest version of the same idea and the reason the
   * normalisation stays bounded in a crowd. Returns 0 under the shipped `"fixed"` mode,
   * where `normPeers` uses docs/03 §3's constant 50.
   *
   * Peers are counted here rather than read from `node.peerCount` because that field is
   * refreshed on the beacon cycle and `electOne` runs between beacons; the scan costs
   * nothing while the flag is off.
   */
  private observedPeerMax(node: MeshNode): number {
    if (this.config.peerNorm !== "observed") return 0;
    let max = peersInRange(node, this.nodes, this.rf).length;
    for (const ogm of Object.values(node.ogmTable)) {
      if (ogm.peerCount > max) max = ogm.peerCount;
    }
    return max;
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

  /** Put chunks on air for as long as the sliding window has room — and, with
   *  `mediaBackpressure`, for as long as the sender's radio has slots to put them in. */
  private pushWindow(t: Transfer): void {
    const window = this.effectiveWindow(t);
    if (window <= 0) {
      // Blocked on the sender's own radio. Nothing is sent and nothing is lost: the drain
      // that frees a slot calls this again, so the transfer resumes without a timer having
      // to notice (docs/08 §12.12). Counted only when backpressure is what closed the window,
      // so a transfer configured with no window at all is not reported as throttled.
      if (this.config.mediaBackpressure) this.transferBlocks++;
      return;
    }
    while (t.nextToSend < t.chunks && t.nextToSend < t.received + window) {
      this.sendChunk(t, t.nextToSend++);
    }
  }

  /** Transmit-queue slots [nodeId] has left. Infinite on the shipped radio, where nothing
   *  queues, so a caller cannot accidentally throttle itself under `channelAccess: "free"`. */
  private radioSlotsFree(nodeId: NodeId): number {
    if (this.config.channelAccess === "free") return Number.POSITIVE_INFINITY;
    const queued = this.channel.get(nodeId)?.queue.length ?? 0;
    return Math.max(0, this.config.channelQueueDepth - queued);
  }

  /** The window the sender may fill right now. Without backpressure it is the configured
   *  depth. With it, the radio's free slots cap it — and unlike the first implementation of
   *  this flag the cap is allowed to reach **zero**, because a window floored at one still
   *  hands a packet to a queue that is already full, which is then shed at the tail. That is
   *  not backpressure, it is a slower way of dropping: measured, it *raised* the drop count
   *  (1441 → 1637 on the campus half-duplex arm). Blocking and resuming on drain is what a
   *  socket does (docs/08 §12.12). */
  private effectiveWindow(t: Transfer): number {
    if (!this.config.mediaBackpressure) return t.window;
    return Math.min(t.window, this.radioSlotsFree(t.from));
  }

  /** Resume any transfer this node is the source of. Called when its radio frees a slot, so a
   *  blocked transfer waits for the medium rather than for a timeout. */
  private resumeBlockedTransfers(nodeId: NodeId): void {
    if (!this.config.mediaBackpressure) return;
    for (const t of this.transfers.values()) {
      if (t.state === "active" && t.from === nodeId) this.pushWindow(t);
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
      // A sender waiting on its own full radio is doing what backpressure asked it to do, so
      // that wait is not a stall. Counting it would re-send into the queue that caused it —
      // the stall path bypasses the window, so it has to consult the same gate.
      const room = this.config.mediaBackpressure ? this.radioSlotsFree(nodeId) : missing.length;
      if (missing.length > 0 && room > 0) {
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
        for (const i of missing.slice(0, Math.min(t.window, room))) this.sendChunk(t, i);
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
    if (pending.onAirAt !== undefined) {
      // The packet went on air later than the timer assumed, so the silence it measures has
      // not elapsed yet. Restart from the transmission instead of retransmitting a packet
      // that may still be sitting in the queue: under a saturated radio that duplicate is
      // what turns waiting into load (docs/08 §12.11).
      // Pushed as an absolute deadline rather than `now + wait`: recomputing the remainder
      // every time accumulates float error, and a remainder of 1e-13 ms reschedules the same
      // event forever.
      const deadline = pending.onAirAt + this.ackTimeoutFor(pending.msg);
      if (this.now < deadline - 1e-9) {
        this.queue.push(deadline, "acktimeout", nodeId, msgId);
        return;
      }
    }
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
  /**
   * Hand a packet to the radio.
   *
   * Under the default `channelAccess: "free"` it goes on air immediately, which is what
   * every number in docs/06-08 was measured under. Under `"halfDuplex"` the node has one
   * transmitter doing one thing at a time, so the packet joins a bounded FIFO and waits
   * for the radio; if the FIFO is full it is dropped (docs/08 §12).
   */
  private transmit(node: MeshNode, msg: MeshMessage, targetId: NodeId): void {
    const target = this.byId(targetId);
    if (!target || !target.isOnline || target.id === node.id) return;
    if (this.config.channelAccess === "free") {
      this.onAir(node, msg, targetId);
      return;
    }
    let ch = this.channel.get(node.id);
    if (!ch) {
      ch = {
        busyUntil: 0,
        queue: [],
        drainScheduled: false,
        cw: this.config.channelCwMin,
        backoffArmed: false,
        backoffSlots: 0,
      };
      this.channel.set(node.id, ch);
    }
    if (ch.queue.length >= this.config.channelQueueDepth) {
      // Drop-tail. The radio is committed as far ahead as it is allowed to be, and a
      // queue that grows without bound does not deliver packets later — it delivers
      // them after the run is over.
      this.channelDrops++;
      if (msg.hopCount > 0) {
        this.channelDropsRelayed++;
        if (this.hasAlternativeNextHop(node, msg)) this.channelDropsWithAlternative++;
      }
      if (msg.type === "file" || msg.type === "voice") this.channelDropsMedia++;
      this.pushLog(
        "loss",
        node.id,
        `${msg.id} → ${targetId} dropped: transmit queue full (${this.config.channelQueueDepth})`,
        { peerId: targetId, msgId: msg.id, msgType: msg.type, hop: msg.hopCount }
      );
      return;
    }
    ch.queue.push({ msg, targetId, queuedAt: this.now });
    this.drainChannel(node);
  }

  /** Whether [node] could have reached [msg]'s destination through a peer other than the one
   *  it chose, at no cost in hops. A relay's route is one next hop, so "round the congestion"
   *  only exists if some peer in range is at least as close to the destination as that hop is;
   *  this counts the shed packets for which such a peer was there. Derived from the route table
   *  and the geometry, so it consumes no random numbers and cannot move a golden vector. */
  private hasAlternativeNextHop(node: MeshNode, msg: MeshMessage): boolean {
    const dest = msg.to;
    if (dest === "BROADCAST" || dest === GROUP_ADDRESS) return false;
    const mine = node.nextHopTable[dest];
    if (!mine || mine.tq < TQ_USABLE) return false;
    for (const peer of peersInRange(node, this.nodes, this.rf)) {
      if (peer.id === mine.bestNeighbor) continue;
      const theirs = peer.nextHopTable[dest];
      // Forwarding to this peer costs one hop to reach it, so it is no worse than the route
      // already chosen only if the peer is strictly closer to the destination.
      if (theirs && theirs.tq >= TQ_USABLE && theirs.hopCount <= mine.hopCount - 1) return true;
    }
    return false;
  }

  /** Put the next queued packet on air if the radio is free, and schedule the drain that
   *  releases the one behind it. */
  private drainChannel(node: MeshNode): void {
    const ch = this.channel.get(node.id);
    if (!ch) return;
    // A radio does not spend air time on a transmission nobody can receive, so packets
    // whose target went offline while they waited are discarded before anything else.
    while (ch.queue.length > 0) {
      const head = this.byId(ch.queue[0].targetId);
      if (head && head.isOnline) break;
      ch.queue.shift();
    }
    if (ch.queue.length === 0) return;
    if (ch.busyUntil > this.now) {
      // Still on air. Make sure something wakes this radio when it is not.
      if (!ch.drainScheduled) {
        ch.drainScheduled = true;
        this.queue.push(ch.busyUntil, "channel", node.id);
      }
      return;
    }
    if (this.config.channelAccess === "csma") {
      // Carrier sense: the medium is busy if anybody within radio range is transmitting, and
      // a node that waits is not itself on air, so this always terminates.
      const freeAt = this.mediumFreeAt(node);
      if (freeAt > this.now) {
        this.channelDeferrals++;
        this.channelDeferMs += freeAt - this.now;
        if (!ch.drainScheduled) {
          ch.drainScheduled = true;
          this.queue.push(freeAt, "channel", node.id);
        }
        return;
      }
      if (this.config.channelBackoff !== "none") {
        // The medium is free *now* — which is exactly when every other node waiting on the
        // same medium also finds it free, because they were all woken at this instant. Left
        // alone they transmit together and listening has synchronised the herd instead of
        // dispersing it. Draw a random number of slots and wait them out (docs/08 §12.13).
        if (!ch.backoffArmed) {
          // `randInt` draws only here, so `channelBackoff: "none"` consumes no random
          // numbers and the shipped model stays bit-identical.
          ch.backoffSlots = randInt(this.rng, 0, ch.cw);
          ch.backoffArmed = true;
          this.channelBackoffs++;
        }
        if (ch.backoffSlots > 0) {
          const wait = ch.backoffSlots * this.config.channelSlotMs;
          // Paid in full rather than a slot at a time: a 64-slot window drained one event
          // per slot is 64 wakeups per transmission, and the answer is the same.
          ch.backoffSlots = 0;
          this.channelDeferrals++;
          this.channelDeferMs += wait;
          if (!ch.drainScheduled) {
            ch.drainScheduled = true;
            this.queue.push(this.now + wait, "channel", node.id);
          }
          return;
        }
      }
    }
    const next = this.takeNextTx(ch);
    const waited = this.now - next.queuedAt;
    if (waited > 0) {
      this.channelDeferrals++;
      this.channelDeferMs += waited;
    }
    const airTime = this.onAir(node, next.msg, next.targetId);
    ch.busyUntil = this.now + airTime;
    // A slot just freed. Anything this node was holding back for want of one goes now, which
    // is the resume half of blocking — without it a transfer that was refused air waits for a
    // timeout instead of for the medium.
    this.resumeBlockedTransfers(node.id);
    if (this.config.channelBackoff !== "none") {
      // Binary exponential backoff: a radio that just collided draws from a window twice as
      // wide next time, so two radios that keep meeting keep backing off until they stop
      // meeting; a radio that got through goes back to the narrow window it started with.
      ch.cw = this.lastTxCollided
        ? Math.min(ch.cw * 2, this.config.channelCwMax)
        : this.config.channelCwMin;
      ch.backoffArmed = false;
    }
    if (ch.queue.length > 0 && !ch.drainScheduled) {
      ch.drainScheduled = true;
      this.queue.push(ch.busyUntil, "channel", node.id);
    }
  }

  /** The instant the medium around [node] comes free: the latest transmit window it can
   *  hear, or `now` if it hears nobody. Carrier sense only, and only over peers in range — a
   *  node cannot sense a transmission it could not receive (docs/08 §12.10). */
  private mediumFreeAt(node: MeshNode): number {
    let freeAt = this.now;
    for (const peer of peersInRange(node, this.nodes, this.rf)) {
      const until = this.txUntil.get(peer.id) ?? 0;
      if (until > freeAt) freeAt = until;
    }
    return freeAt;
  }

  /** Take the next packet off the queue: arrival order, or by class when the config asks
   *  for it. Within a class it is still arrival order, so a voice note cannot be overtaken
   *  by a later one. */
  private takeNextTx(ch: ChannelState): { msg: MeshMessage; targetId: NodeId; queuedAt: number } {
    if (this.config.channelPriority === "fifo") return ch.queue.shift()!;
    if (this.config.channelPriority === "ackFirst") {
      const ack = ch.queue.findIndex((q) => q.msg.type === "ack");
      return ch.queue.splice(ack === -1 ? 0 : ack, 1)[0];
    }
    let best = 0;
    for (let i = 1; i < ch.queue.length; i++) {
      const c = CHANNEL_CLASS[ch.queue[i].msg.type];
      const bc = CHANNEL_CLASS[ch.queue[best].msg.type];
      if (c < bc) best = i;
    }
    return ch.queue.splice(best, 1)[0];
  }

  /**
   * The packet goes on air: counters, loss draw, log, delivery event. Returns the air
   * time it occupied — a lost packet still occupied the radio for all of it.
   */
  private onAir(node: MeshNode, msg: MeshMessage, targetId: NodeId): number {
    const target = this.byId(targetId)!;
    // Cleared per transmission so the contention window sees this packet's fate and not the
    // last one's.
    this.lastTxCollided = false;
    node.txCount++;
    this.relayTx++;
    const loss = effectiveLossProbability(node, target, this.rf, this.config.linkRetries);
    const rssi = rssiModel(node, target, this.rf);
    // What this packet occupies a radio for, without the jitter draw: the receiver-side
    // model below needs it before the packet's fate is known, and both branches that never
    // land return it. No random number is consumed here, so `channelCapture: "none"` stays
    // bit-identical to the model every other result in this repository was measured under.
    const occupied = this.occupancyMs(msg.sizeBytes, msg.transport);
    if (this.config.channelAccess !== "free") {
      // A retry timer measures the silence after a transmission, so under a queued radio it
      // has to start when the packet leaves rather than when it was handed over.
      const pending = this.pendingAcks.get(msg.id);
      if (pending && pending.from === node.id) pending.onAirAt = this.now;
    }
    const capture = this.config.channelCapture !== "none";
    const sense = this.config.channelAccess === "csma";
    // A radio is deaf from the moment it starts transmitting, whether or not the packet
    // survives the link — and carrier sense needs the same fact from the other side, because
    // what a sender listens for is exactly its peers' transmit windows.
    if (capture || sense) this.txUntil.set(node.id, this.now + occupied);
    // skills/07 "wake-locks": a transmission holds the radio — and therefore the CPU — for
    // exactly as long as the packet occupies it. Accumulated here rather than read off
    // `txUntil`, which the shipped `free`/`none` baseline never maintains.
    this.holdWakeLock(node.id, occupied);
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
      // Air time without the jitter draw: consuming a random number here would move the
      // stream the default model depends on, and the golden vectors with it.
      return occupied;
    }
    if (capture) {
      // Two ways a packet that survived the link still does not arrive: its receiver is
      // transmitting, or its receiver is locked onto a packet that got there first. Both
      // are losses rather than deferrals — that is what a collision is. Under `first` the
      // earlier packet always wins and no signal-strength comparison happens, which is the
      // pessimistic bound (docs/08 §12.9). Under `strongest` a newcomer that is enough
      // stronger takes the receiver over instead, and the incumbent is what is lost — the
      // capture effect, and the reason `first` and `none` bracket the truth rather than
      // either of them being it (docs/08 §12.15).
      const deaf = (this.txUntil.get(target.id) ?? 0) > this.now;
      const busy = !deaf && (this.rxUntil.get(target.id) ?? 0) > this.now;
      const held = this.rxRssi.get(target.id) ?? Number.NEGATIVE_INFINITY;
      const captures =
        busy &&
        this.config.channelCapture === "strongest" &&
        rssi >= held + this.config.channelCaptureRatioDb;
      if ((deaf || busy) && !captures) {
        this.lastTxCollided = true;
        if (deaf) this.channelDeafRx++;
        else this.channelCaptured++;
        this.recordTxOutcome(node, 0);
        this.pushLog(
          "loss",
          node.id,
          `${msg.id} → ${targetId} collided (${
            deaf
              ? "receiver was transmitting"
              : this.config.channelCapture === "strongest"
                ? `receiver held a stronger packet (${held.toFixed(0)} vs ${rssi.toFixed(0)} dBm)`
                : "receiver was locked onto an earlier packet"
          })`,
          { peerId: targetId, msgId: msg.id, msgType: msg.type, hop: msg.hopCount, rssi }
        );
        return occupied;
      }
      if (captures) {
        // The newcomer wins the receiver. The incumbent is condemned by transmission
        // sequence rather than by message id, so that a retry of the same message — or a
        // second relay carrying the same copy — is a fresh attempt.
        const victim = this.rxSeq.get(target.id);
        if (victim !== undefined) this.superseded.add(victim);
        this.channelCaptureEffects++;
        // …and the incumbent is a collision loss, so it is counted as one.
        this.channelCaptured++;
        // `lastTxCollided` stays clear for the winner: its own transmission was clean, and
        // doubling its contention window would punish the packet that survived. The
        // incumbent's transmitter is not told, which is the honest limit of modelling this
        // at the receiver — a real radio gets no such notification either, and it is why
        // `channelBackoff` and `channelCapture: "strongest"` do not compose into anything
        // better than each alone.
      }
    }
    // Under `strongest` the outcome is booked at arrival instead, because a packet taken over
    // part-way through was not a success and booking it as one here would leave the link
    // estimate optimistic about a radio that is losing packets to third parties. That would
    // also make the arm incomparable with `first`, where the loser of a collision *is* booked
    // as a failure: the only difference between the two arms should be which packet survives.
    if (this.config.channelCapture !== "strongest") this.recordTxOutcome(node, 1);
    this.pushLog("tx", node.id, `${msg.id} → ${targetId} (${msg.type}, hop ${msg.hopCount}, ${rssi.toFixed(0)} dBm)`, {
      peerId: targetId,
      msgId: msg.id,
      msgType: msg.type,
      hop: msg.hopCount,
      rssi,
    });
    const base = msg.transport === "wifiDirect" ? this.config.hopLatencyWifiMs : this.config.hopLatencyBleMs;
    // Air time: what the payload physically occupies the radio for. The loss draw and
    // the jitter draw happen in the same order under both channel models, so
    // `channelAccess` changes *when* a packet lands and never which random numbers a
    // transmission consumes.
    const airTime =
      base +
      this.serializationMs(msg.sizeBytes, msg.transport) +
      randRange(this.rng, this.config.jitterMinMs, this.config.jitterMaxMs);
    // Occupancy is not latency. `airTime` says when this packet lands, which keeps its
    // hop-latency base under both models because that is what docs/02 §6's budget measures;
    // `rxOccupied` says how long the radio was busy hearing it, which is the only one of the
    // two `radioOccupancy` may change (docs/06 §24.5). Identical under the shipped model.
    const rxOccupied =
      this.config.radioOccupancy === "airtime"
        ? this.airtimeMs(msg.sizeBytes, msg.transport)
        : airTime;
    if (capture) this.rxUntil.set(target.id, this.now + rxOccupied);
    // The receiving side of the same lock. Counted whether or not the packet survives the
    // link: a radio that woke up and listened spent the power either way, which is exactly
    // what makes a flood a battery-drain attack rather than a bandwidth one.
    this.holdWakeLock(target.id, rxOccupied);
    let seq: number | undefined;
    if (this.config.channelCapture === "strongest") {
      // Only assigned here, so the two shipped modes consume nothing and behave exactly as
      // every published number in this repository was measured.
      seq = ++this.txSeq;
      this.rxRssi.set(target.id, rssi);
      this.rxSeq.set(target.id, seq);
    }
    this.queue.push(this.now + airTime, "msg", targetId, { msg, via: node.id, seq } as MsgPayload);
    return airTime;
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

    // A transmission the receiver gave up on part-way through, because a stronger packet took
    // it over (`channelCapture: "strongest"`). Checked before anything else: the receiver
    // never decoded this one, so it is not coverage evidence, not a delivery, and not a
    // duplicate. Keyed by transmission rather than by message id, so a retry of the same
    // message is a fresh attempt and not a condemned one. Under every other mode `seq` is
    // undefined and this cannot fire.
    const seq = payload.seq;
    if (seq !== undefined && sender) {
      if (this.superseded.has(seq)) {
        this.superseded.delete(seq);
        this.recordTxOutcome(sender, 0);
        this.pushLog("loss", nodeId, `${msg.id} lost (receiver was taken over by a stronger packet)`, {
          peerId: via,
          msgId: msg.id,
          msgType: msg.type,
          hop: msg.hopCount,
        });
        return;
      }
      this.recordTxOutcome(sender, 1);
    }

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

    // Placed after the hop record exists so a suppressed broadcast still shows in the
    // hop trace, which is the artifact an auditor reads (docs/07 §6).
    //
    // docs/04 §6: "Max 5 broadcasts / minute per node; SUPERs drop excess." Enforced
    // by SUPERs only, exactly as written — which is a limitation worth stating rather
    // than hiding: a NORMAL node neither relays far nor filters, so a flooder still
    // reaches its own one-hop neighbourhood. The gate is on the `broadcast` type and
    // not on `to === "BROADCAST"`, because SOS travels to BROADCAST too and docs/04
    // §6 gives SOS its own mechanism (opt-in listening, plus the collapsing in §11);
    // rate-limiting an emergency channel at 5/min would be a worse failure than the
    // abuse it prevents.
    if (
      this.config.rateLimits &&
      msg.type === "broadcast" &&
      (this.config.broadcastCapScope === "all" || node.role === "SUPER")
    ) {
      const gate = admitByRate(
        this.rateBroadcasts,
        `${node.id}|${msg.from}`,
        this.config.broadcastPerMinuteCap,
        this.now
      );
      if (!gate.ok) {
        this.rateBroadcastDrops++;
        if (hopRecord) {
          hopRecord.action = "suppressed";
          hopRecord.reason = gate.reason;
        }
        this.pushLog(
          "decision",
          node.id,
          `${msg.id} broadcast from ${msg.from} suppressed by ${node.name} ` +
            `(${node.role === "SUPER" ? "SUPER" : "NORMAL, cap scope all"}): ${gate.reason}`,
          { peerId: via, msgId: msg.id, msgType: msg.type, hop: msg.hopCount }
        );
        return;
      }
    }


    // docs/04 §6: "Block/mute peer locally (ignore msgs from pubKey)." Placed after the
    // hop record, like the rate gates, so the audit trail shows a node ignored a message
    // rather than silently never seeing it — which is the difference between a user
    // choice and packet loss. `isBlockableTraffic` keeps control plane and SOS out; see
    // its doc comment for why blocking an ACK makes the airtime worse.
    const blockedHere = isBlockableTraffic(msg) && this.isBlocked(node.id, msg.from);
    if (blockedHere) {
      this.blockedDrops++;
      if (hopRecord) {
        hopRecord.action = "blocked";
        hopRecord.reason = `${node.name} has blocked ${msg.from}`;
      }
      this.pushLog(
        "decision",
        node.id,
        `${msg.id} from ${msg.from} ignored by ${node.name}: sender is blocked` +
          (this.config.blockScope === "relay" ? " (and not relayed)" : ""),
        { peerId: via, msgId: msg.id, msgType: msg.type, hop: msg.hopCount }
      );
      // "relay" is §6's "ignore floods": the blocker stops paying for someone it blocked.
      // "delivery" stops here and lets the mesh carry the copy for everyone else.
      if (this.config.blockScope === "relay") return;
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

    if (msg.to === node.id && !blockedHere) {
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
      if (group && isMember && group.keyEpoch === msg.groupEpoch && !blockedHere) {
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
      } else if (group && isMember && !blockedHere) {
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

    if (msg.to === "BROADCAST" && !blockedHere) {
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

    // docs/04 §6: "Cap relay to 30 msgs/min per source; ignore floods." Every node
    // enforces this one, because relaying is what every node does and a flood costs
    // the relays' queues rather than a SUPER's attention — docs/08 §12.13 measured
    // queue drops running eight to one against receiver collisions, so the buffer is
    // where a flood actually lands. Control-plane types are exempt; see
    // `countsAgainstRelayCap` for the 2 s OGM arithmetic that forces it.
    if (this.config.rateLimits && countsAgainstRelayCap(msg)) {
      const gate = admitByRate(
        this.rateRelays,
        `${node.id}|${msg.from}`,
        this.config.relayPerSourcePerMinuteCap,
        this.now
      );
      if (!gate.ok) {
        this.rateRelayDrops++;
        if (hopRecord) {
          hopRecord.action = "suppressed";
          hopRecord.reason = gate.reason;
        }
        this.pushLog(
          "decision",
          node.id,
          `${msg.id} from ${msg.from} not relayed by ${node.name}: ${gate.reason}`,
          { peerId: via, msgId: msg.id, msgType: msg.type, hop: msg.hopCount }
        );
        return;
      }
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
      this.queue.cancel("cover", node.id);
      this.queue.cancel("scan", node.id);
      this.channel.delete(node.id);
      this.queue.cancel("channel", node.id);
      this.txUntil.delete(node.id);
      this.rxUntil.delete(node.id);
    } else {
      node.battery = Math.max(node.battery, 0.3);
      node.uptimeMin = 0;
      node.offlineAt = -1;
      node.reasonTrace = "Reconnected";
      this.queue.push(this.now + 100, "ogm", node.id);
      if (this.config.coverTraffic) this.queue.push(this.now + 100, "cover", node.id);
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
    // Not filtered on `charging`, unlike the battery rates: a plugged-in device still holds
    // its CPU awake for every packet it hears. The denominator is the network's total, so
    // the two shares sum to 100 and neither can exceed it — which is the property that makes
    // them readable when the absolute milliseconds are not (see `radioDemandRatio`).
    const heldBy = (role: "SUPER" | "NORMAL"): number =>
      online
        .filter((n) => n.role === role)
        .reduce((sum, n) => sum + (this.wakeLockMsByNode.get(n.id) ?? 0), 0);
    const heldTotal = online.reduce(
      (sum, n) => sum + (this.wakeLockMsByNode.get(n.id) ?? 0),
      0
    );
    const wakeShare = (role: "SUPER" | "NORMAL"): number =>
      heldTotal === 0 ? 0 : (heldBy(role) / heldTotal) * 100;
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
      coverTx: this.coverTx,
      routeExpiries: this.routeExpiries,
      connectivitySamples: this.connectivitySamples,
      connectedSampleShare:
        this.connectivitySamples === 0 ? 1 : this.connectedSamples / this.connectivitySamples,
      meanLargestComponent:
        this.connectivitySamples === 0 ? 1 : this.largestComponentSum / this.connectivitySamples,
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
      dtnCommunityCarries: this.dtnCommunityCarries,
      sentChunks: this.sentChunks,
      channelDeferrals: this.channelDeferrals,
      channelDeferMs: this.channelDeferMs,
      channelDrops: this.channelDrops,
      channelDropsRelayed: this.channelDropsRelayed,
      channelDropsMedia: this.channelDropsMedia,
      channelDropsWithAlternative: this.channelDropsWithAlternative,
      channelCaptured: this.channelCaptured,
      channelCaptureEffects: this.channelCaptureEffects,
      channelBackoffs: this.channelBackoffs,
      transferBlocks: this.transferBlocks,
      rateBroadcastDrops: this.rateBroadcastDrops,
      rateRelayDrops: this.rateRelayDrops,
      blockedDrops: this.blockedDrops,
      channelDeafRx: this.channelDeafRx,
      sentSync: this.sentSync,
      bytesDelivered: this.bytesDelivered,
      batteryPercentPerHourNormal: drainPerHour("NORMAL"),
      batteryPercentPerHourSuper: drainPerHour("SUPER"),
      scansPerSec: this.scanCount / elapsedSec,
      relaysPerSec: this.relayTx / elapsedSec,
      wakeLocks: [...this.wakeLocksByNode.values()].reduce((a, b) => a + b, 0),
      wakeLockMs: [...this.wakeLockMsByNode.values()].reduce((a, b) => a + b, 0),
      wakeLockShareNormal: wakeShare("NORMAL"),
      wakeLockShareSuper: wakeShare("SUPER"),
      radioDemandRatio: heldTotal / (Math.max(1, online.length) * elapsedMs),
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
