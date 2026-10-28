import 'package:duman_mesh_sim/mesh_sim.dart';
import 'package:test/test.dart';
import '../tool/routing_strategies.dart';

void main() {
  test('unapproved and unknown strategies always fall back to baseline', () {
    final config = SimConfig(dutyCycleEnabled: true);
    for (final id in [...routingStrategyIds, 'unknown']) {
      expect(identical(applyRoutingStrategy(config, id), config), isTrue);
    }
    expect(identical(applyRoutingStrategy(config, 'unknown', offline: true), config), isTrue);
  });
  test('bounded candidates match TypeScript patches and retain user power mode', () {
    final config = SimConfig(dutyCycleEnabled: true);
    expect(applyRoutingStrategy(config, 'ack-2000-v1', offline: true).ackTimeoutMs, 2000);
    expect(applyRoutingStrategy(config, 'ack-6000-v1', offline: true).ackTimeoutMs, 6000);
    expect(applyRoutingStrategy(config, 'super-carrier-v1', offline: true).dtnPreferSuper, isTrue);
    expect(applyRoutingStrategy(config, 'community-carrier-v1', offline: true).dtnPreferCommunity, isTrue);
    expect(applyRoutingStrategy(config, 'route-flood-v1', offline: true).relayPolicy, RelayPolicy.routeFlood);
    for (final id in routingStrategyIds) {
      final candidate = applyRoutingStrategy(config, id, offline: true);
      expect(candidate.dutyCycleEnabled, isTrue);
      expect(candidate.nodeCount, config.nodeCount);
      expect(candidate.seed, config.seed);
      expect(candidate.maxRetries, config.maxRetries);
      expect(candidate.enableDtn, config.enableDtn);
    }
  });
}
