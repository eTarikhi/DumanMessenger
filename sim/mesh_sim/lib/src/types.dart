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

/// Flood-suppression policy for the data plane (docs/03 §6).
enum RelayPolicy { mpr, floodAll }

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

  Ogm copyWith({int? hopCount}) => Ogm(
        nodeId: nodeId,
        seq: seq,
        score: score,
        isSuper: isSuper,
        peerCount: peerCount,
        batteryBucket: batteryBucket,
        bestHopTo: Map<NodeId, int>.of(bestHopTo),
        hopCount: hopCount ?? this.hopCount,
      );
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

  /// Neighbour the window belongs to; a change of relay resets the window.
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
  final Map<NodeId, double> neighborScores = <NodeId, double>{};

  /// seenKey -> simulation time first heard.
  final Map<String, double> seenCache = <String, double>{};

  /// msgIds for which a SUPER retransmission was overheard (MPR suppression).
  final Set<String> mprHeardSuper = <String>{};
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
