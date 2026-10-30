/**
 * `skills/07` telemetry, fourth item: *"Battery %/h per role, scans/sec, relays/sec,
 * wake-locks"*. The first three shipped with the metrics dashboard; wake-locks did not,
 * which left unmeasured the one item that explains *why* the battery numbers differ by
 * role.
 *
 * A wake lock is what an Android device holds while its CPU must stay awake. On a
 * messenger whose radio is the reason the device is awake, radio activity is the whole of
 * it, so this counts one acquisition per transmission and per reception, held for as long
 * as that packet physically occupies the radio — durations the engine already computes for
 * the receiver model, which makes this accounting rather than a new radio model, and works
 * under the shipped `channelAccess: "free"` baseline where `txUntil`/`rxUntil` are never
 * maintained.
 */
import { describe, expect, it } from "vitest";
import { MeshSimulation, type SimConfig } from "../simulation";
import { campusQuad } from "../scenarios";

/**
 * Settle elections and routes, clear the window, drive traffic, read the counters — the
 * shape the probes use. The traffic callback receives the simulation, because a closure
 * that reaches for the variable it is being used to define is in that variable's temporal
 * dead zone when it runs, and `tsc` does not catch that.
 */
function measured(
  traffic: (sim: MeshSimulation) => void,
  over: Partial<SimConfig> = {}
): MeshSimulation {
  const sim = new MeshSimulation({ ...campusQuad(42), ...over });
  sim.runFor(90_000);
  sim.refresh();
  sim.clearRecords();
  traffic(sim);
  sim.runFor(60_000);
  sim.refresh();
  return sim;
}

const honest = (sim: MeshSimulation) => sim.injectTraffic(30, 40_000);

