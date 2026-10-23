export type NodeId = string;
export type MsgId = string;

export type Role = "SUPER" | "NORMAL";
export type TransportType = "ble" | "wifiDirect" | "multipeer";

export type MsgType =
  | "text"
  | "broadcast"
  | "voice"
  /** One chunk of a large transfer (docs/05 §3.2: 64 KB slices, sliding-window ACK). */
  | "file"
  | "sos"
  /** Anti-entropy traffic for group history: a digest beacon, a request for the
   *  buckets that differ, or the entries that fill them (roadmap Phase 1: "CRDT for
   *  group/broadcast history (hash beacon anti-entropy)"). Control plane, so it is
   *  neither ACKed nor counted as 1:1 traffic. */
  | "sync"
  | "ack"
  | "ogm";

/** Flood-suppression policy for the data plane (docs/03 §6). */
/**
 * Relay policy for the data plane.
 *
 * - `mpr`         routing plus MPR flood suppression — what ships.
 * - `route-flood` routing without suppression. Comparing this against `mpr`
 *                 isolates what MPR still buys once the route table works;
 *                 the two mechanisms are substitutes, so the honest overhead
 *                 claim needs both (docs/06 §6).
 * - `flood-all`   naive epidemic flooding: no route table, no suppression.
 *                 This is the baseline skills/02 ("overhead ≤70% of
 *                 flood-all") and skills/08 ("overhead ↓30% vs naive flood")
 *                 are written against.
 */
export type RelayPolicy = "mpr" | "route-flood" | "flood-all";

/**
 * How much of a radio a device has (docs/08 §12).
 *
 * - `free`       the model every other number in this repository was measured
 *                under: an infinitely wide radio. A transmission occupies no
 *                exclusive resource, so two packets on air at the same instant
 *                both succeed and a 10 MB file cannot cost anybody else anything.
 *                This is what made the first contention measurement in docs/08 §9
 *                come out null — correctly null, but null for a reason that has
 *                nothing to do with mesh etiquette.
 * - `csma`       `halfDuplex` plus carrier sense: before a packet goes on air the node
 *                checks whether any peer within radio range is transmitting, and waits for
 *                the medium to come free if one is. This is what BLE and Wi-Fi both do at
 *                the link layer, so it is the most realistic of the three — and it is the
 *                mechanism that stops a node transmitting into a receiver that cannot hear
 *                it (docs/08 §12.10). Plain carrier sense, no contention window: two nodes
 *                that sense each other busy simply wait — and are woken at the same instant
 *                the medium clears, so they transmit together. `channelBackoff: "binary"`
 *                adds the random wait that disperses them (§12.13).
 * - `halfDuplex` one radio per device, and it does one thing at a time. Packets
 *                go into a bounded FIFO and on air when the radio comes free;
 *                when the FIFO is full the newest packet is dropped, because a
 *                real radio sheds load rather than promising air time it does
 *                not have. Two things it still does not model, both optimistic:
 *                a busy *receiver* can still take a packet (no capture effect),
 *                and packets waiting their turn do not collide.
 *
 * Ships as `free` because every acceptance gate in skills/02 and skills/08 was
 * written against it and because the honest reading of `halfDuplex` results is
 * that they belong to a different (harder) network than the one the roadmap
 * specifies. Flip it to measure what a shared medium would cost.
 */
export type ChannelAccess = "free" | "halfDuplex" | "csma";

/**
 * Whether a node that has been waiting for the medium waits a random number of slots
 * before it takes it (docs/08 §12.13).
 *
 * Carrier sense without backoff has a failure mode that is invisible in the deferral
 * counter: every node waiting on the same busy medium is woken at *the same instant* —
 * the moment it comes free — and they all transmit together. Listening synchronises the
 * herd instead of dispersing it, which is why `csma` measured worse than not listening at
 * all. A contention window is the standard answer: draw a random slot count, wait it out,
 * and double the window you draw from after a collision so a node that keeps losing keeps
 * backing off further.
 *
 * - `none`   transmit the instant the medium is free. Ships, and is what every `csma`
 *            number in docs/08 §12.10 was measured under.
 * - `binary` binary exponential backoff: `channelCwMin` slots on a clean transmission,
 *            doubling up to `channelCwMax` after each collision.
 *
 * Only consulted under `channelAccess: "csma"`. Without a shared medium there is nobody to
 * contend with, and a node whose own radio is busy is already serialised by its FIFO.
 */
