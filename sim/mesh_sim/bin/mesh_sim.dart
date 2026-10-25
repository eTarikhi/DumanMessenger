/// Headless CLI for the Duman mesh simulator (skills/08).
///
///     dart run bin/mesh_sim.dart --scenario campus_quad --seed 42
///     dart run bin/mesh_sim.dart --scenario festival_crowd --nodes 80 --json
///
/// Exits non-zero when the acceptance criteria for the chosen scenario fail, so
/// CI can gate on it directly.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:duman_mesh_sim/mesh_sim.dart';

const int _defaultMessages = 150;
const double _defaultGapMs = 1500;

/// The A/B against naive flooding must feed *identical* traffic to both runs.
/// Drawing pairs from the simulation's own RNG does not do that: MPR's 300 ms
/// wait changes event interleaving, so the two runs consume the stream
/// differently and quietly become two different experiments.
List<List<int>> _trafficPlan(int seed, int count, int nodeCount) {
  final rng = createRng((seed ^ 0x5bf03635) & 0xFFFFFFFF);
  final plan = <List<int>>[];
  for (var i = 0; i < count; i++) {
    final from = (rng() * nodeCount).floor();
    var to = (rng() * nodeCount).floor();
    var guard = 0;
    while (to == from && guard++ < 32) {
      to = (rng() * nodeCount).floor();
    }
    if (to != from) plan.add(<int>[from, to]);
  }
  return plan;
}

int _replay(MeshSimulation sim, List<List<int>> plan, double gapMs) {
  var sent = 0;
  for (var i = 0; i < plan.length; i++) {
    final from = sim.nodes[plan[i][0]];
    final to = sim.nodes[plan[i][1]];
    if (from.isOnline && to.isOnline) {
      if (sim.sendMessage(from.id, to.id, 'cli-$i') != null) sent++;
    }
    sim.runFor(gapMs);
  }
  sim.refresh();
  return sent;
}

void _usage() {
  stdout.writeln('''
Duman mesh simulator (headless)

  --scenario <name>   ${scenarioNames().join(' | ')}   (default: campus_quad)
  --seed <int>        PRNG seed                            (default: 42)
  --nodes <int>       override node count
  --messages <int>    unicast messages to inject           (default: $_defaultMessages)
  --gap <ms>          simulated ms between messages        (default: ${_defaultGapMs.toInt()})
  --policy <name>     mpr | route-flood | flood-all        (default: mpr)
  --duty-cycle        NORMAL scans 3 s and sleeps 7 s (skills/07). Gates the
                      15%-per-8h battery budget, which an always-scanning
                      NORMAL node in a mobile population does not meet.
  --channel-access <name>
                      free | half-duplex | csma. What the medium does when two
                      radios talk at once (docs/08 §12.9-§12.10)
  --channel-capture <name>
                      none | first | strongest. What a busy *receiver* does:
                      take everything, lock onto the first packet, or let a
                      newcomer that is enough stronger take over (docs/08 §12.9,
                      §12.15)
  --capture-ratio <dB>
                      margin a newcomer must clear to take the receiver over
                      (default: 6; read only under --channel-capture strongest)
  --channel-queue <int>
                      transmit queue depth, so a busy radio buffers instead of
                      dropping (docs/08 §12.7)
  --channel-priority <name>
                      fifo | ack-first | by-class. Which queued packet a busy
                      radio takes next (docs/08 §12.8)
  --backoff <name>    none | binary. Wait a random number of slots before taking
                      a medium that has just freed up (docs/08 §12.13)
  --media-backpressure
                      stop a transfer pumping chunks into a radio that is full
                      (docs/08 §12.12)
  --rate-limits       enforce docs/04 §6's abuse limits: 5 broadcasts/min per node
                      (SUPERs drop excess) and 30 relayed msgs/min per source, with
                      control-plane traffic exempt
  --broadcast-cap-scope <name>
                      super | all. Who enforces the broadcast cap. `super` is what
                      docs/04 §6 says and bounds how far a flood travels; `all` also
                      stops the flooder's own neighbours hearing it (docs/06 §21.5)
  --cover-traffic       emit dummy beacons at a low rate (docs/04 §5's traffic-analysis
                        mitigation). Off by default; costs airtime and hides nothing this
                        engine cannot model — see docs/06 §23 for what it does and does not
                        cover. Reports coverTx
  --cover-interval <ms> Mean gap between a node's dummy beacons, default 30000. Read only
                        with --cover-traffic, like --capture-ratio is read only under
                        --channel-capture strongest
  --radio-occupancy <n> How long a packet holds a radio, which is not how long it takes to
                        arrive: hop-latency (ships, and is what docs/08 §12's contention
                        numbers were measured under) or airtime (bytes x 8 / kbps for the
                        whole packet, beacons sized from the fields an OGM carries).
                        Delivery latency is the same either way; under the shipped free/none
                        radio only the wake-lock telemetry moves. docs/06 §24.6
  --block-scope <name>
                      delivery | relay. How far a local block reaches (docs/04 §6,
                      "Block/mute peer locally"). `delivery` — the default — means the
                      blocking node ignores the message and the mesh still carries it;
                      `relay` also refuses to forward, which is §6's "ignore floods"
                      (docs/06 §22). Inert until something calls blockPeer()
  --trace             print the hop-by-hop route each delivered message took
  --capture           record the pcap-like mesh log and print its tail
  --capture-ogm       also log OGM beacons (they outnumber everything else)
  --group [N]         create an N-member group (default 5, spread across the
                      world) and report what a group message costs in both
                      delivery modes -- the docs/06 §14 measurement
  --history           form a group, take one member out of range while it talks, and
                      report whether hash-beacon anti-entropy repairs what it missed
                      (roadmap Phase 1, docs/06 §17)
  --media             run the media transport in a separate world and report what
                      a 10 MB image costs at 1/2/3 hops, what a BLE-only mesh can
                      still carry, and whether a push-to-talk note plays inside the
                      roadmap's budget (docs/08)
  --sos               fire an SOS from the edge of the world in a separate run
                      and report how far it got (roadmap Phase 3 exit criterion:
                      "SOS reaches all within ttl")
  --json              machine-readable metrics on stdout
  --no-check          report metrics without asserting the acceptance criteria
  -h, --help          this text
''');
}

String _arg(List<String> args, String name, String fallback) {
  final i = args.indexOf(name);
  return (i >= 0 && i + 1 < args.length) ? args[i + 1] : fallback;
}

