import 'routing_selector.dart';
/// Discrete-event mesh simulation, mirroring `src/simulation.ts`.
///
/// Time is virtual (`now`), so TTLs, the 300 ms MPR wait, OGM expiry and latency
/// are all real protocol durations instead of wall-clock artefacts. Nothing in
/// here touches wall-clock time or an unseeded random source, which is what makes
/// a CI run reproduce a field test exactly.
library;

import 'dart:convert';
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
    this.coverTraffic = false,
    this.coverIntervalMs = 30000,
    this.radioOccupancy = RadioOccupancy.hopLatency,
    this.ogmAliasBytes = 32,
    this.connectivitySampleMs = 5000,
    this.ogmIntervalMode = OgmIntervalMode.fixed,
    this.ogmDensityReferencePeers = 10,
    this.scanIntervalMode = ScanIntervalMode.fixed,
    this.scanDensityReferencePeers = 10,
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
    this.groupMode = GroupMode.scopedFlood,
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
    this.mediaAckTimeoutMs = 600,
    this.adaptiveMediaAck = false,
    this.channelAccess = ChannelAccess.free,
    this.channelQueueDepth = 8,
    this.channelPriority = ChannelPriority.fifo,
    this.bleKbps = 80,
    this.wifiDirectKbps = 20000,
    this.transferChunkBytes = 65536,
    this.transferWindow = 4,
    this.transferStallMs = 3000,
    this.voiceKbps = 12,
    this.voiceFrameMs = 500,
    this.jitterBufferMs = 200,
    this.voiceTtl = 3,
    this.maxTransferBytes = 10 * 1048576,
    this.historyBeaconMs = 10000,
    this.historyReplyMax = 32,
    this.dtnPreferSuper = false,
    this.communityRelayQuota = 0,
    this.peerNorm = PeerNorm.fixed,
    this.channelCapture = ChannelCapture.none,
    this.channelCaptureRatioDb = 6,
    this.channelBackoff = ChannelBackoff.none,
    this.channelCwMin = 4,
    this.channelCwMax = 64,
    this.channelSlotMs = 1.0,
    this.mediaBackpressure = false,
    this.rateLimits = false,
    this.broadcastPerMinuteCap = broadcastPerMinuteCapDefault,
    this.relayPerSourcePerMinuteCap = relayPerSourcePerMinuteCapDefault,
    this.broadcastCapScope = BroadcastCapScope.superOnly,
    this.blockScope = BlockScope.delivery,
    this.communityRelayPreference = false,
    this.dtnPreferCommunity = false,
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

  /// docs/04 §5: "Mitigate traffic analysis: random jitter 50-200 ms before forwarding,
  /// dummy beacons at low rate." The jitter half ships unconditionally; this is the
  /// dummy-beacon half, off by default. A cover packet is one radio burst carrying
  /// nothing: it increments the node's `txCount`, which is what a passive observer counts,
  /// creates no routing state, delivers nothing and is never acknowledged. It models
  /// timing and count cover only — this engine gives beacons no length, so a length-based
  /// observer is out of reach here (docs/06 §23).
  final bool coverTraffic;

  /// Mean interval between a node's dummy beacons. "Low rate" is the document's word and
  /// not a number, so docs/06 §23 sweeps it instead of picking one.
  final double coverIntervalMs;

  /// How long a packet holds a radio, which is not the same question as how long it takes to
  /// arrive (docs/06 §24.5-§24.6). [RadioOccupancy.hopLatency] ships and is what every
  /// published number was measured under; [RadioOccupancy.airtime] charges only
  /// `bytes x 8 / kbps` for the whole packet. Delivery latency is unaffected either way —
  /// `airTime` keeps its hop-latency base, because that is what docs/02 §6's budget
  /// measures — and under the shipped `free`/`none` baseline nothing reads occupancy except
  /// the wake-lock accounting, so the knob moves telemetry and nothing else.
  final RadioOccupancy radioOccupancy;

  /// How many bytes one *advertised* neighbour costs on air, read only under
  /// [RadioOccupancy.airtime]. 32 ships, because that is what this engine puts in an OGM: the
  /// neighbour's X25519 public key. docs/03 §4 says a real deployment advertises 2-byte
  /// aliases instead, and §24.6 derives the difference — a fully loaded beacon is 1270 B on
  /// public keys, over the 1024 B BLE ceiling, and 130 B on aliases. Since beacon *reception*
  /// dominates demanded radio time, the encoding is a bigger lever than the beacon interval.
  /// The originator's own id stays 32 B either way.
  final int ogmAliasBytes;

  /// How often to sample the connectivity of the radio graph, in ms. 0 disables it.
  ///
  /// docs/06 §24.10 measured why this belongs in the engine rather than in a probe: a 60-node
  /// crowd splits and re-joins repeatedly inside a measurement window, so `broadcastReach` and
  /// `deliveryRatio` averaged over that window are unreadable without knowing how much of it the
  /// network was in one piece. The graph measured *after* the window cannot tell you — a
  /// partition that healed looks like a network that was never partitioned, which is exactly the
  /// mistake §24.9 made. Sampling consumes no random numbers and schedules no events, so it
  /// cannot move a golden vector or a published number.
  final double connectivitySampleMs;

  /// Whether a node beacons on the fixed interval docs/03 §4 specifies or on one derived from
  /// its peer count. Ships off, and docs/06 §24.11-§24.12 is why — which is not that it lost.
  /// Where the topology can be held equal it is cheaper and does not cost reach: with mobility
  /// off in festival_crowd it takes 44% off the demanded radio time and 44% off the beacons, and
  /// is equal or better on reach in seven of eight seeds. Delivery is not a win — better on four
  /// seeds, worse on three, level on one, and the +2.5 mean is mostly one seed. Where the
  /// topology cannot be held equal it loses or cannot be read —
  /// sparse_village pays 3.11x the airtime for 1.6 points, campus_quad 1.20x for -0.7, and the
  /// mobile crowd's two arms land in different topologies, so that pair means nothing because
  /// §24.10 shows reach tracks the topology rather than the interval. It ships off because the
  /// shipped condition is the mobile one.
  final OgmIntervalMode ogmIntervalMode;

  /// The peer count at which [OgmIntervalMode.density] reproduces [ogmIntervalMs] exactly. 10
  /// is the median peer count campus_quad produces, so the reference world is the one §4's 2 s
  /// was written against and the crowd stretches from there.
  final int ogmDensityReferencePeers;

  /// Whether a node scans on its role's fixed interval or on one scaled by its peer count at the
  /// last scan — docs/05 §1.2's adaptive-scan-interval row, documented and never built until now.
  /// Anchored so a node with [scanDensityReferencePeers] peers scans at exactly its role's
  /// configured interval, and clamped to `[base / 4, base * 4]` so a node with one peer does not
  /// stop scanning and a node in a crowd does not scan continuously. Consumes no random number, so
  /// the fixed mode's draw sequence is untouched and the golden vectors do not move.
  final ScanIntervalMode scanIntervalMode;

  /// The peer count at which [ScanIntervalMode.density] reproduces the configured interval.
  final int scanDensityReferencePeers;
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

  /// How a group message travels: one scoped flood the whole network relays and
  /// only members accept, or one routed unicast per member (docs/06 §14).
  final GroupMode groupMode;

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

  /// First retry timer for one chunk of a transfer, before any ACK has measured the
  /// path. Media cannot wait as long as text: 4 s is eight 500 ms voice frames, and
  /// one lost frame then leaves a four-second hole in the audio that a 200 ms jitter
  /// buffer cannot cover (docs/08 §5).
  final double mediaAckTimeoutMs;

  /// Grow that timer from the round trips the transfer's own ACKs report. Off by
  /// default: measured against a fixed 600 ms it wins for a voice note two hops away
  /// and loses for a file, where the window keeps the radio busy enough to inflate
  /// every round trip (docs/08 §7).
  final bool adaptiveMediaAck;

  /// How much of a radio a device has. [ChannelAccess.free] — the default, and the model
  /// every other number in this repository was measured under — gives it an infinitely
  /// wide radio. [ChannelAccess.halfDuplex] gives it the one radio a phone has, which is
  /// the mechanism that lets media actually compete with text (docs/08 §12).
  final ChannelAccess channelAccess;

  /// How many packets a node's transmitter will hold while it is busy. Bounded on
  /// purpose: an unbounded queue lets the radio commit air time arbitrarily far into the
  /// future, and the mesh then spends its whole run waiting for a horizon that keeps
  /// moving (docs/08 §12.1).
  final int channelQueueDepth;

  /// Which queued packet a busy radio takes next: arrival order (ships), acknowledgements
  /// first, or a WMM-like class ranking that also promotes an SOS and a voice frame above
  /// a bulk chunk (docs/08 §12.8).
  final ChannelPriority channelPriority;

  /// Link throughput, for the serialization time a large payload occupies the radio
  /// with. The 250x ratio is not a guess: docs/05 §3.2 puts Wi-Fi Direct at "250x
  /// faster than BLE" for images, so 80 kbit/s against 20 Mbit/s reproduces exactly
  /// that claim (docs/08 §1).
  final double bleKbps;
  final double wifiDirectKbps;

  /// Chunk size for a large transfer (docs/05 §3.2: "64 KB slices").
  final int transferChunkBytes;

  /// Chunks in flight before waiting for an ACK ("sliding-window ACK").
  final int transferWindow;

  /// How long a transfer may make no progress before the sender re-sends the chunks
  /// the receiver is still missing. Without it a chunk whose retries ran out parks in
  /// the OppQueue, the window never advances, and the transfer hangs forever — which
  /// is what "resume on reconnect" (docs/05 §3.2) has to mean in practice
  /// (docs/08 §6).
  final double transferStallMs;

  /// Opus framing for push-to-talk (docs/05 §3.3: "500 ms frames at 6-12 kbps").
  /// 12 kbps is the fastest documented rate that keeps a frame inside one BLE
  /// packet: frameBytes = voiceFrameMs x voiceKbps / 8 <= 1024 up to 16.4 kbps.
  final double voiceKbps;
  final double voiceFrameMs;

  /// Receiver buffer before playback can start (docs/05 §3.3: "jitter buffer
  /// 200 ms").
  final double jitterBufferMs;

  /// TTL for one voice chunk. skills/05 puts `VOICE_CHUNK` at `prio=high, ttl=3`: a
  /// frame that needs four hops is stale by the time it arrives, so it is not worth
  /// the radio time.
  final int voiceTtl;

  /// skills/05: "Max 10 MB". A larger send is refused rather than attempted, because
  /// on this mesh it would occupy the radio for minutes (docs/08 §8).
  final int maxTransferBytes;

  /// How often a group member offers its history digests to the co-members it can hear
  /// (roadmap Phase 1: "hash beacon anti-entropy"). 0 turns repair off, which leaves a
  /// member that missed a flood missing it forever.
  final double historyBeaconMs;

  /// Entries in one anti-entropy reply. Bounded so that repairing a long absence cannot
  /// turn into one huge transmission; the next beacon picks up the rest.
  final int historyReplyMax;

  /// skills/04: "DO prefer SUPER as bundle carrier (more storage/battery)". When a carrier
  /// has no route of its own, hand the bundle to the strongest SUPER in range instead of
  /// waiting for a route to appear. Bounded by the spray limit either way.
  ///
  /// Implemented, measured, and **off by default**: once a carried bundle is parked instead
  /// of being deleted by flood suppression, the routing layer delivers it by itself, and
  /// biasing the spray towards SUPERs duplicates copies into the busiest nodes' queues —
  /// crowd delivery falls 94.7% to 91.2% over six seeds and parked bundles grow 39 to 63
  /// per run (docs/06 §20.4). The intuition behind the rule is about who should *hold* a
  /// bundle, not about who should be handed extra copies.
  final bool dtnPreferSuper;

  /// Share of the top-20% SUPER cap reserved for community relays — plugged, stationary
  /// nodes such as a café's tablet (roadmap Phase 5). 0 disables it, which is what ships,
  /// and 1 or more exempts them from the cap entirely. Measured and rejected: a tablet
  /// that is not elected lost to other tablets, and the exemption raises everybody else's
  /// transmissions 12% while pushing the SUPER ratio to the top of skills/02's band
  /// (docs/06 §19.4).
  final double communityRelayQuota;

  /// Whether the coverage score normalises peer count against a fixed 50 (ships) or against
  /// the largest peer count this node has heard. Measured and rejected: it lifts every open
  /// node's score and changes no election (docs/06 §18.4).
  final PeerNorm peerNorm;

  /// What a receiver does when two packets arrive at once. [ChannelCapture.none] ships: a busy
  /// receiver takes everything. [ChannelCapture.first] loses the later packet, and loses any
  /// packet that arrives while its receiver is transmitting (docs/08 §12.9).
  final ChannelCapture channelCapture;

  /// How much stronger a newcomer has to be to take a busy receiver over, in dB. Only read
  /// under [ChannelCapture.strongest]. Six dB is the capture ratio usually quoted for an
  /// angle-modulated receiver; 0 dB is loudest-wins with no margin, and a large value
  /// collapses the model back onto [ChannelCapture.first].
  final double channelCaptureRatioDb;

  /// Whether a node that has been waiting for the medium waits a *random* number of slots
  /// before taking it. Carrier sense alone wakes every waiting node at the same instant the
  /// medium clears, so they transmit together; the random wait is what disperses them, and
  /// doubling the window after a collision is what stops two nodes that keep meeting from
  /// keeping meeting (docs/08 §12.13). Consulted only under [ChannelAccess.csma].
  final ChannelBackoff channelBackoff;

  /// Contention window after a clean transmission, in slots.
  final int channelCwMin;

  /// Contention window ceiling after repeated collisions, in slots.
  final int channelCwMax;

  /// How long one backoff slot lasts. 802.11's is 9 µs at 2.4 GHz; a BLE mesh has no such
  /// constant, so this is a knob rather than a calibration.
  final double channelSlotMs;

  /// Whether a transfer stops pumping chunks when its sender's radio is full. A real socket
  /// blocks; an engine that keeps handing packets to a saturated radio converts somebody
  /// else's queue slots into drops. Measured: it halves a one-peer transfer's drops and its
  /// time together, and does nothing for a mesh, because the queue that overflows in a mesh
  /// belongs to a relay (docs/08 §12.12). Off by default, and inert under
  /// [ChannelAccess.free] where nothing queues.
  final bool mediaBackpressure;

  /// Whether docs/04 §6's two abuse limits are enforced. Off by default, so a
  /// shipped run allocates no buckets and no golden vector moves.
  final bool rateLimits;

  /// docs/04 §6: "Max 5 broadcasts / minute per node; SUPERs drop excess."
  final int broadcastPerMinuteCap;

  /// docs/04 §6: "Cap relay to 30 msgs/min per source; ignore floods." Control-plane
  /// traffic is exempt — see [countsAgainstRelayCap].
  final int relayPerSourcePerMinuteCap;

  /// Who enforces the broadcast cap: SUPERs only, as docs/04 §6 says, or every node.
  final BroadcastCapScope broadcastCapScope;

  /// How far a local block reaches: delivery only, as docs/04 §6 says, or relay too.
  final BlockScope blockScope;

  /// When two relays cover the same neighbours, pick the plugged one. Off by default and
  /// measured as a null result: it moves 0.6 of 100 MPR slots in a crowd and nothing
  /// downstream, because who transmits is decided per packet from what was actually heard
  /// (docs/06 §19.5).
  final bool communityRelayPreference;

  /// Hand a parked bundle to a plugged, stationary carrier instead of a SUPER when the
  /// holder has no route of its own. Off by default and measured as a negative: parked
  /// bundles grow 27-55% for at most 0.7 extra opportunistic deliveries a run
  /// (docs/06 §19.5).
  final bool dtnPreferCommunity;
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
    GroupMode? groupMode,
    double? warmupMs,
    double? trafficIntervalMs,
    int? maxRetries,
    double? ackTimeoutMs,
    double? mediaAckTimeoutMs,
    bool? adaptiveMediaAck,
    ChannelAccess? channelAccess,
    int? channelQueueDepth,
    ChannelPriority? channelPriority,
    int? transferChunkBytes,
    int? transferWindow,
    double? transferStallMs,
    double? historyBeaconMs,
    int? historyReplyMax,
    bool? dtnPreferSuper,
    double? communityRelayQuota,
    PeerNorm? peerNorm,
    ChannelCapture? channelCapture,
    double? channelCaptureRatioDb,
    ChannelBackoff? channelBackoff,
    int? channelCwMin,
    int? channelCwMax,
    double? channelSlotMs,
    bool? mediaBackpressure,
    bool? rateLimits,
    int? broadcastPerMinuteCap,
    int? relayPerSourcePerMinuteCap,
    BroadcastCapScope? broadcastCapScope,
    BlockScope? blockScope,
    bool? coverTraffic,
    double? coverIntervalMs,
    RadioOccupancy? radioOccupancy,
    int? ogmAliasBytes,
    double? connectivitySampleMs,
    OgmIntervalMode? ogmIntervalMode,
    int? ogmDensityReferencePeers,
    ScanIntervalMode? scanIntervalMode,
    int? scanDensityReferencePeers,
    bool? communityRelayPreference,
    bool? dtnPreferCommunity,
    double? voiceKbps,
    double? voiceFrameMs,
    double? jitterBufferMs,
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
        mediaAckTimeoutMs: mediaAckTimeoutMs ?? this.mediaAckTimeoutMs,
        adaptiveMediaAck: adaptiveMediaAck ?? this.adaptiveMediaAck,
        channelAccess: channelAccess ?? this.channelAccess,
        channelQueueDepth: channelQueueDepth ?? this.channelQueueDepth,
        channelPriority: channelPriority ?? this.channelPriority,
        bleKbps: bleKbps,
        wifiDirectKbps: wifiDirectKbps,
        transferChunkBytes: transferChunkBytes ?? this.transferChunkBytes,
        transferWindow: transferWindow ?? this.transferWindow,
        transferStallMs: transferStallMs ?? this.transferStallMs,
        historyBeaconMs: historyBeaconMs ?? this.historyBeaconMs,
        historyReplyMax: historyReplyMax ?? this.historyReplyMax,
        dtnPreferSuper: dtnPreferSuper ?? this.dtnPreferSuper,
        communityRelayQuota: communityRelayQuota ?? this.communityRelayQuota,
        peerNorm: peerNorm ?? this.peerNorm,
        channelCapture: channelCapture ?? this.channelCapture,
        channelCaptureRatioDb: channelCaptureRatioDb ?? this.channelCaptureRatioDb,
        channelBackoff: channelBackoff ?? this.channelBackoff,
        channelCwMin: channelCwMin ?? this.channelCwMin,
        channelCwMax: channelCwMax ?? this.channelCwMax,
        channelSlotMs: channelSlotMs ?? this.channelSlotMs,
        mediaBackpressure: mediaBackpressure ?? this.mediaBackpressure,
        rateLimits: rateLimits ?? this.rateLimits,
        broadcastPerMinuteCap:
            broadcastPerMinuteCap ?? this.broadcastPerMinuteCap,
        relayPerSourcePerMinuteCap:
            relayPerSourcePerMinuteCap ?? this.relayPerSourcePerMinuteCap,
        broadcastCapScope: broadcastCapScope ?? this.broadcastCapScope,
        blockScope: blockScope ?? this.blockScope,
        coverTraffic: coverTraffic ?? this.coverTraffic,
        coverIntervalMs: coverIntervalMs ?? this.coverIntervalMs,
        radioOccupancy: radioOccupancy ?? this.radioOccupancy,
        ogmAliasBytes: ogmAliasBytes ?? this.ogmAliasBytes,
        connectivitySampleMs: connectivitySampleMs ?? this.connectivitySampleMs,
        ogmIntervalMode: ogmIntervalMode ?? this.ogmIntervalMode,
        ogmDensityReferencePeers:
            ogmDensityReferencePeers ?? this.ogmDensityReferencePeers,
        scanIntervalMode: scanIntervalMode ?? this.scanIntervalMode,
        scanDensityReferencePeers:
            scanDensityReferencePeers ?? this.scanDensityReferencePeers,
        communityRelayPreference:
            communityRelayPreference ?? this.communityRelayPreference,
        dtnPreferCommunity: dtnPreferCommunity ?? this.dtnPreferCommunity,
        voiceKbps: voiceKbps ?? this.voiceKbps,
        voiceFrameMs: voiceFrameMs ?? this.voiceFrameMs,
        jitterBufferMs: jitterBufferMs ?? this.jitterBufferMs,
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
        groupMode: groupMode ?? this.groupMode,
        warmupMs: warmupMs ?? this.warmupMs,
        trafficIntervalMs: trafficIntervalMs ?? this.trafficIntervalMs,
      );

  RfParams get rf => RfParams(
        txPowerDbm: txPowerDbm,
        rxSensitivityDbm: rxSensitivityDbm,
        wallPenaltyDb: wallPenaltyDb,
        obstacles: obstacles,
      );
}