export type ChannelBackoff = "none" | "binary";

/**
 * Which queued packet a busy radio takes next (docs/08 §12.8).
 *
 * - `fifo`   arrival order. Simple, fair, and what a radio with no notion of what it is
 *            carrying does. Ships.
 * - `ackFirst` acknowledgements jump the queue, everything else keeps arrival order. An
 *            ACK is 100 bytes and it is what releases the next chunk of somebody's
 *            transfer, so promoting it is cheap and it pays: measured against a 10 MB
 *            file in flight it cuts the transfer by a third (docs/08 §12.8).
 * - `class`  a WMM-like ranking: deadline-driven traffic (an SOS flood, a push-to-talk
 *            frame) first, then acknowledgements, then everything else in arrival order —
 *            which puts a text message ahead of the 64 KB file chunk queued behind it.
 *            Promoting voice is the part that does not pay: a streamed note three hops
 *            away already needs more air time than its capture clock gives it, so it
 *            cannot be rescued by jumping the queue, and the text it jumps ahead of pays
 *            for the attempt.
 *
 * Only consulted where a radio queues at all — `"halfDuplex"` and `"csma"`. Under `"free"`
 * nothing ever waits, so there is no order to choose.
 */
export type ChannelPriority = "fifo" | "ackFirst" | "class";

/**
 * How the coverage score normalises a node's peer count (docs/03 §3, docs/06 §18.2).
 *
 * - `fixed`    against a constant 50 peers, as `docs/03` specifies: `log(1+P)/log(51)`.
 *              Bounded and comparable across worlds, but it saturates — a node hearing 199
 *              peers and one hearing 60 differ by 0.09 of score, so the score cannot say
 *              "dramatically better placed", which is exactly what an atrium or a ridge is.
 * - `observed` against the largest peer count this node has actually heard, from its own
 *              count and the `peerCount` field of the OGMs in its table. Openness becomes
 *              decisive in a sparse world and stays bounded in a crowd, because the
 *              denominator is the world's own maximum rather than a constant. Not shipped:
 *              it is the same trap as docs/06 §15's density rule approached from the other
 *              side, and it needs a field test to justify it.
 */
export type PeerNorm = "fixed" | "observed";

/**
 * What a receiver does when two packets arrive at once (docs/08 §12.9).
 *
 * - `none`  a busy receiver takes everything. This is what ships, and it is why the
 *           contention measurement in docs/08 §9 comes out null: with no shared medium and
 *           an infinitely attentive receiver, a transmission cannot harm another one.
 * - `first` the receiver locks onto the packet that got there first, and two things are
 *           lost: a packet that arrives while the receiver is locked onto another one
 *           (first capture, with no signal-strength comparison), and a packet that arrives
 *           while the receiver is itself transmitting (a half-duplex radio cannot hear
 *           over its own transmitter). Both are modelled as losses rather than deferrals,
 *           which is what a collision is. This is the *pessimistic* arm: it never lets a
 *           strong packet survive a weak one, which no real radio behaves like.
 * - `strongest` the same, plus the capture effect. A newcomer that is at least
 *           `channelCaptureRatioDb` stronger than the packet the receiver is holding takes
 *           the receiver over, and the incumbent is the packet that is lost. A real radio
 *           does this: it demodulates the stronger signal through the weaker one rather than
 *           losing both, which is why `first` bounds the loss from above and `none` from
 *           below, and the truth is in between (docs/08 §12.15).
 *
 * Independent of `channelAccess`: `first` under `"free"` is receiver contention with no
 * transmitter queue, which separates the two mechanisms the half-duplex model conflates.
 */
export type ChannelCapture = "none" | "first" | "strongest";

export interface Vec2 {
  x: number;
  y: number;
}

/** Axis-aligned building / obstacle. A segment crossing one of these loses
 *  `wallPenaltyDb` per boundary crossing (docs/01 §2.1, skills/08). */
export interface Obstacle {
  x: number;
  y: number;
  w: number;
  h: number;
  label: string;
}

