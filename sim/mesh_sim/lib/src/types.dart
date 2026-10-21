/// Domain types, mirroring `src/types.ts` field-for-field so the two engines
/// can be diffed line by line and share golden vectors.
library;

typedef NodeId = String;
typedef MsgId = String;

enum Role { superNode, normal }

extension RoleName on Role {
  /// Wire/UI spelling used by the docs ("SUPER" / "NORMAL").
  String get label => this == Role.superNode ? 'SUPER' : 'NORMAL';

  static Role parse(String s) => s == 'SUPER' ? Role.superNode : Role.normal;
}

enum TransportType { ble, wifiDirect, multipeer }

enum MsgType { text, broadcast, voice, sos, ack, ogm }

enum Priority { low, normal, high }

/// Relay policy for the data plane (docs/03 §6).
///
/// * [RelayPolicy.mpr] — routing plus MPR flood suppression: what ships.
/// * [RelayPolicy.routeFlood] — routing without suppression. Comparing it
///   against [RelayPolicy.mpr] isolates what MPR still buys once the route
///   table works; the two mechanisms are substitutes, so an honest overhead
///   claim needs both arms (docs/06 §6).
/// * [RelayPolicy.floodAll] — naive epidemic flooding: no route table, no
///   suppression. This is the baseline skills/02 ("overhead <=70% of
///   flood-all") and skills/08 ("overhead down 30% vs naive flood") name.
enum RelayPolicy { mpr, routeFlood, floodAll }

class Vec2 {
  Vec2(this.x, this.y);

  double x;
  double y;

  Vec2 clone() => Vec2(x, y);
}

/// Axis-aligned building. A segment crossing one loses `wallPenaltyDb` per
/// boundary crossing (docs/01 §2.1, skills/08).
class Obstacle {
  const Obstacle(this.x, this.y, this.w, this.h, this.label);

  final double x;
  final double y;
  final double w;
  final double h;
  final String label;
}

class MeshMessage {
  MeshMessage({
    required this.id,
    required this.type,
    required this.from,
    required this.to,
    required this.destHint,
    required this.body,
    required this.ttl,
    required this.timestamp,
    required this.transport,
    required this.sizeBytes,
    this.hopCount = 0,
    this.carried = false,
    this.attempt = 0,
    this.priority = Priority.normal,
    this.encrypted = true,
  });

  final MsgId id;
  final MsgType type;
  final NodeId from;

  /// Destination node id, or the literal `'BROADCAST'`.
  final String to;

  /// Truncated hash of the destination pubkey so relays can route without
  /// learning the identity (docs/04 §4).
  final String destHint;
  final String body;
  int ttl;
  int hopCount;

  /// True once held in an OppQueue awaiting a contact (docs/03 §8).
  /// Opportunistic deliveries are not latency-bounded, so the docs/04 per-hop
  /// budget must be measured on traffic that was actually routed.
  bool carried;

  /// Retransmission attempt for the same logical message. The destination dedups
  /// on `id`; intermediate nodes dedup on `id#attempt`, so a source retry is not
  /// swallowed by nodes that already relayed attempt 0.
  int attempt;
  Priority priority;

  /// Simulation time in ms — never wall-clock, so runs stay reproducible.
  double timestamp;
  bool encrypted;
  final TransportType transport;
  final int sizeBytes;

  MeshMessage copyWith({
    int? ttl,
    int? hopCount,
    int? attempt,
    bool? carried,
    double? timestamp,
    Priority? priority,
  }) =>
      MeshMessage(
        id: id,
        type: type,
        from: from,
        to: to,
        destHint: destHint,
        body: body,
        ttl: ttl ?? this.ttl,
        hopCount: hopCount ?? this.hopCount,
        carried: carried ?? this.carried,
        attempt: attempt ?? this.attempt,
        priority: priority ?? this.priority,
        timestamp: timestamp ?? this.timestamp,
        encrypted: encrypted,
        transport: transport,
        sizeBytes: sizeBytes,
      );
}

/// Originator Message — BATMAN-lite control-plane beacon (docs/03 §4).
class Ogm {
  Ogm({
    required this.nodeId,
    required this.seq,
    required this.score,
    required this.isSuper,
    required this.peerCount,
    required this.batteryBucket,
    required this.bestHopTo,
    this.hopCount = 0,
    this.neighborIds = const <NodeId>[],
    this.declinedRouter = false,
  });

  final NodeId nodeId;
  int seq;
  final double score;
  final bool isSuper;
  final int peerCount;
  final int batteryBucket;

  /// Best known hop count to other originators, gossiped so routes to
  /// non-neighbours can be learned (docs/03 §4 step 1).
  final Map<NodeId, int> bestHopTo;

  /// How many gossip hops this copy has travelled.
  int hopCount;

  /// The originator's own 1-hop neighbours, bounded and deterministically
  /// ordered. This is the OLSR HELLO payload (docs/01): without it a node cannot
  /// know whether a relay it overheard actually *covers* its own neighbours,
  /// which is the whole point of MPR selection.
  final List<NodeId> neighborIds;