void main(List<String> args) {
  if (args.contains('-h') || args.contains('--help')) {
    _usage();
    return;
  }

  final scenarioName = _arg(args, '--scenario', 'campus_quad');
  final seed = int.parse(_arg(args, '--seed', '42'));
  final messages = int.parse(_arg(args, '--messages', '$_defaultMessages'));
  final gapMs = double.parse(_arg(args, '--gap', '$_defaultGapMs'));
  final policyName = _arg(args, '--policy', 'mpr');
  final dutyCycle = args.contains('--duty-cycle');
  final showTrace = args.contains('--trace');
  final sosProbe = args.contains('--sos');
  final mediaProbe = args.contains('--media');
  final historyProbe = args.contains('--history');
  final groupProbe = args.contains('--group');
  final groupSize = int.parse(_arg(args, '--group', '5'));
  final capture = args.contains('--capture');
  final asJson = args.contains('--json');
  final noCheck = args.contains('--no-check');

  SimConfig config;
  try {
    config = buildScenario(scenarioName, seed);
  } on ArgumentError catch (e) {
    stderr.writeln(e.message);
    exitCode = 64;
    return;
  }
  if (dutyCycle) config = config.copyWith(dutyCycleEnabled: true);
  if (capture) {
    config = config.copyWith(
        captureLog: true, captureOgm: args.contains('--capture-ogm'));
  }
  final nodesOverride = args.indexOf('--nodes');
  if (nodesOverride >= 0 && nodesOverride + 1 < args.length) {
    config = config.copyWith(nodeCount: int.parse(args[nodesOverride + 1]));
  }
  switch (policyName) {
    case 'mpr':
      break;
    case 'route-flood':
      config = config.copyWith(relayPolicy: RelayPolicy.routeFlood);
      break;
    case 'flood-all':
      config = config.copyWith(relayPolicy: RelayPolicy.floodAll);
      break;
    default:
      stderr.writeln('Unknown --policy "$policyName". '
          'Try: mpr | route-flood | flood-all');
      exitCode = 64;
      return;
  }

  // --- the radio model of docs/08 §12 -----------------------------------------
  //
  // The engine has carried every one of these knobs since the measurements in docs/08 §12 were
  // taken, but the CLI never exposed them — so the six-arm contention table (§12.9-§12.10) and
  // the capture sweep (§12.15) could only be reproduced from inside a test file. In the one
  // engine the roadmap calls authoritative, from the one place a reader would not think to look.
  // Each switch is the --policy idiom above: an unknown name is a usage error that prints the
  // valid set, never a silent fall back to the default. An absent flag changes nothing at all,
  // so every published number and the golden vectors stay exactly where they were.
  var radioOverridden = false;

  final accessName = _arg(args, '--channel-access', '');
  if (accessName.isNotEmpty) {
    radioOverridden = true;
    switch (accessName) {
      case 'free':
        config = config.copyWith(channelAccess: ChannelAccess.free);
        break;
      case 'half-duplex':
        config = config.copyWith(channelAccess: ChannelAccess.halfDuplex);
        break;
      case 'csma':
        config = config.copyWith(channelAccess: ChannelAccess.csma);
        break;
      default:
        stderr.writeln('Unknown --channel-access "$accessName". '
            'Try: free | half-duplex | csma');
        exitCode = 64;
        return;
    }
  }

  final captureName = _arg(args, '--channel-capture', '');
  if (captureName.isNotEmpty) {
    radioOverridden = true;
    switch (captureName) {
      case 'none':
        config = config.copyWith(channelCapture: ChannelCapture.none);
        break;
      case 'first':
        config = config.copyWith(channelCapture: ChannelCapture.first);
        break;
      case 'strongest':
        config = config.copyWith(channelCapture: ChannelCapture.strongest);
        break;
      default:
        stderr.writeln('Unknown --channel-capture "$captureName". '
            'Try: none | first | strongest');
        exitCode = 64;
        return;
    }
  }

  final priorityName = _arg(args, '--channel-priority', '');
  if (priorityName.isNotEmpty) {
    radioOverridden = true;
    switch (priorityName) {
      case 'fifo':
        config = config.copyWith(channelPriority: ChannelPriority.fifo);
        break;
      case 'ack-first':
        config = config.copyWith(channelPriority: ChannelPriority.ackFirst);
        break;
      case 'by-class':
        config = config.copyWith(channelPriority: ChannelPriority.byClass);
        break;
      default:
        stderr.writeln('Unknown --channel-priority "$priorityName". '
            'Try: fifo | ack-first | by-class');
        exitCode = 64;
        return;
    }
  }

  final backoffName = _arg(args, '--backoff', '');
  if (backoffName.isNotEmpty) {
    radioOverridden = true;
    switch (backoffName) {
      case 'none':
        config = config.copyWith(channelBackoff: ChannelBackoff.none);
        break;
      case 'binary':
        config = config.copyWith(channelBackoff: ChannelBackoff.binary);
        break;
      default:
        stderr.writeln('Unknown --backoff "$backoffName". Try: none | binary');
        exitCode = 64;
        return;
    }
  }

  final ratioArg = _arg(args, '--capture-ratio', '');
  if (ratioArg.isNotEmpty) {
    // tryParse, not parse: a bad number is a usage error with a message, not a stack trace.
    final db = double.tryParse(ratioArg);
    if (db == null) {
      stderr.writeln('--capture-ratio needs a number in dB, got "$ratioArg"');
      exitCode = 64;
      return;
    }
    radioOverridden = true;
    config = config.copyWith(channelCaptureRatioDb: db);
  }

  final queueArg = _arg(args, '--channel-queue', '');
  if (queueArg.isNotEmpty) {
    final depth = int.tryParse(queueArg);
    if (depth == null || depth < 1) {
      stderr.writeln('--channel-queue needs a positive integer, got "$queueArg"');
      exitCode = 64;
      return;
    }
    radioOverridden = true;
    config = config.copyWith(channelQueueDepth: depth);
  }

  if (args.contains('--media-backpressure')) {
    radioOverridden = true;
    config = config.copyWith(mediaBackpressure: true);
  }

  // Not part of the radio model, so it does not set `radioOverridden`: the shipped
  // combination is inert by construction and this one is a policy switch.
  if (args.contains('--rate-limits')) {
    config = config.copyWith(rateLimits: true);
  }

  if (args.contains('--cover-traffic')) {
    config = config.copyWith(coverTraffic: true);
  }

  final coverArg = _arg(args, '--cover-interval', '');
  if (coverArg.isNotEmpty) {
    // tryParse, not parse: a bad number is a usage error with a message, not a stack trace.
    final ms = double.tryParse(coverArg);
    if (ms == null || ms <= 0) {
      stderr.writeln('--cover-interval needs a positive number of ms, got "$coverArg"');
      exitCode = 64;
      return;
    }
    config = config.copyWith(coverIntervalMs: ms);
  }

  final occupancyName = _arg(args, '--radio-occupancy', '');
  if (occupancyName.isNotEmpty) {
    switch (occupancyName) {
      case 'hop-latency':
        config = config.copyWith(radioOccupancy: RadioOccupancy.hopLatency);
        break;
      case 'airtime':
        config = config.copyWith(radioOccupancy: RadioOccupancy.airtime);
        break;
      default:
        stderr.writeln('Unknown --radio-occupancy "$occupancyName". '
            'Try: hop-latency | airtime');
        exitCode = 64;
        return;
    }
  }

  final blockScopeName = _arg(args, '--block-scope', '');
  if (blockScopeName.isNotEmpty) {
    switch (blockScopeName) {
      case 'delivery':
        config = config.copyWith(blockScope: BlockScope.delivery);
        break;
      case 'relay':
        config = config.copyWith(blockScope: BlockScope.relay);
        break;
      default:
        stderr.writeln('Unknown --block-scope "$blockScopeName". '
            'Try: delivery | relay');
        exitCode = 64;
        return;
    }
  }

  final capScopeName = _arg(args, '--broadcast-cap-scope', '');
  if (capScopeName.isNotEmpty) {
    switch (capScopeName) {
      case 'super':
        config =
            config.copyWith(broadcastCapScope: BroadcastCapScope.superOnly);
        break;
      case 'all':
        config = config.copyWith(broadcastCapScope: BroadcastCapScope.all);
        break;
      default:
        stderr.writeln('Unknown --broadcast-cap-scope "$capScopeName". '
            'Try: super | all');
        exitCode = 64;
        return;
    }
  }

  // Built here rather than nested inside the header's own interpolation, which would put a
  // string literal containing an interpolation inside a ternary inside an interpolation.
  final radioArm = radioOverridden
      ? ', radio ${config.channelAccess.name}+${config.channelCapture.name}'
      : '';

  final plan = _trafficPlan(config.seed, messages, config.nodeCount);
  final sim = MeshSimulation(config);
  final sent = _replay(sim, plan, gapMs);

  // The two A/B arms from docs/06 §7, so one invocation reproduces the whole
  // overhead table: naive epidemic flooding is the baseline the acceptance
  // criteria name, and routing-without-suppression is the only arm that isolates
  // what MPR still buys once the route table works.
  final baseline = MeshSimulation(config.copyWith(relayPolicy: RelayPolicy.floodAll));
  _replay(baseline, plan, gapMs);

  MeshSimulation? routeOnly;
  if (config.relayPolicy != RelayPolicy.routeFlood) {
    routeOnly =
        MeshSimulation(config.copyWith(relayPolicy: RelayPolicy.routeFlood));
    _replay(routeOnly, plan, gapMs);
  }

  // A separate run: an SOS fan-out costs thousands of transmissions, and folding
  // that into this one would make the overhead ratio meaningless.
  final sos = sosProbe ? _sosProbe(config) : null;
  // Also separate: a group flood costs the whole network relays, so folding it
  // into the overhead measurement would report the group's cost as routing's.
  final group = (groupProbe || args.contains('--group'))
      ? _groupProbe(config, groupSize)
      : null;
  // Separate again: one 10 MB file is 160 chunks and thousands of relays, and
  // folding that into this run would report a file transfer's cost as routing's.
  final media = mediaProbe ? _mediaProbe(config) : null;
  // And again separate: repairing a group's history is background traffic that has
  // nothing to do with the delivery ratio this run is asserting.
  final history = historyProbe ? _historyProbe(config) : null;

  final s = sim.stats;
  final unicast = sim.deliveries
      .where((d) => d.type != MsgType.ack && d.type != MsgType.broadcast)
      .toList();
  final withinFive = unicast.where((d) => d.hops <= 5).length;
  final overheadVsFlood =
      s.totalForwarded / math.max(1, baseline.stats.totalForwarded);

  final report = <String, Object?>{
    'scenario': scenarioName,
    'seed': seed,
    'policy': policyName,
    // Which radio model this run used. Present unconditionally, so two arms of one scenario can
    // be told apart from their JSON alone; the human table below skips it and carries the arm in
    // the header line instead.
    'radio': <String, Object?>{
      'channelAccess': config.channelAccess.name,
      'channelCapture': config.channelCapture.name,
      'captureRatioDb': _round(config.channelCaptureRatioDb),
      'channelQueueDepth': config.channelQueueDepth,
      'channelPriority': config.channelPriority.name,
      'channelBackoff': config.channelBackoff.name,
      'mediaBackpressure': config.mediaBackpressure,
      'rateLimits': config.rateLimits,
      'broadcastPerMinuteCap': config.broadcastPerMinuteCap,
      'relayPerSourcePerMinuteCap': config.relayPerSourcePerMinuteCap,
      'broadcastCapScope': config.broadcastCapScope.wire,
      'blockScope': config.blockScope.wire,
      'coverTraffic': config.coverTraffic,
      'coverIntervalMs': config.coverIntervalMs,
      'radioOccupancy': config.radioOccupancy.wire,
    },
    'nodes': sim.nodes.length,
    'sent': sent,
    'deliveredUnicast': unicast.length,
    'deliveryRatio': _round(s.deliveryRatio),
    'deliveredWithinFiveHops': withinFive,
    'withinFiveRatio': _round(withinFive / math.max(1, sent)),
    'superNodes': s.superNodes,
    'superRatio': _round(s.superRatio),
    'timeAvgSuperRatio': _round(sim.timeAvgSuperRatio),
    'electionsPerMin': _round(s.electionsPerMin),
    'avgHops': _round(s.avgHops),
    'latencyP50Ms': _round(s.p50LatencyMs),
    'latencyP95Ms': _round(s.p95LatencyMs),
    'relayTx': s.totalForwarded,
    'floodAllRelayTx': baseline.stats.totalForwarded,
    'overheadVsFloodAll': _round(overheadVsFlood),
    // null when route-flood *is* the selected policy: there is nothing to
    // compare it against that the run has not already measured.
    'routeFloodRelayTx': routeOnly?.stats.totalForwarded,
    'overheadVsRouteFlood': routeOnly == null
        ? null
        : _round(s.totalForwarded / math.max(1, routeOnly.stats.totalForwarded)),
    'overheadRatio': _round(s.overheadRatio),
    'mprSuppressed': s.mprSuppressed,
    'retriesSent': s.retriesSent,
    'retriesExhausted': s.retriesExhausted,
    'acksReceived': s.acksReceived,
    'controlOverhead': s.controlOverhead,
    'lostTransmissions': s.lostTransmissions,
    'lostOgmTransmissions': s.lostOgmTransmissions,
    'totalQueued': s.totalQueued,
    'avgPeers': _round(s.avgPeers),
    'isolatedNodes': s.isolatedNodes,
    'avgScore': _round(s.avgScore),
    'simTimeMs': s.simTimeMs,
    // skills/07 telemetry and the roadmap's Phase 2 "battery %/h, latency by
    // hop". Measured over the post-warm-up window, not read off the drain model.
    'dutyCycle': config.dutyCycleEnabled,
    'batteryPctPerHourNormal': _round(s.batteryPercentPerHourNormal),
    'batteryPctPerHourSuper': _round(s.batteryPercentPerHourSuper),
    'batteryPct8hNormal': _round(s.batteryPercentPerHourNormal * 8),
    'batteryPct8hSuper': _round(s.batteryPercentPerHourSuper * 8),
    'scansPerSec': _round(s.scansPerSec),
    'relaysPerSec': _round(s.relaysPerSec),
    'awakeRatio': _round(s.awakeRatio),
    'scansSkippedAsleep': s.scansSkippedAsleep,
    'electionEvents': s.electionEvents,
    if (showTrace)
      'traces': sim.deliveries.take(40).map((d) {
        final chain = deliveredChain(d.hopTrace, d.to);
        return <String, Object?>{
          'msgId': d.msgId,
          'from': d.from,
          'to': d.to,
          'hops': d.hops,
          'latencyMs': _round(d.latencyMs),
          'dtn': d.dtn,
          'attempt': d.attempt,
          'route': <NodeId>[d.from, ...chain.map((h) => h.nodeId)],
          'hopTrace': chain.map((h) => h.toJson()).toList(),
        };
      }).toList(),
    if (capture)
      'logTail': sim.log
          .skip(math.max(0, sim.log.length - 50))
          .map((e) => e.toJson())
          .toList(),
    if (sos != null) 'sos': sos,
    if (group != null) 'group': group,
    if (media != null) 'media': media,
    if (history != null) 'history': history,
    'latencyByHop': s.latencyByHop.map((b) => <String, Object?>{
          'hops': b.hops,
          'count': b.count,
          'avgMs': _round(b.avgMs),
          'p95Ms': _round(b.p95Ms),
        }).toList(),
  };

  if (asJson) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  } else {
    stdout.writeln('Duman mesh simulator — $scenarioName '
        '(seed $seed, policy $policyName'
        '${config.dutyCycleEnabled ? ', duty-cycle' : ''}$radioArm)');
    stdout.writeln('─' * 62);
    report.forEach((k, v) {
      if (k == 'latencyByHop' || k == 'radio') return;
      stdout.writeln('  ${k.padRight(24)} $v');
    });
    if (group != null) {
      stdout.writeln('\nGroup probe (${group['members']} members spread across the world, '
          '${group['sends']} messages each)');
      for (final mode in <String>['scopedFlood', 'perMemberUnicast']) {
        final m = group[mode] as Map<String, Object?>;
        if (m.containsKey('error')) {
          stdout.writeln('  ${mode.padRight(20)} ${m['error']}');
          continue;
        }
        stdout.writeln('  ${mode.padRight(20)} delivery ${(m['deliveryPct'] as num).toStringAsFixed(1)}%  '
            'tx/msg ${m['txPerMsg']}  receipts ${m['receipts']}/${m['expected']}  '
            'p95 ${m['p95Ms']} ms  retries ${m['retries']}  acks ${m['acks']}');
      }
      stdout.writeln('  ${(group['verdict'] as String)}');
    }
    if (history != null) {
      stdout.writeln('\nHistory probe (${history['members']} members, '
          '${history['messages']} messages, one member out of range for all of them)');
      stdout.writeln('  ${'member held'.padRight(22)}${history['heldBefore']} entries '
          '(missed ${history['missed']})');
      stdout.writeln('  ${'without repair'.padRight(22)}${history['offRecovered']} recovered, '
          'converged=${history['offConverged']} — a missed flood is missed for good');
      stdout.writeln('  ${'with repair'.padRight(22)}${history['recovered']} recovered in '
          '${history['convergedSeconds']} s (${history['rounds']} beacon rounds)');
      stdout.writeln('  ${'radio cost'.padRight(22)}${history['beacons']} beacons, '
          '${history['requests']} requests, ${history['replies']} replies = '
          '${history['syncPackets']} packets, ${history['bytes']} payload bytes');
      stdout.writeln('  ${'one beacon is'.padRight(22)}${history['beaconChars']} characters '
          '-> ${history['beaconWire']} B on the wire (${history['beaconTransport']}), '
          'constant in the size of the history');
      stdout.writeln('  ${history['verdict']}');
    }

    if (media != null) {
      stdout.writeln('\nMedia probe (10 MB image, 64 KB chunks behind a '
          '${config.transferWindow}-deep window; 3 s Opus note in '
          '${config.voiceFrameMs.toStringAsFixed(0)} ms frames at '
          '${config.voiceKbps.toStringAsFixed(0)} kbit/s)');
      stdout.writeln('  ${'hops'.padRight(5)}${'transport'.padRight(12)}'
          '${'chunks'.padRight(8)}${'time'.padRight(11)}${'kbit/s'.padRight(9)}'
          '${'retrans'.padRight(9)}stalls');
      for (final f in (media['files'] as List).cast<Map<String, Object?>>()) {
        stdout.writeln('  ${'${f['hops']}'.padRight(5)}${'${f['transport']}'.padRight(12)}'
            '${'${f['chunks']}'.padRight(8)}'
            '${(f['ms'] == null ? 'TIMEOUT' : '${f['ms']} ms').padRight(11)}'
            '${'${f['kbps'] ?? '-'}'.padRight(9)}${'${f['retransmitted']}'.padRight(9)}'
            '${f['stalls']}');
      }
      final ble = media['bleOnly'] as Map<String, Object?>;
      stdout.writeln('  BLE-only at the ${ble['mtuBytes']} B MTU skills/05 specifies '
          '(no Wi-Fi Direct peer): '
          '${ble['complete'] == true ? '${ble['ms']} ms' : 'not finished in 15 min'} '
          'for 10 MB over ${ble['chunks']} chunks');
      for (final row
          in (media['bleLadder'] as List).cast<Map<String, Object?>>()) {
        final kb = (row['bytes'] as int) ~/ 1024;
        final outcome = row['complete'] == true
            ? '${row['ms']} ms'
            : '>5 min (${row['received']}/${row['chunks']} chunks)';
        stdout.writeln('    $kb KB over BLE → $outcome');
      }
      stdout.writeln('  ${'note'.padRight(6)}${'mode'.padRight(10)}${'hops'.padRight(6)}'
          '${'radio'.padRight(12)}${'first audio'.padRight(13)}${'play delay'.padRight(12)}'
          '${'max gap'.padRight(10)}${'underruns'.padRight(11)}budget');
      for (final v in (media['voice'] as List).cast<Map<String, Object?>>()) {
        stdout.writeln('  ${'3 s'.padRight(6)}${'${v['mode']}'.padRight(10)}${'${v['hops']}'.padRight(6)}'
            '${'${v['transport']}'.padRight(12)}${'${v['firstAudioMs']} ms'.padRight(13)}'
            '${(v['playDelayMs'] == null ? 'TIMEOUT' : '${v['playDelayMs']} ms').padRight(12)}'
            '${'${v['maxGapMs']} ms'.padRight(10)}${'${v['underruns']}'.padRight(11)}'
            '${v['meetsBudget'] == true ? 'PASS' : 'FAIL'} (<${(v['budgetMs'] as num) ~/ 1000} s)');
      }
      final acc = media['acceptance'] as Map<String, Object?>;
      stdout.writeln('  skills/05 acceptance:');
      stdout.writeln('    [1] 1-hop Wi-Fi PTT round trip '
          '${acc['wifiPttRoundTripMs']} ms (buffer excluded '
          '${acc['wifiPttBufferExcludedMs']} ms) → '
          '${acc['wifiPttUnder1s'] == true ? 'PASS <1 s' : 'FAIL'}');
      stdout.writeln('    [2] 3-hop BLE voice note '
          '${acc['bleNoteFrames']}/${acc['bleNoteFrameCount']} frames → '
          '${acc['bleNoteIntact'] == true ? 'intact PASS' : 'INCOMPLETE'}');
      final r = acc['resume'] as Map<String, Object?>?;
      final resumed = acc['resumeAfterDisconnect'] == true
          ? 'resumed, ${r?['ms']} ms PASS'
          : 'DID NOT RESUME';
      stdout.writeln('    [3] 10 MB Wi-Fi Direct, receiver offline at '
          '${r?['atDisconnect']}/${r?['chunks']} chunks for 20 s → $resumed '
          '(${r?['stalls']} window stalls, ${r?['stallsWhileAway']} while away)');
      stdout.writeln('    [ ] 11 MB send → '
          '${acc['overCeilingRefused'] == true ? 'refused' : 'ACCEPTED'} '
          '(skills/05 "Max 10 MB")');
      final ch = media['channel'] as Map<String, Object?>?;
      if (ch != null) {
        stdout.writeln('  channel access (docs/08 §12) — `free` is the shipped model:');
        stdout.writeln('    ${'model'.padRight(11)}${'window'.padRight(7)}'
            '${'10 MB @3 hops'.padRight(15)}retrans  dropped');
        for (final f in (ch['files'] as List).cast<Map<String, Object?>>()) {
          final ms = f['ms'];
          stdout.writeln('    ${'${f['channel']}'.padRight(11)}'
              '${'${f['window']}'.padRight(7)}'
              '${(f['complete'] == true ? '${ms} ms' : 'TIMEOUT').padRight(15)}'
              '${'${f['retransmitted']}'.padRight(8)}${f['drops']}');
        }
        stdout.writeln('    ${'model'.padRight(11)}${'arm'.padRight(11)}'
            '${'delivery'.padRight(10)}${'retries'.padRight(8)}'
            '${'parked'.padRight(7)}${'deferred'.padRight(10)}'
            '${'dropped'.padRight(9)}file done');
        for (final t in (ch['text'] as List).cast<Map<String, Object?>>()) {
          stdout.writeln('    ${'${t['channel']}'.padRight(11)}'
              '${'${t['arm']}'.padRight(11)}${'${t['ratio']}'.padRight(10)}'
              '${'${t['retries']}'.padRight(8)}${'${t['parked']}'.padRight(7)}'
              '${'${t['deferMs']} ms'.padRight(10)}'
              '${'${t['drops']}'.padRight(9)}'
              '${t['arm'] == 'quiet' ? '—' : (t['fileComplete'] == true ? 'yes' : 'no')}');
        }
        final prio = (ch['priority'] as List?)?.cast<Map<String, Object?>>();
        if (prio != null && prio.isNotEmpty) {
          stdout.writeln('    queue discipline on one radio (docs/08 §12.8):');
          for (final r in prio) {
            stdout.writeln('      ${'${r['arm']}'.padRight(28)}'
                '${'${r['priority']}'.padRight(10)}'
                '${'${r['what']} ${r['ms']} ms'.padRight(26)}${r['metric']}');
          }
        }
      }
      stdout.writeln('  ${media['verdict']}');
    }

    if (sos != null) {
      stdout.writeln('\nSOS probe (edge sender ${sos['sender']}, ttl '
          '${config.sosTtl}, ${config.sosRepeats} repeats, '
          '${(config.sosRepeatMs / 1000).toStringAsFixed(0)} s apart)');
      stdout.writeln('  ${'floods on air'.padRight(26)} ${sos['floods']}');
      stdout.writeln('  ${'radio-connected peers'.padRight(26)} '
          '${sos['componentPeers']}/${sos['onlinePeers']}');
      stdout.writeln('  ${'reached (component)'.padRight(26)} '
          '${sos['reachedComponent']}/${sos['componentPeers']}  '
          '${sos['componentReachPct']}%');
      stdout.writeln('  ${'reached (all online)'.padRight(26)} '
          '${sos['reachedAll']}/${sos['onlinePeers']}  ${sos['allReachPct']}%');
      stdout.writeln('  ${'last node heard at'.padRight(26)} ${sos['tLastMs']} ms');
      stdout.writeln('  ${'data transmissions'.padRight(26)} ${sos['dataTx']}');
      stdout.writeln('  ${'radio receipts'.padRight(26)} ${sos['radioReceipts']} '
          '→ ${sos['reachedAll']} alerts (repeats collapse)');
      final missed = sos['missed'] as List<Object?>;
      if (missed.isEmpty) {
        stdout.writeln('  ${'missed in component'.padRight(26)} none');
      } else {
        stdout.writeln('  ${'missed in component'.padRight(26)} ${missed.join(', ')}');
      }
    }
    if (showTrace) {
      final traced = sim.deliveries.take(20).toList();
      stdout.writeln('\nHop traces (${sim.deliveries.length} deliveries, showing ${traced.length})');
      for (final d in traced) {
        final chain = deliveredChain(d.hopTrace, d.to);
        final relays = chain.length > 1 ? chain.sublist(0, chain.length - 1) : <HopRecord>[];
        final supers = relays
            .where((h) => sim.nodes.any((n) => n.id == h.nodeId && n.role == Role.superNode))
            .map((h) => h.nodeId)
            .toList();
        stdout.writeln('  ${d.msgId} ${d.from} → ${d.to} · ${d.hops} hop(s) · '
            '${d.latencyMs.toStringAsFixed(0)} ms'
            '${d.dtn ? ' · DTN' : ''}${d.attempt > 0 ? ' · retry ${d.attempt}' : ''}');
        final viaLabel = relays.isEmpty
            ? 'direct — no relay'
            : 'via ${relays.length} node(s)';
        final superLabel =
            supers.isEmpty ? '' : ' • SUPER ${supers.join(', ')}';
        stdout.writeln('    $viaLabel$superLabel');
        for (var i = 0; i < chain.length; i++) {
          final h = chain[i];
          stdout.writeln('      ${i + 1}. ${h.nodeId.padRight(9)} '
              '${h.rssi.toStringAsFixed(0).padLeft(4)} dBm  '
              '+${h.atMs.toStringAsFixed(0).padLeft(7)} ms  '
              '${h.action.name.padRight(11)} ${h.reason ?? ''}');
        }
      }
    }
    if (capture) {
      final tail = sim.log.skip(math.max(0, sim.log.length - 30)).toList();
      stdout.writeln('\nMesh log (${sim.log.length} captured, last ${tail.length})');
      for (final e in tail) {
        stdout.writeln('  ${(e.atMs / 1000).toStringAsFixed(2)}s '
            '${e.kind.name.padRight(10)} ${e.nodeId.padRight(9)} ${e.detail}');
      }
    }
    if (s.latencyByHop.isNotEmpty) {
      stdout.writeln('  ${'latencyByHop'.padRight(24)} hops      n     avg     p95');
      for (final b in s.latencyByHop) {
        stdout.writeln('  ${''.padRight(24)} ${b.hops.toString().padLeft(4)}'
            '${b.count.toString().padLeft(7)}'
            '${b.avgMs.toStringAsFixed(0).padLeft(6)} ms'
            '${b.p95Ms.toStringAsFixed(0).padLeft(6)} ms');
      }
    }
  }

  if (noCheck) return;

  // skills/02 + skills/08 acceptance criteria. The DTN scenarios are
  // deliberately partitioned, so the delivery bar only applies where the world
  // is actually connected.
  final failures = <String>[];
  final connected = s.isolatedNodes == 0;
  if (s.superRatio < 0.15 || s.superRatio > 0.25) {
    failures.add('SUPER ratio ${(s.superRatio * 100).toStringAsFixed(0)}% outside 15-25%');
  }
  if (s.electionsPerMin > 1) {
    failures.add('election flapping ${s.electionsPerMin.toStringAsFixed(2)}/node/min > 1');
  }
  // skills/07: "Android 8h NORMAL: <15% extra drain vs idle". Only gated when
  // the duty cycle is on, because that is the configuration the criterion
  // describes — an always-scanning NORMAL node measures 18-25% per 8 h once
  // mobility is included (docs/06 §7), i.e. the sleep slot is load-bearing for
  // the budget rather than a refinement of it.
  if (config.dutyCycleEnabled && s.batteryPercentPerHourNormal * 8 >= 15) {
    failures.add('NORMAL battery '
        '${(s.batteryPercentPerHourNormal * 8).toStringAsFixed(1)}% per 8h >= 15%');
  }
  if (connected) {
    if (s.deliveryRatio < 0.90) {
      failures.add('delivery ${(s.deliveryRatio * 100).toStringAsFixed(1)}% < 90%');
    }
    if (withinFive / math.max(1, sent) < 0.90) {
      failures.add('<5-hop delivery ${(withinFive / math.max(1, sent) * 100).toStringAsFixed(1)}% < 90%');
    }
    if (overheadVsFlood > 0.70) {
      failures.add('overhead ${(overheadVsFlood * 100).toStringAsFixed(0)}% of flood-all > 70%');
    }
  }

  if (failures.isEmpty) {
    if (!asJson) stdout.writeln('\nPASS — acceptance criteria met.');
    return;
  }
  stderr.writeln('\nFAIL — ${failures.length} acceptance criteria not met:');
  for (final f in failures) {
    stderr.writeln('  • $f');
  }
  exitCode = 1;
}

