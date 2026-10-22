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
  --group [N]         create an N-member group (default 5, spread across the
                      world) and report what a group message costs in both
                      delivery modes -- the docs/06 §14 measurement
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
    if (sos != null) 'sos': sos,
    if (group != null) 'group': group,
    if (media != null) 'media': media,
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
      stdout.writeln('  BLE-only (1 KB slices, no Wi-Fi Direct peer): '
          '${ble['complete'] == true ? '${ble['ms']} ms' : 'not finished in 15 min'} '
          'for 10 MB over ${ble['chunks']} chunks');
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
      : bleSim.sendFile(blePair[0].id, blePair[1].id, tenMb, chunkBytes: 1024);
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
  };

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

  return <String, Object?>{
    'files': files,
    'bleOnly': bleOnly,
    'voice': voice,
    'pttMeetsBudget': pttOk,
    'imageMeetsBudget': filesOk,
    'verdict': verdict,
  };
}
