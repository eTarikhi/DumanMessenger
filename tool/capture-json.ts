/**
 * Emit a field-test capture from a simulated run (`docs/09-field-test-plan.md` §4).
 *
 * The point is not another simulator report: it is to produce the *same JSONL a rack of
 * real phones will produce*, so the analyzer in `tool/field-report.ts` can be written,
 * tested and debugged now, against a log whose ground truth is known, instead of being
 * written on the day of the field test against a log whose ground truth is not.
 *
 *   npm run field:capture -- campus_quad 42 /tmp/capture.jsonl
 */
import { writeFileSync } from "node:fs";
import { MeshSimulation, type SimConfig } from "../src/simulation";
import { buildScenario, scenarioNames } from "../src/scenarios";
import { countWallCrossings, distance, rssiModel } from "../src/rf";
import type { MeshLogEntry } from "../src/types";

const MESSAGES = 150;
const GAP_MS = 1000;
const SAMPLE_MS = 30000;

interface Record_ {
  v: 1;
  kind: string;
  atMs: number;
  device: string;
  [key: string]: unknown;
}

function logRecord(e: MeshLogEntry): Record_ {
  return {
    v: 1,
    kind: e.kind,
    atMs: Math.round(e.atMs * 1000) / 1000,
    device: e.nodeId,
    ...(e.peerId !== undefined ? { peerId: e.peerId } : {}),
    ...(e.msgId !== undefined ? { msgId: e.msgId } : {}),
    ...(e.msgType !== undefined ? { msgType: e.msgType } : {}),
    ...(e.hop !== undefined ? { hop: e.hop } : {}),
    ...(e.rssi !== undefined ? { rssi: Math.round(e.rssi * 100) / 100 } : {}),
    detail: e.detail,
  };
}

function main(): void {
  const requested = process.argv[2] ?? "campus_quad";
  const scenario = (
    scenarioNames().includes(requested as never) ? requested : "campus_quad"
  ) as ReturnType<typeof scenarioNames>[number];
  const seed = Number(process.argv[3] ?? 42);
  const out = process.argv[4] ?? "/tmp/field-capture.jsonl";
  // The field test's A/B: the same world under a naive flood-all relay policy, so the
  // analyzer can judge "overhead ≤70% of flood-all" from two captures.
  const policy = process.argv[5] as SimConfig["relayPolicy"] | undefined;

  const world: SimConfig = {
    ...buildScenario(scenario, seed),
    captureLog: true,
    // A phone rotates its log to disk; the engine's 2000-entry cap would silently drop
    // the start of the run and with it the denominator of every ratio below.
    maxLogEntries: Number.MAX_SAFE_INTEGER,
    ...(policy ? { relayPolicy: policy } : {}),
  };
  const sim = new MeshSimulation(world);
  sim.runFor(world.warmupMs);
  sim.clearRecords();

  const lines: Record_[] = [
    {
      v: 1,
      kind: "meta",
      atMs: 0,
      device: "simulator",
      scenario,
      seed,
      nodes: sim.nodes.length,
      engine: "typescript-reference",
      policy: world.relayPolicy,
      dutyCycle: world.dutyCycleEnabled,
      maxLogEntries: world.maxLogEntries,
      note: "synthetic capture: the same schema a rack of phones emits (docs/09 §4)",
    },
  ];

  // Traffic, sampled as it goes: the log grows while the world moves, exactly as it
  // would on the day, and the analyzer has to cope with that.
  let nextSample = SAMPLE_MS;
  for (let i = 0; i < MESSAGES; i++) {
    sim.injectRandomMessage();
    sim.runFor(GAP_MS);
    while (sim.now >= nextSample) {
      for (const node of sim.nodes) {
        lines.push({
          v: 1,
          kind: "sample",
          atMs: nextSample,
          device: node.id,
          role: node.role,
          battery: Math.round(node.battery * 10000) / 10000,
          charging: node.charging,
          online: node.isOnline,
          awake: sim.isAwake(node),
          peers: node.peerIds.length,
          txCount: node.txCount,
        });
        // What a calibration walk logs: an RSSI reading against a measured distance and
        // a counted number of walls between the two phones.
        for (const peerId of node.peerIds) {
          const peer = sim.nodes.find((p) => p.id === peerId);
          if (!peer) continue;
          lines.push({
            v: 1,
            kind: "calibration",
            atMs: nextSample,
            device: node.id,
            peerId,
            rssi: Math.round(rssiModel(node, peer, sim.rf) * 100) / 100,
            distanceM: Math.round(distance(node.pos, peer.pos) * 100) / 100,
            walls: countWallCrossings(node.pos, peer.pos, sim.rf.obstacles),
          });
        }
      }
      // One network-wide record per sample boundary, beside the per-device ones. `device` is
      // `"*"` because the record is about the graph and not about a phone, which is the
      // convention `docs/09` §4 documents for it.
      //
      // This exists because `docs/06` §24.10 measured what happens without it: a 60-node crowd
      // splits and re-joins inside a window, so broadcast reach reads as two modes, and a graph
      // sampled once *after* the walk cannot tell a partition that healed from one that never
      // happened. §24.9 drew exactly that wrong conclusion from exactly that measurement.
      // `docs/09` §5 asks the field team to log connectivity during the walk; this is the
      // simulator's half of that, so §7 can validate the analyzer against known ground truth.
      const sizes = sim.componentSizes();
      lines.push({
        v: 1,
        kind: "topology",
        atMs: nextSample,
        device: "*",
        nodes: sim.nodes.length,
        components: sizes.length,
        largest: sizes[0] ?? 0,
        connected: sizes.length === 1,
      });
      nextSample += SAMPLE_MS;
    }
  }
  sim.runFor(60000); // let the last messages land

  for (const entry of sim.log) lines.push(logRecord(entry));

  lines.sort((a, b) => a.atMs - b.atMs);
  writeFileSync(out, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");

  const stats = sim.refresh();
  const kinds = new Map<string, number>();
  for (const l of lines) kinds.set(l.kind, (kinds.get(l.kind) ?? 0) + 1);
  console.log(`wrote ${lines.length} records to ${out}`);
  console.log(`  ${[...kinds.entries()].map(([k, n]) => `${k}=${n}`).join(" ")}`);
  console.log(
    `  ground truth for the analyzer: deliveryRatio ${stats.deliveryRatio.toFixed(4)}, ` +
      `relayTx ${stats.totalForwarded}, sentUnicast ${stats.sentUnicast}, ` +
      `superRatio ${stats.superRatio.toFixed(4)}, p95 ${stats.p95LatencyMs.toFixed(0)} ms`
  );
}

main();