double _round(num v) => double.parse(v.toStringAsFixed(4));


/// Fire one SOS from the edge of the world and measure how far it got.
///
/// "SOS reaches all within ttl" (roadmap Phase 3, docs/05 §"Exit criteria") is
/// only meaningful against the nodes a chain of radio links can actually reach:
/// in the sparse_village world 3 of 11 online nodes share a component with any
/// given sender, and no protocol choice closes that. So the probe reports reach
/// both ways — component-relative, which is the protocol's responsibility, and
/// raw.
Map<String, Object?> _sosProbe(SimConfig config) {
  final sim = MeshSimulation(config);
  // 90 s to settle elections and routes before the emergency, then a clean slate.
  sim.runFor(90000);
  sim.clearRecords();

  final online = sim.nodes.where((n) => n.isOnline).toList();
  final cx = online.fold<double>(0, (a, n) => a + n.pos.x) / online.length;
  final cy = online.fold<double>(0, (a, n) => a + n.pos.y) / online.length;
  var sender = online.first;
  for (final n in online) {
    final d = (n.pos.x - cx) * (n.pos.x - cx) + (n.pos.y - cy) * (n.pos.y - cy);
    final b =
        (sender.pos.x - cx) * (sender.pos.x - cx) + (sender.pos.y - cy) * (sender.pos.y - cy);
    if (d > b) sender = n;
  }

  final comp = _component(sim, sender);
  final t0 = sim.now;
  final msg = sim.sendMessage(
      sender.id, broadcastAddress, 'injured, need help', MsgType.sos);
  sim.runFor(45000);
  sim.refresh();

  final others = sim.nodes.where((n) => n.isOnline && n.id != sender.id).toList();
  final inComp = others.where((n) => comp.contains(n.id)).toList();
  final sosId = msg?.sosId ?? '';
  bool heard(MeshNode n) => n.inbox.any((m) => m.sosId == sosId);
  final reachedComp = inComp.where(heard).toList();
  final reachedAll = others.where(heard).toList();

  final sosIds = sim.sentRecords
      .where((r) => r.type == MsgType.sos && r.from == sender.id)
      .map((r) => r.msgId)
      .toSet();
  final first = <NodeId, double>{};
  for (final d in sim.deliveries) {
    if (sosIds.contains(d.msgId)) first.putIfAbsent(d.to, () => d.timestamp);
  }
  final tLast =
      first.isEmpty ? -1.0 : first.values.reduce(math.max) - t0;

  return <String, Object?>{
    'sender': sender.id,
    'senderPos': <String, double>{'x': sender.pos.x, 'y': sender.pos.y},
    'floods': sim.stats.sosFloods,
    'onlinePeers': others.length,
    'componentPeers': inComp.length,
    'reachedComponent': reachedComp.length,
    'reachedAll': reachedAll.length,
    'componentReachPct':
        _round(100 * reachedComp.length / math.max(1, inComp.length)),
    'allReachPct': _round(100 * reachedAll.length / math.max(1, others.length)),
    'tLastMs': _round(tLast),
    'dataTx': sim.stats.totalForwarded,
    'radioReceipts': sim.deliveries.where((d) => sosIds.contains(d.msgId)).length,
    'missed': inComp.where((n) => !heard(n)).map((n) => n.id).toList(),
  };
}