const SimConfig defaultConfig = SimConfig();

// --- group history anti-entropy (roadmap Phase 1: "CRDT for group/broadcast
// --- history (hash beacon anti-entropy)") -----------------------------------

/// JavaScript's `Math.imul`, as in `rng.dart`: multiply and keep the low 32 bits.
int _imul32(int x, int y) => ((x & 0xffffffff) * (y & 0xffffffff)) & 0xffffffff;

/// FNV-1a, 32-bit, over the characters of a message id.
///
/// Not a cryptographic hash, deliberately: a digest here only has to tell two sets
/// apart, and the ids it covers are already visible to every relay on the path. Four
/// lines that behave identically in TypeScript and Dart, which is what the
/// cross-language fixed points in `test/history_test.dart` assert.
int fnv1a32(String text) {
  var h = 0x811c9dc5;
  for (var i = 0; i < text.length; i++) {
    h = _imul32(h ^ text.codeUnitAt(i), 0x01000193);
  }
  return h & 0xffffffff;
}

/// Which of the [historyBuckets] a message id falls in.
int historyBucket(String msgId) => fnv1a32(msgId) % historyBuckets;

/// The digest a node advertises for one group: one XOR-folded hash per bucket, plus a
/// count.
class HistoryDigest {
  HistoryDigest(this.count, this.buckets);

  final int count;
  final List<int> buckets;
}

/// XOR over a *set* is order-independent, so two nodes holding the same entries produce
/// the same digest whatever order they arrived in. That is what makes the merge a union
/// rather than a negotiation, and what lets a beacon be lost, duplicated or reordered
/// without the protocol caring (the G-Set property [HistoryEntry] documents).
///
/// Splitting into buckets is what keeps a repair proportional to the *difference*: a
/// node that missed two messages out of two hundred asks for one bucket, not for the
/// whole history.
HistoryDigest historyDigest(Iterable<HistoryEntry> entries) {
  final buckets = List<int>.filled(historyBuckets, 0);
  var count = 0;
  for (final e in entries) {
    final b = historyBucket(e.msgId);
    buckets[b] = (buckets[b] ^ fnv1a32(e.msgId)) & 0xffffffff;
    count++;
  }
  return HistoryDigest(count, buckets);
}

/// `HB|group|epoch|count|hexdigests` — what a beacon carries.
String encodeHistoryBeacon(String groupId, int epoch, HistoryDigest digest) {
  final hexes = digest.buckets
      .map((b) => b.toRadixString(16).padLeft(8, '0'))
      .join(',');
  return 'HB|$groupId|$epoch|${digest.count}|$hexes';
}


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
    required this.sentGroup,
    required this.groupReceipts,
    required this.groupExpected,
    required this.groupDeliveryRatio,
    required this.groupEpochRejected,
    required this.transfersStarted,
    required this.transfersCompleted,
    required this.transferStalls,
    required this.sentChunks,
    required this.bytesDelivered,
    required this.routeExpiries,
    required this.connectivitySamples,
    required this.connectedSampleShare,
    required this.meanLargestComponent,
    required this.sentSync,
    required this.coverTx,
    required this.historyBeacons,
    required this.historyRequests,
    required this.historyReplies,
    required this.historyEntriesSynced,
    required this.historyEpochDropped,
    required this.historyBytes,
    required this.bundlesPruned,
    required this.dtnSuperCarries,
    required this.dtnCommunityCarries,
    required this.channelDeferrals,
    required this.channelDeferMs,
    required this.channelDrops,
    required this.channelCaptured,
    required this.channelCaptureEffects,
    required this.channelDeafRx,
    required this.channelBackoffs,
    required this.channelDropsRelayed,
    required this.channelDropsMedia,
    required this.channelDropsWithAlternative,
    required this.transferBlocks,
    required this.rateBroadcastDrops,
    required this.rateRelayDrops,
    required this.blockedDrops,
    required this.batteryPercentPerHourNormal,
    required this.batteryPercentPerHourSuper,
    required this.scansPerSec,
    required this.relaysPerSec,
    required this.wakeLocks,
    required this.wakeLockMs,
    required this.wakeLockShareNormal,
    required this.wakeLockShareSuper,
    required this.radioDemandRatio,
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

  /// Group messages handed to the radio: 1 per send in [GroupMode.scopedFlood],
  /// one per member in [GroupMode.perMemberUnicast].
  final int sentGroup;

  /// Member deliveries of group traffic.
  final int groupReceipts;

  /// Member deliveries that should have happened: the denominator that makes
  /// [groupDeliveryRatio] comparable across the two modes.
  final int groupExpected;
  final double groupDeliveryRatio;

  /// Copies a *member* could not decrypt because the key had rotated since.
  final int groupEpochRejected;

  /// Large transfers started and finished, windows that had to be kicked, chunks put
  /// on air, and payload bytes that arrived (docs/08). Chunks are kept out of
  /// [sentUnicast]/[deliveryRatio] on purpose: one 10 MB file is 160 of them.
  final int transfersStarted;
  final int transfersCompleted;
  final int transferStalls;
  final int sentChunks;
  final int bytesDelivered;

  /// Anti-entropy (docs/06 §17): packets put on air, digest beacons, bucket requests,
  /// replies, entries recovered that way, entries a key rotation made unreadable, and
  /// the payload bytes the whole exchange occupied. Counted apart from
  /// [sentUnicast]/[deliveryRatio]: a digest is control traffic, not a message anybody
  /// sent to anybody.
  /// Route entries dropped because no beacon refreshed them inside [neighborScoreTtlMs] —
  /// the route table's churn. docs/06 §24.7 uses it to test why a 12 s beacon interval
  /// delivered worse than both 5 s and 25 s in a 60-node crowd.
  final int routeExpiries;

  /// How many times the radio graph was sampled inside the window, at
  /// [SimConfig.connectivitySampleMs]. Zero disables the metric, not the network.
  final int connectivitySamples;

  /// Fraction of those samples at which every node could reach every other. Read this beside
  /// `broadcastReach` and `deliveryRatio` in any mobile scenario: docs/06 §24.10 shows
  /// festival_crowd reaches 98% when it stays connected and 54-79% when it does not, and the
  /// two look like one bimodal metric unless this is beside them.
  final double connectedSampleShare;

  /// Mean share of the network inside the largest component across those samples. A broadcast
  /// cannot do better than this, so a reach near it is a topology result and a reach well below
  /// it is a routing one.
  final double meanLargestComponent;

  final int sentSync;

  /// Dummy beacons put on air by [SimConfig.coverTraffic] (docs/04 §5). Zero unless it is
  /// on, which is what makes the feature inert. Not included in [controlOverhead], which
  /// counts the OGMs the routing protocol needs; cover traffic is optional and its whole
  /// cost belongs in this column.
  final int coverTx;
  final int historyBeacons;
  final int historyRequests;
  final int historyReplies;
  final int historyEntriesSynced;
  final int historyEpochDropped;
  final int historyBytes;

  /// DTN (skills/04): bundles dropped because their ACK was overheard, and bundles handed
  /// to a SUPER because the carrier had no route of its own (docs/06 §20).
  final int bundlesPruned;
  final int dtnSuperCarries;

  /// Bundles handed to a community relay as carrier (`dtnPreferCommunity`, docs/06 §19.5).
  final int dtnCommunityCarries;

  /// Channel access (docs/08 §12): transmissions that had to wait for a radio, how long
  /// they waited in total, and packets a full transmit queue could not hold. All zero
  /// under the default [ChannelAccess.free], where nothing is ever occupied.
  final int channelDeferrals;
  final double channelDeferMs;
  final int channelDrops;

  /// Packets lost because the receiver was locked onto a packet that arrived first, and
  /// packets lost because the receiver was itself transmitting. Both zero under
  /// [ChannelCapture.none] (docs/08 §12.9).
  final int channelCaptured;
  final int channelDeafRx;

  /// Times a stronger newcomer took a busy receiver over from the packet it was holding,
  /// under [ChannelCapture.strongest]. Each one is also a collision loss — of the incumbent —
  /// so it is counted in [channelCaptured] too. This is the count that says how much of
  /// `first`'s pessimism the capture effect buys back: over six seeds, none of it
  /// (docs/08 §12.15).
  final int channelCaptureEffects;

  /// Contention-window draws: how often a node found the medium free and still had to wait a
  /// random number of slots for it (docs/08 §12.13). Zero unless [ChannelBackoff.binary].
  final int channelBackoffs;

  /// Where the shedding happens, which is what docs/08 §12.14 measures rather than argues.
  /// [channelDropsRelayed] counts packets shed by a node forwarding somebody else's message, so
  /// `channelDrops - channelDropsRelayed` were shed by their own originator.
  /// [channelDropsMedia] counts the shed packets that were file or voice chunks.
  /// [channelDropsWithAlternative] counts the relay sheds for which a peer in range was at least
  /// as close to the destination as the next hop chosen — the packets that could have gone round
  /// the congestion instead of into it.
  final int channelDropsRelayed;
  final int channelDropsMedia;
  final int channelDropsWithAlternative;

  /// Times a transfer was refused air by its own radio and had to wait for a slot to free. This
  /// is backpressure working, not a failure (docs/08 §12.12).
  final int transferBlocks;

  /// Broadcasts a SUPER dropped because the source exceeded docs/04 §6's 5/min.
  final int rateBroadcastDrops;

  /// Relays refused because the source exceeded docs/04 §6's 30/min.
  final int rateRelayDrops;

  /// Messages a node ignored because it had blocked the sender locally (docs/04 §6).
  /// Counted per receiving node, so one broadcast heard by four blockers is four.
  final int blockedDrops;

  /// skills/07 telemetry: "Battery %/h per role, scans/sec, relays/sec".
  /// Measured from the battery snapshot taken when metrics were cleared, over
  /// nodes that are online, in that role and not charging.
  final double batteryPercentPerHourNormal;
  final double batteryPercentPerHourSuper;
  final double scansPerSec;
  final double relaysPerSec;

  /// skills/07 telemetry, fourth item: "wake-locks". One acquisition per transmission and
  /// per reception, held for as long as that packet occupies the radio. Mirror of the
  /// TypeScript fields of the same name, including the reason these are *shares* and not
  /// percentages of wall clock — see [radioDemandRatio].
  final int wakeLocks;
  final double wakeLockMs;
  final double wakeLockShareNormal;
  final double wakeLockShareSuper;

  /// Total demanded radio time divided by the radio time that exists (`nodes × window`).
  /// Above 1 the model asks for more airtime than there is; docs/06 §24 measures roughly
  /// 3.9 on campus_quad at 20 nodes under every channel model, because a beacon is charged
  /// one `hopLatencyBleMs` at each of the peers that hear it and reception dominates the
  /// total. Transmission *counts* are exact; durations are the model's, not a device's.
  final double radioDemandRatio;

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
        'wakeLocks': wakeLocks,
        'wakeLockMs': wakeLockMs,
        'wakeLockShareNormal': wakeLockShareNormal,
        'wakeLockShareSuper': wakeLockShareSuper,
        'radioDemandRatio': radioDemandRatio,
        'scansSkippedAsleep': scansSkippedAsleep,
        'awakeRatio': awakeRatio,
        'electionEvents': electionEvents,
        // Everything above is the basic mesh readout. What follows is the rest of the
        // instrumentation this repository measures with: group traffic, transfers, history
        // anti-entropy, the DTN carry path, and the radio model of docs/08 §12. All of it was
        // declared as a field and none of it was emitted, so this serializer reported 38 of the
        // class's 70 fields.
        //
        // The CLI's `--json` is NOT what this fixes: bin/mesh_sim.dart builds its own report map,
        // rounded to 4 dp and carrying the scenario and probe sections, and it does not call
        // toJson(). This matters to a consumer that embeds the library instead — which is what
        // the Flutter app in the roadmap does, and telemetry is the first thing it will want to
        // persist. Raw values here, rounded ones there; the two are for different readers.
        //
        // All scalars, so they encode as they stand. Ordered to match the class above.
        'sosFloods': sosFloods,
        'sentGroup': sentGroup,
        'groupReceipts': groupReceipts,
        'groupExpected': groupExpected,
        'groupDeliveryRatio': groupDeliveryRatio,
        'groupEpochRejected': groupEpochRejected,
        'transfersStarted': transfersStarted,
        'transfersCompleted': transfersCompleted,
        'transferStalls': transferStalls,
        'sentChunks': sentChunks,
        'bytesDelivered': bytesDelivered,
        'routeExpiries': routeExpiries,
        'connectivitySamples': connectivitySamples,
        'connectedSampleShare': connectedSampleShare,
        'meanLargestComponent': meanLargestComponent,
        'sentSync': sentSync,
        'coverTx': coverTx,
        'historyBeacons': historyBeacons,
        'historyRequests': historyRequests,
        'historyReplies': historyReplies,
        'historyEntriesSynced': historyEntriesSynced,
        'historyEpochDropped': historyEpochDropped,
        'historyBytes': historyBytes,
        'bundlesPruned': bundlesPruned,
        'dtnSuperCarries': dtnSuperCarries,
        'dtnCommunityCarries': dtnCommunityCarries,
        'channelDeferrals': channelDeferrals,
        'channelDeferMs': channelDeferMs,
        'channelDrops': channelDrops,
        'channelCaptured': channelCaptured,
        'channelDeafRx': channelDeafRx,
        'channelCaptureEffects': channelCaptureEffects,
        'channelBackoffs': channelBackoffs,
        'channelDropsRelayed': channelDropsRelayed,
        'channelDropsMedia': channelDropsMedia,
        'channelDropsWithAlternative': channelDropsWithAlternative,
        'transferBlocks': transferBlocks,
        'rateBroadcastDrops': rateBroadcastDrops,
        'rateRelayDrops': rateRelayDrops,
        'blockedDrops': blockedDrops,
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
    this.groupId,
    this.groupEpoch,
    this.transferId,
    this.chunkIndex,
    this.retransmitted = false,
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

  /// Set on group traffic, so it can be accounted separately from 1:1.
  final String? groupId;

  /// The key epoch this copy was sent under.
  final int? groupEpoch;

  /// Set on one chunk of a large transfer, with its position in it, so arrival gaps
  /// can be measured per frame.
  final String? transferId;
  final int? chunkIndex;

  /// Whether this copy needed a retransmission to arrive.
  final bool retransmitted;
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
    this.groupId,
    this.transferId,
  });

  final MsgId msgId;
  final NodeId from;
  final String to;
  final MsgType type;
  final String body;
  final double timestamp;

  /// Set on a chunk, so a UI can show the file it belongs to rather than 160 empty
  /// messages (docs/08 §3.1).
  final String? transferId;

  /// Set on every SOS flood of one emergency, so a UI can collapse the repeats
  /// into a single alert exactly as a receiver's inbox does.
  final String? sosId;

  /// Set on group traffic, so a UI can show one card per send even in
  /// [GroupMode.perMemberUnicast], where one user action is N radio messages.
  final String? groupId;
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
  const _MsgPayload(this.msg, this.via, {this.seq});

  final MeshMessage msg;
  final NodeId via;

  /// Which *transmission* this is, not which message. A message can be on air several times
  /// over — a retry, or two relays racing with the same copy — and
  /// [ChannelCapture.strongest] has to be able to say "this one was taken over" without
  /// condemning every later attempt at the same message. Only assigned under `strongest`, so
  /// the two shipped modes never touch it.
  final int? seq;
}

