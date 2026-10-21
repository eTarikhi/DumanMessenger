import 'dart:convert';
import 'dart:io';

import 'package:duman_mesh_sim/mesh_sim.dart';
import 'package:test/test.dart';

/// Cross-language parity.
///
/// `test-fixtures/golden-vectors.json` is generated from the TypeScript
/// reference implementation by `npm run golden`. These assertions pin the Dart
/// engine to exactly the same numbers, so a drift in the RNG, the spawn draw
/// order or the protocol logic fails CI in whichever language moved.
Map<String, dynamic> _load() {
  final file = File('../../test-fixtures/golden-vectors.json');
  if (!file.existsSync()) {
    fail('golden fixture not found at ${file.absolute.path} — run `npm run golden`');
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  final fixture = _load();
  final rngSpec = fixture['rng'] as Map<String, dynamic>;
  final spawnSpec = fixture['spawn'] as Map<String, dynamic>;
  final runSpec = fixture['run'] as Map<String, dynamic>;
  final expect_ = runSpec['expect'] as Map<String, dynamic>;

  group('golden vectors v${fixture['version']}', () {
    test('reproduces the mulberry32 stream bit-for-bit', () {
      final rng = createRng(rngSpec['seed'] as int);
      final scale = (rngSpec['fixedPointScale'] as num).toDouble();
      for (final raw in rngSpec['values'] as List<dynamic>) {
        expect((rng() * scale).round(), equals(raw),
            reason: 'RNG stream diverged from the TypeScript engine');
      }
    });

    test('reproduces the seeded spawn geometry', () {
      final config = buildScenario(spawnSpec['scenario'] as String,
          spawnSpec['seed'] as int);
      final nodes = createNodes(createRng(config.seed), config);
      final golden = spawnSpec['nodes'] as List<dynamic>;
      expect(nodes, hasLength(golden.length));

      for (var i = 0; i < nodes.length; i++) {
        final n = nodes[i];
        final g = golden[i] as Map<String, dynamic>;
        expect(n.id, equals(g['id']));
        expect(n.pos.x, closeTo((g['x'] as num).toDouble(), 1e-6),
            reason: '${n.id} x diverged');
        expect(n.pos.y, closeTo((g['y'] as num).toDouble(), 1e-6),
            reason: '${n.id} y diverged');
        expect(n.battery, closeTo((g['battery'] as num).toDouble(), 1e-9));
        expect(n.uptimeMin, closeTo((g['uptimeMin'] as num).toDouble(), 1e-6));
        expect(n.mobility, closeTo((g['mobility'] as num).toDouble(), 1e-9));
        expect(n.pdr, closeTo((g['pdr'] as num).toDouble(), 1e-9));
        expect(n.stationary, equals(g['stationary']));
        expect(n.charging, equals(g['charging']));
      }
    });

    test('reproduces the reference run', () {
      final config =
          buildScenario(runSpec['scenario'] as String, runSpec['seed'] as int);
      final messages = runSpec['messages'] as int;
      final gapMs = (runSpec['gapMs'] as num).toDouble();

      final sim = MeshSimulation(config);
      for (var i = 0; i < messages; i++) {
        final online = sim.nodes.where((n) => n.isOnline).toList();
        final from = online[(sim.rng() * online.length).floor()];
        var to = online[(sim.rng() * online.length).floor()];
        var guard = 0;
        while (to.id == from.id && guard++ < 32) {
          to = online[(sim.rng() * online.length).floor()];
        }
        if (to.id != from.id) {
          sim.sendMessage(from.id, to.id, 'golden-$i');
        }
        sim.runFor(gapMs);
      }
      sim.refresh();

      final unicast = sim.deliveries
          .where((d) => d.type != MsgType.ack && d.type != MsgType.broadcast)
          .toList();
      final transitions = sim.nodes.fold<int>(0, (s, n) => s + n.roleTransitions);
      final s = sim.stats;

      // Integer protocol counters must match exactly.
      expect(sim.now, closeTo((expect_['simTimeMs'] as num).toDouble(), 1e-6));
      expect(sim.nodes.where((n) => n.isOnline).length,
          equals(expect_['onlineNodes']));
      expect(sim.nodes.where((n) => n.role == Role.superNode).length,
          equals(expect_['superNodes']));
      expect(s.sentUnicast, equals(expect_['sentUnicast']));
      expect(unicast.length, equals(expect_['deliveredUnicast']));
      expect(s.totalForwarded, equals(expect_['relayTx']));
      expect(s.controlOverhead, equals(expect_['ogmTx']));
      expect(s.retriesSent, equals(expect_['retriesSent']));
      expect(s.acksReceived, equals(expect_['acksReceived']));
      expect(transitions, equals(expect_['roleTransitions']));
      expect(s.totalQueued, equals(expect_['totalQueued']));
      expect(unicast.fold<int>(0, (sum, d) => sum + d.hops),
          equals(expect_['sumHopCounts']));

      // Floating aggregates carry a tolerance so a last-ULP difference between
      // the JS and Dart libm implementations cannot fail the build.
      expect(s.avgScore,
          closeTo((expect_['avgScore'] as num).toDouble(), 1e-5));
      expect(s.avgHops, closeTo((expect_['avgHops'] as num).toDouble(), 1e-5));
      expect(s.avgLatencyMs,
          closeTo((expect_['avgLatencyMs'] as num).toDouble(), 1e-2));
      expect(s.p95LatencyMs,
          closeTo((expect_['p95LatencyMs'] as num).toDouble(), 1e-2));
    });
  });
}
