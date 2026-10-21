/// Discrete-event mesh simulation, mirroring `src/simulation.ts`.
///
/// Time is virtual (`now`), so TTLs, the 300 ms MPR wait, OGM expiry and latency
/// are all real protocol durations instead of wall-clock artefacts. Nothing in
/// here touches wall-clock time or an unseeded random source, which is what makes
/// a CI run reproduce a field test exactly.
library;

import 'dart:math' as math;

import 'election.dart';
import 'events.dart';
import 'rf.dart';
import 'rng.dart';
import 'routing.dart';
import 'types.dart';

/// A waypoint cluster: where a crowd actually stands (skills/08).
class SpawnCluster {
  const SpawnCluster(this.cx, this.cy, this.radius, this.count, this.label);

  final double cx;
  final double cy;
  final double radius;
  final int count;
  final String label;
}

class SimConfig {
  const SimConfig({
    this.seed = 42,
    this.areaWidth = 100,
    this.areaHeight = 100,
    this.nodeCount = 20,
    this.clusters = const <SpawnCluster>[],
    this.stationaryRatio = 0.5,
    this.chargingRatio = 0.15,
    this.obstacles = const <Obstacle>[
      Obstacle(8, 8, 18, 13, 'Block A'),
      Obstacle(74, 70, 18, 14, 'Block B'),
    ],
    this.tickIntervalMs = 1000,
    this.physicsIntervalMs = 250,
    this.ogmIntervalMs = 2000,
    this.ogmJitterMs = 200,
    this.ogmTtl = 5,
    this.electionIntervalMs = 30000,
    this.scanIntervalSuperMs = 250,
    this.scanIntervalNormalMs = 1000,
    this.dutyCycleEnabled = false,
    this.normalScanWindowMs = 3000,
    this.normalScanCycleMs = 10000,
    this.sleepDrainFactor = 0.25,
    this.captureLog = false,
    this.captureOgm = false,
    this.maxLogEntries = 2000,
    this.sosTtl = 5,
    this.sosRepeatMs = 5000,
    this.sosRepeats = 3,
    this.enableSuperElection = true,
    this.enableMobility = true,
    this.enableDtn = true,
    this.relayPolicy = RelayPolicy.mpr,
    this.hopLatencyBleMs = 120,
    this.hopLatencyWifiMs = 40,
    this.jitterMinMs = 50,
    this.jitterMaxMs = 200,
    this.mprWaitMs = mprWaitDefaultMs,
    this.ackTimeoutMs = 4000,
    this.maxRetries = 2,
    this.txPowerDbm = defaultTxPowerDbm,
    this.rxSensitivityDbm = defaultRxSensitivityDbm,
    this.wallPenaltyDb = defaultWallPenaltyDb,
    this.linkRetries = 2,
    this.batteryDrainMultiplier = 1,
    this.warmupMs = 8000,
    this.trafficIntervalMs = 0,
  });

  /// PRNG seed — the whole run is a pure function of it.
  final int seed;

  /// Test area in metres (skills/08 specifies a 100x100 m area).
  final double areaWidth;
  final double areaHeight;
  final int nodeCount;

  /// Optional waypoint clusters. When set, nodes spawn inside these discs
  /// (round-robin by index) instead of uniformly across the area — real crowds
  /// cluster, and clustering is what produces stable router candidates.
  final List<SpawnCluster> clusters;
  final double stationaryRatio;
  final double chargingRatio;
  final List<Obstacle> obstacles;

  final double tickIntervalMs;
  final double physicsIntervalMs;
  final double ogmIntervalMs;
  final double ogmJitterMs;
  final int ogmTtl;
  final double electionIntervalMs;
  final double scanIntervalSuperMs;
  final double scanIntervalNormalMs;

  /// skills/07 duty cycling — "NORMAL `scan 3s/sleep 7s`, SUPER `continuous`".
  /// Off by default: it changes when discovery happens, so turning it on is a
  /// different experiment (docs/06 §7).
  final bool dutyCycleEnabled;
  final double normalScanWindowMs;
  final double normalScanCycleMs;

  /// Scanner-off battery drain as a fraction of the awake rate.
  final double sleepDrainFactor;

  /// Record the pcap-like mesh log ([MeshSimulation.log]). Off by default: a
  /// 60-node crowd emits hundreds of thousands of events and the golden runs pay
  /// for none of it. Hop traces on delivered messages are always recorded — they
  /// are bounded by the path length and are what the UI's "via 2 nodes" reads.
  final bool captureLog;

  /// Also log OGM beacons. Separate flag because beacons outnumber everything.
  final bool captureOgm;

  /// Ring-buffer depth for [MeshSimulation.log].
  final int maxLogEntries;

  /// docs/05 §"Broadcast SOS | All transports, flood (TTL=5)". TTL sets the
  /// *radius* an SOS can reach: a deployment wider than this many hops leaves the
  /// far side unheard, and repeating cannot fix that (see docs/06 §11).
  final int sosTtl;

  /// Gap between the repeated SOS floods.
  final double sosRepeatMs;

  /// How many times the originator re-floods after the first. `0` reduces SOS to a
  /// single broadcast, which is the arm the repeat mechanism is measured against.
  final int sosRepeats;

  final bool enableSuperElection;
  final bool enableMobility;
  final bool enableDtn;

  /// [RelayPolicy.mpr] ships; the other two are the A/B baselines.
  final RelayPolicy relayPolicy;

  final double hopLatencyBleMs;
  final double hopLatencyWifiMs;
  final double jitterMinMs;
  final double jitterMaxMs;
  final double mprWaitMs;

  /// Source retransmission when no ACK returns (docs/03 §6 "ACK via reverse
  /// path"). 0 disables retries.
  final double ackTimeoutMs;
  final int maxRetries;

  final double txPowerDbm;
  final double rxSensitivityDbm;
  final double wallPenaltyDb;

  /// Link-layer retransmissions before a failure is reported upwards.
  final int linkRetries;
  final double batteryDrainMultiplier;

  /// Simulated time spent settling before metrics start counting.
  final double warmupMs;

  /// Inject random traffic every N ms (0 = off).
  final double trafficIntervalMs;

  SimConfig copyWith({
    int? seed,
    double? areaWidth,
    double? areaHeight,
    int? nodeCount,
    List<SpawnCluster>? clusters,
    double? stationaryRatio,
    double? chargingRatio,
    List<Obstacle>? obstacles,
    RelayPolicy? relayPolicy,
    bool? enableSuperElection,
    bool? enableMobility,
    bool? enableDtn,
    double? batteryDrainMultiplier,
    bool? dutyCycleEnabled,
    double? normalScanWindowMs,
    double? normalScanCycleMs,
    double? sleepDrainFactor,
    bool? captureLog,
    bool? captureOgm,
    int? maxLogEntries,
    int? sosTtl,
    double? sosRepeatMs,
    int? sosRepeats,
    double? warmupMs,
    int? maxRetries,
    double? ackTimeoutMs,
    double? wallPenaltyDb,
  }) =>
      SimConfig(
        seed: seed ?? this.seed,
        areaWidth: areaWidth ?? this.areaWidth,
        areaHeight: areaHeight ?? this.areaHeight,
        nodeCount: nodeCount ?? this.nodeCount,
        clusters: clusters ?? this.clusters,
        stationaryRatio: stationaryRatio ?? this.stationaryRatio,
        chargingRatio: chargingRatio ?? this.chargingRatio,
        obstacles: obstacles ?? this.obstacles,
        tickIntervalMs: tickIntervalMs,
        physicsIntervalMs: physicsIntervalMs,
        ogmIntervalMs: ogmIntervalMs,
        ogmJitterMs: ogmJitterMs,
        ogmTtl: ogmTtl,
        electionIntervalMs: electionIntervalMs,
        scanIntervalSuperMs: scanIntervalSuperMs,
        scanIntervalNormalMs: scanIntervalNormalMs,
        enableSuperElection: enableSuperElection ?? this.enableSuperElection,
        enableMobility: enableMobility ?? this.enableMobility,
        enableDtn: enableDtn ?? this.enableDtn,
        relayPolicy: relayPolicy ?? this.relayPolicy,
        hopLatencyBleMs: hopLatencyBleMs,
        hopLatencyWifiMs: hopLatencyWifiMs,
        jitterMinMs: jitterMinMs,
        jitterMaxMs: jitterMaxMs,
        mprWaitMs: mprWaitMs,
        ackTimeoutMs: ackTimeoutMs ?? this.ackTimeoutMs,
        maxRetries: maxRetries ?? this.maxRetries,
        txPowerDbm: txPowerDbm,
        rxSensitivityDbm: rxSensitivityDbm,
        wallPenaltyDb: wallPenaltyDb ?? this.wallPenaltyDb,
        linkRetries: linkRetries,
        batteryDrainMultiplier:
            batteryDrainMultiplier ?? this.batteryDrainMultiplier,
        dutyCycleEnabled: dutyCycleEnabled ?? this.dutyCycleEnabled,
        normalScanWindowMs: normalScanWindowMs ?? this.normalScanWindowMs,
        normalScanCycleMs: normalScanCycleMs ?? this.normalScanCycleMs,
        sleepDrainFactor: sleepDrainFactor ?? this.sleepDrainFactor,
        captureLog: captureLog ?? this.captureLog,
        captureOgm: captureOgm ?? this.captureOgm,
        maxLogEntries: maxLogEntries ?? this.maxLogEntries,
        sosTtl: sosTtl ?? this.sosTtl,
        sosRepeatMs: sosRepeatMs ?? this.sosRepeatMs,
        sosRepeats: sosRepeats ?? this.sosRepeats,
        warmupMs: warmupMs ?? this.warmupMs,
        trafficIntervalMs: trafficIntervalMs,
      );