/// Every node a chain of radio links reaches from [start], at this instant.
Set<NodeId> _component(MeshSimulation sim, MeshNode start) {
  final seen = <NodeId>{start.id};
  final stack = <MeshNode>[start];
  while (stack.isNotEmpty) {
    final n = stack.removeLast();
    if (!n.isOnline) continue;
    for (final p in peersInRange(n, sim.nodes, sim.rf)) {
      if (p.isOnline && !seen.contains(p.id)) {
        seen.add(p.id);
        stack.add(p);
      }
    }
  }
  return seen;
}

/// What a group message costs, in both delivery modes, on the same world and the
/// same traffic (docs/06 §14).
///
/// Run separately from the main report for the same reason as the SOS probe: a
/// scoped group flood is relayed by the whole network, so charging it to the
/// routing overhead ratio would misattribute the cost.
Map<String, Object?> _groupProbe(SimConfig config, int size) {
  const sends = 5;
  final modes = <String, Map<String, Object?>>{};

  for (final mode in GroupMode.values) {
    final sim = MeshSimulation(config.copyWith(groupMode: mode));
    sim.runFor(90000);
    sim.clearRecords();

    final online = sim.nodes.where((n) => n.isOnline).toList();
    final cx = online.fold<double>(0, (a, n) => a + n.pos.x) / online.length;
    final cy = online.fold<double>(0, (a, n) => a + n.pos.y) / online.length;
    double d2(MeshNode n) =>
        (n.pos.x - cx) * (n.pos.x - cx) + (n.pos.y - cy) * (n.pos.y - cy);
    // Spread across the world by rank, so the group is not one radio cell.
    final ranked = online.toList()..sort((a, b) => d2(b).compareTo(d2(a)));
    final step = ranked.length ~/ math.max(1, size);
    final ids = <NodeId>{};
    for (var i = 0; i < ranked.length && ids.length < size; i++) {
      ids.add(ranked[(i * step) % ranked.length].id);
    }
    final group = sim.createGroup('field team', ids.toList(), ids.first);
    if (group == null) {
      modes[mode.name] = <String, Object?>{'error': 'could not form a group of $size'};
      continue;
    }

    for (var i = 0; i < sends; i++) {
      sim.sendMessage(ids.first, group.id, 'status $i');
      sim.runFor(4000);
    }
    sim.refresh();
    final lat = sim.deliveries
        .where((d) => d.groupId == group.id)
        .map((d) => d.latencyMs)
        .toList()
      ..sort();
    modes[mode.name] = <String, Object?>{
      'deliveryPct': _round(100 * sim.stats.groupDeliveryRatio),
      'receipts': sim.stats.groupReceipts,
      'expected': sim.stats.groupExpected,
      'radioMessages': sim.stats.sentGroup,
      'txPerMsg': _round(sim.stats.totalForwarded / sends),
      'p95Ms': _round(lat.isEmpty
          ? 0.0
          : lat[math.max(0, math.min(lat.length - 1, (lat.length * 0.95).floor()))]),
      'retries': sim.stats.retriesSent,
      'acks': sim.stats.acksReceived,
      'epochRejected': sim.stats.groupEpochRejected,
    };
  }

  final floodTx = (modes[GroupMode.scopedFlood.name]?['txPerMsg'] as num?) ?? 0;
  final uniTx = (modes[GroupMode.perMemberUnicast.name]?['txPerMsg'] as num?) ?? 0;
  final String verdict;
  if (uniTx <= 0 || floodTx <= 0) {
    verdict = 'not enough traffic to compare';
  } else if (uniTx < floodTx) {
    verdict = 'per-member unicast is ${(floodTx / uniTx).toStringAsFixed(1)}x cheaper here '
        '(members are close enough that the route table can aim each copy)';
  } else {
    verdict = 'scoped flood is ${(uniTx / floodTx).toStringAsFixed(1)}x cheaper here '
        '(members are far enough that each routed copy fans out anyway)';
  }
  return <String, Object?>{
    'members': size,
    'sends': sends,
    GroupMode.scopedFlood.name: modes[GroupMode.scopedFlood.name],
    GroupMode.perMemberUnicast.name: modes[GroupMode.perMemberUnicast.name],
    'verdict': verdict,
  };
}

