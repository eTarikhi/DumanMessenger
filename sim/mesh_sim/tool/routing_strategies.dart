// Offline bounded strategy library. No simulator default or wire format changes.
import 'package:duman_mesh_sim/mesh_sim.dart';

const routingStrategyIds = <String>[
  'baseline-v1', 'ack-2000-v1', 'ack-6000-v1',
  'super-carrier-v1', 'community-carrier-v1', 'route-flood-v1',
];

SimConfig applyRoutingStrategy(SimConfig config, String id, {bool offline = false}) {
  // Unknown and unvalidated policies cannot take over routing.
  if (!offline) return config;
  switch (id) {
    case 'ack-2000-v1':
      return config.copyWith(ackTimeoutMs: 2000);
    case 'ack-6000-v1':
      return config.copyWith(ackTimeoutMs: 6000);
    case 'super-carrier-v1':
      return config.copyWith(dtnPreferSuper: true);
    case 'community-carrier-v1':
      return config.copyWith(dtnPreferCommunity: true);
    case 'route-flood-v1':
      return config.copyWith(relayPolicy: RelayPolicy.routeFlood);
    default:
      return config;
  }
}