  RfParams get rf => RfParams(
        txPowerDbm: txPowerDbm,
        rxSensitivityDbm: rxSensitivityDbm,
        wallPenaltyDb: wallPenaltyDb,
        obstacles: obstacles,
      );
}

const SimConfig defaultConfig = SimConfig();

class SimulationStats {
  const SimulationStats({
    required this.tick,
    required this.simTimeMs,
    required this.onlineNodes,
    required this.superNodes,
    required this.superRatio,
    required this.avgScore,
    required this.avgBattery,
    required this.totalDelivered,
    required this.totalForwarded,
    required this.totalQueued,
    required this.deliveryRatio,
    required this.broadcastReach,
    required this.overheadRatio,
    required this.avgLatencyMs,
    required this.p50LatencyMs,
    required this.p95LatencyMs,
    required this.avgHops,
    required this.avgPeers,
    required this.isolatedNodes,
    required this.lostTransmissions,
    required this.lostOgmTransmissions,
    required this.mprSuppressed,
    required this.roleChangesPerNodeMin,
    required this.electionsPerMin,
    required this.controlOverhead,
    required this.retriesSent,
    required this.retriesExhausted,
    required this.acksReceived,
    required this.sentUnicast,
    required this.sentBroadcast,
    required this.sosFloods,
    required this.batteryPercentPerHourNormal,
    required this.batteryPercentPerHourSuper,
    required this.scansPerSec,
    required this.relaysPerSec,
    required this.scansSkippedAsleep,
    required this.awakeRatio,
    required this.electionEvents,
    required this.latencyByHop,
  });

  final int tick;

  /// Virtual clock in ms — everything reported is derived from this.
  final double simTimeMs;
  final int onlineNodes;
  final int superNodes;
  final double superRatio;
  final double avgScore;
  final double avgBattery;
  final int totalDelivered;
  final int totalForwarded;
  final int totalQueued;
  final double deliveryRatio;
  final double broadcastReach;

  /// skills/08: overhead = relays / delivered.
  final double overheadRatio;
  final double avgLatencyMs;

  /// skills/08: "latencyP50/P95" per run.
  final double p50LatencyMs;
  final double p95LatencyMs;
  final double avgHops;

  /// Mean peer count — the connectivity health of the simulated world.
  final double avgPeers;

  /// Nodes that can hear nobody: the failure mode that made the original
  /// prototype useless (11-18 of 20 nodes isolated).
  final int isolatedNodes;
  final int lostTransmissions;
  final int lostOgmTransmissions;
  final int mprSuppressed;
  final double roleChangesPerNodeMin;

  /// skills/08: "superStability (elections/min)".
  final double electionsPerMin;
  final int controlOverhead;
  final int retriesSent;
  final int retriesExhausted;
  final int acksReceived;
  final int sentUnicast;
  final int sentBroadcast;

  /// SOS floods actually put on air, repeats included (docs/05 §SOS mode).
  final int sosFloods;

  /// skills/07 telemetry: "Battery %/h per role, scans/sec, relays/sec".
  /// Measured from the battery snapshot taken when metrics were cleared, over
  /// nodes that are online, in that role and not charging.
  final double batteryPercentPerHourNormal;
  final double batteryPercentPerHourSuper;
  final double scansPerSec;
  final double relaysPerSec;

  /// Scans a duty-cycling node skipped because its scanner was asleep.
  final int scansSkippedAsleep;

  /// Fraction of online non-SUPER nodes inside their wake window (1 when duty
  /// cycling is off).
  final double awakeRatio;

  /// Election log depth — skills/02: "DO log `electionEvents` for tuner".
  final int electionEvents;

  /// roadmap Phase 2 metrics dashboard: "latency by hop". First-attempt routed
  /// unicast only, matching the docs/04 §5 budget's scope.
  final List<LatencyByHop> latencyByHop;

  Map<String, Object?> toJson() => <String, Object?>{
        'tick': tick,
        'simTimeMs': simTimeMs,
        'onlineNodes': onlineNodes,
        'superNodes': superNodes,
        'superRatio': superRatio,
        'avgScore': avgScore,
        'avgBattery': avgBattery,
        'totalDelivered': totalDelivered,
        'totalForwarded': totalForwarded,
        'totalQueued': totalQueued,
        'deliveryRatio': deliveryRatio,
        'broadcastReach': broadcastReach,
        'overheadRatio': overheadRatio,
        'avgLatencyMs': avgLatencyMs,
        'p50LatencyMs': p50LatencyMs,
        'p95LatencyMs': p95LatencyMs,
        'avgHops': avgHops,
        'avgPeers': avgPeers,
        'isolatedNodes': isolatedNodes,
        'lostTransmissions': lostTransmissions,
        'lostOgmTransmissions': lostOgmTransmissions,
        'mprSuppressed': mprSuppressed,
        'roleChangesPerNodeMin': roleChangesPerNodeMin,
        'electionsPerMin': electionsPerMin,
        'controlOverhead': controlOverhead,
        'retriesSent': retriesSent,
        'retriesExhausted': retriesExhausted,
        'acksReceived': acksReceived,
        'sentUnicast': sentUnicast,
        'sentBroadcast': sentBroadcast,
        'batteryPercentPerHourNormal': batteryPercentPerHourNormal,
        'batteryPercentPerHourSuper': batteryPercentPerHourSuper,
        'scansPerSec': scansPerSec,
        'relaysPerSec': relaysPerSec,
        'scansSkippedAsleep': scansSkippedAsleep,
        'awakeRatio': awakeRatio,
        'electionEvents': electionEvents,
        'latencyByHop': latencyByHop.map((b) => b.toJson()).toList(),
      };
}

/// Latency distribution for one hop count.
class LatencyByHop {
  const LatencyByHop({
    required this.hops,
    required this.count,
    required this.avgMs,
    required this.p95Ms,
  });

  final int hops;
  final int count;
  final double avgMs;
  final double p95Ms;

  Map<String, Object?> toJson() => <String, Object?>{
        'hops': hops,
        'count': count,
        'avgMs': avgMs,
        'p95Ms': p95Ms,
      };
}

class DeliveryRecord {
  DeliveryRecord({
    required this.msgId,
    required this.from,
    required this.to,
    required this.type,
    required this.hops,
    required this.latencyMs,
    required this.path,
    required this.timestamp,
    required this.dtn,
    required this.attempt,
    required this.hopTrace,
  });

  final MsgId msgId;
  final NodeId from;
  final NodeId to;
  final MsgType type;
  final int hops;
  final double latencyMs;
  final List<NodeId> path;
  final double timestamp;

  /// True if the message reached its destination via store-carry-forward.
  final bool dtn;

  /// 0 for a first-attempt delivery.
  final int attempt;

  /// The journey behind [path]: time, link budget and decision per hop
  /// (roadmap Phase 4, "via 2 nodes • SUPER Amir").
  final List<HopRecord> hopTrace;
}

