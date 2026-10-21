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
  --policy <name>     mpr | flood-all                      (default: mpr)
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
  final nodesOverride = args.indexOf('--nodes');
  if (nodesOverride >= 0 && nodesOverride + 1 < args.length) {
    config = config.copyWith(nodeCount: int.parse(args[nodesOverride + 1]));
  }
  if (policyName == 'flood-all') {
    config = config.copyWith(relayPolicy: RelayPolicy.floodAll);
  }

  final plan = _trafficPlan(config.seed, messages, config.nodeCount);
  final sim = MeshSimulation(config);
  final sent = _replay(sim, plan, gapMs);

  final baseline = MeshSimulation(config.copyWith(relayPolicy: RelayPolicy.floodAll));
  _replay(baseline, plan, gapMs);

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
  };

  if (asJson) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  } else {
    stdout.writeln('Duman mesh simulator — $scenarioName (seed $seed, policy $policyName)');
    stdout.writeln('─' * 62);
    report.forEach((k, v) => stdout.writeln('  ${k.padRight(24)} $v'));
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
