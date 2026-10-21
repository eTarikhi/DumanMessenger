import type { SimConfig } from "./simulation";
import { DEFAULT_CONFIG } from "./simulation";

/**
 * Named field scenarios (skills/08-qa-simulator.skill.md).
 *
 * Every scenario is a pure function of its seed, so a CI run reproduces a field
 * test exactly. Node positions come from waypoint clusters rather than uniform
 * noise, because real crowds gather at a café terrace or on library steps — and
 * because a well-situated cluster centre is precisely the "person on a balcony
 * in the centre of the quad" that docs/03 §2 expects to be elected SUPER.
 */

/** 20 people across a campus quad: three gathering spots linked by a walkway.
 *  This is the scenario the skills/02 + skills/08 acceptance criteria target. */
export function campusQuad(seed = 42): SimConfig {
  return {
    ...DEFAULT_CONFIG,
    seed,
    areaWidth: 100,
    areaHeight: 100,
    nodeCount: 20,
    clusters: [
      { cx: 22, cy: 26, radius: 10, count: 7, label: "Café terrace" },
      { cx: 50, cy: 50, radius: 12, count: 7, label: "Quad centre" },
      { cx: 76, cy: 30, radius: 9, count: 6, label: "Library steps" },
    ],
    stationaryRatio: 0.5,
    chargingRatio: 0.15,
    obstacles: [
      { x: 8, y: 74, w: 18, h: 13, label: "Block A" },
      { x: 74, y: 74, w: 18, h: 14, label: "Block B" },
    ],
  };
}

/** 12 people spread over a village: mostly out of range of one another, so
 *  traffic has to survive in the DTN OppQueue until someone walks past. */
export function sparseVillage(seed = 42): SimConfig {
  return {
    ...DEFAULT_CONFIG,
    seed,
    areaWidth: 300,
    areaHeight: 300,
    nodeCount: 12,
    clusters: [
      { cx: 40, cy: 40, radius: 14, count: 4, label: "North farm" },
      { cx: 260, cy: 250, radius: 14, count: 4, label: "South farm" },
      { cx: 150, cy: 150, radius: 8, count: 4, label: "Well" },
    ],
    stationaryRatio: 0.25,
    chargingRatio: 0.1,
    obstacles: [],
    enableDtn: true,
  };
}

/** 60 people in a festival field, mostly moving — the density target from
 *  docs/02 §6 ("support 50+ nodes in a dense area"). */
export function festivalCrowd(seed = 42): SimConfig {
  return {
    ...DEFAULT_CONFIG,
    seed,
    areaWidth: 140,
    areaHeight: 140,
    nodeCount: 60,
    clusters: [
      { cx: 45, cy: 45, radius: 22, count: 25, label: "Main stage" },
      { cx: 100, cy: 95, radius: 20, count: 20, label: "Food court" },
      { cx: 40, cy: 105, radius: 16, count: 15, label: "Camping" },
    ],
    stationaryRatio: 0.2,
    chargingRatio: 0.05,
    obstacles: [{ x: 66, y: 62, w: 16, h: 12, label: "Sound tent" }],
  };
}

/** Two groups far apart with a single traveller shuttling between them: the
 *  store-carry-forward case from docs/03 §8. */
export function partitionedPair(seed = 42): SimConfig {
  return {
    ...DEFAULT_CONFIG,
    seed,
    areaWidth: 260,
    areaHeight: 120,
    nodeCount: 10,
    clusters: [
      { cx: 30, cy: 60, radius: 12, count: 5, label: "West group" },
      { cx: 230, cy: 60, radius: 12, count: 5, label: "East group" },
    ],
    stationaryRatio: 0.6,
    chargingRatio: 0.2,
    obstacles: [],
    enableMobility: true,
    enableDtn: true,
  };
}

export const SCENARIOS = {
  campus_quad: campusQuad,
  sparse_village: sparseVillage,
  festival_crowd: festivalCrowd,
  partitioned_pair: partitionedPair,
} as const;

export type ScenarioName = keyof typeof SCENARIOS;

export function scenarioNames(): ScenarioName[] {
  return Object.keys(SCENARIOS) as ScenarioName[];
}

export function buildScenario(name: string, seed = 42): SimConfig {
  const factory = SCENARIOS[name as ScenarioName];
  if (!factory) throw new Error(`Unknown scenario "${name}". Try: ${scenarioNames().join(", ")}`);
  return factory(seed);
}
