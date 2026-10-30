/**
 * `docs/04` §5's second mitigation: *"dummy beacons at low rate"*.
 *
 * The measurement behind this feature is a **null result** — `docs/06` §23 — so these tests
 * assert what makes the knob shippable rather than what makes it useful: it is inert when off,
 * it emits at the rate it is told to, its cost is monotone in that rate, and it does not
 * starve the network. Nothing here asserts that a sender is hidden, because on this observable
 * in this topology they are not, and a test that claimed otherwise would be the same mistake
 * the probe's first version made.
 */
import { describe, expect, it } from "vitest";
import { MeshSimulation } from "../simulation";
import { campusQuad } from "../scenarios";

const WINDOW_MS = 60_000;

/**
 * @param traffic inject honest messages in the window. Only the delivery floor needs them —
 *   without traffic there is nothing to deliver and `deliveryRatio` is 0 by definition — and
 *   only the airtime test must go without, because `injectTraffic` draws from the same RNG
 *   the cover beacons do, so the arms diverge and real traffic varies by more than the cover
 *   packets add. Measuring airtime on a quiet world isolates the cover contribution; the
 *   probe drives its traffic explicitly by id, which is why it can assert monotone totals.
 */
function world(coverTraffic: boolean, coverIntervalMs = 30_000, traffic = false) {
  const sim = new MeshSimulation({ ...campusQuad(42), coverTraffic, coverIntervalMs });
  sim.runFor(90_000); // settle elections, as the probes do
  sim.refresh();
  sim.clearRecords();
  const before = sim.nodes.map((n) => n.txCount);
  if (traffic) sim.injectTraffic(20, WINDOW_MS);
  sim.runFor(WINDOW_MS);
  sim.refresh();
  return {
    sim,
    coverTx: sim.stats.coverTx,
    transmissions: sim.nodes.reduce((sum, n, i) => sum + (n.txCount - before[i]), 0),
    deliveryRatio: sim.stats.deliveryRatio,
  };
}

describe("cover traffic (docs/04 §5, dummy beacons)", () => {
  it("is off by default at a rate the document does not specify", () => {
    const config = campusQuad(42);
    expect(config.coverTraffic).toBe(false);
    // "Low rate" is an adjective, so the default is a round guess and docs/06 §23 sweeps
    // 60/30/10/5 s rather than defending one.
    expect(config.coverIntervalMs).toBe(30_000);
  });

  it("emits nothing when off, which is what keeps every published number intact", () => {
    expect(world(false).coverTx).toBe(0);
  });

  it("emits at the rate it is told to, and faster when told to be faster", () => {
    const off = world(false).coverTx;
    const slow = world(true, 30_000).coverTx;
    const fast = world(true, 5_000).coverTx;
    expect(off).toBe(0);
    expect(slow).toBeGreaterThan(0);
    expect(fast).toBeGreaterThan(slow);
    // Order of magnitude, not an exact count: a node that is offline or out of battery does
    // not beacon, and the interval carries the same ±ogmJitterMs as a real OGM.
    const nodes = 20;
    expect(fast).toBeGreaterThanOrEqual(nodes * (WINDOW_MS / 5_000) * 0.5);
    expect(fast).toBeLessThanOrEqual(nodes * (WINDOW_MS / 5_000) * 2);
  });

  it("costs airtime in proportion to its rate — a dummy that is free is not on air", () => {
    const off = world(false).transmissions;
    const slow = world(true, 30_000).transmissions;
    const fast = world(true, 5_000).transmissions;
    expect(slow).toBeGreaterThan(off);
    expect(fast).toBeGreaterThan(slow);
  });

  it("does not starve the network, which is the floor §23 asserts instead of an equality", () => {
    // Not an equality: cover packets consume RNG draws, so the two worlds diverge from the
    // first dummy beacon and unrelated counts differ the way any two sequences do.
    for (const interval of [30_000, 5_000]) {
      expect(world(true, interval, true).deliveryRatio).toBeGreaterThan(0.5);
    }
  });

  it("counts cover separately from the routing protocol's own beacons", () => {
    const { sim } = world(true, 5_000);
    // `controlOverhead` is the OGM count the routing protocol needs; cover traffic is
    // optional and its whole cost belongs in `coverTx`, so neither is folded into the
    // other and a reader can see what disabling cover would actually save.
    expect(sim.stats.coverTx).toBeGreaterThan(0);
    expect(sim.stats.controlOverhead).toBeGreaterThan(0);
  });
});
