/**
 * In-window connectivity sampling, which `docs/06` §24.10 turned out to need.
 *
 * A 60-node crowd splits and re-joins repeatedly inside a measurement window, so
 * `broadcastReach` averaged over that window reads as two modes unless you know how much of it
 * the network was in one piece. The graph measured *after* the window cannot tell you: a
 * partition that healed looks exactly like a network that was never partitioned, which is the
 * mistake §24.9 made when it concluded that topology could not explain the weak mode.
 */
import { describe, expect, it } from "vitest";
import { MeshSimulation, type SimConfig } from "../simulation";
import { campusQuad, festivalCrowd } from "../scenarios";

function measured(over: Partial<SimConfig> = {}, scenario = campusQuad) {
  const sim = new MeshSimulation({ ...scenario(42), ...over });
  sim.runFor(90_000);
  sim.refresh();
  sim.clearRecords();
  sim.injectTraffic(30, 40_000);
  sim.runFor(60_000);
  sim.refresh();
  return sim;
}

describe("connectivity sampling (docs/06 §24.10)", () => {
  it("reports the radio graph's components, largest first, summing to the network", () => {
    const sim = measured();
    const sizes = sim.componentSizes();
    expect(sizes.length).toBeGreaterThan(0);
    expect(sizes.reduce((a, b) => a + b, 0)).toBe(sim.nodes.length);
    for (let i = 1; i < sizes.length; i++) expect(sizes[i - 1]).toBeGreaterThanOrEqual(sizes[i]);
  });

  it("samples the window at the configured interval, and not the settle period", () => {
    const sim = measured({ connectivitySampleMs: 5_000 });
    // 60 s window at 5 s per sample. The count is a range rather than exactly 12 because the
    // sampler runs on the 250 ms physics tick, so a sample lands on the first tick at or after
    // each boundary.
    expect(sim.stats.connectivitySamples).toBeGreaterThanOrEqual(11);
    expect(sim.stats.connectivitySamples).toBeLessThanOrEqual(13);
  });

  it("can be disabled, and a disabled run reports the trivially connected defaults", () => {
    const sim = measured({ connectivitySampleMs: 0 });
    expect(sim.stats.connectivitySamples).toBe(0);
    // Zero samples must not read as "never connected": with nothing measured, the shares are
    // 1 so that a consumer dividing by them or comparing against a threshold is not misled.
    expect(sim.stats.connectedSampleShare).toBe(1);
    expect(sim.stats.meanLargestComponent).toBe(1);
  });

  it("says a settled 20-node campus stays in one piece", () => {
    const sim = measured({ connectivitySampleMs: 5_000 });
    expect(sim.stats.connectedSampleShare).toBe(1);
    expect(sim.stats.meanLargestComponent).toBe(1);
    // Which is why campus_quad's three-seed numbers were sound and festival_crowd's were not.
    expect(sim.componentSizes()).toEqual([sim.nodes.length]);
  });

  it("catches the crowd splitting, which an end-of-window graph cannot", () => {
    // docs/06 §24.10 measured seed 2024 at a 12 s beacon interval as connected for 17% of six
    // in-window samples with a mean largest component of 72%, while the graph at the end of the
    // window was whole. The engine's own sampler has to see the same thing, or the metric it
    // now reports is not the one that explained the bimodality.
    const sim = measured(
      { connectivitySampleMs: 5_000, ogmIntervalMs: 12_000 },
      festivalCrowd
    );
    const fresh = new MeshSimulation({ ...festivalCrowd(2024), ogmIntervalMs: 12_000 });
    fresh.runFor(90_000);
    fresh.refresh();
    fresh.clearRecords();
    fresh.injectTraffic(30, 40_000);
    fresh.runFor(60_000);
    fresh.refresh();
    // The whole graph at the end of the window — the measurement §24.9 trusted.
    expect(fresh.componentSizes()).toEqual([fresh.nodes.length]);
    // And the window it was actually living through, which is not whole.
    expect(fresh.stats.connectedSampleShare).toBeLessThan(1);
    expect(fresh.stats.meanLargestComponent).toBeLessThan(0.95);
    expect(fresh.stats.broadcastReach).toBeLessThan(0.9);
    expect(sim.nodes.length).toBe(60);
  });

  it("does not change the world it measures", () => {
    // Sampling reads the graph and writes counters. It consumes no random number and schedules
    // no event, so a run that samples and a run that does not must agree on everything that is
    // not a connectivity statistic — which is what makes it safe to leave on by default.
    const on = measured({ connectivitySampleMs: 5_000 });
    const off = measured({ connectivitySampleMs: 0 });
    for (const key of [
      "totalDelivered",
      "totalForwarded",
      "deliveryRatio",
      "broadcastReach",
      "overheadRatio",
      "controlOverhead",
      "routeExpiries",
      "wakeLocks",
    ] as const) {
      expect(on.stats[key], key).toBe(off.stats[key]);
    }
    expect(on.stats.connectivitySamples).toBeGreaterThan(0);
    expect(off.stats.connectivitySamples).toBe(0);
  });
});