/// One transmission waiting for its node's radio (docs/08 §12).
class _QueuedTx {
  const _QueuedTx(this.msg, this.targetId, this.queuedAt);

  final MeshMessage msg;
  final NodeId targetId;
  final double queuedAt;
}

/// One node's radio under [ChannelAccess.halfDuplex]: the instant it comes free again,
/// the bounded FIFO waiting for it, and whether a drain event is already scheduled for
/// it. Without that last flag a packet handed to a busy radio whose queue had just
/// drained has nothing to wake the radio up, and waits for some other transmission to
/// come along — which in a quiet mesh is never.
/// WMM-like ranking for a radio that has to choose what to send next. An SOS and a
/// push-to-talk frame have a deadline; an ACK is small and keeps somebody else's window
/// moving; a 64 KB chunk has neither property and is the only thing here that can afford
/// to wait. [MsgType.ogm] never reaches a transmit queue — control beacons have their own
/// path — and is ranked last for exhaustiveness.
const Map<MsgType, int> _channelClass = <MsgType, int>{
  MsgType.sos: 0,
  MsgType.voice: 0,
  MsgType.ack: 1,
  MsgType.text: 2,
  MsgType.broadcast: 2,
  MsgType.file: 2,
  MsgType.sync: 2,
  MsgType.ogm: 2,
};

class _ChannelState {
  _ChannelState(this.cw);

  double busyUntil = 0;
  final List<_QueuedTx> queue = <_QueuedTx>[];
  bool drainScheduled = false;

  /// Contention window this radio currently draws from, in slots. Starts at
  /// `config.channelCwMin`, doubles after a collision, resets after a clean transmission.
  int cw;

  /// Whether a slot count has already been drawn for the attempt now in progress, and how
  /// many slots of it are left to wait. Drawn once per attempt so a radio that is deferred
  /// again mid-backoff keeps the turn it already paid for.
  bool backoffArmed = false;
  int backoffSlots = 0;
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


/// What a transfer is carrying: a file chopped into chunks, or a push-to-talk note
/// streamed as Opus frames.
enum TransferKind { file, voice }

enum TransferState { active, complete }

/// One large transfer in flight (docs/05 §3.2-3.3).
///
/// Chunks are ordinary unicasts, so they inherit everything the data plane already
/// does — ACKs, retransmission, and the OppQueue as a last resort. What they need on
/// top is a window, a record of what has arrived, and a watchdog for when the window
/// stops moving.
class Transfer {
  Transfer({
    required this.id,
    required this.kind,
    required this.from,
    required this.to,
    required this.totalBytes,
    required this.chunkBytes,
    required this.chunks,
    required this.window,
    required this.startedAt,
    required this.lastProgressAt,
    required this.transport,
    this.forcedTransport,
  });

  final String id;
  final TransferKind kind;
  final NodeId from;
  final NodeId to;
  final int totalBytes;
  final int chunkBytes;
  final int chunks;

  /// Chunks that may be in flight at once: the sliding window's depth.
  final int window;
  final double startedAt;

  /// Chunks the receiver has.
  int received = 0;

  /// Chunks that took at least one retransmission to arrive.
  int retransmitted = 0;

  /// Times the window stopped moving and missing chunks had to be re-sent.
  int stalls = 0;

  /// Chunk indices the receiver has, so a retry that arrives twice is not counted.
  final Set<int> receivedChunks = <int>{};

  /// Chunk indices the sender has actually put on air. A voice note is captured in
  /// real time, so frames that have not been recorded yet are missing without being
  /// lost — and re-sending them would be meaningless.
  final Set<int> onAir = <int>{};

  /// Next chunk index the sender may put on air (the window's right edge).
  int nextToSend = 0;

  /// Simulation time the last chunk arrived: the stall watchdog's reference.
  double lastProgressAt;

  /// When the receiver got chunk 0: streaming playback can begin here.
  double? firstChunkAt;

  /// When the last chunk arrived.
  double? completedAt;

  /// For a voice note: when capture ended, i.e. when the user let go of the button.
  double? releasedAt;

  /// Round trips this transfer's own ACKs have reported. Null until the first one:
  /// [SimConfig.mediaAckTimeoutMs] covers the cold start. [minRttMs] is the one the
  /// timer is built from, because a smoothed average measures the queue the transfer
  /// is creating for itself (docs/08 §7).
  double? srttMs;
  double rttVarMs = 0.0;
  double? minRttMs;

  TransportType transport;

  /// skills/05: "Send ... via best transport (WiFi Direct if GO connected, else
  /// chunked BLE 512B MTU)". A Wi-Fi Direct group owner that is already negotiated
  /// means the radio is available whatever the payload size says, so the caller can
  /// force it; null leaves the size-based choice in [selectTransport].
  final TransportType? forcedTransport;
  TransferState state = TransferState.active;
}

/// Ties a message to one chunk of one transfer. Internal, like [_GroupCtx].
class _ChunkCtx {
  _ChunkCtx(this.transferId, this.index, this.bytes, [this.transport]);

  final String transferId;
  final int index;
  final int bytes;
  final TransportType? transport;
}

class _ChunkPayload {
  _ChunkPayload(this.transferId, this.index);

  final String transferId;
  final int index;
}

/// Ties a message to the group and key epoch it was sent under. Internal: a caller
/// passes a group id as the destination and [MeshSimulation.sendMessage] builds this.
class _GroupCtx {
  _GroupCtx(this.id, this.epoch);

  final String id;
  final int epoch;
}

class _SosRepeatPayload {
  _SosRepeatPayload(this.sosId, this.body, this.repeat);

  final String sosId;
  final String body;
  final int repeat;
}

class _PendingAck {
  _PendingAck(this.msg, this.from, this.attempts, this.sentAt);

  final MeshMessage msg;
  final NodeId from;
  int attempts;

  /// Simulation time this attempt went on air, so an ACK can report a round trip.
  final double sentAt;

  /// When the originator's own copy last actually went on air. Only maintained under a queued
  /// radio, where handing a packet over and transmitting it are different instants and a retry
  /// timer that cannot tell them apart retransmits packets that were never sent
  /// (docs/08 §12.11).
  double? onAirAt;
}

class MeshSimulation {
  MeshSimulation([SimConfig config = defaultConfig, RoutingSelectorOptions? selectorOptions, int? motionSeed])
      : _motionRng = motionSeed == null ? null : createRng(motionSeed),
        _selectorOptions = selectorOptions, config = config,
        rng = createRng(config.seed),
        rf = config.rf {
    // `nodes` is built from the *same* stream as every later draw, so the spawn
    // order is part of the cross-language determinism contract.
    nodes = createNodes(rng, this.config);
    if(selectorOptions!=null) {
      for(final n in nodes) { _routingSelectors[n.id]=RoutingSelector(selectorOptions); }
    }
    _schedule();
    runFor(this.config.warmupMs);
    clearRecords();
    stats = _computeStats();
  }

  final Rng? _motionRng;
  final RoutingSelectorOptions? _selectorOptions;
  final Map<String, RoutingSelector> _routingSelectors = {};
  final Map<String, double> _peerObservedAt = {};
  final List<SelectorDecision> selectorDiagnostics = [];
  void rollbackRoutingSelector() { for(final c in _routingSelectors.values) {c.rollback();} }
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
  int _channelDeferrals = 0;
  double _channelDeferMs = 0;
  int _channelDrops = 0;
  int _channelCaptured = 0;
  int _channelCaptureEffects = 0;
  int _channelDeafRx = 0;
  /// Per-transmission sequence, for [ChannelCapture.strongest] only. Not a random draw, so it
  /// cannot move a golden vector.
  int _txSeq = 0;
  int _channelBackoffs = 0;
  int _channelDropsRelayed = 0;
  int _channelDropsMedia = 0;
  int _channelDropsWithAlternative = 0;
  int _transferBlocks = 0;
  int _rateBroadcastDrops = 0;
  int _rateRelayDrops = 0;
  int _blockedDrops = 0;

  /// Token buckets for docs/04 §6's two caps, keyed `"enforcer|source"`. Held here
  /// rather than on `MeshNode` so the feature adds no field to the cross-language
  /// node contract: a node's identity, RNG draw order and golden-vector surface are
  /// untouched, and the state is per enforcing pair anyway.
  final Map<String, RateBucket> _rateBroadcasts = {};
  final Map<String, RateBucket> _rateRelays = {};

  /// docs/04 §6's local blocklist, keyed blocker → blocked peers. On the simulation for
  /// the same reason the rate buckets are: it adds no field to the cross-language node
  /// contract, and it is inert while empty, so a shipped run behaves identically whether
  /// or not the feature exists. Mirror of `blocked` in `src/simulation.ts`.
  final Map<NodeId, Set<NodeId>> _blocked = {};

  /// skills/07's fourth telemetry item, per node: acquisitions and milliseconds held. On
  /// the simulation rather than on `MeshNode`, so no field is added to the cross-language
  /// node contract and no golden vector moves.
  final Map<NodeId, int> _wakeLocksByNode = {};
  final Map<NodeId, double> _wakeLockMsByNode = {};

  /// Whether the transmission that just went on air collided at its receiver. Written by
  /// [_onAir], read by the contention window to decide whether to widen.
  bool _lastTxCollided = false;

  /// Until when each node is transmitting, and until when it is locked onto a reception.
  /// Maintained only while the receiver model or carrier sense is on, so the shipped model
  /// pays nothing.
  final Map<NodeId, double> _txUntil = <NodeId, double>{};
  final Map<NodeId, double> _rxUntil = <NodeId, double>{};
  final Map<NodeId, double> _rxRssi = <NodeId, double>{};
  final Map<NodeId, int> _rxSeq = <NodeId, int>{};
  final Set<int> _superseded = <int>{};

  /// One radio per node. Only maintained under [ChannelAccess.halfDuplex] — under
  /// [ChannelAccess.free] a radio is never busy, so the map stays empty.
  final Map<NodeId, _ChannelState> _channel = <NodeId, _ChannelState>{};
  int _ogmTx = 0;
  int _coverTx = 0;
  int _routeExpiries = 0;

  /// In-window connectivity sampling (docs/06 §24.10). Counters, not state: nothing here feeds
  /// back into routing, so a sample cannot change the world it is measuring.
  int _connectivitySamples = 0;
  int _connectedSamples = 0;
  double _largestComponentSum = 0;
  double _lastConnectivitySampleMs = -1;
  int _lostDataTx = 0;
  int _lostOgmTx = 0;
  int _duplicateRx = 0;
  int _mprSuppressed = 0;
  int _broadcastReceipts = 0;
  int _sentUnicast = 0;
  int _sentBroadcast = 0;
  int _sosFloods = 0;
  int _sentGroup = 0;
  int _groupReceipts = 0;
  int _groupExpected = 0;
  int _groupEpochRejected = 0;
  int _transfersStarted = 0;
  int _transfersCompleted = 0;
  int _transferStalls = 0;
  int _sentChunks = 0;
  int _bytesDelivered = 0;
  int _sentSync = 0;
  int _historyBeacons = 0;
  int _historyRequests = 0;
  int _historyReplies = 0;
  int _historyEntriesSynced = 0;
  int _historyEpochDropped = 0;
  int _historyBytes = 0;
  int _bundlesPruned = 0;
  int _dtnSuperCarries = 0;
  int _dtnCommunityCarries = 0;