/// Run the media transport end to end and report what it costs (roadmap Phase 3
/// exit criteria, docs/08).
///
/// Separate world, like the SOS and group probes: one 10 MB file is 160 chunks and
/// thousands of relays, which would otherwise be reported as routing overhead.
Map<String, Object?> _mediaProbe(SimConfig config) {
  const tenMb = 10 * 1048576;

  /// skills/05: "chunked BLE 512B MTU" — what a file is sliced into when there is
  /// no Wi-Fi Direct group owner to carry it.
  const bleMtu = 512;

  MeshSimulation fresh() {
    final sim = MeshSimulation(config.copyWith(trafficIntervalMs: 0));
    sim.runFor(90000);
    sim.clearRecords();
    return sim;
  }

  bool runUntil(MeshSimulation sim, bool Function() done, double budgetMs) {
    var elapsed = 0.0;
    while (!done() && elapsed < budgetMs) {
      sim.runFor(250);
      elapsed += 250;
    }
    return done();
  }

  /// Shortest hop count from [from] to every online node, over links that can carry
  /// a packet right now.
  Map<NodeId, int> bfs(MeshSimulation sim, MeshNode from) {
    final online = sim.nodes.where((n) => n.isOnline).toList();
    final dist = <NodeId, int>{from.id: 0};
    final queue = <MeshNode>[from];
    while (queue.isNotEmpty) {
      final n = queue.removeAt(0);
      final d = dist[n.id]!;
      for (final p in peersInRange(n, online, sim.rf)) {
        if (!dist.containsKey(p.id)) {
          dist[p.id] = d + 1;
          queue.add(p);
        }
      }
    }
    return dist;
  }

  /// A pair exactly [hops] apart, preferring clean endpoint radios so the
  /// measurement is about distance rather than about retransmission.
  List<MeshNode>? pairAt(MeshSimulation sim, int hops) {
    final online = sim.nodes.where((n) => n.isOnline).toList();
    double bestLeg(MeshNode n) {
      final peers = peersInRange(n, online, sim.rf);
      if (peers.isEmpty) return 1.0;
      return peers
          .map((p) =>
              effectiveLossProbability(n, p, sim.rf, config.linkRetries))
          .reduce((x, y) => x < y ? x : y);
    }

    List<MeshNode>? best;
    var bestLoss = 2.0;
    for (final a in online) {
      final dist = bfs(sim, a);
      for (final b in online) {
        if (b.id == a.id || dist[b.id] != hops) continue;
        if (hops == 1 && !canReach(a, b, sim.rf)) continue;
        final loss = math.max(bestLeg(a), bestLeg(b));
        if (loss < bestLoss) {
          bestLoss = loss;
          best = <MeshNode>[a, b];
        }
      }
    }
    return best;
  }

  // --- a 10 MB image at 1, 2 and 3 hops ------------------------------------
  final files = <Map<String, Object?>>[];
  for (final hops in <int>[1, 2, 3]) {
    final sim = fresh();
    final pair = pairAt(sim, hops);
    if (pair == null) {
      files.add(<String, Object?>{'hops': hops, 'error': 'no pair that far apart'});
      continue;
    }
    final t = sim.sendFile(pair[0].id, pair[1].id, tenMb);
    if (t == null) {
      files.add(<String, Object?>{'hops': hops, 'error': 'sender offline'});
      continue;
    }
    final done =
        runUntil(sim, () => t.state == TransferState.complete, 600000);
    files.add(<String, Object?>{
      'hops': hops,
      'chunks': t.chunks,
      'transport': t.transport.name,
      'complete': done,
      'ms': t.completedAt == null ? null : _round(t.completedAt! - t.startedAt),
      'kbps': t.completedAt == null
          ? null
          : _round(tenMb * 8 / (t.completedAt! - t.startedAt)),
      'retransmitted': t.retransmitted,
      'stalls': t.stalls,
    });
  }

  // --- the same file with no Wi-Fi Direct peer ------------------------------
  final bleSim = fresh();
  final blePair = pairAt(bleSim, 1);
  final ble = blePair == null
      ? null
      : bleSim.sendFile(blePair[0].id, blePair[1].id, tenMb, chunkBytes: bleMtu);
  final bleDone = ble == null
      ? false
      : runUntil(bleSim, () => ble.state == TransferState.complete, 900000);
  final bleOnly = <String, Object?>{
    'chunks': ble?.chunks ?? 0,
    'transport': ble?.transport.name ?? 'ble',
    'complete': bleDone,
    'ms': (ble == null || ble.completedAt == null)
        ? null
        : _round(ble.completedAt! - ble.startedAt),
    'receivedIn15Min': ble?.received ?? 0,
    'mtuBytes': bleMtu,
  };

  // What a BLE-only mesh can still do inside a minute, at the same MTU.
  final bleLadder = <Map<String, Object?>>[];
  for (final size in <int>[262144, 1048576, 2 * 1048576, 5 * 1048576]) {
    final sim = fresh();
    final pair = pairAt(sim, 1);
    if (pair == null) continue;
    final t = sim.sendFile(pair[0].id, pair[1].id, size, chunkBytes: bleMtu);
    if (t == null) continue;
    final done =
        runUntil(sim, () => t.state == TransferState.complete, 300000);
    bleLadder.add(<String, Object?>{
      'bytes': size,
      'complete': done,
      'ms': t.completedAt == null ? null : _round(t.completedAt! - t.startedAt),
      'received': t.received,
      'chunks': t.chunks,
    });
  }

  // --- skills/05's three acceptance boxes ----------------------------------
  // [1] "1-hop WiFi: PTT round-trip <1s". The modes table above it puts streaming
  // PTT at 150-300 ms on one Wi-Fi Direct hop, which reads as excluding the jitter
  // buffer, so both numbers are reported.
  final wifiSim = fresh();
  final wifiPair = pairAt(wifiSim, 1);
  final wifiNote = wifiPair == null
      ? null
      : wifiSim.sendVoice(wifiPair[0].id, wifiPair[1].id, 3.0,
          transport: TransportType.wifiDirect);
  double? wifiRoundTrip;
  if (wifiNote != null) {
    final note = wifiNote;
    if (runUntil(wifiSim, () => note.state == TransferState.complete, 30000) &&
        note.completedAt != null) {
      wifiRoundTrip = note.completedAt! +
          wifiSim.config.jitterBufferMs -
          (note.releasedAt ?? note.startedAt);
    }
  }

  // [2] "3-hop BLE: voice note arrives intact".
  final bleNoteSim = fresh();
  final bleNotePair = pairAt(bleNoteSim, 3);
  final bleNote = bleNotePair == null
      ? null
      : bleNoteSim.sendVoice(bleNotePair[0].id, bleNotePair[1].id, 3.0);
  var bleNoteOk = false;
  if (bleNote != null) {
    final note = bleNote;
    bleNoteOk =
        runUntil(bleNoteSim, () => note.state == TransferState.complete, 30000);
  }

  // [3] "10 MB image: delivered over WiFi Direct with resume after mid-transfer
  // disconnect". The disconnect is the interesting half.
  final resumeSim = fresh();
  final resumePair = pairAt(resumeSim, 3);
  Map<String, Object?>? resume;
  if (resumePair != null) {
    final t = resumeSim.sendFile(resumePair[0].id, resumePair[1].id, tenMb,
        transport: TransportType.wifiDirect);
    if (t != null) {
      runUntil(resumeSim, () => t.received >= (t.chunks * 0.3).floor(), 120000);
      final atDisconnect = t.received;
      resumeSim.toggleNodeOnline(resumePair[1].id); // receiver walks away
      resumeSim.runFor(20000);
      final stallsAway = t.stalls;
      resumeSim.toggleNodeOnline(resumePair[1].id); // ... and comes back
      final done =
          runUntil(resumeSim, () => t.state == TransferState.complete, 600000);
      resume = <String, Object?>{
        'atDisconnect': atDisconnect,
        'chunks': t.chunks,
        'stallsWhileAway': stallsAway,
        'stalls': t.stalls,
        'retransmitted': t.retransmitted,
        'complete': done,
        'ms': t.completedAt == null ? null : _round(t.completedAt! - t.startedAt),
      };
    }
  }

  // The ceiling itself: skills/05 "Max 10 MB".
  final ceilingSim = fresh();
  final ceilingPair = pairAt(ceilingSim, 1);
  final refused = ceilingPair == null
      ? null
      : ceilingSim.sendFile(ceilingPair[0].id, ceilingPair[1].id, 11 * 1048576);

  // --- push-to-talk: streamed against one blob ------------------------------
  final voice = <Map<String, Object?>>[];
  for (final hops in <int>[1, 2, 3]) {
    for (final stream in <bool>[true, false]) {
      final sim = fresh();
      final pair = pairAt(sim, hops);
      if (pair == null) continue;
      final t = sim.sendVoice(pair[0].id, pair[1].id, 3.0, stream: stream);
      if (t == null) continue;
      runUntil(sim, () => t.state == TransferState.complete, 60000);

      final arrivals = sim.deliveries
          .where((d) => d.transferId == t.id && d.chunkIndex != null)
          .toList()
        ..sort((x, y) => x.chunkIndex!.compareTo(y.chunkIndex!));
      var underruns = 0;
      var maxGap = 0.0;
      for (var i = 1; i < arrivals.length; i++) {
        final gap = arrivals[i].timestamp - arrivals[i - 1].timestamp;
        if (gap > maxGap) maxGap = gap;
        // Playback underruns when the next frame is not in the buffer by the time
        // the current one finishes.
        if (gap > config.voiceFrameMs + config.jitterBufferMs) underruns++;
      }
      final released = t.releasedAt ?? t.startedAt;
      final budget = hops >= 3 ? 8000.0 : 3000.0;
      final playDelay = t.completedAt == null
          ? null
          : t.completedAt! + config.jitterBufferMs - released;
      voice.add(<String, Object?>{
        'hops': hops,
        'mode': stream ? 'streamed' : 'blob',
        'transport': t.transport.name,
        'frames': t.chunks,
        'firstAudioMs': t.firstChunkAt == null
            ? null
            : _round(t.firstChunkAt! + config.jitterBufferMs - t.startedAt),
        'playDelayMs': playDelay == null ? null : _round(playDelay),
        'maxGapMs': _round(maxGap),
        'underruns': underruns,
        'retransmitted': t.retransmitted,
        'budgetMs': budget,
        'meetsBudget': playDelay != null && playDelay < budget,
      });
    }
  }

  final streamed = voice.where((v) => v['mode'] == 'streamed').toList();
  final blob = voice.where((v) => v['mode'] == 'blob').toList();
  final pttOk =
      streamed.isNotEmpty && streamed.every((v) => v['meetsBudget'] == true);
  final filesOk = files.isNotEmpty && files.every((f) => f['complete'] == true);
  num minOf(Iterable<Map<String, Object?>> rows) =>
      rows.map((v) => (v['firstAudioMs'] as num?) ?? 0).reduce((x, y) => x < y ? x : y);
  final firstStreamed = streamed.isEmpty ? null : minOf(streamed);
  final firstBlob = blob.isEmpty ? null : minOf(blob);

  final verdict = <String>[
    filesOk
        ? 'a 10 MB image crosses 1-3 hops on Wi-Fi Direct'
        : 'a 10 MB image did NOT cross every distance tried',
    if (files.isNotEmpty && files.last['ms'] != null)
      '3 hops in ${(files.last['ms'] as num).toInt() ~/ 1000} s',
    'BLE-only: ${bleOnly['complete'] == true ? '${bleOnly['ms']} ms' : 'unfinished in 15 min'}',
    pttOk
        ? 'push-to-talk plays inside the budget at every hop count'
        : 'push-to-talk BUSTS the budget somewhere',
    if (firstStreamed != null && firstBlob != null)
      'streaming starts audio at ${firstStreamed.toInt()} ms against ${firstBlob.toInt()} ms for one blob',
  ].join('; ');

  final acceptance = <String, Object?>{
    'wifiPttRoundTripMs': wifiRoundTrip == null ? null : _round(wifiRoundTrip),
    'wifiPttBufferExcludedMs':
        wifiRoundTrip == null ? null : _round(wifiRoundTrip - config.jitterBufferMs),
    'wifiPttUnder1s': wifiRoundTrip != null && wifiRoundTrip < 1000,
    'bleNoteIntact': bleNoteOk && bleNote != null
        ? bleNote.received == bleNote.chunks
        : false,
    'bleNoteFrames': bleNote?.received ?? 0,
    'bleNoteFrameCount': bleNote?.chunks ?? 0,
    'resumeAfterDisconnect': resume?['complete'] ?? false,
    'resume': resume,
    'overCeilingRefused': refused == null,
  };

  // --- channel access: the one radio a phone actually has (docs/08 §12) ------
  //
  // Everything above was measured under `ChannelAccess.free`, which gives a device an
  // infinitely wide radio: a transmission occupies no exclusive resource, so two packets
  // on air at once both succeed and a 10 MB file cannot cost anybody else anything. That
  // is why the contention A/B in docs/08 §9 comes out null. These rows flip the one
  // switch that gives the device a real radio and re-measure the same questions.

  /// A fixed traffic plan, replayed identically in every arm. Letting each arm draw its
  /// own traffic is what produced the first, wrong contention table (docs/08 §9).
  List<List<int>> textPlan(int seed, int nodeCount, int messages) {
    final rng = createRng(seed ^ 0x2f6e2b1);
    final out = <List<int>>[];
    for (var i = 0; i < messages; i++) {
      final a = (rng() * nodeCount).floor();
      var b = (rng() * nodeCount).floor();
      var guard = 0;
      while (b == a && guard++ < 32) {
        b = (rng() * nodeCount).floor();
      }
      if (a != b) out.add(<int>[a, b]);
    }
    return out;
  }

  /// Text traffic under one channel model, with and without a 10 MB file in flight.
  /// The text metrics are snapshotted at the end of the plan so a transfer that takes
  /// minutes cannot dilute its own damage across a tail where nothing competes.
  Map<String, Object?> textArm(ChannelAccess ca, int seed, bool withFile,
      {int? window}) {
    final sim = MeshSimulation(
        config.copyWith(trafficIntervalMs: 0, channelAccess: ca));
    sim.runFor(90000);
    sim.clearRecords();
    final p = textPlan(seed, sim.nodes.length, 40);
    Transfer? transfer;
    if (withFile && p.isNotEmpty) {
      transfer = sim.sendFile(sim.nodes[p[0][0]].id, sim.nodes[p[0][1]].id, tenMb,
          window: window);
    }
    var sent = 0;
    for (var i = 1; i < p.length; i++) {
      final from = sim.nodes[p[i][0]];
      final to = sim.nodes[p[i][1]];
      if (from.isOnline &&
          to.isOnline &&
          sim.sendMessage(from.id, to.id, 'c-$i') != null) {
        sent++;
      }
      sim.runFor(2000);
    }
    final stats = sim.refresh();
    final uni = sim.deliveries
        .where((d) =>
            d.type != MsgType.ack &&
            d.type != MsgType.broadcast &&
            d.groupId == null &&
            d.transferId == null)
        .toList();
    return <String, Object?>{
      'channel': ca.name,
      'arm': withFile ? 'file w${window ?? config.transferWindow}' : 'quiet',
      'sent': sent,
      'delivered': uni.length,
      'ratio': _round(uni.length / math.max(1, sent)),
      'retries': stats.retriesSent,
      'parked': stats.totalQueued,
      'deferrals': stats.channelDeferrals,
      'deferMs': _round(stats.channelDeferMs),
      'drops': stats.channelDrops,
      // Whether the file finished inside the traffic plan's own window. Under a real
      // radio a 10 MB transfer outlives 80 s of text traffic by minutes, which is itself
      // part of the finding.
      'fileComplete': transfer?.state == TransferState.complete,
    };
  }

  /// One 10 MB file at three hops, alone, under each channel model and window depth:
  /// the sliding window is worth several-fold on a free radio and almost nothing on a
  /// real one, because there is only one transmitter to fill.
  final channelFiles = <Map<String, Object?>>[];
  for (final ca in <ChannelAccess>[
    ChannelAccess.free,
    ChannelAccess.halfDuplex
  ]) {
    for (final w in <int>[1, config.transferWindow]) {
      final sim = MeshSimulation(
          config.copyWith(trafficIntervalMs: 0, channelAccess: ca));
      sim.runFor(90000);
      sim.clearRecords();
      final pair = pairAt(sim, 3);
      if (pair == null) continue;
      final t = sim.sendFile(pair[0].id, pair[1].id, tenMb, window: w);
      if (t == null) continue;
      final done =
          runUntil(sim, () => t.state == TransferState.complete, 600000);
      channelFiles.add(<String, Object?>{
        'channel': ca.name,
        'window': w,
        'complete': done,
        'ms': t.completedAt == null ? null : _round(t.completedAt! - t.startedAt),
        'retransmitted': t.retransmitted,
        'drops': sim.refresh().channelDrops,
      });
    }
  }

  /// Two nodes 20 m apart, no walls and no traffic of their own: one radio and one
  /// sender, so whatever differs between the arms below is the queue discipline and
  /// nothing else (docs/08 §12.8). The campus-scale A/B — three seeds against text, a
  /// file and a note — is the TypeScript probe's §8; these two rows pin the mechanism.
  MeshSimulation radioPair(ChannelPriority priority) {
    final sim = MeshSimulation(config.copyWith(
      nodeCount: 2,
      stationaryRatio: 1.0,
      chargingRatio: 0.0,
      trafficIntervalMs: 0,
      enableSuperElection: false,
      warmupMs: 0,
      obstacles: const <Obstacle>[],
      channelAccess: ChannelAccess.halfDuplex,
      channelPriority: priority,
    ));
    for (var i = 0; i < sim.nodes.length; i++) {
      final node = sim.nodes[i];
      node.pos = Vec2(10.0 + i * 20, 10);
      node.target = Vec2(10.0 + i * 20, 10);
      node.mobility = 0;
      node.isOnline = true;
      node.battery = 1.0;
    }
    sim.runFor(20000);
    sim.clearRecords();
    return sim;
  }

  final channelPriorityRows = <Map<String, Object?>>[];
  for (final arm in <(ChannelPriority, String)>[
    (ChannelPriority.fifo, 'voice behind a 2 MB file'),
    (ChannelPriority.byClass, 'voice behind a 2 MB file'),
    (ChannelPriority.fifo, 'an ACK behind a 2 MB file'),
    (ChannelPriority.ackFirst, 'an ACK behind a 2 MB file'),
  ]) {
    final priority = arm.$1;
    final sim = radioPair(priority);
    final a = sim.nodes[0].id;
    final b = sim.nodes[1].id;
    final file = sim.sendFile(a, b, 2 * 1048576);
    if (file == null) continue;
    sim.runFor(1000);
    final isVoice = arm.$2.startsWith('voice');
    Transfer? note;
    if (isVoice) {
      note = sim.sendVoice(a, b, 5.0, stream: true);
    } else {
      sim.sendMessage(a, b, 'probe-ack', MsgType.ack);
    }
    runUntil(sim, () => file.state == TransferState.complete, 600000);
    if (note != null) {
      runUntil(sim, () => note!.state == TransferState.complete, 600000);
    }
    final fileDone = file.completedAt ?? double.infinity;
    String metric;
    double ms;
    String what;
    if (isVoice) {
      final framesFirst = sim.deliveries
          .where((d) => d.transferId == note?.id && d.timestamp < fileDone)
          .length;
      metric = '$framesFirst/${note?.chunks ?? 0} frames before the file';
      ms = _round((note?.completedAt ?? 0) - (note?.startedAt ?? 0));
      what = 'note finished in';
    } else {
      // The injected ACK runs A -> B; the transfer's own acknowledgements run the other
      // way, so the recipient is what tells them apart.
      double? ackAt;
      for (final d in sim.deliveries) {
        if (d.type == MsgType.ack && d.to == b) {
          ackAt = d.timestamp;
          break;
        }
      }
      final at = ackAt;
      final chunksFirst = at == null
          ? 0
          : sim.deliveries
              .where((d) => d.transferId == file.id && d.timestamp < at)
              .length;
      metric = '$chunksFirst/${file.chunks} chunks before the ACK';
      ms = _round((file.completedAt ?? 0) - file.startedAt);
      what = 'file finished in';
    }
    channelPriorityRows.add(<String, Object?>{
      'arm': arm.$2,
      'priority': priority == ChannelPriority.byClass ? 'class' : priority.name,
      'metric': metric,
      'ms': ms,
      'what': what,
    });
  }

  final channelText = <Map<String, Object?>>[
    for (final ca in <ChannelAccess>[
      ChannelAccess.free,
      ChannelAccess.halfDuplex
    ]) ...<Map<String, Object?>>[
      textArm(ca, config.seed, false),
      textArm(ca, config.seed, true),
      if (ca == ChannelAccess.halfDuplex) textArm(ca, config.seed, true, window: 1),
    ],
  ];

  return <String, Object?>{
    'files': files,
    'bleOnly': bleOnly,
    'bleLadder': bleLadder,
    'voice': voice,
    'acceptance': acceptance,
    'channel': <String, Object?>{
      'files': channelFiles,
      'text': channelText,
      'priority': channelPriorityRows,
    },
    'pttMeetsBudget': pttOk,
    'imageMeetsBudget': filesOk,
    'verdict': verdict,
  };
}

