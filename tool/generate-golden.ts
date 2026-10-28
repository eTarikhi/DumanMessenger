/**
 * Generates `test-fixtures/golden-vectors.json`.
 *
 * The fixture is the cross-language contract between this TypeScript reference
 * implementation and the authoritative Dart engine in `sim/mesh_sim`. Both test
 * suites assert against the same numbers, so a divergence in the RNG, the spawn
 * geometry or the protocol logic fails CI in whichever language drifted.
 *
 * Regenerate with `npm run golden` after an intentional engine change, then
 * update the Dart expectations in the same commit.
 */
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { createRng } from "../src/rng";
import { MeshSimulation, createNodes, type SimConfig } from "../src/simulation";
import { campusQuad } from "../src/scenarios";
import type { HistoryEntry } from "../src/types";

const SEED = 42;
const MESSAGES = 20;
const GAP_MS = 1500;

/** Fixed-point so no decimal-formatting differences can creep in. */
const fp = (v: number, scale = 1e9) => Math.round(v * scale);

function rngVectors() {
  const rng = createRng(SEED);
  const values: number[] = [];
  for (let i = 0; i < 16; i++) values.push(fp(rng()));
  return { seed: SEED, fixedPointScale: 1e9, values };
}

function spawnVectors(config: SimConfig) {
  const rng = createRng(config.seed);
  const nodes = createNodes(rng, config);
  return nodes.map((n) => ({
    id: n.id,
    x: Number(n.pos.x.toFixed(6)),
    y: Number(n.pos.y.toFixed(6)),
    battery: Number(n.battery.toFixed(9)),
    uptimeMin: Number(n.uptimeMin.toFixed(6)),
    mobility: Number(n.mobility.toFixed(9)),
    pdr: Number(n.pdr.toFixed(9)),
    stationary: n.stationary,
    charging: n.charging,
  }));
}

/** Deterministic traffic: pairs drawn from the simulation's own RNG. */
function runVectors(config: SimConfig) {
  const sim = new MeshSimulation(config);
  for (let i = 0; i < MESSAGES; i++) {
    const online = sim.nodes.filter((n) => n.isOnline);
    if (online.length >= 2) {
      const from = online[Math.floor(sim.rng() * online.length)];
      let to = online[Math.floor(sim.rng() * online.length)];
      let guard = 0;
      while (to.id === from.id && guard++ < 32) {
        to = online[Math.floor(sim.rng() * online.length)];
      }
      if (to.id !== from.id) sim.sendMessage(from.id, to.id, `golden-${i}`, "text");
    }
    sim.runFor(GAP_MS);
  }
  sim.refresh();

  const unicast = sim.deliveries.filter((d) => d.type !== "ack" && d.type !== "broadcast");
  const transitions = sim.nodes.reduce((s, n) => s + n.roleTransitions, 0);
  return {
    scenario: "campus_quad",
    seed: config.seed,
    messages: MESSAGES,
    gapMs: GAP_MS,
    expect: {
      onlineNodes: sim.nodes.filter((n) => n.isOnline).length,
      superNodes: sim.nodes.filter((n) => n.role === "SUPER").length,
      sentUnicast: sim.stats.sentUnicast,
      deliveredUnicast: unicast.length,
      relayTx: sim.stats.totalForwarded,
      ogmTx: sim.stats.controlOverhead,
      retriesSent: sim.stats.retriesSent,
      acksReceived: sim.stats.acksReceived,
      roleTransitions: transitions,
      totalQueued: sim.stats.totalQueued,
      sumHopCounts: unicast.reduce((s, d) => s + d.hops, 0),
      // Both readings of the hop criterion, pinned so the two engines cannot drift on a number an
      // owner decision rests on (finding F2: skills/02 writes it at three hops, skills/08 at five).
      // Counted over the gate's own population — every unicast delivery, retries and DTN bundles included. Do not derive either reading from `latencyByHop`: that table is scoped to first-attempt routed unicast, so it omits exactly the deliveries that make the two numbers differ (campus_quad seed 42: 148 within five hops, 140 in the table).
      deliveredWithinFiveHops: unicast.filter((d) => d.hops <= 5).length,
      deliveredWithinThreeHops: unicast.filter((d) => d.hops <= 3).length,
      simTimeMs: fp(sim.now, 1),
      avgScore: Number(sim.stats.avgScore.toFixed(6)),
      avgHops: Number(sim.stats.avgHops.toFixed(6)),
      avgLatencyMs: Number(sim.stats.avgLatencyMs.toFixed(3)),
      p95LatencyMs: Number(sim.stats.p95LatencyMs.toFixed(3)),
    },
  };
}

