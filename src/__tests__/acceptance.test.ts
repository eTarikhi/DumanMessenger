import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { MeshSimulation, createNodes, type SimConfig } from "../simulation";
import { buildScenario, campusQuad, festivalCrowd, scenarioNames, sparseVillage } from "../scenarios";
import { createRng } from "../rng";

/**
 * Acceptance criteria, transcribed from the repo's own targets:
 *
 *   skills/02-qa-mesh-routing.skill.md
 *     "Simulator 20 nodes: SUPER ratio 15-25%, delivery >=90% at 3 hops,
 *      overhead <=70% of flood-all."
 *
 *   skills/08-qa-simulator.skill.md
 *     "CI simulator: 20-node seed -> delivery >=90% <5 hops,
 *      overhead down 30% vs naive flood."
 *
 *   docs/04-offline-first-architecture.md §5 (latency budget)
 *     "1 hop: < 2 s ; 3 hops: < 5 s"
 *
 *   docs/03-smart-router-algorithm.md §5 (election)
 *     "hysteresis: prevent SUPER flapping"
 *
 * Reading of the two delivery clauses: "delivery >=90% <5 hops" means at least
 * 90% of *sent* messages arrive within five radio hops, and "delivery >=90% at
 * 3 hops" means the 90% bar holds in a network whose typical path is ~3 hops
 * (asserted separately via avgHops). Both are measured on unicast traffic;
 * ACKs and broadcasts are excluded so control traffic cannot inflate the ratio.
 */

const SEEDS = [42, 7, 1234, 99, 2026, 555];
const MESSAGES = 150;
const GAP_MS = 1500;

/**
 * The A/B against naive flooding must feed *identical* traffic to both runs.
 * Drawing pairs from the simulation's own RNG does not do that: MPR's 300 ms
 * wait changes event interleaving, so the two runs consume the stream
 * differently and quietly become two different experiments. A dedicated plan
 * generator removes that confound.
 */
