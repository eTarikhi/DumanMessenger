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

enum MsgType {
  text,
  broadcast,
  voice,

  /// One chunk of a large transfer (docs/05 §3.2: 64 KB slices behind a
  /// sliding-window ACK).
  file,
  sos,

  /// Anti-entropy traffic for group history: a digest beacon, a request for the
  /// buckets that differ, or the entries that fill them (roadmap Phase 1: "CRDT for
  /// group/broadcast history (hash beacon anti-entropy)"). Control plane, so it is
  /// neither acknowledged nor counted as 1:1 traffic.
  sync,
  ack,
  ogm
}

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

/// How much of a radio a device has (docs/08 §12).
///
/// [ChannelAccess.free] is an infinitely wide radio: a transmission occupies no exclusive
/// resource, so two packets on air at the same instant both succeed and a 10 MB file
/// cannot cost anybody else anything. It is the default, and the model every acceptance
/// gate in skills/02 and skills/08 was written against.
///
/// [ChannelAccess.halfDuplex] is the one radio a phone actually has: packets go into a
/// bounded FIFO and on air when the radio comes free, and when the FIFO is full the newest
/// packet is dropped, because a real radio sheds load rather than promising air time it
/// does not have. Two things it still does not model, both optimistic: a busy *receiver*
/// can still take a packet (no capture effect), and packets waiting their turn do not
/// collide.
enum ChannelAccess { free, halfDuplex }

/// Which queued packet a busy radio takes next (docs/08 §12.8).
///
/// [ChannelPriority.fifo] is arrival order: simple, fair, and what a radio with no notion
/// of what it is carrying does. It ships.
///
/// [ChannelPriority.ackFirst] lets acknowledgements jump the queue. An ACK is about 100
/// bytes and it releases the next chunk of somebody's transfer, so promoting it is cheap
/// and it pays: 17% off a 2 MB transfer on one radio, 5-17% off a 10 MB file that has
/// traffic to compete with.
///
/// [ChannelPriority.byClass] is a WMM-like ranking that also puts an SOS and a voice frame
/// above a bulk chunk — TypeScript spells this `"class"`, which is a reserved word here.
/// It buys the bulk transfer another 22% and the voice nothing: a note three hops away is
/// limited by its own air time, and no queue order creates air time.
///
/// Only consulted under [ChannelAccess.halfDuplex]. With a free radio nothing waits, so
/// there is no order to choose.
enum ChannelPriority { fifo, ackFirst, byClass }

/// How the coverage score normalises a node's peer count (docs/03 §3, docs/06 §18.4).
///
/// [PeerNorm.fixed] is docs/03's constant denominator of 50 peers: `log(1+P)/log(51)`.
/// Bounded and comparable across worlds, but it saturates — a node hearing 199 peers and one
/// hearing 60 differ by 0.09 of score, so the score cannot say "dramatically better placed".
///
/// [PeerNorm.observed] normalises against the largest peer count the node has actually heard,
/// from its own count and the `peerCount` field of the OGMs in its table, so it stays
/// decentralised. Measured and not shipped: an election is a ranking and this is a level
/// change, so it lifts every open node in a neighbourhood together and the most open node in
/// the world keeps its exact rank — 7 of 13 on the campus world, 12 of 25 in the crowd —
/// while spending skills/02's SUPER-ratio margin (one seed of six lands on the 15% floor).
enum PeerNorm { fixed, observed }

/// What a receiver does when two packets arrive at once (docs/08 §12.9).
///
/// [ChannelCapture.none] is a receiver that takes everything, however busy it is. It ships,
/// and it is the second half of why this model has no contention: with no shared medium and an
/// infinitely attentive receiver, a transmission cannot harm another one.
///
/// [ChannelCapture.first] locks the receiver onto whichever packet arrived first, and loses two
/// kinds of packet: one that arrives while the receiver is locked onto another (first capture,
/// with no signal-strength comparison), and one that arrives while the receiver is itself
/// transmitting, because a half-duplex radio cannot hear over its own transmitter. Both are
/// losses rather than deferrals, which is what a collision is.
///
/// Independent of [ChannelAccess]: `first` under [ChannelAccess.free] is receiver contention
/// with no transmitter queue, which separates the two mechanisms the half-duplex model
/// conflates. Measured in docs/08 §12.9, where the receiver turns out to be where most of the
/// contention lives — 13.6 points of delivery against a transmitter queue's 4.0.
enum ChannelCapture { none, first }

/// Address of a scoped group flood. Not a node id, and deliberately distinct from
/// `broadcastAddress`: a broadcast is public by design (docs/04 §4), a group flood
/// is delivered only to members holding the current key epoch.
const String groupAddress = 'GROUP';

/// Group size limits — roadmap Phase 1: "group (3-10 members)".
const int groupMinMembers = 3;
const int groupMaxMembers = 10;

/// How a group message travels. `docs/06` §14 measures the two against each other:
/// per-member unicast is dramatically cheaper when every member is a direct peer
/// (4.0 transmissions per message against 519.6 for a scoped flood in a 60-node
/// crowd) and dramatically dearer when members are spread (3020 vs 519), and the
/// sender cannot tell which case it is in from its own routing table — so the
/// geometry-independent flood is the default.
enum GroupMode { scopedFlood, perMemberUnicast }

/// A group channel (docs/04 §4, roadmap Phase 1 and Phase 4 "Group UX").
class Group {
  Group({
    required this.id,
    required this.name,
    required this.members,
    required this.adminId,
    required this.keyEpoch,
    required this.createdAt,
  });