/**
 * The anti-entropy reply body, byte for byte.
 *
 * `docs/06` §17.6 accounts sync packets separately and promises the golden vectors stay identical in
 * both languages, which they do — but "identical" only ever covered the RNG, the spawn geometry and
 * a run that creates no group, so nothing pinned the one thing a repair actually puts on air: the
 * serialised entries. That gap was measurable the first time CI ran the Dart engine at all. The two
 * engines reported the same 166 beacons, 3 requests, 2 replies and 171 packets for the same history
 * probe, and different payload bytes: 30 430 here against 29 750 there.
 *
 * The cause was two encoding details, worth 17 bytes an entry:
 *
 *   · `synced?: boolean` is `undefined` until a copy arrives by repair, and `JSON.stringify` drops
 *     undefined keys. Dart's `toJson()` emitted `"synced":false` unconditionally — 15 bytes to say
 *     nothing the receiver does not already know, since it sets the flag itself.
 *   · an integral `at` prints as `1200` from a JS `number` and as `1200.0` from a Dart `double`:
 *     2 more bytes.
 *
 * So this section carries the entries *and* the exact string both engines must produce from them.
 * The Dart side rebuilds the entries with `HistoryEntry.fromJson` and compares `jsonEncode` against
 * `replyBody`; this side compares `JSON.stringify` against the same field. Neither engine can change
 * its encoding without moving the fixture, and moving the fixture fails the `web` job's
 * `git diff --quiet` check until both sides are updated together.
 *
 * ASCII only, deliberately: `src/__tests__/wire-bytes.test.ts` records that this fixture contains no
 * non-ASCII character, which is what lets one engine count code units and the other bytes.
 */
function historyVectors() {
  const entries: HistoryEntry[] = [
    { msgId: "grp-1:0:node-3", groupId: "grp-1", from: "node-3", at: 1200, body: "first", epoch: 0 },
    { msgId: "grp-1:1:node-7", groupId: "grp-1", from: "node-7", at: 1500.5, body: "second", epoch: 0 },
    {
      msgId: "grp-1:2:node-3",
      groupId: "grp-1",
      from: "node-3",
      at: 2400,
      body: "repaired copy",
      epoch: 1,
      synced: true,
    },
  ];
  const replyBody = JSON.stringify(entries);
  return {
    note:
      "One anti-entropy reply body, and the entries it is built from. Both engines must serialise " +
      "these entries to exactly replyBody: an entry carries no synced key unless it is true, and an " +
      "integral at carries no decimal point.",
    entries,
    replyBody,
    replyBytes: replyBody.length,
  };
}

const config = campusQuad(SEED);
const fixture = {
  // 2 added the `history` section: the reply-body encoding both engines must agree on byte for byte.
  version: 2,
  note: "Generated by tool/generate-golden.ts. Do not edit by hand.",
  generatedFrom: "src/ (TypeScript reference implementation)",
  rng: rngVectors(),
  spawn: { scenario: "campus_quad", seed: SEED, nodes: spawnVectors(config) },
  run: runVectors(config),
  history: historyVectors(),
};

const out = resolve(__dirname, "../../../test-fixtures/golden-vectors.json");
writeFileSync(out, JSON.stringify(fixture, null, 2) + "\n");
console.log(`wrote ${out}`);
console.log(JSON.stringify(fixture.run.expect, null, 2));