export interface MeshMessage {
  id: MsgId;
  type: MsgType;
  from: NodeId;
  to: NodeId | "BROADCAST";
  /** Truncated hash of the destination pubkey so relays can route without
   *  learning the identity (docs/04 §4). */
  destHint: string;
  body: string;
  ttl: number;
  hopCount: number;
  /** True once this message has been held in an OppQueue awaiting a contact
   *  (docs/03 §8). Opportunistic deliveries are not latency-bounded, so the
   *  docs/04 per-hop budget must be measured on traffic that was routed. */
  carried: boolean;
  /** Retransmission attempt for the same logical message. The destination
   *  dedups on `id`; intermediate nodes dedup on `id#attempt`, so a source
   *  retry is not swallowed by nodes that already relayed attempt 0. */
  attempt: number;
  priority: "low" | "normal" | "high";
  /** Simulation time in ms — never wall-clock, so runs stay reproducible. */
  timestamp: number;
  encrypted: boolean;
  /** Transport the router selected for this payload (docs/02 §3.1). */
  transport: TransportType;
  /** Stable identity of one emergency across its repeated floods. Each flood is
   *  a *new* message id — the seen-cache would otherwise swallow every repeat —
   *  but receivers collapse on this, so one emergency raises one alert rather
   *  than four (docs/04: the SOS channel is opt-in and must not spam). */
  sosId?: string;
  /** 0-based index of this flood within the SOS. */
  sosRepeat?: number;
  /** GPS fix carried by *this* flood. Repeating is what keeps it useful: a
   *  sender that is moving reports a different position in flood 3 than in
   *  flood 0, and a rescuer following the alert sees the movement. */
  sosPos?: Vec2;
  /** Set on traffic addressed to a group (docs/04 §4). A scoped flood carries
   *  `to === GROUP_ADDRESS`; per-member unicast carries the member's id. Either
   *  way this is what keeps group traffic out of the unicast metrics. */
  groupId?: string;
  /** The group's key epoch when this message was sent. A receiver that is a
   *  member but holds a different epoch cannot decrypt it — which is exactly what
   *  "groupKey rotated on member leave" (docs/04 §4) is for. */
  groupEpoch?: number;
  /** Set on one chunk of a large transfer, with its position in it. */
  transferId?: string;
  chunkIndex?: number;
  /** Byte size, used by transport selection. */
  sizeBytes: number;
}

/** Originator Message — BATMAN-lite control-plane beacon (docs/03 §4). */
export interface OGM {
  nodeId: NodeId;
  seq: number;
  score: number;
  isSuper: boolean;
  peerCount: number;
  batteryBucket: number;
  /** Best known hop count to other originators, gossiped so that routes to
   *  non-neighbours can be learned (docs/03 §4 step 1). */
  bestHopTo: Record<string, number>;
  /** How many gossip hops this copy has travelled. */
  hopCount: number;
  /**
   * The originator's own 1-hop neighbours, bounded and deterministically
   * ordered. This is the OLSR HELLO payload (docs/01 §"OLSR's MPR"): without it
   * a node cannot know whether a relay it overheard actually *covers* its own
   * neighbours, which is the whole point of MPR selection.
   */
  neighborIds: NodeId[];
  /**
   * The originator has declined the router role — SUPER opt-out or battery
   * saver (skills/02 acceptance). Advertised so that neighbours can drop it
   * from the top-20% candidacy ranking instead of letting a node that will
   * never promote occupy a slot and thin the router set below the 15% floor.
   * Without the flag the declination is only knowable locally, which a real
   * device cannot observe for its peers.
   */
  declinedRouter: boolean;
}

/** What a node did with a copy it accepted. */
export type HopAction =
  | "received"
  | "delivered"
  | "relayed"
  | "suppressed"
  | "queued"
  | "expired";

/**
 * One hop of a message's journey, recorded as a *fresh* copy arrives.
 *
 * roadmap Phase 4 asks for hop transparency — "via 2 nodes • SUPER Amir" — which
 * needs more than the node list: when each hop happened, over what link budget,
 * and what the forwarding decision said. This is the record behind that string.
 */
export interface HopRecord {
  nodeId: NodeId;
  /** Simulation time this copy arrived. */
  atMs: number;
  /** Who handed it over. */
  via: NodeId;
  /** Link budget of that hand-over in dBm, from the docs/05 §1.1 model. */
  rssi: number;
  /** `msg.hopCount` as it arrived: 0 for the originator's first neighbour. */
  hop: number;
  action: HopAction;
  /** `decideForward`'s own words — "route via node-7", "MPR suppressed". */
  reason?: string;
}