  /// The originator has declined the router role — SUPER opt-out or battery
  /// saver (skills/02 acceptance). Advertised so neighbours can drop it from the
  /// top-20% candidacy ranking instead of letting a node that will never promote
  /// occupy a slot and thin the router set below the 15% floor. Without the flag
  /// the declination is only knowable locally, which a real device cannot do for
  /// its peers.
  final bool declinedRouter;

  Ogm copyWith({int? hopCount}) => Ogm(
        nodeId: nodeId,
        seq: seq,
        score: score,
        isSuper: isSuper,
        peerCount: peerCount,
        batteryBucket: batteryBucket,
        bestHopTo: Map<NodeId, int>.of(bestHopTo),
        hopCount: hopCount ?? this.hopCount,
        neighborIds: List<NodeId>.of(neighborIds),
        declinedRouter: declinedRouter,
      );
}

/// What a node did with a copy it accepted.
enum HopAction { received, delivered, relayed, suppressed, queued, expired }

/// One hop of a message's journey, recorded as a *fresh* copy arrives.
///
/// roadmap Phase 4 asks for hop transparency — "via 2 nodes • SUPER Amir" —
/// which needs more than the node list: when each hop happened, over what link
/// budget, and what the forwarding decision said. This is the record behind that
/// string.
class HopRecord {
  HopRecord({
    required this.nodeId,
    required this.atMs,
    required this.via,
    required this.rssi,
    required this.hop,
    required this.action,
    this.reason,
  });

  final NodeId nodeId;

  /// Simulation time this copy arrived.
  final double atMs;

  /// Who handed it over.
  final NodeId via;

  /// Link budget of that hand-over in dBm, from the docs/05 §1.1 model.
  final double rssi;

  /// `msg.hopCount` as it arrived: 0 for the originator's first neighbour.
  final int hop;

  /// Provisional on receipt, then set to the outcome: `wait-mpr` becomes
  /// [HopAction.suppressed] when the 300 ms wait ends that way.
  HopAction action;

  /// `decideForward`'s own words — "route via node-7", "MPR suppressed".
  String? reason;

  Map<String, Object?> toJson() => <String, Object?>{
        'nodeId': nodeId,
        'atMs': atMs,
        'via': via,
        'rssi': rssi,
        'hop': hop,
        'action': action.name,
        'reason': reason,
      };
}

/// Capture-log event kinds. [MeshLogKind.ogm] is opt-in separately: beacons
/// outnumber everything else and drown the data plane in a 60-node crowd.
enum MeshLogKind { tx, loss, duplicate, deliver, decision, queue, election, ack, ogm }

/// One line of the pcap-like mesh log: a timestamped radio or protocol event
/// with enough context to reconstruct why a message went where it did. Bounded —
/// a 60-node crowd emits hundreds of thousands of beacons — and off by default
/// so the golden runs pay nothing for it.
class MeshLogEntry {
  const MeshLogEntry({
    required this.atMs,
    required this.kind,
    required this.nodeId,
    required this.detail,
    this.peerId,
    this.msgId,
    this.msgType,
    this.hop,
    this.rssi,
  });

  final double atMs;
  final MeshLogKind kind;

  /// Who the event happened at (for [MeshLogKind.tx], the sender).
  final NodeId nodeId;

  /// The other end of the link, where there is one.
  final NodeId? peerId;
  final MsgId? msgId;
  final MsgType? msgType;
  final int? hop;
  final double? rssi;

  /// Human-readable detail: the forwarding reason, the role transition, ...
  final String detail;

  Map<String, Object?> toJson() => <String, Object?>{
        'atMs': atMs,
        'kind': kind.name,
        'nodeId': nodeId,
        'peerId': peerId,
        'msgId': msgId,
        'msgType': msgType?.name,
        'hop': hop,
        'rssi': rssi,
        'detail': detail,
      };
}

/// OGM receipt history for one (originator, neighbour) link.
///
/// tq is a *link* metric — docs/03 §7 measures "OGMs received via that neighbor
/// / OGMs expected" — so it is tracked per neighbour that delivers copies of an
/// originator's beacons, not per route entry. See [recordTqSample].
class TqWindow {
  TqWindow({required this.lastSeq, required this.window});

  /// Highest originator sequence number heard over this neighbour.
  int lastSeq;

  /// Ring buffer of 1 (heard) / 0 (missed) OGM receipts, newest last.
  List<int> window;
}

class NextHopEntry {
  NextHopEntry({
    required this.bestNeighbor,
    required this.tq,
    required this.lastSeq,
    required this.hopCount,
    required this.lastSeen,
    required this.window,
    required this.windowNeighbor,
  });

  NodeId bestNeighbor;

  /// Transmit quality: sliding-window ratio of received/expected OGMs
  /// (docs/03 §7, window of 32).
  double tq;
  int lastSeq;
  int hopCount;

  /// Simulation time (ms) of the last OGM heard for this originator.
  double lastSeen;

  /// Ring buffer of 1/0 OGM receipts over the last `tqWindow` intervals.
  List<int> window;

