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

  final bool enableSuperElection;
  final bool enableMobility;
  final bool enableDtn;

  /// `mpr` suppresses redundant NORMAL relays; `floodAll` is the baseline.
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
}

class SentRecord {
  SentRecord({
    required this.msgId,
    required this.from,
    required this.to,
    required this.type,
    required this.body,
    required this.timestamp,
  });

  final MsgId msgId;
  final NodeId from;
  final String to;
  final MsgType type;
  final String body;
  final double timestamp;
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

  return MeshNode(
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
  final double createdAt;
  final NodeId from;
  final String to;
  final MsgType type;
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
    _clearRecords();
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

  // counters
  int _relayTx = 0;
  int _ogmTx = 0;
  int _lostDataTx = 0;
  int _lostOgmTx = 0;
  int _duplicateRx = 0;
  int _mprSuppressed = 0;
  int _broadcastReceipts = 0;
  int _sentUnicast = 0;
  int _sentBroadcast = 0;
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

  void _clearRecords() {
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
    _superSamples = 0;
    _superSampleSum = 0;
    _retriesSent = 0;
    _retriesExhausted = 0;
    _acksReceived = 0;
    _pendingAcks.clear();
    for (final n in nodes) {
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
    _clearRecords();
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
      batteryDrain(node, dtSec, config.batteryDrainMultiplier);
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
    node.peerCount = peersInRange(node, nodes, rf).length;
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

  void _onElection() {
    for (final node in nodes) {
      if (!node.isOnline) continue;
      node.score = computeScore(node, nodes, rf);
      if (!config.enableSuperElection) continue;
      final outcome = electRole(node, nodes, rf);
      if (outcome.role != node.role) {
        node.wasSuper = node.role == Role.superNode;
        node.roleTransitions++;
        roleEvents.add(
            RoleEvent(now, node.id, node.role, outcome.role, outcome.reason));
      }
      node.role = outcome.role;
      node.reasonTrace = outcome.reason;
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
    final peers = peersInRange(node, nodes, rf);
    node.peerCount = peers.length;
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

    final interval = node.role == Role.superNode
        ? config.scanIntervalSuperMs
        : config.scanIntervalNormalMs;
    _queue.push(now + interval, EventKind.scan, nodeId);
  }

  void _onTraffic() {
    injectRandomMessage();
    if (config.trafficIntervalMs > 0) {
      _queue.push(now + config.trafficIntervalMs, EventKind.traffic, '*');
    }
  }

  // --- sending ---------------------------------------------------------------

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

    final ttl = type == MsgType.sos ? 7 : 5;
    final priority = (type == MsgType.sos || type == MsgType.voice)
        ? Priority.high
        : Priority.normal;
    final msgType =
        (toId == broadcastAddress && type == MsgType.text) ? MsgType.broadcast : type;
    final msg = createMessage(_nextMsgId(), now, fromId, toId, body,
        type: msgType, ttl: ttl, priority: priority);

    from.sentLog.add(msg);
    if (msgType != MsgType.ack) {
      sentRecords.add(SentRecord(
        msgId: msg.id,
        from: fromId,
        to: toId,
        type: msgType,
        body: body,
        timestamp: now,
      ));
      if (toId == broadcastAddress) {
        _sentBroadcast++;
      } else {
        _sentUnicast++;
      }
    }
    _traces[msg.id] = _PathTrace(<NodeId>[fromId], now, fromId, toId, msgType);

    if (toId != broadcastAddress && msgType != MsgType.ack && config.maxRetries > 0) {
      _pendingAcks[msg.id] = _PendingAck(msg, fromId, 0);
      _queue.push(now + config.ackTimeoutMs, EventKind.ackTimeout, fromId, msg.id);
    }

    final decision = decideForward(
        from, msg, nodes, rf, config.relayPolicy == RelayPolicy.mpr);
    _applyDecision(from, msg, decision.mode, decision.targets);
    return msg;
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
      if (config.enableDtn) enqueueOpp(node, pending.msg, now);
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
        node, retry, nodes, rf, config.relayPolicy == RelayPolicy.mpr);
    _applyDecision(node, retry, decision.mode, decision.targets);
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
      MeshNode node, MeshMessage msg, ForwardMode mode, List<NodeId> targets) {
    switch (mode) {
      case ForwardMode.direct:
      case ForwardMode.route:
      case ForwardMode.flood:
        for (final t in targets) {
          _transmit(node, msg, t);
        }
        break;
      case ForwardMode.waitMpr:
        _queue.push(now + config.mprWaitMs, EventKind.mpr, node.id, msg);
        break;
      case ForwardMode.queue:
        if (config.enableDtn) enqueueOpp(node, msg, now);
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
    if (decision.mode == ForwardMode.drop) {
      _mprSuppressed++;
      node.mprSuppressed++;
      return;
    }
    _applyDecision(node, msg, decision.mode, decision.targets);
  }

  /// One radio transmission: rolls link loss, then schedules the hop.
  void _transmit(MeshNode node, MeshMessage msg, NodeId targetId) {
    final target = _byId(targetId);
    if (target == null || !target.isOnline || target.id == node.id) return;
    node.txCount++;
    _relayTx++;
    final loss = effectiveLossProbability(node, target, rf, config.linkRetries);
    if (chance(rng, loss)) {
      _lostDataTx++;
      _recordTxOutcome(node, 0);
      return;
    }
    _recordTxOutcome(node, 1);
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

    if (isSeen(node, seenKey(msg))) {
      // A duplicate copy still carries information: it tells this node that a
      // SUPER neighbour retransmitted, which is what MPR suppression listens for.
      _duplicateRx++;
      if (sender != null && sender.role == Role.superNode) {
        node.mprHeardSuper.add(msg.id);
      }
      return;
    }
    markSeen(node, seenKey(msg), now);
    if (sender != null && sender.role == Role.superNode) {
      node.mprHeardSuper.add(msg.id);
    }

    final trace = _traces[msg.id];
    if (trace != null && !trace.path.contains(node.id)) trace.path.add(node.id);

    if (msg.to == node.id) {
      if (msg.type == MsgType.ack) {
        final ackedId = msg.body.length > 4 ? msg.body.substring(4) : '';
        _pendingAcks.remove(ackedId);
        _acksReceived++;
      }
      final fresh = deliverToInbox(node, msg);
      if (fresh) _recordDelivery(node, msg, trace);
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
        for (final rec in sentRecords) {
          if (rec.msgId == msg.id) {
            rec.recipients++;
            rec.delivered = true;
            break;
          }
        }
      }
    }

    if (msg.ttl <= 0) return;

    final forwarded = msg.copyWith(ttl: msg.ttl - 1, hopCount: msg.hopCount + 1);
    final decision = decideForward(
        node, forwarded, nodes, rf, config.relayPolicy == RelayPolicy.mpr);
    _applyDecision(node, forwarded, decision.mode, decision.targets);
  }

  void _sendAck(MeshNode node, MeshMessage original) {
    final ack = createMessage(_nextMsgId(), now, node.id, original.from,
        'ACK:${original.id}',
        type: MsgType.ack, ttl: 3, priority: Priority.high);
    _traces[ack.id] =
        _PathTrace(<NodeId>[node.id], now, node.id, original.from, MsgType.ack);
    final decision = decideForward(
        node, ack, nodes, rf, config.relayPolicy == RelayPolicy.mpr);
    _applyDecision(node, ack, decision.mode, decision.targets);
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