/// How a forwarding decision shows up in a message's hop trace.
/// [ForwardMode.waitMpr] is provisional: if the 300 ms wait ends in suppression,
/// `_onMprDecide` rewrites the record so the trace reports the outcome, not the
/// intention.
const Map<ForwardMode, HopAction> hopActionByMode = <ForwardMode, HopAction>{
  ForwardMode.direct: HopAction.relayed,
  ForwardMode.route: HopAction.relayed,
  ForwardMode.flood: HopAction.relayed,
  ForwardMode.waitMpr: HopAction.relayed,
  ForwardMode.queue: HopAction.queued,
  ForwardMode.drop: HopAction.suppressed,
};

/// The chain of nodes a delivered copy actually travelled, recovered by walking
/// [HopRecord.via] backwards from the recipient.
///
/// `path` (and therefore `hopTrace`) is every node that accepted a fresh copy —
/// a *tree* once a relay fans out, so a 4-hop delivery in a 20-node mesh can list
/// 15 nodes. The roadmap's "via 2 nodes • SUPER Amir" wants the route, not the
/// tree, and `via` is enough to recover it. The originator is not in the result
/// (it never receives its own message): prepend `delivery.from` when rendering.
/// A retransmission shares the message id and so the same trace, in which case
/// the first record for each node wins.
List<HopRecord> deliveredChain(List<HopRecord> hopTrace, NodeId to) {
  final firstAt = <NodeId, HopRecord>{};
  for (final h in hopTrace) {
    firstAt.putIfAbsent(h.nodeId, () => h);
  }
  final chain = <HopRecord>[];
  final seen = <NodeId>{};
  var cur = firstAt[to];
  while (cur != null && !seen.contains(cur.nodeId)) {
    seen.add(cur.nodeId);
    chain.insert(0, cur);
    cur = firstAt[cur.via];
  }
  return chain;
}

class SentRecord {
  SentRecord({
    required this.msgId,
    required this.from,
    required this.to,
    required this.type,
    required this.body,
    required this.timestamp,
    this.sosId,
  });

  final MsgId msgId;
  final NodeId from;
  final String to;
  final MsgType type;
  final String body;
  final double timestamp;

  /// Set on every SOS flood of one emergency, so a UI can collapse the repeats
  /// into a single alert exactly as a receiver's inbox does.
  final String? sosId;
  bool delivered = false;
  int recipients = 0;
}

class RoleEvent {
  const RoleEvent(this.at, this.nodeId, this.from, this.to, this.reason);

  final double at;
  final NodeId nodeId;
  final Role from;
  final Role to;
  final String reason;
}

const List<String> _names = <String>[
  'Amir', 'Bianca', 'Cristi', 'Daria', 'Emir', 'Florin', 'Gabi', 'Hana',
  'Igor', 'Jana', 'Kemal', 'Lena', 'Marcu', 'Nadia', 'Ovidiu', 'Petra',
  'Radu', 'Sara', 'Tudor', 'Ulla', 'Vlad', 'Wanda', 'Xenia', 'Yusuf',
];

const int pdrWindow = 20;

/// Node construction draws from the PRNG in a fixed order. That order is part of
/// the cross-language contract with `src/simulation.ts` — changing it invalidates
/// the golden vectors.
MeshNode createNode(
  NodeId id,
  int index,
  Rng rng,
  SimConfig config,
  SpawnCluster? spawn,
) {
  final name = _names[index % _names.length];
  final stationary = chance(rng, config.stationaryRatio);
  final charging = chance(rng, config.chargingRatio);

  // Spawn inside the area but never inside a building. The rejection loop keeps
  // the draw order byte-identical to the TypeScript engine.
  Vec2 draw() {
    if (spawn != null) {
      final angle = rng() * math.pi * 2;
      final rad = spawn.radius * math.sqrt(rng());
      return Vec2(spawn.cx + math.cos(angle) * rad, spawn.cy + math.sin(angle) * rad);
    }
    return Vec2(4 + rng() * (config.areaWidth - 8), 4 + rng() * (config.areaHeight - 8));
  }

  var pos = draw();
  for (var attempt = 0;
      attempt < 16 && insideAnyObstacle(pos, config.obstacles);
      attempt++) {
    pos = draw();
  }
  final x = math.max(2.0, math.min(config.areaWidth - 2, pos.x));
  final y = math.max(2.0, math.min(config.areaHeight - 2, pos.y));
  final battery = 0.5 + rng() * 0.5;
  // A real handset has been up for hours before it joins a mesh. Starting at
  // 0-30 min meant the documented stability term min(uptimeMin/60, 1) could
  // never saturate during a short run, quietly starving the coverage score.
  final uptimeMin = 30 + rng() * 330;
  final wander = 0.2 + rng() * 0.6;
  final pdr = 0.8 + rng() * 0.2;
  final wanderRadius = spawn != null
      ? spawn.radius
      : math.min(config.areaWidth, config.areaHeight) / 4;
  final targetAngle = rng() * math.pi * 2;
  final targetRad = wanderRadius * math.sqrt(rng());

  final node = MeshNode(
    id: id,
    name: '$name-$index',
    pos: Vec2(x, y),
    battery: battery,
    charging: charging,
    uptimeMin: uptimeMin,
    mobility: stationary ? 0 : wander,
    pdr: pdr,
    stationary: stationary,
    home: Vec2(x, y),
    target: Vec2(
      math.max(2.0, math.min(config.areaWidth - 2, x + math.cos(targetAngle) * targetRad)),
      math.max(2.0, math.min(config.areaHeight - 2, y + math.sin(targetAngle) * targetRad)),
    ),
    wanderRadius: wanderRadius,
    txPower: config.txPowerDbm,
  );
  // Spread duty phases evenly over the cycle by index, so a crowd does not sleep
  // in lockstep. Derived, never drawn: the RNG draw order is a contract.
  node.dutyPhaseMs = config.nodeCount > 0
      ? (index % config.nodeCount) *
          (config.normalScanCycleMs / config.nodeCount)
      : 0.0;
  node.batteryAtMeasure = node.battery;
  return node;
}

/// Assign each node index to a cluster, round-robin over the declared counts.
SpawnCluster? clusterForIndex(SimConfig config, int index) {
  if (config.clusters.isEmpty) return null;
  var cursor = 0;
  for (final c in config.clusters) {
    if (index < cursor + c.count) return c;
    cursor += c.count;
  }
  // Indices past the declared cluster sizes fall back to the largest cluster.
  var biggest = config.clusters.first;
  for (final c in config.clusters) {
    if (c.count > biggest.count) biggest = c;
  }
  return biggest;
}

List<MeshNode> createNodes(Rng rng, SimConfig config) {
  final nodes = <MeshNode>[];
  for (var i = 0; i < config.nodeCount; i++) {
    nodes.add(createNode('node-$i', i, rng, config, clusterForIndex(config, i)));
  }
  return nodes;
}

double percentile(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final idx = math.min(
      sorted.length - 1, math.max(0, ((p / 100) * sorted.length).ceil() - 1));
  return sorted[idx];
}

class _MsgPayload {
  const _MsgPayload(this.msg, this.via);

  final MeshMessage msg;
  final NodeId via;
}

class _PathTrace {
  _PathTrace(this.path, this.createdAt, this.from, this.to, this.type);

  final List<NodeId> path;

  /// One record per node that accepted a fresh copy, in arrival order. Parallel
  /// to [path] but carrying time, link budget and the forwarding decision.
  final List<HopRecord> hops = <HopRecord>[];
  final double createdAt;
  final NodeId from;
  final String to;
  final MsgType type;
}

class _SosRepeatPayload {
  _SosRepeatPayload(this.sosId, this.body, this.repeat);

  final String sosId;
  final String body;
  final int repeat;
}

class _PendingAck {
  _PendingAck(this.msg, this.from, this.attempts);

  final MeshMessage msg;
  final NodeId from;
  int attempts;
}

class MeshSimulation {
  MeshSimulation([SimConfig config = defaultConfig])
      : config = config,
        rng = createRng(config.seed),
        rf = config.rf {
    // `nodes` is built from the *same* stream as every later draw, so the spawn
    // order is part of the cross-language determinism contract.
    nodes = createNodes(rng, this.config);
    _schedule();
    runFor(this.config.warmupMs);
    clearRecords();
    stats = _computeStats();
  }

