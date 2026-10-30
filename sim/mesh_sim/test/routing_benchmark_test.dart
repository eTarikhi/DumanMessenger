import 'dart:convert';
import 'dart:io';
import 'package:duman_mesh_sim/mesh_sim.dart';
import 'package:test/test.dart';
import '../tool/routing_strategies.dart';

// Pin all six offline arms against the reference engine on the same traffic.
// This is parity evidence, not a claim that every scenario passes release gates.
void main() {
  final fixture = jsonDecode(File('../../test-fixtures/routing-benchmark.json').readAsStringSync())
      as Map<String, dynamic>;
  for (final raw in fixture['rows'] as List<dynamic>) {
    final row = raw as Map<String, dynamic>;
    test('${row['scenario']} duty=${row['duty']} ${row['strategy']} parity', () {
      final seed = row['seed'] as int;
      final config = applyRoutingStrategy(
        buildScenario(row['scenario'] as String, seed)
            .copyWith(dutyCycleEnabled: row['duty'] as bool),
        row['strategy'] as String, offline: true);
      final sim = MeshSimulation(config);
      final rng = createRng((seed ^ 0x5bf03635) & 0xffffffff);
      var sent = 0;
      for (var i = 0; i < 150; i++) {
        final a = (rng() * config.nodeCount).floor();
        var b = (rng() * config.nodeCount).floor();
        var guard = 0;
        while (b == a && guard++ < 32) {
          b = (rng() * config.nodeCount).floor();
        }
        if (b == a) continue;
        if (sim.nodes[a].isOnline && sim.nodes[b].isOnline &&
            sim.sendMessage(sim.nodes[a].id, sim.nodes[b].id, 'acc-$i', MsgType.text) != null) {
          sent++;
        }
        sim.runFor(1500);
      }
      sim.refresh();
      final uni = sim.deliveries.where((d) => d.type != MsgType.ack && d.type != MsgType.broadcast).toList();
      expect(sent, row['sent']);
      expect(uni.length, row['delivered']);
      expect(uni.map((d) => d.msgId).toSet().length, uni.length);
      expect(uni.where((d) => d.hops <= 5).length, row['withinFive']);
      expect(uni.where((d) => d.hops <= 3).length, row['withinThree']);
      expect(sim.stats.totalForwarded, row['relays']);
      expect(sim.stats.retriesSent, row['retries']);
    });
  }
}