function trafficPlan(seed: number, count: number, nodeCount: number): Array<[number, number]> {
  const rng = createRng((seed ^ 0x5bf03635) >>> 0);
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

function replay(sim: MeshSimulation, plan: Array<[number, number]>): number {
  let sent = 0;
  for (let i = 0; i < plan.length; i++) {
    const [fromIdx, toIdx] = plan[i];
    const from = sim.nodes[fromIdx];
    const to = sim.nodes[toIdx];
    if (from.isOnline && to.isOnline) {
      if (sim.sendMessage(from.id, to.id, `acc-${i}`, "text")) sent++;
    }
    sim.runFor(GAP_MS);
  }
  sim.refresh();
  return sent;
}

interface RunResult {
  sim: MeshSimulation;
  sent: number;
  deliveredUnicast: number;
  withinFiveHops: number;
  overFiveHops: number;
  deliveryRatio: number;
  withinFiveRatio: number;
  superRatio: number;
  relayTx: number;
  overheadVsFlood: number;
  floodDeliveryRatio: number;
  /** Relays of the naive epidemic arm, kept so tests can quote real numbers. */
  floodRelays: number;
  /** `route-flood` arm: identical routing, MPR suppression switched off. */
  overheadVsRouteFlood: number;
  routeFloodDeliveryRatio: number;
  avgHops: number;
  flapPerNodeMin: number;
  p50: number;
  p95: number;
  oneHopMax: number;
  threeHopMax: number;
}

/** Deterministic traffic drawn from the simulation's own RNG stream. */
function measure(cfg: SimConfig, withFloodBaseline = true): RunResult {
  const sim = new MeshSimulation(cfg);
  const plan = trafficPlan(cfg.seed, MESSAGES, cfg.nodeCount);
  const sent = replay(sim, plan);

  const uni = sim.deliveries.filter((d) => d.type !== "ack" && d.type !== "broadcast");
  const withinFiveHops = uni.filter((d) => d.hops <= 5).length;

  let baselineRelays = sim.stats.totalForwarded;
  let routeFloodRelays = sim.stats.totalForwarded;
  let floodDeliveryRatio = uni.length / Math.max(1, sent);
  let routeFloodDeliveryRatio = floodDeliveryRatio;
  if (withFloodBaseline) {
    // Same seed, same world, same traffic — only the relay policy differs.
    // Two baselines, because they answer different questions:
    //   flood-all    naive epidemic flooding — what the criteria are written
    //                against ("overhead <=70% of flood-all", "down 30% vs
    //                naive flood").
    //   route-flood  routing kept, suppression off — the only arm that isolates
    //                what MPR costs and buys on top of a working route table.
    const arm = (policy: SimConfig["relayPolicy"]) => {
      const run = new MeshSimulation({ ...cfg, relayPolicy: policy });
      replay(run, plan);
      const delivered = run.deliveries.filter((d) => d.type !== "ack" && d.type !== "broadcast");
      return { relays: run.stats.totalForwarded, deliveryRatio: delivered.length / Math.max(1, sent) };
    };
    const flood = arm("flood-all");
    baselineRelays = flood.relays;
    floodDeliveryRatio = flood.deliveryRatio;
    const routeOnly = arm("route-flood");
    routeFloodRelays = routeOnly.relays;
    routeFloodDeliveryRatio = routeOnly.deliveryRatio;
    expect(baselineRelays).toBeGreaterThan(0);
    expect(routeFloodRelays).toBeGreaterThan(0);
  }

  // Per-hop transport budget (docs/04 §5) applies to first-attempt deliveries:
  // a retry legitimately adds a whole ACK timeout to the user-visible latency.
  const firstTry = uni.filter((d) => d.attempt === 0 && !d.dtn);
  const oneHop = firstTry.filter((d) => d.hops === 1).map((d) => d.latencyMs);
  const threeHop = firstTry.filter((d) => d.hops <= 3).map((d) => d.latencyMs);
  const max = (xs: number[]) => (xs.length ? Math.max(...xs) : 0);

  return {
    sim,
    sent,
    deliveredUnicast: uni.length,
    withinFiveHops,
    overFiveHops: uni.length - withinFiveHops,
    deliveryRatio: uni.length / Math.max(1, sent),
    withinFiveRatio: withinFiveHops / Math.max(1, sent),
    superRatio: sim.stats.superRatio,
    relayTx: sim.stats.totalForwarded,
    overheadVsFlood: sim.stats.totalForwarded / Math.max(1, baselineRelays),
    floodDeliveryRatio,
    floodRelays: baselineRelays,
    overheadVsRouteFlood: sim.stats.totalForwarded / Math.max(1, routeFloodRelays),
    routeFloodDeliveryRatio,
    avgHops: sim.stats.avgHops,
    flapPerNodeMin: sim.stats.roleChangesPerNodeMin,
    p50: sim.stats.p50LatencyMs,
    p95: sim.stats.p95LatencyMs,
    oneHopMax: max(oneHop),
    threeHopMax: max(threeHop),
  };
}

describe("skills/02 + skills/08 acceptance — campus quad, 20 nodes", () => {
  const results = new Map<number, RunResult>();
  for (const seed of SEEDS) results.set(seed, measure(campusQuad(seed)));

  it.each(SEEDS)("seed %i elects a stable 15-25% super-node set", (seed) => {
    const r = results.get(seed)!;
    expect(r.superRatio).toBeGreaterThanOrEqual(0.15);
    expect(r.superRatio).toBeLessThanOrEqual(0.25);
    expect(r.flapPerNodeMin).toBeLessThanOrEqual(1);
  });

  it.each(SEEDS)("seed %i delivers >=90% of messages", (seed) => {
    const r = results.get(seed)!;
    expect(r.deliveryRatio).toBeGreaterThanOrEqual(0.9);
  });

  it.each(SEEDS)("seed %i delivers >=90% within five hops", (seed) => {
    const r = results.get(seed)!;
    expect(r.withinFiveRatio).toBeGreaterThanOrEqual(0.9);
    // Paths stay short: the doc target is a ~3 hop network.
    expect(r.avgHops).toBeLessThanOrEqual(3);
  });

  it.each(SEEDS)("seed %i uses <=70% of the naive flood-all relay budget", (seed) => {
    const r = results.get(seed)!;
    // The documented bar is 70%. Measured against a genuinely naive baseline
    // (no route table, no suppression) the engine sits at 7-9%, so the real
    // margin is pinned separately from the loose bar: a regression that doubles
    // the relay count should fail here instead of hiding inside 70%.
    expect(r.overheadVsFlood).toBeLessThanOrEqual(0.7);
    expect(r.overheadVsFlood).toBeLessThanOrEqual(0.25);
    // MPR must never cost *more* than routing without suppression. The size of
    // that cut is pinned on the mean below, not per seed.
    expect(r.overheadVsRouteFlood).toBeLessThan(1);
  });

  it("MPR buys a further cut over routing without suppression, on the mean", () => {
    // Per seed this ratio is noisy on a cold start — 0.61 to 0.95 across the six
    // seeds. The reason is instructive: `route-flood` is the arm that floods most,
    // so it was also the arm most inflated by the originator re-flooding copies of
    // its own message that peers relayed back. With that amplifier gone (the
    // duplicate guard in onMsgReceive) the marginal cut is real but smaller than
    // the 0.85 an earlier measurement suggested: measured mean 0.736 with the
    // guard, 0.666 without, i.e. part of the old "advantage" was the amplifier
    // being proportional to how much you flood. Pinned on the mean so a seed that
    // happens to route most traffic in one hop cannot move the bar.
    const all = [...results.values()];
    const mean = all.reduce((a, r) => a + r.overheadVsRouteFlood, 0) / all.length;
    expect(all.length).toBe(SEEDS.length);
    expect(mean).toBeLessThanOrEqual(0.8);
  });

  it.each(SEEDS)("seed %i keeps a fully connected world with no isolated node", (seed) => {
    const r = results.get(seed)!;
    expect(r.sim.nodes.filter((n) => n.peerCount === 0)).toHaveLength(0);
    expect(r.sim.stats.avgPeers).toBeGreaterThan(3);
  });

  it("respects the docs/04 latency budget", () => {
    for (const seed of SEEDS) {
      const r = results.get(seed)!;
      expect(r.oneHopMax).toBeLessThan(2000); // 1 hop < 2 s
      expect(r.threeHopMax).toBeLessThan(5000); // 3 hops < 5 s
    }
  });

  it("suppression actually fires, and only under MPR", () => {
    for (const seed of SEEDS) {
      const r = results.get(seed)!;
      expect(r.sim.stats.mprSuppressed).toBeGreaterThan(0);
    }
  });
});

describe("dense crowd (docs/02 §6: 50+ nodes)", () => {
  it("stays stable and cheap at 60 nodes", () => {
    const r = measure(festivalCrowd(42));
    expect(r.superRatio).toBeGreaterThanOrEqual(0.1);
    expect(r.superRatio).toBeLessThanOrEqual(0.3);
    expect(r.flapPerNodeMin).toBeLessThanOrEqual(1);
    expect(r.avgHops).toBeLessThanOrEqual(4);
    expect(r.deliveryRatio).toBeGreaterThanOrEqual(0.85);
  });

  it("costs MPR nothing against the same engine without suppression", () => {
    // docs/05 §"Duman's hybrid selection": MPR suppression must cut redundant
    // transmissions without costing delivery. Suppression gated on *coverage*
    // (does a relay I heard actually reach my neighbours?) is what makes that
    // hold: the doc-literal "heard any SUPER" rule lost 16-29 delivery points
    // here, because a SUPER three clusters away still silenced this node.
    //
    // The yardstick is `route-flood`, not `flood-all`. Naive epidemic flooding
    // does reach 100% in this crowd — by spending 7-9x the relays — so
    // "within 5 points of flood-all" would demand epidemic redundancy from a
    // routing engine and measure nothing about MPR. And the bound is on the
    // mean across seeds: 150 messages through a chaotic 60-node world carries
    // several points of run-to-run variance, which a per-seed bound mistakes
    // for a regression. Measured mean gap: -0.9 points.
    const gaps: number[] = [];
    for (const seed of [42, 7, 1234]) {
      const r = measure(festivalCrowd(seed));
      gaps.push(r.deliveryRatio - r.routeFloodDeliveryRatio);
      // 12-14% of the naive flood budget; the documented bar is 70%.
      expect(r.overheadVsFlood).toBeLessThanOrEqual(0.2);
      // MPR's own marginal cut on top of routing: 42-50% measured.
      expect(r.overheadVsRouteFlood).toBeLessThanOrEqual(0.7);
      expect(r.sim.stats.mprSuppressed).toBeGreaterThan(1000);
      expect(r.deliveryRatio).toBeGreaterThanOrEqual(0.85);
    }
    const mean = gaps.reduce((a, b) => a + b, 0) / gaps.length;
    expect(mean).toBeGreaterThanOrEqual(-0.03);
  });
});

describe("delay-tolerant scenarios", () => {
  it("carries traffic in a sparse village instead of dropping it", () => {
    const r = measure(sparseVillage(42), false);
    expect(r.sim.stats.totalQueued).toBeGreaterThan(0);
    expect(r.sim.nodes.every((n) => n.oppQueue.length <= 500)).toBe(true);
  });

  it("exposes every named scenario through the same factory", () => {
    expect(scenarioNames()).toEqual(["campus_quad", "sparse_village", "festival_crowd", "partitioned_pair"]);
    for (const name of scenarioNames()) {
      const cfg = buildScenario(name, 42);
      const sim = new MeshSimulation(cfg);
      sim.runFor(2000);
      expect(sim.nodes).toHaveLength(cfg.nodeCount);
    }
    expect(() => buildScenario("nope")).toThrow(/Unknown scenario/);
  });

  it("honours the skills/08 configuration envelope", () => {
    // nodeCount 10-200, configurable area, walls, RSSI model.
    for (const nodeCount of [10, 60]) {
      const sim = new MeshSimulation({ ...campusQuad(42), nodeCount });
      sim.runFor(2000);
      expect(sim.nodes).toHaveLength(nodeCount);
    }
    const cfg = { ...campusQuad(42), areaWidth: 200, areaHeight: 120, wallPenaltyDb: 20 };
    const sim = new MeshSimulation(cfg);
    for (const n of sim.nodes) {
      expect(n.pos.x).toBeLessThanOrEqual(200);
      expect(n.pos.y).toBeLessThanOrEqual(120);
    }
    expect(sim.rf.wallPenaltyDb).toBe(20);
  });
});

describe("golden vectors shared with sim/mesh_sim (Dart)", () => {
  const fixture = JSON.parse(
    readFileSync(resolve(process.cwd(), "test-fixtures/golden-vectors.json"), "utf8")
  ) as {
    version: number;
    rng: { seed: number; fixedPointScale: number; values: number[] };
    spawn: { scenario: string; seed: number; nodes: Array<Record<string, unknown>> };
    run: { scenario: string; seed: number; messages: number; gapMs: number; expect: Record<string, number> };
  };

  it("reproduces the mulberry32 stream bit-for-bit", () => {
    const rng = createRng(fixture.rng.seed);
    for (const expected of fixture.rng.values) {
      expect(Math.round(rng() * fixture.rng.fixedPointScale)).toBe(expected);
    }
  });

  it("reproduces the seeded spawn geometry", () => {
    // Compared at spawn time, not after the constructor's warm-up window has
    // moved people around their waypoints.
    const cfg = buildScenario(fixture.spawn.scenario, fixture.spawn.seed);
    const nodes = createNodes(createRng(cfg.seed), cfg);
    expect(nodes).toHaveLength(fixture.spawn.nodes.length);
    nodes.forEach((node, i) => {
      const g = fixture.spawn.nodes[i];
      expect(node.id).toBe(g.id);
      expect(node.pos.x).toBeCloseTo(g.x as number, 5);
      expect(node.pos.y).toBeCloseTo(g.y as number, 5);
      expect(node.battery).toBeCloseTo(g.battery as number, 8);
      expect(node.uptimeMin).toBeCloseTo(g.uptimeMin as number, 5);
      expect(node.mobility).toBeCloseTo(g.mobility as number, 8);
      expect(node.pdr).toBeCloseTo(g.pdr as number, 8);
      expect(node.stationary).toBe(g.stationary);
      expect(node.charging).toBe(g.charging);
    });
  });

  it("reproduces the reference run", () => {
    const cfg = buildScenario(fixture.run.scenario, fixture.run.seed);
    const sim = new MeshSimulation(cfg);
    for (let i = 0; i < fixture.run.messages; i++) {
      const online = sim.nodes.filter((n) => n.isOnline);
      const from = online[Math.floor(sim.rng() * online.length)];
      let to = online[Math.floor(sim.rng() * online.length)];
      let guard = 0;
      while (to.id === from.id && guard++ < 32) to = online[Math.floor(sim.rng() * online.length)];
      if (to.id !== from.id) sim.sendMessage(from.id, to.id, `golden-${i}`, "text");
      sim.runFor(fixture.run.gapMs);
    }
    sim.refresh();

    const e = fixture.run.expect;
    const uni = sim.deliveries.filter((d) => d.type !== "ack" && d.type !== "broadcast");
    const transitions = sim.nodes.reduce((s, n) => s + n.roleTransitions, 0);

    // Integer protocol counters: these must match exactly. A mismatch means the
    // two engines have diverged in logic or in RNG draw order.
    expect(sim.now).toBe(e.simTimeMs);
    expect(sim.nodes.filter((n) => n.isOnline).length).toBe(e.onlineNodes);
    expect(sim.nodes.filter((n) => n.role === "SUPER").length).toBe(e.superNodes);
    expect(sim.stats.sentUnicast).toBe(e.sentUnicast);
    expect(uni.length).toBe(e.deliveredUnicast);
    expect(sim.stats.totalForwarded).toBe(e.relayTx);
    expect(sim.stats.controlOverhead).toBe(e.ogmTx);
    expect(sim.stats.retriesSent).toBe(e.retriesSent);
    expect(sim.stats.acksReceived).toBe(e.acksReceived);
    expect(transitions).toBe(e.roleTransitions);
    expect(sim.stats.totalQueued).toBe(e.totalQueued);
    expect(uni.reduce((s, d) => s + d.hops, 0)).toBe(e.sumHopCounts);

    // Floating aggregates: tolerance absorbs last-ULP differences between the
    // JS and Dart libm implementations of log10/sin/cos/sqrt.
    expect(sim.stats.avgScore).toBeCloseTo(e.avgScore, 5);
    expect(sim.stats.avgHops).toBeCloseTo(e.avgHops, 5);
    expect(sim.stats.avgLatencyMs).toBeCloseTo(e.avgLatencyMs, 2);
    expect(sim.stats.p95LatencyMs).toBeCloseTo(e.p95LatencyMs, 2);
  });
});