  late List<MeshNode> nodes;
  SimConfig config;
  RfParams rf;
  Rng rng;
  double now = 0;
  int tick = 0;
  late SimulationStats stats;
  List<DeliveryRecord> deliveries = <DeliveryRecord>[];
  List<SentRecord> sentRecords = <SentRecord>[];
  List<RoleEvent> roleEvents = <RoleEvent>[];

  final EventQueue _queue = EventQueue();
  int _msgCounter = 0;
  final Map<String, _PathTrace> _traces = <String, _PathTrace>{};

  /// Logical msgId -> the originator still waiting for its ACK.
  final Map<String, _PendingAck> _pendingAcks = <String, _PendingAck>{};

  /// pcap-like capture of radio and protocol events. Bounded, and empty unless
  /// [SimConfig.captureLog] is set.
  final List<MeshLogEntry> log = <MeshLogEntry>[];

  // counters
  int _scanCount = 0;
  int _scansSkippedAsleep = 0;

  /// Simulation time when metrics were last cleared: the telemetry baseline.
  double _measureStartMs = 0;
  int _relayTx = 0;
  int _ogmTx = 0;
  int _lostDataTx = 0;
  int _lostOgmTx = 0;
  int _duplicateRx = 0;
  int _mprSuppressed = 0;
  int _broadcastReceipts = 0;
  int _sentUnicast = 0;
  int _sentBroadcast = 0;
  int _sosFloods = 0;
  int _superSamples = 0;
  double _superSampleSum = 0;
  int _retriesSent = 0;
  int _retriesExhausted = 0;
  int _acksReceived = 0;

  // --- lifecycle -------------------------------------------------------------

  void _schedule() {
    _queue.clear();
    _queue.push(config.physicsIntervalMs, EventKind.physics, '*');
    if (config.enableSuperElection) {
      _queue.push(config.electionIntervalMs, EventKind.election, '*');
    }
    for (final node in nodes) {
      final stagger = randRange(rng, 0, config.ogmIntervalMs);
      _queue.push(stagger, EventKind.ogm, node.id);
      _queue.push(stagger / 2, EventKind.scan, node.id);
    }
    if (config.trafficIntervalMs > 0) {
      _queue.push(config.trafficIntervalMs, EventKind.traffic, '*');
    }
  }

  /// Re-baseline the measurement window: drop the accumulated records and
  /// snapshot every node's battery and the clock now, so the stats that follow
  /// describe only what happens after this call. The warm-up path uses it to
  /// discard bootstrap churn; a caller can use it to measure a settled window
  /// (roles promoted at the first election otherwise bleed their pre-promotion
  /// drain into a per-role %/h average).
  void clearRecords() {
    log.clear();
    deliveries = <DeliveryRecord>[];
    sentRecords = <SentRecord>[];
    roleEvents = <RoleEvent>[];
    _traces.clear();
    _relayTx = 0;
    _ogmTx = 0;
    _lostDataTx = 0;
    _lostOgmTx = 0;
    _duplicateRx = 0;
    _mprSuppressed = 0;
    _broadcastReceipts = 0;
    _sentUnicast = 0;
    _sentBroadcast = 0;
    _sosFloods = 0;
    _superSamples = 0;
    _superSampleSum = 0;
    _retriesSent = 0;
    _retriesExhausted = 0;
    _acksReceived = 0;
    _scanCount = 0;
    _scansSkippedAsleep = 0;
    _measureStartMs = now;
    _pendingAcks.clear();
    for (final n in nodes) {
      n.batteryAtMeasure = n.battery;
      n.roleTransitions = 0;
      n.txCount = 0;
      n.mprSuppressed = 0;
      n.inbox.clear();
      n.oppQueue.clear();
      n.sentLog.clear();
    }
  }

  /// Advance the virtual clock by [ms], running every event that comes due.
  void runFor(double ms) {
    final target = now + ms;
    while (true) {
      final ev = _queue.peek();
      if (ev == null || ev.at > target) break;
      _queue.pop();
      now = ev.at;
      _handleEvent(ev.kind, ev.nodeId, ev.payload);
    }
    now = target;
  }

  /// One tick (the CLI/UI equivalent of a frame).
  void step() {
    runFor(config.tickIntervalMs);
    tick++;
    stats = _computeStats();
  }

  void runTicks(int n) {
    for (var i = 0; i < n; i++) {
      runFor(config.tickIntervalMs);
    }
    tick += n;
    stats = _computeStats();
  }

  void reset([SimConfig? config]) {
    if (config != null) this.config = config;
    rng = createRng(this.config.seed);
    rf = this.config.rf;
    nodes = createNodes(rng, this.config);
    now = 0;
    tick = 0;
    _msgCounter = 0;
    _schedule();
    runFor(this.config.warmupMs);
    clearRecords();
    stats = _computeStats();
  }

  // --- events ----------------------------------------------------------------

  void _handleEvent(EventKind kind, String nodeId, Object? payload) {
    switch (kind) {
      case EventKind.physics:
        _onPhysics();
        break;
      case EventKind.ogm:
        _onOgm(nodeId);
        break;
      case EventKind.election:
        _onElection();
        break;
      case EventKind.scan:
        _onScan(nodeId);
        break;
      case EventKind.msg:
        _onMsgReceive(nodeId, payload! as _MsgPayload);
        break;
      case EventKind.mpr:
        _onMprDecide(nodeId, payload! as MeshMessage);
        break;
      case EventKind.ackTimeout:
        _onAckTimeout(nodeId, payload! as String);
        break;
      case EventKind.sosRepeat:
        _onSosRepeat(nodeId, payload! as _SosRepeatPayload);
        break;
      case EventKind.traffic:
        _onTraffic();
        break;
    }
  }

  void _onPhysics() {
    final dtSec = config.physicsIntervalMs / 1000;
    for (final node in nodes) {
      if (!node.isOnline) continue;
      integrateMotion(node, rng, dtSec, config.areaWidth, config.areaHeight,
          config.enableMobility);
      // A duty-cycling node with its scanner off burns less: skills/07's whole
      // argument is that the sleep slot is what keeps NORMAL under 15%/8h.
      batteryDrain(
          node,
          dtSec,
          config.batteryDrainMultiplier *
              (isAwake(node) ? 1.0 : config.sleepDrainFactor));
      node.uptimeMin += dtSec / 60;
      node.lastPhysicsAt = now;
      if (node.battery <= 0) {
        node.isOnline = false;
        node.offlineAt = now;
        node.role = Role.normal;
        node.reasonTrace = 'Battery depleted';
        _queue.cancel(EventKind.ogm, node.id);
        _queue.cancel(EventKind.scan, node.id);
      }
    }
    _queue.push(now + config.physicsIntervalMs, EventKind.physics, '*');
  }

  void _onOgm(String nodeId) {
    final node = _byId(nodeId);
    if (node == null || !node.isOnline) return;
    _refreshPeerList(node);
    node.score = computeScore(node, nodes, rf);
    node.seq++;
    _beacon(node, buildOgm(node));
    final jitter = randRange(rng, -config.ogmJitterMs, config.ogmJitterMs);
    _queue.push(now + math.max(200.0, config.ogmIntervalMs + jitter),
        EventKind.ogm, nodeId);
  }

  /// Transmit an OGM to every peer, then let each peer gossip it onward.
  void _beacon(MeshNode node, Ogm ogm) {
    for (final peer in peersInRange(node, nodes, rf)) {
      _ogmTx++;
      _pushLog(
          MeshLogKind.ogm,
          node.id,
          'OGM seq ${ogm.seq} → ${peer.id} (score ${ogm.score.toStringAsFixed(2)})',
          peerId: peer.id);
      if (chance(rng, effectiveLossProbability(node, peer, rf, config.linkRetries))) {
        _lostOgmTx++;
        continue;
      }
      _acceptOgm(peer, ogm, node.id);
    }
  }

  void _acceptOgm(MeshNode receiver, Ogm ogm, NodeId via) {
    if (!receiver.isOnline) return;
    final shouldGossip = receiveOgm(receiver, ogm, via, now);
    if (!shouldGossip) return;
    final next = ogmToGossip(ogm, config.ogmTtl);
    if (next == null) return;
    for (final peer in peersInRange(receiver, nodes, rf)) {
      if (peer.id == via) continue;
      _ogmTx++;
      if (chance(rng,
          effectiveLossProbability(receiver, peer, rf, config.linkRetries))) {
        _lostOgmTx++;
        continue;
      }
      _acceptOgm(peer, next, receiver.id);
    }
  }