/** Capture-log event kinds. `ogm` is opt-in separately: beacons outnumber
 *  everything else and drown the data plane in a 60-node crowd. */
/** Address of a scoped group flood. Not a node id, and deliberately distinct
 *  from `"BROADCAST"`: a broadcast is public by design (docs/04 §4), a group
 *  flood is delivered only to members holding the current key epoch. */
export const GROUP_ADDRESS = "GROUP";

/** Group size limits — roadmap Phase 1: "group (3-10 members)". */
export const GROUP_MIN_MEMBERS = 3;
export const GROUP_MAX_MEMBERS = 10;

/** Buckets a group history digest is split into. Sixteen is the usual compromise
 *  between beacon size and how much a reply over-sends: one differing bucket costs
 *  1/16 of the history in ids, and the beacon itself stays inside one BLE packet. */
export const HISTORY_BUCKETS = 16;

/**
 * One group message a node holds, kept so a peer can repair it later.
 *
 * The set of these per group is a grow-only set — a G-Set CRDT — so merging two
 * nodes' histories is a union: idempotent, commutative and associative, which is
 * what lets anti-entropy run in any order, lose beacons, and still converge
 * (roadmap Phase 1: "CRDT for group/broadcast history").
 */
export interface HistoryEntry {
  msgId: string;
  groupId: string;
  from: NodeId;
  at: number;
  body: string;
  /** The group's key epoch when this was sent. A rotation makes everything under an
   *  older epoch unreadable (docs/06 §14), so entries are only repairable inside the
   *  epoch they were written in. */
  epoch: number;
  /** True once this copy arrived by anti-entropy rather than by the original flood. */
  synced?: boolean;
}

/** A group channel (docs/04 §4, roadmap Phase 1 and Phase 4 "Group UX"). */
export interface Group {
  id: string;
  name: string;
  members: Set<NodeId>;
  /** Only the admin may rotate the key (roadmap Phase 4: "admin rotate key"). */
  adminId: NodeId;
  /** Bumped on every membership change and on manual rotation. */
  keyEpoch: number;
  createdAt: number;
}

export type MeshLogKind =
  | "tx"
  | "loss"
  | "duplicate"
  | "deliver"
  | "decision"
  | "queue"
  | "election"
  | "ack"
  /** An SOS flood: sent, repeated, or collapsed onto an existing alert. */
  | "sos"
  /** Group membership: created, joined, left, key rotated, or a stale epoch rejected. */
  | "group"
  /** One round of history anti-entropy: a beacon, a request, or a reply. */
  | "sync"
  /** A large transfer: one chunk on air, or the whole file complete. */
  | "transfer"
  | "ogm";

/**
 * One line of the pcap-like mesh log: a timestamped radio or protocol event with
 * enough context to reconstruct why a message went where it did. Bounded — a
 * 60-node crowd emits hundreds of thousands of beacons — and off by default so
 * the golden runs pay nothing for it.
 */
export interface MeshLogEntry {
  atMs: number;
  kind: MeshLogKind;
  /** Who the event happened at (for `tx`, the sender). */
  nodeId: NodeId;
  /** The other end of the link, where there is one. */
  peerId?: NodeId;
  msgId?: MsgId;
  msgType?: MsgType;
  hop?: number;
  rssi?: number;
  /** Human-readable detail: the forwarding reason, the role transition, ... */
  detail: string;
}

/** OGM receipt history for one (originator, neighbour) link.
 *
 *  tq is a *link* metric (docs/03 §7: "OGMs received via that neighbor / OGMs
 *  expected"), so it has to be tracked per neighbour that delivers copies of an
 *  originator's beacons, not per route entry. See `recordTqSample`. */
export interface TqWindow {
  /** Highest originator sequence number heard over this neighbour. */
  lastSeq: number;
  /** Ring buffer of 1 (heard) / 0 (missed) OGM receipts, newest last. */
  window: number[];
}

export interface NextHopEntry {
  bestNeighbor: NodeId;
  /** Transmit quality, sliding-window ratio of received/expected OGMs
   *  (docs/03 §7: window of 32). */
  tq: number;
  lastSeq: number;
  hopCount: number;
  /** Simulation time (ms) of the last OGM heard for this originator. */
  lastSeen: number;
  /** Ring buffer of 1/0 OGM receipts over the last `tqWindow` intervals. */
  window: number[];
  /** Neighbour the window belongs to; a change of relay resets the window. */
  windowNeighbor: NodeId;
}

