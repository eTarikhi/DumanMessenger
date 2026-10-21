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
  --trace             print the hop-by-hop route each delivered message took
  --capture           record the pcap-like mesh log and print its tail
  --capture-ogm       also log OGM beacons (they outnumber everything else)
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
        '${config.dutyCycleEnabled ? ', duty-cycle' : ''})');
    stdout.writeln('─' * 62);
    report.forEach((k, v) {
      if (k == 'latencyByHop') return;
      stdout.writeln('  ${k.padRight(24)} $v');
    });
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