  /// Is this node's scanner inside its wake window?
  ///
  /// skills/07: "Duty cycle: NORMAL `scan 3s/sleep 7s`, SUPER `continuous`".
  /// Only *scanning* is affected. An asleep node keeps beaconing and keeps
  /// relaying traffic it already knows how to forward, which is the BLE
  /// asymmetry the spec describes: the advertiser stays up and the link layer
  /// schedules connection events, while the scanner is what gets throttled
  /// (Android caps it at 5 starts per 30 s). Modelling a fully off radio would
  /// also need connection-interval negotiation, which is out of scope here.
  bool isAwake(MeshNode node, [double? atMs]) {
    if (!config.dutyCycleEnabled || node.role == Role.superNode) return true;
    final t = atMs ?? now;
    final cycle = math.max(1.0, config.normalScanCycleMs);
    final phase = ((t + node.dutyPhaseMs) % cycle + cycle) % cycle;
    return phase < config.normalScanWindowMs;
  }

  /// Append one capture-log line. A no-op unless capture is on, so the default
  /// path — and every golden vector — pays nothing for the log.
  void _pushLog(MeshLogKind kind, NodeId nodeId, String detail,
      {NodeId? peerId,
      MsgId? msgId,
      MsgType? msgType,
      int? hop,
      double? rssi}) {
    if (!config.captureLog) return;
    if (kind == MeshLogKind.ogm && !config.captureOgm) return;
    log.add(MeshLogEntry(
      atMs: now,
      kind: kind,
      nodeId: nodeId,
      detail: detail,
      peerId: peerId,
      msgId: msgId,
      msgType: msgType,
      hop: hop,
      rssi: rssi,
    ));
    if (log.length > config.maxLogEntries) {
      log.removeRange(0, log.length - config.maxLogEntries);
    }
  }

  /// Score and re-elect one node, recording any transition.
  void _electOne(MeshNode node) {
    node.score = computeScore(node, nodes, rf);
    if (!config.enableSuperElection) return;
    final outcome = electRole(node, nodes, rf);
    if (outcome.role != node.role) {
      node.wasSuper = node.role == Role.superNode;
      node.roleTransitions++;
      roleEvents
          .add(RoleEvent(now, node.id, node.role, outcome.role, outcome.reason));
    }
    if (outcome.role != node.role) {
      _pushLog(MeshLogKind.election, node.id,
          '${node.name}: ${node.role.label} → ${outcome.role.label} — ${outcome.reason}');
    }
    node.role = outcome.role;
    node.reasonTrace = outcome.reason;
  }

  void _onElection() {
    for (final node in nodes) {
      if (!node.isOnline) continue;
      _electOne(node);
    }
    final online = nodes.where((n) => n.isOnline).toList();
    _superSamples++;
    _superSampleSum += online.where((n) => n.role == Role.superNode).length /
        math.max(1, online.length);
    _queue.push(now + config.electionIntervalMs, EventKind.election, '*');
  }

  void _onScan(String nodeId) {
    final node = _byId(nodeId);
    if (node == null || !node.isOnline) return;
    final interval = node.role == Role.superNode
        ? config.scanIntervalSuperMs
        : config.scanIntervalNormalMs;

    if (!isAwake(node)) {
      // Scanner off: no discovery, no OppQueue hand-off, no MPR recompute this
      // cycle. The scan event still recurs so the node picks its window back up
      // without a reschedule, and the event stream stays regular.
      _scansSkippedAsleep++;
      _queue.push(now + interval, EventKind.scan, nodeId);
      return;
    }
    _scanCount++;

    final peers = _refreshPeerList(node);
    if (peers.isNotEmpty) {
      var sum = 0.0;
      for (final p in peers) {
        sum += rssiModel(node, p, rf);
      }
      node.avgRssi = sum / peers.length;
    }
    pruneSeenCache(node, now);
    pruneStaleEntries(node, now, neighborScoreTtlMs);
    pruneOppQueue(node, now);
    node.mprSet = selectMprSet(node);

    if (config.enableDtn && node.oppQueue.isNotEmpty) {
      final scan = scanOppQueue(node, nodes, rf, now);
      for (final q in scan.deliver) {
        _transmit(node, q.msg, q.msg.to);
      }
      for (final f in scan.forward) {
        _transmit(node, f.queued.msg, f.to);
      }
      node.oppQueue
        ..clear()
        ..addAll(scan.keep);
    }

    _queue.push(now + interval, EventKind.scan, nodeId);
  }

  void _onTraffic() {
    injectRandomMessage();
    if (config.trafficIntervalMs > 0) {
      _queue.push(now + config.trafficIntervalMs, EventKind.traffic, '*');
    }
  }

  // --- sending ---------------------------------------------------------------

  /// Recompute the 1-hop neighbour list. Sorted, so OGM advertisements and the
  /// MPR set are deterministic across runs and across both language engines.
  List<MeshNode> _refreshPeerList(MeshNode node) {
    final peers = peersInRange(node, nodes, rf);
    node.peerCount = peers.length;
    node.peerIds = peers.map((p) => p.id).toList()..sort();
    return peers;
  }

  String _nextMsgId() {
    _msgCounter++;
    return 'm$_msgCounter';
  }