  final String id;
  final String name;
  final Set<NodeId> members;

  /// Only the admin may rotate the key (roadmap Phase 4: "admin rotate key").
  final NodeId adminId;

  /// Bumped on every membership change and on manual rotation.
  int keyEpoch;
  final double createdAt;
}

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
    this.sosId,
    this.sosRepeat,
    this.sosPos,
    this.groupId,
    this.groupEpoch,
    this.transferId,
    this.chunkIndex,
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

  /// Set on one chunk of a large transfer, with its position in it, so the receiver
  /// can dedupe by index and the sender can slide its window (docs/08 §3). Relays
  /// must carry both: `copyWith` does.
  final String? transferId;
  final int? chunkIndex;

  /// Stable identity of one emergency across its repeated floods. Each flood is a
  /// *new* message id — the seen-cache is keyed on the id, so a repeat that reused
  /// one would be dropped by every node that already heard it — but receivers
  /// collapse on this, so one emergency raises one alert rather than four
  /// (docs/04: the SOS channel is opt-in and must not spam).
  final String? sosId;

  /// 0-based index of this flood within the SOS.
  final int? sosRepeat;

  /// GPS fix carried by *this* flood. Repeating is what keeps it useful: a sender
  /// that is moving reports a different position in flood 3 than in flood 0, and a
  /// rescuer following the alert sees the movement.
  final Vec2? sosPos;

  /// Set on traffic addressed to a group (docs/04 §4). A scoped flood carries
  /// `to == groupAddress`; per-member unicast carries the member's id. Either way
  /// this is what keeps group traffic out of the unicast metrics.
  final String? groupId;

  /// The group's key epoch when this message was sent. A receiver that is a member
  /// but holds a different epoch cannot decrypt it — which is exactly what
  /// "groupKey rotated on member leave" (docs/04 §4) is for.
  final int? groupEpoch;

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
        // Relays must not strip these: a forwarded copy is still the same
        // emergency, and the receiver collapses on sosId.
        sosId: sosId,
        sosRepeat: sosRepeat,
        sosPos: sosPos,
        // Relays must not strip these either: a forwarded group copy is still
        // addressed to that group under that epoch.
        groupId: groupId,
        groupEpoch: groupEpoch,
        // Nor these: a relayed chunk is still one slice of the same transfer, and
        // the receiver dedupes on the index.
        transferId: transferId,
        chunkIndex: chunkIndex,
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
enum MeshLogKind {
  tx,
  loss,
  duplicate,
  deliver,
  decision,
  queue,
  election,
  ack,

  /// An SOS flood: sent, repeated, or collapsed onto an existing alert.
  sos,

  /// Group membership: created, joined, left, key rotated, or a stale epoch
  /// rejected.
  group,

  /// A large transfer: one chunk on air, a stalled window, or the whole file
  /// complete.
  transfer,

  /// One round of group-history anti-entropy: a beacon, a request, or a reply.
  sync,
  ogm
}

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

/// Buckets a group history digest is split into. Sixteen is the usual compromise
/// between beacon size and how much a reply over-sends: one differing bucket costs
/// 1/16 of the history in ids, and the beacon itself stays inside one BLE packet.
const int historyBuckets = 16;

/// Cap on the ids a request lists. Well above a bucket's share of any realistic group
/// history (400 entries over 16 buckets is 25), so it bounds the packet without ever
/// bounding the repair.
const int historyRequestMaxIds = 64;

/// One group message a node holds, kept so a peer can repair it later.
///
/// The set of these per group is a grow-only set — a G-Set CRDT — so merging two
/// nodes' histories is a union: idempotent, commutative and associative, which is what
/// lets anti-entropy run in any order, lose beacons, and still converge.
class HistoryEntry {
  HistoryEntry({
    required this.msgId,
    required this.groupId,
    required this.from,
    required this.at,
    required this.body,
    required this.epoch,
    this.synced = false,
  });

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        msgId: json['msgId'] as String,
        groupId: json['groupId'] as String,
        from: json['from'] as String,
        at: (json['at'] as num).toDouble(),
        body: json['body'] as String,
        epoch: json['epoch'] as int,
        synced: (json['synced'] as bool?) ?? false,
      );

  final String msgId;
  final String groupId;
  final NodeId from;
  final double at;
  final String body;

  /// The group's key epoch when this was sent. A rotation makes everything under an
  /// older epoch unreadable (docs/06 §14), so entries are only repairable inside the
  /// epoch they were written in.
  final int epoch;

  /// True once this copy arrived by anti-entropy rather than by the original flood.
  final bool synced;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'msgId': msgId,
        'groupId': groupId,
        'from': from,
        'at': at,
        'body': body,
        'epoch': epoch,
        'synced': synced,
      };

  HistoryEntry withSynced() => HistoryEntry(
        msgId: msgId,
        groupId: groupId,
        from: from,
        at: at,
        body: body,
        epoch: epoch,
        synced: true,
      );
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

  /// Group history this node holds, per group id then per message id. Union-merged by
  /// anti-entropy; see [HistoryEntry].
  final Map<String, Map<String, HistoryEntry>> history =
      <String, Map<String, HistoryEntry>>{};
  final List<MeshMessage> inbox = <MeshMessage>[];
  final List<MeshMessage> sentLog = <MeshMessage>[];
  final double txPower;

  /// Drawn once from `stationaryRatio` and then mutable, matching the TypeScript engine:
  /// a harness that models "this phone is sitting on a café counter" has to be able to say
  /// so, and `isCommunityRelay` reads it (docs/06 §19).
  bool stationary;
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