  /// Neighbour whose receipt window backs this entry's tq.
  NodeId windowNeighbor;
}

class QueuedMessage {
  QueuedMessage({
    required this.msg,
    required this.createdAt,
    required this.copyCount,
    required this.ttlMs,
  });

  MeshMessage msg;

  /// Simulation time (ms) at which the message was queued.
  double createdAt;
  int copyCount;
  double ttlMs;
}

/// Outcome of one link-layer transmission, for the PDR feedback loop.
class TxWindow {
  TxWindow();

  /// 1 = acked, 0 = lost.
  final List<int> outcomes = <int>[];
  int cursor = 0;
  int filled = 0;
}

class MeshNode {
  MeshNode({
    required this.id,
    required this.name,
    required this.pos,
    required this.battery,
    required this.charging,
    required this.uptimeMin,
    required this.mobility,
    required this.pdr,
    required this.stationary,
    required this.home,
    required this.target,
    required this.wanderRadius,
    required this.txPower,
  });

  final NodeId id;
  final String name;
  Vec2 pos;
  double battery;
  bool charging;
  double uptimeMin;

  /// 0 = stationary, 1 = sprinting (docs/03 §3).
  double mobility;

  /// User declined the router role. skills/02 acceptance: "SUPER opt-out
  /// respected"; the roadmap's risk table puts it the other way round ("SUPER
  /// opt-in"). Either way the node must never be promoted while it is set.
  bool superOptOut = false;

  /// OS battery-saver mode. skills/02 acceptance: "NORMAL never auto-promoted
  /// if battery saver on".
  bool batterySaver = false;

  /// Phase offset inside the duty cycle, spread by node index so a crowd does
  /// not sleep in lockstep. Derived from the index rather than drawn from the
  /// RNG: the draw order is part of the cross-language contract.
  double dutyPhaseMs = 0;

  /// Battery level when metrics were last cleared — the baseline for measured
  /// %/h telemetry (skills/07: "Battery %/h per role").
  double batteryAtMeasure = 0;

  /// Packet delivery ratio over the last 20 transmissions.
  double pdr;
  Role role = Role.normal;
  double score = 0;
  int seq = 0;
  int peerCount = 0;
  double avgRssi = -70;
  bool isOnline = true;

  /// Human-readable explanation of the last role decision.
  String reasonTrace = 'Initial';
  final Map<NodeId, Ogm> ogmTable = <NodeId, Ogm>{};
  final Map<NodeId, NextHopEntry> nextHopTable = <NodeId, NextHopEntry>{};

  /// `'originator|neighbour'` -> receipt history behind that link's tq.
  /// Insertion order is significant: `pruneStaleEntries` evicts the oldest when
  /// the bound is hit, and JS Maps iterate in insertion order too, so both
  /// engines evict identically.
  final Map<String, TqWindow> tqWindows = <String, TqWindow>{};
  final Map<NodeId, double> neighborScores = <NodeId, double>{};

  /// seenKey -> simulation time first heard.
  final Map<String, double> seenCache = <String, double>{};

  /// msgIds for which a SUPER retransmission was overheard (MPR suppression).
  final Set<String> mprHeardSuper = <String>{};

  /// seenKey -> the neighbours we heard the message from. Coverage evidence for
  /// the MPR gate: a neighbour we received a copy from already holds it, and its
  /// advertised list tells us who else is reached.
  final Map<String, Set<NodeId>> heardRelays = <String, Set<NodeId>>{};

  /// neighbour id -> that neighbour's advertised 1-hop list (2-hop view).
  final Map<NodeId, List<NodeId>> twoHopView = <NodeId, List<NodeId>>{};

  /// Minimal relay set covering this node's 2-hop neighbourhood (docs/03 §1).
  List<NodeId> mprSet = <NodeId>[];

  /// This node's own 1-hop neighbours, sorted; advertised in its OGM.
  List<NodeId> peerIds = <NodeId>[];
  final List<QueuedMessage> oppQueue = <QueuedMessage>[];
  final List<MeshMessage> inbox = <MeshMessage>[];
  final List<MeshMessage> sentLog = <MeshMessage>[];
  final double txPower;
  final bool stationary;
  int demoteCounter = 0;
  bool wasSuper = false;

  // --- simulation bookkeeping ------------------------------------------------
  /// Where this node belongs (its cluster centre or spawn point).
  final Vec2 home;

  /// Current waypoint the node is walking towards.
  Vec2 target;

  /// How far from `home` it is willing to wander, in metres.
  final double wanderRadius;

  double lastPhysicsAt = 0;
  double nextOgmAt = 0;
  double nextScanAt = 0;
  final TxWindow tx = TxWindow();

  /// Number of role transitions, for the flapping metric (skills/02).
  int roleTransitions = 0;

  /// Packets this node transmitted (relay overhead numerator).
  int txCount = 0;

  /// Flood retransmissions this node suppressed thanks to MPR.
  int mprSuppressed = 0;

  /// Simulation time at which the node went offline (-1 while online).
  double offlineAt = -1;
}
