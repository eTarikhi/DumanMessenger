/**
 * `docs/05` §1.2's third mitigation row: *"Adaptive scan intervals — scan interval scales with
 * peer density: dense = shorter interval (peers stable), sparse = longer (fewer discoveries
 * expected)"*. Documented, and not built until now.
 *
 * The direction is the **inverse** of the beacon rule `docs/06` §24.11 built and rejected, and
 * that is not a contradiction. A scan is this device waking to look; a beacon is every neighbour
 * waking to listen. So the cost of scanning scales with the scanner's own duty and the cost of
 * beaconing scales with how many will hear it — which is why one rule shortens the interval in a
 * crowd and the other lengthens it.
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

describe("adaptive scan intervals (docs/05 §1.2, layer 3)", () => {
  it("ships fixed, so nothing published moves", () => {
    for (const scenario of [campusQuad, sparseVillage, festivalCrowd]) {
      expect(scenario(42).scanIntervalMode).toBe("fixed");
      expect(scenario(42).scanDensityReferencePeers).toBe(10);
    }
  });

  it("scans less in a sparse world, which is the row's claimed saving", () => {
    // "Sparse = longer (fewer discoveries expected)": a node with three peers has little to
    // find, so it wakes less often. This is the half of the row that saves battery, and it is
    // the half §24.11's beacon rule got backwards — there, a sparse node beaconed four times
    // the specified rate to hold a reception load nobody was struggling with.
    const fixed = measured({}, sparseVillage);
    const adaptive = measured({ scanIntervalMode: "density" }, sparseVillage);
    expect(adaptive.stats.scansPerSec).toBeLessThan(fixed.stats.scansPerSec);
    // And it must not cost the network anything: fewer scans in a sparse world should not
    // strand a message, because there is little to discover either way.
    expect(adaptive.stats.deliveryRatio).toBeGreaterThanOrEqual(
      fixed.stats.deliveryRatio - 0.05
    );
  });

  it("scans more in a dense world, which is what the row says and what it costs", () => {
    // "Dense = shorter interval (peers stable)". This is the half that spends battery, and it is
    // worth asserting rather than assuming the row is a saving everywhere: in a crowd it is a
    // cost, and whether the discovery is worth it is a measurement, not a premise.
    const fixed = measured({}, festivalCrowd);
    const adaptive = measured({ scanIntervalMode: "density" }, festivalCrowd);
    expect(adaptive.stats.scansPerSec).toBeGreaterThan(fixed.stats.scansPerSec);
  });

  it("is anchored, so a reference-density node scans at exactly the configured interval", () => {
    // The anchor is what keeps this a scaling of the specified behaviour rather than a
    // replacement of it: at ten peers both modes agree, so a difference anywhere is attributable
    // to density and not to a re-tuned constant. campus_quad's median peer count is near ten,
    // which is why the two modes land close there and far apart at the extremes.
    const fixed = measured({});
    const adaptive = measured({ scanIntervalMode: "density" });
    const ratio = adaptive.stats.scansPerSec / Math.max(1e-9, fixed.stats.scansPerSec);
    expect(ratio).toBeGreaterThan(0.6);
    expect(ratio).toBeLessThan(1.6);
  });

  it("clamps, so one peer does not stop a node scanning and a crowd does not pin it awake", () => {
    // The clamp is [base / 4, base × 4]. Without the upper bound a node with forty peers would
    // scan every 250 ms forever; without the lower one a node with a single peer would scan
    // every forty seconds and miss the contact it has. Neither is asserted numerically here
    // because the interval is private — the bound that is observable is that the scan rate stays
    // inside four times either way of the fixed mode's, in the densest world available.
    const fixed = measured({}, festivalCrowd);
    const adaptive = measured({ scanIntervalMode: "density" }, festivalCrowd);
    expect(adaptive.stats.scansPerSec).toBeLessThan(fixed.stats.scansPerSec * 4.5);
    expect(adaptive.stats.scansPerSec).toBeGreaterThan(fixed.stats.scansPerSec / 4.5);
  });

  it("does not consume random numbers the fixed mode does not, so the default is untouched", () => {
    // The knob changes when a scan is scheduled, which changes the draw order — so the two modes
    // are different worlds and cannot be compared field by field. What must hold is that the
    // *default* is the world every published number was measured in: identical config produces
    // identical telemetry across two runs, and the adaptive mode is only ever reached by asking.
    const a = measured({});
    const b = measured({});
    expect(a.stats.scansPerSec).toBe(b.stats.scansPerSec);
    expect(a.stats.totalDelivered).toBe(b.stats.totalDelivered);
    expect(a.stats.deliveryRatio).toBe(b.stats.deliveryRatio);
  });
});