  MeshNode? _byId(NodeId id) {
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// Inject a user message into the mesh. Returns the message, or null.
  MeshMessage? sendMessage(
    NodeId fromId,
    String toId,
    String body, [
    MsgType type = MsgType.text,
  ]) {
    final from = _byId(fromId);
    if (from == null || !from.isOnline) return null;

    // docs/05 §"Broadcast SOS | All transports, flood (TTL=5)". Reach comes from
    // repeating the flood and, where the deployment is wider than that, from the
    // scenario's sosTtl override — see _onSosRepeat and docs/06 §11.
    final ttl = type == MsgType.sos ? config.sosTtl : 5;
    final priority = (type == MsgType.sos || type == MsgType.voice)
        ? Priority.high
        : Priority.normal;
    final msgType =
        (toId == broadcastAddress && type == MsgType.text) ? MsgType.broadcast : type;
    final isSos = msgType == MsgType.sos;
    final sosId = isSos ? 'sos-$fromId-${now.round()}' : null;
    final msg = createMessage(_nextMsgId(), now, fromId, toId, body,
        type: msgType,
        ttl: ttl,
        priority: priority,
        sosId: sosId,
        sosRepeat: isSos ? 0 : null,
        sosPos: isSos ? from.pos.clone() : null,
        transport: isSos ? TransportType.wifiDirect : null);
    if (isSos) {
      _sosFloods++;
      _pushLog(
          MeshLogKind.sos,
          fromId,
          '$sosId flood 1/${config.sosRepeats + 1} from ${from.name} at '
              '(${from.pos.x.toStringAsFixed(1)}, ${from.pos.y.toStringAsFixed(1)})',
          msgId: msg.id,
          msgType: MsgType.sos);
    }

    from.sentLog.add(msg);
    if (msgType != MsgType.ack) {
      sentRecords.add(SentRecord(
        msgId: msg.id,
        from: fromId,
        to: toId,
        type: msgType,
        body: body,
        timestamp: now,
        sosId: msg.sosId,
      ));
      if (toId == broadcastAddress) {
        _sentBroadcast++;
      } else {
        _sentUnicast++;
      }
    }
    _traces[msg.id] = _PathTrace(<NodeId>[fromId], now, fromId, toId, msgType);

    // A note to self never needs the radio: the originator ignores copies of its
    // own messages (see _onMsgReceive), so echo it straight into the inbox.
    if (toId == fromId && msgType != MsgType.ack) {
      if (deliverToInbox(from, msg)) {
        _recordDelivery(from, msg, _traces[msg.id]);
      }
      _pushLog(MeshLogKind.deliver, fromId,
          '${msg.id} kept locally — the sender is the destination',
          msgId: msg.id, msgType: msgType);
      return msg;
    }

    if (toId != broadcastAddress && msgType != MsgType.ack && config.maxRetries > 0) {
      _pendingAcks[msg.id] = _PendingAck(msg, fromId, 0);
      _queue.push(now + config.ackTimeoutMs, EventKind.ackTimeout, fromId, msg.id);
    }

    final decision = decideForward(
        from, msg, nodes, rf, config.relayPolicy);
    _applyDecision(from, msg, decision);
    if (msgType == MsgType.sos && config.sosRepeats > 0) {
      _scheduleSosRepeat(fromId, msg.sosId!, body, 1);
    }
    return msg;
  }

  /// Build one SOS flood.
  ///
  /// Wi-Fi Direct is the transport an SOS goes out on. In this model the RF budget
  /// is transport-independent, so what it buys is a third of the per-hop latency
  /// (`hopLatencyWifiMs` 40 vs `hopLatencyBleMs` 120) — and docs/02 §3.1 has the
  /// app preferring the higher-capability transport for a payload that must move.
  /// "All transports" is not modelled: one payload, one transport, one radio.
  MeshMessage _createSos(
      MeshNode from, String body, int repeat, String sosId) {
    return createMessage(_nextMsgId(), now, from.id, broadcastAddress, body,
        type: MsgType.sos,
        ttl: config.sosTtl,
        priority: Priority.high,
        sosId: sosId,
        sosRepeat: repeat,
        sosPos: from.pos.clone(),
        transport: TransportType.wifiDirect);
  }

  void _scheduleSosRepeat(NodeId nodeId, String sosId, String body, int repeat) {
    _queue.push(now + config.sosRepeatMs, EventKind.sosRepeat, nodeId,
        _SosRepeatPayload(sosId, body, repeat));
  }

  /// Repeat an SOS flood — docs/05 §"SOS mode: repeated flood of GPS + text over
  /// all transports", whose exit criterion is "SOS reaches all within TTL".
  ///
  /// Every flood is a fresh message with a fresh id: the seen-cache is keyed on the
  /// id, so a repeat that reused one would be dropped by every node that already
  /// heard it. What ties the floods together is `sosId`, which is also what
  /// receivers collapse on. Each carries the sender's position *now*, so a sender
  /// that is moving stays trackable across repeats — which is a reason to repeat
  /// beyond mere loss recovery. A node that goes offline or is switched off stops
  /// flooding: the emergency is over, or it can no longer speak.
  void _onSosRepeat(String nodeId, _SosRepeatPayload payload) {
    final node = _byId(nodeId);
    if (node == null || !node.isOnline) return;

    final msg = _createSos(node, payload.body, payload.repeat, payload.sosId);
    _sosFloods++;
    _sentBroadcast++;

    node.sentLog.add(msg);
    sentRecords.add(SentRecord(
      msgId: msg.id,
      from: nodeId,
      to: broadcastAddress,
      type: MsgType.sos,
      body: payload.body,
      timestamp: now,
      sosId: msg.sosId,
    ));
    _traces[msg.id] =
        _PathTrace(<NodeId>[nodeId], now, nodeId, broadcastAddress, MsgType.sos);
    _pushLog(
        MeshLogKind.sos,
        nodeId,
        '${payload.sosId} flood ${payload.repeat + 1}/${config.sosRepeats + 1} '
            'from ${node.name} at (${node.pos.x.toStringAsFixed(1)}, '
            '${node.pos.y.toStringAsFixed(1)})',
        msgId: msg.id,
        msgType: MsgType.sos);

    final decision =
        decideForward(node, msg, nodes, rf, config.relayPolicy);
    _applyDecision(node, msg, decision);

    if (payload.repeat < config.sosRepeats) {
      _scheduleSosRepeat(nodeId, payload.sosId, payload.body, payload.repeat + 1);
    }
  }

  /// No ACK came back, so the originator retransmits. The retry carries the same
  /// logical id but a new `attempt`, which lets it travel again through nodes
  /// that already relayed (and deduped) the first copy.
  void _onAckTimeout(String nodeId, String msgId) {
    final pending = _pendingAcks[msgId];
    if (pending == null || pending.from != nodeId) return;
    final node = _byId(nodeId);
    if (node == null || !node.isOnline) {
      _pendingAcks.remove(msgId);
      return;
    }
    if (pending.attempts >= config.maxRetries) {
      _pendingAcks.remove(msgId);
      _retriesExhausted++;
      // Last resort: carry it until a peer appears (docs/03 §8).
      if (config.enableDtn) {
        enqueueOpp(node, pending.msg, now);
        _pushLog(
            MeshLogKind.queue,
            node.id,
            '$msgId retries exhausted at ${node.name} — carrying until a peer appears (${node.oppQueue.length} held)',
            msgId: msgId,
            msgType: pending.msg.type);
      }
      return;
    }
    pending.attempts++;
    _retriesSent++;
    final retry = pending.msg.copyWith(
      attempt: pending.attempts,
      ttl: pending.msg.ttl,
      hopCount: 0,
      timestamp: now,
    );
    final decision = decideForward(
        node, retry, nodes, rf, config.relayPolicy);
    _applyDecision(node, retry, decision);
    _queue.push(now + config.ackTimeoutMs, EventKind.ackTimeout, nodeId, msgId);
  }

  /// Pick a random online pair and send a message (used by the traffic generator).
  MeshMessage? injectRandomMessage() {
    final online = nodes.where((n) => n.isOnline).toList();
    if (online.length < 2) return null;
    final from = online[(rng() * online.length).floor()];
    var to = online[(rng() * online.length).floor()];
    var guard = 0;
    while (to.id == from.id && guard++ < 32) {
      to = online[(rng() * online.length).floor()];
    }
    if (to.id == from.id) return null;
    final broadcast = chance(rng, 0.25);
    return sendMessage(
      from.id,
      broadcast ? broadcastAddress : to.id,
      broadcast ? 'ping all' : 'hey ${to.name}',
      broadcast ? MsgType.broadcast : MsgType.text,
    );
  }

  /// Send [count] messages spread evenly over [overMs] of simulated time.
  void injectTraffic(int count, double overMs) {
    final gap = overMs / math.max(1, count);
    for (var i = 0; i < count; i++) {
      _queue.push(now + gap * (i + 1), EventKind.traffic, '*');
    }
  }

  void _applyDecision(
      MeshNode node, MeshMessage msg, ForwardDecision decision) {
    switch (decision.mode) {
      case ForwardMode.direct:
      case ForwardMode.route:
      case ForwardMode.flood:
        for (final t in decision.targets) {
          _transmit(node, msg, t);
        }
        break;
      case ForwardMode.waitMpr:
        _queue.push(now + config.mprWaitMs, EventKind.mpr, node.id, msg);
        break;
      case ForwardMode.queue:
        if (config.enableDtn) {
          enqueueOpp(node, msg, now);
          _pushLog(
              MeshLogKind.queue,
              node.id,
              '${msg.id} → OppQueue at ${node.name} (${node.oppQueue.length} held)',
              msgId: msg.id,
              msgType: msg.type);
        }
        break;
      case ForwardMode.drop:
        _mprSuppressed++;
        break;
    }
  }

  void _onMprDecide(String nodeId, MeshMessage msg) {
    final node = _byId(nodeId);
    if (node == null || !node.isOnline) return;
    final decision = resolveMprWait(node, msg, nodes, rf);
    final trace = _traces[msg.id];
    HopRecord? hopRecord;
    if (trace != null) {
      for (final h in trace.hops) {
        if (h.nodeId == node.id) {
          hopRecord = h;
          break;
        }
      }
    }
    if (decision.mode == ForwardMode.drop) {
      _mprSuppressed++;
      node.mprSuppressed++;
      if (hopRecord != null) {
        hopRecord.action = HopAction.suppressed;
        hopRecord.reason = decision.reason;
      }
      _pushLog(
          MeshLogKind.decision,
          node.id,
          '${msg.id} MPR-suppressed at ${node.name} — ${decision.reason}',
          msgId: msg.id,
          msgType: msg.type,
          hop: msg.hopCount);
      return;
    }
    if (hopRecord != null) hopRecord.reason = decision.reason;
    _applyDecision(node, msg, decision);
  }

  /// One radio transmission: rolls link loss, then schedules the hop.
  void _transmit(MeshNode node, MeshMessage msg, NodeId targetId) {
    final target = _byId(targetId);
    if (target == null || !target.isOnline || target.id == node.id) return;
    node.txCount++;
    _relayTx++;
    final loss = effectiveLossProbability(node, target, rf, config.linkRetries);
    final rssi = rssiModel(node, target, rf);
    if (chance(rng, loss)) {
      _lostDataTx++;
      _recordTxOutcome(node, 0);
      _pushLog(
          MeshLogKind.loss,
          node.id,
          '${msg.id} → $targetId lost (${(loss * 100).toStringAsFixed(1)}% at ${rssi.toStringAsFixed(0)} dBm)',
          peerId: targetId,
          msgId: msg.id,
          msgType: msg.type,
          hop: msg.hopCount,
          rssi: rssi);
      return;
    }
    _recordTxOutcome(node, 1);
    _pushLog(
        MeshLogKind.tx,
        node.id,
        '${msg.id} → $targetId (${msg.type.name}, hop ${msg.hopCount}, ${rssi.toStringAsFixed(0)} dBm)',
        peerId: targetId,
        msgId: msg.id,
        msgType: msg.type,
        hop: msg.hopCount,
        rssi: rssi);
    final base = msg.transport == TransportType.wifiDirect
        ? config.hopLatencyWifiMs
        : config.hopLatencyBleMs;
    final delay = base + randRange(rng, config.jitterMinMs, config.jitterMaxMs);
    _queue.push(now + delay, EventKind.msg, targetId, _MsgPayload(msg, node.id));
  }

  void _recordTxOutcome(MeshNode node, int ok) {
    final w = node.tx;
    if (w.outcomes.length < pdrWindow) {
      w.outcomes.add(ok);
    } else {
      w.outcomes[w.cursor] = ok;
    }
    w.cursor = (w.cursor + 1) % pdrWindow;
    w.filled = math.min(pdrWindow, w.filled + 1);
    var sum = 0;
    for (final v in w.outcomes) {
      sum += v;
    }
    node.pdr = w.filled == 0 ? 0.9 : sum / w.outcomes.length;
  }

  // --- receiving -------------------------------------------------------------

  void _onMsgReceive(String nodeId, _MsgPayload payload) {
    final node = _byId(nodeId);
    if (node == null || !node.isOnline) return;
    final msg = payload.msg;
    final via = payload.via;
    final sender = _byId(via);

    // Coverage evidence for the MPR gate. Any neighbour we receive a copy from
    // already holds the message, so it never needs covering again; and that
    // neighbour's own advertised list tells us who else is reached. Recorded for
    // duplicates too, since a second relay covering a different neighbour is
    // exactly what closes a hole.
    if (sender != null) {
      final key = seenKey(msg);
      final relays = node.heardRelays.putIfAbsent(key, () => <NodeId>{});
      relays.add(sender.id);
    }

    // A node never hears its own transmission, but it does hear peers relaying it
    // back — and that copy is not news. Without this the originator would accept
    // its own broadcast as a delivery (raising its own SOS as a received alert)
    // and then re-flood it, so every returning copy triggers a fresh fan-out from
    // the source: a storm amplifier on exactly the message type that already
    // floods to every peer. Coverage evidence above is recorded either way, since
    // a neighbour relaying my message back is still a neighbour that holds it.
    final isOwn = msg.from == node.id;
    if (isOwn || isSeen(node, seenKey(msg))) {
      // A duplicate copy still carries information: it tells this node that a
      // SUPER neighbour retransmitted, which is what MPR suppression listens for.
      _duplicateRx++;
      if (sender != null && sender.role == Role.superNode) {
        node.mprHeardSuper.add(msg.id);
      }
      _pushLog(
          MeshLogKind.duplicate,
          node.id,
          isOwn
              ? '${msg.id} own message returned by $via — not re-flooded'
              : '${msg.id} duplicate from $via — already seen, not relayed',
          peerId: via,
          msgId: msg.id,
          msgType: msg.type,
          hop: msg.hopCount);
      return;
    }
    markSeen(node, seenKey(msg), now);
    if (sender != null && sender.role == Role.superNode) {
      node.mprHeardSuper.add(msg.id);
    }

    final trace = _traces[msg.id];
    // roadmap Phase 4 hop transparency: record when the copy arrived, over what
    // link budget, and — below — what this node decided to do with it. Only
    // fresh copies are traced, so a flood cannot grow the array without bound;
    // duplicates and losses live in the capture log instead.
    HopRecord? hopRecord;
    if (trace != null && !trace.path.contains(node.id)) {
      trace.path.add(node.id);
      hopRecord = HopRecord(
        nodeId: node.id,
        atMs: now,
        via: via,
        rssi: sender != null ? rssiModel(node, sender, rf) : 0.0,
        hop: msg.hopCount,
        action: HopAction.received,
      );
      trace.hops.add(hopRecord);
    }

    if (msg.to == node.id) {
      if (msg.type == MsgType.ack) {
        final ackedId = msg.body.length > 4 ? msg.body.substring(4) : '';
        _pendingAcks.remove(ackedId);
        _acksReceived++;
        _pushLog(MeshLogKind.ack, node.id, '$ackedId acknowledged',
            msgId: ackedId, peerId: via);
      }
      // Set before _recordDelivery copies the trace, so the delivered record
      // carries the final action rather than the provisional one.
      if (hopRecord != null) hopRecord.action = HopAction.delivered;
      final fresh = deliverToInbox(node, msg);
      if (fresh) _recordDelivery(node, msg, trace);
      _pushLog(
          MeshLogKind.deliver,
          node.id,
          '${msg.id} delivered to ${node.name} via $via — ${msg.hopCount + 1} hop${msg.hopCount == 0 ? '' : 's'}, ${(now - msg.timestamp).toStringAsFixed(0)} ms',
          peerId: via,
          msgId: msg.id,
          msgType: msg.type,
          hop: msg.hopCount + 1);
      if (msg.type != MsgType.ack && msg.to != broadcastAddress) {
        _sendAck(node, msg);
      }
      return;
    }

    if (msg.to == broadcastAddress) {
      final fresh = deliverToInbox(node, msg);
      if (fresh) {
        _broadcastReceipts++;
        _recordDelivery(node, msg, trace);
        _pushLog(
            MeshLogKind.deliver,
            node.id,
            '${msg.id} broadcast reached ${node.name} via $via',
            peerId: via,
            msgId: msg.id,
            msgType: msg.type,
            hop: msg.hopCount + 1);
        for (final rec in sentRecords) {
          if (rec.msgId == msg.id) {
            rec.recipients++;
            rec.delivered = true;
            break;
          }
        }
      }
    }

    if (msg.ttl <= 0) {
      if (hopRecord != null) hopRecord.action = HopAction.expired;
      _pushLog(
          MeshLogKind.decision,
          node.id,
          '${msg.id} TTL exhausted at ${node.name} — not forwarded',
          msgId: msg.id,
          msgType: msg.type,
          hop: msg.hopCount);
      return;
    }

    final forwarded = msg.copyWith(ttl: msg.ttl - 1, hopCount: msg.hopCount + 1);
    final decision = decideForward(
        node, forwarded, nodes, rf, config.relayPolicy);
    if (hopRecord != null) {
      hopRecord.action = hopActionByMode[decision.mode] ?? HopAction.received;
      hopRecord.reason = decision.reason;
    }
    _pushLog(
        MeshLogKind.decision,
        node.id,
        '${msg.id} at ${node.name}: ${decision.mode.name} — ${decision.reason}',
        msgId: msg.id,
        msgType: msg.type,
        hop: forwarded.hopCount);
    _applyDecision(node, forwarded, decision);
  }

  void _sendAck(MeshNode node, MeshMessage original) {
    final ack = createMessage(_nextMsgId(), now, node.id, original.from,
        'ACK:${original.id}',
        type: MsgType.ack, ttl: 3, priority: Priority.high);
    _traces[ack.id] =
        _PathTrace(<NodeId>[node.id], now, node.id, original.from, MsgType.ack);
    final decision = decideForward(
        node, ack, nodes, rf, config.relayPolicy);
    _applyDecision(node, ack, decision);
  }

  void _recordDelivery(MeshNode node, MeshMessage msg, _PathTrace? trace) {
    final createdAt = trace != null ? trace.createdAt : msg.timestamp;
    deliveries.add(DeliveryRecord(
      msgId: msg.id,
      from: msg.from,
      to: node.id,
      type: msg.type,
      // Radio hops traversed: a direct transmission is 1 hop, so the documented
      // "<2 s 1 hop / <5 s 3 hops" budget is comparable.
      hops: msg.hopCount + 1,
      latencyMs: math.max(0.0, now - createdAt),
      path: trace != null ? List<NodeId>.of(trace.path) : <NodeId>[node.id],
      timestamp: now,
      attempt: msg.attempt,
      dtn: msg.carried,
      hopTrace: trace != null ? List<HopRecord>.of(trace.hops) : <HopRecord>[],
    ));
    if (deliveries.length > 5000) deliveries.removeAt(0);
    for (final rec in sentRecords) {
      if (rec.msgId == msg.id) {
        rec.delivered = true;
        break;
      }
    }
  }

  // --- manual controls -------------------------------------------------------

  void toggleNodeOnline(NodeId id) {
    final node = _byId(id);
    if (node == null) return;
    node.isOnline = !node.isOnline;
    if (!node.isOnline) {
      node.role = Role.normal;
      node.reasonTrace = 'Offline';
      node.offlineAt = now;
      _queue.cancel(EventKind.ogm, node.id);
      _queue.cancel(EventKind.scan, node.id);
    } else {
      node.battery = math.max(node.battery, 0.3);
      node.uptimeMin = 0;
      node.offlineAt = -1;
      node.reasonTrace = 'Reconnected';
      _queue.push(now + 100, EventKind.ogm, node.id);
      _queue.push(now + 100, EventKind.scan, node.id);
    }
    stats = _computeStats();
  }

  /// skills/02: "SUPER opt-out respected". Re-elects immediately, so the opt-out
  /// takes effect now instead of at the next 30 s tick.
  void setSuperOptOut(NodeId id, bool optedOut) {
    final node = _byId(id);
    if (node == null) return;
    node.superOptOut = optedOut;
    if (node.isOnline) _electOne(node);
    stats = _computeStats();
  }

  /// skills/02: "NORMAL never auto-promoted if battery saver on".
  void setBatterySaver(NodeId id, bool on) {
    final node = _byId(id);
    if (node == null) return;
    node.batterySaver = on;
    if (node.isOnline) _electOne(node);
    stats = _computeStats();
  }

  void setNodeCharging(NodeId id, bool charging) {
    final node = _byId(id);
    if (node == null) return;
    node.charging = charging;
    stats = _computeStats();
  }

  // --- metrics ---------------------------------------------------------------

  SimulationStats _computeStats() {
    final online = nodes.where((n) => n.isOnline).toList();
    final supers = online.where((n) => n.role == Role.superNode).toList();
    final avgScore = online.isEmpty
        ? 0.0
        : online.fold<double>(0, (s, n) => s + n.score) / online.length;
    final avgBattery = online.isEmpty
        ? 0.0
        : online.fold<double>(0, (s, n) => s + n.battery) / online.length;

    final unicastDeliveries = deliveries
        .where((d) => d.type != MsgType.ack && d.type != MsgType.broadcast)
        .toList();
    final dataDeliveries = deliveries.where((d) => d.type != MsgType.ack).toList();
    final latencies = unicastDeliveries.map((d) => d.latencyMs).toList()..sort();
    final hops = unicastDeliveries.map((d) => d.hops).toList();

    final deliveryRatio =
        _sentUnicast > 0 ? unicastDeliveries.length / _sentUnicast : 0.0;
    final broadcastReach = _sentBroadcast > 0
        ? _broadcastReceipts / (_sentBroadcast * math.max(1, online.length))
        : 0.0;
    final overheadRatio =
        dataDeliveries.isNotEmpty ? _relayTx / dataDeliveries.length : 0.0;
    final avgLatencyMs = latencies.isEmpty
        ? 0.0
        : latencies.fold<double>(0, (s, v) => s + v) / latencies.length;
    final avgHops = hops.isEmpty
        ? 0.0
        : hops.fold<int>(0, (s, v) => s + v) / hops.length;

    final elapsedMin = now / 60000;
    final transitions = nodes.fold<int>(0, (s, n) => s + n.roleTransitions);
    final roleChangesPerNodeMin = (elapsedMin > 0 && nodes.isNotEmpty)
        ? transitions / nodes.length / elapsedMin
        : 0.0;

    final peerCounts = nodes.map((n) => n.peerCount).toList();
    final avgPeers = peerCounts.isEmpty
        ? 0.0
        : peerCounts.fold<int>(0, (a, b) => a + b) / peerCounts.length;

    // skills/07 telemetry, measured rather than read off the drain model so it
    // reflects the role mix, duty cycling and charging as they actually happened
    // during the window.
    final elapsedMs = math.max(1.0, now - _measureStartMs);
    final elapsedHours = elapsedMs / 3600000.0;
    final elapsedSec = elapsedMs / 1000.0;
    double drainPerHour(Role role) {
      final rates = online
          .where((n) => n.role == role && !n.charging)
          .map((n) => ((n.batteryAtMeasure - n.battery) / elapsedHours) * 100)
          // A node that charged and later unplugged shows a net gain. That is not
          // a drain rate, so it drops out instead of pulling the mean down.
          .where((v) => v > 0)
          .toList();
      if (rates.isEmpty) return 0.0;
      return rates.fold<double>(0.0, (a, b) => a + b) / rates.length;
    }

    final dutyNodes = online.where((n) => n.role != Role.superNode).toList();
    final awakeRatio = dutyNodes.isEmpty
        ? 1.0
        : dutyNodes.where(isAwake).length / dutyNodes.length;

    // roadmap Phase 2 metrics dashboard: "latency by hop". Scoped like the
    // docs/04 §5 budget — first-attempt routed unicast only — so a retry (which
    // adds a whole ACK timeout) and a DTN bundle (which measures a meeting time,
    // not transport) cannot smear the distribution.
    final perHop = <int, List<double>>{};
    for (final d in unicastDeliveries) {
      if (d.attempt != 0 || d.dtn) continue;
      perHop.putIfAbsent(d.hops, () => <double>[]).add(d.latencyMs);
    }
    final hopEntries = perHop.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final latencyByHop = hopEntries.map((e) {
      final sorted = e.value.toList()..sort();
      return LatencyByHop(
        hops: e.key,
        count: sorted.length,
        avgMs: sorted.fold<double>(0.0, (a, b) => a + b) / sorted.length,
        p95Ms: percentile(sorted, 95.0),
      );
    }).toList();

    return SimulationStats(
      tick: tick,
      simTimeMs: now,
      onlineNodes: online.length,
      superNodes: supers.length,
      superRatio: online.isEmpty ? 0.0 : supers.length / online.length,
      avgScore: avgScore,
      avgBattery: avgBattery,
      totalDelivered: unicastDeliveries.length,
      totalForwarded: _relayTx,
      totalQueued: nodes.fold<int>(0, (s, n) => s + n.oppQueue.length),
      deliveryRatio: deliveryRatio,
      broadcastReach: broadcastReach,
      overheadRatio: overheadRatio,
      avgLatencyMs: avgLatencyMs,
      p50LatencyMs: percentile(latencies, 50.0),
      p95LatencyMs: percentile(latencies, 95.0),
      avgHops: avgHops,
      avgPeers: avgPeers,
      isolatedNodes: peerCounts.where((c) => c == 0).length,
      lostTransmissions: _lostDataTx,
      lostOgmTransmissions: _lostOgmTx,
      mprSuppressed: _mprSuppressed,
      roleChangesPerNodeMin: roleChangesPerNodeMin,
      electionsPerMin: roleChangesPerNodeMin,
      controlOverhead: _ogmTx,
      retriesSent: _retriesSent,
      retriesExhausted: _retriesExhausted,
      acksReceived: _acksReceived,
      sentUnicast: _sentUnicast,
      sentBroadcast: _sentBroadcast,
      sosFloods: _sosFloods,
      batteryPercentPerHourNormal: drainPerHour(Role.normal),
      batteryPercentPerHourSuper: drainPerHour(Role.superNode),
      scansPerSec: _scanCount / elapsedSec,
      relaysPerSec: _relayTx / elapsedSec,
      scansSkippedAsleep: _scansSkippedAsleep,
      awakeRatio: awakeRatio,
      electionEvents: roleEvents.length,
      latencyByHop: latencyByHop,
    );
  }

  /// Time-averaged SUPER ratio across election samples.
  double get timeAvgSuperRatio =>
      _superSamples > 0 ? _superSampleSum / _superSamples : 0;

  int get duplicateReceptions => _duplicateRx;

  SimulationStats refresh() {
    stats = _computeStats();
    return stats;
  }
}