/// Form a group, take one member out of range while it talks, and report whether
/// hash-beacon anti-entropy repairs what it missed (roadmap Phase 1, docs/06 §17).
///
/// Runs the same world twice — once with repair switched off — because "the member
/// eventually caught up" is only meaningful against "without beacons it never does".
Map<String, Object?> _historyProbe(SimConfig config) {
  const messages = 20;
  const size = 5;

  ({
    int held,
    int missed,
    int recovered,
    bool converged,
    double seconds,
    int rounds,
    int beacons,
    int requests,
    int replies,
    int packets,
    int bytes,
  }) run({required bool repair}) {
    final sim = MeshSimulation(config.copyWith(
        trafficIntervalMs: 0,
        captureLog: true,
        historyBeaconMs: repair ? config.historyBeaconMs : 0));
    sim.runFor(90000);
    sim.clearRecords();

    final online = sim.nodes.where((n) => n.isOnline).toList();
    final cx = online.fold<double>(0, (a, n) => a + n.pos.x) / online.length;
    final cy = online.fold<double>(0, (a, n) => a + n.pos.y) / online.length;
    double d2(MeshNode n) =>
        (n.pos.x - cx) * (n.pos.x - cx) + (n.pos.y - cy) * (n.pos.y - cy);
    final ranked = online.toList()..sort((a, b) => d2(b).compareTo(d2(a)));
    final step = ranked.length ~/ math.max(1, size);
    final ids = <NodeId>{};
    for (var i = 0; i < ranked.length && ids.length < size; i++) {
      ids.add(ranked[(i * step) % ranked.length].id);
    }
    final group = sim.createGroup('field team', ids.toList(), ids.first)!;
    final away = ids.last;

    sim.toggleNodeOnline(away); // out of range for the whole conversation
    for (var i = 0; i < messages; i++) {
      sim.sendMessage(ids.first, group.id, 'status $i');
      sim.runFor(1500);
    }
    sim.runFor(2000);
    final heldBefore = sim.groupHistoryOf(ids.first, group.id).length;

    sim.toggleNodeOnline(away);
    final from = sim.now;
    var converged = false;
    var elapsed = 0.0;
    while (elapsed < 300000) {
      sim.runFor(250);
      elapsed += 250;
      if (sim.historyConverged(group)) {
        converged = true;
        break;
      }
    }
    final stats = sim.refresh();
    final recovered = sim.groupHistoryOf(away, group.id).length;
    return (
      held: heldBefore,
      missed: heldBefore,
      recovered: recovered,
      converged: converged,
      seconds: converged ? (sim.now - from) / 1000 : -1,
      rounds: stats.historyReplies,
      beacons: stats.historyBeacons,
      requests: stats.historyRequests,
      replies: stats.historyReplies,
      packets: stats.sentSync,
      bytes: stats.historyBytes,
    );
  }

  final off = run(repair: false);
  final on = run(repair: true);

  final beacon = encodeHistoryBeacon(
      'grp-1', 0, historyDigest(<HistoryEntry>[]));
  final verdict = on.converged
      ? 'anti-entropy recovered all ${on.recovered} messages the absent member missed, '
          'in ${on.rounds} bounded rounds; without it the member holds ${off.recovered}'
      : 'anti-entropy did NOT converge inside 5 minutes (${on.recovered}/${on.missed} recovered)';

  return <String, Object?>{
    'members': size,
    'messages': messages,
    'heldBefore': on.held,
    'missed': on.missed,
    'offRecovered': off.recovered,
    'offConverged': off.converged,
    'recovered': on.recovered,
    'converged': on.converged,
    'convergedSeconds': on.seconds < 0 ? null : _round(on.seconds),
    'rounds': on.rounds,
    'beacons': on.beacons,
    'requests': on.requests,
    'replies': on.replies,
    'syncPackets': on.packets,
    'bytes': on.bytes,
    'beaconChars': beacon.length,
    'beaconWire': wireSizeOfBody(beacon),
    'beaconTransport': selectTransport(wireSizeOfBody(beacon)).name,
    'verdict': verdict,
  };
}