export interface QueuedMessage {
  msg: MeshMessage;
  /** Simulation time (ms) at which the message was queued. */
  createdAt: number;
  copyCount: number;
  ttlMs: number;
}

/** Outcome of one link-layer transmission, for the PDR feedback loop. */
export interface TxWindow {
  outcomes: number[]; // 1 = acked, 0 = lost
  cursor: number;
  filled: number;
}

export interface MeshNode {
  id: NodeId;
  name: string;
  pos: Vec2;
  battery: number;
  charging: boolean;
  uptimeMin: number;
  /** 0 = stationary, 1 = sprinting (docs/03 §3). */
  mobility: number;
  /** Packet delivery ratio over the last 20 transmissions. */
  pdr: number;
  role: Role;
  score: number;
  seq: number;
  peerCount: number;
  avgRssi: number;
  isOnline: boolean;
  /** Human-readable explanation of the last role decision, for the UI. */
  reasonTrace: string;
  ogmTable: Record<string, OGM>;
  nextHopTable: Record<string, NextHopEntry>;
  /** `"originator|neighbour"` -> receipt history behind that link's tq. */
  tqWindows: Map<string, TqWindow>;
  neighborScores: Record<string, number>;
  /** msgId -> simulation time first heard. */
  seenCache: Map<string, number>;
  /** msgIds for which a SUPER retransmission was overheard (MPR suppression). */
  mprHeardSuper: Set<string>;
  /** msgId -> the neighbours actually heard retransmitting it. Coverage evidence. */
  heardRelays: Map<string, Set<string>>;
  /** neighbour id -> that neighbour's advertised 1-hop list (2-hop view). */
  twoHopView: Record<string, NodeId[]>;
  /** Minimal relay set covering this node's 2-hop neighbourhood (docs/03 §1). */
  mprSet: NodeId[];
  /** This node's own 1-hop neighbours, sorted; advertised in its OGM. */
  peerIds: NodeId[];
  /** User declined the router role. skills/02 acceptance: "SUPER opt-out
   *  respected"; the roadmap's risk table puts it the other way round ("SUPER
   *  opt-in"). Either way the node must never be promoted while it is set. */
  superOptOut: boolean;
  /** OS battery-saver mode. skills/02 acceptance: "NORMAL never auto-promoted
   *  if battery saver on". */
  batterySaver: boolean;
  /** Phase offset inside the duty cycle, spread by node index so a crowd does
   *  not sleep in lockstep. Derived from the index rather than drawn from the
   *  RNG: the draw order is part of the cross-language contract. */
  dutyPhaseMs: number;
  /** Battery level when metrics were last cleared — the baseline for measured
   *  %/h telemetry (skills/07: "Battery %/h per role"). */
  batteryAtMeasure: number;
  oppQueue: QueuedMessage[];
  /** Group history this node holds, per group id then per message id. Union-merged
   *  by anti-entropy; see `HistoryEntry`. */
  history: Map<string, Map<string, HistoryEntry>>;
  inbox: MeshMessage[];
  sentLog: MeshMessage[];
  txPower: number;
  stationary: boolean;
  demoteCounter: number;
  wasSuper: boolean;

  // --- simulation bookkeeping -------------------------------------------------
  /** Where this node belongs (its cluster centre or spawn point). */
  home: Vec2;
  /** Current waypoint the node is walking towards. */
  target: Vec2;
  /** How far from `home` it is willing to wander, in metres. */
  wanderRadius: number;
  /** Simulation time of this node's last physics integration. */
  lastPhysicsAt: number;
  /** Simulation time of this node's next OGM. */
  nextOgmAt: number;
  /** Simulation time of this node's next peer scan. */
  nextScanAt: number;
  /** Link-layer transmission outcomes (PDR window). */
  tx: TxWindow;
  /** Number of role transitions, for the flapping metric (skills/02). */
  roleTransitions: number;
  /** Packets this node transmitted (relay overhead numerator). */
  txCount: number;
  /** Flood retransmissions this node suppressed thanks to MPR. */
  mprSuppressed: number;
  /** Simulation time at which the node went offline (for battery metrics). */
  offlineAt: number;
}
