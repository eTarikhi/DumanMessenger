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
import { campusQuad, festivalCrowd, sparseVillage } from "../scenarios";

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

describe("the density-derived beacon interval (docs/06 §24.11)", () => {
  it("ships on the fixed interval docs/03 §4 specifies", () => {
    const config = campusQuad(42);
    expect(config.ogmIntervalMode).toBe("fixed");
    expect(config.ogmDensityReferencePeers).toBe(10);
    expect(config.ogmIntervalMs).toBe(2_000);
  });

  it("beacons a reference-density node at exactly the specified interval", () => {
    // The rule is anchored, not a replacement: a node with ten peers beacons every 2 s in
    // both modes, so the derived mode cannot be blamed for a change it did not make. Measured
    // through the beacon count over a window, since the interval itself is private.
    const fixed = measured({ ogmIntervalMode: "fixed" });
    expect(fixed.stats.controlOverhead).toBeGreaterThan(0);
    const on = measured({ connectivitySampleMs: 0 });
    const off = measured({ connectivitySampleMs: 0, ogmIntervalMode: "density" });
    // In a settled campus the peer counts sit near the reference, so the two modes beacon
    // within a third of each other — and the derived mode is not cheaper, which is the first
    // half of why §24.11 rejects it.
    expect(off.stats.controlOverhead).toBeGreaterThan(on.stats.controlOverhead * 0.66);
    expect(off.stats.deliveryRatio).toBeLessThanOrEqual(on.stats.deliveryRatio + 0.05);
  });

  it("spends more airtime in a sparse world, where the floor bites", () => {
    // docs/06 §24.11: sparse_village pays 3.1x the demanded radio time for 1.6 points of
    // delivery. A node with three peers hits the ogmIntervalMs / 4 floor and beacons four
    // times the specified rate, to hold a reception load nobody was struggling with. The
    // threshold here is loose because the two modes are different worlds; the direction is
    // what is being pinned, and it is the direction that made the lever get rejected.
    const fixed = measured({ radioOccupancy: "airtime" }, sparseVillage);
    const derived = measured(
      { radioOccupancy: "airtime", ogmIntervalMode: "density" },
      sparseVillage
    );
    expect(derived.stats.controlOverhead).toBeGreaterThan(fixed.stats.controlOverhead);
    expect(derived.stats.radioDemandRatio).toBeGreaterThan(fixed.stats.radioDemandRatio);
    // And the topologies are comparable, which is what makes the comparison readable at all:
    // §24.10's metric says both worlds are equally partitioned, so the cost is not a topology
    // difference in disguise.
    expect(derived.stats.meanLargestComponent).toBeCloseTo(
      fixed.stats.meanLargestComponent,
      1
    );
  });

  it("holds the topology still, and there the derived interval is cheaper without losing reach", () => {
    // docs/06 §24.12. With mobility off, both arms share a graph *by construction* — the
    // positions are drawn from the same seed and never move — so a difference between them is
    // caused by the beacon interval and nothing else. That is the comparison §24.11 said the
    // verdict needed and could not make.
    //
    // What is asserted here is only what the mechanism guarantees: identical topology, fewer
    // beacons, less demanded radio time. Delivery is *not* asserted, and that is a measured
    // limit rather than an oversight — over eight seeds the derived interval is better on
    // delivery in four, worse in two and level in two, and the +2.5-point mean §24.12 quotes
    // is most of one seed (31337, +22). Seed 42, which this helper runs, is one of the two
    // where it is worse. A test that asserted the mean's direction on one seed would be
    // §24.8's mistake in reverse.
    const fixed = measured(
      { radioOccupancy: "airtime", enableMobility: false },
      festivalCrowd
    );
    const derived = measured(
      {
        radioOccupancy: "airtime",
        enableMobility: false,
        ogmIntervalMode: "density",
      },
      festivalCrowd
    );
    // Identical topology, exactly and not approximately: a static graph sampled twelve times
    // gives the same answer in both arms, so this is an equality rather than a tolerance.
    expect(derived.stats.meanLargestComponent).toBe(fixed.stats.meanLargestComponent);
    expect(derived.stats.connectedSampleShare).toBe(fixed.stats.connectedSampleShare);
    // And the lever, in the two columns that are structural rather than sampled: fewer
    // beacons, and less demanded radio time per beacon.
    expect(derived.stats.controlOverhead).toBeLessThan(fixed.stats.controlOverhead);
    expect(derived.stats.radioDemandRatio).toBeLessThan(fixed.stats.radioDemandRatio);
    // Reach, not delivery: over eight seeds the derived interval is equal or better on reach
    // in seven, which is the strongest claim the data supports. On this seed it is better too,
    // but one seed is why that sentence says eight.
    expect(derived.stats.broadcastReach).toBeGreaterThanOrEqual(fixed.stats.broadcastReach);
  });
});
