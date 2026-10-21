/// Named field scenarios (skills/08-qa-simulator.skill.md), mirroring
/// `src/scenarios.ts` so both engines can run the same acceptance test.
///
/// Every scenario is a pure function of its seed, so a CI run reproduces a field
/// test exactly. Node positions come from waypoint clusters rather than uniform
/// noise, because real crowds gather at a café terrace or on library steps — and
/// because a well-situated cluster centre is precisely the "person on a balcony
/// in the centre of the quad" that docs/03 §2 expects to be elected SUPER.
library;

import 'simulation.dart';
import 'types.dart';

/// 20 people across a campus quad: three gathering spots linked by a walkway.
/// This is the scenario the skills/02 + skills/08 acceptance criteria target.
SimConfig campusQuad([int seed = 42]) => SimConfig(
      seed: seed,
      areaWidth: 100,
      areaHeight: 100,
      nodeCount: 20,
      clusters: const <SpawnCluster>[
        SpawnCluster(22, 26, 10, 7, 'Café terrace'),
        SpawnCluster(50, 50, 12, 7, 'Quad centre'),
        SpawnCluster(76, 30, 9, 6, 'Library steps'),
      ],
      stationaryRatio: 0.5,
      chargingRatio: 0.15,
      obstacles: const <Obstacle>[
        Obstacle(8, 74, 18, 13, 'Block A'),
        Obstacle(74, 74, 18, 14, 'Block B'),
      ],
    );

/// 12 people spread over a village: mostly out of range of one another, so
/// traffic has to survive in the DTN OppQueue until someone walks past.
SimConfig sparseVillage([int seed = 42]) => SimConfig(
      seed: seed,
      areaWidth: 300,
      areaHeight: 300,
      nodeCount: 12,
      clusters: const <SpawnCluster>[
        SpawnCluster(40, 40, 14, 4, 'North farm'),
        SpawnCluster(260, 250, 14, 4, 'South farm'),
        SpawnCluster(150, 150, 8, 4, 'Well'),
      ],
      stationaryRatio: 0.25,
      chargingRatio: 0.1,
      obstacles: const <Obstacle>[],
      enableDtn: true,
    );

/// 60 people in a festival field, mostly moving — the density target from
/// docs/02 §6 ("support 50+ nodes in a dense area").
SimConfig festivalCrowd([int seed = 42]) => SimConfig(
      seed: seed,
      areaWidth: 140,
      areaHeight: 140,
      nodeCount: 60,
      clusters: const <SpawnCluster>[
        SpawnCluster(45, 45, 22, 25, 'Main stage'),
        SpawnCluster(100, 95, 20, 20, 'Food court'),
        SpawnCluster(40, 105, 16, 15, 'Camping'),
      ],
      stationaryRatio: 0.2,
      chargingRatio: 0.05,
      obstacles: const <Obstacle>[Obstacle(66, 62, 16, 12, 'Sound tent')],
    );

/// Two groups far apart with a single traveller shuttling between them: the
/// store-carry-forward case from docs/03 §8.
SimConfig partitionedPair([int seed = 42]) => SimConfig(
      seed: seed,
      areaWidth: 260,
      areaHeight: 120,
      nodeCount: 10,
      clusters: const <SpawnCluster>[
        SpawnCluster(30, 60, 12, 5, 'West group'),
        SpawnCluster(230, 60, 12, 5, 'East group'),
      ],
      stationaryRatio: 0.6,
      chargingRatio: 0.2,
      obstacles: const <Obstacle>[],
      enableMobility: true,
      enableDtn: true,
    );

const Map<String, SimConfig Function(int)> scenarios =
    <String, SimConfig Function(int)>{
  'campus_quad': campusQuad,
  'sparse_village': sparseVillage,
  'festival_crowd': festivalCrowd,
  'partitioned_pair': partitionedPair,
};

List<String> scenarioNames() => scenarios.keys.toList();

SimConfig buildScenario(String name, [int seed = 42]) {
  final factory = scenarios[name];
  if (factory == null) {
    throw ArgumentError('Unknown scenario "$name". Try: ${scenarioNames().join(', ')}');
  }
  return factory(seed);
}
