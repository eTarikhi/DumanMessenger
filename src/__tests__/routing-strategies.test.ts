import { describe, it, expect } from "vitest";
import { DEFAULT_CONFIG } from "../simulation";
import { STRATEGIES, applyStrategy, percentile, trafficPlan } from "../../tool/routing/strategies";
import { createRng } from "../rng";

describe("offline routing policy safety", () => {
  it("defaults to exact baseline for unknown and unapproved policies", () => {
    for (const id of ["unknown", ...STRATEGIES.map(s => s.id)]) {
      expect(applyStrategy(DEFAULT_CONFIG, id)).toEqual(DEFAULT_CONFIG);
    }
  });
  it("preserves topology, protocol limits and power settings in all bounded arms", () => {
    const allowed = new Set(["ackTimeoutMs", "dtnPreferSuper", "dtnPreferCommunity", "relayPolicy"]);
    for (const { id } of STRATEGIES) {
      const original = { ...DEFAULT_CONFIG, dutyCycleEnabled: true };
      const before = JSON.stringify(original);
      const candidate = applyStrategy(original, id, true);
      for (const key of Object.keys(candidate) as Array<keyof typeof candidate>) {
        if (!allowed.has(key)) expect(candidate[key]).toEqual(original[key]);
      }
      expect(JSON.stringify(original)).toBe(before);
    }
  });
  it("replays a seed-independent traffic stream identically", () => {
    const plan = trafficPlan(42, 150, 20, createRng);
    expect(plan).toEqual(trafficPlan(42, 150, 20, createRng));
    expect(plan).toHaveLength(150);
    expect(plan.every(([a,b]) => a !== b && a >= 0 && b < 20)).toBe(true);
    expect(plan).not.toEqual(trafficPlan(7, 150, 20, createRng));
  });
  it("does not mutate percentile input and handles no deliveries", () => {
    const values = [3, 1, 2];
    expect(percentile(values, .95)).toBe(3);
    expect(percentile(values, .5)).toBe(2);
    expect(percentile([], .95)).toBeNull();
    expect(values).toEqual([3, 1, 2]);
  });
});
