export type NodeId = string;
export type MsgId = string;

export type Role = "SUPER" | "NORMAL";
export type TransportType = "ble" | "wifiDirect" | "multipeer";

export type MsgType = "text" | "broadcast" | "voice" | "sos" | "ack" | "ogm";

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
  oppQueue: QueuedMessage[];
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
