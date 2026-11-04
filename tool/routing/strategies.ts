import type { SimConfig } from "../../src/simulation";

/** Offline candidates, NOT permission to deploy. No change to simulator defaults. */
export const STRATEGIES = [
  { id: "baseline-v1", patch: {}, status: "approved" },
  { id: "ack-2000-v1", patch: { ackTimeoutMs: 2000 }, status: "candidate" },
  { id: "ack-6000-v1", patch: { ackTimeoutMs: 6000 }, status: "candidate" },
  { id: "super-carrier-v1", patch: { dtnPreferSuper: true }, status: "candidate" },
  { id: "community-carrier-v1", patch: { dtnPreferCommunity: true }, status: "candidate" },
  { id: "route-flood-v1", patch: { relayPolicy: "route-flood" }, status: "diagnostic" },
] as const;
export type StrategyId = typeof STRATEGIES[number]["id"];

export function applyStrategy(config: SimConfig, id: string, offline = false): SimConfig {
  const strategy = STRATEGIES.find(s => s.id === id);
  if (!strategy || (!offline && strategy.status !== "approved")) return { ...config };
  // Bounded, typed patches cannot change topology, seeds, power mode, TTL, or metrics.
  return { ...config, ...strategy.patch };
}

export function trafficPlan(seed: number, count: number, nodeCount: number,
  rngFactory: (seed: number) => () => number): Array<[number, number]> {
  const rng = rngFactory((seed ^ 0x5bf03635) >>> 0);
  const plan: Array<[number, number]> = [];
  for (let i = 0; i < count; i++) {
    const from = Math.floor(rng() * nodeCount);
    let to = Math.floor(rng() * nodeCount);
    let guard = 0;
    while (to === from && guard++ < 32) to = Math.floor(rng() * nodeCount);
    if (to !== from) plan.push([from, to]);
  }
  return plan;
}
export function percentile(values: number[], q: number): number | null {
  if (!values.length) return null;
  const sorted = values.slice().sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(q * sorted.length) - 1)];
}