describe("wake-lock accounting (skills/07)", () => {
  it("counts under the shipped radio baseline, which maintains no busy-radio maps", () => {
    const sim = measured(honest);
    expect(sim.config.channelAccess).toBe("free");
    expect(sim.config.channelCapture).toBe("none");
    expect(sim.stats.wakeLocks).toBeGreaterThan(0);
    expect(sim.stats.wakeLockMs).toBeGreaterThan(0);
  });

  it("reports per node what it reports in total", () => {
    const sim = measured(honest);
    const locks = sim.nodes.reduce((sum, n) => sum + sim.wakeLocksFor(n.id), 0);
    const ms = sim.nodes.reduce((sum, n) => sum + sim.wakeLockMsFor(n.id), 0);
    expect(locks).toBe(sim.stats.wakeLocks);
    expect(ms).toBeCloseTo(sim.stats.wakeLockMs, 6);
  });

  it("holds at least one lock per transmission, and a second for whoever hears it", () => {
    const sim = measured((s) => {
      for (let i = 0; i < 10; i++) {
        s.sendMessage(s.nodes[0].id, "BROADCAST", `m ${i}`, "broadcast");
        s.runFor(2_000);
      }
    });
    // A transmission acquires one lock for the sender and one for the receiver it was aimed
    // at, so the count is at least twice the number of packets put on air — and
    // `relaysPerSec` is that packet rate over the same 60 s window. The 0.9 is slack for
    // the last packet's reception landing after the window closes.
    const packets = sim.stats.relaysPerSec * 60;
    expect(sim.stats.wakeLocks).toBeGreaterThanOrEqual(packets * 2 * 0.9);
  });

  it("splits the network's radio demand between the two roles, and the shares sum to 100", () => {
    const sim = measured(honest);
    const { wakeLockShareNormal, wakeLockShareSuper } = sim.stats;
    expect(wakeLockShareNormal).toBeGreaterThan(0);
    expect(wakeLockShareSuper).toBeGreaterThan(0);
    expect(wakeLockShareNormal + wakeLockShareSuper).toBeCloseTo(100, 6);
    // SUPERs are the relays — skills/02 gives them continuous scanning and MPR-selected
    // forwarding — and they are a minority of the network, so their share of the radio
    // demand has to exceed their share of the nodes. That comparison is the metric's whole
    // content, and it is a ratio, so it survives the caveat below.
    const supers = sim.nodes.filter((n) => n.role === "SUPER").length;
    expect(wakeLockShareSuper / 100).toBeGreaterThan(supers / sim.nodes.length);
  });

  it("reports the model's over-subscription plainly instead of hiding it in a percentage", () => {
    // docs/06 §24: at 20 nodes on campus_quad the engine demands roughly four times the
    // radio time that exists, because a beacon costs one hop latency at each of the peers
    // that hear it. Pinned as a floor rather than an exact figure so the test says "this is
    // a property of the model, and it is documented" rather than "this number is right".
    const sim = measured(honest);
    expect(sim.stats.radioDemandRatio).toBeGreaterThan(1);
    // And it is not a runaway: it stays within an order of magnitude, which is what makes
    // the role split above usable at all.
    expect(sim.stats.radioDemandRatio).toBeLessThan(10);
  });

  it("does not let the packet share be read as the energy gap between roles", () => {
    // docs/06 §24.1, and the correction it carries. SUPERs hold ~28 % of packet radio demand
    // while being 25 % of the nodes — a ratio near 1.14 — and the measured battery ratio
    // between the same two roles is three to four times larger. Both are true, they are
    // different quantities, and an earlier version of §24.1 quoted the first as though it
    // were the second. The role gap lives in *scan duty*, which this accounting excludes on
    // purpose, so this test pins the distinction instead of either number.
    const superShare = (sim: MeshSimulation) =>
      sim.nodes.filter((n) => n.role === "SUPER").length / sim.nodes.length;
    const energyRatio = (sim: MeshSimulation) =>
      sim.stats.batteryPercentPerHourSuper /
      Math.max(1e-9, sim.stats.batteryPercentPerHourNormal);

    const dutyOff = measured(honest, { dutyCycleEnabled: false });
    const dutyOn = measured(honest, { dutyCycleEnabled: true });

    // Packet demand: a modest multiple of the node share, not an energy gap.
    expect(dutyOn.stats.wakeLockShareSuper / 100).toBeLessThan(superShare(dutyOn) * 2);
    // Energy: much larger, and the duty cycle widens it, because an asleep NORMAL pays
    // sleepDrainFactor 0.25 while a SUPER scans continuously and pays full rate.
    expect(energyRatio(dutyOn)).toBeGreaterThan(2);
    expect(energyRatio(dutyOn)).toBeGreaterThan(energyRatio(dutyOff));
  });

  it("prices concentration on the neighbours who have to hear it", () => {
    // docs/04 §6 calls a flood a battery-drain attack. The wake-lock column is where that
    // becomes visible: every node in range pays a reception for every copy, and reception
    // is the expensive half of a broadcast. Both worlds below put the same number of
    // broadcasts on air in the same window; the only difference is whether they come from
    // one node or are spread evenly, so what is compared is concentration, not volume.
    const spread = (sim: MeshSimulation) => {
      for (let i = 0; i < 30; i++) {
        sim.sendMessage(
          sim.nodes[i % sim.nodes.length].id,
          "BROADCAST",
          `q ${i}`,
          "broadcast"
        );
        sim.runFor(1_000);
      }
    };
    const concentrated = (sim: MeshSimulation) => {
      for (let i = 0; i < 30; i++) {
        sim.sendMessage(sim.nodes[0].id, "BROADCAST", `f ${i}`, "broadcast");
        sim.runFor(1_000);
      }
    };
    const others = (sim: MeshSimulation) =>
      sim.nodes.slice(1).reduce((sum, n) => sum + sim.wakeLockMsFor(n.id), 0);
    expect(others(measured(concentrated))).toBeGreaterThan(others(measured(spread)));
  });

  it("measures the window, not the whole run", () => {
    const sim = new MeshSimulation(campusQuad(42));
    sim.runFor(90_000);
    sim.refresh();
    expect(sim.stats.wakeLocks).toBeGreaterThan(0);
    sim.clearRecords();
    // `clearRecords` re-baselines the window but does not recompute `stats` — that is what
    // `refresh` is for, and the first version of this test asserted on stale numbers.
    sim.refresh();
    expect(sim.stats.wakeLocks).toBe(0);
    expect(sim.stats.wakeLockMs).toBe(0);
  });
});