  /// Nodes with a beacon chain running, so joining a second group does not start a
  /// second one (the beacon covers every group the node is in).
  final Set<NodeId> _historyBeaconArmed = <NodeId>{};
  int _transferSeq = 0;

  /// Live and finished large transfers, keyed by transfer id.
  final Map<String, Transfer> transfers = <String, Transfer>{};
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
      // Reuses the stagger already drawn for the beacon rather than drawing its own, so
      // enabling cover traffic does not shift the RNG sequence at t=0.
      if (config.coverTraffic) _queue.push(stagger, EventKind.cover, node.id);
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
    _channelDeferrals = 0;
    _channelDeferMs = 0;
    _channelDrops = 0;
    _channelCaptured = 0;
    _channelCaptureEffects = 0;
    _channelDeafRx = 0;
    _txSeq = 0;
    _superseded.clear();
    _channelBackoffs = 0;
    _channelDropsRelayed = 0;
    _channelDropsMedia = 0;
    _channelDropsWithAlternative = 0;
    _transferBlocks = 0;
    _rateBroadcastDrops = 0;
    _rateRelayDrops = 0;
    _blockedDrops = 0;
    _wakeLocksByNode.clear();
    _wakeLockMsByNode.clear();
    _rateBroadcasts.clear();
    _rateRelays.clear();
    _lastTxCollided = false;
    _channel.clear();
    _txUntil.clear();
    _rxUntil.clear();
    _rxRssi.clear();
    _rxSeq.clear();
    _ogmTx = 0;
    _coverTx = 0;
    _routeExpiries = 0;
    _connectivitySamples = 0;
    _connectedSamples = 0;
    _largestComponentSum = 0;
    // Sample from the start of the window rather than inheriting the settle period's clock, so
    // a caller that clears and then runs for 60 s gets 60 s of samples.
    _lastConnectivitySampleMs = now;
    _lostDataTx = 0;
    _lostOgmTx = 0;
    _duplicateRx = 0;
    _mprSuppressed = 0;
    _broadcastReceipts = 0;
    _sentUnicast = 0;
    _sentBroadcast = 0;
    _sosFloods = 0;
    _sentGroup = 0;
    _groupReceipts = 0;
    _groupExpected = 0;
    _groupEpochRejected = 0;
    transfers.clear();
    _transferSeq = 0;
    _transfersStarted = 0;
    _transfersCompleted = 0;
    _transferStalls = 0;
    _sentChunks = 0;
    _bytesDelivered = 0;
    _sentSync = 0;
    _historyBeacons = 0;
    _historyRequests = 0;
    _historyReplies = 0;
    _historyEntriesSynced = 0;
    _historyEpochDropped = 0;
    _historyBytes = 0;
    _bundlesPruned = 0;
    _dtnSuperCarries = 0;
    _dtnCommunityCarries = 0;
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
    // Groups belong to the world, not to the metrics window: rebuilding the mesh
    // invalidates every membership, so the registry goes with it.
    groups.clear();
    _historyBeaconArmed.clear();
    _groupSeq = 0;
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
      case EventKind.cover:
        _onCover(nodeId);
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
      case EventKind.channel: {
        final node = _byId(nodeId);
        if (node != null && node.isOnline) {
          final ch = _channel[node.id];
          if (ch != null) ch.drainScheduled = false;
          _drainChannel(node);
        }
        break;
      }
      case EventKind.mpr:
        _onMprDecide(nodeId, payload! as MeshMessage);
        break;
      case EventKind.ackTimeout:
        _onAckTimeout(nodeId, payload! as String);
        break;
      case EventKind.sosRepeat:
        _onSosRepeat(nodeId, payload! as _SosRepeatPayload);
        break;
      case EventKind.transferChunk:
        final chunk = payload! as _ChunkPayload;
        final transfer = transfers[chunk.transferId];
        final sender = _byId(nodeId);
        if (transfer != null &&
            transfer.state == TransferState.active &&
            sender != null &&
            sender.isOnline) {
          _sendChunk(transfer, chunk.index);
        }
        break;
      case EventKind.transferStall:
        _onTransferStall(nodeId, (payload! as _ChunkPayload).transferId);
        break;
      case EventKind.historyBeacon:
        _onHistoryBeacon(nodeId);
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
      integrateMotion(node, _motionRng ?? rng, dtSec, config.areaWidth, config.areaHeight,
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
        _queue.cancel(EventKind.cover, node.id);
        _queue.cancel(EventKind.scan, node.id);
        // A dead radio is an idle radio: whatever it had committed to is gone, and a node
        // that comes back must not inherit a busy transmitter.
        _channel.remove(node.id);
        _queue.cancel(EventKind.channel, node.id);
        _txUntil.remove(node.id);
        _rxUntil.remove(node.id);
        _rxRssi.remove(node.id);
        _rxSeq.remove(node.id);
      }
    }
    // Sampled here rather than from its own event: a queue entry would carry a sequence number,
    // and two events at the same instant are ordered by it, so adding one could reorder
    // unrelated events. This consumes no random number and schedules nothing, so a published
    // number and a golden vector are both untouched by it.
    _sampleConnectivity();
    _queue.push(now + config.physicsIntervalMs, EventKind.physics, '*');
  }

  void _onOgm(String nodeId) {
    final node = _byId(nodeId);
    if (node == null || !node.isOnline) return;
    _refreshPeerList(node);
    node.score = computeScore(node, nodes, rf, _observedPeerMax(node));
    node.seq++;
    _beacon(node, buildOgm(node));
    final jitter = randRange(rng, -config.ogmJitterMs, config.ogmJitterMs);
    _queue.push(now + math.max(200.0, _ogmIntervalFor(node) + jitter),
        EventKind.ogm, nodeId);
  }

  /// Put one dummy beacon on air (docs/04 §5, "dummy beacons at low rate").
  ///
  /// The point of cover traffic is that an observer cannot tell it from the real thing, so
  /// it is counted exactly where a real transmission is counted — [MeshNode.txCount] — and
  /// nowhere else. It does not enter the message path: no routing state, no delivery, no
  /// ACK. Returning early when the knob is off keeps the reschedule from happening, so a
  /// disabled run pushes no event and spends no draw.
  void _onCover(String nodeId) {
    if (!config.coverTraffic) return;
    final node = _byId(nodeId);
    if (node == null || !node.isOnline) return;
    node.txCount++;
    _coverTx++;
    _pushLog(MeshLogKind.ogm, node.id, 'dummy beacon (cover traffic) → peers in range');
    final jitter = randRange(rng, -config.ogmJitterMs, config.ogmJitterMs);
    _queue.push(now + math.max(200.0, config.coverIntervalMs + jitter),
        EventKind.cover, nodeId);
  }

  /// The interval before this node's next scan, under [SimConfig.scanIntervalMode] — docs/05
  /// §1.2's adaptive-scan-interval row. Scaled from the peer count the *previous* scan found,
  /// because a node cannot know how dense its neighbourhood is before it looks, which is why the
  /// clamp matters: a node that has just moved into a crowd scans at its old, longer interval for
  /// one cycle, and a node just left alone scans at its old, shorter one.
  double _scanIntervalFor(MeshNode node) {
    final base = node.role == Role.superNode
        ? config.scanIntervalSuperMs
        : config.scanIntervalNormalMs;
    if (config.scanIntervalMode == ScanIntervalMode.fixed) return base;
    final peers = math.max(1, node.peerIds.length);
    final reference = math.max(1, config.scanDensityReferencePeers);
    // Inverse of the beacon rule: dense scans sooner, sparse scans later.
    final raw = (base * reference) / peers;
    return math.min(base * 4, math.max(base / 4, raw));
  }

  /// The interval before this node's next beacon, under [SimConfig.ogmIntervalMode].
  ///
  /// [OgmIntervalMode.density] holds the receptions a node imposes constant: at interval `I`
  /// with `p` peers it causes `p / I` receptions per millisecond, so setting `I` proportional
  /// to `p` keeps that product at whatever the reference density produces. Called after
  /// `_refreshPeerList`, so `peerIds` is this instant's neighbourhood. Consumes no random
  /// number — the jitter draw belongs to the caller and happens either way — so the fixed
  /// mode's sequence of draws is untouched and the golden vectors do not move.
  double _ogmIntervalFor(MeshNode node) {
    if (config.ogmIntervalMode == OgmIntervalMode.fixed) return config.ogmIntervalMs;
    final peers = math.max(1, node.peerIds.length);
    final reference = math.max(1, config.ogmDensityReferencePeers);
    final raw = (config.ogmIntervalMs * peers) / reference;
    final floor = config.ogmIntervalMs / 4;
    // Two chances per soft-state TTL: a neighbour expires at neighborScoreTtlMs, and an
    // interval at half that survives one lost beacon, which BLE links produce routinely.
    final ceiling = neighborScoreTtlMs / 2;
    return math.min(ceiling, math.max(floor, raw));
  }

  /// Transmit an OGM to every peer, then let each peer gossip it onward.
  void _beacon(MeshNode node, Ogm ogm) {
    final peers = peersInRange(node, nodes, rf);
    // One beacon is one broadcast, however many peers are in range to hear it: the per-peer
    // loop below exists to give each link its own loss draw, not because the radio
    // transmits once per neighbour. Charging the sender per peer inflated an idle node's
    // wake-lock share past 100 % of the clock, which is how that was caught. The receiver
    // side *is* per peer, because each of them really does wake and listen.
    if (peers.isNotEmpty) _holdWakeLock(node.id, _beaconWakeMs(ogm));
    for (final peer in peers) {
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
      _holdWakeLock(peer.id, _beaconWakeMs(ogm));
      _acceptOgm(peer, ogm, node.id);
    }
  }

  void _acceptOgm(MeshNode receiver, Ogm ogm, NodeId via) {
    if (!receiver.isOnline) return;
    final shouldGossip = receiveOgm(receiver, ogm, via, now);
    if (!shouldGossip) return;
    final next = ogmToGossip(ogm, config.ogmTtl);
    if (next == null) return;
    // One gossip retransmission, not one per neighbour — the same reasoning as [_beacon].
    final gossipTo =
        peersInRange(receiver, nodes, rf).where((p) => p.id != via).toList();
    if (gossipTo.isNotEmpty) _holdWakeLock(receiver.id, _beaconWakeMs(next));
    for (final peer in gossipTo) {
      _ogmTx++;
      if (chance(rng,
          effectiveLossProbability(receiver, peer, rf, config.linkRetries))) {
        _lostOgmTx++;
        continue;
      }
      _holdWakeLock(peer.id, _beaconWakeMs(next));
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
    node.score = computeScore(node, nodes, rf, _observedPeerMax(node));
    if (!config.enableSuperElection) return;
    final outcome = electRole(node, nodes, rf, config.communityRelayQuota);
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
    final interval = _scanIntervalFor(node);

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
    _routeExpiries += pruneStaleEntries(node, now, neighborScoreTtlMs);
    pruneOppQueue(node, now);
    node.mprSet =
        selectMprSet(node, nodes, config.communityRelayPreference);

    if (config.enableDtn && node.oppQueue.isNotEmpty) {
      final scan = scanOppQueue(node, nodes, rf, now,
          preferSuper: config.dtnPreferSuper,
          preferCommunity: config.dtnPreferCommunity);
      _dtnSuperCarries += scan.superCarries;
      _dtnCommunityCarries += scan.communityCarries;
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
    if(_selectorOptions!=null) _peerObservedAt[node.id]=now;
    node.peerCount = peers.length;
    node.peerIds = peers.map((p) => p.id).toList()..sort();
    return peers;
  }

  /// The largest peer count this node has heard: its own, and the `peerCount` advertised in
  /// the OGMs it holds. That is the decentralised denominator `PeerNorm.observed` asks for
  /// (docs/06 §18.4) — a node cannot know the world's maximum, only what its own
  /// neighbourhood told it. Returns 0 under the shipped `PeerNorm.fixed`, where `_normPeers`
  /// uses docs/03 §3's constant 50.
  ///
  /// Peers are counted here rather than read from `node.peerCount`, which is refreshed on the
  /// beacon cycle while elections also run between beacons; the scan costs nothing while the
  /// flag is off.
  int _observedPeerMax(MeshNode node) {
    if (config.peerNorm != PeerNorm.observed) return 0;
    var max = peersInRange(node, nodes, rf).length;
    for (final ogm in node.ogmTable.values) {
      if (ogm.peerCount > max) max = ogm.peerCount;
    }
    return max;
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
  // --- media transport (docs/05 §3.2-3.3, roadmap Phase 3, docs/08) ----------

  /// How long a payload occupies the radio on top of the calibrated hop latency.
  ///
  /// [SimConfig.hopLatencyBleMs] already *includes* one GATT write of a full-sized
  /// packet, so only the excess over that packet is charged. That leaves every
  /// latency measured so far — and the golden vectors — exactly where they are, while
  /// making a 64 KB chunk cost what a 64 KB chunk costs (docs/08 §2).
  double serializationMs(int bytes, TransportType transport) {
    final excess = math.max(0, bytes - bleMaxBytes);
    if (excess == 0) return 0.0;
    final kbps = transport == TransportType.wifiDirect
        ? config.wifiDirectKbps
        : config.bleKbps;
    return (excess * 8) / kbps; // bits over kbit/s is milliseconds
  }

  /// Send a large file: sliced into [SimConfig.transferChunkBytes] chunks and pushed
  /// through a sliding window of unacknowledged chunks (docs/05 §3.2, "64 KB slices,
  /// sliding-window ACK").
  ///
  /// Every chunk is an ordinary unicast, so it inherits ACKs, retransmission and the
  /// OppQueue as a last resort — which is what makes "resume on reconnect" work
  /// without any media-specific state machine. Returns null if the sender is offline.
  Transfer? sendFile(NodeId fromId, NodeId toId, int totalBytes,
      {int? chunkBytes, int? window, TransportType? transport}) {
    final from = _byId(fromId);
    if (from == null || !from.isOnline || totalBytes <= 0) return null;
    if (totalBytes > config.maxTransferBytes) {
      // skills/05: "Max 10 MB". Refusing is the honest behaviour: docs/08 §8
      // measures what attempting it would cost the mesh.
      _pushLog(
          MeshLogKind.transfer,
          fromId,
          'refused ${(totalBytes / 1048576).toStringAsFixed(1)} MB to $toId — over the '
              '${(config.maxTransferBytes / 1048576).toStringAsFixed(0)} MB ceiling (skills/05)',
          msgType: MsgType.file);
      return null;
    }
    final slice = math.max(64, chunkBytes ?? config.transferChunkBytes);
    final chunks = math.max(1, (totalBytes / slice).ceil());
    final t = _newTransfer(TransferKind.file, fromId, toId, totalBytes, slice,
        chunks, window, transport);
    _pushWindow(t);
    return t;
  }

  /// Start a push-to-talk note. [seconds] is how long the button is held, and the note
  /// is captured and streamed at the same time: frame i covers the capture window
  /// `[i, i+1) x voiceFrameMs`, so it can only leave at the *end* of that window
  /// (docs/05 §3.3, "500 ms frames at 6-12 kbps"). The last frame therefore departs at
  /// the moment of release — the honest worst case, and the one the roadmap's
  /// "<3 s 1-hop" budget has to cover.
  ///
  /// `stream: false` sends the finished note as one blob at release instead, which is
  /// the alternative the streaming design is measured against in docs/08 §5.
  Transfer? sendVoice(NodeId fromId, NodeId toId, double seconds,
      {bool stream = true, TransportType? transport}) {
    final from = _byId(fromId);
    if (from == null || !from.isOnline || seconds <= 0) return null;
    final frameMs = config.voiceFrameMs;
    final frames = math.max(1, ((seconds * 1000) / frameMs).ceil());
    final frameBytes = math.max(1, ((frameMs * config.voiceKbps) / 8).ceil());
    // Capture ends one `seconds` from now either way, and nothing can leave the phone
    // before it has been recorded.
    final releasedAt = now + seconds * 1000;
    final totalBytes = frames * frameBytes;

    if (!stream) {
      final t = _newTransfer(TransferKind.voice, fromId, toId, totalBytes,
          totalBytes, 1, 1, transport);
      t.releasedAt = releasedAt;
      _queue.push(
          releasedAt, EventKind.transferChunk, fromId, _ChunkPayload(t.id, 0));
      return t;
    }

    final t = _newTransfer(TransferKind.voice, fromId, toId, totalBytes,
        frameBytes, frames, 1, transport);
    t.releasedAt = releasedAt;
    for (var i = 0; i < frames; i++) {
      final departsAt = now + math.min((i + 1) * frameMs, seconds * 1000);
      _queue.push(
          departsAt, EventKind.transferChunk, fromId, _ChunkPayload(t.id, i));
    }
    return t;
  }

  Transfer _newTransfer(TransferKind kind, NodeId fromId, NodeId toId,
      int totalBytes, int chunkBytes, int chunks, int? window,
      [TransportType? forced]) {
    final id = 'transfer-${_transferSeq++}';
    final t = Transfer(
      id: id,
      kind: kind,
      from: fromId,
      to: toId,
      totalBytes: totalBytes,
      chunkBytes: chunkBytes,
      chunks: chunks,
      window: math.max(1, window ?? config.transferWindow),
      startedAt: now,
      lastProgressAt: now,
      transport: forced ?? selectTransport(chunkBytes),
      forcedTransport: forced,
    );
    transfers[id] = t;
    _transfersStarted++;
    _queueStallCheck(id, fromId);
    return t;
  }

  /// (Re)arm the stall watchdog. It stops by itself once the transfer completes.
  void _queueStallCheck(String transferId, NodeId nodeId) {
    _queue.push(now + config.transferStallMs, EventKind.transferStall, nodeId,
        _ChunkPayload(transferId, 0));
  }

  /// Put chunks on air for as long as the sliding window has room.
  /// Put chunks on air for as long as the sliding window has room — and, with
  /// `mediaBackpressure`, for as long as the sender's radio has slots to put them in.
  void _pushWindow(Transfer t) {
    final window = _effectiveWindow(t);
    if (window <= 0) {
      // Blocked on the sender's own radio. Nothing is sent and nothing is lost: the drain that
      // frees a slot calls this again, so the transfer resumes without a timer having to notice
      // (docs/08 §12.12). Counted only when backpressure is what closed the window.
      if (config.mediaBackpressure) _transferBlocks++;
      return;
    }
    while (t.nextToSend < t.chunks && t.nextToSend < t.received + window) {
      _sendChunk(t, t.nextToSend++);
    }
  }

  /// Transmit-queue slots [nodeId] has left. Effectively infinite on the shipped radio, where
  /// nothing queues, so a caller cannot accidentally throttle itself under [ChannelAccess.free].
  int _radioSlotsFree(NodeId nodeId) {
    if (config.channelAccess == ChannelAccess.free) return 1 << 30;
    final queued = _channel[nodeId]?.queue.length ?? 0;
    return math.max(0, config.channelQueueDepth - queued);
  }

  /// Resume any transfer this node is the source of. Called when its radio frees a slot, so a
  /// blocked transfer waits for the medium rather than for a timeout.
  void _resumeBlockedTransfers(NodeId nodeId) {
    if (!config.mediaBackpressure) return;
    for (final t in transfers.values) {
      if (t.state == TransferState.active && t.from == nodeId) _pushWindow(t);
    }
  }

  /// The window the sender may fill right now. Without backpressure it is the configured depth.
  /// With it, the radio's free slots cap it — and the cap may reach zero, so a transfer that is
  /// already committed as far ahead as the queue allows blocks and is resumed by the drain
  /// instead of pushing everybody else out of it. The first implementation floored the cap at one,
  /// which still hands a packet to a queue that is already full and has it shed at the tail: not
  /// backpressure, a slower way of dropping, and measured it *raised* the drop count (docs/08
  /// §12.12).
  int _effectiveWindow(Transfer t) {
    if (!config.mediaBackpressure) return t.window;
    return math.min(t.window, _radioSlotsFree(t.from));
  }

  void _sendChunk(Transfer t, int index) {
    final bytes = math.min(t.chunkBytes, t.totalBytes - index * t.chunkBytes);
    if (bytes <= 0 || index >= t.chunks) return;
    t.onAir.add(index);
    // skills/05: a voice note goes out as VOICE_CHUNK packets, prio=high and ttl=3,
    // which sendMessage derives from the voice type.
    sendMessage(
        t.from,
        t.to,
        '',
        t.kind == TransferKind.voice ? MsgType.voice : MsgType.file,
        null,
        _ChunkCtx(t.id, index, bytes, t.forcedTransport));
  }

  /// The window has not moved for [SimConfig.transferStallMs]: re-send the chunks the
  /// receiver is still missing.
  ///
  /// This is what makes a transfer survive the two things a mesh actually does to it —
  /// a chunk whose retries ran out (it goes to the OppQueue and its logical id is
  /// never seen again), and a link that came back after a node walked out of range.
  /// The receiver dedupes by chunk index, so a re-send that was not needed costs radio
  /// time and nothing else.
  void _onTransferStall(String nodeId, String transferId) {
    final t = transfers[transferId];
    if (t == null || t.state != TransferState.active) return;
    final node = _byId(nodeId);
    // A transfer three hops away legitimately hears nothing for longer than the stall
    // threshold, so the threshold follows the retry timer it is backstopping.
    final stallMs = math.max(
        config.transferStallMs,
        _transferTimeoutMs(t) * (config.maxRetries + 1) * 1.25);
    if (node != null && node.isOnline && now - t.lastProgressAt >= stallMs) {
      // Only chunks that were put on air and never arrived. Frames still being
      // recorded are not missing, they are not due yet.
      final missing = t.onAir.where((i) => !t.receivedChunks.contains(i)).toList()
        ..sort();
      // A sender waiting on its own full radio is doing what backpressure asked it to do, so that
      // wait is not a stall. Counting it would re-send into the queue that caused it — the stall
      // path bypasses the window, so it has to consult the same gate.
      final room =
          config.mediaBackpressure ? _radioSlotsFree(nodeId) : missing.length;
      if (missing.isNotEmpty && room > 0) {
        t.stalls++;
        _transferStalls++;
        t.lastProgressAt = now;
        _pushLog(
            MeshLogKind.transfer,
            nodeId,
            '${t.id} stalled — nothing arrived for ${stallMs.toStringAsFixed(0)} ms, '
                're-sending ${math.min(missing.length, math.min(t.window, room))} of ${missing.length} '
                'missing chunk${missing.length == 1 ? '' : 's'} (stall ${t.stalls})',
            msgType: MsgType.file);
        for (final i in missing.take(math.min(t.window, room))) {
          _sendChunk(t, i);
        }
      }
    }
    _queueStallCheck(transferId, nodeId);
  }

  /// The receiver got a chunk: slides the window on, and completes the transfer when
  /// the last one lands. A duplicate (a retry that arrived after the original) is
  /// ignored, exactly as the inbox ignores a duplicate message.
  void _onChunkArrived(MeshMessage msg, MeshNode node) {
    final t = transfers[msg.transferId];
    if (t == null || t.to != node.id || t.state != TransferState.active) return;
    final index = msg.chunkIndex ?? 0;
    if (t.receivedChunks.contains(index)) return;
    t.receivedChunks.add(index);
    t.received++;
    t.lastProgressAt = now;
    t.transport = msg.transport;
    if (msg.attempt > 0) t.retransmitted++;
    if (index == 0) t.firstChunkAt = now;

    if (t.received == t.chunks) {
      t.completedAt = now;
      t.state = TransferState.complete;
      _transfersCompleted++;
      _bytesDelivered += t.totalBytes;
      final size = t.totalBytes >= 1048576
          ? '${(t.totalBytes / 1048576).toStringAsFixed(1)} MB'
          : '${(t.totalBytes / 1024).toStringAsFixed(1)} KB';
      _pushLog(
          MeshLogKind.transfer,
          node.id,
          '${t.id} ${t.kind.name} $size complete: ${t.chunks} chunk'
              '${t.chunks == 1 ? '' : 's'} in ${(now - t.startedAt).toStringAsFixed(0)} ms'
              '${t.retransmitted == 0 ? '' : ', ${t.retransmitted} retransmitted'} '
              'over ${t.transport.name}',
          peerId: t.from,
          msgId: msg.id,
          msgType: msg.type);
      return;
    }
    if (t.kind == TransferKind.file) _pushWindow(t);
  }

  /// The ACK timeout that applies to this message: media retries far sooner than text,
  /// and optionally on a timer measured from the path rather than a constant.
  double _ackTimeoutFor(MeshMessage msg) {
    final id = msg.transferId;
    if (id == null) {
      final node=_byId(msg.from), controller=_routingSelectors[msg.from];
      if(_selectorOptions!=null && node!=null && controller!=null) {
        selectorDiagnostics.add(controller.decide(LocalRoutingContext(node.peerCount.toDouble(),
          node.oppQueue.length.toDouble(),config.dutyCycleEnabled?1:0,node.battery,node.batterySaver,
          _peerObservedAt[node.id]??double.negativeInfinity),now));
        if(selectorDiagnostics.length>256) selectorDiagnostics.removeAt(0);
      }
      return config.ackTimeoutMs;
    }
    final t = transfers[id];
    return t == null ? config.mediaAckTimeoutMs : _transferTimeoutMs(t);
  }

  /// The retry timer one transfer is using right now.
  double _transferTimeoutMs(Transfer t) => config.adaptiveMediaAck
      ? mediaTimeoutMs(t)
      : config.mediaAckTimeoutMs;

  /// The retry timer for a transfer, from the round trips its own ACKs have reported:
  /// twice the fastest one seen, plus 200 ms of slack, clamped to
  /// `[300 ms, ackTimeoutMs]`.
  ///
  /// Measured rather than fixed because the right value is a property of the path and
  /// the path is not known in advance: a round trip is ~0.5 s at one hop and ~1.5 s at
  /// three, so any constant is wrong for one of them. The *minimum* rather than
  /// RFC 6298's `srtt + 4 x rttvar`, because with a window of chunks in flight the
  /// smoothed average measures the queue the transfer is creating for itself and drifts
  /// to the ceiling — measured in docs/08 §7.
  double mediaTimeoutMs(Transfer t) {
    final minRtt = t.minRttMs;
    if (minRtt == null) return config.mediaAckTimeoutMs;
    return math.min(config.ackTimeoutMs, math.max(300.0, 2 * minRtt + 200));
  }

  /// Fold one ACK's round trip into the transfer's estimate.
  void _observeAck(MeshMessage msg, double sentAt) {
    final id = msg.transferId;
    if (id == null) return;
    final t = transfers[id];
    if (t == null) return;
    final rtt = now - sentAt;
    if (t.minRttMs == null || rtt < t.minRttMs!) t.minRttMs = rtt;
    final srtt = t.srttMs;
    if (srtt == null) {
      t.srttMs = rtt;
      t.rttVarMs = rtt / 2;
      return;
    }
    t.rttVarMs = 0.75 * t.rttVarMs + 0.25 * (srtt - rtt).abs();
    t.srttMs = 0.875 * srtt + 0.125 * rtt;
  }

  /// How long [bytes] take to push over [transport] at the modelled bit rate — the whole
  /// packet, unlike [serializationMs], which charges only the excess over a full BLE packet
  /// because the calibrated hop latency already includes one.
  double airtimeMs(int bytes, TransportType transport) {
    final kbps = transport == TransportType.wifiDirect
        ? config.wifiDirectKbps
        : config.bleKbps;
    return (math.max(0, bytes) * 8) / kbps; // bits over kbit/s is milliseconds
  }

  /// How long a packet holds a radio, under [SimConfig.radioOccupancy]. The
  /// [RadioOccupancy.hopLatency] branch is the expression `_onAir` used before this method
  /// existed, so the default model is unchanged and the golden vectors do not move.
  double occupancyMs(int bytes, TransportType transport) {
    if (config.radioOccupancy == RadioOccupancy.airtime) {
      return airtimeMs(bytes, transport);
    }
    return (transport == TransportType.wifiDirect
            ? config.hopLatencyWifiMs
            : config.hopLatencyBleMs) +
        serializationMs(bytes, transport);
  }

  /// What one beacon costs in wake-lock time. Beacons ride [_beacon] rather than [_onAir],
  /// so under the shipped occupancy model they are accounted as one BLE hop with no payload
  /// term. It cannot be ignored, because on an idle network beaconing is the only radio
  /// activity there is — one acquisition every 2 s per node.
  ///
  /// Under [RadioOccupancy.airtime] the duration comes from [ogmWireBytes], derived from the
  /// fields an OGM actually carries, so a beacon advertising 30 neighbours and 8 routes
  /// costs what that payload costs and one advertising 3 neighbours costs far less.
  double _beaconWakeMs(Ogm ogm) {
    if (config.radioOccupancy == RadioOccupancy.airtime) {
      return airtimeMs(
          ogmWireBytes(ogm.neighborIds.length, ogm.bestHopTo.length,
              config.ogmAliasBytes),
          TransportType.ble);
    }
    return config.hopLatencyBleMs;
  }

  /// One wake-lock acquisition of [ms] milliseconds by [nodeId] (skills/07 telemetry).
  void _holdWakeLock(NodeId nodeId, double ms) {
    _wakeLocksByNode[nodeId] = (_wakeLocksByNode[nodeId] ?? 0) + 1;
    _wakeLockMsByNode[nodeId] = (_wakeLockMsByNode[nodeId] ?? 0) + ms;
  }

  /// Wake locks acquired by one node since the metrics were cleared.
  int wakeLocksFor(NodeId nodeId) => _wakeLocksByNode[nodeId] ?? 0;

  /// Milliseconds one node has spent holding a wake lock since the metrics were cleared.
  double wakeLockMsFor(NodeId nodeId) => _wakeLockMsByNode[nodeId] ?? 0;

  /// Component sizes of the radio graph right now — who can hear whom — largest first.
  ///
  /// A node is in a component with the peers inside RF range of it, which is the graph a
  /// broadcast has to cross. docs/06 §24.10 uses this to explain festival_crowd's two modes,
  /// and any measurement of reach in a mobile network should report it beside the reach,
  /// because a graph sampled once after the window cannot see a partition that healed.
  List<int> componentSizes() =>
      radioComponents(nodes, rf).map((c) => c.length).toList();

  /// The radio graph's components as node-id lists, largest first — the same walk
  /// [componentSizes] reports the sizes of, for a caller that needs to know *which* node is in
  /// which piece. The TypeScript visualiser draws it; a probe could use it to attribute a
  /// delivery failure to the component the sender was in.
  List<List<NodeId>> components() => radioComponents(nodes, rf);

  /// Take one connectivity sample if the interval has elapsed. Called from the physics tick, so
  /// it adds no event to the queue and consumes no random number.
  void _sampleConnectivity() {
    final every = config.connectivitySampleMs;
    if (every <= 0) return;
    if (_lastConnectivitySampleMs < 0) _lastConnectivitySampleMs = now;
    if (now - _lastConnectivitySampleMs < every) return;
    _lastConnectivitySampleMs = now;
    final sizes = componentSizes();
    if (sizes.isEmpty) return;
    _connectivitySamples++;
    if (sizes.length == 1) _connectedSamples++;
    _largestComponentSum += sizes.first / nodes.length;
  }

  /// Block a peer locally, as docs/04 §6 specifies: no moderation server exists, so the
  /// list never leaves the device and never affects anyone else's view of the network.
  /// Returns whether the list changed.
  ///
  /// Keyed on the sender's node id, which is the mesh's identity: docs/07 §4 derives
  /// `destHint8 = SHA-256(pubKey)[0:8]`, and a node id carries that hint, so blocking a
  /// pubKey and blocking a node id are the same act on air.
  bool blockPeer(NodeId blockerId, NodeId peerId) {
    if (blockerId == peerId) return false; // a node cannot block itself
    final list = _blocked[blockerId];
    if (list != null) return list.add(peerId);
    _blocked[blockerId] = {peerId};
    return true;
  }

  /// Undo a block. Returns whether the list changed.
  bool unblockPeer(NodeId blockerId, NodeId peerId) {
    final list = _blocked[blockerId];
    if (list == null || !list.remove(peerId)) return false;
    if (list.isEmpty) _blocked.remove(blockerId);
    return true;
  }

  /// Whether [blockerId] has blocked [peerId].
  bool isBlocked(NodeId blockerId, NodeId peerId) =>
      _blocked[blockerId]?.contains(peerId) ?? false;

  /// The peers a node has blocked, sorted — the same contract as [MeshNode.peerIds].
  List<NodeId> blockedPeers(NodeId blockerId) {
    final list = _blocked[blockerId]?.toList() ?? <NodeId>[];
    list.sort();
    return list;
  }

  MeshMessage? sendMessage(
    NodeId fromId,
    String toId,
    String body, [
    MsgType type = MsgType.text,
    _GroupCtx? groupCtx,
    _ChunkCtx? chunk,
  ]) {
    final from = _byId(fromId);
    if (from == null || !from.isOnline) return null;

    // A group id in the destination position means "send to this group"
    // (docs/04 §4, roadmap Phase 1 "group (3-10 members)"). Which radio pattern
    // that turns into is `groupMode`, and the two are measured against each other
    // in docs/06 §14 rather than assumed.
    final group = groupCtx == null ? groups[toId] : null;
    if (group != null) {
      final targets = group.members.where((id) => id != fromId).toList();
      if (targets.isEmpty) return null;
      _groupExpected += targets.length;
      final ctx = _GroupCtx(group.id, group.keyEpoch);
      if (config.groupMode == GroupMode.perMemberUnicast) {
        // One routed message per member: the route table can aim each one, and each
        // costs an ACK and possibly a retry.
        MeshMessage? last;
        for (final t in targets) {
          final m = sendMessage(fromId, t, body, type, ctx);
          if (m != null) last = m;
        }
        return last;
      }
      // One scoped flood: addressed to nobody in particular, relayed by the whole
      // network on the normal policy, accepted only by members holding the current
      // key epoch. The network never learns who the members are.
      return sendMessage(fromId, groupAddress, body, type, ctx);
    }

    // docs/05 §"Broadcast SOS | All transports, flood (TTL=5)". Reach comes from
    // repeating the flood and, where the deployment is wider than that, from the
    // scenario's sosTtl override — see _onSosRepeat and docs/06 §11.
    final ttl = type == MsgType.sos
        ? config.sosTtl
        : (type == MsgType.voice ? config.voiceTtl : 5);
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
        // SOS rides Wi-Fi Direct whatever its size; a chunk rides whatever the
        // transfer was told to use (skills/05: "WiFi Direct if GO connected"), and
        // failing that whatever its size implies.
        transport: chunk?.transport ??
            (isSos ? TransportType.wifiDirect : null),
        groupId: groupCtx?.id,
        groupEpoch: groupCtx?.epoch,
        // A chunk's size is the payload it carries, not the empty body it was built
        // from — and that size is what picks the transport and the air time.
        sizeBytes: chunk?.bytes,
        transferId: chunk?.transferId,
        chunkIndex: chunk?.index);
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
        groupId: msg.groupId,
        transferId: msg.transferId,
      ));
      // Group traffic gets its own counters: folding it into sentUnicast would let
      // a 10-member group flatter deliveryRatio, and folding it into sentBroadcast
      // would deflate broadcastReach.
      if (msgType == MsgType.sync) {
        _sentSync++;
      } else if (chunk != null) {
        _sentChunks++;
      } else if (groupCtx != null) {
        _sentGroup++;
      } else if (toId == broadcastAddress) {
        _sentBroadcast++;
      } else {
        _sentUnicast++;
      }
    }
    if (groupCtx != null) {
      _recordHistory(from, groupCtx.id, msg, groupCtx.epoch);
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

    // A scoped group flood is addressed to nobody, so no ACK can ever come back:
    // arming the retry timer here would burn two retransmissions and then push the
    // message into the OppQueue on every single group send.
    // Anti-entropy is not acknowledged either: it is periodic by construction, so a
    // lost beacon costs one interval of convergence rather than a retransmission, and
    // acknowledging every digest would cost more than the repair it reports on.
    if (toId != broadcastAddress &&
        toId != groupAddress &&
        msgType != MsgType.ack &&
        msgType != MsgType.sync &&
        config.maxRetries > 0) {
      _pendingAcks[msg.id] = _PendingAck(msg, fromId, 0, now);
      _queue.push(now + _ackTimeoutFor(msg), EventKind.ackTimeout, fromId, msg.id);
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
      groupId: msg.groupId,
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
    final onAirAt = pending.onAirAt;
    if (onAirAt != null) {
      // The packet went on air later than the timer assumed, so the silence it measures has
      // not elapsed yet. Restart from the transmission instead of retransmitting a packet that
      // may still be sitting in the queue: under a saturated radio that duplicate is what turns
      // waiting into load (docs/08 §12.11). Pushed as an absolute deadline rather than
      // `now + wait`, because recomputing a remainder accumulates float error and a remainder
      // of 1e-13 ms reschedules the same event forever.
      final deadline = onAirAt + _ackTimeoutFor(pending.msg);
      if (now < deadline - 1e-9) {
        _queue.push(deadline, EventKind.ackTimeout, nodeId, msgId);
        return;
      }
    }
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
    _queue.push(now + _ackTimeoutFor(retry), EventKind.ackTimeout, nodeId, msgId);
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
  /// Hand a packet to the radio.
  ///
  /// Under the default [ChannelAccess.free] it goes on air immediately, which is what
  /// every number in docs/06-08 was measured under. Under [ChannelAccess.halfDuplex] the
  /// node has one transmitter doing one thing at a time, so the packet joins a bounded
  /// FIFO and waits for the radio; if the FIFO is full it is dropped (docs/08 §12).
  void _transmit(MeshNode node, MeshMessage msg, NodeId targetId) {
    final target = _byId(targetId);
    if (target == null || !target.isOnline || target.id == node.id) return;
    if (config.channelAccess == ChannelAccess.free) {
      _onAir(node, msg, targetId);
      return;
    }
    var ch = _channel[node.id];
    if (ch == null) {
      ch = _ChannelState(config.channelCwMin);
      _channel[node.id] = ch;
    }
    if (ch.queue.length >= config.channelQueueDepth) {
      // Drop-tail: the radio is committed as far ahead as it is allowed to be.
      _channelDrops++;
      if (msg.hopCount > 0) {
        _channelDropsRelayed++;
        if (_hasAlternativeNextHop(node, msg)) _channelDropsWithAlternative++;
      }
      if (msg.type == MsgType.file || msg.type == MsgType.voice) _channelDropsMedia++;
      _pushLog(
          MeshLogKind.loss,
          node.id,
          '${msg.id} → $targetId dropped: transmit queue full (${config.channelQueueDepth})',
          peerId: targetId,
          msgId: msg.id,
          msgType: msg.type,
          hop: msg.hopCount);
      return;
    }
    ch.queue.add(_QueuedTx(msg, targetId, now));
    _drainChannel(node);
  }

  /// Put the next queued packet on air if the radio is free, and make sure something
  /// wakes it when it is not.
  /// Whether [node] could have reached [msg]'s destination through a peer other than the one it
  /// chose, at no cost in hops. A relay's route is one next hop, so "round the congestion" only
  /// exists if some peer in range is at least as close to the destination as that hop is. Derived
  /// from the route table and the geometry, so it consumes no random numbers and cannot move a
  /// golden vector (docs/08 §12.14).
  bool _hasAlternativeNextHop(MeshNode node, MeshMessage msg) {
    final dest = msg.to;
    if (dest == broadcastAddress || dest == groupAddress) return false;
    final mine = node.nextHopTable[dest];
    if (mine == null || mine.tq < tqUsable) return false;
    for (final peer in peersInRange(node, nodes, rf)) {
      if (peer.id == mine.bestNeighbor) continue;
      final theirs = peer.nextHopTable[dest];
      // Forwarding to this peer costs one hop to reach it, so it is no worse than the route
      // already chosen only if the peer is strictly closer to the destination.
      if (theirs != null && theirs.tq >= tqUsable && theirs.hopCount <= mine.hopCount - 1) {
        return true;
      }
    }
    return false;
  }

  void _drainChannel(MeshNode node) {
    final ch = _channel[node.id];
    if (ch == null) return;
    // A radio does not spend air time on a transmission nobody can receive, so packets
    // whose target went offline while they waited are discarded first.
    while (ch.queue.isNotEmpty) {
      final head = _byId(ch.queue.first.targetId);
      if (head != null && head.isOnline) break;
      ch.queue.removeAt(0);
    }
    if (ch.queue.isEmpty) return;
    if (ch.busyUntil > now) {
      if (!ch.drainScheduled) {
        ch.drainScheduled = true;
        _queue.push(ch.busyUntil, EventKind.channel, node.id);
      }
      return;
    }
    if (config.channelAccess == ChannelAccess.csma) {
      // Carrier sense: the medium is busy if anybody within radio range is transmitting, and
      // a node that waits is not itself on air, so this always terminates.
      final freeAt = _mediumFreeAt(node);
      if (freeAt > now) {
        _channelDeferrals++;
        _channelDeferMs += freeAt - now;
        if (!ch.drainScheduled) {
          ch.drainScheduled = true;
          _queue.push(freeAt, EventKind.channel, node.id);
        }
        return;
      }
      if (config.channelBackoff != ChannelBackoff.none) {
        // The medium is free *now* — which is exactly when every other node waiting on the
        // same medium also finds it free, because they were all woken at this instant. Left
        // alone they transmit together and listening has synchronised the herd instead of
        // dispersing it. Draw a random number of slots and wait them out (docs/08 §12.13).
        if (!ch.backoffArmed) {
          // `randInt` draws only here, so ChannelBackoff.none consumes no random numbers and
          // the shipped model stays bit-identical.
          ch.backoffSlots = randInt(rng, 0, ch.cw);
          ch.backoffArmed = true;
          _channelBackoffs++;
        }
        if (ch.backoffSlots > 0) {
          final wait = ch.backoffSlots * config.channelSlotMs;
          // Paid in full rather than a slot at a time: a 64-slot window drained one event per
          // slot is 64 wakeups per transmission, and the answer is the same.
          ch.backoffSlots = 0;
          _channelDeferrals++;
          _channelDeferMs += wait;
          if (!ch.drainScheduled) {
            ch.drainScheduled = true;
            _queue.push(now + wait, EventKind.channel, node.id);
          }
          return;
        }
      }
    }
    final next = _takeNextTx(ch);
    final waited = now - next.queuedAt;
    if (waited > 0) {
      _channelDeferrals++;
      _channelDeferMs += waited;
    }
    final airTime = _onAir(node, next.msg, next.targetId);
    ch.busyUntil = now + airTime;
    // A slot just freed. Anything this node was holding back for want of one goes now, which is
    // the resume half of blocking — without it a transfer that was refused air waits for a
    // timeout instead of for the medium.
    _resumeBlockedTransfers(node.id);
    if (config.channelBackoff != ChannelBackoff.none) {
      // Binary exponential backoff: a radio that just collided draws from a window twice as
      // wide next time, so two radios that keep meeting keep backing off until they stop
      // meeting; a radio that got through goes back to the narrow window it started with.
      ch.cw = _lastTxCollided
          ? (ch.cw * 2 > config.channelCwMax ? config.channelCwMax : ch.cw * 2)
          : config.channelCwMin;
      ch.backoffArmed = false;
    }
    if (ch.queue.isNotEmpty && !ch.drainScheduled) {
      ch.drainScheduled = true;
      _queue.push(ch.busyUntil, EventKind.channel, node.id);
    }
  }

  /// The instant the medium around [node] comes free: the latest transmit window it can hear,
  /// or `now` if it hears nobody. Carrier sense only, and only over peers in range — a node
  /// cannot sense a transmission it could not receive (docs/08 §12.10).
  double _mediumFreeAt(MeshNode node) {
    var freeAt = now;
    for (final peer in peersInRange(node, nodes, rf)) {
      final until = _txUntil[peer.id] ?? 0;
      if (until > freeAt) freeAt = until;
    }
    return freeAt;
  }

  /// Take the next packet off the queue: arrival order, or by class when the config asks
  /// for it. Within a class it is still arrival order, so a voice note cannot be overtaken
  /// by a later one.
  _QueuedTx _takeNextTx(_ChannelState ch) {
    if (config.channelPriority == ChannelPriority.fifo) return ch.queue.removeAt(0);
    if (config.channelPriority == ChannelPriority.ackFirst) {
      final ack = ch.queue.indexWhere((q) => q.msg.type == MsgType.ack);
      return ch.queue.removeAt(ack == -1 ? 0 : ack);
    }
    var best = 0;
    for (var i = 1; i < ch.queue.length; i++) {
      if (_channelClass[ch.queue[i].msg.type]! < _channelClass[ch.queue[best].msg.type]!) {
        best = i;
      }
    }
    return ch.queue.removeAt(best);
  }

  /// The packet goes on air: counters, loss draw, log, delivery event. Returns the air
  /// time it occupied — a lost packet still occupied the radio for all of it.
  double _onAir(MeshNode node, MeshMessage msg, NodeId targetId) {
    final target = _byId(targetId)!;
    // Cleared per transmission so the contention window sees this packet's fate and not the
    // last one's.
    _lastTxCollided = false;
    node.txCount++;
    _relayTx++;
    final loss = effectiveLossProbability(node, target, rf, config.linkRetries);
    final rssi = rssiModel(node, target, rf);
    // What this packet occupies a radio for, without the jitter draw: the receiver-side model
    // below needs it before the packet's fate is known, and both branches that never land
    // return it. No random number is consumed here, so `ChannelCapture.none` stays
    // bit-identical to the model every other result was measured under.
    final occupied = occupancyMs(msg.sizeBytes, msg.transport);
    if (config.channelAccess != ChannelAccess.free) {
      // A retry timer measures the silence after a transmission, so under a queued radio it
      // has to start when the packet leaves rather than when it was handed over.
      final pending = _pendingAcks[msg.id];
      if (pending != null && pending.from == node.id) pending.onAirAt = now;
    }
    final capture = config.channelCapture != ChannelCapture.none;
    final sense = config.channelAccess == ChannelAccess.csma;
    // A radio is deaf from the moment it starts transmitting, whether or not the packet
    // survives the link — and carrier sense needs the same fact from the other side, because
    // what a sender listens for is exactly its peers' transmit windows.
    if (capture || sense) _txUntil[node.id] = now + occupied;
    // skills/07 "wake-locks": a transmission holds the radio — and therefore the CPU — for
    // as long as the packet occupies it. Accumulated here rather than read off `_txUntil`,
    // which the shipped `free`/`none` baseline never maintains.
    _holdWakeLock(node.id, occupied);
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
      // Air time without the jitter draw: consuming a random number here would move the
      // stream the default model depends on, and the golden vectors with it.
      return occupied;
    }
    if (capture) {
      // Two ways a packet that survived the link still does not arrive: its receiver is
      // transmitting, or its receiver is locked onto a packet that got there first. Both are
      // losses rather than deferrals — that is what a collision is. Under `first` the earlier
      // packet always wins and no signal-strength comparison happens, which is the pessimistic
      // bound (docs/08 §12.9). Under `strongest` a newcomer that is enough stronger takes the
      // receiver over instead and the incumbent is what is lost — the capture effect, and the
      // reason `first` and `none` bracket the truth rather than either of them being it
      // (docs/08 §12.15).
      final deaf = (_txUntil[target.id] ?? 0) > now;
      final busy = !deaf && (_rxUntil[target.id] ?? 0) > now;
      final held = _rxRssi[target.id] ?? double.negativeInfinity;
      final captures = busy &&
          config.channelCapture == ChannelCapture.strongest &&
          rssi >= held + config.channelCaptureRatioDb;
      if ((deaf || busy) && !captures) {
        _lastTxCollided = true;
        if (deaf) {
          _channelDeafRx++;
        } else {
          _channelCaptured++;
        }
        _recordTxOutcome(node, 0);
        final reason = deaf
            ? 'receiver was transmitting'
            : config.channelCapture == ChannelCapture.strongest
                ? 'receiver held a stronger packet '
                    '(${held.toStringAsFixed(0)} vs ${rssi.toStringAsFixed(0)} dBm)'
                : 'receiver was locked onto an earlier packet';
        _pushLog(MeshLogKind.loss, node.id,
            '${msg.id} → $targetId collided ($reason)',
            peerId: targetId,
            msgId: msg.id,
            msgType: msg.type,
            hop: msg.hopCount,
            rssi: rssi);
        return occupied;
      }
      if (captures) {
        // The newcomer wins the receiver. The incumbent is condemned by transmission sequence
        // rather than by message id, so a retry of the same message — or a second relay
        // carrying the same copy — is a fresh attempt.
        final victim = _rxSeq[target.id];
        if (victim != null) _superseded.add(victim);
        _channelCaptureEffects++;
        // …and the incumbent is a collision loss, so it is counted as one.
        _channelCaptured++;
        // `_lastTxCollided` stays clear for the winner: its own transmission was clean, and
        // doubling its contention window would punish the packet that survived. The
        // incumbent's transmitter is not told, which is the honest limit of modelling this at
        // the receiver — a real radio gets no such notification either, and it is why
        // `channelBackoff` and `strongest` do not compose into anything better than each
        // alone.
      }
    }
    // Under `strongest` the outcome is booked at arrival instead, because a packet taken over
    // part-way through was not a success and booking it as one here would leave the link
    // estimate optimistic about a radio that is losing packets to third parties. That would
    // also make the arm incomparable with `first`, where the loser of a collision *is* booked
    // as a failure: the only difference between the two arms should be which packet survives.
    // Measured before this was corrected, `csma` with a file in flight read 0.9266 over three
    // seeds — clearing the ≥0.90 gate — and the whole of that was the bookkeeping.
    if (config.channelCapture != ChannelCapture.strongest) _recordTxOutcome(node, 1);
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
    // Air time: what the payload physically occupies the radio for. The loss draw and the
    // jitter draw happen in the same order under both channel models, so `channelAccess`
    // changes *when* a packet lands and never which random numbers a transmission
    // consumes.
    final airTime = base +
        serializationMs(msg.sizeBytes, msg.transport) +
        randRange(rng, config.jitterMinMs, config.jitterMaxMs);
    // Occupancy is not latency. `airTime` says when this packet lands, which keeps its
    // hop-latency base under both models because that is what docs/02 §6's budget measures;
    // `rxOccupied` says how long the radio was busy hearing it, which is the only one of the
    // two [SimConfig.radioOccupancy] may change. Identical under the shipped model.
    final rxOccupied = config.radioOccupancy == RadioOccupancy.airtime
        ? airtimeMs(msg.sizeBytes, msg.transport)
        : airTime;
    if (capture) _rxUntil[target.id] = now + rxOccupied;
    // The receiving side of the same lock, counted whether or not the packet survives the
    // link: a radio that woke and listened spent the power either way, which is what makes
    // a flood a battery-drain attack rather than a bandwidth one.
    _holdWakeLock(target.id, rxOccupied);
    int? seq;
    if (config.channelCapture == ChannelCapture.strongest) {
      // Only assigned here, so the two shipped modes consume nothing and behave exactly as
      // every published number in this repository was measured.
      final n = ++_txSeq;
      seq = n;
      _rxRssi[target.id] = rssi;
      // `n` rather than `seq`: the map's value type is non-nullable and this does not rely on
      // the compiler having promoted the nullable local.
      _rxSeq[target.id] = n;
    }
    _queue.push(
        now + airTime, EventKind.msg, targetId, _MsgPayload(msg, node.id, seq: seq));
    return airTime;
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

    // A transmission the receiver gave up on part-way through, because a stronger packet took
    // it over ([ChannelCapture.strongest]). Checked before anything else: the receiver never
    // decoded this one, so it is not coverage evidence, not a delivery and not a duplicate.
    // Keyed by transmission rather than by message id, so a retry of the same message is a
    // fresh attempt and not a condemned one. Under every other mode `seq` is null and this
    // cannot fire.
    final seq = payload.seq;
    if (seq != null && sender != null) {
      if (_superseded.contains(seq)) {
        _superseded.remove(seq);
        _recordTxOutcome(sender, 0);
        _pushLog(
            MeshLogKind.loss,
            nodeId,
            '${msg.id} lost (receiver was taken over by a stronger packet)',
            peerId: via,
            msgId: msg.id,
            msgType: msg.type,
            hop: msg.hopCount);
        return;
      }
      _recordTxOutcome(sender, 1);
    }

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

    // Placed after the hop record exists so a suppressed broadcast still shows in
    // the hop trace, which is the artifact an auditor reads (docs/07 §6).
    //
    // docs/04 §6: "Max 5 broadcasts / minute per node; SUPERs drop excess."
    // Enforced by SUPERs only, exactly as written — a limitation worth stating
    // rather than hiding, since a NORMAL node neither relays far nor filters, so a
    // flooder still reaches its own one-hop neighbourhood. The gate is on the
    // `broadcast` type and not on `to == broadcastAddress`, because SOS travels to
    // BROADCAST too and docs/04 §6 gives SOS its own mechanism (opt-in listening,
    // plus the collapsing in §11); rate-limiting an emergency channel at 5/min would
    // be a worse failure than the abuse it prevents.
    if (config.rateLimits &&
        msg.type == MsgType.broadcast &&
        (config.broadcastCapScope == BroadcastCapScope.all ||
            node.role == Role.superNode)) {
      final gate = admitByRate(_rateBroadcasts, '${node.id}|${msg.from}',
          config.broadcastPerMinuteCap, now);
      if (!gate.ok) {
        _rateBroadcastDrops++;
        if (hopRecord != null) {
          hopRecord.action = HopAction.suppressed;
          hopRecord.reason = gate.reason;
        }
        _pushLog(
            MeshLogKind.decision,
            node.id,
            '${msg.id} broadcast from ${msg.from} suppressed by ${node.name} '
                '(${node.role == Role.superNode ? 'SUPER' : 'NORMAL, cap scope all'}): '
                '${gate.reason}',
            peerId: via,
            msgId: msg.id,
            msgType: msg.type,
            hop: msg.hopCount);
        return;
      }
    }

    // docs/04 §6: "Block/mute peer locally (ignore msgs from pubKey)." Placed after the
    // hop record, like the rate gates, so the audit trail shows a node ignored a message
    // rather than silently never seeing it — which is the difference between a user
    // choice and packet loss. [isBlockableTraffic] keeps control plane and SOS out; see
    // its doc comment for why blocking an ACK makes the airtime worse.
    final blockedHere =
        isBlockableTraffic(msg) && isBlocked(node.id, msg.from);
    if (blockedHere) {
      _blockedDrops++;
      if (hopRecord != null) {
        hopRecord.action = HopAction.blocked;
        hopRecord.reason = '${node.name} has blocked ${msg.from}';
      }
      _pushLog(
          MeshLogKind.decision,
          node.id,
          '${msg.id} from ${msg.from} ignored by ${node.name}: sender is blocked'
              '${config.blockScope == BlockScope.relay ? ' (and not relayed)' : ''}',
          peerId: via,
          msgId: msg.id,
          msgType: msg.type,
          hop: msg.hopCount);
      // "relay" is §6's "ignore floods": the blocker stops paying for someone it blocked.
      // "delivery" stops here and lets the mesh carry the copy for everyone else.
      if (config.blockScope == BlockScope.relay) return;
    }

    // skills/04: "On ackReceived from dest: remove + gossip ACK (so relays can prune)".
    // The ACK comes back along the reverse path, and the nodes on that path are the ones
    // that were carrying copies, so hearing one is enough to drop the bundle — no extra
    // traffic and no new packet type. Measured, it fires essentially never (docs/06
    // §20.5); it is kept because it is free and correct when it does.
    if (msg.type == MsgType.ack && msg.body.length > 4) {
      _bundlesPruned += pruneAcked(node, msg.body.substring(4));
    }

    if (msg.to == node.id && !blockedHere) {
      if (msg.type == MsgType.ack) {
        final ackedId = msg.body.length > 4 ? msg.body.substring(4) : '';
        final pending = _pendingAcks.remove(ackedId);
        if (pending != null) _observeAck(pending.msg, pending.sentAt);
        _acksReceived++;
        _pushLog(MeshLogKind.ack, node.id, '$ackedId acknowledged',
            msgId: ackedId, peerId: via);
      }
      // Set before _recordDelivery copies the trace, so the delivered record
      // carries the final action rather than the provisional one.
      if (hopRecord != null) hopRecord.action = HopAction.delivered;
      if (msg.type == MsgType.sync) {
        // Control plane: it reached this node, which the hop trace should say, but it
        // is not a message for the user and not a delivery to count.
        _onSyncMessage(node, msg);
        return;
      }
      final fresh = deliverToInbox(node, msg);
      if (fresh) {
        _recordDelivery(node, msg, trace);
        if (msg.transferId != null) _onChunkArrived(msg, node);
      }
      _pushLog(
          MeshLogKind.deliver,
          node.id,
          '${msg.id} delivered to ${node.name} via $via — ${msg.hopCount + 1} hop${msg.hopCount == 0 ? '' : 's'}, ${(now - msg.timestamp).toStringAsFixed(0)} ms',
          peerId: via,
          msgId: msg.id,
          msgType: msg.type,
          hop: msg.hopCount + 1);
      if (msg.type != MsgType.ack && msg.to != broadcastAddress) {
        // A bundle that arrived by store-carry-forward is acknowledged to whoever carried
        // it in, not to the originator: the originator's retry timer expired long ago, and
        // the carriers are the nodes holding copies that can now be pruned (skills/04:
        // "remove + gossip ACK (so relays can prune)").
        _sendAck(node, msg, msg.carried ? via : null);
      }
      return;
    }

    if (msg.to == groupAddress && msg.groupId != null) {
      final group = groups[msg.groupId];
      final isMember = group != null && group.members.contains(node.id);
      if (group != null &&
          isMember &&
          group.keyEpoch == msg.groupEpoch &&
          !blockedHere) {
        final fresh = deliverToInbox(node, msg);
        if (fresh) {
          _recordDelivery(node, msg, trace);
          _recordHistory(node, group.id, msg, msg.groupEpoch ?? group.keyEpoch);
          _pushLog(
              MeshLogKind.deliver,
              node.id,
              '${msg.id} group "${group.name}" reached ${node.name} via $via '
                  '(epoch ${msg.groupEpoch})',
              peerId: via,
              msgId: msg.id,
              msgType: msg.type,
              hop: msg.hopCount + 1);
        }
      } else if (group != null && isMember && !blockedHere) {
        // A member holding an older epoch cannot decrypt this copy: the key rotated
        // when somebody left or joined (docs/04 §4, "groupKey rotated on member
        // leave"). It still relays — the bytes are not secret to the network, only
        // unreadable to this node.
        _groupEpochRejected++;
        _pushLog(
            MeshLogKind.group,
            node.id,
            '${msg.id} group "${group.name}" at ${node.name}: sent under epoch '
                '${msg.groupEpoch}, holds ${group.keyEpoch} — cannot decrypt, still relaying',
            msgId: msg.id,
            msgType: msg.type);
      }
      // Non-members fall through silently: relaying traffic you cannot read is the
      // normal case in a scoped flood, and logging it would drown the capture.
    }

    if (msg.to == broadcastAddress && !blockedHere) {
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

    // docs/04 §6: "Cap relay to 30 msgs/min per source; ignore floods." Every node
    // enforces this one, because relaying is what every node does and a flood costs
    // the relays' queues rather than a SUPER's attention — docs/08 §12.13 measured
    // queue drops running eight to one against receiver collisions, so the buffer is
    // where a flood actually lands.
    if (config.rateLimits && countsAgainstRelayCap(msg)) {
      final gate = admitByRate(_rateRelays, '${node.id}|${msg.from}',
          config.relayPerSourcePerMinuteCap, now);
      if (!gate.ok) {
        _rateRelayDrops++;
        if (hopRecord != null) {
          hopRecord.action = HopAction.suppressed;
          hopRecord.reason = gate.reason;
        }
        _pushLog(
            MeshLogKind.decision,
            node.id,
            '${msg.id} from ${msg.from} not relayed by ${node.name}: '
                '${gate.reason}',
            peerId: via,
            msgId: msg.id,
            msgType: msg.type,
            hop: msg.hopCount);
        return;
      }
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

  void _sendAck(MeshNode node, MeshMessage original, [NodeId? ackTo]) {
    final target = ackTo ?? original.from;
    final ack = createMessage(_nextMsgId(), now, node.id, target,
        'ACK:${original.id}',
        type: MsgType.ack, ttl: 3, priority: Priority.high);
    _traces[ack.id] =
        _PathTrace(<NodeId>[node.id], now, node.id, target, MsgType.ack);
    final decision = decideForward(
        node, ack, nodes, rf, config.relayPolicy);
    _applyDecision(node, ack, decision);
  }

  void _recordDelivery(MeshNode node, MeshMessage msg, _PathTrace? trace) {
    // Counted here rather than at a delivery call site because group traffic arrives
    // by two different roads — a scoped flood addressed to groupAddress, or a routed
    // unicast per member — and a counter in only one of them silently reports 0% for
    // the other mode.
    if (msg.groupId != null) _groupReceipts++;
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
      groupId: msg.groupId,
      groupEpoch: msg.groupEpoch,
      transferId: msg.transferId,
      chunkIndex: msg.chunkIndex,
      retransmitted: msg.attempt > 0,
    ));
    if (deliveries.length > 5000) deliveries.removeAt(0);
    for (final rec in sentRecords) {
      if (rec.msgId == msg.id) {
        rec.delivered = true;
        break;
      }
    }
  }

  // --- group channels (docs/04 §4, roadmap Phase 1 and Phase 4 "Group UX") ----

  /// Live group channels. Membership is simulator state, not wire state: the
  /// network relays a group flood without ever learning who is in it.
  final Map<String, Group> groups = <String, Group>{};
  int _groupSeq = 0;

  /// Create a group. The 3-10 member bound is roadmap Phase 1's, and it is enforced
  /// here rather than left to a UI: below 3 a group is a 1:1 chat with an audience,
  /// and above 10 it is a broadcast wearing a member list — which matters because a
  /// scoped flood costs the whole network relays no matter how few nodes accept it.
  Group? createGroup(String name, List<NodeId> memberIds, [NodeId? adminId]) {
    final unique = <NodeId>{};
    for (final id in memberIds) {
      if (_byId(id) != null) unique.add(id);
    }
    if (unique.length < groupMinMembers || unique.length > groupMaxMembers) {
      return null;
    }
    final list = unique.toList();
    final group = Group(
      id: 'grp-${++_groupSeq}',
      name: name,
      members: unique,
      adminId: (adminId != null && unique.contains(adminId)) ? adminId : list.first,
      keyEpoch: 0,
      createdAt: now,
    );
    groups[group.id] = group;
    for (final id in unique) {
      _armHistoryBeacon(id);
    }
    _pushLog(MeshLogKind.group, group.adminId,
        'group "${group.name}" created with ${unique.length} members (epoch 0)');
    return group;
  }

  /// Add a member. Rotates the key on the way in, for the mirror image of the reason
  /// [removeFromGroup] rotates it: a joiner must not be able to read the history it
  /// missed. docs/04 §4 names the leave case; the join case is the same argument.
  bool inviteToGroup(String groupId, NodeId nodeId) {
    final group = groups[groupId];
    if (group == null || group.members.contains(nodeId) || _byId(nodeId) == null) {
      return false;
    }
    if (group.members.length >= groupMaxMembers) return false;
    group.members.add(nodeId);
    group.keyEpoch++;
    _armHistoryBeacon(nodeId);
    _pushLog(
        MeshLogKind.group,
        nodeId,
        '${_byId(nodeId)?.name} joined "${group.name}" — key rotated to epoch ${group.keyEpoch}');
    return true;
  }

  /// Remove a member and rotate the group key, which is what makes the departure
  /// stick: the departed node keeps relaying group traffic (it is just bytes now)
  /// but can no longer read any of it. Refuses to go below 3 members — at that point
  /// the group is a 1:1 chat and should be one.
  bool removeFromGroup(String groupId, NodeId nodeId) {
    final group = groups[groupId];
    if (group == null || !group.members.contains(nodeId)) return false;
    if (group.members.length <= groupMinMembers) return false;
    group.members.remove(nodeId);
    group.keyEpoch++;
    _pushLog(
        MeshLogKind.group,
        nodeId,
        '${_byId(nodeId)?.name} left "${group.name}" — key rotated to epoch ${group.keyEpoch}');
    return true;
  }

  /// Manual rotation, admin only (roadmap Phase 4: "admin rotate key").
  bool rotateGroupKey(String groupId, NodeId requestedBy) {
    final group = groups[groupId];
    if (group == null || group.adminId != requestedBy) return false;
    group.keyEpoch++;
    _pushLog(MeshLogKind.group, requestedBy,
        'admin rotated "${group.name}" key to epoch ${group.keyEpoch}');
    return true;
  }

  /// Groups a node belongs to, for a UI's destination picker.
  // --- group history anti-entropy -------------------------------------------

  /// Start a node's beacon chain. One chain covers every group the node is in, so
  /// joining a second group does not start a second one.
  ///
  /// Nothing is scheduled for a node with no groups, which is why this whole feature is
  /// inert on a run that never creates one — including the golden vectors.
  void _armHistoryBeacon(NodeId nodeId) {
    if (config.historyBeaconMs <= 0) return;
    if (_historyBeaconArmed.contains(nodeId)) return;
    _historyBeaconArmed.add(nodeId);
    _queue.push(now + config.historyBeaconMs, EventKind.historyBeacon, nodeId);
  }

  /// The entries a node can actually share for one group: the ones written under the key
  /// epoch the group is on now.
  ///
  /// A rotation makes everything older unreadable to everybody (docs/06 §14), so
  /// repairing it would move bytes nobody can decrypt. That has a consequence worth
  /// stating plainly: in a group whose membership changes often, the repairable history
  /// is only ever as old as the last change.
  Map<String, HistoryEntry> syncableHistory(MeshNode node, Group group) {
    final all = node.history[group.id];
    final out = <String, HistoryEntry>{};
    if (all == null) return out;
    all.forEach((id, entry) {
      if (entry.epoch == group.keyEpoch) out[id] = entry;
    });
    return out;
  }

  /// The repairable history one node holds for one group, oldest first. What a UI renders
  /// when it wants to show a member the messages it missed and recovered; entries carry
  /// [HistoryEntry.synced] so a recovered one can be marked as such.
  List<HistoryEntry> groupHistoryOf(NodeId nodeId, String groupId) {
    final node = _byId(nodeId);
    final group = groups[groupId];
    if (node == null || group == null) return <HistoryEntry>[];
    final list = syncableHistory(node, group).values.toList()
      ..sort((a, b) {
        if (a.at != b.at) return a.at.compareTo(b.at);
        return a.msgId.compareTo(b.msgId);
      });
    return list;
  }

  /// Add one entry to a node's history.
  void _recordHistory(
      MeshNode node, String groupId, MeshMessage msg, int epoch) {
    _putHistory(
        node,
        HistoryEntry(
          msgId: msg.id,
          groupId: groupId,
          from: msg.from,
          at: msg.timestamp,
          body: msg.body,
          epoch: epoch,
        ));
  }

  /// The union step of the G-Set: returns true if the entry was new to this node.
  bool _putHistory(MeshNode node, HistoryEntry entry) {
    final map = node.history.putIfAbsent(
        entry.groupId, () => <String, HistoryEntry>{});
    if (map.containsKey(entry.msgId)) return false;
    map[entry.msgId] = entry;
    return true;
  }

  /// Offer this node's digests to every co-member it can currently hear.
  ///
  /// Beacons go only to peers, not across the mesh: anti-entropy repairs the last hop of
  /// a loss (a node that was asleep, out of range, or switched off while a flood went
  /// by), and a peer that is out of range will be a peer again later. The chain stops by
  /// itself when a node leaves its last group.
  void _onHistoryBeacon(NodeId nodeId) {
    final node = _byId(nodeId);
    _historyBeaconArmed.remove(nodeId);
    if (node == null || !node.isOnline || config.historyBeaconMs <= 0) return;
    final mine = groupsOf(nodeId);
    if (mine.isEmpty) return;
    _armHistoryBeacon(nodeId);

    for (final group in mine) {
      final held = syncableHistory(node, group);
      final digest = historyDigest(held.values);
      for (final peerId in node.peerIds) {
        if (!group.members.contains(peerId)) continue;
        final body = encodeHistoryBeacon(group.id, group.keyEpoch, digest);
        if (sendMessage(nodeId, peerId, body, MsgType.sync) != null) {
          _historyBeacons++;
          _historyBytes += body.length;
        }
      }
    }
  }

  /// One anti-entropy packet arrived: a beacon, a request for the buckets that differ, or
  /// the entries that fill them.
  ///
  /// The three-step exchange is what keeps a repair proportional to the difference rather
  /// than to the history — a beacon is 156 characters whatever the group has said, and a
  /// reply carries only the buckets the requester is missing.
  void _onSyncMessage(MeshNode node, MeshMessage msg) {
    final parts = msg.body.split('|');
    if (parts.length < 4) return;
    // A message body may itself contain '|', so the payload is everything after the
    // third field rather than the fourth field alone.
    final payload = parts.sublist(3).join('|');
    final group = groups[parts[1]];
    if (group == null || !group.members.contains(node.id)) return;
    final epoch = int.tryParse(parts[2]);
    if (epoch == null || epoch != group.keyEpoch) return; // the key has rotated since

    if (parts[0] == 'HB') {
      final held = syncableHistory(node, group);
      final digest = historyDigest(held.values);
      if (parts.length < 5) return;
      final theirs =
          parts[4].split(',').map((h) => int.tryParse(h, radix: 16) ?? -1).toList();
      if (theirs.length != historyBuckets) return;
      final differing = <int>[];
      for (var i = 0; i < historyBuckets; i++) {
        if (theirs[i] != digest.buckets[i]) differing.add(i);
      }
      if (differing.isEmpty) return;
      // The request carries the ids this node already holds in those buckets. Without
      // them a *bounded* reply would offer the same head of the list every round and
      // convergence would stall at `historyReplyMax` entries — which is exactly what the
      // first version of this protocol did (docs/06 §17).
      final wanted = differing.toSet();
      final have = held.values
          .where((e) => wanted.contains(historyBucket(e.msgId)))
          .map((e) => e.msgId)
          .toList()
        ..sort();
      final body =
          'RQ|${group.id}|$epoch|${differing.join(',')}|${have.take(historyRequestMaxIds).join(',')}';
      if (sendMessage(node.id, msg.from, body, MsgType.sync) != null) {
        _historyRequests++;
        _historyBytes += body.length;
        _pushLog(
            MeshLogKind.sync,
            node.id,
            '${group.name}: ${node.name} and ${_byId(msg.from)?.name ?? msg.from} disagree '
                'on bucket${differing.length == 1 ? '' : 's'} ${differing.join(',')} '
                '(${digest.count} vs ${int.tryParse(parts[3]) ?? 0} entries) — requesting',
            peerId: msg.from,
            msgId: msg.id,
            msgType: MsgType.sync);
      }
      return;
    }

    if (parts[0] == 'RQ') {
      // `RQ|group|epoch|buckets|ids`: the buckets being asked for, then the ids the
      // requester already holds in them (which may be none).
      final wanted = parts[3].split(',').map((b) => int.tryParse(b) ?? -1).toSet();
      final theyHave = <String>{};
      if (parts.length > 4 && parts[4].isNotEmpty) theyHave.addAll(parts[4].split(','));
      final held = syncableHistory(node, group);
      final out = held.values
          .where((e) =>
              wanted.contains(historyBucket(e.msgId)) && !theyHave.contains(e.msgId))
          .toList()
        ..sort((a, b) => a.msgId.compareTo(b.msgId));
      final slice = out.take(config.historyReplyMax).toList();
      if (slice.isEmpty) return;
      final body = 'RS|${group.id}|$epoch|'
          '${jsonEncode(slice.map((e) => e.toJson()).toList())}';
      if (sendMessage(node.id, msg.from, body, MsgType.sync) != null) {
        _historyReplies++;
        _historyBytes += body.length;
        _pushLog(
            MeshLogKind.sync,
            node.id,
            '${group.name}: ${node.name} sent ${slice.length} of ${out.length} missing '
                'entries in bucket${wanted.length == 1 ? '' : 's'} ${wanted.join(',')} to '
                '${_byId(msg.from)?.name ?? msg.from}',
            peerId: msg.from,
            msgId: msg.id,
            msgType: MsgType.sync);
      }
      return;
    }

    if (parts[0] == 'RS') {
      final List<HistoryEntry> entries;
      try {
        final decoded = jsonDecode(payload) as List<dynamic>;
        entries = decoded
            .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        return;
      }
      var added = 0;
      var dropped = 0;
      for (final entry in entries) {
        if (entry.epoch != group.keyEpoch) {
          // Unreadable under the current key. Counted rather than silently dropped,
          // because it is the cost of rotating on every membership change.
          dropped++;
          continue;
        }
        if (_putHistory(node, entry.withSynced())) added++;
      }
      _historyEntriesSynced += added;
      _historyEpochDropped += dropped;
      if (added > 0) {
        _pushLog(
            MeshLogKind.sync,
            node.id,
            '${group.name}: ${node.name} recovered $added message${added == 1 ? '' : 's'} '
                'from ${_byId(msg.from)?.name ?? msg.from}'
                '${dropped > 0 ? ' ($dropped unreadable under epoch ${group.keyEpoch})' : ''}',
            peerId: msg.from,
            msgId: msg.id,
            msgType: MsgType.sync);
      }
    }
  }

  /// Whether every member of a group holds the same repairable history.
  bool historyConverged(Group group) {
    final members = <MeshNode>[];
    for (final id in group.members) {
      final n = _byId(id);
      if (n != null) members.add(n);
    }
    if (members.isEmpty) return true;
    final reference = historyDigest(syncableHistory(members.first, group).values);
    for (final m in members) {
      final d = historyDigest(syncableHistory(m, group).values);
      if (d.count != reference.count) return false;
      for (var i = 0; i < historyBuckets; i++) {
        if (d.buckets[i] != reference.buckets[i]) return false;
      }
    }
    return true;
  }

  List<Group> groupsOf(NodeId nodeId) =>
      groups.values.where((g) => g.members.contains(nodeId)).toList();

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
      _queue.cancel(EventKind.cover, node.id);
      _queue.cancel(EventKind.scan, node.id);
      _channel.remove(node.id);
      _queue.cancel(EventKind.channel, node.id);
      _txUntil.remove(node.id);
      _rxUntil.remove(node.id);
    } else {
      node.battery = math.max(node.battery, 0.3);
      node.uptimeMin = 0;
      node.offlineAt = -1;
      node.reasonTrace = 'Reconnected';
      _queue.push(now + 100, EventKind.ogm, node.id);
      if (config.coverTraffic) _queue.push(now + 100, EventKind.cover, node.id);
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
        // Group traffic is neither: it has its own denominator (`groupExpected`),
        // and folding it in here would let a 10-member group flatter deliveryRatio.
        // Media chunks are excluded as well: a 10 MB file is 160 of them, and
        // letting them into the ratio would make delivery about the file rather
        // than about the mesh.
        .where((d) =>
            d.type != MsgType.ack &&
            d.type != MsgType.broadcast &&
            d.type != MsgType.sync &&
            d.groupId == null &&
            d.transferId == null)
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

    // Not filtered on charging, unlike the battery rates: a plugged-in device still holds
    // its CPU awake for every packet it hears. The denominator is the network total, so the
    // two shares sum to 100 and neither can exceed it — the property that makes them
    // readable when the absolute milliseconds are not (see radioDemandRatio).
    double heldBy(Role role) => online
        .where((n) => n.role == role)
        .fold<double>(0, (sum, n) => sum + (_wakeLockMsByNode[n.id] ?? 0));
    final heldTotal = online.fold<double>(
        0, (sum, n) => sum + (_wakeLockMsByNode[n.id] ?? 0));
    double wakeShare(Role role) =>
        heldTotal == 0 ? 0 : (heldBy(role) / heldTotal) * 100;

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
      coverTx: _coverTx,
      retriesSent: _retriesSent,
      retriesExhausted: _retriesExhausted,
      acksReceived: _acksReceived,
      sentUnicast: _sentUnicast,
      sentBroadcast: _sentBroadcast,
      sosFloods: _sosFloods,
      sentGroup: _sentGroup,
      groupReceipts: _groupReceipts,
      groupExpected: _groupExpected,
      groupDeliveryRatio:
          _groupExpected > 0 ? _groupReceipts / _groupExpected : 0.0,
      groupEpochRejected: _groupEpochRejected,
      transfersStarted: _transfersStarted,
      transfersCompleted: _transfersCompleted,
      transferStalls: _transferStalls,
      sentChunks: _sentChunks,
      bytesDelivered: _bytesDelivered,
      routeExpiries: _routeExpiries,
      connectivitySamples: _connectivitySamples,
      connectedSampleShare: _connectivitySamples == 0
          ? 1.0
          : _connectedSamples / _connectivitySamples,
      meanLargestComponent: _connectivitySamples == 0
          ? 1.0
          : _largestComponentSum / _connectivitySamples,
      sentSync: _sentSync,
      historyBeacons: _historyBeacons,
      historyRequests: _historyRequests,
      historyReplies: _historyReplies,
      historyEntriesSynced: _historyEntriesSynced,
      historyEpochDropped: _historyEpochDropped,
      historyBytes: _historyBytes,
      bundlesPruned: _bundlesPruned,
      dtnSuperCarries: _dtnSuperCarries,
      dtnCommunityCarries: _dtnCommunityCarries,
      channelDeferrals: _channelDeferrals,
      channelDeferMs: _channelDeferMs,
      channelDrops: _channelDrops,
      channelCaptured: _channelCaptured,
      channelCaptureEffects: _channelCaptureEffects,
      channelDeafRx: _channelDeafRx,
      channelBackoffs: _channelBackoffs,
      channelDropsRelayed: _channelDropsRelayed,
      channelDropsMedia: _channelDropsMedia,
      channelDropsWithAlternative: _channelDropsWithAlternative,
      transferBlocks: _transferBlocks,
      rateBroadcastDrops: _rateBroadcastDrops,
      rateRelayDrops: _rateRelayDrops,
      blockedDrops: _blockedDrops,
      batteryPercentPerHourNormal: drainPerHour(Role.normal),
      batteryPercentPerHourSuper: drainPerHour(Role.superNode),
      scansPerSec: _scanCount / elapsedSec,
      relaysPerSec: _relayTx / elapsedSec,
      wakeLocks: _wakeLocksByNode.values.fold<int>(0, (a, b) => a + b),
      wakeLockMs: heldTotal,
      wakeLockShareNormal: wakeShare(Role.normal),
      wakeLockShareSuper: wakeShare(Role.superNode),
      radioDemandRatio:
          heldTotal / (math.max(1, online.length) * elapsedMs),
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
